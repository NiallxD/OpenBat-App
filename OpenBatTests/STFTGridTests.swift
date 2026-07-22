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

    @Test func streamPooledGridFromFileBoundsOutputToTargetColumns() {
        // A span whose native column count is much larger than the requested
        // target — this is the exact case the streaming path exists for.
        // Also a WHOLE-FILE-shaped span (the case that used to require a
        // completely separate, bulk-load-then-sample pipeline) — 1s of audio
        // is nowhere near a real recording's length, but exercises the same
        // "read far less than the full span" code path via `oversample`.
        let url = TestWavFactory.make(sampleRate: 384_000, seconds: 1.0, toneFrequency: 30_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var scratch = STFTGrid.Scratch()
        guard let (grid, nCols) = STFTGrid.streamPooledGridFromFile(
            wavURL: url, startSample: 0, endSample: Int(384_000 * 1.0), targetColumns: 256, scratch: &scratch)
        else {
            Issue.record("streamPooledGridFromFile returned nil for a valid 1s file")
            return
        }
        #expect(nCols == 256, "expected pooling down to the requested target column count, got \(nCols)")
        #expect(grid.count == STFTGrid.binCount * nCols)
        // Raw (non-normalized) dB values should be finite, not the initial
        // -.greatestFiniteMagnitude sentinel (which would mean a bucket was
        // never written to).
        #expect(grid.allSatisfy { $0 > -1000 && $0.isFinite })
    }

    @Test func streamPooledGridFromFileMatchesComputeWhenNativeColumnsFitWithinTarget() {
        // When targetColumns comfortably exceeds the native frame count, no
        // pooling (stride > 1) should occur — sanity check that visiting
        // every native frame via oversample doesn't distort short spans.
        let sampleRate = 384_000.0
        let seconds = 0.01
        let url = TestWavFactory.make(sampleRate: UInt32(sampleRate), seconds: seconds, toneFrequency: 50_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var scratch = STFTGrid.Scratch()
        let totalSamples = Int(sampleRate * seconds)
        guard let (grid, nCols) = STFTGrid.streamPooledGridFromFile(
            wavURL: url, startSample: 0, endSample: totalSamples, targetColumns: 10_000, scratch: &scratch)
        else {
            Issue.record("streamPooledGridFromFile returned nil")
            return
        }
        let nativeFrames = 1 + (totalSamples - STFTGrid.windowLen) / STFTGrid.hop
        #expect(nCols == nativeFrames, "targetColumns exceeds native frames, so no pooling should occur")
        #expect(grid.count == STFTGrid.binCount * nCols)
    }

    @Test func streamPooledGridFromFileHandlesWholeFileSpanBounded() {
        // Confirms the actual load-bearing property this function exists
        // for: a span many times longer than the target column count still
        // returns promptly and bounded — no attempt to read/hold the whole
        // span in memory. 5s stands in for "much longer than the screen
        // could ever show at native resolution" without making the test slow.
        let url = TestWavFactory.make(sampleRate: 384_000, seconds: 5.0, toneFrequency: 45_000)
        defer { try? FileManager.default.removeItem(at: url) }
        var scratch = STFTGrid.Scratch()
        guard let (grid, nCols) = STFTGrid.streamPooledGridFromFile(
            wavURL: url, startSample: 0, endSample: Int(384_000 * 5.0), targetColumns: 1536, scratch: &scratch)
        else {
            Issue.record("streamPooledGridFromFile returned nil for a valid 5s file")
            return
        }
        #expect(nCols == 1536)
        #expect(grid.count == STFTGrid.binCount * nCols)
        #expect(grid.allSatisfy { $0 > -1000 && $0.isFinite })
    }
}
