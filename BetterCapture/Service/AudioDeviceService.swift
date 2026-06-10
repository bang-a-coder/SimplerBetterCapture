//
//  AudioDeviceService.swift
//  BetterCapture
//
//  Created by Joshua Sattler on 02.02.26.
//

import AVFoundation
import OSLog

/// Represents an audio input device
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isDefault: Bool
}

/// Service for enumerating and monitoring available microphone devices
@MainActor
@Observable
final class AudioDeviceService {

    // MARK: - Properties

    private(set) var availableDevices: [AudioInputDevice] = []
    private let audioDeviceProvider: () -> [AVCaptureDevice]
    private let defaultAudioDeviceProvider: () -> AVCaptureDevice?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture",
        category: "AudioDeviceService"
    )

    // MARK: - Initialization

    init(
        audioDeviceProvider: @escaping () -> [AVCaptureDevice] = {
            AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone],
                mediaType: .audio,
                position: .unspecified
            ).devices
        },
        defaultAudioDeviceProvider: @escaping () -> AVCaptureDevice? = {
            AVCaptureDevice.default(for: .audio)
        },
        observesDeviceChanges: Bool = true
    ) {
        self.audioDeviceProvider = audioDeviceProvider
        self.defaultAudioDeviceProvider = defaultAudioDeviceProvider
        refreshDevices()
        if observesDeviceChanges {
            setupNotifications()
        }
    }

    // MARK: - Public Methods

    /// Refreshes the list of available audio input devices
    func refreshDevices() {
        let defaultID = defaultAudioDeviceProvider()?.uniqueID

        availableDevices = audioDeviceProvider().map { device in
            AudioInputDevice(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: device.uniqueID == defaultID
            )
        }

        logger.info("Found \(self.availableDevices.count) audio input devices")
    }

    var defaultMicrophoneName: String? {
        defaultAudioDeviceProvider()?.localizedName
    }

    func resolvedMicrophoneID(for selectedID: String?) -> String? {
        Self.resolvedMicrophoneID(selectedID: selectedID, devices: availableDevices)
    }

    func microphoneDisplayName(for selectedID: String?) -> String {
        Self.microphoneDisplayName(
            selectedID: selectedID,
            devices: availableDevices,
            defaultMicrophoneName: defaultMicrophoneName
        )
    }

    func clearUnavailableSelection(in settings: SettingsStore) {
        guard settings.selectedMicrophoneID != nil else { return }

        if resolvedMicrophoneID(for: settings.selectedMicrophoneID) == nil {
            settings.selectedMicrophoneID = nil
        }
    }

    nonisolated static func resolvedMicrophoneID(selectedID: String?, devices: [AudioInputDevice]) -> String? {
        guard let selectedID else {
            return nil
        }

        return devices.contains { $0.id == selectedID } ? selectedID : nil
    }

    nonisolated static func microphoneDisplayName(
        selectedID: String?,
        devices: [AudioInputDevice],
        defaultMicrophoneName: String?
    ) -> String {
        if let selectedID, let device = devices.first(where: { $0.id == selectedID }) {
            return device.name
        }

        if let defaultMicrophoneName, !defaultMicrophoneName.isEmpty {
            return "Default (\(defaultMicrophoneName))"
        }

        return "System Default"
    }

    // MARK: - Private Methods

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDevices()
                self?.logger.info("Audio device connected")
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDevices()
                self?.logger.info("Audio device disconnected")
            }
        }
    }
}
