//
//  TuningPeakDetectorTests.swift
//  OpenBatTests
//
//  The one measurement the playback path takes from the audio itself — which
//  frequency heterodyne should tune to. It replaced running the live
//  Detector's whole SpectrogramProcessor on the pacing thread, so what needs
//  proving is that it still answers the same question with the same numbers:
//  the right frequency, and a zero (not a wrong guess) when there is nothing
//  worth tuning to.
//

import Testing
import Foundation
@testable import OpenBat

struct TuningPeakDetectorTests {

    private func tone(_ hz: Double, sampleRate: Double, count: Int, amplitude: Float = 0.6) -> [Float] {
        (0..<count).map { i in
            amplitude * Float(sin(2 * .pi * hz * Double(i) / sampleRate))
        }
    }

    /// The value, not just "non-zero" — a bin→Hz conversion that is off by a
    /// factor or an octave would still return something.
    @Test func resolvesAToneToItsOwnFrequency() {
        let detector = TuningPeakDetector()
        let sr = 384_000.0
        for hz in [20_000.0, 40_000.0, 85_000.0] {
            let samples = tone(hz, sampleRate: sr, count: TuningPeakDetector.windowLen)
            let peak = samples.withUnsafeBufferPointer {
                detector.strongestPeak($0.baseAddress!, count: $0.count, sampleRate: sr)
            }
            #expect(peak != nil)
            // One bin at a 2048-point FFT on 384 kHz audio is 187.5 Hz, and a
            // Hann window spreads a tone across a few of them, so allow a
            // couple of bins either way.
            #expect(abs((peak ?? 0) - hz) < 500,
                    "a \(hz) Hz tone resolved to \(peak ?? 0) Hz")
        }
    }

    /// Silence must report "nothing to tune to" (0), not the loudest bin of
    /// the noise floor — the squelch gate reads this, so a wrong answer here
    /// holds the gate open over an empty recording.
    @Test func silenceReportsNoConfidentPeak() {
        let detector = TuningPeakDetector()
        let quiet = [Float](repeating: 0, count: TuningPeakDetector.windowLen)
        let peak = quiet.withUnsafeBufferPointer {
            detector.strongestPeak($0.baseAddress!, count: $0.count, sampleRate: 384_000)
        }
        #expect(peak == 0)
    }

    /// A block too short to measure is NOT the same as a quiet one, and the
    /// distinction is load-bearing: with silence removal on, a kept region's
    /// tail can be shorter than one analysis window, and treating that as
    /// "nothing there" would close the squelch gate just before the next
    /// region's call arrived. The pacing thread skips such a tick entirely.
    @Test func aShortBlockIsUnmeasuredRatherThanQuiet() {
        let detector = TuningPeakDetector()
        let short = tone(40_000, sampleRate: 384_000, count: TuningPeakDetector.windowLen - 1)
        let peak = short.withUnsafeBufferPointer {
            detector.strongestPeak($0.baseAddress!, count: $0.count, sampleRate: 384_000)
        }
        #expect(peak == nil)
    }

    /// Rumble below the band floor must not be tuned to — the same
    /// `peakMinFraction` skip the live trigger scan makes. A 40 kHz call
    /// under a much louder 2 kHz rumble still reports the call.
    @Test func ignoresRumbleBelowTheBandFloor() {
        let detector = TuningPeakDetector()
        let sr = 384_000.0
        let n = TuningPeakDetector.windowLen
        let call = tone(40_000, sampleRate: sr, count: n, amplitude: 0.2)
        let rumble = tone(2_000, sampleRate: sr, count: n, amplitude: 0.9)
        let mixed = zip(call, rumble).map(+)
        let peak = mixed.withUnsafeBufferPointer {
            detector.strongestPeak($0.baseAddress!, count: $0.count, sampleRate: sr)
        }
        #expect(abs((peak ?? 0) - 40_000) < 500,
                "resolved \(peak ?? 0) Hz — rumble below the band floor is being tuned to")
    }

    /// **The regression guard that matters most here.** A bat call is 2-5 ms;
    /// a playback block is 20 ms. If the detector only looks at part of a
    /// block, calls fall between the looks and the squelch gate never opens
    /// for them — which is exactly what happened when detection was moved
    /// onto the 15 Hz tuning tick and only the last window of each block was
    /// examined: heterodyne playback went nearly silent because "most calls
    /// don't trigger it" (Niall, 2026-09-01).
    ///
    /// A short call placed anywhere in a block must be found.
    @Test func findsAShortCallAnywhereInABlock() {
        let detector = TuningPeakDetector()
        let sr = 384_000.0
        let block = Int(sr * 0.02)                 // one 20 ms playback block
        let callSamples = Int(sr * 0.003)          // a 3 ms call
        // Every position from the very start to the very end of the block.
        for offset in stride(from: 0, through: block - callSamples, by: block / 16) {
            var samples = [Float](repeating: 0, count: block)
            for i in 0..<block { samples[i] = Float.random(in: -0.001...0.001) }
            for k in 0..<callSamples {
                samples[offset + k] += 0.4 * Float(sin(2 * .pi * 40_000 * Double(k) / sr))
            }
            let peak = samples.withUnsafeBufferPointer {
                detector.strongestPeak($0.baseAddress!, count: $0.count, sampleRate: sr)
            }
            #expect(abs((peak ?? 0) - 40_000) < 1_000,
                    "a 3 ms call at offset \(offset) of a 20 ms block resolved \(peak ?? 0) Hz — the block is not being scanned in full")
        }
    }
}
