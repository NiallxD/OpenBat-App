//
//  ModelReliability.swift
//  OpenBat
//
//  How often a model is RIGHT when it names a species — its published precision,
//  measured against recordings of known species, per class.
//
//  This exists because the confidence percentage everywhere else in the app
//  answers a different question than users think it does. That number is a
//  softmax share-out: the model's 31 outputs are forced to sum to 1, so the
//  winner's figure describes how far ahead it finished, not how likely the ID is
//  to be correct. Nothing in it can express "none of these fit well" — softmax
//  is shift-invariant, so the overall strength of the evidence is discarded and
//  only the ranking survives. Cross-entropy training then pushed every output
//  toward 1.0, including on the clips where two Myotis genuinely were
//  inseparable, so a 99% is routine and means much less than it reads.
//
//  Precision is the number people are actually asking for: of all the times this
//  model said MYLU, how often was it really a MYLU. It is a property of the
//  MODEL, not of the call in front of you — the same figure for every detection
//  of that species — which is exactly why it is worth showing beside the
//  per-call percentage rather than instead of it. One says how clearly this call
//  beat the alternatives; the other says how much that verdict has historically
//  been worth.
//
//  Recall (the paper's "correct identification rate") is deliberately NOT what
//  is shown: that is "of all the MYLU out there, how many did it catch", which
//  says nothing about whether the name on this row is right.
//

import Foundation

/// One class's published track record, from the model authors' own evaluation.
struct SpeciesReliability {
    /// Of all the audio files the model labelled this species, the fraction that
    /// really were it. 0–1. The file level is the unit OpenBat shows: a pass is
    /// aggregated across its pulses before it is named (see `PassAggregation`).
    let precision: Float
    /// The same measure at the individual-pulse level, on a set two orders of
    /// magnitude larger (74,773 spectrograms vs 2426 files). Not shown to users
    /// — the wrong unit — but kept because it is the better-supported figure and
    /// is consistently harsher: MYLU is 0.89 per file and 0.67 per pulse.
    let pulsePrecision: Float
    /// How many test files carried this species. Small samples make the
    /// precision figure meaningless — see `minimumSampleSize`.
    let sampleSize: Int

    /// Below this, the published figure is not shown at all. The NABat test set
    /// has classes with four files in it; a "100%" computed from nine recordings
    /// is not a track record, and printing it would put the app's most
    /// authoritative-looking number on its least supported claim. 30 is a round
    /// number chosen to sit above the paper's sparse tail (MYVE 4, IDPH 4,
    /// NOISE 5, MYAU 9, LABL 17, ANPA 23, NYMA 23, EUPE 25) and below the bulk
    /// of the classes, which have 80–140.
    static let minimumSampleSize = 30

    /// The figure to show, or nil when it rests on too few test files to quote.
    ///
    /// Exact, unrounded, uncapped (Niall, 2026-09-10). It briefly displayed to
    /// the nearest 5% and capped at 95%, on the reasoning that ~100 test files
    /// don't support finer resolution or a claim of perfection; the cost was
    /// that twelve of the 23 quotable species collapsed onto an identical 95%
    /// and the table stopped discriminating at exactly the end where it should.
    /// The published number is the published number, and the sample-size guard
    /// below is what keeps the weakly-evidenced ones off the screen entirely.
    var quotablePrecision: Float? {
        sampleSize >= Self.minimumSampleSize ? precision : nil
    }
}

enum ModelReliability {

    /// NABat ML (Khalighifar et al. 2022, J. Appl. Ecol. 59:2849–2862),
    /// audio-file-level precision per class, from the paper's Table S2. Sample
    /// sizes are the test-set counts from its Table 1.
    ///
    /// File level rather than pulse level: an OpenBat pass is aggregated across
    /// its pulses before it is named (see `PassAggregation`), so the file-level
    /// figure is the one measured on the same unit the user is shown.
    /// Values are verbatim from Table S2; they are not rounded here, so the
    /// source stays checkable against the paper. Rounding and the ceiling happen
    /// at the point of display (`quotablePrecision`).
    static let nabat: [String: SpeciesReliability] = [
        "ANPA": SpeciesReliability(precision: 0.86, pulsePrecision: 0.82, sampleSize: 23),
        "COTO": SpeciesReliability(precision: 1.00, pulsePrecision: 0.75, sampleSize: 34),
        "EPFU": SpeciesReliability(precision: 0.85, pulsePrecision: 0.77, sampleSize: 117),
        "EUMA": SpeciesReliability(precision: 0.88, pulsePrecision: 0.77, sampleSize: 38),
        "EUPE": SpeciesReliability(precision: 0.90, pulsePrecision: 0.76, sampleSize: 25),
        "IDPH": SpeciesReliability(precision: 1.00, pulsePrecision: 0.79, sampleSize: 4),
        "LANO": SpeciesReliability(precision: 0.93, pulsePrecision: 0.75, sampleSize: 122),
        "LABL": SpeciesReliability(precision: 0.90, pulsePrecision: 0.87, sampleSize: 17),
        "LABO": SpeciesReliability(precision: 0.88, pulsePrecision: 0.80, sampleSize: 125),
        "LACI": SpeciesReliability(precision: 0.94, pulsePrecision: 0.79, sampleSize: 116),
        "LAIN": SpeciesReliability(precision: 0.95, pulsePrecision: 0.90, sampleSize: 101),
        "LASE": SpeciesReliability(precision: 0.89, pulsePrecision: 0.79, sampleSize: 114),
        "MYAU": SpeciesReliability(precision: 1.00, pulsePrecision: 0.93, sampleSize: 9),
        "MYCA": SpeciesReliability(precision: 0.97, pulsePrecision: 0.85, sampleSize: 101),
        "MYCI": SpeciesReliability(precision: 0.95, pulsePrecision: 0.86, sampleSize: 127),
        "MYEV": SpeciesReliability(precision: 0.89, pulsePrecision: 0.87, sampleSize: 119),
        "MYGR": SpeciesReliability(precision: 1.00, pulsePrecision: 0.98, sampleSize: 42),
        "MYLE": SpeciesReliability(precision: 0.86, pulsePrecision: 0.90, sampleSize: 96),
        "MYLU": SpeciesReliability(precision: 0.89, pulsePrecision: 0.67, sampleSize: 127),
        "MYSE": SpeciesReliability(precision: 0.92, pulsePrecision: 0.84, sampleSize: 46),
        "MYSO": SpeciesReliability(precision: 0.98, pulsePrecision: 0.95, sampleSize: 85),
        "MYTH": SpeciesReliability(precision: 0.98, pulsePrecision: 0.88, sampleSize: 110),
        "MYVE": SpeciesReliability(precision: 1.00, pulsePrecision: 0.18, sampleSize: 4),
        "MYVO": SpeciesReliability(precision: 0.82, pulsePrecision: 0.68, sampleSize: 76),
        "MYYU": SpeciesReliability(precision: 0.94, pulsePrecision: 0.89, sampleSize: 121),
        "NYHU": SpeciesReliability(precision: 0.86, pulsePrecision: 0.77, sampleSize: 136),
        "NYMA": SpeciesReliability(precision: 0.74, pulsePrecision: 0.91, sampleSize: 23),
        "PAHE": SpeciesReliability(precision: 0.98, pulsePrecision: 0.98, sampleSize: 83),
        "PESU": SpeciesReliability(precision: 0.96, pulsePrecision: 0.88, sampleSize: 117),
        "TABR": SpeciesReliability(precision: 0.91, pulsePrecision: 0.71, sampleSize: 109),
        "NOISE": SpeciesReliability(precision: 1.00, pulsePrecision: 0.42, sampleSize: 5),
    ]

    /// BatDetect2 publishes no comparable per-class precision, so it quotes none
    /// rather than borrowing NABat's.
    static let batDetect2: [String: SpeciesReliability] = [:]

    static func table(forModel id: String) -> [String: SpeciesReliability] {
        switch id {
        case ModelRegistry.nabatID: return nabat
        default: return [:]
        }
    }

    /// The quotable precision for a species code, or nil where the owning model
    /// publishes none, the class is absent, or the figure rests on too few test
    /// files to mean anything.
    ///
    /// Looked up by code alone, with no model argument, for the same reason
    /// `ModelRegistry.complex(id:)` is: nothing persisted on a `Recording` or a
    /// `PassRecord` says which model produced it, and the two models' code
    /// vocabularies don't overlap (NABat's four-letter North American codes vs
    /// BatDetect2's six-letter European ones), so a code identifies its model.
    static func precision(for code: String) -> Float? {
        reliability(for: code)?.precision
    }

    /// The whole record for `code`, or nil under the same conditions as
    /// `precision(for:)`. Callers that explain the figure need the pulse-level
    /// number beside it: the two are not competing estimates of one quantity but
    /// measurements of different units, and the gap between them is the value of
    /// hearing a bat many times rather than once (Niall, 2026-09-10). A median of
    /// the two would be a number nobody measured.
    static func reliability(for code: String) -> SpeciesReliability? {
        guard let r = nabat[code], r.quotablePrecision != nil else { return nil }
        return r
    }

    /// Why a species has no precision to show — so the row can say which of the
    /// two quite different reasons applies instead of just showing nothing.
    ///
    /// The badge that used to sit here fell back to the call's own confidence
    /// whenever this returned a reason, which put two unrelated quantities behind
    /// one identical-looking percentage. It shows the reason now.
    enum PrecisionAbsence: Equatable {
        /// The model that named this species publishes no per-species track
        /// record at all (BatDetect2), so there is nothing to quote for any of
        /// its species.
        case notPublished
        /// The model publishes one, but this species was tested on too few
        /// recordings for the figure to mean anything — see `minimumSampleSize`.
        case tooFewTestRecordings(Int)
    }

    /// nil when there *is* a quotable precision for `code`.
    static func precisionAbsence(for code: String) -> PrecisionAbsence? {
        guard let r = nabat[code] else { return .notPublished }
        guard r.quotablePrecision == nil else { return nil }
        return .tooFewTestRecordings(r.sampleSize)
    }
}
