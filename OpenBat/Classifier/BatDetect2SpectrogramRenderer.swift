//
//  BatDetect2SpectrogramRenderer.swift
//  OpenBat
//
//  Spectrogram config for BatDetect2 (macaodha/batdetect2, CC BY-NC 4.0 — the
//  MIT-adjacent base model, NOT the batdetect2-acoupi GPL3 wrapper).
//
//  Params below are transcribed from the published v2.0.0b2 preprocessing config
//  (bat_detect2/preprocess/{audio,spectrogram,config}.py, model.yaml) — they are
//  NOT YET VERIFIED against a converted checkpoint's actual expected input, since no
//  BatDetect2 weights have been converted to CoreML yet. Treat every value here as a
//  starting point to confirm once real weights + a reference spectrogram are in hand
//  (same process NaBatSpectrogramRenderer went through — see its magma/viridis note).
//
//  Unlike NABat (a 100×100 fixed classifier over a single pre-cut pulse), BatDetect2
//  is a fully-convolutional detector: it expects a longer spectrogram chunk and
//  produces its own per-pixel detections. OpenBat plugs it in via the same
//  pulse-triggered adapter as NABat (see BatDetect2Classifier) — PulseDetector still
//  finds the call and cuts a fixed window; BatDetect2's own detection head is only
//  used to pick the best in-window detection, not to find calls independently.
//

import Foundation

enum BatDetect2SpectrogramRenderer {

    // 256 kHz target, 2 ms window, 75% overlap — matches the published config.
    // PCM handed in must already be at this rate (resample upstream if the model's
    // ModelInputSpec window is cut from 384 kHz audio; see BatDetect2Classifier).
    static let targetSampleRate = 256_000.0
    static let nFFT = 512                          // 0.002 s * 256 kHz
    static let hop  = 128                          // 25% of nFFT (75% overlap)

    // TODO: confirm exact output width against the converted checkpoint. Height
    // (128) and the resize_factor (0.5) come straight from model.yaml; width depends
    // on how many frames the model's input chunk produces at hop=128 samples, then
    // halved by resize_factor — placeholder until verified.
    static let outH = 128
    static let outW = 128

    static let spec = SpectrogramRenderSpec(
        sampleRate: targetSampleRate,
        nFFT: nFFT,
        hop: hop,
        window: .hann,
        minFreqHz: 10_000,
        maxFreqHz: 120_000,
        // PCEN constants from model.yaml's spectrogram_transforms entry — unverified.
        scaling: .pcen(timeConstant: 0.1, gain: 0.98, bias: 2, power: 0.5),
        denoise: .spectralMeanSubtraction,
        normalize: .peak,
        resize: .bilinear,
        color: .grayscale,
        outputWidth: outW,
        outputHeight: outH
    )

    /// Convert PCM (already at `targetSampleRate`) into the grayscale image tensor
    /// BatDetect2's CNN expects. Returns nil if `pcm` is shorter than one FFT window.
    static func render(pcm: [Float]) -> ClassifierSpectrogramEngine.RenderOutput? {
        ClassifierSpectrogramEngine.render(pcm: pcm, spec: spec)
    }
}
