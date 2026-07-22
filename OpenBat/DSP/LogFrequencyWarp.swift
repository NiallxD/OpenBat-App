//
//  LogFrequencyWarp.swift
//  OpenBat
//
//  Nearest-neighbour row-remap that turns a linear-frequency spectrogram
//  bitmap into a log-frequency one, for views that render via a plain
//  UIImage/CGImage rather than a Metal shader (which can do the log warp in
//  the fragment shader instead — see Spectrogram.metal/SpectrogramRenderer's
//  `logFrequency` uniform for that path). Extracted from PulseZoomView (the
//  first caller) so WavSpectrogramView can share the exact same
//  implementation instead of duplicating it.
//

import UIKit

nonisolated enum LogFrequencyWarp {

    /// `log(0)` is undefined, so a nominal 0 Hz low bound — the WAV player's
    /// default, un-zoomed viewport starts exactly there — needs a positive
    /// floor before it can drive a log axis at all. A tiny floor (e.g. 1 Hz)
    /// technically avoids the undefined-log crash but is actively wrong for
    /// display: log-compressing the FULL 1 Hz–192 kHz range devotes roughly
    /// HALF the vertical space to 1–10 kHz alone (equal log-decades get
    /// equal screen space), which is almost entirely DC/handling-noise
    /// content for bat recordings — squashing the actual call energy
    /// (essentially always ≥ 10 kHz) into a thin sliver at the top. 10 kHz
    /// is a reasonable floor for bat echolocation specifically (this
    /// codebase's whole domain) — comfortably below the lowest-frequency
    /// species' calls, well above where there's ever anything worth log-
    /// compressing room for. Still respects a MORE conservative (higher)
    /// linear low bound if the user has already trimmed the Y-axis there
    /// themselves — this is a floor, not an override.
    private static func clampedLo(_ lo: Double) -> Double { max(lo, 10_000) }

    /// Remaps `image`'s rows (row 0 = top = `hiHz`, last row = bottom =
    /// `loHz`, evenly spaced in Hz — every renderer in this codebase's native
    /// layout) so that row *position* instead follows a log frequency scale.
    /// For each destination row, finds the Hz a log axis puts there, then
    /// finds which row of the SOURCE (linear) image already shows that Hz,
    /// and copies it across. Returns `image` unchanged if the inputs don't
    /// support warping (degenerate range, no backing CGImage, etc).
    static func warp(_ image: UIImage, loHz: Double, hiHz: Double) -> UIImage? {
        let lo = clampedLo(loHz)
        guard hiHz > lo,
              let cg = image.cgImage,
              let dataProvider = cg.dataProvider,
              let data = dataProvider.data,
              let srcPtr = CFDataGetBytePtr(data)
        else { return image }

        let width = cg.width
        let height = cg.height
        guard height > 1 else { return image }
        let bytesPerRow = cg.bytesPerRow
        var out = [UInt8](repeating: 0, count: bytesPerRow * height)
        let logSpan = log(hiHz / lo)

        out.withUnsafeMutableBytes { dst in
            guard let dstBase = dst.baseAddress else { return }
            for y in 0..<height {
                let v = Double(y) / Double(height - 1)                 // 0 = top, 1 = bottom
                let hz = lo * exp((1 - v) * logSpan)                   // log-axis Hz at this row
                let linearFrac = (hiHz - hz) / (hiHz - loHz)           // where that Hz sits in the ORIGINAL linear source
                let srcY = min(height - 1, max(0, Int((linearFrac * Double(height - 1)).rounded())))
                memcpy(dstBase.advanced(by: y * bytesPerRow),
                       srcPtr.advanced(by: srcY * bytesPerRow),
                       bytesPerRow)
            }
        }

        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let warped = CGImage(width: width, height: height,
                                   bitsPerComponent: cg.bitsPerComponent, bitsPerPixel: cg.bitsPerPixel,
                                   bytesPerRow: bytesPerRow,
                                   space: cg.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: cg.bitmapInfo, provider: provider, decode: nil,
                                   shouldInterpolate: true, intent: .defaultIntent)
        else { return image }
        return UIImage(cgImage: warped)
    }

    /// Converts a Hz value to a v-fraction (0 = top/high, 1 = bottom/low)
    /// within [lo, hi], honouring linear or log mode — shared by callers that
    /// need to know where a specific Hz sits within a (possibly warped)
    /// image, e.g. axis tick labels or a zoom geometry anchored on a known
    /// frequency. Uses the same `clampedLo` floor as `warp` so labels always
    /// agree with what's actually rendered.
    static func hzToVFrac(_ hz: Double, lo: Double, hi: Double, log logMode: Bool) -> Double {
        guard hi > lo else { return 0.5 }
        if logMode {
            let clo = clampedLo(lo)
            guard hi > clo else { return 0.5 }
            let hzC = min(max(hz, clo), hi)
            return 1 - (log(hzC / clo) / log(hi / clo))
        }
        return (hi - hz) / (hi - lo)
    }

    /// Inverse of `hzToVFrac`.
    static func vFracToHz(_ v: Double, lo: Double, hi: Double, log logMode: Bool) -> Double {
        guard hi > lo else { return lo }
        if logMode {
            let clo = clampedLo(lo)
            guard hi > clo else { return lo }
            return clo * exp((1 - v) * log(hi / clo))
        }
        return hi - v * (hi - lo)
    }
}
