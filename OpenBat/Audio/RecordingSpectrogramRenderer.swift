//
//  RecordingSpectrogramRenderer.swift
//  OpenBat
//
//  Offline "whole file" spectrogram for a saved Recording WAV — rendered once by
//  AudioRecorder right after a segment closes (see CLAUDE.md's recording-subsystem
//  notes) and cached as a JPEG alongside the classification thumbnails, so opening a
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

    /// Renders a full spectrogram overview of `wavURL`, downsampled on the time axis
    /// to at most `maxWidth` columns via max-pooling (preserves a brief loud call
    /// instead of averaging it into the surrounding quiet). Returns nil if the file
    /// can't be read or is empty. Safe to call off the main thread (does real file
    /// IO and FFT work) — the caller decides where to run it.
    static func render(wavURL: URL, maxWidth: Int = 2400) -> UIImage? {
        guard let header = WavHeader.read(url: wavURL) else { return nil }
        let sampleRate = header.sampleRate
        let dataBytes  = header.dataBytes
        let totalSamples = Int(dataBytes) / 2   // 16-bit mono, matching AudioRecorder.wavHeader

        guard let handle = try? FileHandle(forReadingFrom: wavURL) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: 44)) != nil else { return nil }

        let processor = SpectrogramProcessor()
        processor.sampleRate = Double(sampleRate)
        let hopSize = processor.hopSize
        let windowLen = processor.windowLen
        let binCount = processor.binCount
        let totalColumns = max(1, (totalSamples - windowLen) / hopSize + 1)
        let width = min(totalColumns, maxWidth)
        let colsPerBucket = max(1, Int((Double(totalColumns) / Double(width)).rounded(.up)))

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
                let bucket = min(width - 1, columnsSeen / colsPerBucket)
                col.magnitudes.withUnsafeBufferPointer { mags in
                    for bin in 0..<binCount {
                        let idx = bin * width + bucket
                        if mags[bin] > accum[idx] { accum[idx] = mags[bin] }
                    }
                }
                columnsSeen += 1
            }
        }

        guard columnsSeen > 0 else { return nil }
        return makeImage(accum: accum, width: width, binCount: binCount)
    }

    private static func makeImage(accum: [Float], width: Int, binCount: Int) -> UIImage? {
        // Must match PulseDetector.Key.displayPalette exactly — mirrors the user's
        // currently-selected display palette without needing a live PulseDetector
        // reference (this renders on AudioRecorder's own background queue).
        let raw = UserDefaults.standard.integer(forKey: "pulse.displayPalette")
        let palette = Palette(rawValue: raw) ?? .inferno

        var pixels = [UInt8](repeating: 255, count: width * binCount * 4)
        for bin in 0..<binCount {
            let yFlipped = binCount - 1 - bin   // row 0 = top = high frequency
            for x in 0..<width {
                let (r, g, b) = DisplayColormap.rgb(accum[bin * width + x], palette: palette)
                let idx = (yFlipped * width + x) * 4
                pixels[idx] = r; pixels[idx + 1] = g; pixels[idx + 2] = b; pixels[idx + 3] = 255
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
