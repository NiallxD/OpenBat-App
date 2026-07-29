//
//  MicCalibrator.swift
//  OpenBat
//
//  Captures ~30s of audio during a deliberately quiet period to measure a
//  microphone's own frequency response, producing a `MicCalibrationCurve`.
//  Deliberately a small, self-contained FFT pass — not a reuse of
//  `SpectrogramProcessor`, which is coupled to ring-buffer/renderer/trigger-
//  scan machinery this doesn't need — but mirrors its exact window/FFT/hop
//  parameters (512/2048/256/1024) so the measured curve lines up bin-for-bin
//  with what it will later correct.
//
//  Quality gates catch the ways a "quiet period" recording can be unusable:
//  interrupted (too short), the input overloaded (clipping), a real sound
//  happened during the window (a call, a knock, a voice — not steady self-
//  noise), or there's no real signal path at all (muted/disconnected input).
//  A failed run never produces a curve, so it can never overwrite a
//  previously-saved good one.
//

import AVFoundation
import Accelerate

/// `@unchecked Sendable`: captured in `AudioEngineController.bufferSink`
/// (a `@Sendable` closure) the same way `SpectrogramProcessor` is — all
/// mutable state is guarded by `stateLock`, so it's genuinely safe to touch
/// from both the audio thread (`feed`) and the main thread (`finish`/`progress`).
final class MicCalibrator: @unchecked Sendable {

    enum Result {
        case success(MicCalibrationCurve)
        case failure(reason: String)
    }

    // Mirrors SpectrogramProcessor's grid exactly — see MicCalibrationCurve's
    // doc comment for why that match matters.
    private static let windowLen = 512
    private static let fftSize = 2048
    private static let hopSize = 256
    private static let binCount = 2048 / 2 // 1024

    /// Roughly ±12 dB — wide enough to correct a real resonance, tight enough
    /// that a near-dead bin (edge-of-band rolloff) can't get boosted into a
    /// false noise line. Starting point; tune against real hardware.
    private static let minGainDB: Float = -12
    private static let maxGainDB: Float = 12
    /// A column's BROADBAND (mean-across-all-bins) level reading this many dB
    /// above the session's own median broadband level is elevated. Compared
    /// against the mean rather than a single bin's peak deliberately — the
    /// loudest of 1024 bins is an extreme-value statistic that spikes well
    /// above its own median from ordinary noise variance alone over tens of
    /// thousands of columns, even with zero real sound, which is exactly what
    /// made an earlier version of this check fail in genuinely quiet rooms.
    /// Starting point; tune against real hardware/recordings. Not `private`:
    /// `MicCalibrationView`'s live level meter uses the same number to color
    /// its green/orange/red thresholds, so the on-screen hint during
    /// recording actually reflects what will and won't pass this check.
    static let transientMarginDB: Float = 12
    /// How many CONSECUTIVE elevated columns count as a genuine transient (a
    /// call, a knock, a voice) rather than one statistical outlier column —
    /// a real bat call or knock spans several overlapping analysis windows
    /// even at its shortest, so requiring a short run filters single-column
    /// noise spikes without missing a real, brief sound.
    private static let transientMinRunColumns = 4
    /// `|sample|` at or above this is treated as overload/handling noise.
    private static let clipThreshold: Float = 0.98
    /// Mean linear magnitude below this is treated as "no real signal path"
    /// (muted/disconnected input) rather than a quiet self-noise floor.
    private static let deadSignalFloor: Float = 1e-6

    private let sampleRate: Double
    private let minColumns: Int

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var accumulator: [Float] = []

    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]

    // Per-bin running sum (linear magnitude) — mean is all the curve math
    // needs; no per-bin variance tracking, the "not quiet" check below works
    // off the per-column broadband trace instead (see columnBroadbandDB).
    private var binSum: [Float]
    private var columnCount = 0

    private var columnBroadbandDB: [Float] = []
    private var clippingDetected = false

    /// `feed` runs on the realtime audio thread (called from a temporarily-
    /// installed `bufferSink`); `finish()`/`progress` are read from the main
    /// thread once the sheet's countdown ends. The one instant those can
    /// genuinely overlap — the last in-flight `feed` call as the sheet stops
    /// installing new ones — is real enough to guard properly rather than
    /// wave off as "benign," since this holds several arrays, not a scalar.
    private let stateLock = NSLock()

    init(sampleRate: Double, captureSeconds: Double = 30) {
        self.sampleRate = sampleRate
        let columnsPerSecond = sampleRate / Double(Self.hopSize)
        self.minColumns = Int(columnsPerSecond * captureSeconds * 0.9)

        self.log2n = vDSP_Length(log2(Float(Self.fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.window = [Float](repeating: 0, count: Self.windowLen)
        vDSP_hann_window(&window, vDSP_Length(Self.windowLen), Int32(vDSP_HANN_NORM))

        self.windowed = [Float](repeating: 0, count: Self.fftSize)
        self.realp = [Float](repeating: 0, count: Self.binCount)
        self.imagp = [Float](repeating: 0, count: Self.binCount)
        self.magnitudes = [Float](repeating: 0, count: Self.binCount)
        self.binSum = [Float](repeating: 0, count: Self.binCount)
        accumulator.reserveCapacity(Self.fftSize * 4)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Fed from a temporarily-installed `AudioEngineController.bufferSink` —
    /// same shape as `SpectrogramProcessor.process`.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var peak: Float = 0
        vDSP_maxmgv(channel, 1, &peak, vDSP_Length(frames))

        stateLock.lock()
        defer { stateLock.unlock() }
        if peak >= Self.clipThreshold { clippingDetected = true }

        accumulator.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))

        var offset = 0
        while accumulator.count - offset >= Self.windowLen {
            processColumn(from: offset)
            offset += Self.hopSize
        }
        if offset > 0 {
            accumulator.removeFirst(offset)
        }
    }

    /// Fraction (0...1) of the target capture completed, for the sheet's
    /// progress ring.
    var progress: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard minColumns > 0 else { return 0 }
        return min(1, Double(columnCount) / Double(minColumns))
    }

    private func processColumn(from offset: Int) {
        accumulator.withUnsafeBufferPointer { acc in
            vDSP_vmul(acc.baseAddress! + offset, 1, window, 1, &windowed, 1, vDSP_Length(Self.windowLen))
        }
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    let interleaved = raw.bindMemory(to: DSPComplex.self).baseAddress!
                    vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(Self.binCount))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(Self.binCount))
            }
        }

        let n = vDSP_Length(Self.binCount)
        vDSP_vadd(binSum, 1, magnitudes, 1, &binSum, 1, n)
        columnCount += 1

        // Broadband (mean-across-bins), not a single bin's peak — see
        // transientMarginDB's doc comment for why that distinction matters.
        var meanMag: Float = 0
        vDSP_meanv(magnitudes, 1, &meanMag, n)
        let scale = 1.0 / Float(Self.fftSize)
        let broadbandDB = 20 * log10f(max(meanMag * scale, 1e-9))
        columnBroadbandDB.append(broadbandDB)
    }

    /// Finalizes the capture and either produces a curve or explains why the
    /// run wasn't usable. Doesn't persist anything itself — the caller
    /// decides whether/where to save a `.success` curve.
    ///
    /// `micName` is taken here rather than at `init` deliberately: it tags
    /// the resulting curve, and by the time a capture finishes the engine
    /// has been running the whole 30s, so `AudioDiagnostics.inputName`
    /// reliably reflects the actually-connected mic — reading it any earlier
    /// (e.g. during idle monitoring, before the engine starts) can still see
    /// a placeholder for some USB devices, which would tag the curve under a
    /// name the app's real lookup could never match later.
    func finish(micName: String) -> Result {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard columnCount >= minColumns else {
            return .failure(reason: "Recording was interrupted — try again without leaving the calibration screen.")
        }
        if clippingDetected {
            return .failure(reason: "The microphone input overloaded during the recording. Move away from loud or close sounds and try again.")
        }

        let medianBroadbandDB = columnBroadbandDB.sorted()[columnBroadbandDB.count / 2]
        let threshold = medianBroadbandDB + Self.transientMarginDB
        var currentRun = 0
        var longestRun = 0
        for db in columnBroadbandDB {
            if db > threshold {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        if longestRun >= Self.transientMinRunColumns {
            return .failure(reason: "We picked up sound during the quiet period — try somewhere with less background noise.")
        }

        var means = [Float](repeating: 0, count: Self.binCount)
        var divisor = Float(columnCount)
        vDSP_vsdiv(binSum, 1, &divisor, &means, 1, vDSP_Length(Self.binCount))

        let overallMean = means.reduce(0, +) / Float(Self.binCount)
        guard overallMean > Self.deadSignalFloor else {
            return .failure(reason: "Couldn't get a clear reading from the microphone — check it's connected and try again.")
        }

        let reference = means.sorted()[means.count / 2]
        let minGainLinear = pow(10, Self.minGainDB / 20)
        let maxGainLinear = pow(10, Self.maxGainDB / 20)
        var gains = [Float](repeating: 1, count: Self.binCount)
        for i in 0..<Self.binCount {
            let raw = means[i] > 0 ? reference / means[i] : maxGainLinear
            gains[i] = min(max(raw, minGainLinear), maxGainLinear)
        }

        let curve = MicCalibrationCurve(binCount: Self.binCount, sampleRate: sampleRate, fftSize: Self.fftSize,
                                         gains: gains, micName: micName, capturedAt: Date())
        return .success(curve)
    }
}
