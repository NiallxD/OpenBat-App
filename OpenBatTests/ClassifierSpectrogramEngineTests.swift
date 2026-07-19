//
//  ClassifierSpectrogramEngineTests.swift
//  OpenBatTests
//
//  Property tests for the shared STFT → denoise → normalize → resize → colorize
//  engine that turns a raw PCM pulse into the exact image tensor each classifier's
//  CNN expects. Both live specs are exercised: NABat (dB / min-max / nearest /
//  magma) and BatDetect2 (PCEN / spectral-mean-subtraction / bilinear / grayscale),
//  so the PCEN path — the most intricate numeric port in the app — is covered here
//  through its real integration point rather than in isolation (`applyPCEN` is
//  private). These assert the invariants a broken port would violate: right tensor
//  shape, output bounded to [0,1], all-finite values, and the peak landing at the
//  time the energy actually is. They are NOT bit-for-bit oracle comparisons — that
//  parity was established once against the Python pipelines (see
//  batdetect2_conversion.md); these guard against regressions from here.
//

import Testing
import Foundation
@testable import OpenBat

@MainActor
struct ClassifierSpectrogramEngineTests {

    // MARK: Helpers

    /// A tone at `hz` windowed by a raised-cosine bump centred at `centerFraction`
    /// of the buffer, so the spectral energy is concentrated at a known TIME (for
    /// peak-time assertions) as well as a known frequency.
    private func burst(hz: Double, rate: Double, count: Int,
                       centerFraction: Double = 0.5, widthFraction: Double = 0.15) -> [Float] {
        let center = Double(count) * centerFraction
        let width = Double(count) * widthFraction
        return (0..<count).map { n in
            let tone = sin(2 * .pi * hz * Double(n) / rate)
            let d = (Double(n) - center) / width
            let envelope = exp(-0.5 * d * d)          // Gaussian bump
            return Float(tone * envelope)
        }
    }

    private func allFinite(_ x: [Float]) -> Bool {
        x.allSatisfy { $0.isFinite }
    }

    // MARK: Contract

    @Test func returnsNilWhenInputShorterThanOneWindow() {
        let short = [Float](repeating: 0, count: NaBatSpectrogramRenderer.nFFT - 1)
        #expect(ClassifierSpectrogramEngine.render(pcm: short, spec: NaBatSpectrogramRenderer.spec) == nil)
    }

    // MARK: NABat (dB path)

    @Test func nabatOutputHasExpectedShapeAndChannels() throws {
        let pcm = burst(hz: 40_000, rate: 384_000, count: 4_096)
        let out = try #require(ClassifierSpectrogramEngine.render(pcm: pcm, spec: NaBatSpectrogramRenderer.spec))
        #expect(out.channels == 3)   // magma colormap
        #expect(out.image.count == NaBatSpectrogramRenderer.outH * NaBatSpectrogramRenderer.outW * 3)
    }

    @Test func nabatMinMaxOutputStaysInUnitRange() throws {
        let pcm = burst(hz: 40_000, rate: 384_000, count: 4_096)
        let out = try #require(ClassifierSpectrogramEngine.render(pcm: pcm, spec: NaBatSpectrogramRenderer.spec))
        #expect(allFinite(out.image))
        #expect(out.image.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func nabatPeakTimeTracksACentredBurst() throws {
        let pcm = burst(hz: 40_000, rate: 384_000, count: 8_192, centerFraction: 0.5)
        let out = try #require(ClassifierSpectrogramEngine.render(pcm: pcm, spec: NaBatSpectrogramRenderer.spec))
        // Energy is concentrated mid-buffer, so the detected peak time should land
        // near the middle. Generous tolerance — this asserts the peak-finder isn't
        // grossly mislocated, not an exact frame.
        #expect(out.peakTimeFraction > 0.3)
        #expect(out.peakTimeFraction < 0.7)
    }

    @Test func nabatPeakTimeShiftsWithTheBurst() throws {
        let early = try #require(ClassifierSpectrogramEngine.render(
            pcm: burst(hz: 40_000, rate: 384_000, count: 8_192, centerFraction: 0.25),
            spec: NaBatSpectrogramRenderer.spec))
        let late = try #require(ClassifierSpectrogramEngine.render(
            pcm: burst(hz: 40_000, rate: 384_000, count: 8_192, centerFraction: 0.75),
            spec: NaBatSpectrogramRenderer.spec))
        // A later burst must report a later peak time — catches an axis flip or a
        // frame-index off-by-one in the peak scan.
        #expect(early.peakTimeFraction < late.peakTimeFraction)
    }

    // MARK: BatDetect2 (PCEN path)

    @Test func batDetect2OutputHasExpectedShapeAndChannels() throws {
        // BatDetect2's spec assumes PCM already at its target rate.
        let pcm = burst(hz: 40_000, rate: BatDetect2SpectrogramRenderer.spec.sampleRate, count: 4_096)
        let out = try #require(ClassifierSpectrogramEngine.render(pcm: pcm, spec: BatDetect2SpectrogramRenderer.spec))
        #expect(out.channels == 1)   // grayscale
        let s = BatDetect2SpectrogramRenderer.spec
        #expect(out.image.count == s.outputHeight * s.outputWidth * 1)
    }

    @Test func pcenPathProducesFiniteNonTrivialOutput() throws {
        // The PCEN recursion involves log1p/expm1/exp over a leaky-integrator state;
        // a broken initial condition or constant (the bugs the port fixed) tends to
        // surface as NaN/Inf or an all-identical image. Assert neither happens.
        let pcm = burst(hz: 45_000, rate: BatDetect2SpectrogramRenderer.spec.sampleRate, count: 4_096)
        let out = try #require(ClassifierSpectrogramEngine.render(pcm: pcm, spec: BatDetect2SpectrogramRenderer.spec))
        #expect(allFinite(out.image))
        let minV = out.image.min() ?? 0
        let maxV = out.image.max() ?? 0
        #expect(maxV > minV)   // not a flat image
    }

    @Test func silenceThroughPcenStaysFinite() throws {
        // Degenerate all-zero input must not divide-by-zero or log(0) into NaN.
        let pcm = [Float](repeating: 0, count: 4_096)
        let out = try #require(ClassifierSpectrogramEngine.render(pcm: pcm, spec: BatDetect2SpectrogramRenderer.spec))
        #expect(allFinite(out.image))
    }
}
