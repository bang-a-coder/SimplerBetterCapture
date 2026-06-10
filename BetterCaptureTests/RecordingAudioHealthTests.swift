//
//  RecordingAudioHealthTests.swift
//  BetterCaptureTests
//
//  Created by Joshua Sattler on 10.06.26.
//

import Foundation
import Testing
@testable import BetterCapture

struct RecordingAudioHealthTests {

    @Test func sourceHealthStartsWaitingBeforeGracePeriod() {
        let start = Date(timeIntervalSince1970: 0)
        let health = RecordingAudioHealth(startedAt: start)

        #expect(health.state(for: .microphone, at: start.addingTimeInterval(1)) == .waiting)
    }

    @Test func sourceHealthBecomesSilentWithoutSamples() {
        let start = Date(timeIntervalSince1970: 0)
        let health = RecordingAudioHealth(startedAt: start)

        #expect(health.state(for: .system, at: start.addingTimeInterval(3)) == .silent)
    }

    @Test func sourceHealthMarksRecentAudibleSamplesLive() {
        let start = Date(timeIntervalSince1970: 0)
        var health = RecordingAudioHealth(startedAt: start)

        health.recordSample(source: .microphone, level: 0.2, at: start.addingTimeInterval(0.5))

        #expect(health.state(for: .microphone, at: start.addingTimeInterval(1)) == .live)
    }

    @Test func sourceHealthMarksQuietSamplesSilent() {
        let start = Date(timeIntervalSince1970: 0)
        var health = RecordingAudioHealth(startedAt: start)

        health.recordSample(source: .system, level: 0.001, at: start.addingTimeInterval(0.5))

        #expect(health.state(for: .system, at: start.addingTimeInterval(1)) == .silent)
    }

    @Test func missingEnabledSourceProducesWarning() {
        let summary = RecordingAudioWriteSummary(
            didWriteSystemAudio: true,
            didWriteMicrophoneAudio: false,
            maxSystemAudioLevel: 0.2,
            maxMicrophoneAudioLevel: 0
        )

        let warnings = summary.warningMessages(
            expectsSystemAudio: true,
            expectsMicrophoneAudio: true,
            microphoneDisplayName: "Default (MacBook Pro Microphone)"
        )

        #expect(warnings == ["No microphone audio was detected from Default (MacBook Pro Microphone)."])
    }
}
