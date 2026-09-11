//
//  ClassifierAnalysisSheet.swift
//  OpenBat
//
//  What the model actually did, for one recording: every call it was given, the
//  softmax it returned, and what the location priors then did to that.
//
//  This is the "Open" in OpenBat taken literally (Niall, 2026-09-10). Every
//  other surface in the app reports a conclusion — a name, a percentage, a
//  track record. This one reports the arithmetic, including the half of it the
//  app has never written down anywhere: the model's own numbers, before any
//  weighting by where you are standing.
//
//  Read `ClassifierAnalysis` for why this is a re-run rather than a replay of
//  stored results, which priors it uses, and what it cannot show.
//

import SwiftUI

struct ClassifierAnalysisSheet: View {
    let recording: Recording
    let store: ClassificationStore
    let settings: AutoIDSettings
    @Environment(\.dismiss) private var dismiss

    @State private var result: ClassifierAnalysis.Result?
    @State private var isRunning = true

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    content(result)
                } else if isRunning {
                    ProgressView("Re-running the classifier…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Nothing to analyse",
                                           systemImage: "waveform.badge.exclamationmark",
                                           description: Text("This recording has no stored calls that can be re-run — see the recording's pulses for what was kept."))
                }
            }
            .pageBackground()
            .navigationTitle("Classifier Analysis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await analyse() }
    }

    // MARK: Content

    @ViewBuilder private func content(_ result: ClassifierAnalysis.Result) -> some View {
        List {
            Section {
                LabeledContent("Model") { Text(result.modelName) }
                LabeledContent("Calls re-run") { Text("\(result.pulses.count)") }
                if result.skipped > 0 {
                    LabeledContent("Not re-run") { Text("\(result.skipped)") }
                }
                LabeledContent("Filed as") { Text(result.storedSpecies) }
                // The headline comparison. The stored name came from the live
                // run; this one comes from the same model over the same file
                // with the same weights, so a disagreement is worth seeing
                // rather than smoothing over.
                LabeledContent("Re-run says") {
                    Text(result.meanAdjusted.first?.species ?? "—")
                        .foregroundStyle(result.meanAdjusted.first?.species == result.storedSpecies
                                         ? Color.primary : Color.orange)
                }
                Text(priorsNote(result))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("This recording")
            }

            Section {
                comparison(raw: result.meanRaw, adjusted: result.meanAdjusted)
            } header: {
                Text("Averaged over every call")
            } footer: {
                Text("Left is the model's own output. Right is after the species weights for where this was recorded, renormalised — which is what the app acts on.")
            }

            Section("Call by call") {
                ForEach(result.pulses) { pulse in
                    pulseRow(pulse)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private func pulseRow(_ pulse: ClassifierAnalysis.Pulse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Pulse \(pulse.number)").font(.headline)
                Text(String(format: "%.2f s", pulse.offsetSeconds))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if pulse.priorChangedTheAnswer {
                    // The one fact this screen exists to make visible.
                    Text("\(pulse.rawWinner) → \(pulse.adjustedWinner)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            if let image = pulse.image {
                PulseImagePlot(image: image,
                               freqMinHz: pulse.imageFreqMinHz,
                               freqMaxHz: pulse.imageFreqMaxHz,
                               spanMs: pulse.imageSpanMs)
            }

            HStack(spacing: 14) {
                stat("Fpeak", String(format: "%.0f kHz", pulse.peakFreqHz / 1000))
                stat("Dur", String(format: "%.0f ms", pulse.durationMs))
            }

            comparison(raw: pulse.raw, adjusted: pulse.adjusted)
        }
        .padding(.vertical, 4)
    }

    /// Raw beside adjusted, same species order on each side so the eye can
    /// travel across a row rather than hunt for a code on the other list.
    @ViewBuilder private func comparison(raw: [ScoreEntry], adjusted: [ScoreEntry]) -> some View {
        let adjustedByCode = Dictionary(uniqueKeysWithValues: adjusted.map { ($0.species, $0.score) })
        // Ordered by what the app acts on, with anything the model rated highly
        // pulled in behind it — a species the priors flattened to nothing is
        // exactly what somebody reading this wants to see.
        let codes = orderedCodes(raw: raw, adjusted: adjusted)
        VStack(spacing: 4) {
            HStack {
                Text("Model").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("After weighting").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            ForEach(codes, id: \.self) { code in
                HStack(spacing: 10) {
                    ScoreBar(species: code, score: raw.first { $0.species == code }?.score ?? 0)
                    ScoreBar(species: code, score: adjustedByCode[code] ?? 0)
                }
            }
        }
    }

    private func orderedCodes(raw: [ScoreEntry], adjusted: [ScoreEntry]) -> [String] {
        var codes = adjusted.prefix(4).map(\.species)
        for entry in raw.prefix(4) where !codes.contains(entry.species) {
            codes.append(entry.species)
        }
        return codes
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit())
        }
    }

    private func priorsNote(_ result: ClassifierAnalysis.Result) -> String {
        guard result.locationWeightingApplied else {
            return "No location weighting was applied to this session, so both columns are the model's own output."
        }
        if result.priorsAreFromSession, let takenAt = result.priorsTakenAt {
            return "Weighted with the species priors this session recorded at "
                + takenAt.formatted(date: .abbreviated, time: .shortened)
                + " — the ones that produced the identification, not today's."
        }
        return "This recording carries no stored priors, so the weights are the ones in force now. They may not be the ones that produced the identification."
    }

    // MARK: Running it

    private func analyse() async {
        guard result == nil else { return }
        guard let input = makeInput() else {
            isRunning = false
            return
        }
        // One capture. See `ClassifierAnalysis.Input` for why that matters here
        // rather than being a matter of taste.
        let outcome = await Task.detached(priority: .userInitiated) {
            ClassifierAnalysis.run(input)
        }.value
        result = outcome
        isRunning = false
    }

    /// Gathers everything the re-run needs while still on the main actor.
    private func makeInput() -> ClassifierAnalysis.Input? {
        let pulses = store.passes(forRecording: recording)
            .flatMap(\.pulses)
            .sorted { $0.date < $1.date }
            .map { ClassifierAnalysis.PulseTime(id: $0.id, date: $0.date) }

        // The session's stamped priors when there are any — see
        // `ClassifierAnalysis`'s header on which weights a re-run should use.
        let session = recording.sessionID.flatMap { id in
            store.sessions.first { $0.id == id }
        }
        let snapshots = session?.priorSnapshots ?? []
        let snapshot = snapshots.filter { $0.takenAt <= recording.date }
            .max(by: { $0.takenAt < $1.takenAt }) ?? snapshots.first

        guard let modelID = snapshot?.modelID ?? settings.effectiveModelID,
              let descriptor = ModelRegistry.descriptor(id: modelID) else { return nil }

        let priors: [String: Float] = snapshot?.priors
            ?? descriptor.classNames.reduce(into: [:]) { $0[$1] = settings.effectivePrior(for: $1) }

        let defaults = UserDefaults.standard
        let noiseFloor = defaults.object(forKey: "pulse.pulseNoiseFloor") as? Double ?? 0.35
        let minFrequency = defaults.object(forKey: "pulse.minFrequencyHz") as? Double
            ?? Tunable.pulseMinFrequencyHz.value(15_000.0)
        let windowMs = defaults.object(forKey: "pulse.displayWindowMs") as? Double
            ?? Tunable.pulseDisplayWindowMs.value(10.0)

        return ClassifierAnalysis.Input(
            recording: recording,
            wavURL: store.wavURL(for: recording),
            pulses: pulses,
            modelID: modelID,
            priors: priors,
            priorsAreFromSession: snapshot != nil,
            priorsTakenAt: snapshot?.takenAt,
            locationWeightingApplied: snapshot?.locationWeightingApplied ?? true,
            qualityGate: settings.qualityGate,
            noiseFloor: Float(noiseFloor),
            minFrequencyHz: minFrequency,
            displaySpanSeconds: windowMs / 1000)
    }
}
