//
//  SpectrogramPyramidTests.swift
//  OpenBatTests
//
//  The tile grid's whole value rests on one property — that a tile's identity
//  and bounds depend ONLY on (level, index), never on the viewport that asked
//  for it. That is what makes tiles cacheable and reusable, and it is exactly
//  what the centred-render scheme it replaces could not offer.
//

import Testing
import Foundation
@testable import OpenBat

struct SpectrogramPyramidTests {

    /// Levels are powers of two in samples-per-column, anchored at the native
    /// analysis hop — so a level is always an exact pooling of the one below
    /// and no level asks the STFT for detail it cannot supply.
    @Test func levelsArePowersOfTwoFromTheNativeHop() {
        #expect(SpectrogramPyramid.samplesPerColumn(level: 0) == STFTGrid.hop)
        for level in 1..<SpectrogramPyramid.levelCount {
            #expect(SpectrogramPyramid.samplesPerColumn(level: level)
                    == SpectrogramPyramid.samplesPerColumn(level: level - 1) * 2)
        }
    }

    /// Out-of-range levels clamp rather than producing a nonsense stride.
    @Test func levelsClamp() {
        #expect(SpectrogramPyramid.samplesPerColumn(level: -3) == STFTGrid.hop)
        #expect(SpectrogramPyramid.samplesPerColumn(level: 999)
                == SpectrogramPyramid.samplesPerColumn(level: SpectrogramPyramid.levelCount - 1))
    }

    /// The level chosen for a viewport must always supply AT LEAST the
    /// columns asked for — never fewer, or the picture is stretched, which is
    /// the "blurry at some zoom levels" failure the old path kept hitting.
    @Test func chosenLevelAlwaysSuppliesEnoughColumns() {
        let target = 2048
        // A second of 384 kHz audio down to a few milliseconds of it.
        for spanSamples in [384_000, 192_000, 76_800, 38_400, 8_192, 2_048] {
            let level = SpectrogramPyramid.level(forSpanSamples: spanSamples, targetColumns: target)
            let columns = spanSamples / SpectrogramPyramid.samplesPerColumn(level: level)
            #expect(columns >= target || level == 0,
                    "span \(spanSamples) chose level \(level), giving \(columns) columns for a target of \(target)")
        }
    }

    /// ...and must not be needlessly fine, which would be more tiles, more
    /// memory and more work for detail the screen cannot show.
    @Test func chosenLevelIsNotFinerThanNeeded() {
        let target = 2048
        let span = 384_000
        let level = SpectrogramPyramid.level(forSpanSamples: span, targetColumns: target)
        guard level < SpectrogramPyramid.levelCount - 1 else { return }
        let coarser = span / SpectrogramPyramid.samplesPerColumn(level: level + 1)
        #expect(coarser < target,
                "level \(level + 1) would still have supplied \(coarser) columns — level \(level) is finer than necessary")
    }

    /// **The property the whole design rests on.** Two different viewports
    /// that overlap the same audio must be handed the SAME tiles, with the
    /// same bounds — otherwise nothing can be cached and every view change is
    /// a fresh render, which is what the old centred tiles did.
    @Test func tileBoundsDependOnlyOnLevelAndIndex() {
        let level = 3
        let a = SpectrogramPyramid.tileIndices(level: level, startSample: 500_000, endSample: 900_000)
        let b = SpectrogramPyramid.tileIndices(level: level, startSample: 700_000, endSample: 1_100_000)
        let shared = Set(a).intersection(Set(b))
        #expect(!shared.isEmpty, "overlapping viewports shared no tiles")
        for index in shared {
            let range = SpectrogramPyramid.sampleRange(level: level, index: index)
            #expect(range.count == SpectrogramPyramid.tileSamples(level: level))
            // And the bounds are a function of the index alone.
            #expect(range.lowerBound == index * SpectrogramPyramid.tileSamples(level: level))
        }
    }

    /// Tiles tile: consecutive indices abut exactly, with no gap and no
    /// overlap, or the assembled image would have seams or duplicated audio.
    @Test func consecutiveTilesAbutExactly() {
        for level in 0..<SpectrogramPyramid.levelCount {
            for index in 0..<4 {
                let here = SpectrogramPyramid.sampleRange(level: level, index: index)
                let next = SpectrogramPyramid.sampleRange(level: level, index: index + 1)
                #expect(here.upperBound == next.lowerBound)
            }
        }
    }

    /// **The seam guard.** A tile's columns must cover its declared bounds
    /// exactly, with no shortfall — an STFT frame covers `windowLen` samples
    /// from where it starts, so the last frame that fits inside a span begins
    /// `windowLen` short of its end. Rendering a tile against its own bounds
    /// therefore leaves its final columns short, every tile ends up slightly
    /// time-compressed, and the error shows at every join as a visible seam
    /// (Niall, 2026-09-01). The renderer reads an overhang to prevent this;
    /// this asserts the arithmetic the overhang has to satisfy.
    @Test func aTilesFrameGridSpansItsWholeDeclaredRange() {
        for level in 0..<SpectrogramPyramid.levelCount {
            let spc = SpectrogramPyramid.samplesPerColumn(level: level)
            let tileSamples = SpectrogramPyramid.tileSamples(level: level)
            // What the renderer reads: the tile, plus a window less a hop.
            let readSpan = tileSamples + STFTGrid.windowLen - STFTGrid.hop
            let frames = 1 + (readSpan - STFTGrid.windowLen) / STFTGrid.hop
            // Enough frames for every column to pool a full `spc` of audio.
            #expect(frames >= tileSamples / STFTGrid.hop,
                    "level \(level): \(frames) frames cannot fill \(tileSamples / spc) columns of \(spc) samples")
            // And the pooling divides evenly, so no column straddles two.
            #expect(spc % STFTGrid.hop == 0)
        }
    }

    /// A span lying inside one tile needs exactly that tile.
    @Test func aSpanInsideOneTileNeedsOnlyThatTile() {
        let level = 4
        let span = SpectrogramPyramid.tileSamples(level: level)
        let indices = SpectrogramPyramid.tileIndices(level: level,
                                                     startSample: span + 10,
                                                     endSample: span + 20)
        #expect(indices.count == 1)
        #expect(indices.lowerBound == 1)
    }

    /// The top level exists so that even the longest recording has a level
    /// whose tiles span the whole file — that is the zoomed-out view.
    @Test func theTopLevelCoversAWholeRecordingInFewTiles() {
        let thirtySeconds = Int(384_000.0 * 30)
        let top = SpectrogramPyramid.levelCount - 1
        let indices = SpectrogramPyramid.tileIndices(level: top, startSample: 0, endSample: thirtySeconds)
        #expect(indices.count == 1, "a 30 s recording needed \(indices.count) tiles at the top level")
    }
}

/// The two ordering/coverage rules the playback buffer depends on, against a
/// real store built over a short generated recording — see
/// `WavSpectrogramView.refreshPyramidTile`.
struct SpectrogramTileStoreOrderTests {

    private func makeStore(seconds: Double) -> (SpectrogramTileStore, Int) {
        let sampleRate = 384_000.0
        let url = TestWavFactory.make(sampleRate: UInt32(sampleRate), seconds: seconds,
                                      toneFrequency: 40_000)
        let total = Int(sampleRate * seconds)
        let overview = WavSpectrogramEngine.renderRawTile(
            wavURL: url, startSample: 0, endSample: total, targetColumns: 512,
            calibrationCurve: nil)!
        let store = SpectrogramTileStore(
            wavURL: url, sampleRate: sampleRate, totalSamples: total, calibrationCurve: nil,
            contrast: SpectrogramContrast(overview: overview, sampleRate: sampleRate,
                                          binCount: STFTGrid.binCount))
        return (store, total)
    }

    /// Nothing behind the playhead may be rendered before everything in front
    /// of it — plain index order built the first thing needed last.
    @Test func fillOrderRunsForwardFromThePlayheadFirst() {
        let (store, total) = makeStore(seconds: 1.0)
        let level = 0
        let tile = SpectrogramPyramid.tileSamples(level: level)
        let pivot = tile * 3
        let keys = store.missingTilesFromPlayhead(level: level, startSample: 0,
                                                  endSample: min(total, tile * 6), pivot: pivot)
        let here = SpectrogramPyramid.tileIndex(level: level, sample: pivot)
        #expect(keys.first?.index == here)
        let firstBehind = keys.firstIndex { $0.index < here } ?? keys.count
        let lastAhead = keys.lastIndex { $0.index >= here } ?? -1
        #expect(lastAhead < firstBehind)
    }

    /// A picture must be available as soon as the tiles UNDER the frame exist,
    /// regardless of whether the runway beyond them has rendered — the
    /// all-or-nothing lead requirement is what left the view blurry with the
    /// tiles it needed already cached.
    @Test func coverageDoesNotWaitForTheRunway() {
        let (store, _) = makeStore(seconds: 1.0)
        let level = 0
        let tile = SpectrogramPyramid.tileSamples(level: level)
        // Exactly the two tiles under a frame, and nothing beyond them.
        for index in 0...1 {
            _ = store.picture(for: SpectrogramPyramid.Key(level: level, index: index),
                              palette: .inferno, noiseFloor: 0.4)
        }
        let assembled = store.assembleCovering(level: level, requiredStart: 0,
                                               requiredEnd: tile + 10, maxTiles: 8,
                                               palette: .inferno, noiseFloor: 0.4)
        #expect(assembled != nil)
        #expect(assembled!.startSample <= 0)
        #expect(assembled!.endSample >= tile + 10)

        // And a frame reaching into a tile that does NOT exist yet has to fail,
        // rather than silently showing a short image stretched across it.
        let past = store.assembleCovering(level: level, requiredStart: 0,
                                          requiredEnd: tile * 4, maxTiles: 8,
                                          palette: .inferno, noiseFloor: 0.4)
        #expect(past == nil)
    }

    /// A frame whose sharp tiles have not landed must come back at a COARSER
    /// level rather than not at all. Returning nil there is what dropped the
    /// picture all the way to the whole-file overview crop — a ~25x collapse in
    /// column density, seen as the spectrogram going suddenly blurry the moment
    /// the playhead crossed into new ground.
    @Test func aMissingSharpTileFallsBackOneLevelNotToNothing() {
        let (store, _) = makeStore(seconds: 1.0)
        let sharp = 0, coarse = 2
        let frameEnd = SpectrogramPyramid.tileSamples(level: sharp) * 3

        // Only the coarse level is cached — exactly the state crossing into
        // unrendered ground leaves, now that the fill renders coarse first.
        for index in SpectrogramPyramid.tileIndices(level: coarse, startSample: 0, endSample: frameEnd) {
            _ = store.picture(for: SpectrogramPyramid.Key(level: coarse, index: index),
                              palette: .inferno, noiseFloor: 0.4)
        }
        #expect(store.assembleCovering(level: sharp, requiredStart: 0, requiredEnd: frameEnd,
                                       maxTiles: 8, palette: .inferno, noiseFloor: 0.4) == nil)

        let best = store.assembleBestCovering(preferredLevel: sharp, requiredStart: 0,
                                              requiredEnd: frameEnd, maxTiles: 8, coarserLevels: 2,
                                              palette: .inferno, noiseFloor: 0.4)
        #expect(best != nil)
        #expect(best?.level == coarse)
        #expect(best!.tile.startSample <= 0)
        #expect(best!.tile.endSample >= frameEnd)
    }

    /// And once the sharp tiles do land, the ladder must stop using the
    /// fallback — otherwise the picture would soften on the first miss and
    /// never recover, which is worse than the cliff it replaces.
    @Test func theSharpLevelWinsBackAsSoonAsItIsCached() {
        let (store, _) = makeStore(seconds: 1.0)
        let sharp = 0
        let frameEnd = SpectrogramPyramid.tileSamples(level: sharp)
        for index in SpectrogramPyramid.tileIndices(level: sharp, startSample: 0, endSample: frameEnd) {
            _ = store.picture(for: SpectrogramPyramid.Key(level: sharp, index: index),
                              palette: .inferno, noiseFloor: 0.4)
        }
        let best = store.assembleBestCovering(preferredLevel: sharp, requiredStart: 0,
                                              requiredEnd: frameEnd, maxTiles: 8, coarserLevels: 2,
                                              palette: .inferno, noiseFloor: 0.4)
        #expect(best?.level == sharp)
    }
}
