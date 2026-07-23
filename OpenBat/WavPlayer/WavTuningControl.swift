//
//  WavTuningControl.swift
//  OpenBat
//
//  Inline heterodyne/RTE tuning + display options for the WAV player —
//  reached via a toolbar button + `.popover`, same invocation pattern as
//  `FrequencyBandControl` (ContentView.bandButton). Previously RTE/heterodyne
//  tuning was only reachable through the global Settings sheet's RTE tab
//  (SettingsView.rteTab) even while playing back a file; this exposes the
//  same `RTESettings` fields directly, without leaving the player.
//
//  No longer has its own frequency-band slider — WavPlayerView derives
//  `bandLow`/`bandHigh` (the heterodyne/RTE processing band) straight from
//  `viewport.minFreqHz/maxFreqHz` (see its `syncBandFromViewport`), which the
//  Range ticker wheel and panning directly on the spectrogram both already
//  drive, so a second, separate band control here would just duplicate that.
//

import SwiftUI

struct WavTuningControl: View {
    @Bindable var rteSettings: RTESettings
    @Binding var logFrequency: Bool
    @Binding var noiseFloor: Double
    @Binding var hideSilence: Bool
    /// 0 = only near-total quiet counts as silence, 1 = aggressive — see
    /// SilenceMap.thresholdDB for the dB mapping.
    @Binding var silenceSensitivity: Double
    /// Seconds of audio kept on EACH side of every detected pulse before the
    /// silence is cut — larger keeps more context (and merges close pulses),
    /// smaller cuts tighter. See SilenceMap.compute's `padSeconds`.
    @Binding var silencePadding: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Display").font(.headline)

            Toggle("Log frequency scale", isOn: $logFrequency)

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Noise floor") {
                    Text(String(format: "%.2f", noiseFloor)).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $noiseFloor, in: 0...0.9, step: 0.05)
            }

            Toggle("Hide silence", isOn: $hideSilence)
            if hideSilence {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Silence sensitivity") {
                        Text(String(format: "%.2f", silenceSensitivity)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $silenceSensitivity, in: 0...1, step: 0.05)
                }
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Pulse margin") {
                        Text(String(format: "%.0f ms", silencePadding * 1000)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $silencePadding, in: 0.005...0.1, step: 0.005)
                }
            }

            Divider()

            Text("Heterodyne / RTE").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("RTE gain") {
                    Text(String(format: "%.1f×", rteSettings.gain)).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $rteSettings.gain, in: 1...16, step: 0.5)
            }

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("RTE sensitivity") {
                    Text(String(format: "%.0f dB", rteSettings.marginDB)).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $rteSettings.marginDB, in: 4...24, step: 1)
            }

            HStack {
                Spacer()
                Button("Reset to defaults") { rteSettings.reset() }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 270)
        .presentationCompactAdaptation(.popover)
    }
}
