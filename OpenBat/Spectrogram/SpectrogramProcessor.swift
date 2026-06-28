//
//  SpectrogramProcessor.swift
//  OpenBat
//
//  Turns the Griff's raw audio stream into spectrogram columns: a windowed,
//  overlapping FFT (Accelerate vDSP) producing one normalised dB-magnitude
//  column per hop. Runs on the realtime audio thread (cheap); finished columns
//  are queued for the Metal renderer to drain on the main thread.
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
    }

    let fftSize: Int
    let hopSize: Int
    var binCount: Int { fftSize / 2 }

    /// Display dynamic range. Bins quieter than `minDB` map to 0 (floor colour),
    /// `maxDB` and above map to 1 (peak colour). Tune for the Griff's levels.
    var minDB: Float = -90
    var maxDB: Float = -20

    // MARK: Auto-tune support
    //
    // Each column we record the loudest bin (above `minPeakFraction` of the band,
    // to skip low-frequency rumble). `peakFrequency` exposes it in Hz for the
    // heterodyne auto-tuner. Written on the audio thread, read on the main thread;
    // single-writer/single-reader of plain values is benign for this use.

    /// Sample rate of the captured stream, needed to convert bins → Hz. Set from
    /// the audio path once the rate is known.
    var sampleRate: Double = 0
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

    init(fftSize: Int = 1024, hopSize: Int = 512) {
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        self.window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        self.windowed = [Float](repeating: 0, count: fftSize)
        self.realp = [Float](repeating: 0, count: fftSize / 2)
        self.imagp = [Float](repeating: 0, count: fftSize / 2)
        self.magnitudes = [Float](repeating: 0, count: fftSize / 2)
        accumulator.reserveCapacity(fftSize * 4)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    // MARK: Audio thread

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        accumulator.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))

        var columns: [Column] = []
        var offset = 0
        while accumulator.count - offset >= fftSize {
            columns.append(makeColumn(from: offset))
            offset += hopSize
        }
        // Keep the unconsumed tail (it overlaps the next window).
        if offset > 0 { accumulator.removeFirst(offset) }

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

    private func makeColumn(from offset: Int) -> Column {
        // Apply the Hann window over the fftSize frame starting at `offset`.
        accumulator.withUnsafeBufferPointer { acc in
            vDSP_vmul(acc.baseAddress! + offset, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
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
        var scale = 1.0 / Float(fftSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(binCount))

        let range = max(maxDB - minDB, 1)
        var column = [Float](repeating: 0, count: binCount)
        for i in 0..<binCount {
            let db = 20 * log10(magnitudes[i] + 1e-7)
            column[i] = min(max((db - minDB) / range, 0), 1)
        }

        // Record the dominant bin within the analysis band for auto-tune.
        let minBin = max(1, Int(Double(binCount) * peakMinFraction))
        let maxBin = min(binCount, max(minBin + 1, Int(Double(binCount) * peakMaxFraction)))
        var bestBin = minBin
        var bestLevel: Float = 0
        for i in minBin..<maxBin where column[i] > bestLevel {
            bestLevel = column[i]
            bestBin = i
        }
        // Update the shared "latest peak" (read by the heterodyne auto-tuner) and
        // also return it with the column so per-column pulse detection is accurate.
        peakBin = bestBin
        peakLevel = bestLevel

        return Column(magnitudes: column, peakBin: bestBin, peakLevel: bestLevel)
    }
}
