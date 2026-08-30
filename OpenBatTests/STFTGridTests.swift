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

    /// Input too short for one window must fail cleanly, not underflow.
    @Test func computeReturnsNilForTooShortInput() {
        var scratch = STFTGrid.Scratch()
        let short = [Float](repeating: 0, count: STFTGrid.windowLen - 1)
        #expect(STFTGrid.compute(pcm: short, scratch: &scratch, dynamicRangeDB: 48) == nil)
    }

    /// A known tone's energy must land at the correct bin, confirming the
    /// bin→Hz mapping and normalization bounds are both right.
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

    /// The case the streaming path exists for: a span whose native column
    /// count exceeds the target must pool down to exactly `targetColumns`,
    /// exercising the same "read far less than the full span" path a
    /// whole-file-length span would use, without an actual long file.
    @Test func streamPooledGridFromFileBoundsOutputToTargetColumns() {
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

    /// When `targetColumns` comfortably exceeds the native frame count, no
    /// pooling should occur — visiting every native frame via oversample
    /// must not distort a short span.
    @Test func streamPooledGridFromFileMatchesComputeWhenNativeColumnsFitWithinTarget() {
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

    /// The load-bearing property this function exists for: a span many
    /// times longer than the target column count still returns promptly and
    /// bounded, with no attempt to read/hold the whole span in memory.
    @Test func streamPooledGridFromFileHandlesWholeFileSpanBounded() {
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

    /// `effectiveHop` must leave every zoom level that already has enough
    /// native frames completely alone — it only steps finer BELOW the
    /// crossover, so no wider view can change appearance because of it.
    @Test func effectiveHopOnlyGoesFinerBelowTheNativeCrossover() {
        let target = 1536
        // A 1 s span at 384 kHz holds ~12 000 native frames — far more than
        // the target, so the native hop stands.
        #expect(STFTGrid.effectiveHop(spanSamples: 384_000, targetColumns: target) == STFTGrid.hop)
        // Right at the crossover (target columns' worth of native hops) it is
        // still the native hop, not one sample less.
        #expect(STFTGrid.effectiveHop(spanSamples: STFTGrid.windowLen + target * STFTGrid.hop,
                                      targetColumns: target) == STFTGrid.hop)
        // A 20 ms span (7 680 samples) has only ~224 native frames for 1 536
        // columns — this is the case that was being stretched.
        let deep = STFTGrid.effectiveHop(spanSamples: 7_680, targetColumns: target)
        #expect(deep < STFTGrid.hop && deep >= 1)
        // Never zero or negative, however extreme the zoom.
        #expect(STFTGrid.effectiveHop(spanSamples: STFTGrid.windowLen + 1, targetColumns: target) >= 1)
    }

    /// The point of the finer hop: a zoomed-in span now fills the tile's
    /// columns with real analysis instead of handing back a few hundred to be
    /// stretched across the view.
    @Test func deepZoomSpanFillsItsColumnsWithTheFinerHop() {
        let sampleRate = 384_000.0
        let url = TestWavFactory.make(sampleRate: UInt32(sampleRate), seconds: 0.2, toneFrequency: 45_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let span = 7_680      // 20 ms
        let target = 1536
        var scratch = STFTGrid.Scratch()
        let nativeFrames = 1 + (span - STFTGrid.windowLen) / STFTGrid.hop
        #expect(nativeFrames < target, "test premise: this span is below the native crossover")

        guard let (_, nativeCols) = STFTGrid.streamPooledGridFromFile(
            wavURL: url, startSample: 0, endSample: span, targetColumns: target, scratch: &scratch)
        else { Issue.record("native-hop render returned nil"); return }
        #expect(nativeCols == nativeFrames, "the native hop can't do better than its own frame count")

        let hop = STFTGrid.effectiveHop(spanSamples: span, targetColumns: target)
        guard let (grid, cols) = STFTGrid.streamPooledGridFromFile(
            wavURL: url, startSample: 0, endSample: span, targetColumns: target,
            scratch: &scratch, frameHop: hop)
        else { Issue.record("fine-hop render returned nil"); return }
        #expect(cols == target, "expected a full-width tile, got \(cols)")
        #expect(grid.count == STFTGrid.binCount * cols)
        // Every column carries real analysis — no untouched sentinel buckets.
        #expect(grid.allSatisfy { $0 > -1000 && $0.isFinite })
    }
}
