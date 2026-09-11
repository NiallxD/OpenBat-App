//
//  HeterodyneListenFloorTests.swift
//  OpenBatTests
//
//  The listening floor, which exists because of a loop that never involved an
//  ultrasonic frequency: with the band set as low as advanced view allows, the
//  phone's own 1–5 kHz output was inside the listening band, and an LO parked
//  under it mixed the speaker straight back into the audible channel. See
//  `HeterodyneProcessor.minimumListenHz`.
//

import Testing
import AVFoundation
@testable import OpenBat

struct HeterodyneListenFloorTests {

    private let inputRate = 384_000.0

    /// Runs `seconds` of a sine through the processor and returns the RMS of
    /// what reaches the speaker.
    private func audibleRMS(inputHz: Double, loHz: Double, seconds: Double = 0.5) -> Float {
        let processor = HeterodyneProcessor()
        processor.reset(inputSampleRate: inputRate)
        // Advanced view's own defaults — the band that made this possible.
        processor.setBand(low: 0.02, high: 0.45)
        processor.loFrequency = loHz
        processor.gain = 1
        processor.setGate(true)

        let frames = AVAudioFrameCount(4096)
        let format = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames

        let outFrames = 1024
        let out = UnsafeMutableBufferPointer<Float>.allocate(capacity: outFrames)
        defer { out.deallocate() }

        var index = 0
        var sum: Double = 0
        var counted = 0
        let total = Int(seconds * inputRate)
        while index < total {
            let channel = buffer.floatChannelData![0]
            for i in 0..<Int(frames) {
                channel[i] = 0.5 * sin(2 * .pi * Float(inputHz) * Float(index + i) / Float(inputRate))
            }
            processor.process(buffer)
            index += Int(frames)
            // Drain roughly what a buffer produced (input rate / decimation).
            processor.render(out.baseAddress!, frames: outFrames / 2)
            // Only the second half of the run counts: the gate ramps for 10 ms
            // and the filters settle.
            if Double(index) / inputRate > seconds / 2 {
                for i in 0..<(outFrames / 2) { sum += Double(out[i] * out[i]); counted += 1 }
            }
        }
        return counted > 0 ? Float((sum / Double(counted)).squareRoot()) : 0
    }

    /// The loop, reproduced: a 5 kHz tone (the phone's own speaker, as the mic
    /// hears it) with the LO parked just under it, which is exactly where the
    /// auto-tuner used to put it. It must not come back out of the speaker at
    /// anything like the level a real call does.
    @Test func speakerOutputCannotReachTheEar() {
        let leaked = audibleRMS(inputHz: 5_000, loHz: 3_500)
        let heard = audibleRMS(inputHz: 20_000, loHz: 18_500)
        // The floor is a 4th-order high-pass, so 5 kHz is ~38 dB down rather
        // than gone. What matters is the loop: the listening path's own gain is
        // ×12, so 30 dB of rejection is already the difference between a loop
        // that grows and one that dies. Before the floor, a band set this low
        // passed the speaker's output at full level.
        #expect(20 * log10(leaked / heard) < -30)
    }

    /// And the floor takes nothing real with it: a 20 kHz call still sounds.
    @Test func ultrasoundStillSounds() {
        let heard = audibleRMS(inputHz: 20_000, loHz: 18_500)
        #expect(heard > 0.05)
    }
}
