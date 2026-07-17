//
//  BatClassifier.swift
//  OpenBat
//
//  Wraps the NABatML CoreML model. Call classify(pcm:) on any background queue;
//  it renders the spectrogram and returns a ClassificationResult synchronously.
//

import CoreML
import Foundation

struct ClassificationResult {
    let species: String       // winning species code, e.g. "MYLU"
    let confidence: Float     // prior-adjusted, renormalized posterior of the winner (0–1)
    let allScores: [String: Float]  // prior-adjusted, renormalized posteriors for all 31 classes (sum to 1)
    /// Raw (pre-prior) softmax output for all 31 classes — the model's unbiased read,
    /// used by `PassAggregation` for the NoID/NOISE pass-level gate. Empty for
    /// results that were never derived from a live classification (e.g. a pass-level
    /// aggregate `ClassificationResult` built for display/logging only).
    var rawScores: [String: Float] = [:]
}

/// Pulse quality gate, mirroring nabat-ml's `Spectrogram._process_window` defaults.
/// A pulse must clear all enabled thresholds before it's classified, so noise and
/// edge-clipped windows don't produce spurious IDs (matching which pulses the
/// reference notebook keeps).
struct QualityGate {
    var enabled: Bool = true
    var snThreshold: Float = 7     // sn_thresh
    var ampThreshold: Float = 21   // amp_thresh (denoised dB)
    /// Require the peak to fall within [edge, 1-edge] of the window (rejects clipped calls).
    var peakTimeEdge: Float = 0.2

    static let disabled = QualityGate(enabled: false)

    func passes(_ o: NaBatSpectrogramRenderer.RenderOutput) -> Bool {
        guard enabled else { return true }
        return o.snr >= snThreshold
            && o.amplitude >= ampThreshold
            && o.peakTimeFraction >= peakTimeEdge
            && o.peakTimeFraction <= (1 - peakTimeEdge)
    }
}

final class BatClassifier: SpeciesClassifier {

    // Class order from training_history_m-1.p, must match CoreML output index order.
    static let classNames: [String] = [
        "ANPA","COTO","EPFU","EUMA","EUPE","IDPH","LABL","LABO","LACI","LAIN",
        "LANO","LASE","MYAU","MYCA","MYCI","MYEV","MYGR","MYLE","MYLU","MYSE",
        "MYSO","MYTH","MYVE","MYVO","MYYU","NOISE","NYHU","NYMA","PAHE","PESU","TABR"
    ]

    // Prior weights for coastal SW BC (from notebook Step 5).
    static let bcPrior: [String: Float] = [
        "MYLU": 1.00, "MYYU": 1.00, "MYCA": 1.00, "MYEV": 1.00,
        "MYVO": 1.00, "MYTH": 1.00, "EPFU": 1.00, "LACI": 1.00,
        "LANO": 1.00, "COTO": 1.00,
        "EUMA": 0.75, "ANPA": 0.75, "PAHE": 0.75,
        "LABO": 0.01, "MYCI": 0.01, "LABL": 0.01, "MYSE": 0.01,
        "PESU": 0.01, "MYAU": 0.01, "LAIN": 0.01, "LASE": 0.01,
        "TABR": 0.01, "EUPE": 0.01, "MYGR": 0.01, "MYLE": 0.01,
        "MYSO": 0.01, "MYVE": 0.01, "NYHU": 0.01, "NYMA": 0.01,
        "IDPH": 0.01, "NOISE": 1.00,
    ]

    private let model: NABatML

    init() throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try NABatML(configuration: config)
    }

    /// Render `pcm` (raw 384 kHz samples) as a NABat spectrogram and run inference.
    /// `prior` maps a species code to its weight (0.01–1.0); defaults to the built-in BC prior.
    /// Safe to call on any background queue; returns nil if the PCM is too short or the model fails.
    func classify(pcm: [Float],
                  gate: QualityGate = QualityGate(),
                  prior: (String) -> Float = { BatClassifier.bcPrior[$0] ?? 1.0 }) -> ClassificationResult? {
        guard let rendered = NaBatSpectrogramRenderer.render(pcm: pcm) else { return nil }
        // Reject low-quality / edge-clipped pulses before running the model.
        guard gate.passes(rendered) else { return nil }
        let imgFloats = rendered.image

        // Build MLMultiArray [1, 100, 100, 3] float32
        guard let input = try? MLMultiArray(shape: [1, 100, 100, 3], dataType: .float32) else { return nil }
        imgFloats.withUnsafeBufferPointer { src in
            let dst = input.dataPointer.bindMemory(to: Float.self, capacity: imgFloats.count)
            UnsafeMutableBufferPointer(start: dst, count: imgFloats.count)
                .update(from: src)
        }

        guard let output = try? model.prediction(input_1: input) else { return nil }
        let outArray = output.Identity

        let n = Self.classNames.count
        var raw = [Float](repeating: 0, count: n)
        for i in 0..<n { raw[i] = outArray[i].floatValue }

        // Apply the prior (masking / down-weighting) then renormalize so the adjusted
        // scores form a proper posterior that sums to 1. Without renormalization the
        // reported confidence understates the true posterior and the minConf threshold
        // in PulseDetector.finalizePass() compares against an arbitrary scale.
        var adjusted = [Float](repeating: 0, count: n)
        for i in 0..<n { adjusted[i] = raw[i] * prior(Self.classNames[i]) }

        let total = adjusted.reduce(0, +)
        if total > 0 {
            let inv = 1 / total
            for i in 0..<n { adjusted[i] *= inv }
        }

        var bestIdx = 0
        for i in 1..<n where adjusted[i] > adjusted[bestIdx] { bestIdx = i }

        var allScores = [String: Float]()
        for i in 0..<n { allScores[Self.classNames[i]] = adjusted[i] }

        var rawScores = [String: Float]()
        for i in 0..<n { rawScores[Self.classNames[i]] = raw[i] }

        return ClassificationResult(
            species: Self.classNames[bestIdx],
            confidence: adjusted[bestIdx],   // renormalized posterior of the winner
            allScores: allScores,
            rawScores: rawScores
        )
    }
}
