//
//  PolyphaseResampler.swift
//  OpenBat
//
//  Rational-ratio resampler for offline (non-realtime) use — e.g. BatDetect2Classifier
//  resampling a captured pulse window from the app's native 384 kHz down to
//  BatDetect2's expected 256 kHz. A plain linear-interpolation resample aliases badly
//  for ultrasonic content near Nyquist (exactly the frequencies bat calls live at), so
//  this instead mirrors `scipy.signal.resample_poly`'s design: zero-stuff by `up`,
//  low-pass with a windowed-sinc FIR (Kaiser, beta 5.0) sized the same way scipy sizes
//  it, then decimate by `down`. Not bit-exact with scipy (it fine-tunes the filter's
//  edge padding to land the decimation phase exactly; this instead just centers the
//  filter's group delay) — fine for a pulse window a few hundred samples long, where a
//  handful of edge samples and microseconds of delay don't matter.
//
//  NAME NOTICE: despite the name, this is the zero-stuff → convolve → decimate form,
//  NOT a polyphase decomposition. That is deliberate, and measured. A true polyphase
//  (compute only the kept outputs, using only the non-zero taps) does ~6× fewer
//  multiply-adds and was written and benchmarked on 2026-08-18 — it came out
//  **slower**, both as per-output `vDSP_dotpr` calls (0.62 ms vs 0.40 ms on the real
//  0.256 s / 384→256 kHz workload) and as an inlined scalar dot product (1.59 ms).
//  `vDSP_conv` is vectorised well enough that one long convolution beats 65 536 short
//  ones, even when five sixths of its arithmetic is against zeros. Both variants
//  matched this one to 5e-7, so the maths was right; the operation count simply
//  wasn't the thing that mattered. Don't rewrite this as a polyphase without
//  re-measuring first.
//
//  What DID help, and is what's here: cache the filter already reversed (it was being
//  re-reversed on every call), and zero-stuff straight into the padded buffer instead
//  of building an upsampled array and then a concatenated copy of it. Bit-identical
//  output, two fewer allocations (~1.6 MB per classified pulse), ~8% faster.
//

import Accelerate
import Foundation

/// `nonisolated`: same reasoning as `Biquad`/`AudioLevel`/`STFTGrid` — stateless
/// DSP called only from `PulseDetector`'s capture queue, never the main actor, but
/// it carried no isolation annotation and so inherited
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. The single-caller, single-queue
/// invariant its scratch state relies on is now stated rather than assumed.
nonisolated enum PolyphaseResampler {

    // Keyed by (up, down): the filter only depends on the reduced ratio, and this
    // app only ever resamples 384kHz -> 256kHz (up=2, down=3), so without this the
    // Kaiser-windowed filter (including its besselI0 series evaluations) would be
    // redesigned from scratch on every classified pulse for no reason.
    private static var filterCache: [FilterKey: [Float]] = [:]
    private static let filterCacheLock = NSLock()

    private struct FilterKey: Hashable { let up: Int, down: Int }

    /// Resample `input` from `srcRate` to `dstRate` using a rational up/down ratio
    /// reduced by their GCD, matching `scipy.signal.resample_poly`'s approach.
    static func resample(_ input: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        guard srcRate != dstRate, !input.isEmpty else { return input }

        let srcInt = Int(srcRate.rounded())
        let dstInt = Int(dstRate.rounded())
        let g = gcd(srcInt, dstInt)
        let up = dstInt / g
        let down = srcInt / g
        let halfLen = 10 * max(up, down)
        let numTaps = 2 * halfLen + 1

        // Pre-reversed and cached — `vDSP_conv` computes correlation, so a true
        // convolution needs the filter reversed. This used to be re-reversed into a
        // fresh 61-element array on every call, which quietly defeated half the
        // point of caching the design.
        let reversedH = cachedReversedFilter(up: up, down: down, numTaps: numTaps)

        // Zero-stuff by `up` directly into the padded buffer: ONE allocation, where
        // this previously built a zero-stuffed array and then a padded copy of it
        // via two array concatenations (three live buffers, ~1.6 MB of the ~2.4 MB
        // this routine used to allocate per classified pulse).
        //
        // `vDSP_conv` needs N + P - 1 input samples to produce N outputs, hence the
        // (numTaps - 1) of zeros at each end.
        let upsampledCount = input.count * up
        let pad = numTaps - 1
        var padded = [Float](repeating: 0, count: upsampledCount + 2 * pad)
        padded.withUnsafeMutableBufferPointer { p in
            for i in 0..<input.count { p[pad + i * up] = input[i] }
        }

        let convLen = upsampledCount + numTaps - 1
        var convolved = [Float](repeating: 0, count: convLen)
        padded.withUnsafeBufferPointer { pBuf in
            reversedH.withUnsafeBufferPointer { hBuf in
                vDSP_conv(pBuf.baseAddress!, 1, hBuf.baseAddress!, 1,
                          &convolved, 1, vDSP_Length(convLen), vDSP_Length(numTaps))
            }
        }

        // Decimate by `down`, offset by the filter's group delay (halfLen samples in
        // the upsampled domain) so the output is time-aligned with the input.
        let outCount = Int(ceil(Double(input.count) * Double(up) / Double(down)))
        var out = [Float](repeating: 0, count: outCount)
        convolved.withUnsafeBufferPointer { c in
            out.withUnsafeMutableBufferPointer { o in
                for i in 0..<outCount {
                    let idx = halfLen + i * down
                    o[i] = idx < c.count ? c[idx] : 0
                }
            }
        }
        return out
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return abs(a)
    }

    /// Designs (or returns the cached) Kaiser-windowed low-pass FIR for one `(up,
    /// down)` ratio, DC-gain-scaled by `up` to compensate the 1/up average energy
    /// loss introduced by zero-stuffing (matches scipy's `h *= up`).
    /// Designs (or returns the cached) Kaiser-windowed low-pass FIR for one `(up,
    /// down)` ratio, DC-gain-scaled by `up` to compensate the 1/up average energy
    /// loss introduced by zero-stuffing (matches scipy's `h *= up`), and stores it
    /// already reversed for `vDSP_conv`.
    private static func cachedReversedFilter(up: Int, down: Int, numTaps: Int) -> [Float] {
        let key = FilterKey(up: up, down: down)
        filterCacheLock.lock()
        defer { filterCacheLock.unlock() }
        if let cached = filterCache[key] { return cached }

        let cutoff = 1.0 / Float(max(up, down))   // normalized to upsampled Nyquist = 1.0
        var h = designLowpass(numTaps: numTaps, cutoff: cutoff)
        var upFactor = Float(up)
        vDSP_vsmul(h, 1, &upFactor, &h, 1, vDSP_Length(h.count))
        let reversed = [Float](h.reversed())
        filterCache[key] = reversed
        return reversed
    }

    /// Windowed-sinc low-pass FIR, `cutoff` normalized to Nyquist = 1.0, DC gain 1.
    private static func designLowpass(numTaps: Int, cutoff: Float) -> [Float] {
        let m = Float(numTaps - 1) / 2
        var h = [Float](repeating: 0, count: numTaps)
        for n in 0..<numTaps {
            let x = Float(n) - m
            let sincVal: Float = x == 0 ? cutoff : sinf(.pi * cutoff * x) / (.pi * x)
            h[n] = sincVal * kaiser(n: n, numTaps: numTaps, beta: 5.0)
        }
        var sum: Float = 0
        vDSP_sve(h, 1, &sum, vDSP_Length(numTaps))
        if sum != 0 {
            var inv = 1 / sum
            vDSP_vsmul(h, 1, &inv, &h, 1, vDSP_Length(numTaps))
        }
        return h
    }

    private static func kaiser(n: Int, numTaps: Int, beta: Float) -> Float {
        let alpha = Float(numTaps - 1) / 2
        let ratio = (Float(n) - alpha) / alpha
        let arg = beta * sqrtf(max(0, 1 - ratio * ratio))
        return besselI0(arg) / besselI0(beta)
    }

    /// Modified Bessel function of the first kind, order 0 (Abramowitz & Stegun 9.8.1/9.8.2).
    private static func besselI0(_ x: Float) -> Float {
        let ax = abs(x)
        if ax < 3.75 {
            let t = (x / 3.75) * (x / 3.75)
            return 1 + t * (3.5156229 + t * (3.0899424 + t * (1.2067492
                 + t * (0.2659732 + t * (0.0360768 + t * 0.0045813)))))
        } else {
            let t = 3.75 / ax
            return (expf(ax) / sqrtf(ax)) * (0.39894228 + t * (0.01328592 + t * (0.00225319
                 + t * (-0.00157565 + t * (0.00916281 + t * (-0.02057706
                 + t * (0.02635537 + t * (-0.01647633 + t * 0.00392377))))))))
        }
    }
}
