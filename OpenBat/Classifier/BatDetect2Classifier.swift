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
//  `init()` loads "BatDetect2" by name via the generic MLModel API (not an
//  Xcode-generated wrapper class) so this file didn't need to change once the
//  .mlpackage was dropped into the project. See BatDetect2SpectrogramRenderer for
//  the (checkpoint-verified) preprocessing config this depends on.
//

import CoreML
import Accelerate
import Foundation

final class BatDetect2Classifier: SpeciesClassifier {

    // The real 17-class order, read directly from batdetect2_uk_same.ckpt's stored
    // hyper_parameters['class_names'] — NOT the paper's prose description. There is
    // no extra "generic Bat" or "background/NotBat" class in this list: the model's
    // ClassifierHead has num_classes+1 output channels (the +1 is a background logit
    // used only inside the softmax, then discarded — see ModelOutput.detection_probs,
    // which is derived by SUMMING these 17 class probabilities, not from a separate
    // detection head). Codes are BatDetect2's own 6-letter species abbreviations
    // (not NABat 4-letter codes), uppercased for consistency with the rest of the app.
    static let classNames: [String] = [
        "MYOMYS", "MYOALC", "CNESER", "PIPNAT", "BARBAR", "MYONAT", "MYODAU",
        "MYOBRA", "PIPPIP", "MYOBEC", "PIPPYG", "RHIHIP", "NYCLEI", "RHIFER",
        "PLEAUR", "NYCNOC", "PLEAUS",
    ]

    /// Code → scientific name, read directly from the checkpoint's own stored
    /// `targets_config.classification_targets` (each entry's `dwc:scientificName`
    /// tag) during conversion — see batdetect2_conversion.md. Used to suggest
    /// location-based priors from GBIF occurrence data (GBIFService.suggestPriors).
    static let scientificNames: [String: String] = [
        "MYOMYS": "Myotis mystacinus",
        "MYOALC": "Myotis alcathoe",
        "CNESER": "Cnephaeus serotinus",
        "PIPNAT": "Pipistrellus nathusii",
        "BARBAR": "Barbastella barbastellus",
        "MYONAT": "Myotis nattereri",
        "MYODAU": "Myotis daubentonii",
        "MYOBRA": "Myotis brandtii",
        "PIPPIP": "Pipistrellus pipistrellus",
        "MYOBEC": "Myotis bechsteinii",
        "PIPPYG": "Pipistrellus pygmaeus",
        "RHIHIP": "Rhinolophus hipposideros",
        "NYCLEI": "Nyctalus leisleri",
        "RHIFER": "Rhinolophus ferrumequinum",
        "PLEAUR": "Plecotus auritus",
        "NYCNOC": "Nyctalus noctula",
        "PLEAUS": "Plecotus austriacus",
    ]

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
    /// to BatDetect2's expected 256 kHz before rendering, matching the reference
    /// pipeline's `scipy.signal.resample_poly` (see PolyphaseResampler) rather than a
    /// naive linear interpolation, which would alias badly this close to Nyquist.
    /// `gate` is unused — BatDetect2 has no equivalent of NABat's quality-gate metrics
    /// defined yet (denoise: .none equivalent quality path), so every window is
    /// classified.
    func classify(pcm: [Float], gate: QualityGate, prior: (String) -> Float) -> ClassificationResult? {
        let resampled = PolyphaseResampler.resample(pcm, from: 384_000, to: BatDetect2SpectrogramRenderer.targetSampleRate)
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
        // Guards the assumption that the model's output spatial resolution equals the
        // input tensor's (128x256) — true for BatDetect2's UNet-style architecture, but
        // not verified by the type system, so a converter/shape change fails safely
        // here instead of indexing out of bounds below.
        guard detectionProbs.count == hw, classProbs.count == n * hw else { return nil }
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
}
