//
//  WavSpectrogramEngine.swift
//  OpenBat
//
//  Offline, static spectrogram rendering for the whole-file WAV player — no
//  live/ring-buffer state, no @MainActor UI. Two tiers, matching the memory
//  analysis behind this rebuild (a raw, unpooled STFT grid at native
//  resolution is only feasible for a few seconds of audio — see
//  STFTGrid.swift's doc comment and CLAUDE.md's WavPlayer notes):
//
//    • `renderOverview` — a cheap, always-resident, whole-file thumbnail
//      (thin wrapper over the existing RecordingSpectrogramRenderer, which
//      already streams+max-pools the file to a bounded-size image regardless
//      of length). Used for the zoomed-out display and as the minimap.
//    • `renderDetailTile` — a fresh render of just the CURRENTLY VISIBLE
//      viewport, re-run from raw PCM every time the viewport settles after a
//      zoom/pan gesture. Bounded to O(targetColumns × croppedBinCount)
//      regardless of the viewport's time span, via STFTGrid.streamPooledGrid
//      (which pools even a many-second span down to `targetColumns` without
//      ever materializing its native-resolution grid).
//
//  Uses STFTGrid's finer time resolution (12 000 cols/sec vs. the overview's
//  1500) for detail tiles — favours time resolution once the viewport
//  narrows enough that fine FM-sweep detail matters. Bin count (1024) matches
//  the overview/live spectrogram, so a detail tile is never coarser on the
//  frequency axis than the overview crop it replaces (an earlier version
//  used 512 bins here specifically, which made zooming in visibly *lose*
//  frequency resolution — the opposite of what "zoom in" should do).
//

import UIKit
import Accelerate

nonisolated enum WavSpectrogramEngine {

    // MARK: Overview

    struct Overview {
        let image: UIImage
        let sampleRate: Double
        let totalSamples: Int
        /// Nyquist frequency — top edge of the overview image's frequency axis.
        var maxFreqHz: Double { sampleRate / 2 }
    }

    /// Computes just the raw magnitude grid behind a whole-file overview —
    /// bounded memory (streams the file in chunks, same as
    /// `RecordingSpectrogramRenderer.render` always has), so this is safe to
    /// run on ANY recording length. Thin wrapper so callers don't need to
    /// know `RecordingSpectrogramRenderer` exists.
    static func renderRawGrid(wavURL: URL, maxWidth: Int = 4096) -> RecordingSpectrogramRenderer.Grid? {
        RecordingSpectrogramRenderer.renderGrid(wavURL: wavURL, maxWidth: maxWidth)
    }

    /// Renders (or reuses `RecordingSpectrogramRenderer`'s own streaming
    /// max-pool pipeline for) a whole-file overview image, bounded to
    /// `maxWidth` columns regardless of file length.
    ///
    /// `cachedImage`, when provided, is used directly instead of re-decoding
    /// and re-analyzing the WAV — `AudioRecorder` already renders and caches
    /// a full-resolution spectrogram once at save time
    /// (`ClassificationStore.spectrogramImage(for:)`), so re-running the
    /// whole FFT pipeline here on every player open was pure waste. Only the
    /// cheap 44-byte header read (for sampleRate/totalSamples) still happens
    /// either way. Falls back to a fresh render when no cache exists (old or
    /// migrated recordings, or a save-time render that failed).
    static func renderOverview(wavURL: URL, maxWidth: Int = 4096, cachedImage: UIImage? = nil) -> Overview? {
        guard let header = WavHeader.read(url: wavURL) else { return nil }
        let totalSamples = Int(header.dataBytes) / 2
        if let cachedImage {
            // `cachedImage` comes from ClassificationStore.spectrogramImage(for:),
            // which is `UIImage(contentsOfFile:)`-backed — lazily decoded from
            // the on-disk JPEG. WavSpectrogramView.croppedOverviewImage()
            // accesses `.cgImage` on EVERY drag/scroll frame (60/sec while
            // panning), so a lazily-backed image here would silently turn the
            // perf win of skipping the FFT render into a new per-frame JPEG
            // decode instead — exactly the kind of stutter that's easy to miss
            // in a build-only check but very visible on-device. Force a single
            // eager decode into a plain in-memory bitmap up front (same shape
            // `RecordingSpectrogramRenderer`'s own from-scratch renders already
            // produce, and the same "draw into a fresh renderer" idiom
            // ClassificationStore.thumbnailJPEG already uses elsewhere) so
            // every later access is a cheap stored-property read.
            let decoded = forceDecoded(cachedImage) ?? cachedImage
            return Overview(image: decoded, sampleRate: Double(header.sampleRate), totalSamples: totalSamples)
        }
        guard let image = RecordingSpectrogramRenderer.render(wavURL: wavURL, maxWidth: maxWidth) else { return nil }
        return Overview(image: image, sampleRate: Double(header.sampleRate), totalSamples: totalSamples)
    }

    private static func forceDecoded(_ image: UIImage) -> UIImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in image.draw(at: .zero) }
    }

    // MARK: Detail tile

    struct DetailTile {
        let image: UIImage
        let startSample: Int
        let endSample: Int          // exclusive
        let minFreqHz: Double       // actual rendered crop (may be clamped from the request)
        let maxFreqHz: Double
    }

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

    /// The expensive half of a detail-tile render — PCM file IO plus the
    /// actual STFT (`STFTGrid.streamPooledGrid`) — split out from `colorize`
    /// below so a change that only affects the pixel mapping (noise floor,
    /// palette) can reuse an already-computed grid instead of re-reading PCM
    /// and re-running the FFT just to recolor the same data. Neither the
    /// noise floor nor the palette feeds into this step at all.
    struct RawTile {
        let grid: [Float]   // row-major [bin*nCols+col], RAW (non peak-normalized) dB
        let nCols: Int
        let startSample: Int
        let endSample: Int   // exclusive
    }

    static func renderRawTile(wavURL: URL, startSample: Int, endSample: Int, targetColumns: Int) -> RawTile? {
        guard endSample > startSample, targetColumns > 0 else { return nil }
        let count = endSample - startSample
        guard let pcm = WavPCMReader.readSamples(wavURL: wavURL, startSample: startSample, count: count),
              pcm.count >= STFTGrid.windowLen
        else { return nil }

        var scratch = STFTGrid.Scratch()
        guard let (rawDBGrid, nCols) = STFTGrid.streamPooledGrid(pcm: pcm, targetColumns: targetColumns,
                                                                  scratch: &scratch)
        else { return nil }

        return RawTile(grid: rawDBGrid, nCols: nCols, startSample: startSample, endSample: endSample)
    }

    /// The cheap half — crops `raw` to `[minFreqHz, maxFreqHz]`, peak-relative
    /// normalizes over just that cropped bin range (zooming into a narrow
    /// high frequency band still gets full dynamic range, rather than being
    /// washed out by louder energy elsewhere in the spectrum that isn't even
    /// being displayed), gates by `noiseFloor`, and colorizes. Pure array
    /// math over an already-computed grid — no file IO, no FFT — so this is
    /// cheap enough to re-run on every noise-floor/palette tick without the
    /// "takes an age to apply" lag re-running `renderRawTile` on every tick
    /// caused.
    static func colorize(_ raw: RawTile, sampleRate: Double, minFreqHz: Double, maxFreqHz: Double,
                         palette: Palette, noiseFloor: Float) -> DetailTile? {
        let nCols = raw.nCols
        let bins = STFTGrid.binCount
        let hzPerBin = (sampleRate / 2) / Double(bins)
        let minBin = min(max(Int(minFreqHz / hzPerBin), 0), bins - 1)
        let maxBin = min(max(Int(maxFreqHz / hzPerBin), minBin), bins - 1)
        let croppedBins = maxBin - minBin + 1

        var maxDB: Float = -.greatestFiniteMagnitude
        for bin in minBin...maxBin {
            let base = bin * nCols
            for col in 0..<nCols where raw.grid[base + col] > maxDB { maxDB = raw.grid[base + col] }
        }
        // Clamp the normalization ceiling up to `absoluteSignalFloorDB` when
        // the tile's own peak doesn't clear it — a call-free view's loudest
        // point is just noise-floor variation, and peak-relative-stretching
        // THAT to full contrast (using `maxDB` directly, unconditionally, as
        // the old code did) is the "renders as pure noise" bug. When a real
        // call IS present (maxDB already clears the floor), this is a no-op
        // and behavior is unchanged from before.
        let ceilingDB = max(maxDB, Self.absoluteSignalFloorDB)
        let minDB = ceilingDB - dynamicRangeDB
        let invRange = 1.0 / dynamicRangeDB

        let floor = min(max(noiseFloor, 0), 0.99)
        let invSpan = 1 / max(0.01, 1 - floor)
        func gate(_ t: Float) -> Float { max(0, (t - floor) * invSpan) }

        // See DisplayColormap.makeLUT's doc comment — measured on-device at
        // 700-850ms for a 1536x1024 tile via the naive per-pixel `rgb` call
        // (dictionary lookup + linear stop-search per pixel); this drops it
        // to low tens of ms.
        let lut = DisplayColormap.makeLUT(palette: palette)
        let lutSteps = lut.count
        var pixels = [UInt8](repeating: 255, count: nCols * croppedBins * 4)
        pixels.withUnsafeMutableBufferPointer { px in
            lut.withUnsafeBufferPointer { lutBuf in
                for bin in minBin...maxBin {
                    let yFlipped = maxBin - bin   // row 0 = top = high frequency within the crop
                    let srcBase = bin * nCols
                    for col in 0..<nCols {
                        let norm = min(max((raw.grid[srcBase + col] - minDB) * invRange, 0), 1)
                        let lutIdx = min(lutSteps - 1, max(0, Int(gate(norm) * Float(lutSteps - 1))))
                        let (r, g, b) = lutBuf[lutIdx]
                        let idx = (yFlipped * nCols + col) * 4
                        px[idx] = r; px[idx + 1] = g; px[idx + 2] = b; px[idx + 3] = 255
                    }
                }
            }
        }

        guard
            let provider = CGDataProvider(data: Data(pixels) as CFData),
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
}
