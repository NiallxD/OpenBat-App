//
//  SpeciesComparePickerSheet.swift
//  OpenBat
//
//  "Compare this bat with…" — the second way into a comparison, from the
//  compare button on a species page. The other way is arming compare mode on a
//  collection and tapping two species (`SpeciesCollectionView`); this one
//  starts from a species you are already reading.
//
//  A sheet rather than a jump back to the list you came from. A species page is
//  reached from at least four places — the globe's search results, a region's
//  collection, Bats Near You, and the Detector's own species sheet — and "back"
//  means something different in each, or nothing at all. A picker of its own
//  also lets you compare against any bat in the guide rather than only the ones
//  in whichever list you happened to arrive through.
//
//  Picking hands the species back and closes — the comparison itself opens over
//  the species page, not inside this sheet. Two full species pages nested in a
//  sheet's own navigation stack read as a preview of a comparison rather than
//  the thing itself, and the screen is the one part of this feature that cannot
//  afford to give away height (Niall, 2026-08-26).
//

import SwiftUI

struct SpeciesComparePickerSheet: View {
    /// The species whose page this was opened from — the left/top half of
    /// whatever comparison comes out of it.
    let base: GuideSpecies
    let store: SpeciesGuideStore
    let presenceStore: SpeciesPresenceStore

    /// Called with the chosen species. The caller closes this sheet and opens
    /// the comparison itself — see the note at the top.
    let onPick: (GuideSpecies) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    /// Everything except the bat you are already looking at.
    private var candidates: [GuideSpecies] {
        store.guide.species.filter { $0.id != base.id }
    }

    /// Same family first, and this is the whole reason the picker is grouped
    /// rather than one long list: the species you want to compare against is
    /// almost always a close relative you can't tell apart, and in an
    /// alphabetical list of the entire guide it is nowhere near the top.
    private var relatives: [GuideSpecies] {
        guard let family = base.family else { return [] }
        return candidates.filter { $0.family == family }
            .sorted { $0.commonName < $1.commonName }
    }

    private var everythingElse: [GuideSpecies] {
        let relativeIDs = Set(relatives.map(\.id))
        return candidates.filter { !relativeIDs.contains($0.id) }
            .sorted { $0.commonName < $1.commonName }
    }

    /// Same fuzzy match the globe's search bar uses, so a name typed here
    /// behaves the way it does everywhere else in the guide.
    private var matches: [GuideSpecies] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return candidates
            .compactMap { s in s.searchScore(for: trimmed).map { (s, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    if matches.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        Section { rows(matches) }
                    }
                } else {
                    if !relatives.isEmpty {
                        Section(base.family ?? "Same family") { rows(relatives) }
                    }
                    Section(relatives.isEmpty ? "Species" : "Everything else") {
                        rows(everythingElse)
                    }
                }
            }
            .searchable(text: $query, prompt: "Search species")
            .navigationTitle("Compare with")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func rows(_ species: [GuideSpecies]) -> some View {
        ForEach(species) { other in
            Button {
                onPick(other)
            } label: {
                HStack {
                    GuideSpeciesRow(species: other)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down.square")
                        .foregroundStyle(Color.batAccent)
                }
                .contentShape(Rectangle())
            }
            // A row that opens a comparison rather than a page — the compare
            // glyph on the right says so, and `.plain` keeps the row looking
            // like the species rows everywhere else instead of tinting the
            // whole thing accent-blue.
            .buttonStyle(.plain)
        }
    }
}
