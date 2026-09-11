//
//  ClassifierAnalysis.swift
//  OpenBat
//
//  Re-runs the classifier over a saved recording and shows its working: for
//  every call, the model's own softmax and the posterior after the location
//  priors have been applied, side by side.
//
//  WHY A RE-RUN RATHER THAN A REPLAY OF WHAT WAS SAVED
//  ---------------------------------------------------
//  What the live path stores is deliberately partial, and every hole is there
//  for a reason. Pulse pictures are drawn a couple of seconds apart because
//  drawing is what holds the capture queue and a discarded render costs real
//  detections (`PulseDetector`'s `wantsImage`). The raw, pre-prior scores are
//  never written down at all — not by the store, and not by the classifier CSV,
//  which logs the adjusted ones. So "show me what was saved" could never answer
//  the question this screen exists for.
//
//  Off the microphone there is no deadline. Every call gets its picture, its
//  full score vector, and both halves of the arithmetic that produced the name.
//
//  NOT STORED, RECOMPUTED
//  ----------------------
//  The result is held for as long as the sheet is open and thrown away after
//  (Niall, 2026-09-10: "if computation is cheap we don't need to store it, it's
//  not likely to change between reruns"). That holds because every input is
//  fixed: the same WAV, the same model, and — see below — the priors the
//  session was actually run with rather than today's.
//
//  WHICH PRIORS
//  ------------
//  The session's own `PriorSnapshot`, when it has one: those are the weights
//  that produced the ID being examined, and they are what makes a re-run
//  reproducible rather than a function of where the phone is standing today.
//  A recording made outside a session, or made before snapshots existed, falls
//  back to the current settings and the screen says so.
//
//  WHAT IT CANNOT SHOW
//  -------------------
//  Calls the live path never captured. The onsets come from the pulses that
//  were stored, so a pulse dropped because a capture was already in flight
//  (`PulseDetector.capturesSkipped`) leaves no timestamp to re-analyse. Finding
//  those would mean re-running detection over the file, which is a larger job
//  than re-running classification and is not what this does.
//

import AVFoundation
import Foundation
import UIKit

nonisolated enum ClassifierAnalysis {

    /// One call, as the model saw it.
    struct Pulse: Identifiable {
        let id: UUID
        /// Position in the recording, 1-based, in the order they were heard.
        let number: Int
        /// Seconds from the start of the WAV — which includes the pre-roll.
        let offsetSeconds: Double
        let image: UIImage?
        let imageFreqMinHz: Double?
        let imageFreqMaxHz: Double?
        let imageSpanMs: Double?
        let peakFreqHz: Double
        let durationMs: Double
        /// The model's own softmax over its classes, descending. This is the
        /// number nothing in the app has ever written down.
        let raw: [ScoreEntry]
        /// After the priors, renormalised — what the app acts on.
        let adjusted: [ScoreEntry]
        /// What each would have been called on its own. When they differ, the
        /// location changed the answer for this call, which is the single most
        /// interesting fact this screen can report.
        var rawWinner: String { raw.first?.species ?? "—" }
        var adjustedWinner: String { adjusted.first?.species ?? "—" }
        var priorChangedTheAnswer: Bool { rawWinner != adjustedWinner }
    }

    struct Result {
        let pulses: [Pulse]
        let modelID: String
        let modelName: String
        /// Mean of the per-pulse vectors across every re-analysed call, the way
        /// a pass is aggregated — descending, both halves.
        let meanRaw: [ScoreEntry]
        let meanAdjusted: [ScoreEntry]
        /// The weights used, and where they came from.
        let priors: [String: Float]
        let priorsAreFromSession: Bool
        let priorsTakenAt: Date?
        let locationWeightingApplied: Bool
        /// What the app decided at the time, for comparison with the re-run.
        let storedSpecies: String
        /// Pulses that were stored but could not be re-analysed — too close to
        /// the start or end of the file for a full model window, or rejected by
        /// the quality gate this time. Reported rather than quietly dropped.
        let skipped: Int
    }

    /// Everything the re-run needs, gathered on the main actor and handed over
    /// as one value.
    ///
    /// One parameter rather than twelve because the closure that carries them
    /// to a background task is otherwise large enough to crash the Swift
    /// compiler outright — `ClosureLifetimeFixup` on `analyse()`, and only
    /// under the coverage instrumentation a test build turns on, so a plain
    /// build looked fine (2026-09-10). It reads better this way regardless.
    struct Input {
        let recording: Recording
        let wavURL: URL
        let pulses: [PulseTime]
        let modelID: String
        let priors: [String: Float]
        let priorsAreFromSession: Bool
        let priorsTakenAt: Date?
        let locationWeightingApplied: Bool
        let qualityGate: QualityGate
        let noiseFloor: Float
        let minFrequencyHz: Double
        let displaySpanSeconds: Double
    }

    struct PulseTime {
        let id: UUID
        let date: Date
    }

    /// Re-analyse one recording. Slow enough to want a background task (a model
    /// inference per call) and nowhere near slow enough to need caching.
    static func run(_ input: Input) -> Result? {
        let recording = input.recording
        let wavURL = input.wavURL
        let pulses = input.pulses
        let modelID = input.modelID
        let priors = input.priors
        let qualityGate = input.qualityGate
        let noiseFloor = input.noiseFloor
        let minFrequencyHz = input.minFrequencyHz
        let displaySpanSeconds = input.displaySpanSeconds
        guard let descriptor = ModelRegistry.descriptor(id: modelID),
              let classifier = descriptor.makeClassifier() else { return nil }

        let file = try? AVAudioFile(forReading: wavURL)
        let sampleRate = file?.fileFormat.sampleRate ?? 384_000
        let totalSamples = Int(file?.length ?? 0)

        let spec = descriptor.input
        // The same window the live path hands the model: `windowSeconds` long,
        // with the onset `onsetFraction` of the way into it. Copied from
        // `PulseDetector.scheduleCapture` rather than re-derived — a re-run that
        // framed the call differently would be answering a different question.
        let clsCount = max(PulseImageRenderer.fftLen, Int(spec.windowSeconds * sampleRate))
        // And the wider window the picture is drawn from, so the crop matches
        // what the live view would have shown.
        let dispSpanSamples = max(PulseImageRenderer.fftLen + PulseImageRenderer.displayHop,
                                  Int(displaySpanSeconds * sampleRate))

        var analysed: [Pulse] = []
        var skipped = 0

        for (index, pulse) in pulses.enumerated() {
            // Pulse timestamps are absolute; the recording's own date is the
            // time of its first sample, pre-roll included.
            let offset = pulse.date.timeIntervalSince(recording.date)
            guard offset >= 0 else { skipped += 1; continue }
            let onsetSample = Int(offset * sampleRate)

            let clsStart = onsetSample - Int(Double(clsCount) * spec.onsetFraction)
            guard clsStart >= 0, clsStart + clsCount <= totalSamples,
                  let clsPCM = WavPCMReader.readSamples(wavURL: wavURL,
                                                        startSample: clsStart,
                                                        count: clsCount),
                  clsPCM.count == clsCount
            else { skipped += 1; continue }

            guard let classification = classifier.classify(pcm: clsPCM,
                                                           gate: qualityGate,
                                                           prior: { priors[$0] ?? 1.0 })
            else { skipped += 1; continue }

            // Picture and measurements from the wider window, exactly as the
            // live renderer would have drawn them — and this time for every
            // call, because nothing is waiting on this thread.
            let dispStart = max(0, onsetSample - dispSpanSamples)
            let dispCount = min(dispSpanSamples * 3, totalSamples - dispStart)
            let dispPCM = dispCount > 0
                ? WavPCMReader.readSamples(wavURL: wavURL, startSample: dispStart, count: dispCount)
                : nil
            let rendered = dispPCM.flatMap {
                PulseImageRenderer.render(pcm: $0,
                                          sampleRate: sampleRate,
                                          noiseFloor: noiseFloor,
                                          minFrequencyHz: minFrequencyHz,
                                          displaySpanSeconds: displaySpanSeconds,
                                          onsetFraction: spec.onsetFraction,
                                          expectedOnsetSample: onsetSample - dispStart,
                                          makeImage: true)
            }

            analysed.append(Pulse(
                id: pulse.id,
                number: index + 1,
                offsetSeconds: offset,
                image: (rendered?.cleanImage ?? rendered?.image),
                imageFreqMinHz: rendered?.cleanFreqMinHz,
                imageFreqMaxHz: rendered?.cleanFreqMaxHz,
                imageSpanMs: rendered?.cleanSpanMs,
                peakFreqHz: rendered?.peakFreq ?? 0,
                durationMs: rendered?.durationMs ?? 0,
                raw: descending(classification.rawScores),
                adjusted: descending(classification.allScores)))
        }

        guard !analysed.isEmpty else { return nil }

        return Result(pulses: analysed,
                      modelID: modelID,
                      modelName: "\(descriptor.displayName) \(descriptor.version)",
                      meanRaw: mean(analysed.map(\.raw)),
                      meanAdjusted: mean(analysed.map(\.adjusted)),
                      priors: priors,
                      priorsAreFromSession: input.priorsAreFromSession,
                      priorsTakenAt: input.priorsTakenAt,
                      locationWeightingApplied: input.locationWeightingApplied,
                      storedSpecies: recording.species,
                      skipped: skipped)
    }

    /// Scores as a descending list, dropping the structural zeros — a model's
    /// class list is the union of everything it can name and most of it is 0
    /// for any given call.
    private static func descending(_ scores: [String: Float]) -> [ScoreEntry] {
        scores.filter { $0.value > 0.0005 }
            .sorted { $0.value > $1.value }
            .map { ScoreEntry(species: $0.key, score: $0.value) }
    }

    /// Mean score per species across pulses — the same shape of arithmetic a
    /// pass uses to turn several calls into one name.
    private static func mean(_ vectors: [[ScoreEntry]]) -> [ScoreEntry] {
        guard !vectors.isEmpty else { return [] }
        var totals: [String: Float] = [:]
        for vector in vectors {
            for entry in vector { totals[entry.species, default: 0] += entry.score }
        }
        let n = Float(vectors.count)
        return totals.map { ScoreEntry(species: $0.key, score: $0.value / n) }
            .sorted { $0.score > $1.score }
    }
}
