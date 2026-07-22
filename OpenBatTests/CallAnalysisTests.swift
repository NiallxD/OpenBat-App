//
//  CallAnalysisTests.swift
//  OpenBatTests
//
//  Exercises CallAnalysis's pure-data `analyze(pcm:...)` entry directly (no
//  file I/O) with synthetic signals whose true parameters are known, so
//  measured PF/CF/duration/start-end-freq/sweep-rate can be checked against
//  ground truth rather than just "didn't crash."
//

import Testing
import Foundation
@testable import OpenBat

struct CallAnalysisTests {

    private let sampleRate = 384_000.0

    /// A short tone burst centered in an otherwise near-silent buffer — models
    /// a real bounded selection (marker padding, or a manual drag box) that
    /// includes some quiet margin around the actual call.
    private func makeBurst(toneHz: Double, burstMs: Double, paddingMsEachSide: Double) -> [Float] {
        let totalMs = burstMs + paddingMsEachSide * 2
        let n = Int(sampleRate * totalMs / 1000)
        let burstStart = Int(sampleRate * paddingMsEachSide / 1000)
        let burstEnd = burstStart + Int(sampleRate * burstMs / 1000)
        var pcm = [Float](repeating: 0, count: n)
        for i in burstStart..<min(burstEnd, n) {
            let t = Double(i - burstStart) / sampleRate
            pcm[i] = Float(sin(2 * .pi * toneHz * t)) * 0.8
        }
        return pcm
    }

    /// A continuous linear FM sweep from `f0` to `fKnee` over the first
    /// `1 - tailFraction` of the duration, then held flat at `fKnee` for the
    /// remaining `tailFraction` — models the classic bat-call shape a
    /// characteristic/knee-frequency measurement targets.
    private func makeChirpWithFlatTail(f0: Double, fKnee: Double, durationMs: Double,
                                       tailFraction: Double) -> [Float] {
        let n = Int(sampleRate * durationMs / 1000)
        let sweepEndIndex = Int(Double(n) * (1 - tailFraction))
        var pcm = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let freq: Double
            if i < sweepEndIndex {
                let frac = Double(i) / Double(max(sweepEndIndex, 1))
                freq = f0 + (fKnee - f0) * frac
            } else {
                freq = fKnee
            }
            phase += 2 * .pi * freq / sampleRate
            pcm[i] = Float(sin(phase)) * 0.8
        }
        return pcm
    }

    @Test func toneBurstMeasuresPeakFrequencyAndDuration() {
        let toneHz = 40_000.0
        let pcm = makeBurst(toneHz: toneHz, burstMs: 5, paddingMsEachSide: 10)
        let result = CallAnalysis.analyze(pcm: pcm, sampleRate: sampleRate,
                                          minFrequencyHz: 5_000, noiseFloor: 0.05)
        #expect(result != nil)
        guard let result else { return }

        let hzPerBin = (sampleRate / 2) / Double(STFTGrid.binCount)
        #expect(abs(result.peakFreqHz - toneHz) <= hzPerBin * 1.5,
                "peak \(result.peakFreqHz) Hz should be near the encoded \(toneHz) Hz tone")
        #expect(result.durationMs > 1 && result.durationMs < 10,
                "measured duration \(result.durationMs)ms should roughly bracket the encoded 5ms burst")
        #expect(result.quality > 0.2,
                "a short burst in an otherwise quiet buffer should stand out with decent quality, got \(result.quality)")
        #expect(abs(result.sweepRateHzPerMs) < hzPerBin * 2,
                "a constant tone should show near-zero sweep rate, got \(result.sweepRateHzPerMs)")
    }

    @Test func chirpWithFlatTailMeasuresStartEndAndCharacteristicFrequency() {
        let f0 = 60_000.0
        let fKnee = 25_000.0
        let durationMs = 10.0
        let tailFraction = 0.3
        let pcm = makeChirpWithFlatTail(f0: f0, fKnee: fKnee, durationMs: durationMs, tailFraction: tailFraction)
        let result = CallAnalysis.analyze(pcm: pcm, sampleRate: sampleRate,
                                          minFrequencyHz: 5_000, noiseFloor: 0.05,
                                          cfTailFraction: tailFraction)
        #expect(result != nil)
        guard let result else { return }

        let hzPerBin = (sampleRate / 2) / Double(STFTGrid.binCount)
        // Start/end frequency are read from the STFT's very first/last
        // analysis window (windowLen=512 samples ≈ 1.33ms) — during a fast
        // sweep, the true instantaneous frequency moves substantially WITHIN
        // that one window (here, ~5000 Hz/ms × 1.33ms ≈ 6.7kHz of sweep
        // inside the first window alone), so some smearing at the very edges
        // is an inherent STFT time-frequency trade-off, not a measurement
        // bug. The flat tail CF sits in a stable region with many frames at
        // the SAME instantaneous frequency, so it stays much sharper.
        let edgeTolerance = 4_000.0
        let cfTolerance = hzPerBin * 3

        #expect(abs(result.startFreqHz - f0) <= edgeTolerance,
                "start freq \(result.startFreqHz) should be near f0=\(f0)")
        #expect(abs(result.endFreqHz - fKnee) <= edgeTolerance,
                "end freq \(result.endFreqHz) should be near fKnee=\(fKnee)")
        #expect(result.characteristicFreqHz != nil)
        if let cf = result.characteristicFreqHz {
            #expect(abs(cf - fKnee) <= cfTolerance,
                    "characteristic frequency \(cf) should track the flat tail near fKnee=\(fKnee)")
        }
        // A downward sweep (f0 > fKnee) must show a negative sweep rate.
        #expect(result.sweepRateHzPerMs < 0,
                "a downward sweep should have negative sweepRateHzPerMs, got \(result.sweepRateHzPerMs)")
        #expect(result.freqMaxHz >= result.freqMinHz)
        #expect(result.bandwidthHz > 0)
    }

    @Test func broadbandNoiseHasLowQuality() {
        var generator = SystemRandomNumberGenerator()
        let n = Int(sampleRate * 0.02)   // 20ms, fully noisy (no quiet padding)
        let pcm = (0..<n).map { _ in Float.random(in: -0.6...0.6, using: &generator) }
        let result = CallAnalysis.analyze(pcm: pcm, sampleRate: sampleRate,
                                          minFrequencyHz: 5_000, noiseFloor: 0.05)
        #expect(result != nil)
        if let result {
            #expect(result.quality < 0.4,
                    "uniformly elevated broadband noise should score low quality (nothing stands out), got \(result.quality)")
        }
    }

    @Test func tooShortSelectionReturnsNil() {
        let pcm = [Float](repeating: 0, count: STFTGrid.windowLen - 1)
        let result = CallAnalysis.analyze(pcm: pcm, sampleRate: sampleRate,
                                          minFrequencyHz: 5_000, noiseFloor: 0.05)
        #expect(result == nil)
    }

    /// Pure silence still normalizes to a uniform grid (peak-relative
    /// normalization maps the — constant — max to 1.0 regardless of absolute
    /// level, same characteristic PulseImageRenderer's identical normalization
    /// has), so `analyze` returns a Result rather than nil; quality should
    /// read as zero (nothing stands out) rather than silently crashing or
    /// producing a misleadingly confident measurement.
    @Test func silentSelectionHasZeroQuality() {
        let pcm = [Float](repeating: 0, count: Int(sampleRate * 0.01))
        let result = CallAnalysis.analyze(pcm: pcm, sampleRate: sampleRate,
                                          minFrequencyHz: 5_000, noiseFloor: 0.05)
        #expect(result != nil)
        #expect(result?.quality == 0)
    }
}
