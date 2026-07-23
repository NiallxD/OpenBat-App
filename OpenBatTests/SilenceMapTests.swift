//
//  SilenceMapTests.swift
//  OpenBatTests
//
//  The virtual<->real domain mapping is what every hide-silence consumer
//  (seek, playhead, tile stitching, analysis) relies on, so it's tested in
//  isolation here rather than only through the UI.
//

import Testing
import Foundation
@testable import OpenBat

struct SilenceMapTests {

    /// Two active segments with a hidden gap between them:
    ///   real [1000,2000) -> virtual [0,1000)
    ///   real [5000,6000) -> virtual [1000,2000)
    private func twoSegmentMap() -> SilenceMap {
        SilenceMap(segments: [
            .init(realStart: 1000, realEnd: 2000, virtualStart: 0),
            .init(realStart: 5000, realEnd: 6000, virtualStart: 1000),
        ], virtualTotal: 2000, realTotal: 7000)
    }

    @Test func virtualToRealMapsWithinAndAcrossSegments() {
        let m = twoSegmentMap()
        #expect(m.virtualToReal(0) == 1000)
        #expect(m.virtualToReal(999) == 1999)
        #expect(m.virtualToReal(1000) == 5000)   // seam: first virtual of segment 1
        #expect(m.virtualToReal(1999) == 5999)
    }

    @Test func virtualToRealClampsOutOfRange() {
        let m = twoSegmentMap()
        #expect(m.virtualToReal(-50) == 1000)
        #expect(m.virtualToReal(999_999) == 6000)   // clamped to virtualTotal -> last real
    }

    @Test func realToVirtualMapsWithinSegments() {
        let m = twoSegmentMap()
        #expect(m.realToVirtual(1000) == 0)
        #expect(m.realToVirtual(1500) == 500)
        #expect(m.realToVirtual(5000) == 1000)
        #expect(m.realToVirtual(5500) == 1500)
    }

    @Test func realToVirtualCollapsesGapsToSeam() {
        let m = twoSegmentMap()
        // A real position inside the hidden gap collapses to the end of the
        // preceding segment (where the playhead sits while gap audio plays).
        #expect(m.realToVirtual(3000) == 1000)
        // Before the first segment -> start of the timeline.
        #expect(m.realToVirtual(0) == 0)
    }

    @Test func roundTripVirtualRealVirtualIsIdentity() {
        let m = twoSegmentMap()
        for v in [0, 1, 500, 999, 1000, 1500, 1999] {
            #expect(m.realToVirtual(m.virtualToReal(v)) == v)
        }
    }

    @Test func nextActiveRealStartOnlyFiresInGaps() {
        let m = twoSegmentMap()
        #expect(m.nextActiveRealStart(after: 0) == 1000)      // before first segment
        #expect(m.nextActiveRealStart(after: 1500) == nil)    // inside an active segment
        #expect(m.nextActiveRealStart(after: 3000) == 5000)   // inside the gap
        #expect(m.nextActiveRealStart(after: 6000) == nil)    // past the last segment
    }

    @Test func realSlicesSplitAVirtualSpanAcrossSegments() {
        let m = twoSegmentMap()
        let slices = m.realSlices(virtualStart: 500, virtualEnd: 1500)
        #expect(slices.count == 2)
        #expect(slices[0].real == 1500..<2000)
        #expect(slices[0].virtual == 500..<1000)
        #expect(slices[1].real == 5000..<5500)
        #expect(slices[1].virtual == 1000..<1500)
    }

    // MARK: Detection

    @Test func computeDetectsLoudRegionAsSingleSegment() {
        let bins = STFTGrid.binCount
        let nCols = 100
        var grid = [Float](repeating: -120, count: bins * nCols)   // bin-major
        // Columns 40..<60 loud across all bins.
        for bin in 0..<bins {
            for col in 40..<60 { grid[bin * nCols + col] = 0 }
        }
        let map = SilenceMap.compute(grid: grid, nCols: nCols, binCount: bins,
                                     totalSamples: 100_000, sampleRate: 384_000,
                                     sensitivity: 0.5, minFreqHz: 0, padSeconds: 0)
        #expect(map.segments.count == 1)
        // samplesPerCol = 1000; one column of pad each side -> ~[39k, 61k).
        #expect(map.segments[0].realStart == 39_000)
        #expect(map.segments[0].realEnd == 61_000)
        #expect(map.virtualTotal == 22_000)
        #expect(map.realTotal == 100_000)
    }

    @Test func computeFallsBackToWholeFileWhenNothingClearsThreshold() {
        let bins = STFTGrid.binCount
        let nCols = 50
        let grid = [Float](repeating: -120, count: bins * nCols)   // all quiet
        let map = SilenceMap.compute(grid: grid, nCols: nCols, binCount: bins,
                                     totalSamples: 50_000, sampleRate: 384_000,
                                     sensitivity: 0.5, minFreqHz: 0, padSeconds: 0)
        #expect(map.segments.count == 1)
        #expect(map.segments[0].realStart == 0)
        #expect(map.segments[0].realEnd == 50_000)
        #expect(map.virtualTotal == 50_000)
    }

    /// The regression guard for "the slider did nothing": a relative
    /// threshold must make higher sensitivity hide strictly more.
    @Test func higherSensitivityHidesMore() {
        let bins = STFTGrid.binCount
        let nCols = 100
        var grid = [Float](repeating: 0, count: bins * nCols)
        // Three tiers: deep silence, mid-level, loud.
        for bin in 0..<bins {
            for col in 0..<40 { grid[bin * nCols + col] = -100 }
            for col in 40..<70 { grid[bin * nCols + col] = -50 }
            for col in 70..<100 { grid[bin * nCols + col] = 0 }
        }
        func virtualTotal(_ s: Double) -> Int {
            SilenceMap.compute(grid: grid, nCols: nCols, binCount: bins,
                               totalSamples: 100_000, sampleRate: 384_000,
                               sensitivity: s, minFreqHz: 0, padSeconds: 0).virtualTotal
        }
        #expect(virtualTotal(0.8) < virtualTotal(0.2))
    }

    @Test func computeMergesNearbyRegionsViaPadding() {
        let bins = STFTGrid.binCount
        let nCols = 100
        var grid = [Float](repeating: -120, count: bins * nCols)
        // Two loud runs with a 4-column gap — a generous pad should merge them.
        for bin in 0..<bins {
            for col in 20..<30 { grid[bin * nCols + col] = 0 }
            for col in 34..<44 { grid[bin * nCols + col] = 0 }
        }
        // samplesPerCol = 1000, padSeconds 0.01 @384k = 3840 samples ~ 4 cols.
        let map = SilenceMap.compute(grid: grid, nCols: nCols, binCount: bins,
                                     totalSamples: 100_000, sampleRate: 384_000,
                                     sensitivity: 0.5, minFreqHz: 0, padSeconds: 0.01)
        #expect(map.segments.count == 1)
    }
}
