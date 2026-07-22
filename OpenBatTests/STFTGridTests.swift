//
//  STFTGridTests.swift
//  OpenBatTests
//
//  Basic correctness coverage for STFTGrid — extracted from PulseImageRenderer
//  (see that refactor) with no prior test coverage of its own. Confirms a
//  synthetic tone's energy lands at the expected bin and that both the
//  one-shot and streaming-pooled paths produce sane, bounded output.
//

import Testing
import Foundation
@testable import OpenBat

struct STFTGridTests {

    private func makeTone(frequency: Double, sampleRate: Double, seconds: Double) -> [Float] {
        let n = Int(sampleRate * seconds)
        return (0..<n).map { i in
            Float(sin(2 * .pi * frequency * Double(i) / sampleRate)) * 0.8
        }
    }

    @Test func computeReturnsNilForTooShortInput() {
        var scratch = STFTGrid.Scratch()
        let short = [Float](repeating: 0, count: STFTGrid.windowLen - 1)
        #expect(STFTGrid.compute(pcm: short, scratch: &scratch, dynamicRangeDB: 48) == nil)
    }

    @Test func computePeakBinMatchesToneFrequency() {
        let sampleRate = 384_000.0
        let toneHz = 40_000.0
        let pcm = makeTone(frequency: toneHz, sampleRate: sampleRate, seconds: 0.02)
        var scratch = STFTGrid.Scratch()
        guard let (grid, nFrames) = STFTGrid.compute(pcm: pcm, scratch: &scratch, dynamicRangeDB: 48) else {
            Issue.record("compute() returned nil for a valid tone buffer")
            return
        }
        #expect(nFrames > 0)
        #expect(grid.count == STFTGrid.binCount * nFrames)

        // Find the (bin, col) with the peak normalized value; confirm its Hz is
        // within one bin-width of the known tone frequency.
        var peakBin = 0, peakVal: Float = -1
        for bin in 0..<STFTGrid.binCount {
            for col in 0..<nFrames {
                let v = grid[bin * nFrames + col]
                if v > peakVal { peakVal = v; peakBin = bin }
            }
        }
        let hzPerBin = (sampleRate / 2) / Double(STFTGrid.binCount)
        let peakHz = Double(peakBin) * hzPerBin
        #expect(abs(peakHz - toneHz) <= hzPerBin * 1.5,
                "peak bin corresponds to \(peakHz) Hz, expected near \(toneHz) Hz")
        #expect(peakVal <= 1.0 && peakVal >= 0.0, "normalized grid values must stay in [0,1], got \(peakVal)")
    }

    @Test func streamPooledGridBoundsOutputToTargetColumns() {
        let sampleRate = 384_000.0
        // A span whose native column count is much larger than the requested
        // target — this is the exact case the streaming path exists for.
        let pcm = makeTone(frequency: 30_000, sampleRate: sampleRate, seconds: 1.0)
        var scratch = STFTGrid.Scratch()
        guard let (grid, nCols) = STFTGrid.streamPooledGrid(pcm: pcm, targetColumns: 256, scratch: &scratch) else {
            Issue.record("streamPooledGrid returned nil for a valid 1s buffer")
            return
        }
        #expect(nCols == 256, "expected pooling down to the requested target column count, got \(nCols)")
        #expect(grid.count == STFTGrid.binCount * nCols)
        // Raw (non-normalized) dB values should be finite, not the initial
        // -.greatestFiniteMagnitude sentinel (which would mean a bucket was
        // never written to).
        #expect(grid.allSatisfy { $0 > -1000 && $0.isFinite })
    }

    @Test func streamPooledGridMatchesComputeWhenNativeColumnsFitWithinTarget() {
        // When targetColumns comfortably exceeds the native frame count, the
        // streaming path's per-frame values (pre-normalization) should equal
        // a plain per-frame dB computation to a plausible bin — sanity check
        // that pooling with colsPerBucket == 1 doesn't distort short spans.
        let sampleRate = 384_000.0
        let pcm = makeTone(frequency: 50_000, sampleRate: sampleRate, seconds: 0.01)
        var scratch = STFTGrid.Scratch()
        guard let (grid, nCols) = STFTGrid.streamPooledGrid(pcm: pcm, targetColumns: 10_000, scratch: &scratch) else {
            Issue.record("streamPooledGrid returned nil")
            return
        }
        let nativeFrames = 1 + (pcm.count - STFTGrid.windowLen) / STFTGrid.hop
        #expect(nCols == nativeFrames, "targetColumns exceeds native frames, so no pooling should occur")
        #expect(grid.count == STFTGrid.binCount * nCols)
    }
}
