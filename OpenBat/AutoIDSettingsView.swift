//
//  AutoIDSettingsView.swift
//  OpenBat
//
//  AutoID tab of SettingsView. Lists the available classifier models and shows
//  which one is identifying; tapping a model pushes ModelDetailView, where its
//  species, priors, and detection thresholds are configured.
//
//  **The activation control is gone** (Niall, 2026-09-08). Which model runs is
//  decided by where the phone is — `AutoIDSettings.applyCoverage` — so the
//  radio buttons that used to be here, and the "Suggested for your location"
//  card with its Use button, were offering a choice the next location fix would
//  have overridden anyway. What is left states the answer and why.
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
            noCoverageSection

            if !modelsInRange.isEmpty {
                Section {
                    ForEach(modelsInRange) { model in
                        modelRow(model)
                    }
                } header: {
                    // The subtitle carries the rule now that nothing on the card is
                    // tappable except the model names: one model runs, and where you
                    // are is what picks it. See `SettingsView`'s header for the
                    // three-part shape every settings card now follows.
                    CardHeader("Models", "Chosen for you from where you are.")
                }
            }

            // Moved here from General (2026-08-18). It lived under a "Location"
            // header there, which described where the setting came from rather
            // than what it decides — these two numbers gate which identifications
            // are good enough to become a pin, so they belong beside the thing
            // making the identifications.
            Section {
                SettingValue("Minimum confidence",
                             "How certain the identification has to be before it earns a pin. The map "
                           + "shows the best of what a session heard, so it will usually hold fewer pins "
                           + "than the session holds identifications.",
                             value: "\(Int(settings.mapPinMinConfidence * 100))%")
                Slider(value: Binding(get: { Double(settings.mapPinMinConfidence) },
                                      set: { settings.mapPinMinConfidence = Float($0) }),
                       in: 0.3...0.95, step: 0.05)

                SettingRow("Minimum calls",
                           "How many calls the pass has to hold, so one chance detection isn't a pin.") {
                    Stepper(value: $settings.mapPinMinPulseCount, in: 1...20) {
                        Text("\(settings.mapPinMinPulseCount)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    .accessibilityLabel("Minimum calls")
                }
            } header: {
                CardHeader("Map pins", "Which identifications end up on the map.")
            }
        }
        .onAppear { location.requestRegionFix() }
    }

    /// Warns that nothing is being identified yet, because with no fix there is
    /// nothing to pick a model from — and that the species priors are still neutral
    /// (every species enabled, equal weight — see `AutoIDSettings.defaultSettings`).
    ///
    /// Shown for both "denied/restricted" (permanent until the user changes it in
    /// Settings) and "not yet determined/no fix yet" (transient): either way the
    /// answer to "why is nothing being named" is the same one.
    @ViewBuilder
    private var locationUnavailableSection: some View {
        if location.currentCoordinate == nil {
            Section {
                Label {
                    Text("Location isn't available, so OpenBat can't tell which "
                       + "model suits where you are. Identification stays off, and "
                       + "species priors haven't been narrowed to your area, until "
                       + "a location fix comes through.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "location.slash")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Says so when the user is somewhere no model covers — which, now that
    /// coverage decides the model, is the same as saying identification is off.
    ///
    /// Only shown with a fix in hand. Without one the section above is already
    /// explaining the same silence, and two notices about one absence is one too
    /// many.
    @ViewBuilder
    private var noCoverageSection: some View {
        if let coordinate = location.currentCoordinate {
            if ModelRegistry.suggestedModel(for: coordinate) == nil {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            // Said plainly first (Niall, 2026-09-10). With the
                            // model list now hidden here rather than listing
                            // models that can't run, this line is the whole
                            // answer to "why is nothing being named" and it
                            // shouldn't have to be inferred from a paragraph.
                            Text("AutoID not available in your region")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Detecting and recording work as normal, and a "
                               + "model switches itself on if you travel into "
                               + "one's range.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "mappin.slash")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// The models that can actually run where the user is standing, plus whichever
    /// one is running if that somehow isn't one of them.
    ///
    /// **Listing every model the app ships was a lie about a choice.** Location
    /// picks the classifier outright, and has since 2026-09-08 — but the card went
    /// on showing all of them, each one tappable through to its own settings
    /// screen. Someone in Canada saw a European model listed beside the North
    /// American one and could open and configure it, which reads as two available
    /// options and an implied switch. There is no switch, and there never was one
    /// to find.
    private var modelsInRange: [ModelDescriptor] {
        guard let coordinate = location.currentCoordinate else { return [] }
        return ModelRegistry.all.filter { model in
            model.coverage?.contains(coordinate) ?? false || model.id == settings.activeModelID
        }
    }

    private func modelRow(_ model: ModelDescriptor) -> some View {
        let isActive = settings.activeModelID == model.id
        return HStack(spacing: 12) {
            // A statement, not a control. It reads as one too — no button shape,
            // and the inactive rows carry an empty circle rather than nothing, so
            // the active one is picked out by contrast rather than by being the
            // only row with a glyph.
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .imageScale(.large)
                .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .accessibilityLabel(isActive ? "Identifying" : "Not in range")

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
