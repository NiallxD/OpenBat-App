//
//  SpectralDenoise.swift
//  OpenBat
//
//  Removes broadband hiss from ultrasonic audio by measuring the noise level
//  IN EACH FREQUENCY BAND SEPARATELY and subtracting it there.
//
//  Why not the expander this replaced (SnippetExpansionProcessor, deleted
//  2026-09-01). That was a single broadband volume knob driven by a 0.33 ms
//  RMS block: it could tell loud from quiet but never hiss from call, so
//  during a call — the part that matters — it did nothing, and between calls
//  it turned everything down together. Worse, slowed 16× its gain moved at up
//  to ~190 Hz, inside the audio band, so it amplitude-modulated the very calls
//  it was meant to clean up. That is what "squeaky" was.
//
//  A bat call occupies a few kHz for a few milliseconds. Hiss occupies
//  everything, all the time. Separating them per-bin is therefore easy and
//  separating them per-moment is impossible, which is the whole argument for
//  this file.
//
//  This is the spectrogram's noise-floor control applied to the audio instead
//  of to the picture — the same operation, the same intuition, a different
//  destination.
//
//  TWO DRIVERS, ONE CORE. `denoiseOffline` is for a finite buffer already
//  wholly in hand (a captured snippet), and can therefore measure the noise
//  from the recording itself before deciding anything. `denoiseStreaming` is
//  for audio arriving a block at a time (file playback), and tracks the noise
//  as it goes. The per-bin subtraction is identical; only the estimator differs.
//
//  Threading: `nonisolated` and allocation-free after `init`, so an instance
//  can be driven from a background worker or a realtime thread. One instance is
//  single-threaded — it holds scratch and overlap state — so give each caller
//  its own.
//

import Accelerate

/// How hard the cleanup pushes.
nonisolated enum DenoiseStrength {
    /// Subtract the measured noise and leave a quiet, steady bed behind it.
    /// Nothing is ever silenced outright, so a call's faintest tail survives at
    /// the cost of the background still being there at about −20 dB.
    case reduce
    /// Keep ONLY the parts of the recording that are plainly a call, and put
    /// digital silence everywhere else — the audio equivalent of the
    /// spectrogram's noise floor crushing everything below it to black, which
    /// is where the idea came from (Niall, 2026-09-01: "if we could only play
    /// back that view it would be clean").
    ///
    /// Available both offline and streaming. The mask cleaning a hard gate
    /// needs looks only at each cell's immediate neighbours, so streaming costs
    /// two frames of lookahead — 1.3 ms at 384 kHz — rather than the whole
    /// signal. (An earlier version of this comment claimed otherwise, which is
    /// why heterodyne went without it for a while.)
    case scrub
}

nonisolated final class SpectralDenoiser {

    /// 512 at 384 kHz is a 1.33 ms window with 750 Hz bins. Short enough not to
    /// smear a 2 ms call across its own analysis, fine enough to separate a
    /// call's band from the hiss either side of it. The hop is half the window,
    /// which is what makes the square of a root-Hann window overlap-add back to
    /// exactly 1 — so a frame whose gains are all 1 reconstructs the input
    /// sample-for-sample, and "denoising off" is provably transparent.
    static let fftSize = 512
    static let hop = fftSize / 2

    /// Nothing is attenuated further than this. A hard zero is what produces
    /// "musical noise" — isolated surviving bins warbling in an otherwise dead
    /// spectrum — so the floor leaves a quiet, steady bed for the ear to sit
    /// against instead. −20 dB is a large reduction that still sounds like a
    /// recording rather than a gate.
    private let floorGain: Float = 0.1

    /// How much of each bin's signal estimate is carried over from the previous
    /// frame — the "decision-directed" smoothing that makes this method work at
    /// all. See `applyGains` for what it is fixing.
    ///
    /// Swept against the demo file rather than picked. Higher settles more of
    /// the noise onto the floor (0.92 → 71% of quiet bins, 0.96 → 92%,
    /// **0.98 → 98%**, 0.99 → 99%), and 0.98 is where that stops buying
    /// anything. It costs nothing at the other end: the peak bin of a call's
    /// ONSET frame comes through at −0.01 dB at every setting tried, and total
    /// call energy at −0.23 dB, which is the theoretical worry about this
    /// smoothing measured and dismissed.
    private let priorSmoothing: Float = 0.98

    /// Per-bin estimate of the CLEAN signal power in the previous frame, which
    /// is what the smoothing above is applied to.
    private var previousClean: [Float]

    /// The smoothed signal-to-noise estimate `applyGains` last computed, kept so
    /// the streaming scrub gate can be taken from exactly the same number the
    /// gain was — rather than recomputing it and risking the two disagreeing.
    private var lastPriors: [Float]

    // MARK: Scrub mode

    /// How far a bin's smoothed signal estimate must stand above the noise
    /// before `scrub` will let it through at all, in dB. Below this the bin is
    /// silenced outright rather than attenuated.
    private let scrubOpenDB: Float = 6

    /// A time-frequency cell survives speckle removal only if at least this
    /// many of its eight neighbours are also above the gate.
    ///
    /// **This is what makes a hard gate usable.** A bat call is a connected
    /// streak across the spectrogram — every cell in it has neighbours. Noise
    /// that momentarily crosses the threshold is a lone cell, and a lone cell
    /// surviving into otherwise perfect silence is exactly the "bag of gravel"
    /// that stops people using hard gates. Removing anything without company
    /// costs the call nothing and removes essentially all of it.
    private let minNeighbours = 3

    /// Mask of which time-frequency cells survive, one byte per cell,
    /// frame-major. A byte rather than a bit: the neighbour counting below
    /// reads it far more than it writes it.
    private var mask: [UInt8]
    private var maskScratch: [UInt8]
    private let maskFrameCapacity: Int

    // MARK: Streaming scrub delay line
    //
    // Scrub needs a cell's neighbours in BOTH directions before it can decide
    // about that cell, and the dilation then needs the cleaned decisions of its
    // neighbours too. That is two frames of lookahead — no more, because the
    // neighbourhood is 3×3 — so a streaming version just holds the last five
    // frames and emits the middle one. 1.3 ms of added latency at 384 kHz.
    //
    // A ring, not a shift register. It WAS a shift register on the theory that
    // five frames are small enough to move cheaply — measured, that theory was
    // wrong by a mile: shifting four arrays of 256 bins on every frame, 1500
    // frames a second, was most of the difference between Scrub costing 7.8% of
    // a core and Reduce costing 2.7%. In realtime heterodyne playback that
    // lands on the same thread already running the spectrogram's FFTs and the
    // heterodyne's per-sample filtering, which is why the sound stuttered there
    // and nowhere else (Niall, 2026-09-01).
    //
    // `slot(_:)` keeps the "slot 0 is oldest, slot 4 is newest" reading the
    // shift register gave for free.

    private static let scrubHistory = 5
    /// Index of the frame being emitted: the middle of the five, so it has two
    /// frames of context on each side.
    private static let scrubEmitSlot = 2

    /// The GAIN-APPLIED spectrum, not the raw one: `applyGains` has already run
    /// by the time a frame is pushed, so scrub is the reduce path plus a gate
    /// here exactly as it is offline.
    private var histReal: [Float]
    /// Float, not the byte-per-cell the offline path uses, so the neighbour
    /// counting below can be done with vDSP instead of a nested loop per bin.
    /// See `pushAndEmitScrubbedFrame`.
    private var histMask: [Float]
    private var histImag: [Float]
    /// Post-speckle-removal masks for the slots that have enough context.
    private var histClean: [Float]
    /// Scratch for the neighbour sums — three rows plus their total.
    private var rowSumA: [Float]
    private var rowSumB: [Float]
    private var rowSumC: [Float]
    private var neighbourTotal: [Float]
    private var keepMask: [Float]
    /// How many frames have entered the delay line since the last reset — the
    /// ring is not emitting anything until it is full.
    private var histFilled = 0
    /// Physical index of the OLDEST slot. Advancing this by one is what
    /// replaced shifting every buffer.
    private var histOrigin = 0

    /// Physical offset of logical slot `i`, where 0 is oldest.
    private func slot(_ i: Int) -> Int {
        ((histOrigin + i) % Self.scrubHistory) * bins
    }

    /// `dst[b] = src[b-1] + src[b] + src[b+1]`, clamped at both edges — the
    /// three-wide neighbourhood sum the scrub mask needs, as two shifted adds
    /// rather than a loop. Used for both the speckle count and the dilation.
    private func horizontalSum(_ src: UnsafePointer<Float>, into dst: UnsafeMutablePointer<Float>) {
        let inner = vDSP_Length(bins - 2)
        vDSP_vadd(src, 1, src + 1, 1, dst + 1, 1, inner)
        vDSP_vadd(dst + 1, 1, src + 2, 1, dst + 1, 1, inner)
        dst[0] = src[0] + src[1]
        dst[bins - 1] = src[bins - 2] + src[bins - 1]
    }

    private let bins: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    /// Root-Hann, used for BOTH analysis and synthesis — see `fftSize`.
    private var window: [Float]

    // Scratch, all sized at init and never resized.
    private var frame: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var gains: [Float]
    /// Per-bin noise magnitude, in the same units as a frame's own magnitudes.
    private var noise: [Float]

    // Working buffers for the vectorised per-bin maths below. They exist for
    // one reason: **every scalar `for b in 0..<bins` loop in the streaming
    // path was costing 30-45x more in a Debug build than in Release**, and a
    // Debug build is what runs during development. Measured at 384 kHz on one
    // core, feeding 20 ms blocks: Reduce 2.2% of a core at `-O` but **65% at
    // `-Onone`**; Scrub 3.7% against **169%** — i.e. past real time, so
    // playback could not keep up, the spectrogram scrolled slower than the
    // clock and nothing reached the speaker at all (Niall, 2026-09-01).
    // vDSP is precompiled library code and does not care how this file is
    // optimised, so moving the per-bin arithmetic into it removes the cliff
    // rather than just moving it.
    private var power: [Float]
    private var noiseSafe: [Float]
    private var tmpA: [Float]
    private var tmpB: [Float]
    private var gainsCopy: [Float]

    /// Reconstruction buffer for the offline driver: the overlap-add
    /// destination, sized for the largest snippet a caller declared.
    private var outBuffer: [Float]
    private let capacity: Int

    // MARK: Offline noise probe

    /// At most this many frames are measured to estimate the noise, spread
    /// evenly across the whole buffer. A cap rather than "every frame" keeps
    /// both the memory and the sort below fixed regardless of snippet length —
    /// and 256 frames is already far more than a percentile needs.
    private static let maxProbeFrames = 256
    /// `maxProbeFrames × bins` magnitudes, frame-major.
    private var probe: [Float]
    /// One bin's magnitudes across the probed frames, sorted in place.
    private var probeColumn: [Float]

    /// Which point in the sorted per-bin powers is taken as the noise's median.
    /// The median, not a lower quarter: what the gain rule wants is the noise's
    /// mean POWER, and the conversion below is exact for the median only. A
    /// snippet is overwhelmingly noise by construction — a tenth of a second
    /// holding one call is ~2% signal — so the median sits safely in it.
    private static let noisePercentile = 0.5

    /// The periodogram of Gaussian noise is exponentially distributed, whose
    /// median is `ln 2` times its mean. Dividing by that turns the robust
    /// measurement above into the mean power the gain rule actually needs.
    private static let medianToMeanPower: Float = 1 / 0.6931472

    // MARK: Streaming state

    /// Frames since the running estimate last rolled over — see
    /// `denoiseStreaming`.
    private var streamFrameCount = 0
    private var runningMin: [Float]
    private var smoothedPower: [Float]

    /// The minimum of a smoothed power still sits below its mean. This lifts it
    /// back — the value is the usual one for this smoothing and window length,
    /// and it only has to be right to within a few dB: the gain rule is not
    /// sharp about the exact noise level, only about it being steady.
    private static let minimumBiasCompensation: Float = 1.5
    private var streamInput: [Float]
    private var streamInputFill = 0
    private var streamOut: [Float]
    private var streamOutFill = 0

    /// How often the running minimum rolls over into the published estimate.
    /// 128 frames is ~16 ms of 384 kHz audio: long enough that a call cannot
    /// occupy the whole span (so the minimum still sees noise), short enough to
    /// follow a site whose background changes.
    private static let streamRolloverFrames = 128

    /// How few frames the first estimate is allowed to be built from. Short
    /// enough not to be heard (8 frames is 5 ms of audio, 85 ms even at 16×),
    /// long enough that the minimum has seen more than one draw.
    private static let streamWarmupFrames = 8

    /// False until a noise estimate has been published at all — see
    /// `updateRunningNoise`.
    private var hasNoiseEstimate = false

    /// Largest block `denoiseStreaming` will accept in one call. Anything
    /// bigger is processed in pieces this size rather than overrunning the
    /// overlap-add buffer — which is what the first version did, silently, for
    /// any block over 512 samples: it emitted the first 512 samples and zeroed
    /// the rest of every block.
    private static let maxStreamBlock = 8192

    /// How many samples of delay `denoiseStreaming` imposes, so a caller that
    /// tracks a position through it can account for the offset.
    ///
    /// One window for the overlap-add either way, plus two more hops for Scrub,
    /// which cannot decide about a frame until it has seen the two after it.
    static func algorithmicDelay(for strength: DenoiseStrength) -> Int {
        fftSize + (strength == .scrub ? 2 * hop : 0)
    }

    /// - Parameter maxOfflineSamples: longest buffer `denoiseOffline` will be
    ///   asked to handle. Pass 0 for a streaming-only instance.
    init(maxOfflineSamples: Int) {
        bins = Self.fftSize / 2
        log2n = vDSP_Length(log2(Double(Self.fftSize)).rounded())
        guard let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("SpectralDenoiser: FFT setup failed")
        }
        setup = s

        // Root of a periodic Hann. `vDSP_hann_window` with `vDSP_HANN_DENORM`
        // gives the periodic form, which is the one that overlap-adds flat.
        var hann = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&hann, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_DENORM))
        var n32 = Int32(Self.fftSize)
        window = [Float](repeating: 0, count: Self.fftSize)
        vvsqrtf(&window, hann, &n32)

        frame = [Float](repeating: 0, count: Self.fftSize)
        realp = [Float](repeating: 0, count: bins)
        imagp = [Float](repeating: 0, count: bins)
        gains = [Float](repeating: 1, count: bins)
        noise = [Float](repeating: 0, count: bins)
        previousClean = [Float](repeating: 0, count: bins)
        lastPriors = [Float](repeating: 0, count: bins)
        runningMin = [Float](repeating: .greatestFiniteMagnitude, count: bins)
        smoothedPower = [Float](repeating: 0, count: bins)
        power = [Float](repeating: 0, count: bins)
        noiseSafe = [Float](repeating: 0, count: bins)
        tmpA = [Float](repeating: 0, count: bins)
        tmpB = [Float](repeating: 0, count: bins)
        gainsCopy = [Float](repeating: 0, count: bins)

        capacity = max(0, maxOfflineSamples)
        outBuffer = [Float](repeating: 0, count: capacity + Self.fftSize)
        maskFrameCapacity = capacity >= Self.fftSize ? (capacity - Self.fftSize) / Self.hop + 1 : 0
        mask = [UInt8](repeating: 0, count: maskFrameCapacity * bins)
        maskScratch = [UInt8](repeating: 0, count: maskFrameCapacity * bins)
        histReal = [Float](repeating: 0, count: Self.scrubHistory * bins)
        histImag = [Float](repeating: 0, count: Self.scrubHistory * bins)
        histMask = [Float](repeating: 0, count: Self.scrubHistory * bins)
        histClean = [Float](repeating: 0, count: Self.scrubHistory * bins)
        rowSumA = [Float](repeating: 0, count: bins)
        rowSumB = [Float](repeating: 0, count: bins)
        rowSumC = [Float](repeating: 0, count: bins)
        neighbourTotal = [Float](repeating: 0, count: bins)
        keepMask = [Float](repeating: 0, count: bins)
        probe = [Float](repeating: 0, count: Self.maxProbeFrames * bins)
        probeColumn = [Float](repeating: 0, count: Self.maxProbeFrames)

        streamInput = [Float](repeating: 0, count: Self.fftSize)
        streamOut = [Float](repeating: 0, count: Self.maxStreamBlock + Self.fftSize * 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    // MARK: Offline

    /// Measure this buffer's own noise, then subtract it, in place.
    ///
    /// Two passes, and the first is what makes this better than any streaming
    /// estimator: with the whole snippet in hand the noise can be read off the
    /// quiet parts *before* a single sample is altered, so nothing has to adapt
    /// and nothing warms up.
    ///
    /// Cheap enough not to think about: a tenth of a second of 384 kHz audio is
    /// ~150 frames, and the replay it prepares lasts 16× the capture, so this
    /// runs in a gap that was previously spent doing nothing at all.
    func denoiseOffline(_ x: UnsafeMutablePointer<Float>, count: Int,
                        strength: DenoiseStrength = .reduce) {
        guard count >= Self.fftSize, count <= capacity else { return }
        let frames = (count - Self.fftSize) / Self.hop + 1
        guard frames > 0 else { return }

        estimateNoiseOffline(x, count: count, frames: frames)

        let scrubbing = strength == .scrub && frames <= maskFrameCapacity
        if scrubbing {
            buildMask(x, frames: frames)
            cleanMask(frames: frames)
        }

        // Each snippet starts from nothing: carrying the last one's signal
        // estimate in would mean the first few frames of a call were shaped by
        // a recording from seconds ago.
        for b in 0..<bins { previousClean[b] = 0 }
        for i in 0..<(count + Self.fftSize) { outBuffer[i] = 0 }
        for f in 0..<frames {
            let start = f * Self.hop
            analyze(x + start)
            applyGains()
            if scrubbing { applyMask(frame: f) }
            synthesize(into: &outBuffer, at: start)
        }
        // Frames only cover whole hops; whatever tail is left over is copied
        // through unaltered rather than dropped — it is at most one hop, and
        // silence there would be an audible click at the end of every replay.
        let covered = (frames - 1) * Self.hop + Self.fftSize
        for i in 0..<min(covered, count) { x[i] = outBuffer[i] }
    }

    /// Per-bin noise magnitude, from the quiet quarter of the probed frames.
    private func estimateNoiseOffline(_ x: UnsafeMutablePointer<Float>, count: Int, frames: Int) {
        let probeCount = min(frames, Self.maxProbeFrames)
        // Evenly spaced across the whole buffer rather than the first N: a pass
        // that begins loud would otherwise have its noise measured entirely
        // from inside the calls.
        let stride = max(1, frames / probeCount)
        for p in 0..<probeCount {
            let f = min(frames - 1, p * stride)
            analyze(x + f * Self.hop)
            for b in 0..<bins {
                probe[p * bins + b] = realp[b] * realp[b] + imagp[b] * imagp[b]
            }
        }
        let index = min(probeCount - 1, Int(Double(probeCount) * Self.noisePercentile))
        for b in 0..<bins {
            for p in 0..<probeCount { probeColumn[p] = probe[p * bins + b] }
            // Only the first `probeCount` entries are live; the rest are stale
            // from a previous, longer snippet.
            probeColumn[0..<probeCount].sort()
            noise[b] = probeColumn[index] * Self.medianToMeanPower
        }
    }

    // MARK: Scrub mask

    /// First pass: mark every time-frequency cell whose smoothed signal
    /// estimate clears `scrubOpenDB`.
    ///
    /// The signal estimate is built with exactly the same recursion
    /// `applyGains` uses, and deliberately WITHOUT the mask applied — so the
    /// final pass, which reruns that recursion, produces identical values and
    /// the mask lines up with the gains it will multiply.
    private func buildMask(_ x: UnsafeMutablePointer<Float>, frames: Int) {
        let open = pow(10, scrubOpenDB / 10)   // a power ratio, not amplitude
        for b in 0..<bins { previousClean[b] = 0 }
        for f in 0..<frames {
            analyze(x + f * Self.hop)
            let row = f * bins
            for b in 0..<bins {
                let power = realp[b] * realp[b] + imagp[b] * imagp[b]
                let noisePower = max(noise[b], 1e-20)
                let observed = power / noisePower
                let prior = priorSmoothing * (previousClean[b] / noisePower)
                          + (1 - priorSmoothing) * max(observed - 1, 0)
                let g = max(floorGain, prior / (1 + prior))
                previousClean[b] = g * g * power
                mask[row + b] = prior > open ? 1 : 0
            }
        }
    }

    /// Second pass: drop cells with no company, then grow what is left by one
    /// cell in each direction.
    ///
    /// The growth matters as much as the removal. A gate that opens exactly on
    /// the surviving cells chops the quiet edges off every call — the onset and
    /// the tail, which are the parts carrying its shape — and switches on and
    /// off abruptly enough to click. One cell of margin (1.3 ms, 750 Hz) keeps
    /// those edges and lets the gain ramp rather than step.
    private func cleanMask(frames: Int) {
        // Speckle removal, reading `mask` and writing `maskScratch`.
        for f in 0..<frames {
            let row = f * bins
            for b in 0..<bins {
                guard mask[row + b] != 0 else { maskScratch[row + b] = 0; continue }
                var neighbours = 0
                for df in -1...1 {
                    let nf = f + df
                    guard nf >= 0, nf < frames else { continue }
                    for db in -1...1 where !(df == 0 && db == 0) {
                        let nb = b + db
                        guard nb >= 0, nb < bins else { continue }
                        if mask[nf * bins + nb] != 0 { neighbours += 1 }
                    }
                }
                maskScratch[row + b] = neighbours >= minNeighbours ? 1 : 0
            }
        }
        // Dilation, reading `maskScratch` and writing back into `mask`.
        for f in 0..<frames {
            let row = f * bins
            for b in 0..<bins {
                var on = false
                for df in -1...1 where !on {
                    let nf = f + df
                    guard nf >= 0, nf < frames else { continue }
                    for db in -1...1 {
                        let nb = b + db
                        guard nb >= 0, nb < bins else { continue }
                        if maskScratch[nf * bins + nb] != 0 { on = true; break }
                    }
                }
                mask[row + b] = on ? 1 : 0
            }
        }
    }

    /// Push the frame currently in `realp`/`imagp`/`gains` into the scrub delay
    /// line, and load the frame from two hops ago back out of it — cleaned,
    /// dilated and gated — ready for `synthesize`.
    ///
    /// Returns false while the line is still filling, in which case there is
    /// nothing to emit yet and `realp`/`imagp` are left alone.
    private func pushAndEmitScrubbedFrame() -> Bool {
        // The oldest slot is overwritten by the newest frame and the origin
        // moves on — no copying. Its mask comes from the same smoothed signal
        // estimate `applyGains` just used, recorded there as `lastPriors` so the
        // two decisions cannot drift apart.
        let newest = slot(0)
        histOrigin = (histOrigin + 1) % Self.scrubHistory
        let open = pow(10, scrubOpenDB / 10)
        histReal.withUnsafeMutableBufferPointer { hr in
            realp.withUnsafeBufferPointer { rp in
                (hr.baseAddress! + newest).update(from: rp.baseAddress!, count: bins)
            }
        }
        histImag.withUnsafeMutableBufferPointer { hi in
            imagp.withUnsafeBufferPointer { ip in
                (hi.baseAddress! + newest).update(from: ip.baseAddress!, count: bins)
            }
        }
        histMask.withUnsafeMutableBufferPointer { hm in
            lastPriors.withUnsafeBufferPointer { lp in
                let m = hm.baseAddress! + newest, p = lp.baseAddress!
                for b in 0..<bins { m[b] = p[b] > open ? 1 : 0 }
            }
        }

        histFilled = min(histFilled + 1, Self.scrubHistory)
        guard histFilled == Self.scrubHistory else { return false }

        // Speckle removal for ONE slot per frame — the newest that has a
        // neighbour on each side — with the results carried along in the shift
        // register like everything else.
        //
        // This used to recompute all three middle slots every frame, on the
        // grounds that carrying them would mean keeping a second buffer in
        // step. It does not: `histClean` shifts with the same loop as the rest,
        // so the work is a third of what it was. That mattered — in realtime
        // heterodyne playback this runs 1500 times a second on the same thread
        // that is already doing the spectrogram's FFTs and the heterodyne's
        // per-sample filtering, and it was enough to make the audio stutter
        // (Niall, 2026-09-01).
        let newestCleanable = Self.scrubHistory - 2
        let cleanRow = slot(newestCleanable)
        let mBefore = slot(newestCleanable - 1), mAfter = slot(newestCleanable + 1)
        // **Counted with vDSP, not with a nested loop per bin.** The nested
        // form did nine bounds-checked reads per bin, 256 bins, 1500 frames a
        // second, and built a fresh Swift Array per bin on top of that
        // (`for base in [a, b, c]` allocates) — around 768 000 heap
        // allocations a second on the thread that has to hand the audio path
        // samples on time. Summing each row's three-wide neighbourhood is
        // just a shifted add, which is one vDSP call per row.
        histMask.withUnsafeBufferPointer { m in
            let mask = m.baseAddress!
            rowSumA.withUnsafeMutableBufferPointer { a in
                horizontalSum(mask + mBefore, into: a.baseAddress!)
            }
            rowSumB.withUnsafeMutableBufferPointer { b in
                horizontalSum(mask + cleanRow, into: b.baseAddress!)
            }
            rowSumC.withUnsafeMutableBufferPointer { c in
                horizontalSum(mask + mAfter, into: c.baseAddress!)
            }
        }
        let n = vDSP_Length(bins)
        vDSP_vadd(rowSumA, 1, rowSumB, 1, &neighbourTotal, 1, n)
        vDSP_vadd(neighbourTotal, 1, rowSumC, 1, &neighbourTotal, 1, n)
        // The row sums include the cell itself; the count is of NEIGHBOURS.
        histMask.withUnsafeBufferPointer { m in
            vDSP_vsub(m.baseAddress! + cleanRow, 1, neighbourTotal, 1, &neighbourTotal, 1, n)
        }
        let threshold = Float(minNeighbours)
        histMask.withUnsafeBufferPointer { m in
            histClean.withUnsafeMutableBufferPointer { c in
                neighbourTotal.withUnsafeBufferPointer { t in
                    let mask = m.baseAddress! + cleanRow, clean = c.baseAddress! + cleanRow
                    let total = t.baseAddress!
                    for b in 0..<bins {
                        clean[b] = (mask[b] != 0 && total[b] >= threshold) ? 1 : 0
                    }
                }
            }
        }

        // Dilate around the emit slot, then gate it and hand it back for
        // synthesis.
        let emit = slot(Self.scrubEmitSlot)
        let cBefore = slot(Self.scrubEmitSlot - 1), cAfter = slot(Self.scrubEmitSlot + 1)
        // Dilation is the same neighbourhood, asked as "any" rather than
        // "how many" — so it is the same three shifted adds, tested against
        // zero. Gating is then a multiply by a 0/1 mask.
        histClean.withUnsafeBufferPointer { c in
            let clean = c.baseAddress!
            rowSumA.withUnsafeMutableBufferPointer { a in
                horizontalSum(clean + cBefore, into: a.baseAddress!)
            }
            rowSumB.withUnsafeMutableBufferPointer { b in
                horizontalSum(clean + emit, into: b.baseAddress!)
            }
            rowSumC.withUnsafeMutableBufferPointer { d in
                horizontalSum(clean + cAfter, into: d.baseAddress!)
            }
        }
        vDSP_vadd(rowSumA, 1, rowSumB, 1, &neighbourTotal, 1, n)
        vDSP_vadd(neighbourTotal, 1, rowSumC, 1, &neighbourTotal, 1, n)
        neighbourTotal.withUnsafeBufferPointer { t in
            keepMask.withUnsafeMutableBufferPointer { k in
                let total = t.baseAddress!, keep = k.baseAddress!
                for b in 0..<bins { keep[b] = total[b] > 0 ? 1 : 0 }
            }
        }
        histReal.withUnsafeBufferPointer { hr in
            realp.withUnsafeMutableBufferPointer { rp in
                vDSP_vmul(hr.baseAddress! + emit, 1, keepMask, 1, rp.baseAddress!, 1, n)
            }
        }
        histImag.withUnsafeBufferPointer { hi_ in
            imagp.withUnsafeMutableBufferPointer { ip in
                vDSP_vmul(hi_.baseAddress! + emit, 1, keepMask, 1, ip.baseAddress!, 1, n)
            }
        }
        realp[0] = 0
        return true
    }

    /// Silence everything the mask rejected. Applied on top of the gains rather
    /// than instead of them, so a cell that survives is still cleaned up —
    /// scrub is the reduce path plus a gate, not a different filter.
    private func applyMask(frame f: Int) {
        let row = f * bins
        for b in 1..<bins where mask[row + b] == 0 {
            realp[b] = 0
            imagp[b] = 0
        }
        if mask[row + bins - 1] == 0 { imagp[0] = 0 }
    }

    // MARK: Streaming

    /// Denoise a block in place, tracking the noise as the audio arrives.
    ///
    /// Output is delayed by one window (1.33 ms at 384 kHz) — the block returns
    /// the audio that arrived one window ago. Irrelevant for playback, and the
    /// reason this is not offered to anything that has to stay in sync with a
    /// live capture.
    ///
    /// The estimator is a rolling per-bin minimum. Hiss is the quietest thing
    /// present in a band that has no call in it, so the minimum over a span
    /// short enough that no call fills it, and long enough to be a real sample,
    /// *is* the noise — see `streamRolloverFrames`.
    func denoiseStreaming(_ x: UnsafeMutablePointer<Float>, count: Int,
                          strength: DenoiseStrength = .reduce) {
        // Split anything oversized rather than overrunning the accumulator.
        guard count <= Self.maxStreamBlock else {
            var done = 0
            while done < count {
                let take = min(Self.maxStreamBlock, count - done)
                denoiseStreaming(x + done, count: take, strength: strength)
                done += take
            }
            return
        }
        var consumed = 0
        while consumed < count {
            let take = min(Self.fftSize - streamInputFill, count - consumed)
            streamInput.withUnsafeMutableBufferPointer { p in
                (p.baseAddress! + streamInputFill).update(from: x + consumed, count: take)
            }
            streamInputFill += take
            consumed += take

            guard streamInputFill == Self.fftSize else { break }

            streamInput.withUnsafeMutableBufferPointer { p in
                analyze(p.baseAddress!)
            }
            updateRunningNoise()
            applyGains()
            if strength == .scrub {
                // Emits the frame from two hops ago, or nothing while the delay
                // line is still filling.
                guard pushAndEmitScrubbedFrame() else {
                    // Still keep the output clock moving, or the caller's
                    // stream would lose these samples rather than be delayed by
                    // them.
                    streamOutFill += Self.hop
                    for i in 0..<(Self.fftSize - Self.hop) {
                        streamInput[i] = streamInput[i + Self.hop]
                    }
                    streamInputFill = Self.fftSize - Self.hop
                    continue
                }
            }
            synthesize(into: &streamOut, at: streamOutFill)

            // One hop consumed from the front, the rest kept as the next
            // frame's overlap. `memmove`, not a copy loop: the regions overlap.
            streamInput.withUnsafeMutableBufferPointer { p in
                _ = memmove(p.baseAddress!, p.baseAddress! + Self.hop,
                            (Self.fftSize - Self.hop) * MemoryLayout<Float>.size)
            }
            streamInputFill = Self.fftSize - Self.hop
            streamOutFill += Self.hop
        }

        // Emit whatever the overlap-add has finished with, and shift it out.
        //
        // **The shift is not optional, and skipping it on the first block was a
        // silent catastrophe.** An earlier version held the first block back to
        // "prime" the overlap and returned before shifting, so the accumulator
        // kept growing; once it passed its own length, `synthesize` hit its
        // bounds check and started discarding frames without a word. Measured
        // against the demo file the streaming output came back 84% zeros and
        // 164 dB down — which from the player sounded like the toggle doing
        // nothing at all (Niall, 2026-09-01).
        //
        // There is no priming any more. Early on there is simply less ready
        // than asked for, and the shortfall is padded — one window's worth,
        // once, at the very start of playback.
        let emit = min(count, streamOutFill)
        streamOut.withUnsafeMutableBufferPointer { p in
            let base = p.baseAddress!
            x.update(from: base, count: emit)
            if emit < count { (x + emit).update(repeating: 0, count: count - emit) }
            // Overlapping regions, so `memmove` rather than a copy loop.
            let remaining = p.count - emit
            if remaining > 0 {
                memmove(base, base + emit, remaining * MemoryLayout<Float>.size)
            }
            (base + remaining).update(repeating: 0, count: emit)
        }
        streamOutFill -= emit
    }

    /// Measure the noise from a sample of the audio that is ABOUT to be played,
    /// so streaming starts already filtering.
    ///
    /// The running estimator needs to see audio before it knows anything, and
    /// what it does meanwhile is nothing — no estimate means no filtering. At
    /// 16× time expansion even a short warm-up is over a second of unfiltered
    /// hiss, and it happens again on every seek. A player knows its file up
    /// front, so it can hand a slice over once at open and skip that entirely
    /// (Niall, 2026-09-01).
    ///
    /// Uses the offline percentile estimator, which is the better one — it sees
    /// the quiet parts directly instead of inferring them from minima. The
    /// running estimator then takes over and tracks any drift from there.
    func seedStreamingNoise(_ x: UnsafePointer<Float>, count: Int) {
        guard count >= Self.fftSize else { return }
        let frames = (count - Self.fftSize) / Self.hop + 1
        guard frames > 0 else { return }
        estimateNoiseOffline(UnsafeMutablePointer(mutating: x), count: count, frames: frames)
        hasNoiseEstimate = true
        // Seeded rather than left empty, or the first rollover would replace a
        // good estimate with a minimum taken over a handful of frames.
        for b in 0..<bins {
            smoothedPower[b] = noise[b]
            runningMin[b] = .greatestFiniteMagnitude
        }
        streamFrameCount = 0
    }

    /// Forget the overlap tail and, unless told otherwise, the noise estimate.
    /// Call when playback seeks or restarts, or the first block after a jump
    /// carries the tail of wherever the playhead used to be.
    ///
    /// `keepingNoise` exists for exactly the seeded case: a seek moves the
    /// playhead but does not change what the recording's background sounds
    /// like, so throwing the estimate away would reintroduce the warm-up on
    /// every scrub.
    func resetStreaming(keepingNoise: Bool = false) {
        streamInputFill = 0
        streamOutFill = 0
        streamFrameCount = 0
        histFilled = 0
        histOrigin = 0
        guard !keepingNoise else {
            for i in 0..<streamOut.count { streamOut[i] = 0 }
            for b in 0..<bins { previousClean[b] = 0 }
            return
        }
        hasNoiseEstimate = false
        for i in 0..<bins {
            runningMin[i] = .greatestFiniteMagnitude
            smoothedPower[i] = 0
            previousClean[i] = 0
            noise[i] = 0
        }
        for i in 0..<streamOut.count { streamOut[i] = 0 }
    }

    /// Minimum statistics: track the minimum of a SMOOTHED power per bin, not
    /// of the raw one. Taking the minimum of raw frames would find the deepest
    /// fluctuation rather than the noise level and read far too low; smoothing
    /// first is what makes the minimum a usable estimator, and
    /// `minimumBiasCompensation` corrects what remains.
    private func updateRunningNoise() {
        let n = vDSP_Length(bins)
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_zvmags(&split, 1, &power, 1, n)
            }
        }
        var keep: Float = 0.9, take: Float = 0.1
        vDSP_vsmsma(smoothedPower, 1, &keep, power, 1, &take, &smoothedPower, 1, n)
        vDSP_vmin(smoothedPower, 1, runningMin, 1, &runningMin, 1, n)
        streamFrameCount += 1

        // **Until the first estimate exists, publish one every frame.**
        // Without this the estimate stays at zero for a whole rollover, which
        // makes every bin look infinitely far above the noise, which sets every
        // gain to 1 — so nothing is filtered at all for the warm-up.
        //
        // That warm-up is 85 ms of AUDIO, which sounds negligible until you
        // remember what this is for: at 16× time expansion it is 1.4 seconds of
        // listening, and it restarts on every seek, every play, and every
        // setting that restarts playback. It is exactly the "always plays noise
        // for the first second" (Niall, 2026-09-01). A running minimum over a
        // handful of frames is a poor estimate, but a poor estimate filters and
        // no estimate does not.
        if !hasNoiseEstimate {
            var bias = Self.minimumBiasCompensation
            vDSP_vsmul(runningMin, 1, &bias, &noise, 1, n)
            if streamFrameCount >= Self.streamWarmupFrames { hasNoiseEstimate = true }
        }

        guard streamFrameCount >= Self.streamRolloverFrames else { return }
        streamFrameCount = 0
        for b in 0..<bins {
            let estimate = runningMin[b] * Self.minimumBiasCompensation
            // Eased rather than replaced, so a rollover that happened to land
            // inside a long call cannot make the estimate jump.
            noise[b] = noise[b] > 0 ? noise[b] * 0.5 + estimate * 0.5 : estimate
            runningMin[b] = .greatestFiniteMagnitude
        }
    }

    // MARK: Core

    /// Windowed forward transform of `fftSize` samples into `realp`/`imagp`.
    private func analyze(_ x: UnsafePointer<Float>) {
        vDSP_vmul(x, 1, window, 1, &frame, 1, vDSP_Length(Self.fftSize))
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { f in
                    f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { c in
                        vDSP_ctoz(c, 2, &split, 1, vDSP_Length(bins))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
    }

    /// Work out how much of each bin to keep, and scale the spectrum by it.
    ///
    /// **The obvious rule — measure the noise, subtract it from this frame's
    /// magnitude, keep the remainder — sounds worse than the hiss it removes,
    /// and measurably so.** Denoising the demo file that way took the hiss down
    /// 17 dB and left the calls alone, but the frame-to-frame level jitter in
    /// the quiet parts went UP (6.0 → 7.6 dB) and the spectral kurtosis with it
    /// (10.6 → 15.1): a smooth bed of hiss had been turned into a sparse
    /// scatter of survivors, each flickering independently. Slowed 16×, that
    /// scatter is an audible warbling (Niall, 2026-09-01 — "a horrible
    /// squabbling sound"). The cause is that a noise bin's magnitude varies
    /// enormously frame to frame even when the noise itself is dead steady, so
    /// a gain computed from one frame's magnitude varies just as much.
    ///
    /// The fix is the standard decision-directed estimator. Instead of asking
    /// "how loud is this bin now", it asks "how much signal does this bin
    /// appear to hold", carrying most of that answer over from the previous
    /// frame. On noise the answer barely moves, so the gain stops flickering;
    /// on a call it moves instantly anyway, because the second term below is
    /// large the moment a real signal arrives. That last property is why this
    /// does NOT blur the onset the way naively averaging the gain over time
    /// would — which is what the previous version of this comment was right to
    /// rule out and wrong to stop there.
    ///
    /// The gain itself is a Wiener gain rather than a subtraction, for the same
    /// reason: it approaches its limits smoothly instead of clipping to a
    /// floor, and a smooth gain rule leaves smooth residual noise.
    private func applyGains() {
        let n = vDSP_Length(bins)
        // power = re² + im², for every bin at once.
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_zvmags(&split, 1, &power, 1, n)
            }
        }
        var tiny: Float = 1e-20
        vDSP_vthr(noise, 1, &tiny, &noiseSafe, 1, n)            // max(noise, 1e-20)

        // How much louder each bin is than the noise, right now, minus one and
        // floored at zero — the "instantaneous" half of the estimate.
        vDSP_vdiv(noiseSafe, 1, power, 1, &tmpA, 1, n)          // observed = power / noise
        var minusOne: Float = -1
        vDSP_vsadd(tmpA, 1, &minusOne, &tmpA, 1, n)
        var zero: Float = 0
        vDSP_vthr(tmpA, 1, &zero, &tmpA, 1, n)                  // max(observed - 1, 0)

        // The inherited half: how much signal the bin looked to hold last
        // frame. Mostly this, so steady noise produces a steady answer.
        vDSP_vdiv(noiseSafe, 1, previousClean, 1, &tmpB, 1, n)
        var a = priorSmoothing, b1 = 1 - priorSmoothing
        vDSP_vsmsma(tmpB, 1, &a, tmpA, 1, &b1, &lastPriors, 1, n)   // prior

        // Wiener gain: prior / (1 + prior), floored.
        var one: Float = 1
        vDSP_vsadd(lastPriors, 1, &one, &tmpA, 1, n)
        vDSP_vdiv(tmpA, 1, lastPriors, 1, &gains, 1, n)
        var floorG = floorGain
        vDSP_vthr(gains, 1, &floorG, &gains, 1, n)

        // previousClean = g² · power — from the UNSMOOTHED gain, as before:
        // the smoothing below is a display-of-the-spectrum decision, not part
        // of the estimator's own recursion.
        vDSP_vmul(gains, 1, gains, 1, &tmpA, 1, n)
        vDSP_vmul(tmpA, 1, power, 1, &previousClean, 1, n)

        // Smoothed across FREQUENCY, never across time. Neighbouring bins
        // agreeing is what stops isolated survivors warbling (musical noise);
        // smoothing across time instead would blur the 2 ms onset this whole
        // mode exists to let you hear.
        //
        // A plain 3-tap average over the ORIGINAL gains — the scalar version
        // carried the pre-overwrite neighbour in `previous` to get exactly
        // that, so it needs a copy here. Bins 0 and bins-1 are left alone,
        // same as before.
        gainsCopy.withUnsafeMutableBufferPointer { gc in
            gains.withUnsafeBufferPointer { g in
                gc.baseAddress!.update(from: g.baseAddress!, count: bins)
            }
        }
        let inner = vDSP_Length(bins - 2)
        gainsCopy.withUnsafeBufferPointer { gc in
            let base = gc.baseAddress!
            tmpA.withUnsafeMutableBufferPointer { t in
                vDSP_vadd(base, 1, base + 1, 1, t.baseAddress! + 1, 1, inner)
                vDSP_vadd(t.baseAddress! + 1, 1, base + 2, 1, t.baseAddress! + 1, 1, inner)
            }
        }
        var third: Float = 1.0 / 3.0
        tmpA.withUnsafeBufferPointer { t in
            gains.withUnsafeMutableBufferPointer { g in
                vDSP_vsmul(t.baseAddress! + 1, 1, &third, g.baseAddress! + 1, 1, inner)
            }
        }

        // Apply, from bin 1 up — bin 0 is handled separately below.
        let upper = vDSP_Length(bins - 1)
        gains.withUnsafeBufferPointer { g in
            realp.withUnsafeMutableBufferPointer { rp in
                vDSP_vmul(rp.baseAddress! + 1, 1, g.baseAddress! + 1, 1, rp.baseAddress! + 1, 1, upper)
            }
            imagp.withUnsafeMutableBufferPointer { ip in
                vDSP_vmul(ip.baseAddress! + 1, 1, g.baseAddress! + 1, 1, ip.baseAddress! + 1, 1, upper)
            }
        }
        // `realp[0]`/`imagp[0]` are DC and Nyquist packed together, not a bin
        // pair. DC is dropped outright — there is a high-pass upstream of every
        // caller and a DC offset is a known trait of this hardware — and
        // Nyquist takes the topmost bin's gain.
        realp[0] = 0
        imagp[0] *= gains[bins - 1]
    }

    /// Inverse transform, window again, and overlap-add into `dst` at `offset`.
    private func synthesize(into dst: inout [Float], at offset: Int) {
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                frame.withUnsafeMutableBufferPointer { f in
                    f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { c in
                        vDSP_ztoc(&split, 1, c, 2, vDSP_Length(bins))
                    }
                }
            }
        }
        // `vDSP_fft_zrip` scales by 2 forward and by fftSize on the inverse.
        var scale = 1.0 / Float(2 * Self.fftSize)
        vDSP_vsmul(frame, 1, &scale, &frame, 1, vDSP_Length(Self.fftSize))
        vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(Self.fftSize))
        guard offset + Self.fftSize <= dst.count else { return }
        frame.withUnsafeBufferPointer { f in
            dst.withUnsafeMutableBufferPointer { d in
                let at = d.baseAddress! + offset
                vDSP_vadd(at, 1, f.baseAddress!, 1, at, 1, vDSP_Length(Self.fftSize))
            }
        }
    }
}
