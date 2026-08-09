//
//  WavSpectrogramEngine.swift
//  OpenBat
//
//  Offline, static spectrogram rendering for the whole-file WAV player — no
//  live/ring-buffer state, no @MainActor UI. ONE pipeline (STFTGrid's
//  disk-native pooling + `colorize` below) drives both tiers this renders
//  at. A raw, unpooled STFT grid at native resolution is only feasible for a
//  few seconds of audio (see STFTGrid.swift), and both tiers must share the
//  same pipeline and bin count (1024) or they look different and swap
//  jarringly when one replaces the other — see Context.md for what this
//  replaced (an older two-pipeline version) and why.
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

import UIKit
import Accelerate

nonisolated enum WavSpectrogramEngine {

    /// Matches `SpectrogramProcessor.dynamicRangeDB` — this tile's own
    /// per-column adaptive ceiling is otherwise the exact same AGC scheme
    /// (see the constants below), so a narrower window here than live used
    /// to clip quieter calls to pure black before the noise-floor slider
    /// ever saw them, regardless of the slider's value.
    private static let dynamicRangeDB: Float = 70
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
    /// Same "AGC release" `SpectrogramProcessor.runningCeilingDB` uses live, just
    /// expressed per SECOND instead of per column — a tile's own column density
    /// varies (an overview column can span many seconds; a detail tile's is
    /// ~1/12 000 s) so a fixed per-column decay can't mean the same thing in
    /// both. `colorize` converts this to a per-column step using each tile's own
    /// density before use. ≈ SpectrogramProcessor's 0.015 dB/column @ 1500 cols/s.
    private static let ceilingReleaseDBPerSecond: Float = 22.5
    /// A little air above the tracked peak, not pinned to pure white — matches
    /// `SpectrogramProcessor.ceilingHeadroomDB`.
    private static let ceilingHeadroomDB: Float = 3
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

    static func renderRawTile(wavURL: URL, startSample: Int, endSample: Int, targetColumns: Int,
                              calibrationCurve: MicCalibrationCurve? = nil) -> RawTile? {
        guard endSample > startSample, targetColumns > 0,
              endSample - startSample >= STFTGrid.windowLen
        else { return nil }
        var scratch = STFTGrid.Scratch()
        guard let (rawDBGrid, nCols) = STFTGrid.streamPooledGridFromFile(
            wavURL: wavURL, startSample: startSample, endSample: endSample,
            targetColumns: targetColumns, scratch: &scratch, calibrationCurve: calibrationCurve)
        else { return nil }
        // The pooled columns span the native STFT FRAME grid, whose last
        // frame STARTS `windowLen`-short of `endSample` — so the image
        // actually covers `[startSample, startSample + nFrames*hop)`, not the
        // full requested `[startSample, endSample)`. Reporting the real
        // covered span is what makes the display crop map column->sample
        // exactly (`(S-startSample)/coveredSpan * nCols == frame index`),
        // which in turn makes it agree with CallAnalysis's own frame->sample
        // maths — without it a detail tile drew features ~windowLen/2 off
        // near its centre (the "annotations / high-res tile don't line up"
        // bug), an error that scales with span so it was invisible on the
        // whole-file overview but visible on a zoomed-in tile.
        let nFrames = 1 + (endSample - startSample - STFTGrid.windowLen) / STFTGrid.hop
        let coveredEnd = startSample + nFrames * STFTGrid.hop
        return RawTile(grid: rawDBGrid, nCols: nCols, startSample: startSample, endSample: coveredEnd)
    }

    // MARK: Colorize (shared by both tiers)

    /// A colorized, ready-to-display render of some span of the file — either
    /// the whole-file overview or a zoomed-in detail tile; both are this same
    /// shape, produced by `colorize` below.
    struct DetailTile {
        let image: UIImage
        let startSample: Int
        let endSample: Int          // exclusive
        let minFreqHz: Double       // actual rendered crop (may be clamped from the request)
        let maxFreqHz: Double
    }

    /// The cheap half — crops `raw` to `[minFreqHz, maxFreqHz]`, tracks a
    /// per-COLUMN adaptive ceiling across the cropped bin range with the same
    /// decaying "AGC release" `SpectrogramProcessor` uses live (clamped by
    /// `absoluteSignalFloorDB` when there's no real signal at all — see its own
    /// doc comment), gates by `noiseFloor`, and colorizes via a precomputed LUT
    /// (see `DisplayColormap.makeLUT`'s doc comment — this used to take 700ms+
    /// per tile via a naive per-pixel dictionary lookup). Pure array math over
    /// an already-computed grid — no file IO, no FFT — so this is cheap enough
    /// to re-run on every noise-floor/palette tick.
    ///
    /// Per-column, not one scalar ceiling for the whole tile: a single loud
    /// noise burst anywhere in a multi-second tile used to pin the WHOLE tile's
    /// contrast to that burst's level, crushing quieter real calls elsewhere in
    /// the same tile/overview — the "even noiseFloor=0 barely shows calls" bug,
    /// and the reason this view could look much noisier than the live Detector
    /// screen's adaptive-ceiling spectrogram for the exact same recording.
    static func colorize(_ raw: RawTile, sampleRate: Double, minFreqHz: Double, maxFreqHz: Double,
                         palette: Palette, noiseFloor: Float) -> DetailTile? {
        let nCols = raw.nCols
        guard nCols > 0 else { return nil }
        let bins = STFTGrid.binCount
        let hzPerBin = (sampleRate / 2) / Double(bins)
        let minBin = min(max(Int(minFreqHz / hzPerBin), 0), bins - 1)
        let maxBin = min(max(Int(maxFreqHz / hzPerBin), minBin), bins - 1)
        let croppedBins = maxBin - minBin + 1

        // Column-wise max dB across the cropped bins — an elementwise running
        // max accumulated one bin-row at a time (vDSP_vmax), not a per-column
        // vDSP_maxv loop: same total work, far fewer (croppedBins, not nCols)
        // vDSP calls.
        var colMaxDB = [Float](repeating: Self.absoluteSignalFloorDB, count: nCols)
        raw.grid.withUnsafeBufferPointer { g in
            for bin in minBin...maxBin {
                vDSP_vmax(g.baseAddress! + bin * nCols, 1, colMaxDB, 1, &colMaxDB, 1, vDSP_Length(nCols))
            }
        }

        // dB/s release converted to this tile's own per-column step — detail
        // tiles (~12 000 cols/s) and the pooled whole-file overview (far
        // coarser, and variable) don't share a column pitch, so a fixed
        // per-column decay can't mean the same thing in both.
        let spanSeconds = sampleRate > 0 ? Double(raw.endSample - raw.startSample) / sampleRate : 0
        let secondsPerColumn = spanSeconds / Double(nCols)
        let decayPerColumn = Float(Double(Self.ceilingReleaseDBPerSecond) * secondsPerColumn)

        var effMinDB = [Float](repeating: 0, count: nCols)
        var runningCeiling = Self.absoluteSignalFloorDB
        for col in 0..<nCols {
            let colMax = colMaxDB[col]
            runningCeiling = colMax > runningCeiling ? colMax : max(colMax, runningCeiling - decayPerColumn)
            runningCeiling = max(runningCeiling, Self.absoluteSignalFloorDB)
            let ceilingDB = min(runningCeiling + Self.ceilingHeadroomDB, 0)
            effMinDB[col] = ceilingDB - dynamicRangeDB
        }

        // dynamicRangeDB itself doesn't vary by column (only the ceiling/floor
        // it's measured from does), so this part of the map stays a scalar.
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
        // (including the same Int truncation, via vDSP_vfixu8). The intercept
        // is now a per-column VECTOR (the ceiling varies by column) added on
        // after a scalar multiply, rather than the single scalar-multiply-add
        // (vDSP_vsmsa) this used to be — same call count (two per bin row
        // instead of one), still no per-pixel scalar loop.
        let lut = DisplayColormap.makeLUT(palette: palette)
        let lutSteps = lut.count
        var lut32 = [UInt32](repeating: 0, count: lutSteps)
        for i in 0..<lutSteps {
            let (r, g, b) = lut[i]
            // Little-endian byte order r,g,b,a — identical memory layout to the
            // old per-byte writes, so the CGImage bitmapInfo below is unchanged.
            lut32[i] = UInt32(r) | (UInt32(g) << 8) | (UInt32(b) << 16) | 0xFF00_0000
        }

        // Slope is constant across columns (dynamicRangeDB doesn't vary, only
        // the ceiling/floor it's measured from does) — a scalar multiply, then
        // add the per-column intercept vector, rather than a wasted
        // constant-filled slope vector just to satisfy vDSP_vma's shape.
        var slope = invRange * invSpan * Float(lutSteps - 1)
        var interceptPerCol = [Float](repeating: 0, count: nCols)
        for col in 0..<nCols {
            interceptPerCol[col] = ((-effMinDB[col]) * invRange - floor) * invSpan * Float(lutSteps - 1)
        }
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
                        vDSP_vsmul(src, 1, &slope, &tmpRow, 1, vDSP_Length(nCols))
                        vDSP_vadd(tmpRow, 1, interceptPerCol, 1, &tmpRow, 1, vDSP_Length(nCols))
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
                                 targetColumns: Int, palette: Palette, noiseFloor: Float,
                                 calibrationCurve: MicCalibrationCurve? = nil) -> DetailTile? {
        guard let raw = renderRawTile(wavURL: wavURL, startSample: startSample, endSample: endSample,
                                      targetColumns: targetColumns, calibrationCurve: calibrationCurve)
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
                                      map: SilenceMap, targetColumns: Int,
                                      calibrationCurve: MicCalibrationCurve? = nil) -> RawTile? {
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
                    targetColumns: cols, scratch: &scratch, calibrationCurve: calibrationCurve) {
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

    /// The always-resident, whole-file render — the zoomed-out display, the
    /// minimap, and the crop source a live drag falls back to outside a
    /// detail tile's own bounds.
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
                               palette: Palette = .inferno, noiseFloor: Float = 0.5,
                               calibrationCurve: MicCalibrationCurve? = nil) -> Overview? {
        guard let header = WavHeader.read(url: wavURL) else { return nil }
        let totalSamples = Int(header.dataBytes) / 2
        guard totalSamples > 0,
              let raw = renderRawTile(wavURL: wavURL, startSample: 0, endSample: totalSamples, targetColumns: maxWidth,
                                      calibrationCurve: calibrationCurve)
        else { return nil }
        let sampleRate = Double(header.sampleRate)
        guard let tile = colorize(raw, sampleRate: sampleRate, minFreqHz: 0, maxFreqHz: sampleRate / 2,
                                 palette: palette, noiseFloor: noiseFloor)
        else { return nil }
        return Overview(rawTile: raw, image: tile.image, sampleRate: sampleRate, totalSamples: totalSamples)
    }
}
