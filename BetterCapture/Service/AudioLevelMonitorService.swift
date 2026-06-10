//
//  AudioLevelMonitorService.swift
//  BetterCapture
//
//  Created by Joshua Sattler on 10.06.26.
//

import AVFoundation
import OSLog
import ScreenCaptureKit
import os

nonisolated final class AudioLevelMonitorService: NSObject, @unchecked Sendable {
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

    private var _audioActivityHandler: RecordingAudioActivityHandler?
    private var stream: SCStream?
    private var microphoneSession: AVCaptureSession?
    private let systemAudioQueue = DispatchQueue(label: "com.bettercapture.audioLevelMonitor.system")
    private let microphoneQueue = DispatchQueue(label: "com.bettercapture.audioLevelMonitor.microphone")
    private let audioActivityHandlerLock = OSAllocatedUnfairLock()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture",
        category: "AudioLevelMonitorService"
    )

    @MainActor
    func startSharedMonitoring(
        filter: SCContentFilter,
        contentSize: CGSize,
        sourceRect: CGRect?,
        captureSystemAudio: Bool,
        captureMicrophone: Bool,
        microphoneDeviceID: String?
    ) async throws {
        try await stop()

        let configuration = SCStreamConfiguration()
        configuration.width = max(Int(contentSize.width.rounded(.up)), 1)
        configuration.height = max(Int(contentSize.height.rounded(.up)), 1)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.capturesAudio = captureSystemAudio
        configuration.captureMicrophone = captureMicrophone
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        if let sourceRect {
            configuration.sourceRect = sourceRect
        }

        if let microphoneDeviceID {
            configuration.microphoneCaptureDeviceID = microphoneDeviceID
        }

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)

        if captureSystemAudio {
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemAudioQueue)
        }

        if captureMicrophone {
            try newStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)
        }

        stream = newStream
        try await newStream.startCapture()
        logger.info("Started shared audio level monitoring")
    }

    func startMicrophoneMonitoring(deviceID: String?) async throws {
        try await stop()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            microphoneQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CaptureError.failedToCreateStream)
                    return
                }

                do {
                    let device: AVCaptureDevice? = if let deviceID {
                        AVCaptureDevice(uniqueID: deviceID)
                    } else {
                        AVCaptureDevice.default(for: .audio)
                    }

                    guard let device else {
                        throw CaptureError.failedToCreateStream
                    }

                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    let session = AVCaptureSession()

                    session.beginConfiguration()

                    guard session.canAddInput(input) else {
                        throw CaptureError.failedToCreateStream
                    }
                    session.addInput(input)

                    guard session.canAddOutput(output) else {
                        throw CaptureError.failedToCreateStream
                    }
                    session.addOutput(output)

                    session.commitConfiguration()
                    output.setSampleBufferDelegate(self, queue: self.microphoneQueue)
                    self.microphoneSession = session
                    session.startRunning()

                    self.logger.info("Started microphone audio level monitoring")
                    continuation.resume(returning: ())
                } catch {
                    self.microphoneSession = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async throws {
        if let stream {
            self.stream = nil
            try await stream.stopCapture()
        }

        let session = microphoneSession
        microphoneSession = nil

        guard let session else {
            return
        }

        nonisolated(unsafe) let stoppable = session
        await withCheckedContinuation { continuation in
            microphoneQueue.async {
                stoppable.stopRunning()
                continuation.resume()
            }
        }
    }
}

nonisolated extension AudioLevelMonitorService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        logger.error("Audio level monitoring stopped: \(error.localizedDescription)")
    }
}

nonisolated extension AudioLevelMonitorService: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch type {
        case .audio:
            audioActivityHandler?(.system, AudioLevelMeter.level(for: sampleBuffer))
        case .microphone:
            audioActivityHandler?(.microphone, AudioLevelMeter.level(for: sampleBuffer))
        case .screen:
            break
        @unknown default:
            break
        }
    }
}

nonisolated extension AudioLevelMonitorService: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        audioActivityHandler?(.microphone, AudioLevelMeter.level(for: sampleBuffer))
    }
}
