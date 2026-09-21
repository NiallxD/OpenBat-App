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
            // The crop as a fraction of the rendered image. Its width is no longer
            // four display windows — the right-hand pad grows to hold the active
            // model's longest call — so it comes off the result rather than being
            // assumed here.
            return ((r.timeTightRightFrac - r.timeTightLeftFrac) * r.renderedSpanMs, r.durationMs)
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
        let spanMs = (r.timeTightRightFrac - r.timeTightLeftFrac) * r.renderedSpanMs
        #expect(abs(spanMs - 10.0) < 0.5, "short call got a \(spanMs) ms window, expected the fixed 10")
        // One display window in from the left edge, as before — expressed against
        // the rendered width rather than the old fixed 0.25, which assumed it.
        let leftMs = r.timeTightLeftFrac * r.renderedSpanMs
        #expect(abs(leftMs - 10.0) < 0.5, "the fixed window should still start one span in, got \(leftMs) ms")
    }

    /// The ceiling this whole change is about. A 58 ms horseshoe call used to be
    /// measured as ~17 ms whatever the bat did, because the renderer's envelope
    /// walk ran a fixed 1.5 display windows past the onset — a display preference
    /// deciding how long a call was allowed to be. With BatDetect2's own span it
    /// must now measure the call it was given.
    @Test func aLongCallIsMeasuredInFull() throws {
        let p = pulse(khz: 82, durationMs: 58, spanMs: 200)
        let r = try #require(PulseImageRenderer.render(
            pcm: p.pcm, sampleRate: Self.sampleRate,
            noiseFloor: 0.35, minFrequencyHz: 15_000,
            displaySpanSeconds: 0.010, onsetFraction: 0.30,
            expectedOnsetSample: p.onset,
            maxCallSeconds: ModelInputSpec.batdetect2.maxCallMs / 1000,
            makeImage: false))
        #expect(r.durationMs > 50,
                "a 58 ms call measured \(r.durationMs) ms — the old ceiling was ~17")
        // And the picture has to be as wide as the measurement, or it is measured
        // correctly and still drawn clipped.
        let cropMs = (r.timeTightRightFrac - r.timeTightLeftFrac) * r.renderedSpanMs
        #expect(cropMs >= r.durationMs,
                "a \(r.durationMs) ms call is drawn in a \(cropMs) ms window")
    }

    /// And a model whose region has no such bat does not pay for one: NABat's span
    /// stops well short of BatDetect2's, so its captures stay small.
    @Test func aShortRegionKeepsItsSmallerSpan() throws {
        #expect(ModelInputSpec.nabat.maxCallMs < ModelInputSpec.batdetect2.maxCallMs)
        let p = pulse(khz: 82, durationMs: 58, spanMs: 200)
        func span(_ maxCallMs: Double) throws -> Double {
            let r = try #require(PulseImageRenderer.render(
                pcm: p.pcm, sampleRate: Self.sampleRate,
                noiseFloor: 0.35, minFrequencyHz: 15_000,
                displaySpanSeconds: 0.010, onsetFraction: 0.30,
                expectedOnsetSample: p.onset,
                maxCallSeconds: maxCallMs / 1000, makeImage: false))
            return r.renderedSpanMs
        }
        #expect(try span(ModelInputSpec.nabat.maxCallMs)
                  < span(ModelInputSpec.batdetect2.maxCallMs),
                "NABat should render a smaller image — that is what keeps its transform cheap")
    }

    /// Widening the search region must not move the quality score. It is a ratio
    /// against the mean of the columns the call does not occupy, so sweeping in
    /// more quiet audio would raise every pulse's score — including NABat's — and
    /// shift every call against the 0.35 the pulse view draws at. The background
    /// window is pinned for exactly this reason.
    @Test func qualityDoesNotMoveWithTheSearchSpan() throws {
        let p = pulse(khz: 45, durationMs: 5, spanMs: 200)
        func quality(_ maxCallMs: Double) throws -> Float {
            let r = try #require(PulseImageRenderer.render(
                pcm: p.pcm, sampleRate: Self.sampleRate,
                noiseFloor: 0.35, minFrequencyHz: 15_000,
                displaySpanSeconds: 0.010, onsetFraction: 0.30,
                expectedOnsetSample: p.onset,
                maxCallSeconds: maxCallMs / 1000, makeImage: false))
            return r.quality
        }
        let narrow = try quality(ModelInputSpec.nabat.maxCallMs)
        let wide   = try quality(ModelInputSpec.batdetect2.maxCallMs)
        #expect(abs(narrow - wide) < 0.01,
                "the same call scored \(narrow) under NABat and \(wide) under BatDetect2")
    }

    /// Diagnostic for the 38 ms Niall measured in the field. A 58 ms call under
    /// the 30 ms fallback should land in the high 30s — if it does, what he was
    /// seeing is the fallback, not BatDetect2's 80 ms, and the question is why the
    /// active model isn't reaching the renderer.
    @Test func theThirtyMsFallbackCapsAroundFortyMs() throws {
        let p = pulse(khz: 82, durationMs: 58, spanMs: 300)
        func dur(_ ms: Double) throws -> Double {
            try #require(PulseImageRenderer.render(
                pcm: p.pcm, sampleRate: Self.sampleRate,
                noiseFloor: 0.35, minFrequencyHz: 15_000,
                displaySpanSeconds: 0.010, onsetFraction: 0.30,
                expectedOnsetSample: p.onset,
                maxCallSeconds: ms / 1000, makeImage: false)).durationMs
        }
        let fallback = try dur(30)
        let bd2 = try dur(80)
        #expect(fallback > 33 && fallback < 43,
                "30 ms fallback capped a 58 ms call at \(fallback) ms")
        #expect(bd2 > 50, "80 ms setting measured \(bd2) ms")
    }

    /// A call is pinned by its loud core, but measured from its faint leading edge,
    /// so the crop has to hold the part that sits BEFORE the pin. A long quiet ramp
    /// into the call is the case that breaks if `wantFrames` is counted from the
    /// lock point instead of from the measured start.
    @Test func theCropHoldsTheFaintLeadingEdge() throws {
        /// Same bright core as `pulse`, preceded by a long quiet ramp — the shape a
        /// CF call actually has, and the one that separates the two thresholds.
        func rampedPulse(leadMs: Double) -> (pcm: [Float], onset: Int) {
            let sr = Self.sampleRate
            let total = Int(90.0 / 1000 * sr)
            let lead = Int(leadMs / 1000 * sr)
            let core = Int(6.0 / 1000 * sr)
            let onset = (total - lead - core) / 2
            var rng = SystemRandomNumberGenerator()
            var pcm = (0..<total).map { _ in Float.random(in: -0.02...0.02, using: &rng) }
            for i in 0..<(lead + core) {
                let t = Double(onset + i) / sr
                // Ramp from well below the peak up to it, then hold.
                let env = i < lead ? 0.02 + 0.2 * Double(i) / Double(max(1, lead)) : 1.0
                pcm[onset + i] += Float(0.8 * env * sin(2 * .pi * 55_000 * t))
            }
            return (pcm, onset)
        }
        for leadMs in [0.0, 2.0, 4.0] {
            let p = rampedPulse(leadMs: leadMs)
            let r = try #require(PulseImageRenderer.render(
                pcm: p.pcm, sampleRate: Self.sampleRate,
                noiseFloor: 0.35, minFrequencyHz: 15_000,
                displaySpanSeconds: 0.006, onsetFraction: 0.30,
                expectedOnsetSample: p.onset, makeImage: false))
            let cropMs = (r.timeTightRightFrac - r.timeTightLeftFrac) * r.renderedSpanMs
            #expect(cropMs >= r.durationMs,
                    "lead \(leadMs) ms: a \(r.durationMs) ms call is cropped to \(cropMs) ms")
        }
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
