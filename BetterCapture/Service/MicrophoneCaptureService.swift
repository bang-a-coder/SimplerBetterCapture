//
//  MicrophoneCaptureService.swift
//  BetterCapture
//
//  Created by Joshua Sattler on 06.04.26.
//

import AVFoundation
import OSLog

/// Captures microphone audio without requiring ScreenCaptureKit content sharing.
@MainActor
final class MicrophoneCaptureService: NSObject {

    nonisolated(unsafe) private weak var sampleBufferDelegate: AssetWriter?

    private var session: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "com.bettercapture.microphoneSession")
    private let outputQueue = DispatchQueue(label: "com.bettercapture.microphoneOutput")

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture",
        category: "MicrophoneCaptureService"
    )

    func start(deviceID: String?, sampleBufferDelegate: AssetWriter) async throws {
        guard session == nil else { return }

        let device: AVCaptureDevice? = if let deviceID {
            AVCaptureDevice(uniqueID: deviceID)
        } else {
            AVCaptureDevice.default(for: .audio)
        }

        guard let device else {
            throw CaptureError.noCaptureSourceSelected
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
        output.setSampleBufferDelegate(self, queue: outputQueue)
        session = newSession

        nonisolated(unsafe) let runnable = newSession
        let isRunning = await withCheckedContinuation { continuation in
            sessionQueue.async {
                runnable.startRunning()
                continuation.resume(returning: runnable.isRunning)
            }
        }

        logger.info("Microphone capture session started (running: \(isRunning))")
    }

    func stop() {
        guard let current = session else { return }
        session = nil
        sampleBufferDelegate = nil

        nonisolated(unsafe) let stoppable = current
        sessionQueue.async {
            stoppable.stopRunning()
        }

        logger.info("Microphone capture session stopped")
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
