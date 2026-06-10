//
//  AudioLevelMeter.swift
//  BetterCapture
//
//  Created by Joshua Sattler on 10.06.26.
//

import AVFoundation

nonisolated enum AudioLevelMeter {
    static let unmeasuredAudioLevel = RecordingAudioSourceMeter.silenceThreshold

    static func level(for sampleBuffer: CMSampleBuffer) -> Float {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
            let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else {
            return CMSampleBufferGetNumSamples(sampleBuffer) > 0 ? unmeasuredAudioLevel : 0
        }

        let audioStreamDescription = streamDescription.pointee
        guard audioStreamDescription.mFormatID == kAudioFormatLinearPCM else {
            return CMSampleBufferGetNumSamples(sampleBuffer) > 0 ? unmeasuredAudioLevel : 0
        }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else {
            return CMSampleBufferGetNumSamples(sampleBuffer) > 0 ? unmeasuredAudioLevel : 0
        }

        return level(
            from: UnsafeRawPointer(dataPointer),
            byteLength: totalLength,
            streamDescription: audioStreamDescription
        )
    }

    private static func level(
        from dataPointer: UnsafeRawPointer,
        byteLength: Int,
        streamDescription: AudioStreamBasicDescription
    ) -> Float {
        let bitsPerChannel = Int(streamDescription.mBitsPerChannel)
        let bytesPerSample = max(bitsPerChannel / 8, 1)
        let sampleCount = byteLength / bytesPerSample

        guard sampleCount > 0 else {
            return 0
        }

        let sampleStride = max(sampleCount / 4096, 1)
        let flags = streamDescription.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0

        var sumSquares = 0.0
        var measuredSamples = 0

        if isFloat, bitsPerChannel == 32 {
            let samples = dataPointer.assumingMemoryBound(to: Float.self)
            for index in stride(from: 0, to: sampleCount, by: sampleStride) {
                let sample = Double(samples[index])
                sumSquares += sample * sample
                measuredSamples += 1
            }
        } else if bitsPerChannel == 16 {
            let samples = dataPointer.assumingMemoryBound(to: Int16.self)
            for index in stride(from: 0, to: sampleCount, by: sampleStride) {
                let sample = Double(samples[index]) / Double(Int16.max)
                sumSquares += sample * sample
                measuredSamples += 1
            }
        } else if bitsPerChannel == 32 {
            let samples = dataPointer.assumingMemoryBound(to: Int32.self)
            for index in stride(from: 0, to: sampleCount, by: sampleStride) {
                let sample = Double(samples[index]) / Double(Int32.max)
                sumSquares += sample * sample
                measuredSamples += 1
            }
        }

        guard measuredSamples > 0 else {
            return unmeasuredAudioLevel
        }

        let rms = sqrt(sumSquares / Double(measuredSamples))
        return min(max(Float(rms.isFinite ? rms : 0), 0), 1)
    }
}
