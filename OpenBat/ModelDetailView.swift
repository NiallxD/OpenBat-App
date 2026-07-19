//
//  ModelDetailView.swift
//  OpenBat
//
//  Detail screen for one classifier model: metadata, the "use this model" switch,
//  and all of the model's settings — pass detection, per-pulse quality gate, and
//  the species list (grouped) with enable toggles and prior sliders.
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
            activeSection
            passSection
            qualityGateSection
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
            LabeledContent("Classes", value: "\(model.classNames.count)")
        } header: {
            Text("Model")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.citation)
                if let url = model.sourceURL {
                    Link(destination: url) {
                        Label("Source repository", systemImage: "arrow.up.right.square")
                    }
                    .font(.footnote)
                }
            }
        }
    }

    private var activeSection: some View {
        Section {
            Toggle("Use this model", isOn: Binding(
                get: { settings.activeModelID == model.id },
                set: { settings.activeModelID = $0 ? model.id : nil }
            ))
        } footer: {
            Text("Only one model runs at a time. Enabling this disables any other.")
        }
    }

    // MARK: Pass detection

    private var passSection: some View {
        Section("Pass detection") {
            LabeledContent("Timeout") {
                HStack(spacing: 8) {
                    Slider(value: bind(\.passTimeoutSeconds), in: 0.5...10, step: 0.5)
                    Text(String(format: "%.1f s", ms.passTimeoutSeconds))
                        .font(.caption.monospacedDigit())
                        .frame(width: 42, alignment: .trailing)
                }
            }
            LabeledContent("Min pulses") {
                Stepper("\(ms.minPassPulseCount)", value: bind(\.minPassPulseCount), in: 1...10)
            }
            LabeledContent("Min confidence") {
                HStack(spacing: 8) {
                    Slider(value: bind(\.minPassConfidence), in: 0...0.5, step: 0.01)
                    Text(String(format: "%.0f%%", ms.minPassConfidence * 100))
                        .font(.caption.monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
    }

    // MARK: Quality gate

    private var qualityGateSection: some View {
        Section {
            Toggle("Quality gate", isOn: bind(\.qualityGateEnabled))
            if ms.qualityGateEnabled {
                LabeledContent("Min SNR") {
                    HStack(spacing: 8) {
                        Slider(value: bind(\.qualitySNThreshold), in: 1...20, step: 1)
                        Text(String(format: "%.0f×", ms.qualitySNThreshold))
                            .font(.caption.monospacedDigit())
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                LabeledContent("Min amplitude") {
                    HStack(spacing: 8) {
                        Slider(value: bind(\.qualityAmpThreshold), in: 5...40, step: 1)
                        Text(String(format: "%.0f dB", ms.qualityAmpThreshold))
                            .font(.caption.monospacedDigit())
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
        } header: {
            Text("Pulse quality")
        } footer: {
            Text("Rejects faint or edge-clipped pulses before classification, matching the "
               + "NABat detector defaults (SNR ≥ 7, amplitude ≥ 21 dB). Rejected pulses still "
               + "appear in the Pulse View but don't form an ID.")
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
                        prior:   priorBinding(for: code)
                    )
                }
            } header: {
                HStack {
                    Text(group.name)
                    Spacer()
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
        } footer: {
            Text("Restores this model's species, priors, and thresholds to a neutral baseline "
               + "(every species enabled, no location bias). Priors re-suggest automatically "
               + "from nearby GBIF occurrence data the next time your location updates.")
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
                        ?? AutoIDSettings.SpeciesState(enabled: true, prior: 1.0)
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
                        ?? AutoIDSettings.SpeciesState(enabled: true, prior: 1.0)
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
                    ?? AutoIDSettings.SpeciesState(enabled: true, prior: 1.0)
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
                Text(code).bold()
                Text(commonName).font(.caption).foregroundStyle(.secondary)
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
