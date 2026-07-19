//
//  BatDetect2SpectrogramRenderer.swift
//  OpenBat
//
//  Spectrogram config for BatDetect2 (macaodha/batdetect2, CC BY-NC 4.0 — the
//  MIT-adjacent base model, NOT the batdetect2-acoupi GPL3 wrapper).
//
//  Params below are confirmed against the actual v2.0.0b2 checkpoint
//  (batdetect2_uk_same.ckpt's stored hyper_parameters['preprocess'], read directly
//  from the Lightning checkpoint — not guessed from docs). See
//  batdetect2_conversion.md for how these were extracted and verified end-to-end
//  (Python `BatDetect2API` on a real UK example WAV vs. this Swift path).
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

    // 256 kHz target, 2 ms window, 75% overlap — confirmed against the checkpoint's
    // stored preprocess config. PCM handed in must already be at this rate (resample
    // upstream from 384 kHz; see BatDetect2Classifier).
    static let targetSampleRate = 256_000.0
    static let nFFT = 512                          // 0.002 s * 256 kHz
    static let hop  = 128                          // 25% of nFFT (75% overlap)

    // Height (128) is fixed regardless of clip length (ResizeConfig.height in the
    // checkpoint's preprocess config). Width scales with input duration — confirmed
    // 256 samples-wide for a 256 ms window (matches ModelInputSpec.batdetect2's
    // windowSeconds, chosen to equal the model's own training clip length).
    static let outH = 128
    static let outW = 256

    static let spec = SpectrogramRenderSpec(
        sampleRate: targetSampleRate,
        nFFT: nFFT,
        hop: hop,
        window: .hann,
        minFreqHz: 10_000,
        maxFreqHz: 120_000,
        // PCEN constants read directly from the checkpoint's stored preprocess
        // config: gain/bias/power match the published defaults, but time_constant is
        // 0.4, NOT the 0.1 originally guessed here.
        scaling: .pcen(timeConstant: 0.4, gain: 0.98, bias: 2, power: 0.5),
        denoise: .spectralMeanSubtraction,
        // The real pipeline's spectrogram_transforms list is exactly
        // [PcenConfig(), SpectralMeanSubtractionConfig()] — no normalize step at all.
        // `.peak` (originally guessed here) does not exist in the reference pipeline.
        normalize: .none,
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
