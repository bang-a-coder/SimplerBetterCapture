//
//  AssetWriterTests.swift
//  BetterCaptureTests
//

import Foundation
import Testing
@testable import BetterCapture

@MainActor
struct AssetWriterTests {

    @Test func audioOnlySeparateOutputsUseSystemAndMicrophoneSuffixes() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: #function)!)
        settings.recordVideo = false
        settings.recordAudio = true
        settings.captureSystemAudio = true
        settings.captureMicrophone = true
        settings.recordSeparateAudioTracks = true

        let outputURL = URL(filePath: "/tmp/Example Recording.mov")
        let plannedOutputURLs = AssetWriter.plannedOutputURLs(for: outputURL, settings: settings)

        #expect(plannedOutputURLs.primary.lastPathComponent == "Example Recording_system.m4a")
        #expect(plannedOutputURLs.secondary?.lastPathComponent == "Example Recording_microphone.m4a")
    }

    @Test func audioOnlyMixedOutputUsesSingleAudioFile() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: #function)!)
        settings.recordVideo = false
        settings.recordAudio = true
        settings.captureSystemAudio = true
        settings.captureMicrophone = true
        settings.recordSeparateAudioTracks = false
        settings.audioCodec = .pcm

        let outputURL = URL(filePath: "/tmp/Example Recording.mov")
        let plannedOutputURLs = AssetWriter.plannedOutputURLs(for: outputURL, settings: settings)

        #expect(plannedOutputURLs.primary.lastPathComponent == "Example Recording.caf")
        #expect(plannedOutputURLs.secondary == nil)
    }
}
