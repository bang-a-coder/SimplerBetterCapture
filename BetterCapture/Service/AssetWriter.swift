//
//  AssetWriter.swift
//  BetterCapture
//
//  Created by Joshua Sattler on 29.01.26.
//

import AVFoundation
import CoreVideo
import Foundation
import OSLog
import ScreenCaptureKit
import VideoToolbox
import os

typealias RecordingAudioActivityHandler = @Sendable (RecordingAudioSource, Float) -> Void

/// Service responsible for writing captured media to disk using AVAssetWriter
nonisolated final class AssetWriter: CaptureEngineSampleBufferDelegate, @unchecked Sendable {

    private enum PostProcessingMode {
        case none
        case mixedAudio
    }

    private struct AudioActivity {
        let source: RecordingAudioSource
        let level: Float
        let handler: RecordingAudioActivityHandler
    }

    // MARK: - Properties

    var audioActivityHandler: RecordingAudioActivityHandler? {
        get {
            audioActivityHandlerLock.withLockUnchecked {
                _audioActivityHandler
            }
        }
        set {
            audioActivityHandlerLock.withLockUnchecked {
                _audioActivityHandler = newValue
            }
        }
    }
    private(set) var lastAudioWriteSummary = RecordingAudioWriteSummary()

    private var _audioActivityHandler: RecordingAudioActivityHandler?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var secondaryAudioWriter: AVAssetWriter?
    private var secondaryAudioInput: AVAssetWriterInput?

    private(set) var isWriting = false
    private(set) var outputURL: URL?
    private var workingOutputURL: URL?
    private var secondaryOutputURL: URL?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture", category: "AssetWriter")

    // Track if we've received the first sample
    private var hasStartedSession = false
    private var sessionStartTime: CMTime = .zero
    private var secondaryHasStartedSession = false

    /// Last appended video presentation time — used to enforce monotonically
    /// increasing timestamps and protect the writer from timing glitches that
    /// occur when Presenter Overlay composites the camera into the stream.
    private var lastVideoPresentationTime: CMTime = .invalid
    private var didReceiveVideoSample = false
    private var didReceiveAudioSample = false
    private var didReceiveMicrophoneSample = false
    private var maxAudioLevel: Float = 0
    private var maxMicrophoneLevel: Float = 0
    private var lastAudioActivityCallbackDates: [RecordingAudioSource: Date] = [:]
    private let audioActivityCallbackInterval: TimeInterval = 0.12
    private var captureVideo = true
    private var captureSystemAudio = false
    private var captureMicrophone = false
    private var separateAudioTracks = false
    private var postProcessingMode: PostProcessingMode = .none

    /// The active HDR preset for this recording session, used to select the
    /// correct color properties for the output container and per-frame tagging.
    private var activeHDRPreset: HDRPreset = .sdr

    /// Whether per-frame `CVBufferSetAttachment` color tagging is needed.
    /// True only for ProRes HDR, where `AVVideoColorPropertiesKey` must be omitted.
    private var tagBuffersWithHDRColorimetry = false

    // Lock for thread-safe access to writer state
    private let lock = OSAllocatedUnfairLock()
    private let audioActivityHandlerLock = OSAllocatedUnfairLock()

    // MARK: - Setup

    /// Prepares the asset writer for recording
    /// - Parameters:
    ///   - url: The output file URL
    ///   - settings: The settings store containing encoding configuration
    ///   - videoSize: The dimensions of the video
    @MainActor
    func setup(
        url: URL,
        settings: SettingsStore,
        videoSize: CGSize,
        captureVideo: Bool = true,
        separateAudioTracks: Bool = true
    ) throws {
        self.captureVideo = captureVideo
        self.captureSystemAudio = settings.captureSystemAudio
        self.captureMicrophone = settings.captureMicrophone
        self.separateAudioTracks = separateAudioTracks
        self.secondaryAudioWriter = nil
        self.secondaryAudioInput = nil
        self.secondaryOutputURL = nil
        self.secondaryHasStartedSession = false
        self.postProcessingMode = determinePostProcessingMode(
            captureVideo: captureVideo,
            captureSystemAudio: settings.captureSystemAudio,
            captureMicrophone: settings.captureMicrophone,
            separateAudioTracks: separateAudioTracks
        )

        let plannedOutputURLs = Self.plannedOutputURLs(for: url, settings: settings)
        let finalOutputURL = plannedOutputURLs.primary
        let secondaryURL = plannedOutputURLs.secondary
        let captureURL = workingCaptureURL(
            for: finalOutputURL,
            needsPostProcessing: postProcessingMode != .none
        )
        let directory = captureURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for existingURL in [finalOutputURL, captureURL, secondaryURL] {
            guard let existingURL, FileManager.default.fileExists(atPath: existingURL.path()) else {
                continue
            }
            try FileManager.default.removeItem(at: existingURL)
        }

        let fileType: AVFileType = if postProcessingMode != .none {
            .mov
        } else if captureVideo {
            settings.containerFormat == .mov ? .mov : .mp4
        } else {
            settings.audioCodec == .aac ? .m4a : .caf
        }

        assetWriter = try AVAssetWriter(outputURL: captureURL, fileType: fileType)

        guard let assetWriter else {
            throw AssetWriterError.failedToCreateWriter
        }

        if captureVideo {
            // Configure video input
            let videoSettings = createVideoSettings(from: settings, size: videoSize)
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput?.expectsMediaDataInRealTime = true

            if let videoInput, assetWriter.canAdd(videoInput) {
                assetWriter.add(videoInput)

                // Create pixel buffer adaptor for appending raw pixel buffers from ScreenCaptureKit.
                // Must match the pixel format configured on SCStreamConfiguration in CaptureEngine.
                let pixelFormat: OSType =
                    (settings.captureHDR && settings.videoCodec.supportsHDR)
                    ? settings.videoCodec.hdrPixelFormat
                    : kCVPixelFormatType_32BGRA

                let sourcePixelBufferAttributes: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                    kCVPixelBufferWidthKey as String: Int(videoSize.width),
                    kCVPixelBufferHeightKey as String: Int(videoSize.height)
                ]
                pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: videoInput,
                    sourcePixelBufferAttributes: sourcePixelBufferAttributes
                )
            }
        }

        if settings.captureSystemAudio {
            let audioSettings = createAudioSettings(for: settings.audioCodec)
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput?.expectsMediaDataInRealTime = true

            if let audioInput, assetWriter.canAdd(audioInput) {
                assetWriter.add(audioInput)
            }
        }

        if settings.captureMicrophone && !usesDirectSeparateAudioOutputs {
            let micSettings = createAudioSettings(for: settings.audioCodec)
            microphoneInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            microphoneInput?.expectsMediaDataInRealTime = true

            if let microphoneInput, assetWriter.canAdd(microphoneInput) {
                assetWriter.add(microphoneInput)
            }
        }

        if usesDirectSeparateAudioOutputs, let secondaryURL {
            let secondaryFileType: AVFileType = settings.audioCodec == .aac ? .m4a : .caf
            let secondaryWriter = try AVAssetWriter(outputURL: secondaryURL, fileType: secondaryFileType)
            let secondaryInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: createAudioSettings(for: settings.audioCodec)
            )
            secondaryInput.expectsMediaDataInRealTime = true

            guard secondaryWriter.canAdd(secondaryInput) else {
                throw AssetWriterError.failedToCreateWriter
            }

            secondaryWriter.add(secondaryInput)
            secondaryAudioWriter = secondaryWriter
            secondaryAudioInput = secondaryInput
        }

        activeHDRPreset = settings.hdrPreset
        let isProResHDR = activeHDRPreset != .sdr
            && (settings.videoCodec == .proRes422 || settings.videoCodec == .proRes4444)
        tagBuffersWithHDRColorimetry = isProResHDR

        outputURL = finalOutputURL
        workingOutputURL = captureURL
        secondaryOutputURL = secondaryURL
        hasStartedSession = false
        sessionStartTime = .zero
        secondaryHasStartedSession = false
        lastVideoPresentationTime = .invalid
        frameCount = 0
        didReceiveVideoSample = false
        didReceiveAudioSample = false
        didReceiveMicrophoneSample = false
        maxAudioLevel = 0
        maxMicrophoneLevel = 0
        lastAudioActivityCallbackDates = [:]
        lastAudioWriteSummary = RecordingAudioWriteSummary()

        logger.info("AssetWriter configured for output: \(captureURL.lastPathComponent)")
    }

    // MARK: - Writing

    /// Starts the writing session
    func startWriting() throws {
        guard let assetWriter, assetWriter.status == .unknown else {
            throw AssetWriterError.writerNotReady
        }

        guard assetWriter.startWriting() else {
            throw AssetWriterError.failedToStartWriting(assetWriter.error)
        }

        if let secondaryAudioWriter {
            guard secondaryAudioWriter.status == .unknown else {
                throw AssetWriterError.writerNotReady
            }

            guard secondaryAudioWriter.startWriting() else {
                assetWriter.cancelWriting()
                throw AssetWriterError.failedToStartWriting(secondaryAudioWriter.error)
            }
        }

        isWriting = true
        logger.info("AssetWriter started writing")
    }

    // Track frame counts for debugging
    private var frameCount = 0

    private var usesDirectSeparateAudioOutputs: Bool {
        !captureVideo && separateAudioTracks && captureSystemAudio && captureMicrophone
    }

    /// Appends a video sample buffer - called synchronously from capture queue
    func appendVideoSample(_ sampleBuffer: CMSampleBuffer) {
        // Check frame status first - only process complete frames
        guard
            let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[String: Any]],
            let attachments = attachmentsArray.first,
            let statusRawValue = attachments[SCStreamFrameInfo.status.rawValue] as? Int,
            let status = SCFrameStatus(rawValue: statusRawValue)
        else {
            logger.warning("Could not extract frame status from sample buffer")
            return
        }

        guard status == .complete else {
            // Frame is not complete (idle, blank, etc.) - skip silently
            return
        }

        lock.withLockUnchecked {
            guard let assetWriter,
                assetWriter.status == .writing,
                let videoInput,
                videoInput.isReadyForMoreMediaData,
                let adaptor = pixelBufferAdaptor
            else {
                return
            }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // Start session on first sample
            if !hasStartedSession {
                assetWriter.startSession(atSourceTime: presentationTime)
                sessionStartTime = presentationTime
                hasStartedSession = true
                logger.info("Session started at time: \(presentationTime.seconds)")
            } else {
                // Guard against non-monotonic timestamps. Presenter Overlay can
                // cause timing glitches when compositing the camera into the
                // stream; a single bad timestamp permanently fails the writer.
                if lastVideoPresentationTime.isValid
                    && presentationTime <= lastVideoPresentationTime {
                    return
                }
            }

            // Extract pixel buffer from sample buffer
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                logger.warning("No image buffer in complete video frame")
                return
            }

            // Log incoming buffer properties on the first frame to aid HDR debugging.
            if frameCount == 0 {
                logPixelBufferProperties(pixelBuffer)
            }

            // For ProRes HDR, inject BT.2020 / PQ colorimetry directly onto
            // the pixel buffer. AVAssetWriter prohibits AVVideoColorPropertiesKey
            // for the high-bit-depth formats ProRes uses, so we tag each frame
            // to ensure the output file contains correct 'colr' / 'nclx' atoms.
            if tagBuffersWithHDRColorimetry {
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            }

            // Append using the pixel buffer adaptor
            if adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
                lastVideoPresentationTime = presentationTime
                didReceiveVideoSample = true
                frameCount += 1
                if frameCount == 1 {
                    logger.info("First video frame appended successfully")
                }
            } else {
                if let error = assetWriter.error {
                    logger.error(
                        "Failed to append video pixel buffer: \(error.localizedDescription)")
                } else {
                    logger.error("Failed to append video pixel buffer - no error available")
                }
            }
        }
    }

    /// Appends a system audio sample buffer - called synchronously from capture queue
    func appendAudioSample(_ sampleBuffer: CMSampleBuffer) {
        let activity: AudioActivity? = lock.withLockUnchecked {
            guard let assetWriter,
                assetWriter.status == .writing,
                let audioInput,
                audioInput.isReadyForMoreMediaData
            else {
                return nil
            }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let level = AudioLevelMeter.level(for: sampleBuffer)

            // Start session on first sample if video hasn't started it yet
            if !hasStartedSession {
                assetWriter.startSession(atSourceTime: presentationTime)
                sessionStartTime = presentationTime
                hasStartedSession = true
                logger.info("Session started at time: \(presentationTime.seconds)")
            }

            if !audioInput.append(sampleBuffer) {
                logger.error("Failed to append audio sample buffer")
                return nil
            } else {
                didReceiveAudioSample = true
                maxAudioLevel = max(maxAudioLevel, level)
                return audioActivity(source: .system, level: level)
            }
        }

        if let activity {
            activity.handler(activity.source, activity.level)
        }
    }

    /// Appends a microphone audio sample buffer
    func appendMicrophoneSample(_ sampleBuffer: CMSampleBuffer) {
        let activity: AudioActivity? = lock.withLockUnchecked {
            let level = AudioLevelMeter.level(for: sampleBuffer)

            if let secondaryAudioWriter,
                secondaryAudioWriter.status == .writing,
                let secondaryAudioInput,
                secondaryAudioInput.isReadyForMoreMediaData
            {
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

                if !hasStartedSession {
                    assetWriter?.startSession(atSourceTime: presentationTime)
                    sessionStartTime = presentationTime
                    hasStartedSession = true
                    logger.info("Session started at time: \(presentationTime.seconds)")
                }

                if !secondaryHasStartedSession {
                    secondaryAudioWriter.startSession(atSourceTime: presentationTime)
                    secondaryHasStartedSession = true
                    logger.info("Secondary audio session started at time: \(presentationTime.seconds)")
                }

                if !secondaryAudioInput.append(sampleBuffer) {
                    logger.error("Failed to append microphone sample buffer")
                    return nil
                } else {
                    didReceiveMicrophoneSample = true
                    maxMicrophoneLevel = max(maxMicrophoneLevel, level)
                    return audioActivity(source: .microphone, level: level)
                }
            }

            guard let assetWriter,
                assetWriter.status == .writing,
                let microphoneInput,
                microphoneInput.isReadyForMoreMediaData
            else {
                return nil
            }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if !hasStartedSession {
                assetWriter.startSession(atSourceTime: presentationTime)
                sessionStartTime = presentationTime
                hasStartedSession = true
                logger.info("Session started at time: \(presentationTime.seconds)")
            }

            if !microphoneInput.append(sampleBuffer) {
                logger.error("Failed to append microphone sample buffer")
                return nil
            } else {
                didReceiveMicrophoneSample = true
                maxMicrophoneLevel = max(maxMicrophoneLevel, level)
                return audioActivity(source: .microphone, level: level)
            }
        }

        if let activity {
            activity.handler(activity.source, activity.level)
        }
    }

    private func audioActivity(source: RecordingAudioSource, level: Float) -> AudioActivity? {
        let now = Date()

        if let lastCallbackDate = lastAudioActivityCallbackDates[source],
           now.timeIntervalSince(lastCallbackDate) < audioActivityCallbackInterval {
            return nil
        }

        lastAudioActivityCallbackDates[source] = now

        guard let audioActivityHandler else {
            return nil
        }

        return AudioActivity(source: source, level: level, handler: audioActivityHandler)
    }

    // MARK: - Finalization

    /// Finishes writing and finalizes the output file
    func finishWriting() async throws -> URL {
        // First critical section: validate state and mark inputs as finished
        let (
            writerToFinish,
            secondaryWriterToFinish,
            finalURL,
            workingURL,
            secondaryURL,
            postProcessingMode,
            secondarySessionStarted,
            didWriteSystemAudio,
            maxSystemAudioLevel,
            maxMicrophoneAudioLevel,
            didWriteMicrophoneSample
        ): (
            AVAssetWriter,
            AVAssetWriter?,
            URL,
            URL,
            URL?,
            PostProcessingMode,
            Bool,
            Bool,
            Float,
            Float,
            Bool
        )

        do {
            (
                writerToFinish,
                secondaryWriterToFinish,
                finalURL,
                workingURL,
                secondaryURL,
                postProcessingMode,
                secondarySessionStarted,
                didWriteSystemAudio,
                maxSystemAudioLevel,
                maxMicrophoneAudioLevel,
                didWriteMicrophoneSample
            ) = try lock.withLockUnchecked {
                guard let assetWriter, isWriting else {
                    throw AssetWriterError.writerNotReady
                }

                guard let outputURL, let workingOutputURL else {
                    throw AssetWriterError.noOutputURL
                }

                logger.info(
                    "Finishing writing - status: \(assetWriter.status.rawValue), session started: \(self.hasStartedSession), frames written: \(self.frameCount)"
                )

                let didWriteAnyMedia = self.didReceiveVideoSample
                    || self.didReceiveAudioSample
                    || self.didReceiveMicrophoneSample

                // Check if we actually started a session (received at least one frame).
                // Audio-only recordings are valid even when no video frames were written.
                guard hasStartedSession, didWriteAnyMedia else {
                    logger.error("No media samples were written - session was never started")
                    throw AssetWriterError.noFramesWritten
                }

                // Mark inputs as finished
                videoInput?.markAsFinished()
                audioInput?.markAsFinished()
                microphoneInput?.markAsFinished()
                secondaryAudioInput?.markAsFinished()

                return (
                    assetWriter,
                    self.secondaryAudioWriter,
                    outputURL,
                    workingOutputURL,
                    self.secondaryOutputURL,
                    self.postProcessingMode,
                    self.secondaryHasStartedSession,
                    self.didReceiveAudioSample,
                    self.maxAudioLevel,
                    self.maxMicrophoneLevel,
                    self.didReceiveMicrophoneSample
                )
            }
        } catch AssetWriterError.noFramesWritten {
            // Cancel needs to be called outside the lock since it acquires its own lock
            cancel()
            throw AssetWriterError.noFramesWritten
        }

        // Finish writing (outside lock since it's async)
        await writerToFinish.finishWriting()
        if let secondaryWriterToFinish, secondarySessionStarted {
            await secondaryWriterToFinish.finishWriting()
            if secondaryWriterToFinish.status == .failed {
                throw AssetWriterError.writingFailed(secondaryWriterToFinish.error)
            }
        } else {
            secondaryWriterToFinish?.cancelWriting()
        }

        // Second critical section: check final status and cleanup
        let captureURL = try lock.withLockUnchecked {
            guard let assetWriter else {
                throw AssetWriterError.writerNotReady
            }

            if assetWriter.status == .failed {
                let error = assetWriter.error
                logger.error(
                    "AssetWriter failed: \(error?.localizedDescription ?? "unknown error")")
                throw AssetWriterError.writingFailed(error)
            }

            isWriting = false
            hasStartedSession = false
            secondaryHasStartedSession = false
            lastVideoPresentationTime = .invalid
            activeHDRPreset = .sdr
            tagBuffersWithHDRColorimetry = false

            logger.info(
                "AssetWriter finished writing \(self.frameCount) frames to: \(workingURL.lastPathComponent)"
            )
            frameCount = 0
            didReceiveVideoSample = false
            didReceiveAudioSample = false
            didReceiveMicrophoneSample = false
            maxAudioLevel = 0
            maxMicrophoneLevel = 0
            lastAudioActivityCallbackDates = [:]
            lastAudioWriteSummary = RecordingAudioWriteSummary(
                didWriteSystemAudio: didWriteSystemAudio,
                didWriteMicrophoneAudio: didWriteMicrophoneSample,
                maxSystemAudioLevel: maxSystemAudioLevel,
                maxMicrophoneAudioLevel: maxMicrophoneAudioLevel
            )

            // Clean up
            self.assetWriter = nil
            self.videoInput = nil
            self.pixelBufferAdaptor = nil
            self.audioInput = nil
            self.microphoneInput = nil
            self.secondaryAudioWriter = nil
            self.secondaryAudioInput = nil
            self.workingOutputURL = nil

            return workingURL
        }

        var resultURL: URL
        switch postProcessingMode {
        case .none:
            resultURL = finalURL
        case .mixedAudio:
            try await exportMixedOutput(from: captureURL, to: finalURL)
            try? FileManager.default.removeItem(at: captureURL)
            resultURL = finalURL
        }

        if let secondaryURL {
            if !didWriteSystemAudio {
                try? FileManager.default.removeItem(at: finalURL)
                if didWriteMicrophoneSample {
                    resultURL = secondaryURL
                }
            }

            if !didWriteMicrophoneSample {
                try? FileManager.default.removeItem(at: secondaryURL)
            }
        }

        self.outputURL = resultURL
        return resultURL
    }

    /// Cancels the current writing session
    func cancel() {
        lock.withLockUnchecked {
            assetWriter?.cancelWriting()
            isWriting = false
            hasStartedSession = false
            secondaryHasStartedSession = false
            lastVideoPresentationTime = .invalid
            activeHDRPreset = .sdr
            tagBuffersWithHDRColorimetry = false
            frameCount = 0
            didReceiveVideoSample = false
            didReceiveAudioSample = false
            didReceiveMicrophoneSample = false
            maxAudioLevel = 0
            maxMicrophoneLevel = 0
            lastAudioActivityCallbackDates = [:]
            lastAudioWriteSummary = RecordingAudioWriteSummary()

            for url in [outputURL, workingOutputURL, secondaryOutputURL] {
                guard let url else { continue }
                try? FileManager.default.removeItem(at: url)
            }

            assetWriter = nil
            secondaryAudioWriter?.cancelWriting()
            secondaryAudioWriter = nil
            videoInput = nil
            pixelBufferAdaptor = nil
            audioInput = nil
            microphoneInput = nil
            secondaryAudioInput = nil
            outputURL = nil
            workingOutputURL = nil
            secondaryOutputURL = nil
            postProcessingMode = .none

            logger.info("AssetWriter cancelled")
        }
    }

    // MARK: - Settings Helpers

    private func determinePostProcessingMode(
        captureVideo: Bool,
        captureSystemAudio: Bool,
        captureMicrophone: Bool,
        separateAudioTracks: Bool
    ) -> PostProcessingMode {
        if !captureVideo, captureSystemAudio, captureMicrophone, !separateAudioTracks {
            return .mixedAudio
        }

        return .none
    }

    @MainActor
    static func plannedOutputURLs(for url: URL, settings: SettingsStore) -> (primary: URL, secondary: URL?) {
        let baseURL = url.deletingPathExtension()
        let primaryBaseURL = if !settings.recordVideo && settings.usesSeparateAudioTracks {
            baseURL
                .deletingLastPathComponent()
                .appending(path: "\(baseURL.lastPathComponent)_system")
        } else {
            baseURL
        }

        let primaryURL = primaryBaseURL.appendingPathExtension(settings.recordingOutputFileExtension)
        let secondaryURL: URL? = if !settings.recordVideo && settings.usesSeparateAudioTracks {
            primaryBaseURL
                .deletingLastPathComponent()
                .appending(path: "\(baseURL.lastPathComponent)_microphone")
                .appendingPathExtension(settings.recordingOutputFileExtension)
        } else {
            nil
        }

        return (primaryURL, secondaryURL)
    }

    private func workingCaptureURL(for finalURL: URL, needsPostProcessing: Bool) -> URL {
        guard needsPostProcessing else {
            return finalURL
        }

        return finalURL
            .deletingPathExtension()
            .appendingPathExtension("capture.mov")
    }

    private func exportMixedOutput(from captureURL: URL, to finalURL: URL) async throws {
        let asset = AVURLAsset(url: captureURL)

        if captureVideo {
            try await exportMixedMovie(from: asset, to: finalURL)
        } else {
            try await exportMixedAudioFile(from: asset, to: finalURL)
        }
    }

    private func exportMixedMovie(from asset: AVURLAsset, to finalURL: URL) async throws {
        let composition = AVMutableComposition()
        let audioMix = AVMutableAudioMix()
        var inputParameters: [AVMutableAudioMixInputParameters] = []

        if let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
           let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
            compositionVideoTrack.preferredTransform = try await videoTrack.load(.preferredTransform)
        }

        let assetAudioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        for audioTrack in assetAudioTracks {
            guard let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                continue
            }

            try compositionAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: audioTrack,
                at: .zero
            )

            let parameters = AVMutableAudioMixInputParameters(track: compositionAudioTrack)
            parameters.setVolume(1, at: .zero)
            inputParameters.append(parameters)
        }

        audioMix.inputParameters = inputParameters

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw AssetWriterError.writingFailed(nil)
        }

        exportSession.audioMix = audioMix
        try await exportSession.export(to: finalURL, as: finalURL.pathExtension == "mp4" ? .mp4 : .mov)
    }

    private func exportMixedAudioFile(from asset: AVURLAsset, to finalURL: URL) async throws {
        let composition = AVMutableComposition()
        let assetAudioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)

        var compositionAudioTracks: [AVCompositionTrack] = []
        for audioTrack in assetAudioTracks {
            guard let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                continue
            }

            try compositionAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: audioTrack,
                at: .zero
            )
            compositionAudioTracks.append(compositionAudioTrack)
        }

        guard !compositionAudioTracks.isEmpty else {
            throw AssetWriterError.noFramesWritten
        }

        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: compositionAudioTracks,
            audioSettings: linearPCMReaderSettings
        )
        guard reader.canAdd(output) else {
            throw AssetWriterError.writingFailed(nil)
        }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: finalURL, fileType: finalURL.pathExtension == "caf" ? .caf : .m4a)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: createAudioSettings(for: finalURL.pathExtension == "caf" ? .pcm : .aac))
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw AssetWriterError.writingFailed(nil)
        }
        writer.add(writerInput)

        try await transcodeAudio(reader: reader, output: output, writer: writer, writerInput: writerInput)
    }

    private func transcodeAudio(
        reader: AVAssetReader,
        output: AVAssetReaderOutput,
        writer: AVAssetWriter,
        writerInput: AVAssetWriterInput
    ) async throws {
        guard writer.startWriting() else {
            throw AssetWriterError.failedToStartWriting(writer.error)
        }

        guard reader.startReading() else {
            throw AssetWriterError.writingFailed(reader.error)
        }

        writer.startSession(atSourceTime: .zero)

        while reader.status == .reading {
            if writerInput.isReadyForMoreMediaData {
                if let sampleBuffer = output.copyNextSampleBuffer() {
                    if !writerInput.append(sampleBuffer) {
                        reader.cancelReading()
                        writer.cancelWriting()
                        throw AssetWriterError.writingFailed(writer.error)
                    }
                } else {
                    break
                }
            } else {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        if reader.status == .failed {
            throw AssetWriterError.writingFailed(reader.error)
        }

        writerInput.markAsFinished()
        await writer.finishWriting()

        if writer.status == .failed {
            throw AssetWriterError.writingFailed(writer.error)
        }
    }

    private var linearPCMReaderSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    @MainActor
    private func createVideoSettings(from settings: SettingsStore, size: CGSize) -> [String: Any] {
        var videoSettings: [String: Any] = [
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]

        let hdrPreset = settings.hdrPreset

        switch settings.videoCodec {
        case .h264:
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.h264

        case .hevc:
            if settings.captureAlphaChannel {
                videoSettings[AVVideoCodecKey] = AVVideoCodecType.hevcWithAlpha
            } else {
                videoSettings[AVVideoCodecKey] = AVVideoCodecType.hevc
            }

        case .proRes422:
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.proRes422

        case .proRes4444:
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        }

        // Add compression properties for H.264 and HEVC to control bitrate.
        // ProRes codecs use fixed-quality encoding and don't need these.
        if let bpp = settings.videoQuality.bitsPerPixel(for: settings.videoCodec) {
            let frameRate = settings.frameRate.effectiveFrameRate
            let bitrate = Int(size.width * size.height * bpp * frameRate)

            var compressionProperties: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: Int(frameRate * 2)
            ]

            // HEVC HDR: enforce Main 10 profile to prevent 8-bit fallback and
            // enable automatic HDR metadata insertion (HDR10 / Dolby Vision).
            if settings.videoCodec == .hevc && hdrPreset != .sdr {
                compressionProperties[AVVideoProfileLevelKey] =
                    kVTProfileLevel_HEVC_Main10_AutoLevel as String
                compressionProperties[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] =
                    kVTHDRMetadataInsertionMode_Auto as String
            }

            videoSettings[AVVideoCompressionPropertiesKey] = compressionProperties

            logger.info(
                "Video compression: \(bitrate / 1_000_000) Mbps at \(Int(frameRate)) fps (\(settings.videoQuality.rawValue) quality)"
            )
        }

        // Color space tagging strategy differs by codec:
        //
        // HEVC HDR: Tag via AVVideoColorPropertiesKey with BT.2020 / PQ.
        //   The encoder writes the correct 'colr' atom and VUI parameters.
        //
        // ProRes HDR: Do NOT set AVVideoColorPropertiesKey. AVAssetWriter
        //   prohibits automatic color matching for the high-bit-depth pixel
        //   formats ProRes uses. Instead, BT.2020 / PQ colorimetry is
        //   injected per-frame via CVBufferSetAttachment in appendVideoSample().
        //
        // SDR (all codecs): Tag with Rec. 709 to ensure 'colr' atoms and
        //   VUI parameters are written.
        let isProRes = settings.videoCodec == .proRes422 || settings.videoCodec == .proRes4444

        if isProRes && hdrPreset != .sdr {
            // Color properties are tagged per-frame via CVBufferSetAttachment.
        } else if hdrPreset != .sdr {
            videoSettings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        } else {
            videoSettings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        }

        return videoSettings
    }

    /// Logs the pixel format, color space, and matrix of an incoming pixel buffer
    /// to help diagnose HDR color mismatches.
    private func logPixelBufferProperties(_ pixelBuffer: CVPixelBuffer) {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let fourCC = String(format: "%c%c%c%c",
                            (pixelFormat >> 24) & 0xFF,
                            (pixelFormat >> 16) & 0xFF,
                            (pixelFormat >> 8) & 0xFF,
                            pixelFormat & 0xFF)

        let primaries = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, nil)
            as? String ?? "none"
        let transfer = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil)
            as? String ?? "none"
        let matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)
            as? String ?? "none"

        let colorSpaceName: String
        if let cgColorSpace = CVImageBufferGetColorSpace(pixelBuffer)?.takeUnretainedValue() {
            colorSpaceName = cgColorSpace.name as String? ?? "unnamed"
        } else {
            colorSpaceName = "nil"
        }

        logger.info(
            """
            First frame buffer properties — \
            pixelFormat: \(fourCC) (0x\(String(pixelFormat, radix: 16))), \
            colorPrimaries: \(primaries), \
            transferFunction: \(transfer), \
            yCbCrMatrix: \(matrix), \
            CGColorSpace: \(colorSpaceName)
            """
        )
    }

    private func createAudioSettings(for audioCodec: AudioCodec) -> [String: Any] {
        switch audioCodec {
        case .aac:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256000
            ]

        case .pcm:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        }
    }
}

// MARK: - CaptureEngineSampleBufferDelegate

extension AssetWriter {

    func captureEngine(
        _ engine: CaptureEngine, didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer
    ) {
        appendVideoSample(sampleBuffer)
    }

    func captureEngine(
        _ engine: CaptureEngine, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer
    ) {
        appendAudioSample(sampleBuffer)
    }

    func captureEngine(
        _ engine: CaptureEngine, didOutputMicrophoneSampleBuffer sampleBuffer: CMSampleBuffer
    ) {
        appendMicrophoneSample(sampleBuffer)
    }
}

// MARK: - Errors

enum AssetWriterError: LocalizedError {
    case failedToCreateWriter
    case writerNotReady
    case failedToStartWriting(Error?)
    case writingFailed(Error?)
    case noOutputURL
    case noFramesWritten

    var errorDescription: String? {
        switch self {
        case .failedToCreateWriter:
            return "Failed to create the asset writer."
        case .writerNotReady:
            return "The asset writer is not ready for writing."
        case .failedToStartWriting(let error):
            return "Failed to start writing: \(error?.localizedDescription ?? "Unknown error")"
        case .writingFailed(let error):
            return "Writing failed: \(error?.localizedDescription ?? "Unknown error")"
        case .noOutputURL:
            return "No output URL was configured."
        case .noFramesWritten:
            return "No media samples were captured. Check your recording permissions and source settings."
        }
    }
}
