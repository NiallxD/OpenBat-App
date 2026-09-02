//
//  SpectrogramPyramid.swift
//  OpenBat
//
//  The tile grid the WAV player's spectrogram is built from — fixed zoom
//  levels, fixed tile boundaries, addressed by (level, index) the way map
//  software addresses (z, x, y).
//
//  **Why fixed, when the thing it replaces rendered exactly what was on
//  screen.** A tile centred on the viewport is invalidated the moment the
//  viewport moves, so every pan and every step of playback produced a fresh,
//  bespoke render overlapping the last one, and nothing could ever be reused
//  — the player recomputed overlapping views of the same audio continuously,
//  which is what all the buffering and re-rendering churn actually was. A
//  tile on a fixed boundary is only invalidated when you leave it, is
//  identical whoever asks for it, and can therefore be cached.
//
//  Scale matters here and it is small: a recording is one bat pass, a few
//  seconds to at most ~30. At playback zoom the WHOLE recording is a few tens
//  of tiles, so after the first fill nothing needs rendering again — no
//  buffering on playback, on scrubbing back, or on replaying.
//
//  Levels are powers of two in samples-per-column, anchored at the native
//  analysis hop, so a level is always an exact pooling of the level below it
//  and no level is ever asked for detail the STFT cannot supply.
//

import Foundation

nonisolated enum SpectrogramPyramid {

    /// Columns in one tile, at every level. 2048 is a compromise: wide enough
    /// that a viewport usually needs two or three tiles rather than a dozen,
    /// narrow enough that one tile is a bounded 2 MB of stored dB and a
    /// bounded unit of work to render.
    static let tileColumns = 2048

    /// Samples per column at the finest level — the native STFT hop, so
    /// level 0 is the most detail the analysis can produce and asking for
    /// more is meaningless (see `STFTGrid.effectiveHop`).
    static let finestSamplesPerColumn = STFTGrid.hop

    /// How many levels exist. 9 spans 32 to 8192 samples per column, which at
    /// 384 kHz is 12 000 down to 47 columns a second — the top level's single
    /// tile covers 43 s, so even the longest recording has a whole-file level.
    static let levelCount = 9

    /// Samples of audio each column of `level` covers. Level 0 is finest.
    static func samplesPerColumn(level: Int) -> Int {
        finestSamplesPerColumn << clampLevel(level)
    }

    /// Samples of audio one tile of `level` covers.
    static func tileSamples(level: Int) -> Int {
        tileColumns * samplesPerColumn(level: level)
    }

    static func clampLevel(_ level: Int) -> Int {
        min(max(level, 0), levelCount - 1)
    }

    /// The coarsest level that still puts at least `targetColumns` across
    /// `spanSamples`.
    ///
    /// Coarsest, not finest: a finer level would be more tiles, more memory
    /// and more work for detail the screen cannot show. Picking by "at least
    /// as many columns as asked for" is what keeps a tile's own density
    /// honest — the thing the old centred renders got wrong when they reused
    /// a wide tile's coarse columns for a much narrower viewport.
    static func level(forSpanSamples spanSamples: Int, targetColumns: Int) -> Int {
        guard spanSamples > 0, targetColumns > 0 else { return 0 }
        let wanted = Double(spanSamples) / Double(targetColumns)
        guard wanted > Double(finestSamplesPerColumn) else { return 0 }
        let steps = Int(log2(wanted / Double(finestSamplesPerColumn)).rounded(.down))
        return clampLevel(steps)
    }

    /// The tile of `level` that `sample` falls in.
    static func tileIndex(level: Int, sample: Int) -> Int {
        let span = tileSamples(level: level)
        return Int(floor(Double(max(sample, 0)) / Double(span)))
    }

    /// Every tile of `level` needed to cover `[startSample, endSample)`.
    static func tileIndices(level: Int, startSample: Int, endSample: Int) -> ClosedRange<Int> {
        let lo = tileIndex(level: level, sample: max(startSample, 0))
        let hi = tileIndex(level: level, sample: max(endSample - 1, 0))
        return lo...max(lo, hi)
    }

    /// The real sample range one tile covers. Independent of the recording,
    /// so two viewports asking for the same tile get byte-identical bounds —
    /// which is the whole point of a fixed grid.
    static func sampleRange(level: Int, index: Int) -> Range<Int> {
        let span = tileSamples(level: level)
        let start = index * span
        return start..<(start + span)
    }

    /// Identifies one tile. Value-typed and hashable so it can key a cache
    /// directly.
    struct Key: Hashable {
        let level: Int
        let index: Int
    }
}
