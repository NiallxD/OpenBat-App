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
            guard let code = species.presenceCode else { return false }
            if case .present = presenceStore.presence(forCode: code, at: coordinate) { return true }
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
                .navigationDestination(for: SpeciesGuideDestination.self) { destination in
                    if case .species(let species) = destination {
                        SpeciesDetailView(species: species, store: guide, presenceStore: presenceStore)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
