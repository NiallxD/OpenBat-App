//
//  PassAggregationTests.swift
//  OpenBatTests
//
//  This is where a pass becomes an identification, and it is shared by the live
//  detector and the WAV GUANO tagger so the two can't disagree. It had no tests.
//
//  The rules it encodes are subtle enough to be worth pinning down explicitly,
//  because they are easy to "simplify" into something wrong:
//
//    * the NoID gate uses each pulse's own TOP RAW score, species discarded — it
//      asks "were these decisive?", not "were these all the same thing";
//    * the reported species comes from prior-ADJUSTED scores, while the NOISE check
//      comes from RAW ones, so priors can never invent evidence that a call
//      happened;
//    * ties break deterministically. `Dictionary.max(by:)` walks in hash order and
//      Swift seeds hashing per process, so before 2026-08-18 an exact tie resolved
//      differently between launches and the same recording could re-classify
//      differently on a re-run.
//

import Foundation
import Testing
@testable import OpenBat

struct PassAggregationTests {

    /// A pulse whose raw scores are given and whose adjusted scores default to the
    /// same thing (i.e. neutral priors) unless overridden.
    private func pulse(raw: [String: Float], adjusted: [String: Float]? = nil) -> PassAggregation.Pulse {
        PassAggregation.Pulse(rawScores: raw, adjustedScores: adjusted ?? raw)
    }

    private func aggregate(_ pulses: [PassAggregation.Pulse],
                           minAdjustedConfidence: Float = 0.05,
                           minPulseCount: Int = 1,
                           rawThreshold: Float = PassAggregation.noidRawConfidenceThreshold,
                           noiseClassName: String? = "NOISE",
                           minWinningMargin: Float = 0) -> PassAggregation.Outcome? {
        PassAggregation.aggregate(pulses,
                                  minAdjustedConfidence: minAdjustedConfidence,
                                  minPulseCount: minPulseCount,
                                  rawConfidenceThreshold: rawThreshold,
                                  noiseClassName: noiseClassName,
                                  minWinningMargin: minWinningMargin).outcome
    }

    /// Same call, asking the other half: why did it decline?
    private func reason(_ pulses: [PassAggregation.Pulse],
                        minAdjustedConfidence: Float = 0.05,
                        minPulseCount: Int = 1,
                        rawThreshold: Float = PassAggregation.noidRawConfidenceThreshold,
                        noiseClassName: String? = "NOISE",
                        minWinningMargin: Float = 0) -> PassAggregation.NoIDReason? {
        PassAggregation.aggregate(pulses,
                                  minAdjustedConfidence: minAdjustedConfidence,
                                  minPulseCount: minPulseCount,
                                  rawConfidenceThreshold: rawThreshold,
                                  noiseClassName: noiseClassName,
                                  minWinningMargin: minWinningMargin).noIDReason
    }

    // MARK: Why a pass went unnamed

    /// "NoID" was one word for several findings. A field evening recorded 35 of
    /// them, 9 of which had cleared the evidence gate — one at 0.946 raw over 19
    /// pulses — and nothing said what had actually stopped those.
    @Test func eachWayOfFailingIsToldApart() {
        // Strong, and split between two species: a refusal, not a failure.
        #expect(reason([pulse(raw: ["MYLU": 0.90, "LANO": 0.88]),
                        pulse(raw: ["MYLU": 0.86, "LANO": 0.89])],
                       minWinningMargin: 0.10) == .tooCloseToCall)
        // The model itself was unsure.
        #expect(reason([pulse(raw: ["MYLU": 0.20, "LANO": 0.18])]) == .weakEvidence)
        // Strong and clear, but not enough of it.
        #expect(reason([pulse(raw: ["MYLU": 0.95])], minPulseCount: 3) == .tooFewPulses)
        // Nothing to aggregate.
        #expect(reason([]) == .noPulses)
        // And a pass that succeeds reports no reason at all.
        #expect(reason([pulse(raw: ["MYLU": 0.95]), pulse(raw: ["MYLU": 0.92])]) == nil)
    }

    // MARK: Defaults that have to reach an existing install

    /// **Changing a default does nothing to anyone who already has the app.**
    /// Saved per-model settings are overlaid on top of the defaults at load, so an
    /// install carrying the old 2.0 s pass timeout kept it and the change shipped
    /// invisibly — one build spent looking for a fault in the segmentation that
    /// was really a value that had never been applied.
    @Test func theOldPassTimeoutIsMigratedForward() {
        #expect(AutoIDSettings.defaultPassTimeoutSeconds == 1.1)
        let d = try? #require(ModelRegistry.descriptor(id: ModelRegistry.nabatID))
        let seeded = d.map { AutoIDSettings.defaultSettings(for: $0) }
        #expect(seeded?.passTimeoutSeconds == AutoIDSettings.defaultPassTimeoutSeconds,
                "the seed and the named default must not drift apart")
        #expect(seeded?.minWinningMargin == 0.10)
    }

    // MARK: The margin gate

    /// The case this exists for. Two species neck and neck is not a weak ID, it is
    /// an unanswered question — and on the demo clip a pass like this reported a
    /// different species between builds while the audio never changed.
    @Test func aPassTooCloseToCallIsNotNamed() {
        let pulses = [pulse(raw: ["MYLU": 0.90, "LANO": 0.88]),
                      pulse(raw: ["MYLU": 0.86, "LANO": 0.89])]
        #expect(aggregate(pulses, minWinningMargin: 0.10) == nil)
        // ...and without the gate it names one, which is the old behaviour.
        #expect(aggregate(pulses)?.species != nil)
    }

    /// A clear winner is unaffected. The gate must not be a general tax on
    /// confidence — the tightest legitimate margin measured on real passes was
    /// 0.15, so 0.10 has to leave that alone.
    @Test func aClearWinnerIsStillNamed() {
        let pulses = [pulse(raw: ["MYLU": 0.90, "MYYU": 0.60]),
                      pulse(raw: ["MYLU": 0.88, "MYYU": 0.62])]
        #expect(aggregate(pulses, minWinningMargin: 0.10)?.species == "MYLU")
    }

    /// A pass with one candidate has nothing to be confused with, so the runner-up
    /// is absent rather than zero-scoring. It must not read as a tie against
    /// nothing and suppress a perfectly good single-species pass.
    @Test func aSingleCandidateIsNotATie() {
        let pulses = [pulse(raw: ["MYLU": 0.90]), pulse(raw: ["MYLU": 0.85])]
        #expect(aggregate(pulses, minWinningMargin: 0.10)?.species == "MYLU")
    }

    /// The noise class is suppressed before the winner is chosen, so it must not
    /// come back as the contender and veto a real species.
    @Test func theNoiseClassIsNotTheRunnerUp() {
        let pulses = [pulse(raw: ["MYLU": 0.60, "NOISE": 0.58]),
                      pulse(raw: ["MYLU": 0.62, "NOISE": 0.55])]
        #expect(aggregate(pulses, minWinningMargin: 0.10)?.species == "MYLU")
    }

    /// Off by default, so every caller that predates the gate — and the WAV
    /// tagging path until it is told otherwise — behaves exactly as before.
    @Test func theGateIsOffUnlessAskedFor() {
        let pulses = [pulse(raw: ["MYLU": 0.90, "LANO": 0.89])]
        #expect(aggregate(pulses)?.species == "MYLU")
    }

    // MARK: The NoID gate

    /// Four confident pulses that disagree about the species still clear the gate:
    /// they are four real bat calls, which is what the gate is asking about. If it
    /// tracked a single species instead, a strong pass of a hard-to-separate genus
    /// would be thrown away — exactly the Myotis case.
    @Test func confidentButDisagreeingPulsesStillClearTheNoIDGate() throws {
        let pulses = [
            pulse(raw: ["PIPPIP": 0.81, "PIPPYG": 0.12, "MYODAU": 0.07]),
            pulse(raw: ["PIPPYG": 0.74, "PIPPIP": 0.20, "MYODAU": 0.06]),
            pulse(raw: ["PIPPIP": 0.79, "PIPPYG": 0.15, "MYODAU": 0.06]),
            pulse(raw: ["MYODAU": 0.68, "PIPPIP": 0.22, "PIPPYG": 0.10]),
        ]
        // Mean top raw = (0.81 + 0.74 + 0.79 + 0.68) / 4 = 0.755, above 0.57.
        let outcome = try #require(aggregate(pulses), "a pass of four confident calls must not be NoID")
        #expect(outcome.species == "PIPPIP", "the species with the most aggregate evidence should win")
    }

    /// The mirror image: pulses that agree perfectly but are all weak are NoID,
    /// because nothing about them looked like a call.
    @Test func consistentButWeakPulsesAreNoID() {
        let pulses = (0..<6).map { _ in
            pulse(raw: ["PIPPIP": 0.30, "PIPPYG": 0.28, "MYODAU": 0.22, "NYCNOC": 0.20])
        }
        #expect(aggregate(pulses) == nil, "mean top raw of 0.30 is below the gate — must be NoID")
    }

    /// Priors must not be able to push a pass through the NoID gate. That gate is
    /// the one question the user's settings are deliberately not allowed to answer.
    @Test func priorsCannotRescueAPassFromNoID() {
        let weak: [String: Float] = ["PIPPIP": 0.30, "PIPPYG": 0.30, "MYODAU": 0.20, "NYCNOC": 0.20]
        // Adjusted scores are wildly confident; raw ones are not.
        let confident: [String: Float] = ["PIPPIP": 0.97, "PIPPYG": 0.01, "MYODAU": 0.01, "NYCNOC": 0.01]
        let pulses = (0..<5).map { _ in pulse(raw: weak, adjusted: confident) }

        #expect(aggregate(pulses) == nil,
                "priors reached the NoID gate — it must read raw scores only")
    }

    // MARK: Noise

    @Test func noiseWinningOnRawEvidenceIsReportedAsNoise() throws {
        let pulses = (0..<4).map { _ in
            pulse(raw: ["NOISE": 0.85, "PIPPIP": 0.10, "MYODAU": 0.05])
        }
        let outcome = try #require(aggregate(pulses))
        #expect(outcome.species == "NOISE")
    }

    /// A model with no noise class (BatDetect2 sums its background probability away
    /// before OpenBat sees per-class scores) must not have one invented for it.
    @Test func modelWithoutANoiseClassNeverReportsNoise() throws {
        let pulses = (0..<4).map { _ in
            pulse(raw: ["PIPPIP": 0.80, "MYODAU": 0.20])
        }
        let outcome = try #require(aggregate(pulses, noiseClassName: nil))
        #expect(outcome.species == "PIPPIP")
    }

    // MARK: Priors decide which species, not whether

    /// Raw evidence favours one species; priors favour another. The reported
    /// species must be the prior-adjusted winner — that is the whole mechanism by
    /// which "this species doesn't live here" takes effect.
    @Test func reportedSpeciesComesFromAdjustedScores() throws {
        let raw: [String: Float] = ["NYCNOC": 0.70, "PIPPIP": 0.25, "MYODAU": 0.05]
        // Noctule suppressed by location; pipistrelle left alone, then renormalised.
        let adjusted: [String: Float] = ["NYCNOC": 0.02, "PIPPIP": 0.93, "MYODAU": 0.05]
        let pulses = (0..<4).map { _ in pulse(raw: raw, adjusted: adjusted) }

        let outcome = try #require(aggregate(pulses))
        #expect(outcome.species == "PIPPIP", "priors should decide which species is reported")
    }

    // MARK: Gates

    @Test func aPassBelowTheMinimumPulseCountIsRejected() {
        let pulses = [pulse(raw: ["PIPPIP": 0.90, "MYODAU": 0.10])]
        #expect(aggregate(pulses, minPulseCount: 3) == nil)
    }

    @Test func aWinnerBelowMinimumAdjustedConfidenceIsRejected() {
        // Clears the raw gate, but the winner's mean adjusted score is small because
        // the adjusted mass is spread thin.
        let raw: [String: Float] = ["A": 0.95, "B": 0.05]
        let adjusted: [String: Float] = ["A": 0.10, "B": 0.09, "C": 0.09, "D": 0.09,
                                         "E": 0.09, "F": 0.09, "G": 0.45]
        let pulses = (0..<4).map { _ in pulse(raw: raw, adjusted: adjusted) }
        #expect(aggregate(pulses, minAdjustedConfidence: 0.60) == nil)
    }

    @Test func emptyPassProducesNothing() {
        #expect(aggregate([]) == nil)
    }

    // MARK: Determinism

    /// An exact tie must resolve the same way every time. This is the regression
    /// guard for the hash-order tiebreak: run the same input through many freshly
    /// built dictionaries and require a single answer.
    ///
    /// Note that Swift's per-process hash seed means a genuinely broken
    /// implementation may still pass within ONE process — so the dictionaries are
    /// rebuilt with differing insertion orders, which is what actually shuffles the
    /// storage layout and exposes the bug.
    @Test func exactTiesResolveIdenticallyEveryTime() throws {
        let codes = ["MYODAU", "MYOBRA", "MYONAT", "MYOMYS", "MYOALC", "MYOBEC"]
        var winners = Set<String>()

        // The SAME two species are tied every time — only the insertion order
        // varies. (An earlier version of this test varied which species were tied,
        // so it was comparing different inputs and failed for that reason rather
        // than for the one it was written to catch.) The tied value must also clear
        // the NoID gate, or the pass is discarded before any tiebreak happens.
        let tied: Set<String> = ["MYOBRA", "MYOALC"]

        for permutation in 0..<64 {
            var raw: [String: Float] = [:]
            var order = codes
            order.shuffle()
            for code in order {
                raw[code] = tied.contains(code) ? 0.70 : 0.05
            }
            let pulses = (0..<4).map { _ in pulse(raw: raw) }
            if let outcome = aggregate(pulses) { winners.insert(outcome.species) }
        }

        #expect(winners.count == 1,
                "an exact tie resolved \(winners.count) different ways: \(winners.sorted())")
    }

    /// And the tiebreak should be the documented one — lowest code wins — rather
    /// than merely "stable by accident".
    @Test func tiesBreakOnTheLowerSpeciesCode() throws {
        let raw: [String: Float] = ["ZZZZ": 0.70, "AAAA": 0.70, "MMMM": 0.10]
        let pulses = (0..<4).map { _ in pulse(raw: raw) }
        let outcome = try #require(aggregate(pulses))
        #expect(outcome.species == "AAAA")
    }

    /// `meanScores` is what the runner-up and the displayed percentage are read
    /// from, so it must be a mean over the pass, not a sum.
    @Test func meanScoresAreAveragedOverThePass() throws {
        let pulses = [
            pulse(raw: ["PIPPIP": 0.90, "MYODAU": 0.10]),
            pulse(raw: ["PIPPIP": 0.70, "MYODAU": 0.30]),
        ]
        let outcome = try #require(aggregate(pulses))
        let pip = try #require(outcome.meanScores["PIPPIP"])
        #expect(abs(pip - 0.80) < 0.001, "expected the mean (0.80), got \(pip)")
        #expect(abs(outcome.confidence - 0.80) < 0.001)
    }

    // MARK: The two raw numbers

    /// `rawSpeciesConfidence` is the REPORTED species' own raw score, and
    /// `meanRawConfidence` is the top score of whatever each call was
    /// individually taken for. On a pass where the calls disagree they are
    /// different numbers, and only the first one can be printed beside the
    /// weighted confidence — printing the second made a weighting that pushed
    /// a species up read as having pushed it down (2026-09-05).
    @Test func rawSpeciesConfidenceIsTheReportedSpeciesOwnScore() throws {
        let pulses = [
            pulse(raw: ["LASCIN": 0.80, "LASNOC": 0.20]),
            pulse(raw: ["LASNOC": 0.90, "LASCIN": 0.10]),
            pulse(raw: ["LASCIN": 0.85, "LASNOC": 0.15]),
            pulse(raw: ["LASCIN": 0.75, "LASNOC": 0.25]),
        ]
        let outcome = try #require(aggregate(pulses))
        #expect(outcome.species == "LASCIN")
        // LASCIN's own mean: (0.80 + 0.10 + 0.85 + 0.75) / 4 = 0.625.
        #expect(abs(outcome.rawSpeciesConfidence - 0.625) < 0.001,
                "expected LASCIN's own mean raw score, got \(outcome.rawSpeciesConfidence)")
        // Mean top raw: (0.80 + 0.90 + 0.85 + 0.75) / 4 = 0.825 — higher,
        // because one call was taken for the other species.
        #expect(abs(outcome.meanRawConfidence - 0.825) < 0.001)
        #expect(outcome.rawSpeciesConfidence < outcome.meanRawConfidence)
    }

    /// With neutral priors the pair collapses: nothing was weighted, so the
    /// species' raw score and its reported confidence are the same number. Any
    /// difference a real record shows between them is therefore the weighting
    /// and nothing else, which is the whole claim the description makes.
    @Test func neutralPriorsLeaveTheRawAndWeightedFiguresEqual() throws {
        let pulses = [
            pulse(raw: ["LASCIN": 0.80, "LASNOC": 0.20]),
            pulse(raw: ["LASCIN": 0.70, "LASNOC": 0.30]),
        ]
        let outcome = try #require(aggregate(pulses))
        #expect(abs(outcome.rawSpeciesConfidence - outcome.confidence) < 0.001)
    }
}
