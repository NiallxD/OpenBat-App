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

enum PassAggregation {

    /// One pulse's contribution to a pass: raw (pre-prior) softmax scores from the
    /// model, and prior-adjusted, renormalized posteriors (`BatClassifier.classify`'s
    /// `allScores`).
    struct Pulse {
        let rawScores: [String: Float]
        let adjustedScores: [String: Float]
    }

    struct Outcome {
        let species: String   // "NOISE" or a species code — never "No ID"/nil, see aggregate(_:)
        let confidence: Float
        let meanScores: [String: Float]
    }

    /// Mean per-pulse raw confidence below this is NoID — the reference pipeline's
    /// fixed threshold, applied to each pulse's own top raw score (not adjusted by
    /// species priors), not a user-tunable setting.
    static let noidRawConfidenceThreshold: Float = 0.57

    /// Returns `nil` for NoID — not enough raw-confidence evidence to call anything,
    /// matching the reference pipeline. Otherwise returns the winning outcome:
    /// `Outcome(species: "NOISE", ...)` when the raw evidence's top class is noise, or
    /// the winning species among `minAdjustedConfidence`/`minPulseCount`-gated,
    /// prior-adjusted posteriors otherwise.
    static func aggregate(_ pulses: [Pulse],
                          minAdjustedConfidence: Float,
                          minPulseCount: Int) -> Outcome? {
        guard !pulses.isEmpty else { return nil }
        let n = Float(pulses.count)

        // NoID gate: mean of each pulse's own top RAW score (its confidence in
        // whatever it predicted, unbiased by priors) — independent of which class
        // actually wins below.
        let meanRawConfidence = pulses.reduce(Float(0)) { $0 + ($1.rawScores.values.max() ?? 0) } / n
        guard meanRawConfidence >= noidRawConfidenceThreshold else { return nil }   // NoID

        // Winning class by raw evidence, aggregated across the pass's pulses.
        var rawSum: [String: Float] = [:]
        for p in pulses { for (k, v) in p.rawScores { rawSum[k, default: 0] += v } }
        guard let rawBest = rawSum.max(by: { $0.value < $1.value }) else { return nil }

        if rawBest.key == "NOISE" {
            return Outcome(species: "NOISE",
                           confidence: rawBest.value / n,
                           meanScores: rawSum.mapValues { $0 / n })
        }

        // Real bat call by raw evidence — now defer to prior-adjusted posteriors to
        // decide which (enabled) species to report, same as OpenBat's existing
        // species-filtering/confidence-tuning behaviour.
        var adjSum: [String: Float] = [:]
        for p in pulses { for (k, v) in p.adjustedScores { adjSum[k, default: 0] += v } }
        let candidates = adjSum.filter { $0.key != "NOISE" }
        let pool = candidates.isEmpty ? adjSum : candidates
        guard let best = pool.max(by: { $0.value < $1.value }) else { return nil }

        let meanConf = best.value / n
        guard pulses.count >= minPulseCount, meanConf >= minAdjustedConfidence else { return nil }

        return Outcome(species: best.key, confidence: meanConf, meanScores: adjSum.mapValues { $0 / n })
    }
}
