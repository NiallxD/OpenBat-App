//
//  SettingsView.swift
//  OpenBat
//
//  The Settings sheet: three tabs (General / AutoID / Detecting) picked by a
//  segmented control rather than a `TabView`, so only the active tab's `Form`
//  exists at a time.
//
//  **Every card here follows one shape** (2026-08-18, Niall's call — the tabs
//  had grown into a heap of sections whose footers explained the implementation
//  rather than the effect):
//
//    1. a short NAME, in ordinary words — what a person would call this thing;
//    2. one line of DESCRIPTION under it saying what the card is for;
//    3. each control as label-and-value, then its one-sentence note, then the
//       control itself. The note sits ABOVE the slider deliberately (Niall,
//       2026-08-18): read top to bottom you get the name, what it does, then the
//       thing you drag — so the explanation arrives before you touch anything
//       rather than after.
//
//  Use `CardHeader` for 1 and 2 and `ControlNote` for 3, so a card added later
//  can't quietly reintroduce the old shape.
//
//  **Plain, not simple.** The reader is an adult using an ultrasonic bat
//  detector, so ordinary technical words are fine — frequency, kHz, calibration,
//  confidence. What is not fine is OUR vocabulary leaking out: no unit a reader
//  hasn't met (columns, magnitude, normalised), no internal noun (threshold,
//  gate, floor, roll) unless the control genuinely is that idea, and no
//  explaining-to-a-child register. Say what changes on screen or in the
//  recording rather than what changes in the maths.
//
//  Sections are `Form`/`Section`, which is what draws the cards — the native
//  grouped inset styling already is a card, and hand-rolling one would give up
//  Dynamic Type, the keyboard avoidance and the system's own Liquid Glass for a
//  rounded rectangle we'd then own forever.
//
//  Two knobs were REMOVED here rather than reworded: the playback noise floor
//  (the WAV player has had its own live slider for it for a while, so Settings
//  was the second, worse copy — the default lives at that slider now) and the CF tail fraction (a research
//  parameter with no lay meaning, now fixed at `CallAnalysis.defaultCFTailFraction`).
//  Neither had a sentence that could be written honestly for a general user.
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
                //
                // The third tab is "Detecting", not "Audio" — it holds the mic,
                // the taps, what counts as a call and what gets recorded, and
                // only one of those is about sound.
                Picker("Section", selection: $selectedTab) {
                    Text("General").tag("general")
                    Text("AutoID").tag("autoID")
                    Text("Detecting").tag("audio")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

                switch selectedTab {
                case "autoID":  AutoIDSettingsView(settings: settings, location: location)
                case "audio":   detectingTab
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

    /// The app-wide interface mode. `true` hides the readouts and controls that
    /// only mean something once you already know what they are — see
    /// `SimplifiedView` for the full list and the reasoning.
    ///
    /// It gates ONE card in this sheet — "Telling calls apart" — and the choice
    /// of which follows `SimplifiedView`'s own precedent for the band button:
    /// a control stays visible in simplified view when it genuinely needs
    /// tweaking in the field. Loudness and lowest pitch are the first things to
    /// reach for when nothing is triggering, and recording length is plain
    /// English, so all three stay. Minimum duration / gap bridging / hold-off do
    /// not — they need a spectrogram in front of you to set meaningfully, and
    /// they are the definition of what that mode exists to hide.
    ///
    /// Hiding is safe here in the way `SimplifiedView` requires. Its rule is
    /// that a hidden control's state must be OVERRIDDEN or the user is stranded;
    /// the exception it already documents is a hidden control whose state has
    /// another route back. That route here is the Advanced switch at the top of
    /// this same sheet's first tab. Overriding would be actively wrong: these
    /// values decide what gets detected at all, so silently substituting
    /// different ones in simplified mode would change what the app hears without
    /// saying so.
    @AppStorage(SimplifiedView.key) private var simplifiedMode = true

    // MARK: - General

    /// Least destructive first, so the bulk deletes stay well below the fold.
    private var generalTab: some View {
        Form {
            Section {
                // Labelled and bound as "Advanced mode", inverted from
                // `simplifiedMode` itself: simplified is the app's default, so
                // off is the state the toggle rests in until someone opts into
                // more. `simplifiedMode` elsewhere in the codebase keeps its own
                // polarity — only this control's presentation is flipped.
                Toggle("Advanced mode", isOn: Binding(
                    get: { !simplifiedMode },
                    set: { simplifiedMode = !$0 }
                ))
            } header: {
                CardHeader("Interface", "How much of the app you see at once.")
            } footer: {
                // Says what the user will SEE, and — the part that matters —
                // that nothing is being thrown away. Someone who has tuned an
                // advanced control and then turns this on needs to know their
                // settings are still there, or the switch reads as destructive
                // and they won't touch it.
                Text(simplifiedMode
                     ? "You're seeing the simple screen: the species name, the level meter and the spectrogram. Turn this on to add the call close-up, the measurements, the timeline and palette controls, and a few finer detection settings. Nothing is deleted either way — whatever you've set is still there when you switch back."
                     : "You're seeing everything. Turn this off for a plainer screen: just the species name, the level meter and the spectrogram.")
            }

            storageSections
            privacySections
            classifierLogSections
        }
        .onChange(of: keepInICloud) { _, _ in showRestartNeeded = true }
        .alert("Restart OpenBat to finish", isPresented: $showRestartNeeded) {
            Button("OK") { }
        } message: {
            Text("Your existing recordings are moved the next time OpenBat starts. Until then they stay where they are — nothing is lost either way.")
        }
        .sheet(isPresented: $showDeleteAllSessionsConfirmation) {
            DeleteAllSessionsConfirmationView(classStore: classStore) { }
        }
        .confirmationDialog("Delete every NoID recording?",
                            isPresented: $showDeleteNoIDConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { classStore.deleteNoIDRecordings() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This can't be undone.")
        }
    }

    // MARK: Storage

    /// Changing this doesn't move anything immediately — the migration runs at
    /// next launch (see `CloudStorage.applyPendingStorageMigration`), so the
    /// alert above tells the user that rather than leaving them to wonder.
    @AppStorage(CloudStorage.keepInICloudKey) private var keepInICloud = true
    @State private var showRestartNeeded = false

    @State private var showDeleteAllSessionsConfirmation = false
    @State private var showDeleteNoIDConfirm = false

    @ViewBuilder
    private var storageSections: some View {
        Group {
            Section {
                Toggle("Keep recordings in iCloud", isOn: $keepInICloud)
            } header: {
                CardHeader("Storage", "Where your recordings and session history are kept.")
            } footer: {
                // Deliberately explicit about both the benefit and the cost:
                // audio is ~768 KB/s at 384 kHz, so a busy night can run to
                // several GB against the user's iCloud quota — and they'd
                // otherwise have no way to connect that to OpenBat.
                Text(keepInICloud
                     ? "They survive deleting the app and follow you to a new device. They stay in your own iCloud and don't appear in the Files app. Bat audio is large — a busy night can use several GB of your iCloud storage."
                     : "They're on this device only, and are lost for good if you delete OpenBat. Nothing is kept in iCloud.")
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

            // Two bulk deletes, and deliberately only two (Niall's call,
            // 2026-08-17). A "low confidence" prune sat between them, keyed to a
            // 57% threshold nobody could see or change — a number that decides
            // what gets destroyed has no business being invisible. Pruning junk
            // is what NoID is for; anything finer is a judgement call that
            // belongs on the individual recording, where the swipe already is.
            //
            // One card now rather than two, since they are the same job at two
            // sizes; ordered least destructive first, per this tab's rule.
            Section {
                Button("Delete NoID Recordings", role: .destructive) {
                    showDeleteNoIDConfirm = true
                }
                ControlNote("Everything that triggered but couldn't be identified — usually noise. Species IDs and sessions are untouched.")

                Button("Delete All Sessions", role: .destructive) {
                    showDeleteAllSessionsConfirmation = true
                }
                ControlNote("Every session on this device, with the IDs and recordings inside it. Recordings not in a session are kept — delete those individually in Sessions.")
            } header: {
                CardHeader("Deleting in bulk", "Neither of these can be undone.")
            }
        }
    }

    // MARK: Community science

    @ViewBuilder
    private var privacySections: some View {
        Group {
            Section {
                Toggle("Contribute my recordings", isOn: .constant(false))
                    .disabled(true)
            } header: {
                CardHeader("Community science", "Sharing what you record with researchers.")
            } footer: {
                Text("No project is running at the moment, so there's nothing to share with yet. Check back soon.")
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

    // MARK: Classifier log

    @State private var showShareLogConfirm = false
    @State private var shareLogItem: ShareItem?
    @State private var logCleared = false
    /// Read once when the card appears and after a clear, not on every body
    /// pass — measuring it touches the logger's queue and the filesystem.
    @State private var logBytes = 0

    private struct ShareItem: Identifiable { let id = UUID(); let url: URL }

    /// Out of the Debug sheet and into ordinary settings (2026-08-26). The log
    /// is the one thing a user can send that explains *why* OpenBat called
    /// something what it called it, so a bug report is worth far more with it
    /// attached — and nobody finds it behind a debug build.
    @ViewBuilder
    private var classifierLogSections: some View {
        Section {
            LabeledContent("Size on this device", value: logSizeText)
                .font(.callout)

            Button {
                showShareLogConfirm = true
            } label: {
                Label("Share Log", systemImage: "square.and.arrow.up")
            }
            ControlNote("Sends a zipped copy. Useful if you're reporting an identification that looks wrong.")

            Button(role: .destructive) {
                ClassificationLogger.shared.clearLog()
                logCleared = true
                // The clear runs on the logger's own queue, so re-read a beat
                // later or the size still shows the old file.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    logBytes = ClassificationLogger.shared.totalBytesOnDisk()
                }
            } label: {
                Label(logCleared ? "Cleared" : "Clear Log", systemImage: "trash")
            }
            ControlNote("Deletes the log only. Your recordings, sessions and species IDs are untouched.")
        } header: {
            CardHeader("Classifier log", "A running record of what OpenBat thought it heard.")
        } footer: {
            Text("Every detection is written down with its date and time, the species OpenBat picked, and how each species scored. It's kept on this device and never sent anywhere on its own.")
        }
        .onAppear { logBytes = ClassificationLogger.shared.totalBytesOnDisk() }
        // The share sheet is deliberately behind a confirmation. The log is a
        // dated diary of every night you were out listening — on its own that
        // says a good deal about where somebody was and when, and roosts are
        // exactly the thing bat workers don't publish. It has to be a decision,
        // not a tap.
        //
        // An alert, not a confirmation dialog: a dialog is an action sheet, and
        // on an iPad it arrives as a popover hanging off the row — which is the
        // presentation for "pick one of these", not for "read this, then decide".
        .alert("Share your classifier log?", isPresented: $showShareLogConfirm) {
            Button("Share") { shareLogAfterDismissal() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The log records the date and time of every detection and what OpenBat identified — enough for someone reading it to work out when, and roughly where, you were listening. It doesn't include your recordings or your exact location. Only share it with someone you trust.")
        }
        .sheet(item: $shareLogItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    /// Opens the share sheet a beat after the alert has gone.
    ///
    /// **The wait is why the share sheet stopped appearing and then vanishing.**
    /// Presenting a sheet while the presentation it was chosen in is still
    /// dismissing gets dropped by SwiftUI — here it got far enough to animate in
    /// before the alert's own dismissal tore it straight back out. Third time
    /// this project has hit it: see the guide's "Sources & licences" button and
    /// `SessionsView.reportImport`.
    private func shareLogAfterDismissal() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            shareLogItem = ShareItem(url: ClassificationLogger.shared.makeShareItem())
        }
    }

    private var logSizeText: String {
        if logBytes == 0 { return "empty" }
        if logBytes < 1024 { return "\(logBytes) B" }
        if logBytes < 1024 * 1024 { return String(format: "%.0f KB", Double(logBytes) / 1024) }
        return String(format: "%.1f MB", Double(logBytes) / (1024 * 1024))
    }

    // MARK: - Detecting

    /// Ordered as the signal travels: the microphone that hears it, the tap you
    /// feel when it does, what has to be true before OpenBat calls it a bat, and
    /// what ends up in a file.
    private var detectingTab: some View {
        Form {
            microphoneSection
            hapticSections
            triggerSections
            recordingSections
        }
        .sheet(isPresented: $showMicCalibration) {
            MicCalibrationView(audio: audio, settings: micCalSettings) { showMicCalibration = false }
        }
    }

    // MARK: Microphone

    /// Why the calibration button is or isn't available, in that order of
    /// precedence — "no mic attached" is the more fundamental blocker, and
    /// telling someone to stop detecting when they have nothing to detect with
    /// would send them round in a circle.
    private var calibrationFooter: String {
        if !audio.diagnostics.canCalibrate {
            return "Plug in your ultrasonic microphone to calibrate it. There's nothing to measure on the phone's own mic — it can't hear the frequencies bats call at."
        }
        if audio.isRunning {
            return "Stop detecting first, then calibrate."
        }
        return "Every microphone hears some pitches louder than others, which shows up as faint horizontal stripes on the spectrogram and biases frequency measurements. Calibrating measures yours in a quiet spot — about 15 seconds — and corrects for it. This affects what you see and measure, never what gets recorded."
    }

    @ViewBuilder
    private var microphoneSection: some View {
        Section {
            if let curve = micCalSettings.curve {
                Toggle("Apply calibration", isOn: $micCalSettings.isEnabled)
                LabeledContent("Measured for", value: curve.micName)
                LabeledContent("Measured on", value: curve.capturedAt.formatted(date: .abbreviated, time: .shortened))
            }
            Button {
                showMicCalibration = true
            } label: {
                Text(micCalSettings.curve == nil ? "Calibrate Microphone" : "Recalibrate Microphone")
            }
            .disabled(audio.isRunning || !audio.diagnostics.canCalibrate)
        } header: {
            CardHeader("Microphone", "The ultrasonic mic OpenBat is listening through.")
        } footer: {
            Text(calibrationFooter)
        }
    }

    // MARK: Haptics

    /// Placed high in this tab because for a user who can't hear the listening
    /// modes this is the *only* live output the app has, and burying it under
    /// the trigger controls would say otherwise.
    @ViewBuilder
    private var hapticSections: some View {
        // No Taptic Engine (iPad) — offer nothing rather than a dead switch.
        if haptics.isSupported {
            Section {
                Toggle("Tap for every call", isOn: $haptics.isEnabled)

                if haptics.isEnabled {
                    LabeledContent("Strength") {
                        Text(String(format: "%.0f%%", haptics.strength * 100))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ControlNote("Scales every tap. Raise it if you're wearing gloves or carrying the phone in a pocket.")
                    Slider(value: $haptics.strength, in: 0.25...1.5, step: 0.05)
                        .accessibilityLabel("Vibration strength")

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
                CardHeader("Vibration", "A tap you feel for each call, instead of one you hear.")
            } footer: {
                Text("Stronger for a closer bat, sharper for a higher-pitched one. When calls come too fast to feel apart — a feeding buzz, as a bat closes on an insect — the taps run together into a hum, so that moment feels different rather than just quicker.\n\nWorks with the screen off, and doesn't need a listening mode switched on.")
            }
        }
    }

    // MARK: What counts as a call

    private var pulseMinFreqKHz: Binding<Double> {
        Binding(get: { pulseDetector.minFrequencyHz / 1000 },
                set: { pulseDetector.minFrequencyHz = $0 * 1000 })
    }

    /// Milliseconds one detector column covers, so "shortest call" can be shown
    /// in a unit a person has met. 256 is `SpectrogramProcessor`'s default hop
    /// and isn't reachable statically from here; this is a label, and nothing
    /// computes anything from it.
    private var columnMs: Double {
        let rate = audio.activeSampleRate > 0 ? audio.activeSampleRate : 384_000
        return 256 / rate * 1000
    }

    /// Shown beside the slider and read out by VoiceOver — one source, so the
    /// two can't disagree.
    private var shortestCallLabel: String {
        String(format: "%.1f ms", Double(pulseDetector.minConsecutiveColumns) * columnMs)
    }

    @ViewBuilder
    private var triggerSections: some View {
        Group {
            Section {
                Picker("Mode", selection: $pulseDetector.triggerMode) {
                    ForEach(PulseDetector.TriggerMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                ControlNote(pulseDetector.triggerMode.description)

                LabeledContent("Loudness") {
                    Text(String(format: "%.2f", pulseDetector.amplitudeThreshold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ControlNote("Matches the brightness scale on the spectrogram, so anything that looks brighter than this will trigger. Lower it for faint, distant bats — and more noise with them.")
                Slider(value: $pulseDetector.amplitudeThreshold, in: 0.1...0.95, step: 0.05)

                if pulseDetector.triggerMode == .ultrasonic {
                    LabeledContent("Lowest pitch") {
                        Text(String(format: "%.0f kHz", pulseDetector.minFrequencyHz / 1000))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ControlNote("Anything below this is ignored however loud it is. 15–20 kHz clears wind and handling noise; raise it to target only the higher-pitched species.")
                    Slider(value: pulseMinFreqKHz, in: 5...150, step: 5)
                }
            } header: {
                CardHeader("What counts as a call",
                           "How loud, and how high, before OpenBat reacts.")
            }

            Section {
                LabeledContent("Shortest call") {
                    Text(shortestCallLabel)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ControlNote("How long a sound must last to count as a call. Raise it to reject clicks and pops.")
                // The detector counts whole analysis columns, but nobody thinks
                // in columns, so the slider moves in columns (step 1, the only
                // values that exist) while the readout is milliseconds. That
                // split is why this one needs an explicit `accessibilityValue`:
                // without it VoiceOver reads the raw "3" and disagrees with the
                // label right beside it.
                Slider(value: Binding(get: { Double(pulseDetector.minConsecutiveColumns) },
                                      set: { pulseDetector.minConsecutiveColumns = Int($0.rounded()) }),
                       in: 1...10, step: 1)
                    .accessibilityLabel("Shortest call")
                    .accessibilityValue(shortestCallLabel)

                LabeledContent("Join gaps up to") {
                    Text(String(format: "%.0f ms", pulseDetector.maxGapMs))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ControlNote("A call can dip quiet partway through. Quiet patches shorter than this stay part of the same call — raise it if one call is being counted as several.")
                Slider(value: $pulseDetector.maxGapMs, in: 0...30, step: 1)

                LabeledContent("Wait after a call") {
                    Text(String(format: "%.0f ms", pulseDetector.holdOffSeconds * 1000))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ControlNote("The shortest gap accepted between two separate calls. 30 ms keeps up with a feeding buzz; raise it if echoes are being counted as extra calls.")
                Slider(value: $pulseDetector.holdOffSeconds, in: 0.02...1.0, step: 0.01)
            } header: {
                CardHeader("Telling calls apart",
                           "Stops one call being counted several times, and clicks being counted at all.")
            }
            .advancedOnly(simplifiedMode)
        }
    }

    // MARK: Recording

    @ViewBuilder
    private var recordingSections: some View {
        Group {
            Section {
                Toggle("Record automatically", isOn: $autoRecordOnSessionStart)
                ControlNote("Starting detection also arms the recorder, so a bat that passes while you aren't watching is still saved.")
            } header: {
                CardHeader("Recording", "When OpenBat saves audio to a file.")
            }

            Section {
                LabeledContent("Keep before a call") {
                    Text(String(format: "%.1f s", recorder.preRollSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ControlNote("The recording reaches back this far before the first call, so the approach isn't lost.")
                // Upper bound from the recorder, which sizes its pre-roll ring for
                // exactly this — a wider slider here than there would silently cap.
                Slider(value: $recorder.preRollSeconds,
                       in: 0.5...AudioRecorder.maxPreRollSeconds, step: 0.5)

                LabeledContent("Stop after quiet for") {
                    Text(String(format: "%.1f s", recorder.postRollSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ControlNote("Each new call extends the recording, so it closes only once nothing has been heard for this long.")
                Slider(value: $recorder.postRollSeconds, in: 1.0...10.0, step: 0.5)
            } header: {
                CardHeader("Length of a recording",
                           "One bat passing several times should be one file, not many.")
            }
        }
    }
}

// MARK: - Card furniture

/// A settings card's name and its one-line description. See this file's header
/// for the shape every card follows and why.
///
/// `.textCase(nil)` on the subtitle is load-bearing: a `Form` section header
/// uppercases its content, which is right for the short name above and shouting
/// for a sentence below it.
struct CardHeader: View {
    let title: String
    let subtitle: String

    init(_ title: String, _ subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(subtitle)
                .font(.caption)
                .textCase(nil)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }
}

/// One plain sentence under a control, saying what moving it does for the
/// reader. Sits inside the card rather than in the section footer so it stays
/// attached to its own control — a card with three sliders can't explain them
/// all in one footer, which is how the old sections ended up with paragraphs.
struct ControlNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
