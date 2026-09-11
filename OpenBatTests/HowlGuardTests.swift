//
//  HowlGuardTests.swift
//  OpenBatTests
//
//  The two things the guard has to get right, which pull against each other:
//  it must collapse a runaway within a fraction of a second, and it must be
//  invisible to a bat pass. Everything else here (the ceiling, the recovery)
//  is what keeps it from pumping between the two.
//

import Testing
import Foundation
@testable import OpenBat

struct HowlGuardTests {

    private let sampleRate = 48_000.0

    /// Runs `seconds` of a signal through the guard, one 512-frame buffer at a
    /// time, and hands back the peak that actually left it.
    @discardableResult
    private func run(_ guard_: HowlGuard, seconds: Double,
                     sample: (Int) -> Float) -> Float {
        let frames = 512
        let total = Int(seconds * sampleRate)
        var peak: Float = 0
        var index = 0
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames)
        defer { buffer.deallocate() }
        while index < total {
            let n = min(frames, total - index)
            for i in 0..<n { buffer[i] = sample(index + i) }
            guard_.process(buffer.baseAddress!, frames: n)
            for i in 0..<n { peak = max(peak, abs(buffer[i])) }
            index += n
        }
        return peak
    }

    /// A steady loud output — the runaway — is down to the floor shortly after
    /// the sustain window, not seconds later.
    @Test func sustainedOutputIsCollapsed() {
        let g = HowlGuard()
        g.reset(sampleRate: sampleRate)
        g.setArmed(true)
        run(g, seconds: Double(HowlGuard.triggerSeconds) + 0.4) { i in
            0.9 * sin(2 * .pi * 2_000 * Float(i) / 48_000)
        }
        #expect(g.tripCount == 1)
        #expect(g.attenuationDB < -20)
    }

    /// The shape that must pass through untouched: 10 ms pulses at 10 Hz, hot
    /// enough to reach the clipper, for longer than any sustain window.
    @Test func batPassIsLeftAlone() {
        let g = HowlGuard()
        g.reset(sampleRate: sampleRate)
        g.setArmed(true)
        let peak = run(g, seconds: 5) { i in
            let phase = Double(i).truncatingRemainder(dividingBy: sampleRate / 10)
            guard phase < sampleRate * 0.010 else { return 0 }
            return 0.9 * sin(2 * .pi * 2_000 * Float(i) / 48_000)
        }
        #expect(g.tripCount == 0)
        #expect(g.attenuationDB == 0)
        #expect(peak > 0.85)
    }

    /// Through headphones there is no loop, so a long steady tone is signal.
    @Test func disarmedGuardNeverDucks() {
        let g = HowlGuard()
        g.reset(sampleRate: sampleRate)
        g.setArmed(false)
        let peak = run(g, seconds: 3) { i in
            0.9 * sin(2 * .pi * 2_000 * Float(i) / 48_000)
        }
        #expect(g.tripCount == 0)
        #expect(peak > 0.85)
    }

    /// The output stage must not be able to put anything into the band the app
    /// listens in — that is what stops the loop existing electrically rather
    /// than merely stabilising it.
    @Test func speakerRouteStripsTheListeningBand() {
        let g = HowlGuard()
        g.reset(sampleRate: sampleRate)
        g.setArmed(true)
        for hz in [15_000.0, 20_000.0] {
            let peak = runBandLimit(g, seconds: 0.3, hz: hz)
            #expect(20 * log10(peak / 0.5) < -30)
        }
    }

    /// Through headphones the replay channel keeps its top end.
    @Test func headphoneRouteKeepsFullBandwidth() {
        let g = HowlGuard()
        g.reset(sampleRate: sampleRate)
        g.setArmed(false)
        let peak = runBandLimit(g, seconds: 0.3, hz: 12_000)
        #expect(peak > 0.45)
    }

    /// Steady tone through `bandLimitOutput` alone; returns the peak of the
    /// last 100 ms, past the filter's settling and the arm crossfade.
    private func runBandLimit(_ guard_: HowlGuard, seconds: Double, hz: Double) -> Float {
        let frames = 512
        let total = Int(seconds * sampleRate)
        let tail = total - Int(0.1 * sampleRate)
        var peak: Float = 0
        var index = 0
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames)
        defer { buffer.deallocate() }
        while index < total {
            let n = min(frames, total - index)
            for i in 0..<n {
                buffer[i] = 0.5 * sin(2 * .pi * Float(hz) * Float(index + i) / Float(sampleRate))
            }
            guard_.bandLimitOutput(buffer.baseAddress!, frames: n)
            if index > tail { for i in 0..<n { peak = max(peak, abs(buffer[i])) } }
            index += n
        }
        return peak
    }

    /// After the howl stops the output comes back — but to a ceiling below
    /// where it ran away, which is what stops the next snap costing another
    /// four seconds of hiss.
    @Test func recoversToALoweredCeiling() {
        let g = HowlGuard()
        g.reset(sampleRate: sampleRate)
        g.setArmed(true)
        run(g, seconds: Double(HowlGuard.triggerSeconds) + 0.4) { i in
            0.9 * sin(2 * .pi * 2_000 * Float(i) / 48_000)
        }
        #expect(g.isSuppressing || g.attenuationDB < -20)
        // Silence: the loop is broken, so the guard unlatches and ramps back.
        run(g, seconds: 6) { _ in 0 }
        #expect(!g.isSuppressing)
        let ceilingDB = 20 * log10(HowlGuard.ceilingDropPerTrip)
        #expect(g.attenuationDB > ceilingDB - 1)
        #expect(g.attenuationDB < 0)      // not all the way back to unity
    }
}
