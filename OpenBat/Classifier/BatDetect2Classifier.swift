//
//  BatDetect2Classifier.swift
//  OpenBat
//
//  Adapter wrapping BatDetect2 (macaodha/batdetect2, CC BY-NC 4.0) to OpenBat's
//  per-pulse SpeciesClassifier shape. BatDetect2 is natively a fully-convolutional
//  detector — one inference over a spectrogram chunk yields a detection heatmap plus
//  per-pixel class probabilities, i.e. it can find its own calls. OpenBat still uses
//  PulseDetector as the single call-finding source (see the ModelInputSpec doc comment
//  in ModelRegistry.swift): this adapter renders BatDetect2's own spectrogram from the
//  pulse window PulseDetector already cut, runs inference, and reports whichever
//  detection in that window scored highest — discarding BatDetect2's bounding-box
//  localization, keeping only its classification.
//
//  NOT YET FUNCTIONAL: no converted CoreML weights are bundled. `init()` loads
//  "BatDetect2" by name via the generic MLModel API (not an Xcode-generated wrapper
//  class) specifically so this file compiles today and only needs the .mlpackage
//  dropped into the project + `classNames`/`outputKeys` confirmed once a conversion
//  exists — no other code changes. See BatDetect2SpectrogramRenderer for the
//  (unverified) preprocessing config this depends on.
//

import CoreML
import Accelerate
import Foundation

final class BatDetect2Classifier: SpeciesClassifier {

    // TODO: replace with the real class order from the converted model's label file.
    // Per the published UK pretrained model: 17 UK species + a generic "Bat" (uncertain
    // ID) class + a background/"Not bat" class. Do NOT ship this guessed list — it must
    // come from the checkpoint being converted.
    static let classNames: [String] = []

    // Output feature names BatDetect2's forward pass exposes; confirm against the
    // actual CoreML conversion's output names (coremltools may rename them).
    private enum OutputKey {
        static let detectionProbs = "detection_probs"  // (1, 1, H, W)
        static let classProbs     = "class_probs"      // (1, C, H, W)
    }

    private let model: MLModel

    init?(modelName: String = "BatDetect2") {
        guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc")
                     ?? Bundle.main.url(forResource: modelName, withExtension: "mlpackage")
        else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let loaded = try? MLModel(contentsOf: url, configuration: config) else { return nil }
        model = loaded
    }

    /// `pcm` is the raw pulse window at the app's native rate (384 kHz); resampled here
    /// to BatDetect2's expected 256 kHz before rendering. `gate` is unused — BatDetect2
    /// has no equivalent of NABat's quality-gate metrics defined yet (denoise: .none
    /// equivalent quality path), so every window is classified.
    func classify(pcm: [Float], gate: QualityGate, prior: (String) -> Float) -> ClassificationResult? {
        guard !Self.classNames.isEmpty else { return nil }  // scaffold: no real labels yet

        let resampled = Self.resample(pcm, from: 384_000, to: BatDetect2SpectrogramRenderer.targetSampleRate)
        guard let rendered = BatDetect2SpectrogramRenderer.render(pcm: resampled) else { return nil }

        let outH = BatDetect2SpectrogramRenderer.outH
        let outW = BatDetect2SpectrogramRenderer.outW
        guard let input = try? MLMultiArray(shape: [1, 1, NSNumber(value: outH), NSNumber(value: outW)],
                                            dataType: .float32) else { return nil }
        rendered.image.withUnsafeBufferPointer { src in
            let dst = input.dataPointer.bindMemory(to: Float.self, capacity: rendered.image.count)
            UnsafeMutableBufferPointer(start: dst, count: rendered.image.count).update(from: src)
        }

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["input": input]),
              let output = try? model.prediction(from: provider),
              let detectionProbs = output.featureValue(for: OutputKey.detectionProbs)?.multiArrayValue,
              let classProbs = output.featureValue(for: OutputKey.classProbs)?.multiArrayValue
        else { return nil }

        // Pick the spatial cell with the highest detection probability, then read its
        // per-class distribution — the single "best detection in this window" BatDetect2
        // found, discarding its bbox/size regression entirely.
        let n = Self.classNames.count
        let hw = outH * outW
        var bestCell = 0
        var bestDetProb = -Float.greatestFiniteMagnitude
        for i in 0..<hw {
            let v = detectionProbs[i].floatValue
            if v > bestDetProb { bestDetProb = v; bestCell = i }
        }

        var raw = [Float](repeating: 0, count: n)
        for c in 0..<n { raw[c] = classProbs[c * hw + bestCell].floatValue }

        var adjusted = [Float](repeating: 0, count: n)
        for i in 0..<n { adjusted[i] = raw[i] * prior(Self.classNames[i]) }
        let total = adjusted.reduce(0, +)
        if total > 0 {
            let inv = 1 / total
            for i in 0..<n { adjusted[i] *= inv }
        }

        var bestIdx = 0
        for i in 1..<n where adjusted[i] > adjusted[bestIdx] { bestIdx = i }

        var allScores = [String: Float](), rawScores = [String: Float]()
        for i in 0..<n {
            allScores[Self.classNames[i]] = adjusted[i]
            rawScores[Self.classNames[i]] = raw[i]
        }

        return ClassificationResult(species: Self.classNames[bestIdx],
                                    confidence: adjusted[bestIdx],
                                    allScores: allScores,
                                    rawScores: rawScores)
    }

    /// Linear-interpolation resample. Adequate as a placeholder — a real deployment
    /// should confirm whether BatDetect2's training data anti-aliased the downsample
    /// (384 kHz → 256 kHz is a 2:3 ratio) before relying on this for accuracy.
    private static func resample(_ pcm: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        guard srcRate != dstRate, !pcm.isEmpty else { return pcm }
        let ratio = srcRate / dstRate
        let outCount = max(1, Int(Double(pcm.count) / ratio))
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcPos = Double(i) * ratio
            let i0 = min(pcm.count - 1, Int(srcPos))
            let i1 = min(pcm.count - 1, i0 + 1)
            let frac = Float(srcPos - Double(i0))
            out[i] = pcm[i0] + (pcm[i1] - pcm[i0]) * frac
        }
        return out
    }
}
