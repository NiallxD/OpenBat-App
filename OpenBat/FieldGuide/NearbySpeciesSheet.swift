//
//  NearbySpeciesSheet.swift
//  OpenBat
//
//  A quick "what's plausible around here" list, reachable from the Detector's
//  nav bar without switching to the field guide tab. Reuses the same presence
//  join `SpeciesExplorerView.nearbySpecies` does, and the same page the guide's
//  own "bats near you" push shows — see `SpeciesCollectionView`.
//
//  Only the sheet wrapper lives here: the resolved species set, the two
//  layouts and the layout toggle are all `SpeciesCollectionView`'s, so this
//  page and the guide's cannot drift apart.
//

import SwiftUI
import MapKit

struct NearbySpeciesSheet: View {
    let guide: SpeciesGuideStore
    let presenceStore: SpeciesPresenceStore
    let coordinate: CLLocationCoordinate2D?

    @Environment(\.dismiss) private var dismiss

    /// Species whose range covers `coordinate`. Joined by
    /// `GuideSpecies.presenceCode` because the grid is keyed by code and the
    /// guide only knows scientific names — the same join, for the same reason,
    /// as `SpeciesExplorerView.nearbySpecies`.
    private var nearbySpecies: [GuideSpecies] {
        guard let coordinate else { return [] }
        return guide.guide.species.filter { species in
            if case .present = presenceStore.presence(forCode: species.presenceCode,
                                                     at: coordinate) { return true }
            return false
        }
    }

    /// Two different empty states, because they need two different answers: no
    /// location fix yet is a "wait a moment", no matching presence data is a
    /// "there is nothing to wait for".
    private var emptyDescription: Text {
        coordinate == nil
            ? Text("Bats near you will show up here once your location is available.")
            : Text("Nothing in the field guide is known to be present at your location.")
    }

    var body: some View {
        NavigationStack {
            SpeciesCollectionView(title: "Bats Near You",
                                  species: nearbySpecies,
                                  countSuffix: "near you",
                                  emptyStateDescription: emptyDescription)
                // No comparing from the Detector's quick list. It answers one
                // question — what might be flying here tonight — and a
                // comparison launched from inside a sheet has nowhere sensible
                // to go back to, since the page it would replace is the sheet's
                // own root (Niall, 2026-08-27).
                .environment(\.speciesCompareMode, .unavailable)
                .navigationDestination(for: SpeciesGuideDestination.self) { destination in
                    switch destination {
                    case .species(let species):
                        SpeciesDetailView(species: species, store: guide, presenceStore: presenceStore)
                    // None of these are reachable from this sheet. The globe's
                    // own destinations have nothing to push them — one
                    // already-resolved list, no region pins, no near-you pill —
                    // and comparison is deliberately not offered here at all
                    // (see the `.unavailable` below).
                    case .region, .nearby, .compare:
                        EmptyView()
                    }
                }
                .toolbar {
                    // Leading, not the usual trailing `confirmationAction`: the
                    // page underneath owns the trailing side — compare, and the
                    // layout toggle — and a Done sharing that corner reads as a
                    // third control of the collection rather than the way out of
                    // the sheet (Niall, 2026-08-26).
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
