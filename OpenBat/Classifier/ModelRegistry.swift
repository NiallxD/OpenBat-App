//
//  ModelRegistry.swift
//  OpenBat
//
//  Registry of the species-classifier models bundled in the app. Each model is
//  fully described by a `ModelDescriptor` (metadata + class list + scientific
//  names + species grouping + a lazy factory). AutoID settings, the settings UI,
//  and the pulse detector are all driven off this registry, so adding a new
//  model is a one-line append here — no other code changes required. Priors
//  aren't part of the descriptor: every model starts neutral and
//  AutoIDSettings suggests real ones from GBIF occurrence data near the
//  user's location (see GBIFService.suggestPriors).
//
//  Only ONE model classifies at a time (see AutoIDSettings.activeModelID).
//

import CoreLocation
import Foundation

/// A rough lat/lon box a model's training region covers, used only to suggest a
/// model for the user's current location — not an authoritative range boundary.
struct ModelCoverage {
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        (minLatitude...maxLatitude).contains(coordinate.latitude)
            && (minLongitude...maxLongitude).contains(coordinate.longitude)
    }
}

/// Anything that can turn a PCM pulse window into a classification. `BatClassifier`
/// (the NABat CoreML model) is the only conformer today.
protocol SpeciesClassifier {
    func classify(pcm: [Float], gate: QualityGate, prior: (String) -> Float) -> ClassificationResult?
}

/// A named group of species codes, used to lay the (long) class list out in the UI.
struct SpeciesGroup: Identifiable {
    let name: String
    let codes: [String]
    var id: String { name }
}

/// A set of species this model routinely confuses acoustically — a "complex". Whether
/// two species are separable is a property of the *model's* discrimination ability (and
/// the physics of the calls it was trained on), so membership lives with the descriptor
/// and is configured per model. Surfaced in the UI so a confident-looking number is never
/// shown for a genuinely confusable species without saying so.
struct SpeciesComplex: Identifiable {
    let id: String            // stable key, persisted on a pass ("myotis")
    let name: String          // "Myotis species"
    let codes: Set<String>    // members
    let note: String          // one-line, honest explanation shown to the user

    /// A runner-up within this posterior gap of the winner is treated as an *active*
    /// ambiguity for this ID (not just an ambient "this species is hard" caveat), when
    /// the runner-up is a complex-mate. Deliberately generous — the point is honesty.
    static let ambiguityMargin: Float = 0.20
}

/// How the pulse detector should cut the PCM window it hands to a model's
/// `classify(pcm:)`. The model owns everything *after* this (spectrogram, tensor
/// shape, resampling); this only describes how much audio it wants and where the
/// call onset should sit within it — the one assumption that lives outside the model.
struct ModelInputSpec {
    /// Length of the classification window in seconds (NABat: 0.05).
    var windowSeconds: Double
    /// Where the call onset should land within the window, 0…1 (NABat: 0.30), so the
    /// peak falls inside the model's expected band.
    var onsetFraction: Double

    static let nabat = ModelInputSpec(windowSeconds: 0.05, onsetFraction: 0.30)

    /// 256 ms — matches BatDetect2's own training clip length exactly (see
    /// `train_config.train_loader.clipping_strategy.duration` in the checkpoint's
    /// stored hyperparameters), confirmed to produce the 128×256 spectrogram the
    /// converted CoreML model was traced with. Onset at 30% mirrors NABat's convention;
    /// unlike NABat's fixed classifier, BatDetect2 is fully convolutional and localizes
    /// calls itself via its own bounding-box regression, so the exact onset placement
    /// within the window is not load-bearing the way it is for NABat — this just needs
    /// to keep the call comfortably inside the window. PulseDetector's
    /// `deferTrailSeconds` budget is widened (computed from ModelRegistry.all) to cover
    /// this window's 179.2 ms trailing requirement.
    static let batdetect2 = ModelInputSpec(windowSeconds: 0.256, onsetFraction: 0.30)
}

/// Everything the app needs to know about a classifier model without loading it.
struct ModelDescriptor: Identifiable {
    let id: String                       // stable key, persisted in settings
    let displayName: String
    let region: String
    /// Rough bounding box for "is this model relevant here" location suggestions.
    /// nil means the model doesn't offer a location suggestion (always shown as an
    /// option, never auto-suggested or excluded).
    let coverage: ModelCoverage?
    let version: String
    /// Shown as a "BETA" badge wherever the model is listed — for a model that's
    /// functional but not yet field-validated the way a non-beta one is.
    let isBeta: Bool
    let summary: String
    /// Attribution shown in the model detail screen — how to credit the authors, in
    /// prose. Paired with `sourceURL` for a tappable link to where they publish the
    /// model files.
    let citation: String
    /// Where the authors provide the model + training code. nil hides the link.
    let sourceURL: URL?
    let classNames: [String]
    /// Code → scientific name, for every code in `classNames` that names a real
    /// taxon (a model's non-bat "NOISE"-equivalent class, if any, is omitted).
    /// Used to look up GBIF occurrence data near the user's location and suggest
    /// per-species priors (see GBIFService.suggestPriors) — there is no static
    /// "default prior" anymore; every model starts neutral (every species
    /// enabled, prior 1.0) until a location fix refines it.
    let scientificNames: [String: String]
    let groups: [SpeciesGroup]
    /// Species clusters this model can't reliably separate. Empty for a model that
    /// makes no such admission.
    let complexes: [SpeciesComplex]
    let defaultGate: QualityGate
    /// How the detector cuts the PCM window for this model (length + onset placement).
    let input: ModelInputSpec
    /// PassAggregation's NoID cutoff — mean per-pulse top RAW score below this closes
    /// the pass with no result. Model-specific because raw-score dynamics differ a lot
    /// between architectures (see PassAggregation.aggregate's doc comment).
    let noidRawConfidenceThreshold: Float
    /// The class name meaning "not a bat call", if this model has one as an explicit
    /// class (NABat: "NOISE"). nil if the model has no such class (BatDetect2's
    /// background probability never reaches OpenBat as a named class).
    let noiseClassName: String?
    /// Builds the (heavy) classifier on demand; nil if the model fails to load.
    let makeClassifier: () -> SpeciesClassifier?

    /// The complex `code` belongs to, if any. A species is in at most one complex.
    func complex(for code: String) -> SpeciesComplex? {
        complexes.first { $0.codes.contains(code) }
    }
}

enum ModelRegistry {

    /// Stable id for the bundled NABat model — referenced by the v1→v2 settings migration.
    static let nabatID = "nabat-ml-v1"

    /// Stable id for the bundled BatDetect2 model.
    static let batDetect2ID = "batdetect2-v2"

    /// All models available in this build. Append a `ModelDescriptor` to add one.
    static let all: [ModelDescriptor] = [nabat, batDetect2]

    static func descriptor(id: String?) -> ModelDescriptor? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// The model whose coverage contains `coordinate`, if any — used to suggest a
    /// model for the user's current location. First match wins; coverage boxes aren't
    /// expected to overlap in practice.
    static func suggestedModel(for coordinate: CLLocationCoordinate2D) -> ModelDescriptor? {
        all.first { $0.coverage?.contains(coordinate) ?? false }
    }

    /// Look up a complex by its stable id across every model — used to resolve a
    /// `complexID` persisted on a pass back to its name/note/members at display time,
    /// without the pass having to store all of that.
    static func complex(id: String?) -> SpeciesComplex? {
        guard let id else { return nil }
        for model in all {
            if let c = model.complexes.first(where: { $0.id == id }) { return c }
        }
        return nil
    }

    // MARK: NABat ML

    private static let nabat = ModelDescriptor(
        id: nabatID,
        displayName: "NABat ML",
        region: "North America",
        // Continental North America + Central America/Caribbean, generously padded —
        // approximate on purpose, this only drives a suggestion, not model eligibility.
        coverage: ModelCoverage(minLatitude: 5, maxLatitude: 75,
                                minLongitude: -170, maxLongitude: -50),
        version: "1.0",
        isBeta: false,
        summary: "USGS North American Bat Monitoring Program classifier — 31 classes "
               + "covering North American bat species plus a non-bat (NOISE) class. "
               + "Priors are suggested automatically from GBIF occurrence data near "
               + "your location, and refresh as you move.",
        citation: "North American Bat Monitoring Program (NABat) acoustic ML classifier, "
                + "U.S. Geological Survey. Model files and training code are published by "
                + "the authors.",
        sourceURL: URL(string: "https://code.usgs.gov/fort/nabat/nabat-ml"),
        classNames: BatClassifier.classNames,
        scientificNames: BatClassifier.scientificNames,
        groups: [
            SpeciesGroup(name: "Myotis",
                         codes: ["MYAU","MYCA","MYCI","MYEV","MYGR","MYLE",
                                 "MYLU","MYSE","MYSO","MYTH","MYVE","MYVO","MYYU"]),
            SpeciesGroup(name: "Lasiurus & allies",
                         codes: ["LABL","LABO","LACI","LAIN","LANO","LASE"]),
            SpeciesGroup(name: "Other vesper bats",
                         codes: ["ANPA","COTO","EPFU","EUMA","EUPE","IDPH","PAHE","PESU"]),
            SpeciesGroup(name: "Free-tailed & evening",
                         codes: ["NYHU","NYMA","TABR"]),
            SpeciesGroup(name: "Non-bat",
                         codes: ["NOISE"]),
        ],
        complexes: [
            SpeciesComplex(
                id: "myotis",
                name: "Myotis species",
                codes: ["MYAU","MYCA","MYCI","MYEV","MYGR","MYLE",
                        "MYLU","MYSE","MYSO","MYTH","MYVE","MYVO","MYYU"],
                note: "Myotis species produce very similar broadband calls and are "
                    + "frequently indistinguishable by acoustic ID alone. Treat a "
                    + "Myotis identification as \u{201C}a Myotis\u{201D} unless a call sequence "
                    + "and range strongly support the species."),
            SpeciesComplex(
                id: "lowfreq",
                name: "Low-frequency bats",
                codes: ["EPFU","LANO","LACI"],
                note: "Big Brown, Silver-haired and Hoary bats all call at low "
                    + "frequencies with overlapping shapes, and single passes are "
                    + "easily confused — especially Big Brown and Silver-haired."),
        ],
        defaultGate: QualityGate(),
        input: .nabat,
        noidRawConfidenceThreshold: PassAggregation.noidRawConfidenceThreshold,
        noiseClassName: "NOISE",
        makeClassifier: { try? BatClassifier() }
    )

    // MARK: BatDetect2

    /// Descriptor for BatDetect2 (macaodha/batdetect2, CC BY-NC 4.0), the
    /// `batdetect2_uk_same.ckpt` checkpoint converted to CoreML — see
    /// batdetect2_conversion.md for the conversion + verification process.
    static let batDetect2 = ModelDescriptor(
        id: batDetect2ID,
        displayName: "BatDetect2",
        region: "United Kingdom",
        coverage: ModelCoverage(minLatitude: 49, maxLatitude: 61,
                                minLongitude: -11, maxLongitude: 2),
        version: "2.0.0b2",
        isBeta: true,
        summary: "University of Edinburgh's fully-convolutional bat call detector + "
               + "classifier, pretrained on 17 UK species. Non-commercial license — "
               + "see citation.",
        citation: "BatDetect2 (macaodha/batdetect2), CC BY-NC 4.0 — non-commercial use "
                + "only. Contact the authors for any commercial use.",
        sourceURL: URL(string: "https://github.com/macaodha/batdetect2"),
        classNames: BatDetect2Classifier.classNames,
        scientificNames: BatDetect2Classifier.scientificNames,
        groups: [
            SpeciesGroup(name: "Myotis",
                         codes: ["MYOMYS","MYOALC","MYONAT","MYODAU","MYOBRA","MYOBEC"]),
            SpeciesGroup(name: "Pipistrelles",
                         codes: ["PIPNAT","PIPPIP","PIPPYG"]),
            SpeciesGroup(name: "Horseshoe bats",
                         codes: ["RHIHIP","RHIFER"]),
            SpeciesGroup(name: "Nyctalus",
                         codes: ["NYCLEI","NYCNOC"]),
            SpeciesGroup(name: "Long-eared bats",
                         codes: ["PLEAUR","PLEAUS"]),
            SpeciesGroup(name: "Other vesper bats",
                         codes: ["CNESER","BARBAR"]),
        ],
        complexes: [
            SpeciesComplex(
                id: "uk-myotis",
                name: "Myotis species",
                codes: ["MYOMYS","MYOALC","MYONAT","MYODAU","MYOBRA","MYOBEC"],
                note: "UK Myotis species produce very similar broadband calls and are "
                    + "frequently indistinguishable by acoustic ID alone — whiskered "
                    + "and Alcathoe bats in particular are near-inseparable acoustically. "
                    + "Treat a Myotis identification as \u{201C}a Myotis\u{201D} unless a "
                    + "call sequence and range strongly support the species."),
            SpeciesComplex(
                id: "uk-pipistrelles",
                name: "Pipistrelle species",
                codes: ["PIPNAT","PIPPIP","PIPPYG"],
                note: "Common and soprano pipistrelles have overlapping peak "
                    + "frequencies (~45 and ~55 kHz) and are commonly confused; "
                    + "Nathusius' pipistrelle is more separable but included here "
                    + "for caution on marginal calls."),
            SpeciesComplex(
                id: "uk-nyctalus",
                name: "Nyctalus species",
                codes: ["NYCLEI","NYCNOC"],
                note: "Leisler's and noctule bats call in overlapping frequency "
                    + "ranges and are frequently confused on single passes."),
            SpeciesComplex(
                id: "uk-plecotus",
                name: "Long-eared bats",
                codes: ["PLEAUR","PLEAUS"],
                note: "Brown and grey long-eared bats produce extremely quiet, "
                    + "similar whispering calls and are effectively inseparable by "
                    + "acoustic ID alone."),
        ],
        defaultGate: .disabled,
        input: .batdetect2,
        // Starting point, NOT independently verified against a labelled noise/no-call
        // dataset the way NABat's 0.57 was — see PassAggregation.aggregate's doc
        // comment. BatDetect2's per-pixel softmax tends to be far more sharply peaked
        // than NABat's (observed 0.7-0.9 on confidently-correct real UK example calls
        // during conversion — see batdetect2_conversion.md), so 0.4 is a conservative
        // placeholder pending real field data.
        noidRawConfidenceThreshold: 0.4,
        noiseClassName: nil,
        makeClassifier: { BatDetect2Classifier() }
    )
}
