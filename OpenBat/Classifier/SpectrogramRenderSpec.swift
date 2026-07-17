//
//  SpectrogramRenderSpec.swift
//  OpenBat
//
//  Per-model configuration for turning a raw PCM pulse window into the image tensor
//  a classifier CNN expects. Each model has its own training-time preprocessing
//  (FFT size, frequency crop, denoise, scaling, colormap) and CNNs are extremely
//  sensitive to any mismatch here — see the magma/viridis note on NaBatSpectrogramRenderer.
//  Pulling these knobs into data (rather than duplicating a whole vDSP file per model)
//  makes it fast to iterate a new model's params against its reference implementation.
//
//  `ClassifierSpectrogramEngine.render(pcm:spec:)` is the shared engine every model's
//  renderer wraps. `ModelInputSpec` (in ModelRegistry.swift) is a separate, smaller
//  concern: how much PCM the pulse detector hands over and where the onset sits in it.
//  This spec governs everything downstream of that PCM window.
//

import Foundation

enum SpectrogramWindowFunction {
    case hamming
    case hann
}

enum SpectrogramScaling {
    /// 10 * log10(power), matching librosa/matplotlib dB spectrograms (NABat).
    case db
    /// Per-Channel Energy Normalization (Lostanlen et al.), as used by BatDetect2's
    /// preprocessing. `timeConstant` in seconds; `gain`/`bias`/`power` per the standard
    /// PCEN formula. NOT YET VERIFIED against a converted BatDetect2 checkpoint — the
    /// exact smoothing/gain constants must be confirmed once real weights are in hand.
    case pcen(timeConstant: Float, gain: Float, bias: Float, power: Float)
}

enum SpectrogramDenoise {
    case none
    /// NABat: subtract the per-row (frequency bin) median, then the per-column (time
    /// frame) median, then clip negatives to 0.
    case rowThenColumnMedian
    /// BatDetect2: subtract the per-frequency-bin mean across time, then clip to 0.
    case spectralMeanSubtraction
}

enum SpectrogramNormalize {
    /// Per-spectrogram min/max to [0,1] (mirrors matplotlib's auto-norm; NABat).
    case minMax
    /// Per-spectrogram peak-normalize so max |value| = 1 (BatDetect2).
    case peak
}

enum SpectrogramResize {
    /// Each output pixel takes the value of the single data cell it falls in. Required
    /// for NABat: its training images come from a pcolormesh QuadMesh (piecewise
    /// constant), and bilinear resampling measurably degrades classification accuracy.
    case nearest
    /// Bilinear interpolation (BatDetect2 uses `torch.nn.functional.interpolate`).
    case bilinear
}

enum SpectrogramColor {
    /// 3-channel RGB via a named colormap.
    case colormap(SpectrogramColormap)
    /// 1-channel raw normalized value, no colormap.
    case grayscale
}

enum SpectrogramColormap {
    case magma
}

/// Everything needed to go from raw PCM to the exact image tensor a model's CNN was
/// trained on. One instance per model, owned by that model's renderer file.
struct SpectrogramRenderSpec {
    /// Sample rate the PCM is assumed to already be at (resampling, if a model needs
    /// it, is the caller's responsibility before hitting this engine).
    var sampleRate: Double
    var nFFT: Int
    var hop: Int
    var window: SpectrogramWindowFunction
    var minFreqHz: Float
    var maxFreqHz: Float
    var scaling: SpectrogramScaling
    var denoise: SpectrogramDenoise
    var normalize: SpectrogramNormalize
    var resize: SpectrogramResize
    var color: SpectrogramColor
    var outputWidth: Int
    var outputHeight: Int

    var channels: Int {
        switch color {
        case .colormap: return 3
        case .grayscale: return 1
        }
    }
}
