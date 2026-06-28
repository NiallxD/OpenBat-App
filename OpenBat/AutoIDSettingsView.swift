//
//  AutoIDSettingsView.swift
//  OpenBat
//
//  AutoID tab of SettingsView.
//  Each species row has an enable/disable toggle and, when enabled, a prior slider.
//  "Off" forces the prior to 0.01 at classification time regardless of the slider.
//

import SwiftUI

struct AutoIDSettingsView: View {
    @Bindable var settings: AutoIDSettings

    // Species groups shown in the list.
    private let groups: [(name: String, codes: [String])] = [
        ("Myotis",               ["MYAU","MYCA","MYCI","MYEV","MYGR","MYLE",
                                   "MYLU","MYSE","MYSO","MYTH","MYVE","MYVO","MYYU"]),
        ("Lasiurus & allies",    ["LABL","LABO","LACI","LAIN","LANO","LASE"]),
        ("Other vesper bats",    ["ANPA","COTO","EPFU","EUMA","EUPE","IDPH","PAHE","PESU"]),
        ("Free-tailed & evening",["NYHU","NYMA","TABR"]),
        ("Non-bat",              ["NOISE"]),
    ]

    var body: some View {
        Form {
            passSection
            qualityGateSection
            speciesSections
            resetSection
        }
    }

    // MARK: Quality gate

    private var qualityGateSection: some View {
        Section {
            Toggle("Quality gate", isOn: $settings.qualityGateEnabled)

            if settings.qualityGateEnabled {
                LabeledContent("Min SNR") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.qualitySNThreshold, in: 1...20, step: 1)
                        Text(String(format: "%.0f×", settings.qualitySNThreshold))
                            .font(.caption.monospacedDigit())
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                LabeledContent("Min amplitude") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.qualityAmpThreshold, in: 5...40, step: 1)
                        Text(String(format: "%.0f dB", settings.qualityAmpThreshold))
                            .font(.caption.monospacedDigit())
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
        } header: {
            Text("Pulse quality")
        } footer: {
            Text("Rejects faint or edge-clipped pulses before classification, matching the NABat detector defaults (SNR ≥ 7, amplitude ≥ 21 dB). Rejected pulses still appear in the Pulse View but don't form an ID.")
        }
    }

    // MARK: Pass detection

    private var passSection: some View {
        Section("Pass detection") {
            LabeledContent("Timeout") {
                HStack(spacing: 8) {
                    Slider(value: $settings.passTimeoutSeconds, in: 0.5...10, step: 0.5)
                    Text(String(format: "%.1f s", settings.passTimeoutSeconds))
                        .font(.caption.monospacedDigit())
                        .frame(width: 42, alignment: .trailing)
                }
            }

            LabeledContent("Min pulses") {
                Stepper("\(settings.minPassPulseCount)",
                        value: $settings.minPassPulseCount, in: 1...10)
            }

            LabeledContent("Min confidence") {
                HStack(spacing: 8) {
                    Slider(value: $settings.minPassConfidence, in: 0...0.5, step: 0.01)
                    Text(String(format: "%.0f%%", settings.minPassConfidence * 100))
                        .font(.caption.monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
    }

    // MARK: Species

    private var speciesSections: some View {
        ForEach(groups, id: \.name) { group in
            Section(group.name) {
                ForEach(group.codes, id: \.self) { code in
                    SpeciesRow(
                        code: code,
                        commonName: SpeciesInfo.commonName[code] ?? code,
                        enabled: enabledBinding(for: code),
                        prior:   priorBinding(for: code)
                    )
                }
            }
        }
    }

    // MARK: Reset

    private var resetSection: some View {
        Section {
            Button("Reset to BC Defaults", role: .destructive) {
                withAnimation { settings.resetToDefaults() }
            }
        } footer: {
            Text("Defaults reflect species confirmed or possible in coastal SW British Columbia.")
        }
    }

    // MARK: Bindings

    private func enabledBinding(for code: String) -> Binding<Bool> {
        Binding(
            get: { self.settings.species[code]?.enabled ?? true },
            set: { value in
                var s = self.settings.species[code] ?? AutoIDSettings.SpeciesState(enabled: true, prior: 1.0)
                s.enabled = value
                self.settings.species[code] = s
            }
        )
    }

    private func priorBinding(for code: String) -> Binding<Float> {
        Binding(
            get: { self.settings.species[code]?.prior ?? 1.0 },
            set: { value in
                var s = self.settings.species[code] ?? AutoIDSettings.SpeciesState(enabled: true, prior: 1.0)
                s.prior = value
                self.settings.species[code] = s
            }
        )
    }
}

// MARK: - Species row

private struct SpeciesRow: View {
    let code: String
    let commonName: String
    @Binding var enabled: Bool
    @Binding var prior: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $enabled) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(code).bold()
                        Text(commonName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(enabled ? String(format: "%.2f", prior) : "off")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            if enabled {
                HStack(spacing: 6) {
                    Text("0.01").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $prior, in: 0.01...1.0, step: 0.01)
                    Text(String(format: "%.2f", prior))
                        .font(.caption2.monospacedDigit())
                        .frame(width: 30, alignment: .trailing)
                }
                .padding(.leading, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: enabled)
        .padding(.vertical, 2)
    }
}
