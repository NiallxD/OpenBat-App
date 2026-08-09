//
//  RecordingSpectrogramRenderer.swift
//  OpenBat
//
//  Offline "whole file" spectrogram for a saved Recording WAV — rendered once by
//  AudioRecorder right after a segment closes (see Context.md §10) and cached
//  as a JPEG alongside the classification thumbnails, so opening a
//  Recording's detail page is instant rather than re-decoding the WAV every time.
//
//  Reuses SpectrogramProcessor (the same FFT the live view runs) so the look is
//  consistent with the rest of the app, fed with the file's PCM in chunks rather
//  than loaded whole — a bout can run up to AudioRecorder's `maxSegmentSeconds`
//  safety cap (minutes), which at 384 kHz would be hundreds of MB as Float32.
//

import AVFoundation
import Accelerate
import UIKit

/// `nonisolated`: same reasoning as `Biquad`/`AudioLevel`/`GuanoMetadata` — this was
/// always documented ("safe to call off the main thread... the caller decides where
/// to run it") but had no explicit isolation annotation, so it inherited this
/// project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` default anyway.
nonisolated enum RecordingSpectrogramRenderer {

    /// The pre-gate, pre-colormap magnitude grid behind a rendered overview —
    /// row-major `[bin*width+col]`, already 0...1 (SpectrogramProcessor's own
    /// adaptive-ceiling contrast) but with no noise-floor gate or palette
    /// applied yet. Kept around (see `WavSpectrogramEngine.Overview.rawGrid`)
    /// so a noise-floor/palette change can recolor a whole-file view
    /// instantly instead of re-deriving it — see `colorize` below and
    /// `renderGrid`'s doc comment for why this matters.
    struct Grid {
        let magnitudes: [Float]
        let width: Int
        let binCount: Int
    }

    /// Renders a full spectrogram overview of `wavURL`, downsampled on the time axis
    /// to at most `maxWidth` columns via max-pooling (preserves a brief loud call
    /// instead of averaging it into the surrounding quiet). Returns nil if the file
    /// can't be read or is empty. Safe to call off the main thread (does real file
    /// IO and FFT work) — the caller decides where to run it.
    static func render(wavURL: URL, maxWidth: Int = 2400) -> UIImage? {
        guard let grid = renderGrid(wavURL: wavURL, maxWidth: maxWidth) else { return nil }
        return colorize(grid)
    }

    /// The expensive half of `render` — PCM IO plus the FFT — split out so a
    /// noise-floor/palette-only change can reuse an already-computed grid
    /// (`colorize` below) instead of re-scanning the file. Streams the file in
    /// bounded chunks rather than loading it whole. Use this, not
    /// `WavPCMReader.readSamples`, for a whole-file view: that reader
    /// materialises its entire requested range in one `[Float]` array, fine for
    /// a small zoomed-in tile but not for a multi-minute recording, where
    /// `renderGrid`'s `O(binCount * width)` memory is the only viable option.
    static func renderGrid(wavURL: URL, maxWidth: Int = 2400) -> Grid? {
        guard let header = WavHeader.read(url: wavURL) else {
            WavPlayerDebugLog.log("RecordingSpectrogramRenderer", "renderGrid: WavHeader.read FAILED for \(wavURL.lastPathComponent)")
            return nil
        }
        let sampleRate = header.sampleRate
        let dataBytes  = header.dataBytes
        let totalSamples = Int(dataBytes) / 2   // 16-bit mono, matching AudioRecorder.wavHeader

        guard let handle = try? FileHandle(forReadingFrom: wavURL) else {
            WavPlayerDebugLog.log("RecordingSpectrogramRenderer", "renderGrid: FileHandle open FAILED for \(wavURL.lastPathComponent)")
            return nil
        }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: 44)) != nil else { return nil }

        let processor = SpectrogramProcessor()
        processor.sampleRate = Double(sampleRate)
        let hopSize = processor.hopSize
        let windowLen = processor.windowLen
        let binCount = processor.binCount
        let totalColumns = max(1, (totalSamples - windowLen) / hopSize + 1)
        let width = min(totalColumns, maxWidth)
        WavPlayerDebugLog.log("RecordingSpectrogramRenderer",
            "renderGrid: \(wavURL.lastPathComponent) totalSamples=\(totalSamples) (\(String(format: "%.1f", Double(totalSamples) / Double(sampleRate)))s) totalColumns=\(totalColumns) -> width=\(width)")

        // Max-pooled accumulator, [bin * width + bucket] — already-normalized 0...1
        // display magnitudes (SpectrogramProcessor's own adaptive-ceiling contrast,
        // tracked in file order same as it tracks in real time for the live view).
        var accum = [Float](repeating: 0, count: binCount * width)
        var columnsSeen = 0

        guard let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)
        else { return nil }

        let chunkSamples = 1 << 19   // ~524k samples (~1.4 s @ 384 kHz) per read
        var int16Buf = [Int16](repeating: 0, count: chunkSamples)
        var bytesRemaining = Int(dataBytes)

        WavPlayerDebugLog.time("RecordingSpectrogramRenderer", "renderGrid scan (\(totalColumns) native columns)") {
            while bytesRemaining > 0 {
                let want = min(chunkSamples * 2, bytesRemaining)
                guard let data = try? handle.read(upToCount: want), !data.isEmpty else { break }
                bytesRemaining -= data.count
                let n = data.count / 2
                guard n > 0 else { continue }
                data.withUnsafeBytes { raw in
                    let src = raw.bindMemory(to: Int16.self)
                    int16Buf.withUnsafeMutableBufferPointer { dst in
                        for i in 0..<n { dst[i] = src[i] }
                    }
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(n)),
                      let floatCh = buffer.floatChannelData?[0]
                else { break }
                buffer.frameLength = AVAudioFrameCount(n)
                int16Buf.withUnsafeBufferPointer { src in
                    vDSP_vflt16(src.baseAddress!, 1, floatCh, 1, vDSP_Length(n))
                    var scale: Float = 1.0 / 32767.0
                    vDSP_vsmul(floatCh, 1, &scale, floatCh, 1, vDSP_Length(n))
                }

                processor.process(buffer)
                for col in processor.drain() {
                    // Proportional mapping (columnsSeen/totalColumns * width), NOT
                    // `columnsSeen / colsPerBucket` for some rounded-up bucket size
                    // — that division systematically undershoots bucket width-1 on
                    // the last column (confirmed on-device: 17% of a real image
                    // left unwritten, black). Proportional mapping always reaches
                    // width-1 on the last column regardless of how evenly
                    // totalColumns divides into width.
                    let bucket = min(width - 1, Int(Double(columnsSeen) * Double(width) / Double(totalColumns)))
                    // Vectorized element-wise max instead of a per-bin scalar Swift
                    // loop — this ran once per FFT column (up to ~900,000 times for
                    // a 10-minute recording at maxSegmentSeconds), each iterating
                    // binCount (1024) times: ~1 billion scalar comparisons for a
                    // long file. `accum`'s bin-major layout ([bin*width+bucket])
                    // means the write side has stride `width`, which vDSP_vmax's
                    // stride parameters handle directly — no transpose needed.
                    accum.withUnsafeMutableBufferPointer { acc in
                        col.magnitudes.withUnsafeBufferPointer { mags in
                            vDSP_vmax(mags.baseAddress!, 1,
                                      acc.baseAddress! + bucket, vDSP_Stride(width),
                                      acc.baseAddress! + bucket, vDSP_Stride(width),
                                      vDSP_Length(binCount))
                        }
                    }
                    columnsSeen += 1
                }
            }
        }

        guard columnsSeen > 0 else {
            WavPlayerDebugLog.log("RecordingSpectrogramRenderer", "renderGrid: 0 columns produced for \(wavURL.lastPathComponent)")
            return nil
        }
        WavPlayerDebugLog.log("RecordingSpectrogramRenderer", "renderGrid: done, columnsSeen=\(columnsSeen)/\(totalColumns)")
        return Grid(magnitudes: accum, width: width, binCount: binCount)
    }

    /// Colorizes an already-computed `Grid` — pure pixel math over an
    /// in-memory array, no file IO or FFT, cheap enough to re-run on every
    /// noise-floor/palette tick. `palette`/`noiseFloor` default to reading
    /// the same UserDefaults keys the original save-time render always used
    /// (this can run on AudioRecorder's own background queue with no other
    /// context) — callers that already track the live values (WavPlayerView)
    /// pass them explicitly instead.
    static func colorize(_ grid: Grid, palette explicitPalette: Palette? = nil,
                         noiseFloor explicitFloor: Float? = nil) -> UIImage? {
        let width = grid.width, binCount = grid.binCount
        let accum = grid.magnitudes

        // Must match PulseDetector.Key.displayPalette exactly — mirrors the user's
        // currently-selected display palette without needing a live PulseDetector
        // reference.
        let palette = explicitPalette ?? {
            let raw = UserDefaults.standard.integer(forKey: "pulse.displayPalette")
            return Palette(rawValue: raw) ?? .inferno
        }()

        // Same UserDefaults-direct read pattern as the palette above — this thumbnail
        // is otherwise a plain 0...1 dB-normalized render with no noise gate, so a
        // quiet recording's background hiss fills the whole frame with low-level
        // colormap speckle instead of reading as mostly black. Gate + stretch the
        // remaining range to full contrast, same shape as PulseImageRenderer's `gate`.
        let floor: Float
        if let explicitFloor {
            floor = min(max(explicitFloor, 0), 0.99)
        } else {
            let hasStoredFloor = UserDefaults.standard.object(forKey: "display.playbackThumbnailNoiseFloor") != nil
            let storedFloor = UserDefaults.standard.double(forKey: "display.playbackThumbnailNoiseFloor")
            floor = Float(min(max(hasStoredFloor ? storedFloor : 0.25, 0), 0.99))
        }
        let invSpan = 1 / max(0.01, 1 - floor)
        func gate(_ t: Float) -> Float { max(0, (t - floor) * invSpan) }

        // See DisplayColormap.makeLUT's doc comment — this single change
        // (256-entry table built once, O(1) lookup per pixel instead of a
        // dictionary lookup + linear stop-search per pixel) is what took this
        // loop from 1.6–5.3 SECONDS down to low tens of ms on-device.
        let lut = DisplayColormap.makeLUT(palette: palette)
        let lutSteps = lut.count
        var pixels = [UInt8](repeating: 255, count: width * binCount * 4)
        WavPlayerDebugLog.time("RecordingSpectrogramRenderer", "colorize pixel loop (\(width)x\(binCount))") {
        pixels.withUnsafeMutableBufferPointer { px in
            lut.withUnsafeBufferPointer { lutBuf in
                for bin in 0..<binCount {
                    let yFlipped = binCount - 1 - bin   // row 0 = top = high frequency
                    for x in 0..<width {
                        let lutIdx = min(lutSteps - 1, max(0, Int(gate(accum[bin * width + x]) * Float(lutSteps - 1))))
                        let (r, g, b) = lutBuf[lutIdx]
                        let idx = (yFlipped * width + x) * 4
                        px[idx] = r; px[idx + 1] = g; px[idx + 2] = b; px[idx + 3] = 255
                    }
                }
            }
        }
        }
        guard
            let provider = CGDataProvider(data: Data(pixels) as CFData),
            let cgImage = CGImage(
                width: width, height: binCount,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
