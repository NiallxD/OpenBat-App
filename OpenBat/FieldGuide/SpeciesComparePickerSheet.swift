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
    /// The row that was tapped, so it can show as chosen while the sheet is on
    /// its way out. A tap here starts a dismissal and then a comparison, and
    /// until this existed the row it started from looked exactly like the rows
    /// it didn't — a quarter-second of a screen that had apparently ignored you
    /// (Niall, 2026-09-02). A tick, not an outline, because these are rows: the
    /// same split the collection page makes.
    @State private var picked: GuideSpecies?
    /// Whether the search field is ACTIVE, not merely present — and the reason
    /// this is bound at all rather than left to `.searchable`'s own default.
    ///
    /// This is the only `.searchable` in the app; every other search in the
    /// guide is a hand-built field with a `FocusState` (see
    /// `SpeciesExplorerView`). `.searchable` brings a `UISearchController`
    /// into the window with it, and a search controller that is still active
    /// when its sheet is torn out from under it leaves its own dimming view
    /// behind: the app looks completely right and answers no touch at all.
    /// Standing it down through the binding first is what stops that — see
    /// `handOff`.
    @State private var searchActive = false

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
                        rows(matches)
                    }
                } else {
                    if !relatives.isEmpty {
                        TileSectionHeading(title: relativesHeading, detail: relativesDetail)
                        rows(relatives)
                    }
                    TileSectionHeading(title: relatives.isEmpty ? "Species" : "Everything else")
                    rows(everythingElse)
                }
            }
            // The same glass tiles, gutters and headings a region's species list
            // is built from — see `TileList`. This sheet is the third place the
            // guide lists species, and it used plain grouped sections while the
            // other two had been rebuilt around tiles (Niall, 2026-09-02).
            .listStyle(.plain)
            .pageBackground()
            .listRowSpacing(0)
            .contentMargins(.top, TileList.scrollTopMargin, for: .scrollContent)
            .searchable(text: $query, isPresented: $searchActive, prompt: "Search species")
            .navigationTitle("Compare with")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// The family heading, in the same "common name (Latin)" shape the region
    /// lists use — the picker was showing the bare family name where they show
    /// "Vesper bats".
    private var relativesHeading: String {
        guard let family = base.family else { return "Same family" }
        return GuideFamily.commonName(for: family) ?? family
    }

    private var relativesDetail: String? {
        guard let family = base.family, GuideFamily.commonName(for: family) != nil else { return nil }
        return family
    }

    /// Hands the pick back, having first stood the search controller down.
    ///
    /// The caller closes this sheet the moment it hears the pick, and on iPad
    /// closes it out from under a live species page. An ACTIVE `.searchable`
    /// does not survive that: its search controller is left holding a dimming
    /// view over the window, and every touch afterwards lands on nothing
    /// (Niall, 2026-09-02).
    ///
    /// Both changes go out in the same update deliberately — the search
    /// controller stands down before the dismissal it would otherwise be
    /// interrupted by, and the hand-off still gets the host's own 350 ms wait
    /// on the other side of it (see `ContentView.sectionScreen`). No second
    /// delay here.
    private func handOff(_ chosen: GuideSpecies) {
        if searchActive {
            searchActive = false
            query = ""
        }
        onPick(chosen)
    }

    private func rows(_ species: [GuideSpecies]) -> some View {
        ForEach(species) { other in
            Button {
                // Set before the hand-off, and deliberately not animated away:
                // the sheet is leaving, and a tick that fades back out on the
                // way would read as the pick being undone.
                picked = other
                handOff(other)
            } label: {
                HStack(spacing: 10) {
                    GuideSpeciesRow(species: other, fullBleedThumbnail: true)
                    Image(systemName: picked == other
                          ? "checkmark.circle.fill" : "arrow.trianglehead.branch")
                        .foregroundStyle(Color.batAccent)
                        .contentTransition(.symbolEffect(.replace))
                }
                .padding(.trailing, 12)
                .contentShape(Rectangle())
                .glassTile()
            }
            // A row that opens a comparison rather than a page — the compare
            // glyph on the right says so, and `.plain` keeps the row looking
            // like the species rows everywhere else instead of tinting the
            // whole thing accent-blue.
            .buttonStyle(.plain)
            .tileRow()
        }
    }
}
