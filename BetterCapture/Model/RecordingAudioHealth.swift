//
//  RecordingAudioHealth.swift
//  BetterCapture
//
//  Created by Joshua Sattler on 10.06.26.
//

import Foundation

nonisolated enum RecordingAudioSource: Hashable, Sendable {
    case system
    case microphone
}

nonisolated enum RecordingAudioSourceState: Equatable, Sendable {
    case waiting
    case silent
    case live
}

nonisolated struct RecordingAudioSourceMeter: Equatable, Sendable {
    static let silenceThreshold: Float = 0.01
    static let startupGraceDuration: TimeInterval = 2
    static let liveHoldDuration: TimeInterval = 1.5

    private(set) var didReceiveSample = false
    private(set) var level: Float = 0
    private(set) var peakLevel: Float = 0
    private(set) var lastSampleAt: Date?

    mutating func recordSample(level newLevel: Float, at date: Date = .now) {
        let normalizedLevel = min(max(newLevel.isFinite ? newLevel : 0, 0), 1)
        didReceiveSample = true
        level = normalizedLevel
        peakLevel = max(peakLevel, normalizedLevel)
        lastSampleAt = date
    }

    func state(startedAt: Date?, at date: Date = .now) -> RecordingAudioSourceState {
        guard didReceiveSample else {
            guard let startedAt, date.timeIntervalSince(startedAt) >= Self.startupGraceDuration else {
                return .waiting
            }
            return .silent
        }

        guard let lastSampleAt, date.timeIntervalSince(lastSampleAt) <= Self.liveHoldDuration else {
            return .silent
        }

        return level >= Self.silenceThreshold ? .live : .silent
    }

}

nonisolated struct RecordingAudioHealth: Equatable, Sendable {
    private(set) var startedAt: Date?
    private var systemMeter = RecordingAudioSourceMeter()
    private var microphoneMeter = RecordingAudioSourceMeter()

    init(startedAt: Date? = nil) {
        self.startedAt = startedAt
    }

    mutating func reset(startedAt: Date = .now) {
        self.startedAt = startedAt
        systemMeter = RecordingAudioSourceMeter()
        microphoneMeter = RecordingAudioSourceMeter()
    }

    mutating func recordSample(source: RecordingAudioSource, level: Float, at date: Date = .now) {
        switch source {
        case .system:
            systemMeter.recordSample(level: level, at: date)
        case .microphone:
            microphoneMeter.recordSample(level: level, at: date)
        }
    }

    func meter(for source: RecordingAudioSource) -> RecordingAudioSourceMeter {
        switch source {
        case .system:
            systemMeter
        case .microphone:
            microphoneMeter
        }
    }

    func state(for source: RecordingAudioSource, at date: Date = .now) -> RecordingAudioSourceState {
        meter(for: source).state(startedAt: startedAt, at: date)
    }
}

nonisolated struct RecordingAudioWriteSummary: Equatable, Sendable {
    var didWriteSystemAudio = false
    var didWriteMicrophoneAudio = false
    var maxSystemAudioLevel: Float = 0
    var maxMicrophoneAudioLevel: Float = 0

    func warningMessages(
        expectsSystemAudio: Bool,
        expectsMicrophoneAudio: Bool,
        microphoneDisplayName: String
    ) -> [String] {
        var warnings: [String] = []

        if expectsSystemAudio {
            if !didWriteSystemAudio {
                warnings.append("No shared system audio was detected.")
            } else if maxSystemAudioLevel < RecordingAudioSourceMeter.silenceThreshold {
                warnings.append("Shared system audio was silent.")
            }
        }

        if expectsMicrophoneAudio {
            if !didWriteMicrophoneAudio {
                warnings.append("No microphone audio was detected from \(microphoneDisplayName).")
            } else if maxMicrophoneAudioLevel < RecordingAudioSourceMeter.silenceThreshold {
                warnings.append("Microphone audio from \(microphoneDisplayName) was silent.")
            }
        }

        return warnings
    }
}

nonisolated struct RecordingAudioStatusItem: Identifiable, Equatable, Sendable {
    let source: RecordingAudioSource
    let title: String
    let detail: String?
    let state: RecordingAudioSourceState
    let level: Float

    var id: RecordingAudioSource { source }
}
