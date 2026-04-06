//
//  MicrophoneCaptureService.swift
//  BetterCapture
//
//  Created by Joshua Sattler on 06.04.26.
//

import AVFoundation
import OSLog

/// Captures microphone audio without requiring ScreenCaptureKit content sharing.
final class MicrophoneCaptureService: NSObject, @unchecked Sendable {

    private weak var sampleBufferDelegate: AssetWriter?

    private var session: AVCaptureSession?
    private let captureQueue = DispatchQueue(label: "com.bettercapture.microphoneCapture")
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture",
        category: "MicrophoneCaptureService"
    )

    func start(deviceID: String?, sampleBufferDelegate: AssetWriter) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CaptureError.failedToCreateStream)
                    return
                }

                guard self.session == nil else {
                    continuation.resume(returning: ())
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
                    let newSession = AVCaptureSession()

                    newSession.beginConfiguration()

                    guard newSession.canAddInput(input) else {
                        throw CaptureError.failedToCreateStream
                    }
                    newSession.addInput(input)

                    guard newSession.canAddOutput(output) else {
                        throw CaptureError.failedToCreateStream
                    }
                    newSession.addOutput(output)

                    newSession.commitConfiguration()

                    self.sampleBufferDelegate = sampleBufferDelegate
                    output.setSampleBufferDelegate(self, queue: self.captureQueue)
                    self.session = newSession
                    newSession.startRunning()

                    self.logger.info("Microphone capture session started (running: \(newSession.isRunning))")
                    continuation.resume(returning: ())
                } catch {
                    self.sampleBufferDelegate = nil
                    self.session = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        captureQueue.async { [weak self] in
            guard let self, let current = self.session else { return }
            self.session = nil
            self.sampleBufferDelegate = nil
            current.stopRunning()
            self.logger.info("Microphone capture session stopped")
        }
    }
}

extension MicrophoneCaptureService: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        sampleBufferDelegate?.appendMicrophoneSample(sampleBuffer)
    }
}
