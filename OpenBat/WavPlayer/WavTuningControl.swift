//
//  WavTuningControl.swift
//  OpenBat
//
//  Inline heterodyne/time-expansion tuning + display
//  options for the WAV player — reached via a toolbar button + `.popover`,
//  same invocation pattern as `FrequencyBandControl` (ContentView.bandButton).
//  This exposes the same listen-mode settings fields directly, without
//  leaving the player. `TimeExpansionSettings` (playback-only, no
//  live-detector counterpart) lives ONLY here and in Settings has no home at
//  all — see WavPlayerView's doc comment on its `timeExpSettings` property.
//
//  No longer has its own frequency-band slider — WavPlayerView derives
//  `bandLow`/`bandHigh` (the heterodyne/time-expansion processing band)
//  straight from `viewport.minFreqHz/maxFreqHz` (see its
//  `syncBandFromViewport`), which the Range ticker wheel and panning directly
//  on the spectrogram both already drive, so a second, separate band control
//  here would just duplicate that.
//

import SwiftUI

struct WavTuningControl: View {
    @Bindable var timeExpSettings: TimeExpansionSettings
    /// `PlaybackEngine.expansionFactor` — the speed the player is set to. Read
    /// from the engine (which is `@Observable`) rather than from the
    /// processor's own `slowdownFactor`, which is lock-guarded and untracked,
    /// so this label would not refresh when the speed changed.
    let timeExpansionSlowdownFactor: Double
    @Binding var logFrequency: Bool
    @Binding var noiseFloor: Double
    @Binding var hideSilence: Bool
    /// How far above the recording's own measured noise floor a sound has to
    /// be to be kept, in dB. A real unit on purpose — the same number means
    /// the same thing on every file, which the 0...1 "sensitivity" it replaced
    /// did not; see SilenceMap.compute.
    @Binding var silenceThresholdDB: Double
    /// What the detection actually did to THIS recording, e.g. "Kept 19% ·
    /// 49 regions" — or why it did nothing. Silence removal could previously
    /// fall back to showing the whole file for three different reasons and
    /// look identical to a broken toggle in all of them.
    let silenceSummary: String?
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
                    LabeledContent("Keep above") {
                        Text(String(format: "%.0f dB", silenceThresholdDB)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $silenceThresholdDB,
                           in: SilenceMap.minThresholdAboveFloorDB...SilenceMap.maxThresholdAboveFloorDB,
                           step: 1)
                    Text("Above this recording's own noise floor. Lower keeps more faint calls; higher cuts harder.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Pulse margin") {
                        Text(String(format: "%.0f ms", silencePadding * 1000)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $silencePadding, in: 0.005...0.1, step: 0.005)
                }
                if let silenceSummary {
                    Text(silenceSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("Time expansion").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Time exp gain") {
                    Text(String(format: "%.1f×", timeExpSettings.gain)).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $timeExpSettings.gain, in: 1...16, step: 0.5)
                Text("Plays the recording back \(Self.slowdownLabel(timeExpansionSlowdownFactor)) slower, at every sample — nothing is dropped or selected out, so pitch drops proportionally instead of being divided or mixed down. Change the speed with the gauge button under the spectrogram.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Reset to defaults") { timeExpSettings.reset() }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 270)
        .presentationCompactAdaptation(.popover)
    }

    /// Whole-number factors (the expected case — 8× for a native 384 kHz
    /// file) read as "8×"; anything else shows one decimal so a
    /// non-384-kHz file doesn't silently claim a round number it isn't.
    private static func slowdownLabel(_ factor: Double) -> String {
        let rounded = factor.rounded()
        if abs(factor - rounded) < 0.05 {
            return "\(Int(rounded))×"
        }
        return String(format: "%.1f×", factor)
    }
}
