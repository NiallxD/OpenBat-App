//
//  MicCalibrationCurve.swift
//  OpenBat
//
//  Correction curve for uneven MEMS microphone frequency response. Cheap
//  ultrasonic USB mics have resonances that make some frequencies read louder
//  than others regardless of what's actually happening acoustically — visible
//  as persistent horizontal noise bands in a spectrogram, and a source of bias
//  in FmaxE (frequency of maximum energy) measurements when a call happens to
//  sit near a resonance peak. `MicCalibrator` measures a mic's own response
//  during a genuinely quiet period and produces one of these; every FFT
//  pipeline that computes magnitude-per-bin for DISPLAY or ANALYSIS applies it
//  before converting to dB. This is deliberately confined to that domain —
//  recorded audio, AutoID classifier input, and uploads all read raw PCM and
//  never see this curve, so it can't affect what's saved, classified, or sent.
//

import Accelerate
import Foundation

struct MicCalibrationCurve: Codable, Equatable {
    /// Number of bins the curve was measured at (`fftSize / 2`).
    let binCount: Int
    /// Sample rate the calibration recording was captured at.
    let sampleRate: Double
    /// Zero-padded FFT size the curve was measured at, so `Hz-per-bin =
    /// sampleRate / fftSize`.
    let fftSize: Int
    /// Linear gain per bin (not dB) — `count == binCount`. Already clamped by
    /// `MicCalibrator` so a near-dead bin can't get boosted into a false line.
    let gains: [Float]
    /// `AudioDiagnostics.inputName` at capture time — ties this curve to the
    /// mic it was measured from, so switching to a different microphone
    /// doesn't silently apply the wrong correction.
    let micName: String
    let capturedAt: Date

    /// Hz spanned by one bin in this curve's own grid.
    private var hzPerBin: Double { sampleRate / Double(fftSize) }

    /// Direct per-index application for a caller whose own grid matches this
    /// curve's (`binCount`/`fftSize`/`sampleRate` all equal) — the common
    /// case, since `SpectrogramProcessor` and `STFTGrid` share one grid by
    /// design. `magnitudes` must have exactly `binCount` entries.
    func apply(to magnitudes: inout [Float]) {
        // `gains.count` is checked as well as `magnitudes.count`: this type is
        // `Codable` and read back from disk, so a truncated or version-skewed
        // curve would otherwise index out of range — on the realtime audio
        // thread, from persisted data.
        guard magnitudes.count == binCount, gains.count == binCount else { return }
        // Vectorised: this runs once per FFT column, i.e. ~1500 times a second at
        // 1024 bins on the realtime audio thread. The scalar loop it replaces was
        // 1.5 M multiplies a second, next to a `makeColumn` whose every other step
        // is already vDSP for exactly this reason.
        magnitudes.withUnsafeMutableBufferPointer { mag in
            gains.withUnsafeBufferPointer { g in
                vDSP_vmul(mag.baseAddress!, 1, g.baseAddress!, 1,
                          mag.baseAddress!, 1, vDSP_Length(binCount))
            }
        }
    }

    /// Frequency-interpolated lookup for a caller with a different bin grid
    /// (`CallAnalysis.traceExtent`'s short-window pass, which zero-pads to a
    /// smaller FFT size and so has coarser bins than this curve was measured
    /// at). Linearly interpolates between the two nearest measured bins.
    func gain(atFrequencyHz hz: Double) -> Float {
        guard hz > 0, hzPerBin > 0 else { return 1 }
        let position = hz / hzPerBin
        let lowIndex = Int(position.rounded(.down))
        guard lowIndex >= 0, lowIndex < binCount else {
            return gains[Swift.max(0, Swift.min(binCount - 1, Int(position.rounded())))]
        }
        guard lowIndex + 1 < binCount else { return gains[lowIndex] }
        let frac = Float(position - Double(lowIndex))
        return gains[lowIndex] + frac * (gains[lowIndex + 1] - gains[lowIndex])
    }
}
