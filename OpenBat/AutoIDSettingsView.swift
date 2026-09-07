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
    /// Handed in by `SettingsView`, which holds it already, rather than read
    /// from the environment. A non-optional `@Environment(FeatureFlagStore.self)`
    /// traps the moment it is read if no ancestor provided one, which is a hard
    /// crash on the way into a tab rather than a missing switch — and this tab
    /// now reads it before it draws anything at all.
    let flags: FeatureFlagStore
    @Bindable var settings: AutoIDSettings
    @Bindable var location: LocationProvider

    var body: some View {
        // **The whole tab, or none of it** (Niall, 2026-09-06). This screen
        // used to say identification was off in a section at the top and leave
        // the model list, the location suggestion and the map-pin gates live
        // underneath, on the reasoning that a model picked while the switch was
        // down would be waiting when it came back. That was a screenful of
        // live controls for a feature that is not running, and opening it while
        // the switch was down crashed the app. Off, this tab is one sentence and
        // a link: none of the model list, the location fix it asks for, or the
        // map-pin gates is built at all.
        if !flags.isEnabled(.automaticID) {
            disabledNotice
        } else {
            settingsForm
        }
    }

    /// What the tab is while identification is switched off remotely.
    ///
    /// It names the OpenBat team rather than hiding behind the passive voice,
    /// because somebody whose app has quietly stopped identifying anything is
    /// owed both the fact that a person decided it and somewhere to read why.
    /// The reason itself is deliberately NOT here: this ships in a binary, and
    /// the switch exists precisely for the situations a release cannot answer
    /// in time. The blog can be written the same afternoon.
    private var disabledNotice: some View {
        ContentUnavailableView {
            Label("AutoID is off", systemImage: "waveform.badge.exclamationmark")
        } description: {
            Text("AutoID has been disabled by the OpenBat team. Check our blog for more info.")
        } actions: {
            Link("Read the blog", destination: Self.blogURL)
                .buttonStyle(.borderedProminent)
        }
    }

    private static let blogURL = URL(string: "https://openbat.app/blog")!

    private var settingsForm: some View {
        Form {
            locationUnavailableSection
            locationSuggestionSection

            Section {
                ForEach(ModelRegistry.all) { model in
                    modelRow(model)
                }
            } header: {
                // "One model at a time" is the card's whole rule, and it is what
                // the single-select circles already show. Where each tap goes —
                // circle to switch, name for the species list — is learned in one
                // tap and doesn't earn a paragraph. See `SettingsView`'s header
                // for the three-part shape every settings card now follows.
                CardHeader("Models", "Which species OpenBat tries to recognise.")
            }

            // Moved here from General (2026-08-18). It lived under a "Location"
            // header there, which described where the setting came from rather
            // than what it decides — these two numbers gate which identifications
            // are good enough to become a pin, so they belong beside the thing
            // making the identifications.
            Section {
                // Both notes sit ABOVE their control, which is where a control's
                // description belongs — they were below, which made them read as
                // an afterthought about the thing you had already moved.
                VStack(alignment: .leading) {
                    HStack {
                        Text("Minimum confidence")
                        Spacer()
                        Text("\(Int(settings.mapPinMinConfidence * 100))%").monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ControlNote("How certain the identification has to be.")
                    Slider(value: Binding(get: { Double(settings.mapPinMinConfidence) },
                                          set: { settings.mapPinMinConfidence = Float($0) }),
                           in: 0.3...0.95, step: 0.05)
                }
                ControlNote("So one chance detection isn't a pin.")
                Stepper("Minimum calls: \(settings.mapPinMinPulseCount)",
                        value: $settings.mapPinMinPulseCount, in: 1...20)
            } header: {
                CardHeader("Map pins", "Which identifications end up on the map.")
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
