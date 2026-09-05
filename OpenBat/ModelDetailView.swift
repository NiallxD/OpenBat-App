//
//  ModelDetailView.swift
//  OpenBat
//
//  Detail screen for one classifier model: what it is, the "use this model"
//  switch, and all of the model's settings — what it takes to call something an
//  ID, which calls are good enough to try, and the species list (grouped) with
//  enable switches and likelihood sliders.
//
//  **Follows `SettingsView`'s card shape, and its rules about words** (Niall,
//  2026-09-02): name, one line of description at ten words or fewer, then the
//  control — and nothing underneath it. Read that file's header before adding
//  anything here. This screen was the worst offender: bare one-word headers, no
//  description anywhere, and footers written in the vocabulary of the code
//  (timeout, min pulses, SNR, priors, "pass detection") rather than of the
//  person deciding. The labels below are the plain-English half of that fix;
//  the stored properties keep their own names.
//
//  Every control writes through `settings.perModel[model.id]` so editing a model
//  that isn't currently active still works.
//

import SwiftUI

/// Small "BETA" pill shown next to a model's name wherever it's listed
/// (`AutoIDSettingsView`'s model row, this screen's title).
struct BetaBadge: View {
    var body: some View {
        Text("BETA")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.15), in: Capsule())
    }
}

struct ModelDetailView: View {
    @Bindable var settings: AutoIDSettings
    let model: ModelDescriptor

    var body: some View {
        Form {
            metadataSection
            citationSection
            activeSection
            passSection
            // Hidden for a model that ignores the gate — see
            // `ModelDescriptor.honoursQualityGate`. The stored setting is left
            // untouched rather than forced off: it belongs to this model's own
            // settings record, and switching to a model that does honour the gate
            // must find it as the user left it.
            if model.honoursQualityGate { qualityGateSection }
            speciesSections
            resetSection
        }
        .navigationTitle(model.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.isBeta {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(model.displayName).font(.headline)
                        BetaBadge()
                    }
                }
            }
        }
    }

    // MARK: Metadata

    private var metadataSection: some View {
        Section {
            LabeledContent("Region", value: model.region)
            LabeledContent("Version", value: model.version)
            // "Classes" was ours, not the reader's — it is a count of the
            // species this model can name.
            LabeledContent("Species it knows", value: "\(model.classNames.count)")
        } header: {
            CardHeader("Model", "Where it works, and what it knows.")
        }
    }

    /// The citation is the one thing on this screen that isn't an explanation of
    /// a control, so it doesn't fall under the no-paragraph rule — it is the
    /// card's content. It was in a footer under the metadata, where it read as
    /// small print about the version number.
    private var citationSection: some View {
        Section {
            Text(model.citation)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let url = model.sourceURL {
                Link(destination: url) {
                    Label("Source repository", systemImage: "arrow.up.right.square")
                }
            }
        } header: {
            CardHeader("Credit", "Who made this model, and where.")
        }
    }

    private var activeSection: some View {
        Section {
            Toggle("Use this model", isOn: Binding(
                get: { settings.activeModelID == model.id },
                set: { settings.activeModelID = $0 ? model.id : nil }
            ))
        } header: {
            CardHeader("Identifying", "Only one model identifies at a time.")
        }
    }

    // MARK: Making an ID

    /// A value beside its label, then its note, then the full-width slider —
    /// the row shape the rest of Settings uses. The sliders here were squeezed
    /// into the trailing half of a `LabeledContent`, which left them about a
    /// thumb wide and gave the note nowhere to go.
    private var passSection: some View {
        Section {
            LabeledContent("Ends a pass after") {
                Text(String(format: "%.1f s", ms.passTimeoutSeconds))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ControlNote("Quiet this long and the bat has gone.")
            Slider(value: bind(\.passTimeoutSeconds), in: 0.5...10, step: 0.5)
                .accessibilityLabel("Ends a pass after")

            ControlNote("How many calls an ID is based on.")
            Stepper("Calls needed: \(ms.minPassPulseCount)",
                    value: bind(\.minPassPulseCount), in: 1...10)

            LabeledContent("Minimum confidence") {
                Text(String(format: "%.0f%%", ms.minPassConfidence * 100))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ControlNote("Below this, no species is named.")
            Slider(value: bind(\.minPassConfidence), in: 0...0.5, step: 0.01)
                .accessibilityLabel("Minimum confidence")
        } header: {
            CardHeader("Making an ID", "Before OpenBat will name a species.")
        }
    }

    // MARK: Call quality

    /// The old footer's one fact worth keeping is that skipping is not hiding —
    /// a skipped call is still drawn in the Pulse View, it just doesn't get a
    /// vote. That is the description. The NABat defaults it also quoted are on
    /// the two controls they belong to.
    private var qualityGateSection: some View {
        Section {
            Toggle("Skip faint calls", isOn: bind(\.qualityGateEnabled))
            if ms.qualityGateEnabled {
                LabeledContent("Minimum clarity") {
                    Text(String(format: "%.0f×", ms.qualitySNThreshold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ControlNote("How far above the noise. NABat uses 7×.")
                Slider(value: bind(\.qualitySNThreshold), in: 1...20, step: 1)
                    .accessibilityLabel("Minimum clarity")

                LabeledContent("Minimum loudness") {
                    Text(String(format: "%.0f dB", ms.qualityAmpThreshold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ControlNote("NABat uses 21 dB.")
                Slider(value: bind(\.qualityAmpThreshold), in: 5...40, step: 1)
                    .accessibilityLabel("Minimum loudness")
            }
        } header: {
            CardHeader("Call quality", "Skipped calls are shown, not identified.")
        }
    }

    // MARK: Species

    private var speciesSections: some View {
        ForEach(model.groups) { group in
            Section {
                ForEach(group.codes, id: \.self) { code in
                    SpeciesRow(
                        code: code,
                        commonName: SpeciesInfo.commonName[code] ?? code,
                        enabled: enabledBinding(for: code),
                        prior:   priorBinding(for: code),
                        resolved: settings.perModel[model.id]?.species[code]?.resolved ?? false
                    )
                }
            } header: {
                // Only the first group carries the description: it explains the
                // slider on every row below, and repeating it over each family
                // would be the wall of text this screen just lost.
                CardHeader(group.name,
                           group.id == model.groups.first?.id
                           ? "How likely each one is where you are." : "") {
                    let on = allEnabled(group.codes)
                    Button(on ? "Disable all" : "Enable all") {
                        setGroup(group.codes, enabled: !on)
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset to defaults", role: .destructive) {
                withAnimation { settings.resetModel(model.id) }
            }
        } header: {
            // That the likelihoods re-suggest themselves from occurrence data at
            // the next location fix is true, and is not a thing anyone reads a
            // settings card to find out. It survives in `AutoIDSettings`.
            CardHeader("Reset", "Every species back on, no location bias.")
        }
    }

    // MARK: Bindings

    /// Current settings for this model (descriptor defaults if somehow absent).
    private var ms: AutoIDSettings.ModelSettings {
        settings.perModel[model.id] ?? AutoIDSettings.defaultSettings(for: model)
    }

    /// Generic write-through binding to one field of this model's settings.
    private func bind<T>(_ keyPath: WritableKeyPath<AutoIDSettings.ModelSettings, T>) -> Binding<T> {
        Binding(
            get: { ms[keyPath: keyPath] },
            set: { settings.perModel[model.id]?[keyPath: keyPath] = $0 }
        )
    }

    private func enabledBinding(for code: String) -> Binding<Bool> {
        Binding(
            get: { settings.perModel[model.id]?.species[code]?.enabled ?? true },
            set: { value in
                var s = settings.perModel[model.id]?.species[code]
                        ?? AutoIDSettings.SpeciesState(enabled: true, prior: 1.0, resolved: false)
                s.enabled = value
                settings.perModel[model.id]?.species[code] = s
            }
        )
    }

    private func priorBinding(for code: String) -> Binding<Float> {
        Binding(
            get: { settings.perModel[model.id]?.species[code]?.prior ?? 1.0 },
            set: { value in
                var s = settings.perModel[model.id]?.species[code]
                        ?? AutoIDSettings.SpeciesState(enabled: true, prior: 1.0, resolved: false)
                s.prior = value
                settings.perModel[model.id]?.species[code] = s
            }
        )
    }

    private func allEnabled(_ codes: [String]) -> Bool {
        codes.allSatisfy { settings.perModel[model.id]?.species[$0]?.enabled ?? true }
    }

    private func setGroup(_ codes: [String], enabled: Bool) {
        for code in codes {
            var s = settings.perModel[model.id]?.species[code]
                    ?? AutoIDSettings.SpeciesState(enabled: true, prior: 1.0, resolved: false)
            s.enabled = enabled
            settings.perModel[model.id]?.species[code] = s
        }
    }
}

// MARK: - Species row

private struct SpeciesRow: View {
    let code: String
    let commonName: String
    @Binding var enabled: Bool
    @Binding var prior: Float
    /// False when no range data backs this species — see
    /// `AutoIDSettings.SpeciesState.resolved`. Shown, rather than kept internal,
    /// because the failure this replaced was invisible: a species nobody had
    /// confirmed looked exactly like one confirmed to be underfoot.
    var resolved: Bool = true

    var body: some View {
        HStack(spacing: 10) {
            // Leading radio-style checkbox — same visual language as
            // AutoIDSettingsView's model-activation control — instead of wrapping
            // the whole row in a Toggle.
            Button {
                enabled.toggle()
            } label: {
                Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(enabled ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(enabled ? "Enabled" : "Disabled")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(code).bold()
                    if !resolved {
                        Image(systemName: "questionmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("No range data")
                    }
                }
                Text(resolved ? commonName : "No range data")
                    .font(.caption)
                    .foregroundStyle(resolved ? Color.secondary : Color.orange)
            }
            .frame(width: 90, alignment: .leading)

            if enabled {
                Slider(value: $prior, in: 0.01...1.0, step: 0.01)
                Text(String(format: "%.2f", prior))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            } else {
                Spacer()
                Text("off")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
