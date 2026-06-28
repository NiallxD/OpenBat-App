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
                        Text("Peak frequency must be at or above this value. 15–20 kHz rejects wind and handling noise; raise to 30–40 kHz to target common pipistrelle ranges.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Frequency gate")
                    }
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
                    Text("Minimum gap between detections. Keep short (~50 ms) — gap-bridging already stops one call re-triggering, and a long hold-off caps the detected call rate (e.g. 300 ms limits you to ~3/sec).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Noise rejection")
                } footer: {
                    Text("Display options (triggered view, pulse zoom & noise floor) are on the main screen — the toolbar toggle and the Pulse View / Spectrogram panel buttons.")
                }
            }
            .navigationTitle("Pulse Detection")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
