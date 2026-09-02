//
//  PulseSettingsView.swift
//  OpenBat
//
//  Sheet for configuring the pulse detector. Presented from the main toolbar.
//

import SwiftUI

struct PulseSettingsView: View {
    @Bindable var detector: PulseDetector

    private var minFreqKHz: Binding<Double> {
        Binding(
            get: { detector.minFrequencyHz / 1000 },
            set: { detector.minFrequencyHz = $0 * 1000 }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $detector.triggerMode) {
                        ForEach(PulseDetector.TriggerMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(detector.triggerMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Trigger mode")
                }

                Section {
                    LabeledContent("Amplitude threshold") {
                        Text(String(format: "%.2f", detector.amplitudeThreshold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $detector.amplitudeThreshold, in: 0.1...0.95, step: 0.05)
                    Text("Normalised peak magnitude (0–1). Matches spectrogram brightness — 0.5 is medium-bright.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Amplitude")
                }

                if detector.triggerMode == .ultrasonic {
                    Section {
                        LabeledContent("Min frequency") {
                            Text(String(format: "%.0f kHz", detector.minFrequencyHz / 1000))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: minFreqKHz, in: 5...150, step: 5)
                        // The old copy suggested raising this to 30–40 kHz "to
                        // target common pipistrelle ranges", which is advice
                        // that silently deafens the detector to every bat
                        // calling below the gate — noctules, serotines and
                        // free-tailed bats sit at 20–30 kHz — with no
                        // indication on screen that anything is being dropped.
                        Text("Peak frequency must be at or above this value. 15–20 kHz rejects wind and handling noise without excluding any bat. Raise it only to ignore a species you know is there: a 35 kHz gate hears nothing from noctules, serotines or free-tailed bats, which call between 20 and 30 kHz.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Frequency gate")
                    }
                }

                Section {
                    LabeledContent("Display refresh") {
                        Text(detector.displayRefreshIntervalSeconds <= 0
                             ? "Every pulse"
                             : String(format: "%.1f s", detector.displayRefreshIntervalSeconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $detector.displayRefreshIntervalSeconds, in: 0...5, step: 0.5)
                    Text("How often the pulse zoom image updates. 0 = every detected pulse. Set to 1–2 s to show one clean pulse per pass without flickering through noise hits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Display")
                }

                Section {
                    Stepper("Min duration: \(detector.minConsecutiveColumns) columns",
                            value: $detector.minConsecutiveColumns, in: 1...10)
                    Text("Above-threshold columns required in a pulse before it's accepted. Increase to reject single-column spikes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("Bridge gaps") {
                        Text(String(format: "%.0f ms", detector.maxGapMs))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $detector.maxGapMs, in: 0...30, step: 1)
                    Text("Brief dips below threshold this short are treated as part of the same call, so one call gives one capture instead of fragmenting. Raise if calls are splitting into pieces.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("Hold-off") {
                        Text(String(format: "%.0f ms", detector.holdOffSeconds * 1000))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $detector.holdOffSeconds, in: 0.02...1.0, step: 0.01)
                    Text("Minimum gap between detections. Default 50 ms passes typical call spacing while still rejecting the closest echoes (amplitude does the rest, since echoes return much quieter). Raise further if echoes still re-trigger.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Noise rejection")
                }
            }
            .navigationTitle("Pulse Detection")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
