//
//  PermissionService.swift
//  BetterCapture
//
//  Created by Joshua Sattler on 07.02.26.
//

import Foundation
import ScreenCaptureKit
import AVFoundation
import OSLog
import CoreGraphics
import AppKit

/// Service responsible for checking and requesting system permissions
@MainActor
@Observable
final class PermissionService {
    private let screenRecordingAccessChecker: () -> Bool
    private let screenRecordingRequester: () -> Bool
    private let microphoneAuthorizationStatusProvider: () -> AVAuthorizationStatus
    private let microphoneAccessRequester: () async -> Bool
    private var hasRequestedScreenRecordingPermissionThisSession = false

    // MARK: - Permission States

    enum PermissionState {
        case unknown
        case granted
        case denied
    }

    struct BannerRowContent: Equatable {
        let title: String
        let message: String
        let actionTitle: String
    }

    private(set) var screenRecordingState: PermissionState = .unknown
    private(set) var microphoneState: PermissionState = .unknown

    var allPermissionsGranted: Bool {
        screenRecordingState == .granted && microphoneState == .granted
    }

    var hasAnyPermissionDenied: Bool {
        screenRecordingState == .denied || microphoneState == .denied
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture",
        category: "PermissionService"
    )

    // MARK: - Initialization

    init(
        screenRecordingAccessChecker: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        screenRecordingRequester: @escaping () -> Bool = { CGRequestScreenCaptureAccess() },
        microphoneAuthorizationStatusProvider: @escaping () -> AVAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: .audio)
        },
        microphoneAccessRequester: @escaping () async -> Bool = {
            await AVCaptureDevice.requestAccess(for: .audio)
        }
    ) {
        self.screenRecordingAccessChecker = screenRecordingAccessChecker
        self.screenRecordingRequester = screenRecordingRequester
        self.microphoneAuthorizationStatusProvider = microphoneAuthorizationStatusProvider
        self.microphoneAccessRequester = microphoneAccessRequester
        updatePermissionStates()
    }

    // MARK: - Permission Checking

    /// Updates all permission states
    func updatePermissionStates() {
        screenRecordingState = checkScreenRecordingPermission()
        microphoneState = checkMicrophonePermission()

        if screenRecordingState == .granted {
            hasRequestedScreenRecordingPermissionThisSession = false
        }

        logger.info("Permission states - Screen: \(String(describing: self.screenRecordingState)), Microphone: \(String(describing: self.microphoneState))")
    }

    private func checkScreenRecordingPermission() -> PermissionState {
        if screenRecordingAccessChecker() {
            return .granted
        }

        return hasRequestedScreenRecordingPermissionThisSession ? .denied : .unknown
    }

    private func checkMicrophonePermission() -> PermissionState {
        switch microphoneAuthorizationStatusProvider() {
        case .authorized:
            return .granted
        case .notDetermined:
            return .unknown
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .unknown
        }
    }

    func screenRecordingBannerContent() -> BannerRowContent? {
        Self.screenRecordingBannerContent(for: screenRecordingState)
    }

    func microphoneBannerContent() -> BannerRowContent? {
        Self.microphoneBannerContent(for: microphoneState)
    }

    static func screenRecordingBannerContent(for state: PermissionState) -> BannerRowContent? {
        switch state {
        case .granted:
            return nil
        case .unknown:
            return BannerRowContent(
                title: "Screen Recording",
                message: "Allow BetterCapture to record your screen in System Settings.",
                actionTitle: "Open Settings"
            )
        case .denied:
            return BannerRowContent(
                title: "Screen Recording",
                message: "Screen recording is still unavailable. If you just enabled this in System Settings, quit and reopen BetterCapture.",
                actionTitle: "Open Settings"
            )
        }
    }

    static func microphoneBannerContent(for state: PermissionState) -> BannerRowContent? {
        switch state {
        case .granted:
            return nil
        case .unknown:
            return BannerRowContent(
                title: "Microphone",
                message: "Allow BetterCapture to access your microphone in System Settings.",
                actionTitle: "Open Settings"
            )
        case .denied:
            return BannerRowContent(
                title: "Microphone",
                message: "Microphone access is still unavailable. Review the setting in System Settings.",
                actionTitle: "Open Settings"
            )
        }
    }

    // MARK: - Permission Requests

    /// Requests required permissions on app launch.
    /// - Parameters:
    ///   - includeScreenRecording: Whether to also request screen recording permission
    ///   - includeMicrophone: Whether to also request microphone permission
    func requestPermissions(includeScreenRecording: Bool, includeMicrophone: Bool) async {
        logger.info(
            "Requesting permissions (includeScreenRecording: \(includeScreenRecording), includeMicrophone: \(includeMicrophone))..."
        )

        if includeScreenRecording {
            requestScreenRecordingPermission()
        }

        // Request microphone permission only if needed (asynchronous)
        if includeMicrophone {
            await requestMicrophonePermission()
        }

        // Update states after requests
        updatePermissionStates()
    }

    /// Requests screen recording permission
    /// - Note: This will open System Settings if permission was previously denied
    func requestScreenRecordingPermission() {
        hasRequestedScreenRecordingPermissionThisSession = true
        let wasGranted = screenRecordingRequester()
        screenRecordingState = wasGranted ? .granted : .denied
        logger.info("Screen recording permission request result: \(wasGranted)")
    }

    /// Requests microphone permission
    func requestMicrophonePermission() async {
        let status = microphoneAuthorizationStatusProvider()

        switch status {
        case .authorized:
            microphoneState = .granted
        case .notDetermined:
            let granted = await microphoneAccessRequester()
            microphoneState = granted ? .granted : .denied
            logger.info("Microphone permission request result: \(granted)")
        case .denied, .restricted:
            microphoneState = .denied
        @unknown default:
            microphoneState = .unknown
        }
    }

    /// Opens System Settings to the Screen Recording preferences pane
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens System Settings to the Microphone preferences pane
    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
