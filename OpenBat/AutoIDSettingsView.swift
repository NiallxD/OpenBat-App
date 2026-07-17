//
//  AutoIDSettingsView.swift
//  OpenBat
//
//  AutoID tab of SettingsView. Lists the available classifier models with a
//  single-select activation control; tapping a model pushes ModelDetailView,
//  where its species, priors, and detection thresholds are configured.
//  Only one model classifies at a time (AutoIDSettings.activeModelID).
//

import SwiftUI

struct AutoIDSettingsView: View {
    @Bindable var settings: AutoIDSettings
    @Bindable var location: LocationProvider

    var body: some View {
        Form {
            locationSuggestionSection

            Section {
                ForEach(ModelRegistry.all) { model in
                    modelRow(model)
                }
            } header: {
                Text("Models")
            } footer: {
                Text("One model classifies at a time. Tap the circle to make a model active "
                   + "(turning off any other); tap the row to configure its species, priors, "
                   + "and detection thresholds.")
            }
        }
        .onAppear { location.requestRegionFix() }
    }

    /// Suggests activating a model that covers the user's current location, or notes
    /// that none does yet. Silent (no section at all) until a fix comes back or the
    /// user has denied location — there's nothing useful to say either way.
    @ViewBuilder
    private var locationSuggestionSection: some View {
        if let coordinate = location.currentCoordinate {
            let suggested = ModelRegistry.suggestedModel(for: coordinate)
            if let suggested, settings.activeModelID != suggested.id {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(suggested.displayName) covers your area").font(.subheadline)
                            Text(suggested.region)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Use") { settings.activeModelID = suggested.id }
                            .buttonStyle(.borderedProminent)
                    }
                } header: {
                    Text("Suggested for your location")
                }
            } else if suggested == nil {
                Section {
                    Text("No AutoID model currently covers your location. "
                       + "You can still activate any model below manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Suggested for your location")
                }
            }
        }
    }

    private func modelRow(_ model: ModelDescriptor) -> some View {
        let isActive = settings.activeModelID == model.id
        return HStack(spacing: 12) {
            // Leading radio: single-select activation. Tapping the active one turns it off.
            Button {
                settings.activeModelID = isActive ? nil : model.id
            } label: {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isActive ? "Active model" : "Activate \(model.displayName)")

            NavigationLink {
                ModelDetailView(settings: settings, model: model)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName).font(.headline)
                    Text("\(model.region) · \(model.classNames.count) classes · v\(model.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
