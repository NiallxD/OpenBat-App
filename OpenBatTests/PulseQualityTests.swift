//
//  PulseQualityTests.swift
//  OpenBatTests
//
//  The pulse view will not show a call scoring below 0.35, so whatever `quality`
//  actually measures decides which bats a person ever sees in detail. It is
//  supposed to mean "this is a clean call standing clear of the background".
//  It used to mean "this is a SHORT call", because it averaged the whole search
//  region — the call included — so a longer call raised its own denominator.
//
//  That is not a cosmetic difference. Call duration tracks frequency: the long
//  calls are the low ones (LACI, LANO, EPFU), so the view silently refused to
//  draw exactly those species. Measured on the demo clip before the fix, a
//  2.1 ms MYYU scored 0.90 and a 13.3 ms LANO scored 0.33.
//

import Testing
import Foundation
@testable import OpenBat

struct PulseQualityTests {

    private static let sampleRate: Double = 384_000

    /// A tone burst of `durationMs` at `khz`, centred in a buffer of `spanMs`,
    /// over uniform low-level noise. Same amplitude and same noise either way, so
    /// the only thing separating two of these is how long the call is.
    private func pulse(khz: Double, durationMs: Double, spanMs: Double,
                       noise: Float = 0.02) -> (pcm: [Float], onset: Int) {
        let sr = Self.sampleRate
        let total = Int(spanMs / 1000 * sr)
        let callLen = Int(durationMs / 1000 * sr)
        let onset = (total - callLen) / 2
        var rng = SystemRandomNumberGenerator()
        var pcm = (0..<total).map { _ in
            Float.random(in: -noise...noise, using: &rng)
        }
        // Flat-topped with short raised-cosine ramps, not a full-length taper. A
        // bat call holds its amplitude for most of its length; a fully tapered
        // burst only clears the renderer's noise gate near its middle, so it reads
        // as a much shorter call than it is and hides the very effect under test.
        let ramp = max(1, Int(0.001 * sr))
        for i in 0..<callLen {
            let t = Double(i) / sr
            let env: Double
            if i < ramp {
                env = 0.5 - 0.5 * cos(.pi * Double(i) / Double(ramp))
            } else if i >= callLen - ramp {
                env = 0.5 - 0.5 * cos(.pi * Double(callLen - 1 - i) / Double(ramp))
            } else {
                env = 1
            }
            pcm[onset + i] += Float(0.8 * env * sin(2 * .pi * khz * 1000 * t))
        }
        return (pcm, onset)
    }

    private func quality(khz: Double, durationMs: Double) throws -> Float {
        let spanMs = 40.0
        let p = pulse(khz: khz, durationMs: durationMs, spanMs: spanMs)
        let r = try #require(PulseImageRenderer.render(
            pcm: p.pcm, sampleRate: Self.sampleRate,
            noiseFloor: 0.35, minFrequencyHz: 15_000,
            displaySpanSeconds: 0.010, onsetFraction: 0.30,
            expectedOnsetSample: p.onset, makeImage: false))
        return r.quality
    }

    /// The point of the whole fix: two equally clean calls score alike however
    /// long they are. A 14 ms call is not a worse call than a 2 ms one.
    @Test func aLongCallScoresLikeAShortOne() throws {
        let short = try quality(khz: 50, durationMs: 2)
        let long  = try quality(khz: 22, durationMs: 14)
        #expect(abs(short - long) < 0.25,
                "short \(short) vs long \(long) — quality must not track duration")
    }

    /// And the specific case that was reported: a LACI-shaped call — low and long
    /// — has to clear the bar the pulse view draws at, or it is never seen.
    @Test func aLowLongCallClearsTheDisplayGate() throws {
        let q = try quality(khz: 20, durationMs: 15)
        #expect(q >= 0.35, "a clean low-frequency call scored \(q); the pulse view draws nothing below 0.35, so this species would be invisible")
    }

    /// Quality still has to mean something: a call buried in noise scores below a
    /// clean one, or the gate is just letting everything through.
    @Test func aNoisyCallStillScoresBelowACleanOne() throws {
        let spanMs = 40.0
        func score(noise: Float) throws -> Float {
            let p = pulse(khz: 40, durationMs: 6, spanMs: spanMs, noise: noise)
            let r = try #require(PulseImageRenderer.render(
                pcm: p.pcm, sampleRate: Self.sampleRate,
                noiseFloor: 0.35, minFrequencyHz: 15_000,
                displaySpanSeconds: 0.010, onsetFraction: 0.30,
                expectedOnsetSample: p.onset, makeImage: false))
            return r.quality
        }
        #expect(try score(noise: 0.01) > score(noise: 0.30))
    }

    /// The default view has to hold the whole call. It used to be a fixed window
    /// with the onset pinned at 30%%, leaving only 70%% of it for the call itself —
    /// so anything longer than ~7 ms of a 10 ms window ran off the right edge, and
    /// the long low species were shown cut in half.
    @Test func theDefaultViewWidensToHoldALongCall() throws {
        func crop(durationMs: Double) throws -> (span: Double, dur: Double) {
            let p = pulse(khz: 22, durationMs: durationMs, spanMs: 90)
            let r = try #require(PulseImageRenderer.render(
                pcm: p.pcm, sampleRate: Self.sampleRate,
                noiseFloor: 0.35, minFrequencyHz: 15_000,
                displaySpanSeconds: 0.010, onsetFraction: 0.30,
                expectedOnsetSample: p.onset, makeImage: false))
            // The crop as a fraction of the rendered image, which spans four
            // display windows — so 0.25 is one window's worth, i.e. 10 ms.
            return ((r.timeTightRightFrac - r.timeTightLeftFrac) * 40.0, r.durationMs)
        }
        let long = try crop(durationMs: 16)
        #expect(long.span >= long.dur,
                "a \(long.dur) ms call is shown in a \(long.span) ms window — it would be clipped")
    }

    /// And a call that already fitted keeps exactly the window it had. The fixed
    /// scale is the point of the pulse view: most calls should still render the
    /// same size in the same place, or comparing two of them by eye stops working.
    @Test func aShortCallKeepsTheFixedWindow() throws {
        let p = pulse(khz: 50, durationMs: 2, spanMs: 90)
        let r = try #require(PulseImageRenderer.render(
            pcm: p.pcm, sampleRate: Self.sampleRate,
            noiseFloor: 0.35, minFrequencyHz: 15_000,
            displaySpanSeconds: 0.010, onsetFraction: 0.30,
            expectedOnsetSample: p.onset, makeImage: false))
        let spanMs = (r.timeTightRightFrac - r.timeTightLeftFrac) * 40.0
        #expect(abs(spanMs - 10.0) < 0.5, "short call got a \(spanMs) ms window, expected the fixed 10")
        #expect(abs(r.timeTightLeftFrac - 0.25) < 0.02, "the fixed window should still start one span in")
    }

    /// Measurements do not depend on the picture: a caller that skipped the render
    /// still gets the frequency, duration and quality it files the pulse with.
    @Test func measurementsSurviveSkippingTheImage() throws {
        let p = pulse(khz: 45, durationMs: 5, spanMs: 40)
        func render(_ makeImage: Bool) throws -> PulseImageRenderer.Result {
            try #require(PulseImageRenderer.render(
                pcm: p.pcm, sampleRate: Self.sampleRate,
                noiseFloor: 0.35, minFrequencyHz: 15_000,
                displaySpanSeconds: 0.010, onsetFraction: 0.30,
                expectedOnsetSample: p.onset, makeImage: makeImage))
        }
        let drawn = try render(true)
        let bare  = try render(false)

        #expect(bare.image == nil)
        #expect(drawn.image != nil)
        #expect(bare.peakFreq == drawn.peakFreq)
        #expect(bare.durationMs == drawn.durationMs)
        #expect(bare.quality == drawn.quality)
    }
}
