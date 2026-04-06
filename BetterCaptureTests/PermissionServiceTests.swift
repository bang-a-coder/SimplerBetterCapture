//
//  PermissionServiceTests.swift
//  BetterCaptureTests
//

import Foundation
import AVFoundation
import Testing
@testable import BetterCapture

@MainActor
struct PermissionServiceTests {

    @Test func freshServiceReportsScreenRecordingUnknownWhenPreflightIsFalse() {
        let service = PermissionService(
            screenRecordingAccessChecker: { false },
            screenRecordingRequester: { false },
            microphoneAuthorizationStatusProvider: { .authorized },
            microphoneAccessRequester: { false }
        )

        #expect(service.screenRecordingState == .unknown)
    }

    @Test func requestingScreenRecordingTurnsFalsePreflightIntoDenied() {
        let service = PermissionService(
            screenRecordingAccessChecker: { false },
            screenRecordingRequester: { false },
            microphoneAuthorizationStatusProvider: { .authorized },
            microphoneAccessRequester: { false }
        )

        service.requestScreenRecordingPermission()
        service.updatePermissionStates()

        #expect(service.screenRecordingState == .denied)
    }

    @Test func screenRecordingUnknownShowsSettingsPrompt() {
        let content = PermissionService.screenRecordingBannerContent(for: .unknown)

        #expect(content?.title == "Screen Recording")
        #expect(content?.message == "Allow BetterCapture to record your screen in System Settings.")
        #expect(content?.actionTitle == "Open Settings")
    }

    @Test func screenRecordingDeniedMentionsRelaunch() {
        let content = PermissionService.screenRecordingBannerContent(for: .denied)

        #expect(content?.message.localizedStandardContains("quit and reopen BetterCapture") == true)
    }

    @Test func microphoneUnknownShowsSettingsPrompt() {
        let content = PermissionService.microphoneBannerContent(for: .unknown)

        #expect(content?.title == "Microphone")
        #expect(content?.message == "Allow BetterCapture to access your microphone in System Settings.")
        #expect(content?.actionTitle == "Open Settings")
    }

    @Test func grantedPermissionsHaveNoBannerContent() {
        #expect(PermissionService.screenRecordingBannerContent(for: .granted) == nil)
        #expect(PermissionService.microphoneBannerContent(for: .granted) == nil)
    }
}
