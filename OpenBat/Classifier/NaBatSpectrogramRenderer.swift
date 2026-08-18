//
//  NaBatSpectrogramRenderer.swift
//  OpenBat
//
//  Replicates nabat-ml spectrogram_v2.py's _process_window() + make_training_spectrogram()
//  via ClassifierSpectrogramEngine, producing the same 100×100 spectrogram the NABat CNN
//  expects.
//
//  Parameters exactly match the Python code:
//    n_fft  = int(0.001 * 384000) = 384   (Hamming window)
//    hop    = n_fft / 4            = 96
//    bandpass: 5 kHz < f < 100 kHz  (zeroed outside)
//    denoise: subtract row median, subtract col median, clip to 0
//    normalize: [0,1] using data min/max (mirrors matplotlib's auto-norm)
//    colormap: MAGMA. The model was trained on make_training_spectrogram() output,
//      which calls librosa.display.specshow() with no explicit cmap. librosa's default
//      for non-negative (sequential) data is magma — NOT viridis. Feeding viridis RGB
//      to a magma-trained CNN produces near-random, diffuse predictions (the cause of
//      the runaway LANO bias). Keep this in sync with librosa's magma default.
//    resize: NEAREST (matches pcolormesh; bilinear measurably hurts accuracy — see
//      ClassifierSpectrogramEngine's resize comment).
//    output: 100×100×3 float32 in [0,1], layout [height][width][RGB]
//

import Foundation

/// `nonisolated`: same reasoning as `Biquad`/`AudioLevel`/`STFTGrid` — stateless
/// DSP called only from `PulseDetector`'s capture queue, never the main actor, but
/// it carried no isolation annotation and so inherited
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. The single-caller, single-queue
/// invariant its scratch state relies on is now stated rather than assumed.
nonisolated enum NaBatSpectrogramRenderer {

    static let nFFT = 384                        // = int(0.001 * 384000)
    static let hop  = 96                          // = nFFT / 4
    static let outW = 100
    static let outH = 100

    static let spec = SpectrogramRenderSpec(
        sampleRate: 384_000,
        nFFT: nFFT,
        hop: hop,
        window: .hamming,
        minFreqHz: 5_000,
        maxFreqHz: 100_000,
        scaling: .db,
        denoise: .rowThenColumnMedian,
        normalize: .minMax,
        resize: .nearest,
        color: .colormap(.magma),
        outputWidth: outW,
        outputHeight: outH
    )

    /// Image plus the quality metrics the nabat-ml detector uses to gate pulses
    /// (`_process_window` in spectrogram_v2.py). Computed on the denoised dB spec
    /// exactly as the reference: verified to match the notebook's stored
    /// `Metadata.amplitude` / `.snr` / `.time` to within 0.3 on real recordings.
    struct RenderOutput {
        let image: [Float]            // outH × outW × 3, values in [0,1]
        let amplitude: Float          // peak-bin value at peak time, denoised dB
        let snr: Float                // peak-row mean (±5 cols) ÷ whole-window mean
        let peakTimeFraction: Float   // 0–1 position of the peak across the window
    }

    /// Convert 50 ms of raw PCM (19 200 samples @ 384 kHz) into the 100×100×3
    /// float32 array the NABat CoreML model expects (values in [0,1]).
    /// Layout: result[row * 100 * 3 + col * 3 + channel], row 0 = top = high freq.
    /// Returns nil if `pcm` is shorter than one FFT window.
    static func render(pcm: [Float], sampleRate: Double = 384_000) -> RenderOutput? {
        var s = spec
        s.sampleRate = sampleRate
        guard let out = ClassifierSpectrogramEngine.render(pcm: pcm, spec: s) else { return nil }
        return RenderOutput(image: out.image,
                            amplitude: out.amplitude,
                            snr: out.snr,
                            peakTimeFraction: out.peakTimeFraction)
    }
}
