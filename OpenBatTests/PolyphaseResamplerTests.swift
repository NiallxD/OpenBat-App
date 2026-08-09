//
//  PolyphaseResamplerTests.swift
//  OpenBatTests
//
//  Numeric-parity / property tests for the 384→256 kHz polyphase resampler that
//  BatDetect2Classifier runs on every captured pulse. The resampler is a straight
//  port of scipy.signal.resample_poly's design but deliberately NOT bit-exact with
//  it (see PolyphaseResampler.swift's header), so rather than compare against a
//  scipy oracle, these assert the properties that actually matter for correctness:
//  right output length, DC/low-frequency energy preserved, and — the whole reason
//  the filter exists — content above the new Nyquist attenuated (anti-aliasing).
//
//  `@testable import` gives access to the app's `internal` PolyphaseResampler. The
//  suite is @MainActor because the app is built with MainActor default actor
//  isolation, which makes its top-level static funcs MainActor-isolated.
//

import Testing
import Foundation
@testable import OpenBat

@MainActor
struct PolyphaseResamplerTests {

    // MARK: Helpers

    /// A `count`-sample sine of frequency `hz` at sample rate `rate`, amplitude 1.
    private func sine(hz: Double, rate: Double, count: Int) -> [Float] {
        (0..<count).map { Float(sin(2 * .pi * hz * Double($0) / rate)) }
    }

    /// Peak absolute amplitude, ignoring `edge` samples at each end (the FIR's
    /// group-delay ramp-up/down isn't representative of steady-state behaviour).
    private func interiorPeak(_ x: [Float], edge: Int) -> Float {
        guard x.count > 2 * edge else { return x.map(abs).max() ?? 0 }
        return x[edge..<(x.count - edge)].map(abs).max() ?? 0
    }

    // MARK: Contract / edge cases

    /// Same rate in and out must be a true no-op, not a lossy round-trip
    /// through the filter.
    @Test func equalRatesReturnsInputUnchanged() {
        let input = sine(hz: 1_000, rate: 384_000, count: 256)
        let out = PolyphaseResampler.resample(input, from: 384_000, to: 384_000)
        #expect(out == input)
    }

    /// Degenerate empty input must not crash or produce spurious samples.
    @Test func emptyInputReturnsEmpty() {
        let out = PolyphaseResampler.resample([], from: 384_000, to: 256_000)
        #expect(out.isEmpty)
    }

    /// Output length must track the up/down ratio (384k→256k is up=2, down=3),
    /// or every downstream consumer sized against it misaligns.
    @Test func outputLengthMatchesRatio() {
        let input = [Float](repeating: 0, count: 300)
        let out = PolyphaseResampler.resample(input, from: 384_000, to: 256_000)
        let expected = Int((Double(input.count) * 2.0 / 3.0).rounded(.up))
        #expect(out.count == expected)
    }

    // MARK: Numeric behaviour

    /// DC must survive resampling (interior, away from filter edges) — the
    /// zero-stuff-then-low-pass design restores the mean via unity DC gain.
    @Test func constantSignalIsPreserved() {
        let input = [Float](repeating: 0.5, count: 512)
        let out = PolyphaseResampler.resample(input, from: 384_000, to: 256_000)
        let interior = out[64..<(out.count - 64)]
        for v in interior {
            #expect(abs(v - 0.5) < 0.01)
        }
    }

    /// A tone well below the new Nyquist must pass essentially untouched.
    @Test func lowFrequencyToneKeepsItsAmplitude() {
        let input = sine(hz: 20_000, rate: 384_000, count: 2_048)
        let out = PolyphaseResampler.resample(input, from: 384_000, to: 256_000)
        let peak = interiorPeak(out, edge: 128)
        #expect(peak > 0.9)
        #expect(peak < 1.1)
    }

    /// The test that would catch a broken/removed low-pass filter: a naive
    /// resample would alias content above the new Nyquist back down as a loud
    /// phantom tone, so the anti-alias filter must instead crush it.
    @Test func aboveNewNyquistIsAttenuated() {
        let input = sine(hz: 150_000, rate: 384_000, count: 2_048)
        let out = PolyphaseResampler.resample(input, from: 384_000, to: 256_000)
        let peak = interiorPeak(out, edge: 128)
        #expect(peak < 0.1)
    }
}
