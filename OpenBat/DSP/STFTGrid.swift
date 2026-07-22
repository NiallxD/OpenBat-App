//
//  STFTGrid.swift
//  OpenBat
//
//  Shared high-resolution STFT core, extracted from PulseImageRenderer so the
//  new WavPlayer analysis/rendering pipeline (WavSpectrogramEngine,
//  CallAnalysis) can reuse the exact same FFT math instead of duplicating it.
//  PulseImageRenderer keeps its onset-locking/capture-geometry logic and just
//  calls `compute(pcm:scratch:dynamicRangeDB:)` for steps 1-2 of its render.
//
//  Two entry points:
//    • `compute` — one-shot: the whole `pcm` slice becomes one dB grid at
//      native resolution. Fine for a short span (a single pulse capture, or a
//      WavPlayer detail-tile narrow enough that native columns stay bounded).
//    • `streamPooledGrid` — for spans whose native column count would make
//      `compute`'s full grid too large to hold at once (a WavPlayer detail
//      tile spanning many seconds): pools each frame's per-bin peak (max) into
//      `targetColumns` buckets as it goes, so memory never exceeds
//      O(targetColumns * binCount) regardless of how long `pcm` is. Returns
//      RAW (non peak-normalized) dB — the caller normalizes over the small
//      pooled result afterward, since the global peak isn't known until every
//      frame's been seen.
//

import Accelerate

nonisolated enum STFTGrid {

    // ── STFT parameters (shared by every caller) ─────────────────────────────
    static let windowLen = 512               // Hann analysis window (samples)
    static let fftLen    = 2048              // zero-padded FFT size
    static let hop       = 32                // 12 000 cols/sec @ 384 kHz
    static var binCount: Int { fftLen / 2 }  // 1024 — matches SpectrogramProcessor/
                                              // RecordingSpectrogramRenderer's bin
                                              // count, so a detail tile isn't coarser
                                              // on the frequency axis than the
                                              // overview crop it replaces.

    // 2048 = 2^11 — radix-2 real FFT (window is zero-padded up to this length).
    private static let log2n = vDSP_Length(11)
    private static let fftSetup: FFTSetup = {
        guard let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("STFTGrid: FFT setup failed")
        }
        return s
    }()
    private static let hannWindow: [Float] = {
        var w = [Float](repeating: 0, count: windowLen)
        vDSP_hann_window(&w, vDSP_Length(windowLen), Int32(vDSP_HANN_NORM))
        return w
    }()

    /// Reusable scratch buffers for one caller's serial STFT work. Each
    /// concurrent caller (PulseImageRenderer's captureQueue vs.
    /// WavSpectrogramEngine's detail-tile render Task, which can run at the
    /// same time) must own its own `Scratch` instance — sharing one across
    /// callers that could run concurrently would race on the same backing
    /// arrays. Buffers grow but are never shrunk across calls on the same
    /// instance, same steal/return reuse pattern PulseImageRenderer's old
    /// static scratch vars used.
    struct Scratch {
        var dB: [Float] = []
        var windowed: [Float] = []
        var realp: [Float] = []
        var imagp: [Float] = []
        var mags: [Float] = []
    }

    /// Computes a peak-normalized [0,1] dB grid, row-major [bin*nFrames+frame],
    /// from the whole `pcm` slice at native STFT resolution. Returns nil if
    /// `pcm` is shorter than one window or produces fewer than 2 frames.
    static func compute(pcm: [Float], scratch: inout Scratch,
                        dynamicRangeDB: Float) -> (grid: [Float], nFrames: Int)? {
        guard pcm.count >= windowLen else {
            WavPlayerDebugLog.log("STFTGrid", "compute: pcm.count=\(pcm.count) < windowLen=\(windowLen), aborting")
            return nil
        }
        let bins = binCount
        let nFrames = 1 + (pcm.count - windowLen) / hop
        guard nFrames >= 2 else {
            WavPlayerDebugLog.log("STFTGrid", "compute: nFrames=\(nFrames) < 2, aborting")
            return nil
        }

        let dbCount = bins * nFrames
        var dB = scratch.dB; scratch.dB = []
        if dB.count < dbCount { dB = [Float](repeating: 0, count: dbCount) }
        var windowed = scratch.windowed; scratch.windowed = []
        if windowed.count != fftLen { windowed = [Float](repeating: 0, count: fftLen) } // tail stays zero (pad)
        var realp = scratch.realp; scratch.realp = []
        var imagp = scratch.imagp; scratch.imagp = []
        var mags  = scratch.mags;  scratch.mags  = []
        if realp.count != bins { realp = [Float](repeating: 0, count: bins) }
        if imagp.count != bins { imagp = [Float](repeating: 0, count: bins) }
        if mags.count  != bins { mags  = [Float](repeating: 0, count: bins) }
        let scale: Float = 1.0 / Float(fftLen)

        WavPlayerDebugLog.time("STFTGrid", "compute (\(nFrames) frames)") {
        pcm.withUnsafeBufferPointer { pBuf in
            for frame in 0..<nFrames {
                let start = frame * hop
                vDSP_vmul(pBuf.baseAddress! + start, 1, hannWindow, 1,
                          &windowed, 1, vDSP_Length(windowLen))
                windowed.withUnsafeBufferPointer { wBuf in
                    wBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { cplx in
                        // realp/imagp pointers must stay valid across all three vDSP calls —
                        // nest under withUnsafeMutableBufferPointer rather than taking
                        // `&realp`/`&imagp` directly, which only guarantees the pointer for
                        // the init call itself and could dangle for the reads/writes after it.
                        realp.withUnsafeMutableBufferPointer { rp in
                            imagp.withUnsafeMutableBufferPointer { ip in
                                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                                vDSP_ctoz(cplx, 2, &split, 1, vDSP_Length(bins))
                                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(bins))
                            }
                        }
                    }
                }
                var s = scale
                vDSP_vsmul(mags, 1, &s, &mags, 1, vDSP_Length(bins))
                // Vectorized dB conversion (clamp, log10, ×20) instead of a
                // scalar log10f-per-bin loop — this ran once per STFT frame
                // (up to thousands/sec), and log10f is a relatively expensive
                // transcendental to call from a Swift loop bins times each.
                // Same vDSP/vvlog10f approach SpectrogramProcessor.makeColumn
                // already uses. Only the final scatter into `dB`'s
                // transposed [bin*nFrames+frame] layout stays a Swift loop —
                // that's a cheap float copy, not a log10f call.
                var floor: Float = 1e-9
                vDSP_vthr(mags, 1, &floor, &mags, 1, vDSP_Length(bins))
                var count32 = Int32(bins)
                vvlog10f(&mags, mags, &count32)
                var scale20: Float = 20.0
                vDSP_vsmul(mags, 1, &scale20, &mags, 1, vDSP_Length(bins))
                for bin in 0..<bins {
                    dB[bin * nFrames + frame] = mags[bin]
                }
            }
        }
        }

        // Normalize to [0,1] over [peakDB - dynamicRange, peakDB]. Lengths are
        // `dbCount`, not `dB.count` — the reused scratch may be larger than
        // this call's used region, and stale tail values must not feed the
        // max or get rescaled.
        var maxDB: Float = -.greatestFiniteMagnitude
        vDSP_maxv(dB, 1, &maxDB, vDSP_Length(dbCount))
        let minDB = maxDB - dynamicRangeDB
        var negMin = -minDB
        var inv = 1.0 / dynamicRangeDB
        vDSP_vsadd(dB, 1, &negMin, &dB, 1, vDSP_Length(dbCount))
        vDSP_vsmul(dB, 1, &inv,    &dB, 1, vDSP_Length(dbCount))
        var lo: Float = 0, hi: Float = 1
        vDSP_vclip(dB, 1, &lo, &hi, &dB, 1, vDSP_Length(dbCount))   // -> norm in [0,1]

        scratch.dB = dB
        scratch.windowed = windowed
        scratch.realp = realp
        scratch.imagp = imagp
        scratch.mags = mags
        return (dB, nFrames)
    }

    /// Streaming variant for spans whose native STFT grid would be too large
    /// to materialize (see the file doc comment). Pools each frame's per-bin
    /// dB peak (max, not average — preserves a brief loud call instead of
    /// smearing it into quiet neighbours, same rationale as
    /// RecordingSpectrogramRenderer's column pooling) directly into
    /// `targetColumns` buckets. At no point does more than one frame's worth
    /// of scratch plus the O(targetColumns * binCount) accumulator exist.
    /// Returns RAW (non peak-normalized) dB values, row-major
    /// [bin*width+bucket] where `width = min(nFrames, targetColumns)`.
    ///
    /// Only visits up to `oversample` native-hop frames PER OUTPUT BUCKET,
    /// not every native frame — bounding total FFT work to
    /// O(width * oversample) regardless of how many native frames the span
    /// actually spans. Without this, a wide span (e.g. a several-second
    /// detail tile, or the whole file at native hop = 12,000 frames/sec)
    /// computed the STFT at every one of potentially hundreds of thousands
    /// of native frames just to pool the result down to ~1500 buckets —
    /// the difference between this being instant and taking multiple
    /// seconds, which is what made re-rendering on every noise-floor slider
    /// tick painfully slow. Each bucket still visits AT LEAST one frame
    /// (`bucketStart`), so the "never left at the sentinel" guarantee below
    /// holds regardless of `oversample`.
    static func streamPooledGrid(pcm: [Float], targetColumns: Int,
                                 scratch: inout Scratch, oversample: Int = 8) -> (dBGrid: [Float], nCols: Int)? {
        guard pcm.count >= windowLen, targetColumns > 0 else {
            WavPlayerDebugLog.log("STFTGrid", "streamPooledGrid: pcm.count=\(pcm.count) targetColumns=\(targetColumns), aborting")
            return nil
        }
        let bins = binCount
        let nFrames = 1 + (pcm.count - windowLen) / hop
        guard nFrames >= 1 else {
            WavPlayerDebugLog.log("STFTGrid", "streamPooledGrid: nFrames=\(nFrames) < 1, aborting")
            return nil
        }
        let width = min(nFrames, targetColumns)
        WavPlayerDebugLog.log("STFTGrid", "streamPooledGrid: nFrames=\(nFrames) -> width=\(width), oversample=\(oversample)")

        var accum = [Float](repeating: -.greatestFiniteMagnitude, count: bins * width)
        var windowed = scratch.windowed; scratch.windowed = []
        if windowed.count != fftLen { windowed = [Float](repeating: 0, count: fftLen) }
        var realp = scratch.realp; scratch.realp = []
        var imagp = scratch.imagp; scratch.imagp = []
        var mags  = scratch.mags;  scratch.mags  = []
        if realp.count != bins { realp = [Float](repeating: 0, count: bins) }
        if imagp.count != bins { imagp = [Float](repeating: 0, count: bins) }
        if mags.count  != bins { mags  = [Float](repeating: 0, count: bins) }
        let scale: Float = 1.0 / Float(fftLen)

        WavPlayerDebugLog.time("STFTGrid", "streamPooledGrid (\(width) buckets x oversample \(oversample))") {
        pcm.withUnsafeBufferPointer { pBuf in
            // Iterate by OUTPUT bucket (not by native frame) so each bucket's
            // own native-frame range can be strided independently — a fixed
            // global stride can't guarantee every bucket gets visited (see
            // the old per-frame version's own comment on that), but a
            // per-bucket range always starts its loop at `bucketStart`, so
            // every bucket is guaranteed at least one sample regardless of
            // how coarse the stride gets.
            for bucket in 0..<width {
                let bucketStart = bucket * nFrames / width
                let bucketEnd = (bucket + 1) * nFrames / width   // exclusive; next bucket's own start
                let bucketFrameCount = max(1, bucketEnd - bucketStart)
                let stride = max(1, bucketFrameCount / oversample)
                var frame = bucketStart
                while frame < bucketEnd {
                    let start = frame * hop
                    vDSP_vmul(pBuf.baseAddress! + start, 1, hannWindow, 1,
                              &windowed, 1, vDSP_Length(windowLen))
                    windowed.withUnsafeBufferPointer { wBuf in
                        wBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { cplx in
                            realp.withUnsafeMutableBufferPointer { rp in
                                imagp.withUnsafeMutableBufferPointer { ip in
                                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                                    vDSP_ctoz(cplx, 2, &split, 1, vDSP_Length(bins))
                                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                                    vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(bins))
                                }
                            }
                        }
                    }
                    var s = scale
                    vDSP_vsmul(mags, 1, &s, &mags, 1, vDSP_Length(bins))
                    // Vectorized dB conversion — see the matching comment in
                    // `compute` above; same fix, same rationale.
                    var floor: Float = 1e-9
                    vDSP_vthr(mags, 1, &floor, &mags, 1, vDSP_Length(bins))
                    var count32 = Int32(bins)
                    vvlog10f(&mags, mags, &count32)
                    var scale20: Float = 20.0
                    vDSP_vsmul(mags, 1, &scale20, &mags, 1, vDSP_Length(bins))
                    // Vectorized element-wise max instead of a per-bin scalar
                    // loop — same fix as RecordingSpectrogramRenderer.renderGrid's
                    // accumulation loop, same reasoning: this ran once per
                    // visited frame (up to width*oversample times, e.g.
                    // 1536*8=12,288 for a detail tile), each iterating `bins`
                    // (1024) times. `accum`'s bin-major layout ([bin*width+bucket])
                    // gives the write side stride `width`, which vDSP_vmax's
                    // stride parameters take directly.
                    accum.withUnsafeMutableBufferPointer { acc in
                        mags.withUnsafeBufferPointer { m in
                            vDSP_vmax(m.baseAddress!, 1,
                                      acc.baseAddress! + bucket, vDSP_Stride(width),
                                      acc.baseAddress! + bucket, vDSP_Stride(width),
                                      vDSP_Length(bins))
                        }
                    }
                    frame += stride
                }
            }
        }
        }

        scratch.windowed = windowed
        scratch.realp = realp
        scratch.imagp = imagp
        scratch.mags = mags
        WavPlayerDebugLog.log("STFTGrid", "streamPooledGrid: done, width=\(width)")
        return (accum, width)
    }
}
