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
    var consent: ConsentStore
    let classStore: ClassificationStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = "autoID"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $selectedTab) {
                    Text("AutoID").tag("autoID")
                    Text("Audio").tag("audio")
                    Text("Location").tag("location")
                    Text("Recordings").tag("recordings")
                    Text("Privacy").tag("privacy")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

                switch selectedTab {
                case "autoID":     AutoIDSettingsView(settings: settings, location: location)
                case "audio":      audioTab
                case "location":   locationTab
                case "recordings": recordingsTab
                default:           privacyTab
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
    @AppStorage("community.recordistName") private var recordistName = ""
    @AppStorage("community.uploadOverWiFiOnly") private var uploadOverWiFiOnly = true
    @AppStorage("community.autoUploadEnabled") private var autoUploadEnabled = false
    @State private var showEraseWarning = false
    @State private var showEraseConfirmation = false
    @State private var showCopiedDeviceID = false

    // MARK: Recordings tab

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

    private var recordingsTab: some View {
        Form {
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
                     ? "Recordings and session history are stored in your own iCloud, so they survive deleting the app and follow you to a new device. They stay in your iCloud account — this is separate from contributing to the community science project, and isn't visible in the Files app. Audio is large: a busy night can use several GB of your iCloud storage."
                     : "Recordings and session history are stored only on this device, and are permanently lost if you delete OpenBat. Nothing is stored in iCloud.")
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
                Text("Permanently deletes every recording (and its WAV file) on this device. Session and pulse-ID history is unaffected. Doesn't touch anything already uploaded.")
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

    private var participationBinding: Binding<Bool> {
        Binding(get: { consent.isGranted },
                set: { newValue in newValue ? consent.grant() : consent.revoke() })
    }

    // MARK: Privacy tab

    private var privacyTab: some View {
        Form {
            Section {
                Toggle("Contribute recordings to the community science project", isOn: participationBinding)
                if consent.isAwaitingServerConfirmation {
                    // Honest about the gap between "saved on this device" and
                    // "the server knows" — this retries by itself, but a
                    // withdrawal in particular shouldn't look complete when the
                    // server hasn't acknowledged it yet.
                    Label("Not yet confirmed by our servers — this will retry automatically when you're online.",
                          systemImage: "arrow.trianglehead.2.clockwise")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("On-device detection and species ID work either way — this only gives OpenBat permission to collect recordings you choose to send. Nothing uploads on its own: pick which recordings to contribute, one at a time, by tapping the cloud icon on an eligible recording in Playback. You can turn this off at any time; it stops future uploads immediately.")
            }

            if consent.isGranted {
                Section {
                    Toggle("Upload automatically", isOn: $autoUploadEnabled)
                } footer: {
                    Text("Off by default, and not the normal way to contribute — recordings are meant to be sent one at a time from Playback. When on, every eligible recording uploads as soon as it's saved instead, subject to the Wi-Fi setting below.")
                }

                Section {
                    Toggle("Upload over Wi-Fi only", isOn: $uploadOverWiFiOnly)
                        .disabled(!autoUploadEnabled)
                } footer: {
                    Text("Uploads use mobile or Wi-Fi data. When on, automatic uploads wait for a Wi-Fi connection instead of using cellular data. Only applies to automatic uploads — tapping a recording's own upload badge always goes ahead regardless.")
                }
            }

            Section {
                TextField("Display name", text: $recordistName)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
            } header: {
                Text("Recordist name")
            } footer: {
                Text("Optional. If set, credited alongside any recordings shared for research or community-science purposes. If left blank, recordings are credited to your device ID instead. This is visible alongside shared recordings, so treat it as a public-facing field even though it's optional.")
            }

            Section {
                LabeledContent("Device ID") {
                    Text(DeviceIdentity.current)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button {
                    UIPasteboard.general.string = DeviceIdentity.current
                    showCopiedDeviceID = true
                } label: {
                    Label("Copy Device ID", systemImage: "doc.on.doc")
                }
            } footer: {
                Text("Identifies your contributions without any personal account. If you'd rather email us to request removal instead of using Erase below, quote this ID.")
            }

            Section {
                Button("Erase All My Data", role: .destructive) {
                    showEraseWarning = true
                }
            } footer: {
                Text("Permanently deletes every recording you've contributed, on our servers — not just future uploads. Separate from the toggle above, and cannot be undone.")
            }
        }
        .alert("Erase All My Data", isPresented: $showEraseWarning) {
            Button("Cancel", role: .cancel) { }
            Button("Continue", role: .destructive) { showEraseConfirmation = true }
        } message: {
            Text("If you just want to stop uploading new recordings, revoke access to this with the toggle. Deleting all data will clear all your historic recordings from our database, removing them from any use in community science. This action cannot be undone.")
        }
        .alert("Copied", isPresented: $showCopiedDeviceID) { } message: {
            Text("Device ID copied to the clipboard.")
        }
        .sheet(isPresented: $showEraseConfirmation) {
            EraseDataConfirmationView(consent: consent, classStore: classStore) { }
        }
    }

    // MARK: Audio tab (formerly separate RTE / Pulse / Audio tabs, merged into
    // one Form — sections keep their original header text from each source tab)

    private var pulseMinFreqKHz: Binding<Double> {
        Binding(get: { pulseDetector.minFrequencyHz / 1000 },
                set: { pulseDetector.minFrequencyHz = $0 * 1000 })
    }

    private var audioTab: some View {
        Form {
            rteSections
            pulseSections
            recordingSections
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

    @ViewBuilder
    private var rteSections: some View {
        Group {
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

    // MARK: Location tab

    /// Map-pin gates: only session IDs clearing both end up as species pins on the map.
    private var locationTab: some View {
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

    @ViewBuilder
    private var recordingSections: some View {
        Group {
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
