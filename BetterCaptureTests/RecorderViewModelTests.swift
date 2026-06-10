//
//  RecorderViewModelTests.swift
//  BetterCaptureTests
//
//  Created by Joshua Sattler on 28.03.26.
//

import Testing
@testable import BetterCapture

/// Tests for RecorderViewModel's pure derived state and formatting.
///
/// These test the computed properties and initial state without
/// triggering any ScreenCaptureKit or system interactions.
@MainActor
struct RecorderViewModelTests {

    // MARK: - formattedDuration

    @Test func formattedDurationAtZero() {
        let viewModel = RecorderViewModel()
        #expect(viewModel.formattedDuration == "00:00")
    }

    // MARK: - Initial State

    @Test func initialStateIsIdle() {
        let viewModel = RecorderViewModel()
        #expect(viewModel.isRecording == false)
    }

    @Test func cannotStartVideoRecordingWithoutContentFilter() {
        let viewModel = RecorderViewModel()
        viewModel.settings.recordVideo = true
        viewModel.settings.recordAudio = false
        #expect(viewModel.canStartRecording == false)
    }

    @Test func canStartMicrophoneOnlyAudioWithoutContentFilter() {
        let viewModel = RecorderViewModel()
        viewModel.settings.recordVideo = false
        viewModel.settings.recordAudio = true
        viewModel.settings.captureMicrophone = true
        #expect(viewModel.canStartRecording == true)
    }

    @Test func canStartSharedAudioWithoutManualSelection() {
        let viewModel = RecorderViewModel()
        viewModel.settings.recordVideo = false
        viewModel.settings.recordAudio = true
        viewModel.settings.captureSystemAudio = true
        #expect(viewModel.canStartRecording == true)
    }

    @Test func microphoneOnlyModeDoesNotShowCaptureContextSection() {
        let viewModel = RecorderViewModel()
        viewModel.settings.recordVideo = false
        viewModel.settings.recordAudio = true
        viewModel.settings.captureSystemAudio = false
        viewModel.settings.captureMicrophone = true

        #expect(viewModel.showsCaptureContextSection == false)
    }

    @Test func audioStatusItemsShowBeforeRecording() {
        let viewModel = RecorderViewModel()
        viewModel.settings.recordVideo = false
        viewModel.settings.recordAudio = true
        viewModel.settings.captureSystemAudio = true
        viewModel.settings.captureMicrophone = true

        #expect(viewModel.audioStatusItems.map(\.source) == [.system, .microphone])
    }

    @Test func hasNoContentSelectedByDefault() {
        let viewModel = RecorderViewModel()
        #expect(viewModel.hasContentSelected == false)
    }

    @Test func isNotAreaSelectionByDefault() {
        let viewModel = RecorderViewModel()
        #expect(viewModel.isAreaSelection == false)
    }

    @Test func presenterOverlayInactiveByDefault() {
        let viewModel = RecorderViewModel()
        #expect(viewModel.isPresenterOverlayActive == false)
    }

    @Test func lastErrorIsNilByDefault() {
        let viewModel = RecorderViewModel()
        #expect(viewModel.lastError == nil)
    }

    @Test func recordingDurationIsZeroByDefault() {
        let viewModel = RecorderViewModel()
        #expect(viewModel.recordingDuration == 0)
    }
}
