//
//  SessionsView.swift
//  OpenBat
//
//  The "Sessions" tab: a chronological log of AutoID passes. Tapping a pass opens
//  its detail, revealing every contributing pulse with its own spectrogram
//  thumbnail, species and confidence — so a field ID can be traced back to the
//  evidence it was built from.
//

import SwiftUI

struct SessionsView: View {
    @Bindable var store: ClassificationStore
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if store.passes.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                if !store.passes.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) { showClearConfirm = true } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Clear all")
                    }
                }
            }
            .confirmationDialog("Delete all saved IDs?",
                                isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) { store.clearAll() }
                Button("Cancel", role: .cancel) { }
            }
        }
    }

    private var list: some View {
        List {
            ForEach(groupedPasses, id: \.key) { group in
                Section(group.title) {
                    ForEach(group.passes) { pass in
                        NavigationLink {
                            PassDetailView(pass: pass, store: store)
                        } label: {
                            PassRow(pass: pass, store: store)
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { group.passes[$0] }.forEach(store.delete)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No IDs yet",
            systemImage: "waveform.badge.magnifyingglass",
            description: Text("Detected bat passes and their species IDs will appear here.")
        )
    }

    // Group passes into day sections (newest first).
    private struct DayGroup { let key: Date; let title: String; let passes: [PassRecord] }
    private var groupedPasses: [DayGroup] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: store.passes) { cal.startOfDay(for: $0.date) }
        return dict.keys.sorted(by: >).map { day in
            DayGroup(key: day, title: Self.dayTitle(day),
                     passes: dict[day]!.sorted { $0.date > $1.date })
        }
    }

    private static func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter(); f.dateStyle = .medium
        return f.string(from: date)
    }
}

// MARK: - Pass row

private struct PassRow: View {
    let pass: PassRecord
    let store: ClassificationStore

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pass.species).font(.headline)
                    Text("·").foregroundStyle(.secondary)
                    Text(pass.commonName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("\(pass.pulseCount) pulse\(pass.pulseCount == 1 ? "" : "s") · \(Self.time(pass.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ConfidenceBadge(confidence: pass.confidence)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var thumbnail: some View {
        if let img = store.image(for: representativePulse) {
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

    private var representativePulse: PulseRecord {
        pass.pulses.max(by: { $0.confidence < $1.confidence }) ?? pass.pulses[0]
    }

    private static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .medium; return f.string(from: d)
    }
}

// MARK: - Pass detail

private struct PassDetailView: View {
    let pass: PassRecord
    let store: ClassificationStore

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(pass.species).font(.title2.bold())
                        Spacer()
                        ConfidenceBadge(confidence: pass.confidence)
                    }
                    Text(pass.commonName).foregroundStyle(.secondary)
                    Text("\(pass.pulseCount) classified pulse\(pass.pulseCount == 1 ? "" : "s") · \(Self.timestamp(pass.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Pulses") {
                ForEach(pass.pulses) { pulse in
                    PulseDetailRow(pulse: pulse, store: store)
                }
            }
        }
        .navigationTitle(pass.species)
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func timestamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium
        return f.string(from: d)
    }
}

// MARK: - Pulse detail row

private struct PulseDetailRow: View {
    let pulse: PulseRecord
    let store: ClassificationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let img = store.image(for: pulse) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 130)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .background(RoundedRectangle(cornerRadius: 8).fill(.black))
            }

            HStack {
                Text(pulse.species).font(.headline)
                Spacer()
                ConfidenceBadge(confidence: pulse.confidence)
            }

            HStack(spacing: 14) {
                stat("Fpeak", String(format: "%.0f kHz", pulse.peakFreqHz / 1000))
                stat("Dur", String(format: "%.0f ms", pulse.durationMs))
            }

            // Top alternative scores as labelled bars.
            VStack(spacing: 3) {
                ForEach(pulse.topScores.prefix(4)) { entry in
                    ScoreBar(species: entry.species, score: entry.score)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit())
        }
    }
}

// MARK: - Small components

private struct ConfidenceBadge: View {
    let confidence: Float
    var body: some View {
        Text(String(format: "%.0f%%", confidence * 100))
            .font(.caption.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }
    private var color: Color {
        switch confidence {
        case 0.6...:  return .green
        case 0.3..<0.6: return .yellow
        default:      return .orange
        }
    }
}

private struct ScoreBar: View {
    let species: String
    let score: Float
    var body: some View {
        HStack(spacing: 6) {
            Text(species)
                .font(.system(size: 10, weight: .medium).monospaced())
                .frame(width: 42, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint)
                        .frame(width: max(2, geo.size.width * CGFloat(min(max(score, 0), 1))))
                }
            }
            .frame(height: 6)
            Text(String(format: "%.0f%%", score * 100))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }
}
