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

    /// Basic forward mapping, including the seam between two segments.
    @Test func virtualToRealMapsWithinAndAcrossSegments() {
        let m = twoSegmentMap()
        #expect(m.virtualToReal(0) == 1000)
        #expect(m.virtualToReal(999) == 1999)
        #expect(m.virtualToReal(1000) == 5000)   // seam: first virtual of segment 1
        #expect(m.virtualToReal(1999) == 5999)
    }

    /// A virtual position outside the map's range must clamp, not crash or
    /// extrapolate into an invalid real sample.
    @Test func virtualToRealClampsOutOfRange() {
        let m = twoSegmentMap()
        #expect(m.virtualToReal(-50) == 1000)
        #expect(m.virtualToReal(999_999) == 6000)   // clamped to virtualTotal -> last real
    }

    /// Basic reverse mapping within active segments.
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

    /// The two directions must be true inverses of each other on active
    /// positions, or the playhead drifts as it maps back and forth.
    @Test func roundTripVirtualRealVirtualIsIdentity() {
        let m = twoSegmentMap()
        for v in [0, 1, 500, 999, 1000, 1500, 1999] {
            #expect(m.realToVirtual(m.virtualToReal(v)) == v)
        }
    }

    /// What playback actually walks — the pacing thread reads these ranges
    /// and nothing between them (see PlaybackDriver.start's `regions`).
    @Test func realRegionsAreTheSegmentsPlaybackReads() {
        let m = twoSegmentMap()
        #expect(m.realRegions == [1000..<2000, 5000..<6000])
        #expect(m.keptFraction == 2000.0 / 7000.0)
    }

    /// A virtual span crossing a segment boundary must split into the
    /// correct real-domain pieces, for tile stitching across a hidden gap.
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

    /// A single loud region in an otherwise quiet grid becomes one segment
    /// with the expected padding.
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
                                     thresholdAboveFloorDB: 12, minFreqHz: 0, padSeconds: 0)
        #expect(map.segments.count == 1)
        // samplesPerCol = 1000; one column of pad each side -> ~[39k, 61k).
        #expect(map.segments[0].realStart == 39_000)
        #expect(map.segments[0].realEnd == 61_000)
        #expect(map.virtualTotal == 22_000)
        #expect(map.realTotal == 100_000)
    }

    /// A recording with nothing loud enough to hide-silence against must
    /// fall back to showing the whole file, not collapse to nothing.
    @Test func computeFallsBackToWholeFileWhenNothingClearsThreshold() {
        let bins = STFTGrid.binCount
        let nCols = 50
        let grid = [Float](repeating: -120, count: bins * nCols)   // all quiet
        let map = SilenceMap.compute(grid: grid, nCols: nCols, binCount: bins,
                                     totalSamples: 50_000, sampleRate: 384_000,
                                     thresholdAboveFloorDB: 12, minFreqHz: 0, padSeconds: 0)
        #expect(map.segments.count == 1)
        #expect(map.segments[0].realStart == 0)
        #expect(map.segments[0].realEnd == 50_000)
        #expect(map.virtualTotal == 50_000)
    }

    /// The regression guard for "the slider did nothing": raising the
    /// threshold must hide strictly more.
    @Test func higherThresholdHidesMore() {
        let bins = STFTGrid.binCount
        let nCols = 100
        var grid = [Float](repeating: 0, count: bins * nCols)
        // Three tiers: deep silence, mid-level, loud.
        for bin in 0..<bins {
            for col in 0..<40 { grid[bin * nCols + col] = -100 }
            for col in 40..<70 { grid[bin * nCols + col] = -70 }
            for col in 70..<100 { grid[bin * nCols + col] = 0 }
        }
        func virtualTotal(_ dB: Double) -> Int {
            SilenceMap.compute(grid: grid, nCols: nCols, binCount: bins,
                               totalSamples: 100_000, sampleRate: 384_000,
                               thresholdAboveFloorDB: dB, minFreqHz: 0, padSeconds: 0).virtualTotal
        }
        // 12 dB over the floor keeps the mid tier as well as the loud one;
        // 40 dB keeps only the loud one.
        #expect(virtualTotal(40) < virtualTotal(12))
    }

    /// Two loud runs close enough together must merge into one segment via
    /// padding, rather than leaving a flickering sliver of hidden gap.
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
                                     thresholdAboveFloorDB: 12, minFreqHz: 0, padSeconds: 0.01)
        #expect(map.segments.count == 1)
    }

    /// A one-column blip is shorter than any bat call — a handling knock, a
    /// switch, a clipped sample. Before the minimum-duration floor each one
    /// became its own padded region, so the compressed timeline filled with
    /// chunks of noise the user could see were not calls.
    @Test func singleColumnTicksAreNotKept() {
        let bins = STFTGrid.binCount
        let nCols = 100
        // 384 samples per column, so the 3 ms floor is 3 columns.
        let totalSamples = 38_400
        var grid = [Float](repeating: -120, count: bins * nCols)
        for bin in 0..<bins {
            grid[bin * nCols + 10] = 0                                  // a tick
            for col in 50..<60 { grid[bin * nCols + col] = 0 }          // a real call
        }
        let map = SilenceMap.compute(grid: grid, nCols: nCols, binCount: bins,
                                     totalSamples: totalSamples, sampleRate: 384_000,
                                     thresholdAboveFloorDB: 12, minFreqHz: 0, padSeconds: 0)
        #expect(map.segments.count == 1)
        // The call, padded one column each side — not the tick at column 10.
        #expect(map.segments[0].realStart == 49 * 384)
        #expect(map.segments[0].realEnd == 61 * 384)
    }

    /// The regression guard for the threshold's old top anchor: it
    /// interpolated up to the file's LOUDEST column, so one broadband
    /// artifact dragged the cut above every real call in the recording and
    /// hid the lot. Anchored to the noise floor alone, the artifact has no
    /// say in where the threshold sits.
    @Test func oneLoudArtifactDoesNotHideFaintCalls() {
        let bins = STFTGrid.binCount
        let nCols = 100
        let totalSamples = 38_400
        var grid = [Float](repeating: -120, count: bins * nCols)
        for bin in 0..<bins {
            for col in 20..<40 { grid[bin * nCols + col] = -70 }        // faint calls
            for col in 80..<83 { grid[bin * nCols + col] = 0 }          // a loud knock
        }
        let map = SilenceMap.compute(grid: grid, nCols: nCols, binCount: bins,
                                     totalSamples: totalSamples, sampleRate: 384_000,
                                     thresholdAboveFloorDB: 12, minFreqHz: 0, padSeconds: 0)
        // Both survive: the faint calls are kept, not swamped by the knock.
        #expect(map.segments.count == 2)
        #expect(map.segments[0].realStart == 19 * 384)
        #expect(map.segments[0].realEnd == 41 * 384)
    }

    /// "Found nothing" and "kept everything" produce the same single
    /// whole-file segment and were indistinguishable to the UI, so the toggle
    /// looked broken in the first case. The flag is what tells them apart.
    @Test func fallbackIsFlaggedButARealDetectionIsNot() {
        let bins = STFTGrid.binCount
        let nCols = 50
        let quiet = [Float](repeating: -120, count: bins * nCols)
        let quietMap = SilenceMap.compute(grid: quiet, nCols: nCols, binCount: bins,
                                          totalSamples: 50_000, sampleRate: 384_000,
                                          thresholdAboveFloorDB: 12, minFreqHz: 0, padSeconds: 0)
        #expect(quietMap.isFallback)

        var loud = quiet
        for bin in 0..<bins {
            for col in 20..<30 { loud[bin * nCols + col] = 0 }
        }
        let loudMap = SilenceMap.compute(grid: loud, nCols: nCols, binCount: bins,
                                         totalSamples: 50_000, sampleRate: 384_000,
                                         thresholdAboveFloorDB: 12, minFreqHz: 0, padSeconds: 0)
        #expect(!loudMap.isFallback)
        #expect(SilenceMap.wholeFile(totalSamples: 100).isFallback == false)
    }
}
