//
//  PassAggregation.swift
//  OpenBat
//
//  Implements the NABat-ml reference pipeline's pass-level outcome rule: given the
//  raw (pre-prior) per-pulse softmax scores for a pass, decide whether there's
//  enough real signal to call anything at all.
//
//  The paper's pass outcomes are NoID* (no qualifying pulse — not modelled here,
//  since OpenBat's passes are pulse-triggered and only exist once a pulse has
//  already been captured), NoID (pulses present, but mean per-pulse raw confidence
//  is below `noidRawConfidenceThreshold`), NOISE (raw evidence's winning class is
//  the noise class), or a species code.
//
//  This raw-confidence gate answers "is this a real, confidently-classified sound
//  at all" using the model's unbiased output. It is deliberately independent of
//  OpenBat's own prior-adjusted species filtering (disabled species, per-model
//  `minPassConfidence`/`minPassPulseCount`) — that machinery only decides WHICH of
//  the user's enabled species to report once the raw evidence has already
//  established that this is a real bat call, not noise.
//
//  Shared by `PulseDetector.finalizePass()` (in-app passes) and
//  `AudioRecorder.speciesAutoID()` (WAV GUANO tagging) so the two can't disagree
//  about whether a burst of pulses is noise, unidentifiable, or a species.
//

import Foundation

/// `nonisolated`: same reasoning as `Biquad`/`AudioLevel` — stateless gating math with
/// no isolation annotation, called from both `PulseDetector.finalizePass` (main actor)
/// and `AudioRecorder.speciesAutoID` (now `nonisolated`, its own background queue).
nonisolated enum PassAggregation {

    /// One pulse's contribution to a pass: raw (pre-prior) softmax scores from the
    /// model, and prior-adjusted, renormalized posteriors (`BatClassifier.classify`'s
    /// `allScores`).
    struct Pulse {
        let rawScores: [String: Float]
        let adjustedScores: [String: Float]
    }

    /// Why a pass came back unnamed.
    ///
    /// **"NoID" was one word for five different findings**, and the difference
    /// matters to whoever reads the record: a pass the model had no confidence in
    /// is not the same as a pass it was very confident about and could not choose
    /// within. A Squamish evening of 2026-09-07 recorded 35 NoIDs, of which 9 had
    /// cleared the evidence gate — one at 0.946 raw over 19 pulses — and nothing
    /// in the export said what had stopped them.
    ///
    /// Raw values are stable: they are persisted on the pass and exported.
    enum NoIDReason: String, Codable {
        /// No pulses reached aggregation at all.
        case noPulses
        /// Mean per-pulse raw confidence below the model's own NoID threshold —
        /// the model was not sure this was a classifiable call.
        case weakEvidence
        /// Fewer pulses than the user's minimum for naming a pass.
        case tooFewPulses
        /// Adjusted confidence in the winner below the user's minimum.
        case lowConfidence
        /// Strong evidence, but the top two species were within
        /// `minWinningMargin`. The interesting one: this is a refusal, not a
        /// failure, and the runner-up is worth reading.
        case tooCloseToCall
    }

    /// What a pass came to. `outcome` and `noIDReason` let a caller that only
    /// cares about one half keep reading it the way it always did.
    enum Verdict {
        case named(Outcome)
        case noID(NoIDReason)

        var outcome: Outcome? {
            if case .named(let o) = self { return o }
            return nil
        }
        var noIDReason: NoIDReason? {
            if case .noID(let r) = self { return r }
            return nil
        }
    }

    struct Outcome {
        let species: String   // "NOISE" or a species code — never "No ID"/nil, see aggregate(_:)
        let confidence: Float
        let meanScores: [String: Float]
        /// Mean of each pulse's own top RAW score — the model's confidence in
        /// whatever it predicted, before priors. Distinct from `confidence`,
        /// which is prior-adjusted and about the species actually reported.
        /// Carried out of here so it can be persisted on the pass and exported:
        /// it is the only number that says how strong the acoustic evidence was
        /// independently of the user's own location and species settings.
        let meanRawConfidence: Float
        /// Mean RAW score of the species actually reported — the same quantity
        /// as `confidence`, measured before the priors were applied and the
        /// posteriors renormalized.
        ///
        /// `meanRawConfidence` above is NOT that: it is the top score of
        /// whatever each pulse individually predicted, so on a pass where the
        /// pulses disagreed it is a maximum across several species and sits
        /// ABOVE the reported species' own score. Printing the two side by side
        /// as "before and after weighting" made a pass whose weighting had
        /// pushed the species UP look as though it had been pushed down
        /// (2026-09-05). This is the number that pairs with `confidence`.
        let rawSpeciesConfidence: Float
    }

    /// Mean per-pulse raw confidence below this is NoID — the reference pipeline's
    /// fixed threshold for NABat, applied to each pulse's own top raw score (not
    /// adjusted by species priors), not a user-tunable setting. Kept as the default so
    /// existing call sites that don't pass `rawConfidenceThreshold` explicitly keep
    /// NABat's exact, already-verified behavior.
    static let noidRawConfidenceThreshold: Float = 0.57

    /// Returns `nil` for NoID — not enough raw-confidence evidence to call anything,
    /// matching the reference pipeline. Otherwise returns the winning outcome:
    /// `Outcome(species: "NOISE", ...)` when the raw evidence's top class is noise, or
    /// the winning species among `minAdjustedConfidence`/`minPulseCount`-gated,
    /// prior-adjusted posteriors otherwise.
    ///
    /// - Parameters:
    ///   - rawConfidenceThreshold: model-specific NoID cutoff. Defaults to NABat's
    ///     verified 0.57. BatDetect2's classifier head is a per-pixel softmax with very
    ///     different dynamics (see `BatDetect2Classifier` — often far more sharply
    ///     peaked than NABat's), so its threshold below (0.4, in `ModelDescriptor`) is
    ///     a documented starting point, NOT independently verified against a labelled
    ///     noise/no-call dataset the way NABat's 0.57 was. Revisit once field data is
    ///     available.
    ///   - noiseClassName: the class name that means "not a bat call", if the model has
    ///     one. NABat's reference pipeline has an explicit "NOISE" class; BatDetect2 has
    ///     none — its background/"not bat" probability is summed away into
    ///     `detection_probs` before OpenBat ever sees per-class scores (see
    ///     `BatDetect2Classifier`), so passing `nil` here is correct, not a gap.
    /// Mean of each pulse's own top raw score. Exposed separately because the
    /// NoID path needs it too: `aggregate` returns nil there, and the raw
    /// confidence is precisely the number that failed the gate — the most
    /// informative thing about a pass OpenBat declined to name.
    static func meanRawConfidence(_ pulses: [Pulse]) -> Float {
        guard !pulses.isEmpty else { return 0 }
        return pulses.reduce(Float(0)) { $0 + ($1.rawScores.values.max() ?? 0) } / Float(pulses.count)
    }

    /// `minWinningMargin` is how far clear of the runner-up the winner must be
    /// before the pass is named at all. Below it the pass is a NoID.
    ///
    /// **A pass whose top two species are neck and neck is not a weak
    /// identification, it is an unanswered question**, and reporting the winner
    /// anyway states as fact something a couple of pulses either way would have
    /// reversed. Measured on the demo clip: correctly segmented passes separated
    /// their top two by 0.15 at the tightest, while the blended passes that kept
    /// flipping species between builds sat at 0.003–0.017. Nothing legitimate was
    /// observed in between.
    ///
    /// The cost is real and was accepted deliberately (Niall, 2026-09-07): two
    /// species genuinely calling at once will now go unnamed rather than have one
    /// of them picked. Silence is the honest answer there, and the pulses are
    /// still recorded — only the pass's verdict is withheld.
    ///
    /// Defaults to 0 so callers that have not been taught about it, and the
    /// tests that predate it, behave exactly as before.
    static func aggregate(_ pulses: [Pulse],
                          minAdjustedConfidence: Float,
                          minPulseCount: Int,
                          rawConfidenceThreshold: Float = noidRawConfidenceThreshold,
                          noiseClassName: String? = "NOISE",
                          minWinningMargin: Float = 0) -> Verdict {
        guard !pulses.isEmpty else { return .noID(.noPulses) }
        let n = Float(pulses.count)

        // NoID gate: mean of each pulse's own top RAW score (its confidence in
        // whatever it predicted, unbiased by priors) — independent of which class
        // actually wins below.
        let rawConfidence = meanRawConfidence(pulses)
        guard rawConfidence >= rawConfidenceThreshold else { return .noID(.weakEvidence) }

        // Winning class by raw evidence, aggregated across the pass's pulses.
        var rawSum: [String: Float] = [:]
        for p in pulses { for (k, v) in p.rawScores { rawSum[k, default: 0] += v } }
        guard let rawBest = rawSum.highestScoring() else { return .noID(.weakEvidence) }

        if let noiseClassName, rawBest.key == noiseClassName {
            return .named(Outcome(species: noiseClassName,
                                  confidence: rawBest.value / n,
                                  meanScores: rawSum.mapValues { $0 / n },
                                  meanRawConfidence: rawConfidence,
                                  rawSpeciesConfidence: rawBest.value / n))
        }

        // Real bat call by raw evidence — now defer to prior-adjusted posteriors to
        // decide which (enabled) species to report, same as OpenBat's existing
        // species-filtering/confidence-tuning behaviour.
        var adjSum: [String: Float] = [:]
        for p in pulses { for (k, v) in p.adjustedScores { adjSum[k, default: 0] += v } }
        let candidates = adjSum.filter { $0.key != noiseClassName }
        let pool = candidates.isEmpty ? adjSum : candidates
        guard let best = pool.highestScoring() else { return .noID(.weakEvidence) }

        let meanConf = best.value / n
        guard pulses.count >= minPulseCount else { return .noID(.tooFewPulses) }
        guard meanConf >= minAdjustedConfidence else { return .noID(.lowConfidence) }

        // Margin gate. Measured against the runner-up among the same candidates the
        // winner was chosen from, so a suppressed noise class cannot count as the
        // contender. A pass with only one candidate has nothing to be confused with
        // and passes trivially.
        if minWinningMargin > 0 {
            let runnerUp = pool.filter { $0.key != best.key }.highestScoring()
            let margin = meanConf - ((runnerUp?.value ?? 0) / n)
            guard margin >= minWinningMargin else { return .noID(.tooCloseToCall) }
        }

        return .named(Outcome(species: best.key, confidence: meanConf,
                              meanScores: adjSum.mapValues { $0 / n },
                              meanRawConfidence: rawConfidence,
                              rawSpeciesConfidence: (rawSum[best.key] ?? 0) / n))
    }
}

/// Highest-scoring entry, with ties broken by species code.
///
/// `Dictionary.max(by:)` walks the dictionary in hash order, and Swift seeds its
/// hashing per process — so an exact tie between two species resolved differently
/// between launches, and the same recording could re-classify differently on a
/// re-run. Vanishingly rare with float scores, but a log people compare across
/// sessions shouldn't have that property at all. The code is an arbitrary but
/// stable tiebreak; what matters is that it is the same every time.
extension Dictionary where Key == String, Value == Float {
    func highestScoring() -> (key: String, value: Float)? {
        var best: (key: String, value: Float)?
        for (k, v) in self {
            guard let current = best else { best = (k, v); continue }
            if v > current.value || (v == current.value && k < current.key) {
                best = (k, v)
            }
        }
        return best
    }
}
