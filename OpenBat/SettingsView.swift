//
//  SettingsView.swift
//  OpenBat
//

import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AutoIDSettings
    @Bindable var rteSettings: RTESettings
    @Bindable var pulseDetector: PulseDetector
    @Bindable var recorder: AudioRecorder
    @Bindable var location: LocationProvider
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = "autoID"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $selectedTab) {
                    Text("AutoID").tag("autoID")
                    Text("RTE").tag("rte")
                    Text("Pulse").tag("pulse")
                    Text("Map").tag("map")
                    Text("Audio").tag("audio")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

                switch selectedTab {
                case "autoID": AutoIDSettingsView(settings: settings, location: location)
                case "rte":    rteTab
                case "pulse":  pulseTab
                case "map":    mapTab
                default:       audioTab
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        settings.save()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @AppStorage("recording.screenCaptureEnabled") private var screenCaptureEnabled = false
    @AppStorage("recording.autoRecordOnSessionStart") private var autoRecordOnSessionStart = true
    /// Read directly by RecordingSpectrogramRenderer (off-main, no live settings
    /// reference) the same way it already reads `pulse.displayPalette`. 0.5 is a
    /// starting default, not a settled value — surfaced here so it can be tuned
    /// without a code change until a final number is picked.
    @AppStorage("display.playbackThumbnailNoiseFloor") private var playbackThumbnailNoiseFloor = 0.5
    /// Read directly by WavPlayerView/CallAnalysisPanel — the fraction of a
    /// measured call's active duration averaged (median) to estimate
    /// characteristic/knee frequency. No existing algorithm to calibrate
    /// against; 0.25 is a starting default per CallAnalysis's own doc comment,
    /// surfaced here (same treatment as the noise floor above) so it can be
    /// tuned against real recordings without a code change.
    @AppStorage("display.cfTailFraction") private var cfTailFraction = CallAnalysis.defaultCFTailFraction

    // MARK: Pulse tab

    private var pulseMinFreqKHz: Binding<Double> {
        Binding(get: { pulseDetector.minFrequencyHz / 1000 },
                set: { pulseDetector.minFrequencyHz = $0 * 1000 })
    }

    private var pulseTab: some View {
        Form {
            Section {
                Picker("Mode", selection: $pulseDetector.triggerMode) {
                    ForEach(PulseDetector.TriggerMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(pulseDetector.triggerMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Trigger mode")
            }

            Section {
                LabeledContent("Amplitude threshold") {
                    Text(String(format: "%.2f", pulseDetector.amplitudeThreshold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $pulseDetector.amplitudeThreshold, in: 0.1...0.95, step: 0.05)
                Text("Normalised peak magnitude (0–1). Matches spectrogram brightness — 0.5 is medium-bright.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Amplitude")
            }

            if pulseDetector.triggerMode == .ultrasonic {
                Section {
                    LabeledContent("Min frequency") {
                        Text(String(format: "%.0f kHz", pulseDetector.minFrequencyHz / 1000))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: pulseMinFreqKHz, in: 5...150, step: 5)
                    Text("Peak frequency must be at or above this value. 15–20 kHz rejects wind and handling noise; raise to 30–40 kHz to target common pipistrelle ranges.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Frequency gate")
                }
            }

            Section {
                Stepper("Min duration: \(pulseDetector.minConsecutiveColumns) columns",
                        value: $pulseDetector.minConsecutiveColumns, in: 1...10)
                Text("Above-threshold columns required before a pulse is accepted. Increase to reject single-column spikes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Bridge gaps") {
                    Text(String(format: "%.0f ms", pulseDetector.maxGapMs))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $pulseDetector.maxGapMs, in: 0...30, step: 1)
                Text("Brief dips below threshold this short are treated as part of the same call. Raise if calls are splitting into pieces.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Hold-off") {
                    Text(String(format: "%.0f ms", pulseDetector.holdOffSeconds * 1000))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $pulseDetector.holdOffSeconds, in: 0.02...1.0, step: 0.01)
                Text("Minimum gap between detections. The 50 ms default matches typical call spacing so a normal pass isn't under-counted; raise it toward 150 ms only if close echoes are double-triggering, or lower it for fast feeding buzzes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Noise rejection")
            }
        }
    }

    // MARK: RTE tab

    private var rteTab: some View {
        Form {
            Section {
                LabeledContent("Minimum frequency") {
                    Text(String(format: "%.0f kHz", rteSettings.minFrequencyKHz))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $rteSettings.minFrequencyKHz, in: 5 ... 60, step: 1)
                Text("Only sounds above this frequency can trigger expansion. If too many non-bat sounds (footsteps, keys, wind) are triggering RTE, move this up a bit; move it down to catch lower-frequency bats.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Noise rejection")
            }

            Section {
                LabeledContent("Tail hold") {
                    Text(String(format: "%.1f ms", rteSettings.holdMs))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $rteSettings.holdMs, in: 0.5 ... 30, step: 0.5)
                Text("How long to keep expanding after the signal drops below threshold. Too short fragments a call into clicks; too long pulls in trailing noise. ~15 ms bridges the dips inside an FM sweep.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Tail")
            }

            Section {
                LabeledContent("Output gain") {
                    Text(String(format: "%.1f ×", rteSettings.gain))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $rteSettings.gain, in: 1 ... 16, step: 0.5)
                Text("Makeup gain applied after expansion. 8× time-stretch halves perceived loudness, so 4–8 × is a good starting point.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Output")
            }

            Section {
                LabeledContent("Sensitivity") {
                    Text(String(format: "%.0f dB", rteSettings.marginDB))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $rteSettings.marginDB, in: 4 ... 24, step: 1)
                Text("How far a sound must rise above the background noise floor to trigger. Lower catches fainter calls but lets in more noise; higher only takes the loudest. The gate is relative, so this adapts to conditions automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Gate window") {
                    Text(String(format: "%.2f ms", rteSettings.gateBlockMs))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $rteSettings.gateBlockMs, in: 0.1 ... 5.0, step: 0.1)
                Text("RMS window for the sub-buffer gate. Smaller = more responsive (catches fast call onsets) but noisier. Larger = smoother gate but can clip the very start of short calls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("Reset to defaults") { rteSettings.reset() }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Advanced")
            }
        }
    }

    /// Map-pin gates: only session IDs clearing both end up as species pins on the map.
    private var mapTab: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Min confidence")
                        Spacer()
                        Text("\(Int(settings.mapPinMinConfidence * 100))%").monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { Double(settings.mapPinMinConfidence) },
                                          set: { settings.mapPinMinConfidence = Float($0) }),
                           in: 0.3...0.95, step: 0.05)
                }
                Stepper("Min pulses: \(settings.mapPinMinPulseCount)",
                        value: $settings.mapPinMinPulseCount, in: 1...20)
            } header: {
                Text("Map pins")
            } footer: {
                Text("A session ID drops a species pin on the map only when its confidence and pulse count both clear these gates — the best of the best.")
            }
        }
    }

    private var audioTab: some View {
        Form {
            Section {
                Toggle("Auto-record on session start", isOn: $autoRecordOnSessionStart)
                Toggle("Screen recording", isOn: $screenCaptureEnabled)
            } header: {
                Text("Recording")
            } footer: {
                Text("When on, starting a New Session automatically arms the triggered WAV recorder. Just Listening always starts unarmed regardless of this setting. Screen recording captures a video (ReplayKit) alongside the triggered WAV passes whenever recording is armed.")
            }

            Section {
                LabeledContent("Pre-roll") {
                    Text(String(format: "%.1f s", recorder.preRollSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $recorder.preRollSeconds, in: 0.5...5.0, step: 0.5)

                LabeledContent("Close after silence") {
                    Text(String(format: "%.1f s", recorder.postRollSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $recorder.postRollSeconds, in: 1.0...10.0, step: 0.5)
            } header: {
                Text("Activity bout")
            } footer: {
                Text("Recording starts this many seconds before the first detected pulse. It keeps extending with every further pulse and only closes once nothing has triggered for the \"close after silence\" duration — so one bat giving several passes in a row lands in a single WAV instead of fragmenting into many.")
            }

            Section {
                LabeledContent("Noise floor") {
                    Text(String(format: "%.2f", playbackThumbnailNoiseFloor))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $playbackThumbnailNoiseFloor, in: 0...0.9, step: 0.05)
            } header: {
                Text("Playback thumbnails")
            } footer: {
                Text("Gates faint background energy out of the whole-recording spectrogram thumbnails shown in the Playback and Sessions lists, so a quiet recording reads as mostly black instead of speckled with low-level noise. Temporary while a final default is settled.")
            }

            Section {
                LabeledContent("CF tail fraction") {
                    Text(String(format: "%.0f%%", cfTailFraction * 100))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $cfTailFraction, in: 0.1...0.5, step: 0.05)
            } header: {
                Text("Call analysis")
            } footer: {
                Text("Characteristic/knee frequency is estimated as the median frequency over the last this-much of a measured call's duration, where FM sweeps typically flatten into a quasi-constant-frequency tail. No prior calibration exists for this — treat as a starting default until checked against real recordings.")
            }
        }
    }
}
