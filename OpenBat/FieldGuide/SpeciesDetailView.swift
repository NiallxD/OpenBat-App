//
//  SpeciesDetailView.swift
//  OpenBat
//
//  The full field-guide species page: header/taxonomy breadcrumb, description,
//  GBIF distribution map, measurements & morphology, echolocation calls,
//  conservation status, and habits. Each section only renders when its
//  backing data is present — sparse guide entries just show fewer sections
//  rather than empty boxes, so the page scales gracefully as the
//  community-editable JSON (SpeciesGuideData.json) grows over time.
//

import SwiftUI

struct SpeciesDetailView: View {
    let species: GuideSpecies
    let store: SpeciesGuideStore

    @State private var showContributors = false

    var body: some View {
        List {
            headerSection
            if let summary = species.summary {
                Section("Overview") { Text(summary) }
            }
            Section("Distribution") {
                GBIFDistributionCard(species: species)
                    .listRowInsets(EdgeInsets())
            }
            measurementsSection
            echolocationSection
            conservationSection
            habitsSection
            Section("Regions") {
                ForEach(store.guide.regions.filter { species.regions.contains($0.id) }) { region in
                    Label(region.name, systemImage: "globe.europe.africa")
                }
            }
            referencesSection
        }
        .navigationTitle(species.commonName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showContributors) {
            ContributorsSheet(species: species)
        }
    }

    // MARK: References

    @ViewBuilder private var referencesSection: some View {
        if species.creator != nil || (species.references?.isEmpty == false) {
            Section("References") {
                if let creator = species.creator {
                    Button {
                        showContributors = true
                    } label: {
                        ContributorSummaryRow(creator: creator, editorCount: species.editors.count)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(Array((species.references ?? []).enumerated()), id: \.offset) { _, citation in
                    Text(citation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Header

    private var breadcrumb: String {
        [species.order, species.family, species.genus]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " › ")
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(species.commonName)
                    .font(.title2.bold())
                Text(species.scientificName)
                    .font(.headline.italic())
                    .foregroundStyle(.secondary)
                if !breadcrumb.isEmpty {
                    Text(breadcrumb)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Measurements & morphology

    @ViewBuilder private var measurementsSection: some View {
        if species.measurements != nil || species.morphology != nil {
            Section("Measurements & Morphology") {
                if let m = species.measurements {
                    if let r = m.forearmMmRange { StatRow(label: "Forearm", value: r.formatted(unit: "mm")) }
                    if let r = m.wingspanCmRange { StatRow(label: "Wingspan", value: r.formatted(unit: "cm")) }
                    if let r = m.weightGRange { StatRow(label: "Weight", value: r.formatted(unit: "g")) }
                    if let color = m.color { StatRow(label: "Colour", value: color) }
                }
                if let morph = species.morphology {
                    if let ear = morph.earType { StatRow(label: "Ears", value: ear) }
                    if let tail = morph.tailType { StatRow(label: "Tail", value: tail) }
                    if let nose = morph.noseType { StatRow(label: "Nose", value: nose) }
                    // TODO: illustrated morphology icons — see CLAUDE.md Taxonomy browser future work.
                    ForEach(morph.otherFeatures ?? [], id: \.self) { feature in
                        Label(feature, systemImage: "sparkle")
                            .font(.subheadline)
                    }
                }
            }
        }
    }

    // MARK: Echolocation

    @ViewBuilder private var echolocationSection: some View {
        if let echo = species.echolocation {
            Section("Echolocation Calls") {
                if let type = echo.callType { StatRow(label: "Call type", value: type) }
                if let r = echo.peakFreqHzRange { StatRow(label: "Peak freq (Pf)", value: r.formattedHz()) }
                if let r = echo.characteristicFreqHzRange { StatRow(label: "Characteristic freq (Cf)", value: r.formattedHz()) }
                if let r = echo.freqHighHzRange { StatRow(label: "Fhigh", value: r.formattedHz()) }
                if let r = echo.freqLowHzRange { StatRow(label: "Flow", value: r.formattedHz()) }
                if let r = echo.durationMsRange { StatRow(label: "Duration", value: r.formatted(unit: "ms")) }
                if let notes = echo.notes { Text(notes).font(.subheadline).foregroundStyle(.secondary) }
                if let imageName = echo.exemplarImageName, let uiImage = UIImage(named: imageName) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    exemplarPlaceholder
                }
            }
        }
    }

    private var exemplarPlaceholder: some View {
        Label("Exemplar call coming soon", systemImage: "waveform")
            .foregroundStyle(.secondary)
    }

    // MARK: Conservation

    @ViewBuilder private var conservationSection: some View {
        if let c = species.conservation, c.iucnStatus != nil || c.localStatus != nil {
            Section("Conservation Status") {
                if let iucn = c.iucnStatus { StatRow(label: "IUCN", value: iucn) }
                if let local = c.localStatus { StatRow(label: "Local status", value: local) }
            }
        }
    }

    // MARK: Habits

    @ViewBuilder private var habitsSection: some View {
        if let h = species.habits {
            Section("Habits") {
                if let v = h.roosting { HabitRow(title: "Roosting", text: v) }
                if let v = h.migration { HabitRow(title: "Migration", text: v) }
                if let v = h.feeding { HabitRow(title: "Feeding", text: v) }
                if let v = h.reproduction { HabitRow(title: "Reproduction", text: v) }
                if let v = h.other { HabitRow(title: "Other", text: v) }
            }
        }
    }
}

/// Labeled value row shared by the measurements/morphology/echolocation/conservation sections.
private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

/// Title + paragraph row used by the habits section.
private struct HabitRow: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Compact "Created by X · N edits" row shown at the top of the References
/// section; tapping it opens `ContributorsSheet` for the full history.
private struct ContributorSummaryRow: View {
    let creator: SpeciesContributor
    let editorCount: Int

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Created by \(creator.name)")
                    if let date = creator.parsedDate {
                        Text(date, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "person.crop.circle")
            }
            Spacer()
            if editorCount > 0 {
                Text("+\(editorCount) edit\(editorCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
    }
}

/// Full contributor history for a species page — creator plus every editor,
/// each with their date and an optional note on what they changed.
private struct ContributorsSheet: View {
    let species: GuideSpecies
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let creator = species.creator {
                    Section("Created") {
                        ContributorRow(contributor: creator)
                    }
                }
                if !species.editors.isEmpty {
                    Section("Edited") {
                        ForEach(species.editors, id: \.self) { editor in
                            ContributorRow(contributor: editor)
                        }
                    }
                }
            }
            .navigationTitle("Contributors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ContributorRow: View {
    let contributor: SpeciesContributor

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(contributor.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let date = contributor.parsedDate {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let note = contributor.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private extension MeasurementRange {
    func formatted(unit: String) -> String {
        // Defensive: a hand-edited JSON entry could have min/max swapped.
        let lo = Swift.min(min, max), hi = Swift.max(min, max)
        return lo == hi ? "\(lo.formattedTrimmed) \(unit)" : "\(lo.formattedTrimmed)–\(hi.formattedTrimmed) \(unit)"
    }

    /// Hz ranges display in kHz, matching the app's spectrogram/pulse UI conventions.
    func formattedHz() -> String {
        let kHzRange = MeasurementRange(min: min / 1000, max: max / 1000)
        return kHzRange.formatted(unit: "kHz")
    }
}

private extension Double {
    var formattedTrimmed: String {
        truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", self) : String(format: "%.1f", self)
    }
}
