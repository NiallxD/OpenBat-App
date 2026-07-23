//
//  WavSpectrogramEngine.swift
//  OpenBat
//
//  Offline, static spectrogram rendering for the whole-file WAV player — no
//  live/ring-buffer state, no @MainActor UI. ONE pipeline (STFTGrid's
//  disk-native pooling + `colorize` below) drives both tiers this still
//  renders at, matching the memory analysis behind this rebuild (a raw,
//  unpooled STFT grid at native resolution is only feasible for a few
//  seconds of audio — see STFTGrid.swift's doc comment):
//
//    • `renderOverview` — a whole-file grid pooled to `maxWidth` columns,
//      computed once per file open and kept resident for the zoomed-out
//      display, the minimap, and as a live-drag crop source at ANY zoom
//      level (a detail tile only ever has pixel data for its own fixed,
//      already-committed bounds — an active drag needs something with
//      full-file coverage to crop from arbitrarily).
//    • `renderDetailTile` — a fresh render of just the CURRENTLY VISIBLE
//      viewport, re-run every time it settles after a zoom/pan gesture, for
//      when the overview's own column density isn't enough to show fine
//      FM-sweep detail at the current zoom (see `WavSpectrogramView.
//      needsDetailTile`). Bounded to O(targetColumns) regardless of the
//      viewport's span — same as the overview.
//
//  An earlier version of this used TWO separate pipelines: this one
//  (STFTGrid, disk-native only for small spans) for detail tiles, and a
//  completely different one (RecordingSpectrogramRenderer +
//  SpectrogramProcessor — different FFT hop, different normalization
//  scheme) for the overview, because STFTGrid's own PCM read used to
//  bulk-load its whole requested span first — fine for a small, zoomed-in
//  tile, but hundreds of MB for a whole-file span. That's what made the
//  overview and a detail tile look visibly different and swap jarringly
//  when one replaced the other. `STFTGrid.streamPooledGridFromFile` reading
//  PCM directly off disk per sampled frame (bounded regardless of span) is
//  what removed the reason for two pipelines to exist at all — see its own
//  doc comment.
//
//  Bin count (1024) is shared by both tiers, so a detail tile is never
//  coarser on the frequency axis than the overview crop it replaces (an
//  earlier version used 512 bins specifically for detail tiles, which made
//  zooming in visibly *lose* frequency resolution — the opposite of what
//  "zoom in" should do).
//

import UIKit
import Accelerate

nonisolated enum WavSpectrogramEngine {

    private static let dynamicRangeDB: Float = 48
    /// Absolute reference below which a tile's own peak is treated as "no
    /// real signal here, just ambient noise" — matches
    /// `SpectrogramProcessor.minCeilingDB`, the same threshold already
    /// calibrated elsewhere in this codebase for exactly this distinction
    /// ("a real bat call comfortably clears this; ambient noise shouldn't" —
    /// see that property's own doc comment). Both STFTGrid and
    /// SpectrogramProcessor compute dB the same way (20·log10 of a magnitude
    /// normalized by the same fftLen/fftSize=2048), so the same absolute
    /// number is meaningful across both. Used below to stop `colorize` from
    /// peak-relative-stretching a call-free tile's own noise floor to full
    /// display contrast — the "zoomed into empty space renders as pure
    /// noise" bug.
    private static let absoluteSignalFloorDB: Float = -40
    /// Default overview width — matches what the old
    /// RecordingSpectrogramRenderer-based overview used, kept for visual
    /// continuity (and as the default in `renderOverview`'s test-covered
    /// signature).
    static let defaultOverviewColumns = 4096

    // MARK: Raw grid (shared by both tiers)

    /// The expensive half of a render — PCM file IO plus the actual STFT
    /// (`STFTGrid.streamPooledGridFromFile`) — split out from `colorize`
    /// below so a change that only affects the pixel mapping (noise floor,
    /// palette) can reuse an already-computed grid instead of re-reading PCM
    /// and re-running the FFT just to recolor the same data. Neither the
    /// noise floor nor the palette feeds into this step at all. Safe to call
    /// with `[startSample, endSample)` spanning the WHOLE file — see
    /// `streamPooledGridFromFile`'s doc comment for why that no longer risks
    /// an unbounded read.
    struct RawTile {
        let grid: [Float]   // row-major [bin*nCols+col], RAW (non peak-normalized) dB
        let nCols: Int
        let startSample: Int
        let endSample: Int   // exclusive
    }

    static func renderRawTile(wavURL: URL, startSample: Int, endSample: Int, targetColumns: Int) -> RawTile? {
        guard endSample > startSample, targetColumns > 0 else { return nil }
        var scratch = STFTGrid.Scratch()
        guard let (rawDBGrid, nCols) = STFTGrid.streamPooledGridFromFile(
            wavURL: wavURL, startSample: startSample, endSample: endSample,
            targetColumns: targetColumns, scratch: &scratch)
        else { return nil }
        return RawTile(grid: rawDBGrid, nCols: nCols, startSample: startSample, endSample: endSample)
    }

    // MARK: Colorize (shared by both tiers)

    struct DetailTile {
        let image: UIImage
        let startSample: Int
        let endSample: Int          // exclusive
        let minFreqHz: Double       // actual rendered crop (may be clamped from the request)
        let maxFreqHz: Double
    }

    /// The cheap half — crops `raw` to `[minFreqHz, maxFreqHz]`, peak-relative
    /// normalizes over just that cropped bin range (zooming into a narrow
    /// high frequency band still gets full dynamic range, rather than being
    /// washed out by louder energy elsewhere in the spectrum that isn't even
    /// being displayed — clamped by `absoluteSignalFloorDB` when there's no
    /// real signal in view at all, see its own doc comment), gates by
    /// `noiseFloor`, and colorizes via a precomputed LUT (see
    /// `DisplayColormap.makeLUT`'s doc comment — this used to take 700ms+ per
    /// tile via a naive per-pixel dictionary lookup). Pure array math over an
    /// already-computed grid — no file IO, no FFT — so this is cheap enough
    /// to re-run on every noise-floor/palette tick.
    static func colorize(_ raw: RawTile, sampleRate: Double, minFreqHz: Double, maxFreqHz: Double,
                         palette: Palette, noiseFloor: Float) -> DetailTile? {
        let nCols = raw.nCols
        let bins = STFTGrid.binCount
        let hzPerBin = (sampleRate / 2) / Double(bins)
        let minBin = min(max(Int(minFreqHz / hzPerBin), 0), bins - 1)
        let maxBin = min(max(Int(maxFreqHz / hzPerBin), minBin), bins - 1)
        let croppedBins = maxBin - minBin + 1

        var maxDB: Float = -.greatestFiniteMagnitude
        raw.grid.withUnsafeBufferPointer { g in
            for bin in minBin...maxBin {
                var rowMax: Float = 0
                vDSP_maxv(g.baseAddress! + bin * nCols, 1, &rowMax, vDSP_Length(nCols))
                if rowMax > maxDB { maxDB = rowMax }
            }
        }
        // Clamp the normalization ceiling up to `absoluteSignalFloorDB` when
        // the tile's own peak doesn't clear it — a call-free view's loudest
        // point is just noise-floor variation, and peak-relative-stretching
        // THAT to full contrast (using `maxDB` directly, unconditionally, as
        // an earlier version did) is the "renders as pure noise" bug. When a
        // real call IS present (maxDB already clears the floor), this is a
        // no-op.
        let ceilingDB = max(maxDB, Self.absoluteSignalFloorDB)
        let minDB = ceilingDB - dynamicRangeDB
        let invRange = 1.0 / dynamicRangeDB

        let floor = min(max(noiseFloor, 0), 0.99)
        let invSpan = 1 / max(0.01, 1 - floor)

        // Normalize + gate + LUT-index in one fused linear map per bin row via
        // vDSP, then a trivial UInt32 gather per pixel — replaces the previous
        // scalar per-pixel loop, which was the single largest measured cost in
        // the whole tile pipeline (a 6k-column tile took 1.6-5.2s here on
        // device; the FFT+file-IO half of the same render was ~150ms). The
        // fused map is exactly equivalent to the old two-step
        // clamp(norm)->gate composition: both are linear with clips only at
        // the shared [0, 1] endpoints, so composing the slopes/intercepts and
        // clipping once at the end lands every value in the same LUT slot
        // (including the same Int truncation, via vDSP_vfixu8).
        let lut = DisplayColormap.makeLUT(palette: palette)
        let lutSteps = lut.count
        var lut32 = [UInt32](repeating: 0, count: lutSteps)
        for i in 0..<lutSteps {
            let (r, g, b) = lut[i]
            // Little-endian byte order r,g,b,a — identical memory layout to the
            // old per-byte writes, so the CGImage bitmapInfo below is unchanged.
            lut32[i] = UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) | 0xFF00_0000
        }

        var slope = invRange * invSpan * Float(lutSteps - 1)
        var intercept = ((-minDB) * invRange - floor) * invSpan * Float(lutSteps - 1)
        var lo: Float = 0
        var hi = Float(lutSteps - 1)

        var pixels = [UInt32](repeating: 0, count: nCols * croppedBins)
        var tmpRow = [Float](repeating: 0, count: nCols)
        var idxRow = [UInt8](repeating: 0, count: nCols)
        raw.grid.withUnsafeBufferPointer { g in
            pixels.withUnsafeMutableBufferPointer { px in
                lut32.withUnsafeBufferPointer { lutBuf in
                    for bin in minBin...maxBin {
                        let src = g.baseAddress! + bin * nCols
                        vDSP_vsmsa(src, 1, &slope, &intercept, &tmpRow, 1, vDSP_Length(nCols))
                        vDSP_vclip(tmpRow, 1, &lo, &hi, &tmpRow, 1, vDSP_Length(nCols))
                        tmpRow.withUnsafeBufferPointer { t in
                            idxRow.withUnsafeMutableBufferPointer { ix in
                                vDSP_vfixu8(t.baseAddress!, 1, ix.baseAddress!, 1, vDSP_Length(nCols))
                            }
                        }
                        let dstBase = (maxBin - bin) * nCols   // row 0 = top = high frequency
                        for col in 0..<nCols {
                            px[dstBase + col] = lutBuf[Int(idxRow[col])]
                        }
                    }
                }
            }
        }

        let pixelData = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard
            let provider = CGDataProvider(data: pixelData as CFData),
            let cgImage = CGImage(
                width: nCols, height: croppedBins,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: nCols * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }

        return DetailTile(image: UIImage(cgImage: cgImage),
                          startSample: raw.startSample, endSample: raw.endSample,
                          minFreqHz: Double(minBin) * hzPerBin,
                          maxFreqHz: Double(maxBin + 1) * hzPerBin)
    }

    /// Re-renders just `[startSample, endSample)` of `wavURL`, cropped to
    /// `[minFreqHz, maxFreqHz]`, pooled to at most `targetColumns` wide.
    /// Convenience wrapper over `renderRawTile` + `colorize` for callers that
    /// don't need to cache the raw grid themselves (tests, and any one-shot
    /// caller) — `WavSpectrogramView` calls the two steps separately so it
    /// can skip the expensive one on a noise-floor/palette-only change.
    static func renderDetailTile(wavURL: URL, sampleRate: Double,
                                 startSample: Int, endSample: Int,
                                 minFreqHz: Double, maxFreqHz: Double,
                                 targetColumns: Int, palette: Palette, noiseFloor: Float) -> DetailTile? {
        guard let raw = renderRawTile(wavURL: wavURL, startSample: startSample, endSample: endSample,
                                      targetColumns: targetColumns)
        else { return nil }
        return colorize(raw, sampleRate: sampleRate, minFreqHz: minFreqHz, maxFreqHz: maxFreqHz,
                        palette: palette, noiseFloor: noiseFloor)
    }

    // MARK: Hide-silence (compressed virtual timeline — see SilenceMap)

    /// Renders a detail tile for a span of the COMPRESSED virtual timeline
    /// by rendering each underlying real slice separately and concatenating
    /// their columns. The returned RawTile's `startSample`/`endSample` are
    /// VIRTUAL — every consumer (tile coverage checks, cropping, the
    /// viewport itself) operates purely in virtual samples while hide-
    /// silence is on, so the tile is a drop-in for `renderRawTile`'s output.
    static func renderRawTileStitched(wavURL: URL, virtualStart: Int, virtualEnd: Int,
                                      map: SilenceMap, targetColumns: Int) -> RawTile? {
        guard virtualEnd > virtualStart, targetColumns > 0 else { return nil }
        let slices = map.realSlices(virtualStart: virtualStart, virtualEnd: virtualEnd)
        guard !slices.isEmpty else { return nil }
        let bins = STFTGrid.binCount
        let totalVirtual = virtualEnd - virtualStart
        var scratch = STFTGrid.Scratch()
        var parts: [(grid: [Float], nCols: Int)] = []
        for slice in slices {
            let cols = max(1, Int((Double(targetColumns) * Double(slice.virtual.count)
                                   / Double(totalVirtual)).rounded()))
            if slice.real.count >= STFTGrid.windowLen,
               let (grid, nCols) = STFTGrid.streamPooledGridFromFile(
                    wavURL: wavURL, startSample: slice.real.lowerBound, endSample: slice.real.upperBound,
                    targetColumns: cols, scratch: &scratch) {
                parts.append((grid, nCols))
            } else {
                // A slice clipped at the viewport edge can be shorter than
                // one STFT window — stand in with silence-floor columns so
                // the stitched grid keeps its time geometry instead of
                // failing the whole tile.
                parts.append(([Float](repeating: -160, count: cols * bins), cols))
            }
        }
        let totalCols = parts.reduce(0) { $0 + $1.nCols }
        guard totalCols > 0 else { return nil }
        var grid = [Float](repeating: -160, count: bins * totalCols)
        var colOffset = 0
        grid.withUnsafeMutableBufferPointer { dst in
            for part in parts {
                part.grid.withUnsafeBufferPointer { src in
                    for bin in 0..<bins {
                        (dst.baseAddress! + bin * totalCols + colOffset)
                            .update(from: src.baseAddress! + bin * part.nCols, count: part.nCols)
                    }
                }
                colOffset += part.nCols
            }
        }
        return RawTile(grid: grid, nCols: totalCols, startSample: virtualStart, endSample: virtualEnd)
    }

    /// The compressed-timeline overview raw grid: the whole-file overview's
    /// columns with the silent gaps' columns dropped — pure column selection
    /// from the already-computed grid, no file IO or FFT. Bounds are
    /// virtual: `[0, map.virtualTotal)`.
    static func compressedOverviewRawTile(from raw: RawTile, map: SilenceMap) -> RawTile {
        let bins = STFTGrid.binCount
        let nCols = raw.nCols
        let total = max(map.realTotal, 1)
        // Per-segment source column ranges (clamped, at least one column each).
        var colRanges: [Range<Int>] = []
        for seg in map.segments {
            let c0 = min(max(Int(Double(seg.realStart) * Double(nCols) / Double(total)), 0), nCols - 1)
            let c1 = min(max(Int((Double(seg.realEnd) * Double(nCols) / Double(total)).rounded()), c0 + 1), nCols)
            colRanges.append(c0..<c1)
        }
        let outCols = colRanges.reduce(0) { $0 + $1.count }
        var grid = [Float](repeating: -160, count: bins * outCols)
        grid.withUnsafeMutableBufferPointer { dst in
            raw.grid.withUnsafeBufferPointer { src in
                var colOffset = 0
                for range in colRanges {
                    for bin in 0..<bins {
                        (dst.baseAddress! + bin * outCols + colOffset)
                            .update(from: src.baseAddress! + bin * nCols + range.lowerBound, count: range.count)
                    }
                    colOffset += range.count
                }
            }
        }
        return RawTile(grid: grid, nCols: outCols, startSample: 0, endSample: map.virtualTotal)
    }

    // MARK: Overview (whole file, same pipeline as a detail tile)

    struct Overview {
        /// The whole-file raw dB grid — kept around so a noise-floor/palette
        /// change recolors this directly (cheap) instead of re-reading PCM
        /// and re-running the FFT. `startSample`/`endSample` always span
        /// `[0, totalSamples)`.
        let rawTile: RawTile
        /// Colorized at whatever noise-floor/palette `renderOverview` was
        /// called with — kept in sync by the caller re-colorizing `rawTile`
        /// (see WavPlayerView.recolorOverviewIfPossible).
        var image: UIImage
        let sampleRate: Double
        let totalSamples: Int
        /// Nyquist frequency — top edge of the overview image's frequency axis.
        var maxFreqHz: Double { sampleRate / 2 }
    }

    /// Renders a whole-file overview — a `RawTile` spanning `[0,
    /// totalSamples)` pooled to at most `maxWidth` columns, colorized once at
    /// `palette`/`noiseFloor` for the initial paint. Bounded regardless of
    /// file length (see `STFTGrid.streamPooledGridFromFile`'s doc comment),
    /// so this is safe to compute fresh on every player open — there's no
    /// cached-JPEG fast path to fall back on anymore, because there's
    /// nothing left to make it worth the two-pipelines-with-different-looks
    /// tradeoff that fast path used to buy.
    static func renderOverview(wavURL: URL, maxWidth: Int = defaultOverviewColumns,
                               palette: Palette = .inferno, noiseFloor: Float = 0.5) -> Overview? {
        guard let header = WavHeader.read(url: wavURL) else { return nil }
        let totalSamples = Int(header.dataBytes) / 2
        guard totalSamples > 0,
              let raw = renderRawTile(wavURL: wavURL, startSample: 0, endSample: totalSamples, targetColumns: maxWidth)
        else { return nil }
        let sampleRate = Double(header.sampleRate)
        guard let tile = colorize(raw, sampleRate: sampleRate, minFreqHz: 0, maxFreqHz: sampleRate / 2,
                                 palette: palette, noiseFloor: noiseFloor)
        else { return nil }
        return Overview(rawTile: raw, image: tile.image, sampleRate: sampleRate, totalSamples: totalSamples)
    }
}
