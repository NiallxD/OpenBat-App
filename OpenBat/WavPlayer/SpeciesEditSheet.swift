//
//  SpeciesEditSheet.swift
//  OpenBat
//
//  Lets the user correct the species assigned to a recording, from the pencil
//  button on WavFileInfoCard's GUANO Metadata card. Same bottom-sheet chrome
//  (centered header, drag indicator, rounded presentation) as ContentView's
//  StartDetectingSheet/SuggestedModelSheet, but with a searchable list rather
//  than a couple of big buttons — there are dozens of species to choose from,
//  pooled across every registered model (see `options`) rather than just the
//  one that produced the original auto-ID, since a manual correction may
//  legitimately name a species outside that model's class list.
//
//  "Other" covers the case the pooled list can't: a species genuinely outside
//  every registered model's coverage area (a European bat on a NABat-only
//  device, say). It swaps the list for a free-text code entry with guidance
//  on the GUANO/NABat 4-letter convention (first two letters of genus + first
//  two of species) — the same shape a manual auto-ID code already takes
//  elsewhere in the app (see SpeciesInfo.commonName's NABat entries).
//

import SwiftUI

struct SpeciesEditSheet: View {
    let currentCode: String
    let onSelect: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var showOtherEntry = false
    @State private var otherCode = ""

    private struct Option: Identifiable, Hashable {
        let code: String
        let commonName: String
        var id: String { code }
    }

    /// Every named taxon across every registered model, de-duplicated by code
    /// and sorted by common name — pooling across models (rather than just
    /// the one that classified this file) means a correction can name a
    /// species the auto-classifier doesn't even offer.
    private var options: [Option] {
        var seen = Set<String>()
        var out: [Option] = []
        for model in ModelRegistry.all {
            for code in model.classNames where code != model.noiseClassName {
                guard seen.insert(code).inserted else { continue }
                out.append(Option(code: code, commonName: SpeciesInfo.commonName[code] ?? code))
            }
        }
        return out.sorted { $0.commonName < $1.commonName }
    }

    private var filtered: [Option] {
        guard !query.isEmpty else { return options }
        let q = query.lowercased()
        return options.filter { $0.commonName.lowercased().contains(q) || $0.code.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showOtherEntry {
                otherEntryForm
            } else {
                searchField
                list
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("Edit Species")
                .font(.title2.weight(.semibold))
            Text(showOtherEntry
                 ? "Enter a species code by hand — for a species outside every installed model's coverage."
                 : "Corrects the ID stored with this recording and its GUANO metadata.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search species", text: $query)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var list: some View {
        List {
            Button {
                onSelect(nil)
                dismiss()
            } label: {
                HStack {
                    Text("No ID")
                    Spacer()
                    if currentCode == "NOID" {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
            }
            .buttonStyle(.plain)

            ForEach(filtered) { option in
                Button {
                    onSelect(option.code)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.commonName)
                            Text(option.code)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if currentCode == option.code {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Button {
                otherCode = ""
                showOtherEntry = true
            } label: {
                HStack {
                    Text("Other…")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
    }

    /// Free-text code entry for a species not in `options` — e.g. one outside
    /// every installed model's region. Explains the GUANO/NABat 4-letter
    /// convention rather than just presenting a blank field, since there's no
    /// picker to lean on here.
    private var otherEntryForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            innerOtherEntryContent
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
    }

    private var innerOtherEntryContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Species codes are normally 4 letters: the first two letters of the "
               + "genus plus the first two of the species, from the scientific name. "
               + "\u{201c}Eptesicus fuscus\u{201d} (Big Brown Bat) becomes EPFU.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("e.g. EPFU", text: $otherCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 12) {
                Button("Back") {
                    showOtherEntry = false
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Use This Code") {
                    let trimmed = otherCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    guard !trimmed.isEmpty else { return }
                    onSelect(trimmed)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.batAccent)
                .disabled(otherCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
