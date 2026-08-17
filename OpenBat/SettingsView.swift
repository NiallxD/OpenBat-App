//
//  SettingsView.swift
//  OpenBat
//
//  The Settings sheet: three tabs (General / AutoID / Audio) picked by a
//  segmented control rather than a `TabView`, so only the active tab's `Form`
//  exists at a time.
//
//  Both General and Audio are composites, built from `@ViewBuilder` section
//  groups rather than owning their sections directly — General absorbed the
//  Location, Storage and Privacy tabs (2026-08-16, alongside the simplified-view
//  switch it now leads with), and Audio absorbed the old Time Expansion, Pulse
//  and Recording tabs before that. Section header text is kept from whichever
//  tab it came from, so the sections still read as their original groups.
//

import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AutoIDSettings
    @Bindable var pulseDetector: PulseDetector
    @Bindable var recorder: AudioRecorder
    @Bindable var location: LocationProvider
    var consent: ConsentStore
    let classStore: ClassificationStore
    let audio: AudioEngineController
    @Bindable var micCalSettings: MicCalibrationSettings
    @Bindable var haptics: PulseHaptics
    @State private var showMicCalibration = false
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = "general"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Three tabs, not five. Location, Storage and Privacy were a
                // tab each and none of them filled one — Location was a single
                // section, Privacy a single disabled toggle. Five segments were
                // also too many for a phone's width, which is why "Recordings"
                // had already been shortened to "Storage" to stop it
                // truncating. They fold into General, which is also where the
                // simplified-view switch belongs: it governs the whole app
                // rather than any one tab, so it goes first, in the tab the
                // sheet opens on.
                Picker("Section", selection: $selectedTab) {
                    Text("General").tag("general")
                    Text("AutoID").tag("autoID")
                    Text("Audio").tag("audio")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

                switch selectedTab {
                case "autoID":  AutoIDSettingsView(settings: settings, location: location)
                case "audio":   audioTab
                default:        generalTab
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
    }

    @AppStorage("recording.autoRecordOnSessionStart") private var autoRecordOnSessionStart = true
    /// Read directly by RecordingSpectrogramRenderer (off-main, no live settings
    /// reference) the same way it already reads `pulse.displayPalette`. 0.25 is a
    /// starting default, not a settled value — surfaced here so it can be tuned
    /// without a code change until a final number is picked.
    @AppStorage("display.playbackThumbnailNoiseFloor") private var playbackThumbnailNoiseFloor = 0.25
    /// Read directly by WavPlayerView/CallAnalysisPanel — the fraction of a
    /// measured call's active duration averaged (median) to estimate
    /// characteristic/knee frequency. No existing algorithm to calibrate
    /// against; 0.25 is a starting default per CallAnalysis's own doc comment,
    /// surfaced here (same treatment as the noise floor above) so it can be
    /// tuned against real recordings without a code change.
    @AppStorage("display.cfTailFraction") private var cfTailFraction = CallAnalysis.defaultCFTailFraction

    // MARK: General tab

    /// The app-wide interface mode. `true` hides the readouts and controls that
    /// only mean something once you already know what they are — see
    /// `SimplifiedView` for the full list and the reasoning.
    @AppStorage(SimplifiedView.key) private var simplifiedMode = true

    /// General: the interface mode, then what used to be the Location, Storage
    /// and Privacy tabs, in that order — least destructive first, so the bulk
    /// deletes stay well below the fold.
    private var generalTab: some View {
        Form {
            Section {
                Toggle("Simplified view", isOn: $simplifiedMode)
            } header: {
                Text("Interface")
            } footer: {
                // Says what it does in terms of what the user will SEE, and —
                // the part that matters — that nothing is being thrown away.
                // Someone who has tuned an advanced control and then turns this
                // on needs to know their settings are still there, or the
                // switch reads as destructive and they won't touch it.
                Text(simplifiedMode
                     ? "Shows just the species ID, the level meter and the spectrogram. Turn this off for the full set of readouts and controls — pulse measurements, the pulse close-up, the timeline and palette controls. Nothing is deleted either way: your settings are kept and come back when you switch."
                     : "Showing every readout and control. Turn this on for a simpler screen: just the species ID, the level meter and the spectrogram.")
            }

            locationSections
            storageSections
            privacySections
        }
        .onChange(of: keepInICloud) { _, _ in showRestartNeeded = true }
        .alert("Restart OpenBat to finish", isPresented: $showRestartNeeded) {
            Button("OK") { }
        } message: {
            Text("Your existing recordings are moved the next time OpenBat starts. Until then they stay where they are — nothing is lost either way.")
        }
        .sheet(isPresented: $showDeleteAllConfirmation) {
            DeleteAllRecordingsConfirmationView(classStore: classStore) { }
        }
        .confirmationDialog("Delete every NoID recording?",
                            isPresented: $showDeleteNoIDConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { classStore.deleteNoIDRecordings() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog("Delete every recording under \(Int(Self.lowConfidenceDeleteThreshold * 100))% confidence?",
                            isPresented: $showDeleteLowConfidenceConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                classStore.deleteRecordings(belowConfidence: Self.lowConfidenceDeleteThreshold)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This can't be undone.")
        }
    }

    // MARK: Storage sections

    /// Below this, a real species ID counts as "low confidence" for the bulk
    /// delete below — separate from RecordingUploader.minUploadConfidence (75%,
    /// what's eligible to UPLOAD); this is a much looser bar for pruning
    /// obvious junk locally, not for deciding what to contribute.
    private static let lowConfidenceDeleteThreshold: Float = 0.57

    /// Changing this doesn't move anything immediately — the migration runs at
    /// next launch (see `CloudStorage.applyPendingStorageMigration`), so the
    /// alert below tells the user that rather than leaving them to wonder.
    @AppStorage(CloudStorage.keepInICloudKey) private var keepInICloud = true
    @State private var showRestartNeeded = false

    @State private var showDeleteAllConfirmation = false
    @State private var showDeleteNoIDConfirm = false
    @State private var showDeleteLowConfidenceConfirm = false

    @ViewBuilder
    private var storageSections: some View {
        Group {
            Section {
                Toggle("Keep recordings in iCloud", isOn: $keepInICloud)
            } header: {
                Text("Storage")
            } footer: {
                // Deliberately explicit about both the benefit and the cost:
                // audio is ~768 KB/s at 384 kHz, so a busy night can run to
                // several GB against the user's iCloud quota — and they'd
                // otherwise have no way to connect that to OpenBat.
                Text(keepInICloud
                     ? "Recordings and session history are stored in your own iCloud, so they survive deleting the app and follow you to a new device. They stay in your iCloud account and aren't visible in the Files app. Audio is large: a busy night can use several GB of your iCloud storage."
                     : "Recordings and session history are stored only on this device, and are permanently lost if you delete OpenBat. Nothing is stored in iCloud.")
            }

            if case .awaitingDownloads(let count) = CloudStorage.lastMigrationResult {
                Section {
                    Label("\(count) recording\(count == 1 ? "" : "s") still need downloading from iCloud before they can be moved to this device. That's been started — reopen OpenBat once it finishes and the move will complete. Nothing has been moved or lost in the meantime.",
                          systemImage: "arrow.down.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if case .failed(let reason) = CloudStorage.lastMigrationResult {
                Section {
                    Label("Couldn't move your recordings: \(reason) Nothing was moved — your library is still where it was. Try again, or free up space first.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            if CloudStorage.lastMigrationResult == .iCloudUnavailable || CloudStorage.isUsingFallbackRoot {
                Section {
                    Label("iCloud isn't available right now, so this is using on-device storage. Check you're signed in to iCloud with iCloud Drive on.",
                          systemImage: "exclamationmark.icloud")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button("Delete All Recordings", role: .destructive) {
                    showDeleteAllConfirmation = true
                }
            } footer: {
                Text("Permanently deletes every recording (and its WAV file) on this device. Session and pulse-ID history is unaffected.")
            }

            Section {
                Button("Delete NoID Recordings", role: .destructive) {
                    showDeleteNoIDConfirm = true
                }
            } footer: {
                Text("Deletes every recording that couldn't be classified (NoID) — usually just noise triggers.")
            }

            Section {
                Button("Delete Low-Confidence Recordings", role: .destructive) {
                    showDeleteLowConfidenceConfirm = true
                }
            } footer: {
                Text("Deletes every recording with a species-ID confidence under \(Int(Self.lowConfidenceDeleteThreshold * 100))%. Doesn't include NoID recordings — use the option above for those.")
            }
        }
    }

    // MARK: Privacy sections

    @ViewBuilder
    private var privacySections: some View {
        Group {
            Section {
                Toggle("Contribute recordings to the community science project", isOn: .constant(false))
                    .disabled(true)
            } footer: {
                Text("There are no community science projects currently active. Check back soon!")
            }

            // Device ID / consent erasure are hidden while contribution is
            // disabled (ConsentStore.uploadContributionEnabled == false):
            // consent can never be granted, so no record ever exists to erase,
            // and with the backend severed (UploadClient/ConsentAPIClient
            // baseURL == "") the Erase call would always fail with a
            // connection-style error that misrepresents a deliberate,
            // permanent severance as a network hiccup.
        }
    }

    // MARK: Audio tab (formerly separate Time Expansion / Pulse / Audio tabs,
    // merged into one Form — sections keep their original header text from each source tab)

    /// Why the calibration button is or isn't available, in that order of
    /// precedence — "no mic attached" is the more fundamental blocker, and
    /// telling someone to stop detecting when they have nothing to detect with
    /// would send them round in a circle.
    private var calibrationFooter: String {
        if !audio.diagnostics.canCalibrate {
            return "Connect your ultrasonic microphone to calibrate it. There's nothing to measure on the phone's built-in mic — it can't hear the frequencies bats call at."
        }
        if audio.isRunning {
            return "Stop detecting first to calibrate."
        }
        return "Corrects for your microphone's own uneven frequency response, flattening the spectrogram's noise floor and sharpening frequency measurements. Takes about 15 seconds in a quiet spot; doesn't change or upload any recording."
    }

    private var pulseMinFreqKHz: Binding<Double> {
        Binding(get: { pulseDetector.minFrequencyHz / 1000 },
                set: { pulseDetector.minFrequencyHz = $0 * 1000 })
    }

    private var audioTab: some View {
        Form {
            hapticSections
            pulseSections
            recordingSections
        }
        .sheet(isPresented: $showMicCalibration) {
            MicCalibrationView(audio: audio, settings: micCalSettings) { showMicCalibration = false }
        }
    }

    /// Pulse haptics. Placed first in the Audio tab because for a user who
    /// can't hear the listening modes this is the *only* live output the app
    /// has, and burying it under the trigger thresholds would say otherwise.
    @ViewBuilder
    private var hapticSections: some View {
        // No Taptic Engine (iPad) — offer nothing rather than a dead switch.
        if haptics.isSupported {
            Section {
                Toggle("Feel each bat pulse", isOn: $haptics.isEnabled)

                if haptics.isEnabled {
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent("Strength") {
                            Text(String(format: "%.0f%%", haptics.strength * 100))
                                .monospacedDigit()
                        }
                        Slider(value: $haptics.strength, in: 0.25...1.5, step: 0.05)
                            .accessibilityLabel("Haptic strength")
                    }

                    Button("Play a sample") { haptics.playPreview() }
                        .disabled(haptics.unavailableReason != nil)
                        .accessibilityHint("Plays three calls of increasing strength, then a feeding buzz")

                    // The honesty path. Low Power Mode kills Core Haptics
                    // outright, and without this the feature just stops — which
                    // for someone relying on it reads as "no bats tonight".
                    if let reason = haptics.unavailableReason {
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Haptics")
            } footer: {
                Text("Every detected call becomes a tap you can feel: stronger for a closer bat, and sharper for a higher-pitched one. When calls come too fast to feel separately — a feeding buzz, when a bat is closing on an insect — the taps merge into one continuous buzz, so that moment feels different rather than just faster.\n\nWorks with the screen off and in demo mode, and doesn't need a listening mode switched on.")
            }
        }
    }

    @ViewBuilder
    private var pulseSections: some View {
        Group {
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


    // MARK: Location sections

    /// Map-pin gates: only session IDs clearing both end up as species pins on the map.
    @ViewBuilder
    private var locationSections: some View {
        Group {
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

    @ViewBuilder
    private var recordingSections: some View {
        Group {
            Section {
                Toggle("Auto-record on session start", isOn: $autoRecordOnSessionStart)
            } header: {
                Text("Recording")
            } footer: {
                Text("When on, starting detection automatically arms the triggered WAV recorder.")
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

            Section {
                if let curve = micCalSettings.curve {
                    Toggle("Apply correction", isOn: $micCalSettings.isEnabled)
                    LabeledContent("Calibrated for", value: curve.micName)
                    LabeledContent("Last calibrated", value: curve.capturedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Button {
                    showMicCalibration = true
                } label: {
                    Text(micCalSettings.curve == nil ? "Calibrate Microphone" : "Recalibrate Microphone")
                }
                .disabled(audio.isRunning || !audio.diagnostics.canCalibrate)
            } header: {
                Text("Microphone Calibration")
            } footer: {
                Text(calibrationFooter)
            }
        }
    }
}
