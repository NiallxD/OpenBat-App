//
//  SpeciesProfileSheet.swift
//  OpenBat
//
//  The field-guide species page, presented modally instead of pushed. Lets a
//  live detection (the SPECIES cell in the stats strip) open the profile for
//  what was just identified without leaving the Detector — switching sections
//  mid-session to look a species up would mean losing sight of the spectrogram
//  exactly when something is flying.
//

import SwiftUI

struct SpeciesProfileSheet: View {
    let species: GuideSpecies
    let store: SpeciesGuideStore
    let rangeStore: SpeciesRangeStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Its own NavigationStack: SpeciesDetailView sets a navigation title and
        // is otherwise a leaf (no NavigationLinks of its own), so nothing here
        // can push — the stack is purely to give it a bar to put the title and
        // the Done button in.
        NavigationStack {
            SpeciesDetailView(species: species, store: store, rangeStore: rangeStore)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
