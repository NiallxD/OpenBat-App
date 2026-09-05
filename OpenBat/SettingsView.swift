//
//  SettingsView.swift
//  OpenBat
//
//  The Settings sheet: three tabs (General / AutoID / Detecting) picked by a
//  segmented control rather than a `TabView`, so only the active tab's `Form`
//  exists at a time.
//
//  **Every card here follows one shape, and it has exactly three parts**
//  (2026-09-02, Niall's call — the cards had grown a description above the
//  control AND a paragraph below it, so the same idea was explained twice at
//  two sizes and the sheet read as a wall of text):
//
//    1. a short NAME, in ordinary words — what a person would call this thing;
//    2. one line of DESCRIPTION under it — **at most ten words, and it must
//       still be one line on the narrowest iPhone**, which in practice means
//       about forty characters;
//    3. the control. A control that needs saying more than its label says gets
//       a `ControlNote`, which is that control's own description and therefore
//       sits ABOVE it, under the same ten-word rule.
//
//  **There is no fourth part.** Nothing goes below the control — no section
//  footer, no trailing paragraph. Whatever a footer was carrying either matters
//  enough to be compressed into the description, or it doesn't matter. The
//  exceptions are the status `Label`s (a failed iCloud move, haptics off in Low
//  Power Mode), which report a condition rather than explain a control, and
//  alert messages, which are read before a decision rather than alongside one.
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
    @Bindable var snippetExpansion: SnippetExpansionSettings
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

                ControlNote("Or follow the phone, which is the default.")
                AppearancePicker()
            } header: {
                // "Nothing is lost" earns its place in ten words: someone who
                // has tuned an advanced control reads a switch that hides
                // controls as destructive, and won't touch it.
                CardHeader("Interface", "How much you see, and how it looks.")
            }

            storageSections
            privacySections
            classifierLogSections
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
                // Of everything the old footer said, this is the half a person
                // decides on. The cost it also carried — bat audio is ~768 KB/s,
                // so a busy night can run to several GB of iCloud quota — has no
                // home at ten words and is not stated anywhere else in the app.
                // If it needs saying, it needs a place that can measure it.
                CardHeader("Storage", "In iCloud they survive deleting the app.")
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
                ControlNote("Unidentified triggers, usually noise.")

                Button("Delete All Sessions", role: .destructive) {
                    showDeleteAllSessionsConfirmation = true
                }
                ControlNote("Sessions, with the recordings inside them.")
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
                // The description says why the switch is dead, because that is
                // the only question this card raises.
                CardHeader("Community science", "No project is running yet.")
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
    /// Read once when the tab appears and after a clear, not on every body
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
            ControlNote("Send a copy when an ID looks wrong.")

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
            ControlNote("The log only. Recordings are untouched.")
        } header: {
            CardHeader("Classifier log", "What OpenBat heard, and when.")
        }
    }

    // The presentations that belong to this card live on the Form in
    // `generalTab`, NOT here. A `.sheet` written on a `Section` is handed down
    // to the section's rows, so the same `shareLogItem` ends up with several
    // presenters bound to it; they race, and the share sheet animates in and
    // straight back out. That — not the alert's dismissal — is why it kept
    // closing itself.

    /// Opens the share sheet a beat after the alert has gone.
    ///
    /// Presenting a sheet while the presentation it was chosen in is still
    /// dismissing gets dropped by SwiftUI, so the share sheet waits the alert
    /// out. Third time this project has hit it: see the guide's "Sources &
    /// licences" button and `SessionsView.reportImport`. The wait alone did not
    /// fix the sheet closing itself here — see the note above the Section.
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
            slowReplaySection
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
    ///
    /// A blocked button is the one case where the reason has to be right there,
    /// so this is the button's `ControlNote` rather than the description: the
    /// card's description can't change with the mic, and a greyed-out button
    /// with no reason beside it reads as a bug.
    private var calibrationNote: String {
        if !audio.diagnostics.canCalibrate {
            return "Plug in your ultrasonic mic to calibrate."
        }
        if audio.isRunning {
            return "Stop detecting first, then calibrate."
        }
        return "Corrects the pitches your mic hears unevenly."
    }

    @ViewBuilder
    private var microphoneSection: some View {
        Section {
            if let curve = micCalSettings.curve {
                Toggle("Apply calibration", isOn: $micCalSettings.isEnabled)
                LabeledContent("Measured for", value: curve.micName)
                LabeledContent("Measured on", value: curve.capturedAt.formatted(date: .abbreviated, time: .shortened))
            }
            ControlNote(calibrationNote)
            Button {
                showMicCalibration = true
            } label: {
                Text(micCalSettings.curve == nil ? "Calibrate Microphone" : "Recalibrate Microphone")
            }
            .disabled(audio.isRunning || !audio.diagnostics.canCalibrate)
        } header: {
            CardHeader("Microphone", "The mic you're listening through.")
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
                    ControlNote("Raise it for gloves, or a pocket.")
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
                // What the taps encode — stronger for a closer bat, sharper for
                // a higher-pitched one, running together into a hum through a
                // feeding buzz — is a paragraph, and it is felt in one press of
                // "Play a sample". The sample button is the explanation now.
                CardHeader("Vibration", "A tap you feel for each call.")
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
                ControlNote("Lower it for faint bats, and more noise.")
                Slider(value: $pulseDetector.amplitudeThreshold, in: 0.1...0.95, step: 0.05)

                if pulseDetector.triggerMode == .ultrasonic {
                    LabeledContent("Lowest pitch") {
                        Text(String(format: "%.0f kHz", pulseDetector.minFrequencyHz / 1000))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ControlNote("Ignored below this. 15–20 kHz clears wind.")
                    Slider(value: pulseMinFreqKHz, in: 5...150, step: 5)
                }
            } header: {
                CardHeader("What counts as a call",
                           "How loud, and how high, to trigger.")
            }

            Section {
                LabeledContent("Shortest call") {
                    Text(shortestCallLabel)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ControlNote("Raise it to reject clicks and pops.")
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
                ControlNote("Shorter quiet patches stay one call.")
                Slider(value: $pulseDetector.maxGapMs, in: 0...30, step: 1)

                LabeledContent("Wait after a call") {
                    Text(String(format: "%.0f ms", pulseDetector.holdOffSeconds * 1000))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ControlNote("Shortest gap between two separate calls.")
                Slider(value: $pulseDetector.holdOffSeconds, in: 0.02...1.0, step: 0.01)
            } header: {
                CardHeader("Telling calls apart",
                           "Stops one call being counted as several.")
            }
            .advancedOnly(simplifiedMode)
        }
    }

    // MARK: Slow replay

    /// Replay speed for the live slow-replay mode, and only the speed. Buffer
    /// length, hiss reduction, fade and gain stay in the live tuning overlay:
    /// those are judged by ear against a pass that is happening right now,
    /// which is what the overlay is for. Speed is decided once and left, so it
    /// belongs where a user goes looking for a setting.
    ///
    /// Three snapped steps, not the overlay's old 4–20 continuum (Niall,
    /// 2026-08-28). The snapping lives in `SnippetExpansionSettings.expansion`
    /// so this card can't be the only thing enforcing it.
    private var slowReplaySteps: [Double] { SnippetExpansionSettings.expansionSteps }

    /// The slider moves in step indices — 8, 10 and 16 aren't evenly spaced, so
    /// a slider over the values themselves couldn't snap to them. The readout
    /// beside it shows the real factor, which is why this needs an explicit
    /// `accessibilityValue`: VoiceOver would otherwise read the index.
    private var slowReplayIndex: Binding<Double> {
        Binding(
            get: {
                let i = slowReplaySteps.firstIndex(of: snippetExpansion.expansion) ?? 0
                return Double(i)
            },
            set: { newIndex in
                let i = min(max(Int(newIndex.rounded()), 0), slowReplaySteps.count - 1)
                snippetExpansion.expansion = slowReplaySteps[i]
                // Settings are pushed into the processor at `start()`, so a
                // change made mid-session would otherwise not be heard until the
                // next run. The processor snapshots its playback parameters at
                // each trigger, so writing it here takes effect on the next
                // replay rather than warping one already sounding.
                audio.snippetExpansion.expansion = snippetExpansion.expansion
            }
        )
    }

    private var slowReplaySpeedLabel: String {
        String(format: "%.0f× slower", snippetExpansion.expansion)
    }

    @ViewBuilder
    private var slowReplaySection: some View {
        Section {
            LabeledContent("Speed") {
                Text(slowReplaySpeedLabel)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ControlNote("Stops listening for about \(Int(snippetExpansion.replaySeconds.rounded())) s each time.")
            Slider(value: slowReplayIndex,
                   in: 0...Double(slowReplaySteps.count - 1),
                   step: 1)
                .accessibilityLabel("Slow replay speed")
                .accessibilityValue(slowReplaySpeedLabel)

            // Volume had no setting at all outside the tuning overlay, and was
            // a fixed multiplier applied to every snippet regardless of how
            // loud the pass was (Niall, 2026-09-01).
            LabeledContent("Volume") {
                Text(String(format: "%+.0f dB", snippetExpansion.trimDB))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ControlNote("Replays are levelled; this shifts them all.")
            Slider(value: Binding(
                get: { snippetExpansion.trimDB },
                set: {
                    snippetExpansion.trimDB = $0
                    // Settings are pushed into the processor at start(), so a
                    // change made mid-session would otherwise not be heard
                    // until the next run — same reasoning as the speed slider.
                    audio.snippetExpansion.trimDB = $0
                }
            ), in: -18...18, step: 1)
                .accessibilityLabel("Replay volume trim")

            Picker("Background", selection: Binding(
                get: { snippetExpansion.denoiseMode },
                set: {
                    snippetExpansion.denoiseMode = $0
                    audio.snippetExpansion.denoiseMode = $0
                }
            )) {
                ForEach(SnippetDenoiseMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            ControlNote("Reduce cuts hiss. Scrub keeps only calls.")
        } header: {
            // The cost of a higher speed is deafness, and from Settings — with
            // no live readout beside it — that is invisible. It used to be a
            // footer; it now rides on the speed slider's own note, which is the
            // only control that changes it and the place a person is looking
            // when they do.
            CardHeader("Slow replay",
                       "How far a call is slowed to hear it.")
        }
    }

    // MARK: Recording

    @ViewBuilder
    private var recordingSections: some View {
        Group {
            Section {
                Toggle("Record automatically", isOn: $autoRecordOnSessionStart)
                ControlNote("Starting detection also arms the recorder.")
            } header: {
                CardHeader("Recording", "When OpenBat saves audio to a file.")
            }

            Section {
                LabeledContent("Keep before a call") {
                    Text(String(format: "%.1f s", recorder.preRollSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ControlNote("Starts this far before the first call.")
                // Upper bound from the recorder, which sizes its pre-roll ring for
                // exactly this — a wider slider here than there would silently cap.
                Slider(value: $recorder.preRollSeconds,
                       in: 0.5...AudioRecorder.maxPreRollSeconds, step: 0.5)

                LabeledContent("Stop after quiet for") {
                    Text(String(format: "%.1f s", recorder.postRollSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ControlNote("Each new call extends the recording.")
                Slider(value: $recorder.postRollSeconds, in: 1.0...10.0, step: 0.5)
            } header: {
                CardHeader("Length of a recording",
                           "One pass should be one file, not many.")
            }
        }
    }
}

// MARK: - Card furniture

/// A settings card's name and its one-line description. See this file's header
/// for the shape every card follows and why.
///
/// **The description is at most ten words and must not wrap on the narrowest
/// iPhone** (Niall, 2026-09-02) — about forty characters. It is the whole
/// explanation the card gets: there is no paragraph under the control any more,
/// so anything that won't compress to one line is something the card has to do
/// without.
///
/// `.textCase(nil)` on the subtitle is load-bearing: a `Form` section header
/// uppercases its content, which is right for the short name above and shouting
/// for a sentence below it.
struct CardHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    /// An optional control on the title's own line — the species list's "Enable
    /// all", and nothing else so far. It goes here rather than in an `HStack`
    /// around the whole header so the description keeps the full width: beside a
    /// button it had about two thirds of it, and a one-line rule that wraps
    /// anyway is not a rule.
    let accessory: Accessory

    init(_ title: String, _ subtitle: String,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 8)
                accessory
            }
            // An empty subtitle draws nothing rather than an empty line: a few
            // cards are a bare name (a species family, a numbered step) and the
            // stack's spacing would otherwise leave them sitting high.
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .textCase(nil)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 2)
    }
}

extension CardHeader where Accessory == EmptyView {
    init(_ title: String, _ subtitle: String) {
        self.init(title, subtitle) { EmptyView() }
    }
}

/// One short line ABOVE a control, saying what moving it does for the reader —
/// the same thing `CardHeader`'s description is for the card, under the same
/// ten-word, one-line rule.
///
/// Above, not below, and inside the card rather than in a section footer: read
/// top to bottom you get the name, what it does, then the thing you touch. A
/// card with three sliders can't explain them all in one footer either, which
/// is how the old sections ended up as paragraphs.
struct ControlNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
