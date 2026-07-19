//
//  LocationChangeSummaryView.swift
//  OpenBat
//
//  One-time sheet shown when a location move far enough to matter (see
//  AutoIDSettings.refreshPriorsFromGBIFIfNeeded) changed something the user
//  should know about: a different model now covers the area, and/or the
//  active model's species priors shifted. Presented from ContentView, driven
//  by AutoIDSettings.pendingChangeSummary.
//

import SwiftUI

struct LocationChangeSummaryView: View {
    @Bindable var settings: AutoIDSettings
    let summary: AutoIDSettings.PriorRefreshSummary

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let model = summary.recommendedModel {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(model.displayName) covers your new area").font(.subheadline)
                                Text(model.region)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Use") {
                                settings.activeModelID = model.id
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } header: {
                        Text("Suggested model")
                    }
                }

                if !summary.newlyEnabledSpecies.isEmpty {
                    Section {
                        ForEach(summary.newlyEnabledSpecies, id: \.self) { code in
                            Text(SpeciesInfo.commonName[code] ?? code)
                        }
                    } header: {
                        Text("Newly likely nearby")
                    } footer: {
                        Text("Enabled based on GBIF occurrence records near your new location.")
                    }
                }

                if !summary.newlyDisabledSpecies.isEmpty {
                    Section {
                        ForEach(summary.newlyDisabledSpecies, id: \.self) { code in
                            Text(SpeciesInfo.commonName[code] ?? code)
                        }
                    } header: {
                        Text("No longer suggested")
                    } footer: {
                        Text("No nearby GBIF occurrence records at your new location. "
                           + "You can re-enable any of these manually in AutoID settings.")
                    }
                }
            }
            .navigationTitle("Location changed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
