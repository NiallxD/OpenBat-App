//
//  SpectrogramProcessor.swift
//  OpenBat
//
//  Turns the Griff's raw audio stream into spectrogram columns: a windowed,
//  overlapping FFT (Accelerate vDSP) producing one normalised dB-magnitude
//  column per hop. Runs on the realtime audio thread (cheap); finished columns
//  are queued for the Metal renderer to drain on the main thread.
//
//  The analysis window is deliberately shorter than the FFT: a `windowLen`-sample
//  Hann window is zero-padded up to `fftSize` before transforming, interpolating
//  extra (sharper-looking) frequency bins — a shorter analysis window smears each
//  column over less time, at the cost of coarser *true* frequency resolution,
//  which the zero-padding then interpolates back to a comparably sharp-looking
//  frequency axis. `hopSize` is windowLen/2 (50% overlap) so consecutive columns
//  blend smoothly instead of looking blocky — losing that overlap (hop ==
//  windowLen, briefly, in an earlier revision) was the main reason the live view
//  looked visibly rougher than PulseImageRenderer's zoomed pulse view, which uses
//  a much higher overlap ratio. Same windowing trick PulseImageRenderer uses.
//

import AVFoundation
import Accelerate

/// Not main-actor isolated: `process(_:)` is called from the realtime audio tap.
/// Mutable DSP state is only touched on that single serial callback thread; the
/// `pending` hand-off to the renderer is lock-protected.
nonisolated final class SpectrogramProcessor: @unchecked Sendable {

    /// One finished FFT column plus its own dominant-bin info. Carrying the peak
    /// per-column (rather than reading the processor's shared `peakLevel`) is
    /// essential: `draw()` drains a *batch* of columns at once, so the shared
    /// value only reflects the last column and can't be used for per-column
    /// pulse detection.
    struct Column {
        let magnitudes: [Float]
        let peakBin: Int
        let peakLevel: Float
        /// Absolute index (in the continuous input stream) of the sample just past
        /// this column's FFT frame. Lets the pulse detector anchor captures to the
        /// PCM ring by absolute position, independent of how columns batch up when
        /// the renderer drains — the source of the old onset jitter.
        let endSample: Int
    }

    /// Raw samples consumed per column (Hann-windowed). Shorter than `fftSize` —
    /// the FFT itself is zero-padded, which sharpens the frequency axis without
    /// changing the time resolution or the hop cadence.
    let windowLen: Int
    /// Zero-padded FFT length. `binCount` (and therefore frequency resolution)
    /// scales with this, independent of `windowLen`.
    let fftSize: Int
    let hopSize: Int
    var binCount: Int { fftSize / 2 }

    /// Fixed floor/ceiling used ONLY for pulse-detection triggering and the
    /// heterodyne auto-tuner (`peakBin`/`peakLevel`/`Column.peakLevel`) — kept
    /// static so trigger sensitivity never silently shifts with the adaptive
    /// display contrast below. `amplitudeThreshold`'s "matches spectrogram
    /// brightness" calibration refers to this fixed scale, not the live display.
    var minDB: Float = -90
    var maxDB: Float = -20

    /// Adaptive DISPLAY contrast: a fixed −20 dBFS ceiling looked muted/low-contrast
    /// whenever real signal levels sat well below that — the main reason the live
    /// view looked visibly worse than PulseImageRenderer's pulse view, which
    /// normalizes each capture relative to ITS OWN peak. `runningCeilingDB` tracks
    /// recent loudness the same way (snaps up instantly on a louder column, decays
    /// gradually otherwise so it doesn't flicker column-to-column), and the
    /// display range rides `dynamicRangeDB` below it instead of a fixed ceiling.
    private let dynamicRangeDB: Float = 70       // same total contrast "stretch" as the old fixed 70 dB span
    private let ceilingHeadroomDB: Float = 3     // a little air above the tracked peak, not pinned to pure white
    private let ceilingDecayPerColumn: Float = 0.015   // ≈ 22 dB/s "AGC release" at 1500 cols/s
    /// Hard floor for the ceiling — without one, it happily decays all the way
    /// down to track the ambient noise floor's own peak whenever nothing louder
    /// has happened recently, which stretches the display's contrast window
    /// across near-silence and makes faint background hiss look like real
    /// activity. A real bat call comfortably clears this; ambient noise shouldn't.
    private let minCeilingDB: Float = -40
    private var runningCeilingDB: Float = -40

    // MARK: Auto-tune support
    //
    // Each column we record the loudest bin (above `minPeakFraction` of the band,
    // to skip low-frequency rumble). `peakFrequency` exposes it in Hz for the
    // heterodyne auto-tuner. Written on the audio thread, read on the main thread;
    // single-writer/single-reader of plain values is benign for this use.

    /// Sample rate of the captured stream, needed to convert bins → Hz. Set from
    /// the audio path once the rate is known.
    var sampleRate: Double = 0
    /// Set (from the main thread) while a sheet covers the live spectrogram and
    /// its Metal render loop is paused (see `SpectrogramView.isPaused`). Skips
    /// FFT column generation entirely — a plain Bool read/write is fine here:
    /// it only ever gates a coarse "do the analysis or don't" branch, so a
    /// stale read for one buffer either way is harmless. Without this, `process`
    /// kept generating columns nobody was draining, both wasting audio-thread
    /// CPU and building a backlog that made the display "catch up" in a rapid
    /// fast-forward once the render loop resumed.
    nonisolated(unsafe) var suspended = false
    /// Normalised (0…1) magnitude required before a peak counts as a detection.
    var peakThreshold: Float = 0.5
    /// Restrict the peak search to this fraction-of-Nyquist band (matches the
    /// spectrogram's displayed frequency range), so auto-tune ignores out-of-band
    /// noise. `peakMinFraction` also keeps the search off the very lowest bins.
    var peakMinFraction: Double = 0.05
    var peakMaxFraction: Double = 1.0

    private(set) nonisolated(unsafe) var peakBin = 0
    private(set) nonisolated(unsafe) var peakLevel: Float = 0

    /// Dominant frequency in Hz, or 0 when there's no confident detection.
    var peakFrequency: Double { frequency(forBin: peakBin, level: peakLevel) }

    /// Converts a column's dominant bin to Hz, returning 0 when the level is
    /// below the detection threshold or the sample rate is unknown.
    func frequency(forBin bin: Int, level: Float) -> Double {
        guard sampleRate > 0, level >= peakThreshold else { return 0 }
        return Double(bin) * sampleRate / Double(fftSize)
    }

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]

    // Reused scratch buffers (audio thread only).
    private var accumulator: [Float] = []
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]

    // Renderer hand-off.
    private let lock = NSLock()
    private var pending: [Column] = []

    // Raw PCM ring buffer for the classifier (written on audio thread, read on main thread).
    // 10 s @ 384 kHz = 3,840,000 samples ≈ 15 MB.
    private let pcmCapacity = 3_840_000
    private var pcmBuffer: [Float]
    private var pcmHead = 0          // next write index
    private var pcmFilled = false    // true once the buffer has wrapped at least once
    private var pcmTotalWritten = 0  // total samples ever written (the stream's absolute clock)
    private let pcmLock = NSLock()

    /// Absolute index (in the continuous input stream) of `accumulator[0]`. Advances
    /// as consumed samples are trimmed; used to stamp each column's `endSample`.
    private var accumAbsStart = 0

    init(windowLen: Int = 512, fftSize: Int = 2048, hopSize: Int = 256) {
        pcmBuffer = [Float](repeating: 0, count: 3_840_000)
        self.windowLen = windowLen
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        self.window = [Float](repeating: 0, count: windowLen)
        vDSP_hann_window(&window, vDSP_Length(windowLen), Int32(vDSP_HANN_NORM))

        // Zero-padded: only the first `windowLen` entries are ever written (in
        // makeColumn), so the tail stays zero for every FFT — the padding itself.
        self.windowed = [Float](repeating: 0, count: fftSize)
        self.realp = [Float](repeating: 0, count: fftSize / 2)
        self.imagp = [Float](repeating: 0, count: fftSize / 2)
        self.magnitudes = [Float](repeating: 0, count: fftSize / 2)
        accumulator.reserveCapacity(fftSize * 4)
    }

    // MARK: PCM snapshot (main thread)

    /// Returns `count` samples ending `startSamplesBack` samples before the most recent.
    /// `startSamplesBack = 0` returns the most recent `count` samples.
    /// Returns an empty array if the requested window isn't in the ring buffer.
    func pcmSnapshot(count: Int, startSamplesBack: Int = 0) -> [Float] {
        pcmLock.lock()
        defer { pcmLock.unlock() }
        return pcmSnapshotLocked(count: count, startSamplesBack: startSamplesBack)
    }

    /// Returns `count` samples ending at absolute stream index `endAbsolute`
    /// (exclusive) — i.e. samples `[endAbsolute - count, endAbsolute)`. Anchoring by
    /// absolute index (stamped on each `Column.endSample`) keeps the captured pulse
    /// window fixed regardless of drain timing. Empty if the range has scrolled out
    /// of the ring or lies in the future.
    func pcmSnapshot(count: Int, endingAtAbsolute endAbsolute: Int) -> [Float] {
        // ONE lock across the whole mapping: reading `pcmTotalWritten`, releasing, then
        // re-locking to read `pcmHead` let the audio thread advance both between the two
        // reads, so `startSamplesBack` (from the old total) no longer lined up with the
        // now-newer head — shifting the "absolute-anchored" window by up to one IO
        // buffer. Computing startBack and copying under a single held lock keeps the
        // window pinned to the exact absolute range requested.
        pcmLock.lock()
        defer { pcmLock.unlock() }
        guard endAbsolute <= pcmTotalWritten else { return [] }
        return pcmSnapshotLocked(count: count, startSamplesBack: pcmTotalWritten - endAbsolute)
    }

    /// Core ring copy — caller must already hold `pcmLock`. The audio thread mutates
    /// `pcmBuffer` through an unsafe pointer, so reading it (and `pcmHead`) must happen
    /// under the lock. The windows are small (≤ ~120 KB), so the copy costs microseconds.
    private func pcmSnapshotLocked(count: Int, startSamplesBack: Int) -> [Float] {
        let available = pcmFilled ? pcmCapacity : pcmHead
        let totalBack = count + startSamplesBack
        guard startSamplesBack >= 0, available >= totalBack else { return [] }

        var out = [Float](repeating: 0, count: count)
        // The window ends `startSamplesBack` before head.
        let end   = (pcmHead - startSamplesBack + pcmCapacity) % pcmCapacity
        let start = (end  - count               + pcmCapacity) % pcmCapacity
        if start < end {
            out.replaceSubrange(0..<count, with: pcmBuffer[start..<end])
        } else {
            let firstLen = pcmCapacity - start
            out.replaceSubrange(0..<firstLen,  with: pcmBuffer[start...])
            out.replaceSubrange(firstLen..<count, with: pcmBuffer[0..<end])
        }
        return out
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    // MARK: Audio thread

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        // Feed the PCM ring buffer for the classifier. Block-copy (at most two
        // memcpy chunks around the ring wrap) instead of a per-sample loop — this
        // runs on the realtime audio thread, so the vectorised copy matters.
        pcmLock.lock()
        pcmBuffer.withUnsafeMutableBufferPointer { dst in
            var srcOffset = 0
            while srcOffset < frames {
                let chunk = min(frames - srcOffset, pcmCapacity - pcmHead)
                dst.baseAddress!.advanced(by: pcmHead)
                    .update(from: channel + srcOffset, count: chunk)
                pcmHead += chunk
                if pcmHead == pcmCapacity { pcmHead = 0; pcmFilled = true }
                srcOffset += chunk
            }
        }
        pcmTotalWritten += frames
        pcmLock.unlock()

        accumulator.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))

        guard !suspended else {
            // No display/pulse-detector is draining columns right now — skip the
            // FFT work and just keep the accumulator from growing unbounded,
            // preserving the trailing overlap so resuming picks up cleanly.
            let keep = windowLen - 1
            if accumulator.count > keep {
                let drop = accumulator.count - keep
                accumulator.removeFirst(drop)
                accumAbsStart += drop
            }
            return
        }

        var columns: [Column] = []
        var offset = 0
        while accumulator.count - offset >= windowLen {
            // Absolute index just past this frame's last real (non-padded) sample.
            let endSample = accumAbsStart + offset + windowLen
            columns.append(makeColumn(from: offset, endSample: endSample))
            offset += hopSize
        }
        // Keep the unconsumed tail (it overlaps the next window).
        if offset > 0 {
            accumulator.removeFirst(offset)
            accumAbsStart += offset
        }

        guard !columns.isEmpty else { return }
        lock.lock()
        pending.append(contentsOf: columns)
        lock.unlock()
    }

    // MARK: Main thread

    /// Returns and clears the columns produced since the last call.
    func drain() -> [Column] {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return [] }
        let columns = pending
        pending.removeAll(keepingCapacity: true)
        return columns
    }

    // MARK: FFT

    private func makeColumn(from offset: Int, endSample: Int) -> Column {
        // Apply the Hann window over the windowLen frame starting at `offset`;
        // `windowed`'s tail (windowLen..<fftSize) is left untouched — the zero pad.
        accumulator.withUnsafeBufferPointer { acc in
            vDSP_vmul(acc.baseAddress! + offset, 1, window, 1, &windowed, 1, vDSP_Length(windowLen))
        }

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    let interleaved = raw.bindMemory(to: DSPComplex.self).baseAddress!
                    vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(binCount))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(binCount))
            }
        }

        // Normalise amplitude, convert to dB, scale into 0...1 for the colormap.
        // Fully vectorised (vDSP/vForce) — this runs per hop on the realtime thread.
        let n = vDSP_Length(binCount)
        var scale = 1.0 / Float(fftSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, n)        // magnitude / fftSize
        var bias: Float = 1e-7
        vDSP_vsadd(magnitudes, 1, &bias, &magnitudes, 1, n)         // + epsilon (avoid log 0)
        var count32 = Int32(binCount)
        vvlog10f(&magnitudes, magnitudes, &count32)                 // log10 in place

        // TRIGGER scan: fixed minDB/maxDB range, unchanged from before — pulse
        // detection and heterodyne auto-tune calibration stay put regardless of
        // how the display's adaptive contrast (below) moves.
        // (db − minDB) / range with db = 20·log10(x) collapses to one affine map:
        //   out = log10(x) · (20/range) + (−minDB/range), then clamp to 0…1.
        let range = max(maxDB - minDB, 1)
        var triggerColumn = [Float](repeating: 0, count: binCount)
        var mul: Float = 20 / range
        var add: Float = -minDB / range
        vDSP_vsmsa(magnitudes, 1, &mul, &add, &triggerColumn, 1, n)
        var lo: Float = 0, hi: Float = 1
        vDSP_vclip(triggerColumn, 1, &lo, &hi, &triggerColumn, 1, n)

        // Record the dominant bin within the analysis band for auto-tune.
        let minBin = max(1, Int(Double(binCount) * peakMinFraction))
        let maxBin = min(binCount, max(minBin + 1, Int(Double(binCount) * peakMaxFraction)))
        var bestBin = minBin
        var bestLevel: Float = 0
        for i in minBin..<maxBin where triggerColumn[i] > bestLevel {
            bestLevel = triggerColumn[i]
            bestBin = i
        }
        // Update the shared "latest peak" (read by the heterodyne auto-tuner) and
        // also return it with the column so per-column pulse detection is accurate.
        peakBin = bestBin
        peakLevel = bestLevel

        // DISPLAY column: adaptive ceiling tracking this column's own peak dB, so
        // the live view's contrast stays well-used regardless of absolute signal
        // level — see the property doc comments above.
        var columnMaxLog: Float = 0
        vDSP_maxv(magnitudes, 1, &columnMaxLog, n)
        let columnMaxDB = columnMaxLog * 20
        if columnMaxDB > runningCeilingDB {
            runningCeilingDB = columnMaxDB
        } else {
            runningCeilingDB = max(columnMaxDB, runningCeilingDB - ceilingDecayPerColumn)
        }
        runningCeilingDB = max(runningCeilingDB, minCeilingDB)
        let effMaxDB = min(runningCeilingDB + ceilingHeadroomDB, 0)
        let effMinDB = effMaxDB - dynamicRangeDB
        let dispRange = max(effMaxDB - effMinDB, 1)
        var displayColumn = [Float](repeating: 0, count: binCount)
        var dispMul: Float = 20 / dispRange
        var dispAdd: Float = -effMinDB / dispRange
        vDSP_vsmsa(magnitudes, 1, &dispMul, &dispAdd, &displayColumn, 1, n)
        vDSP_vclip(displayColumn, 1, &lo, &hi, &displayColumn, 1, n)

        return Column(magnitudes: displayColumn, peakBin: bestBin, peakLevel: bestLevel, endSample: endSample)
    }
}
