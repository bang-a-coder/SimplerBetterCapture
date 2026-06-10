//
//  AudioDeviceServiceTests.swift
//  BetterCaptureTests
//
//  Created by Joshua Sattler on 10.06.26.
//

import Foundation
import Testing
@testable import BetterCapture

struct AudioDeviceServiceTests {

    @Test func staleMicrophoneIDResolvesToDefault() {
        let devices = [
            AudioInputDevice(id: "built-in", name: "MacBook Pro Microphone", isDefault: true)
        ]

        #expect(AudioDeviceService.resolvedMicrophoneID(selectedID: "missing", devices: devices) == nil)
    }

    @Test func validMicrophoneIDIsPreserved() {
        let devices = [
            AudioInputDevice(id: "built-in", name: "MacBook Pro Microphone", isDefault: true)
        ]

        #expect(AudioDeviceService.resolvedMicrophoneID(selectedID: "built-in", devices: devices) == "built-in")
    }

    @Test func defaultMicrophoneLabelIncludesResolvedDeviceName() {
        let devices = [
            AudioInputDevice(id: "built-in", name: "MacBook Pro Microphone", isDefault: true)
        ]

        #expect(
            AudioDeviceService.microphoneDisplayName(
                selectedID: nil,
                devices: devices,
                defaultMicrophoneName: "MacBook Pro Microphone"
            ) == "Default (MacBook Pro Microphone)"
        )
    }

    @MainActor
    @Test func emptyDeviceListClearsStaleSelection() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: #function)!)
        settings.selectedMicrophoneID = "missing"
        let service = AudioDeviceService(
            audioDeviceProvider: { [] },
            defaultAudioDeviceProvider: { nil },
            observesDeviceChanges: false
        )

        service.clearUnavailableSelection(in: settings)

        #expect(settings.selectedMicrophoneID == nil)
    }
}
