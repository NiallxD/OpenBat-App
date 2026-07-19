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

    @Test func equalRatesReturnsInputUnchanged() {
        let input = sine(hz: 1_000, rate: 384_000, count: 256)
        let out = PolyphaseResampler.resample(input, from: 384_000, to: 384_000)
        #expect(out == input)
    }

    @Test func emptyInputReturnsEmpty() {
        let out = PolyphaseResampler.resample([], from: 384_000, to: 256_000)
        #expect(out.isEmpty)
    }

    @Test func outputLengthMatchesRatio() {
        // 384k → 256k reduces to up=2, down=3, so out ≈ ceil(n * 2/3).
        let input = [Float](repeating: 0, count: 300)
        let out = PolyphaseResampler.resample(input, from: 384_000, to: 256_000)
        let expected = Int((Double(input.count) * 2.0 / 3.0).rounded(.up))
        #expect(out.count == expected)
    }

    // MARK: Numeric behaviour

    @Test func constantSignalIsPreserved() {
        // Zero-stuff-by-up then low-pass with DC gain = up restores the mean, so a
        // constant should survive resampling (interior, away from filter edges).
        let input = [Float](repeating: 0.5, count: 512)
        let out = PolyphaseResampler.resample(input, from: 384_000, to: 256_000)
        let interior = out[64..<(out.count - 64)]
        for v in interior {
            #expect(abs(v - 0.5) < 0.01)
        }
    }

    @Test func lowFrequencyToneKeepsItsAmplitude() {
        // 20 kHz is far below the 128 kHz new-Nyquist, so it must pass essentially
        // untouched — amplitude preserved to within a few percent in the interior.
        let input = sine(hz: 20_000, rate: 384_000, count: 2_048)
        let out = PolyphaseResampler.resample(input, from: 384_000, to: 256_000)
        let peak = interiorPeak(out, edge: 128)
        #expect(peak > 0.9)
        #expect(peak < 1.1)
    }

    @Test func aboveNewNyquistIsAttenuated() {
        // 150 kHz sits above the 128 kHz Nyquist of the 256 kHz output. A naive
        // (linear) resample would alias it back down as a loud phantom tone; the
        // anti-alias filter must instead crush it. This is the test that would
        // catch a broken/removed low-pass filter.
        let input = sine(hz: 150_000, rate: 384_000, count: 2_048)
        let out = PolyphaseResampler.resample(input, from: 384_000, to: 256_000)
        let peak = interiorPeak(out, edge: 128)
        #expect(peak < 0.1)
    }
}
