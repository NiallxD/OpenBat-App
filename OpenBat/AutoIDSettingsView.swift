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
            locationUnavailableSection
            locationSuggestionSection

            Section {
                ForEach(ModelRegistry.all) { model in
                    modelRow(model)
                }
            } header: {
                CardHeader("Models", "Which set of species OpenBat tries to recognise.")
            } footer: {
                Text("One model identifies at a time. Tap the circle to switch to a model; "
                   + "tap its name to see the species it knows and how sure it has to be.")
            }

            // Moved here from General (2026-08-18). It lived under a "Location"
            // header there, which described where the setting came from rather
            // than what it decides — these two numbers gate which identifications
            // are good enough to become a pin, so they belong beside the thing
            // making the identifications.
            Section {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Minimum confidence")
                        Spacer()
                        Text("\(Int(settings.mapPinMinConfidence * 100))%").monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { Double(settings.mapPinMinConfidence) },
                                          set: { settings.mapPinMinConfidence = Float($0) }),
                           in: 0.3...0.95, step: 0.05)
                }
                ControlNote("How certain the identification has to be.")
                Stepper("Minimum calls: \(settings.mapPinMinPulseCount)",
                        value: $settings.mapPinMinPulseCount, in: 1...20)
                ControlNote("How many calls it has to be based on, so a single "
                          + "chance detection doesn't become a pin.")
            } header: {
                CardHeader("Map pins", "Which of your identifications end up on the map.")
            }
        }
        .onAppear { location.requestRegionFix() }
    }

    /// Warns that AutoID species priors are neutral (every species enabled, equal
    /// weight — see `AutoIDSettings.defaultSettings`) until a location fix lets GBIF
    /// refine them. Shown for both "denied/restricted" (permanent until the user
    /// changes it in Settings) and "not yet determined/no fix yet" (transient), since
    /// either way the user is currently getting unfiltered results.
    @ViewBuilder
    private var locationUnavailableSection: some View {
        if location.currentCoordinate == nil {
            Section {
                Label {
                    Text("Location isn't available, so species priors haven't been "
                       + "narrowed to your area — AutoID may be less accurate than "
                       + "with location enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "location.slash")
                        .foregroundStyle(.secondary)
                }
            }
        }
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
                    HStack(spacing: 6) {
                        Text(model.displayName).font(.headline)
                        if model.isBeta { BetaBadge() }
                    }
                    Text("\(model.region) · \(model.classNames.count) classes · v\(model.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
