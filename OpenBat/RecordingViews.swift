//
//  RecordingViews.swift
//  OpenBat
//
//  UI for `Recording` — the WAV-backed unit AudioRecorder's bout-based trigger
//  produces (see CLAUDE.md's recording-subsystem notes). Shown two places:
//    • the Listening tab's list (SessionsView.listeningContent)
//    • a session's recordings list (SessionsView.SessionDetailView)
//  Both open the same RecordingDetailView — a whole-file spectrogram plus the
//  finer-grained per-pulse IDs (PassRecord/PulseRecord, PulseDetector's own
//  "one run of pulses" grouping) that happened during the recording's time span.
//

import SwiftUI

// MARK: - Row

struct RecordingRow: View {
    let recording: Recording
    let store: ClassificationStore

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(recording.species).font(.headline)
                    Text("·").foregroundStyle(.secondary)
                    Text(recording.commonName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if recording.isNoID {
                    Text("Triggered, but couldn't be classified")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text("\(Self.durationString(recording.durationSeconds)) · \(recording.pulseCount) pulse\(recording.pulseCount == 1 ? "" : "s") · \(Self.time(recording.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let confidence = recording.confidence {
                ConfidenceBadge(confidence: confidence)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var thumbnail: some View {
        if let img = store.spectrogramImage(for: recording) {
            Image(uiImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 56, height: 40)
                .overlay { Image(systemName: "waveform").font(.caption2).foregroundStyle(.secondary) }
        }
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .medium; return f.string(from: d)
    }

    static func durationString(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s < 60 ? "\(s)s" : String(format: "%dm %02ds", s / 60, s % 60)
    }
}

// MARK: - Detail

struct RecordingDetailView: View {
    let recording: Recording
    @Bindable var store: ClassificationStore
    /// Shared with SessionsView/PlaybackListView via the same UserDefaults key.
    @AppStorage("display.showNoID") private var showNoID = false

    /// Every pass whose pulses fall inside this recording's time span — the
    /// per-pulse ID detail, same rows/detail screen the rest of the app uses.
    /// Filtered the same way the Recording lists are: a sub-pass within an
    /// otherwise-real recording can itself be NoID (e.g. one clean approach plus
    /// one ambiguous one nearby).
    private var recordingPasses: [PassRecord] {
        store.passes(forRecording: recording).filteredByNoID(showNoID: showNoID)
    }

    var body: some View {
        List {
            Section("Spectrogram") {
                spectrogramSection
                    .listRowInsets(EdgeInsets())
            }

            Section {
                LabeledContent("Species") { Text("\(recording.species) · \(recording.commonName)") }
                if let confidence = recording.confidence {
                    LabeledContent("Confidence") {
                        Text(String(format: "%.0f%%", confidence * 100))
                    }
                }
                LabeledContent("Duration") { Text(Self.durationString(recording.durationSeconds)) }
                LabeledContent("Recorded") { Text(Self.fullTimestamp(recording.date)) }
            }

            Section("Pulses & IDs") {
                if recordingPasses.isEmpty {
                    Text(store.passes(forRecording: recording).isEmpty
                         ? "No classified pulses in this recording."
                         : "Every pulse here is unclassified (NoID) — tap the filter icon to show them.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recordingPasses) { pass in
                        NavigationLink {
                            PassDetailView(pass: pass, store: store)
                        } label: {
                            PassRow(pass: pass, store: store)
                        }
                    }
                }
            }
        }
        .navigationTitle(recording.commonName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $showNoID) {
                    Image(systemName: showNoID ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .toggleStyle(.button)
                .accessibilityLabel(showNoID ? "Hide unclassified pulses" : "Show unclassified pulses")
            }
        }
    }

    @ViewBuilder private var spectrogramSection: some View {
        if let img = store.spectrogramImage(for: recording) {
            // Fixed display height, native aspect ratio — a long bout renders a wide
            // image, so it scrolls horizontally rather than being squashed to fit.
            let aspect = img.size.width / max(img.size.height, 1)
            ScrollView(.horizontal, showsIndicators: true) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 180 * aspect, height: 180)
            }
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(height: 120)
                .overlay {
                    Text("Spectrogram unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
        }
    }

    static func durationString(_ seconds: Double) -> String { RecordingRow.durationString(seconds) }

    private static func fullTimestamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium
        return f.string(from: d)
    }
}

// MARK: - Session species summary

/// Bar-chart summary of every species ID'd in a session — same `ScoreBar` visual
/// language as a single pulse's candidate scores, but counting DETECTIONS (passes)
/// across the whole outing instead of one pulse's per-species confidence. NOISE and
/// NOID passes are excluded (they're not species IDs).
struct SessionSpeciesSummary: View {
    let passes: [PassRecord]

    private var counts: [(species: String, commonName: String, count: Int)] {
        var byspecies: [String: (commonName: String, count: Int)] = [:]
        for pass in passes where !pass.isNoise && !pass.isNoID {
            byspecies[pass.species, default: (pass.commonName, 0)].count += 1
        }
        return byspecies
            .map { (species: $0.key, commonName: $0.value.commonName, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    var body: some View {
        let rows = counts
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows, id: \.species) { row in
                    SpeciesCountBar(species: row.species, count: row.count,
                                   maxCount: rows.first?.count ?? 1)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct SpeciesCountBar: View {
    let species: String
    let count: Int
    let maxCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(species)
                .font(.system(size: 11, weight: .medium).monospaced())
                .frame(width: 46, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint)
                        .frame(width: max(3, geo.size.width * CGFloat(count) / CGFloat(max(maxCount, 1))))
                }
            }
            .frame(height: 7)
            Text("\(count)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
    }
}
