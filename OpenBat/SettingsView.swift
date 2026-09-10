//
//  SettingsView.swift
//  OpenBat
//
//  The Settings sheet: three tabs (General / AutoID / Detecting) picked by a
//  segmented control rather than a `TabView`, so only the active tab's `Form`
//  exists at a time.
//
//  **Every card here is a name, one line of description, and rows** (Niall,
//  2026-09-02, amended 2026-09-09):
//
//    1. a short NAME, in ordinary words — what a person would call this thing;
//    2. one line of DESCRIPTION under it — **at most ten words, and it must
//       still be one line on the narrowest iPhone**, which in practice means
//       about forty characters;
//    3. rows. **A row is the option's name and the thing you touch, and
//       nothing else** — a toggle, a button, a picker, a slider's readout.
//
//  Anything more to say about a control goes behind the ⓘ on its own name
//  (`SettingName`/`SettingInfo`), not in grey type beside it. The old shape put
//  a line above every control, so a card with four controls carried four
//  explanations and a page of cards read as a wall of small type — "it makes
//  the settings menus look so messy", which is exactly what it did. The rule
//  the notes lived under (ten words, one line) goes with them: a popover can
//  say the whole thing, and several of those notes had been cut to the point of
//  saying nothing.
//
//  Use `CardHeader` for 1 and 2, and `SettingRow`/`SettingToggle`/`SettingValue`
//  for 3, so a card added later can't quietly reintroduce the old shape.
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
    @Bindable var heterodyne: HeterodyneSettings
    /// Remote kill switches, so the configuration card can show and override
    /// them — see `FeatureFlags.swift`.
    let flags: FeatureFlagStore
    /// Opens the configuration menu, which lives in `ContentView` because it
    /// needs the demo feed and the tuning overlay. Settings only asks.
    let onOpenConfig: () -> Void
    @State private var showMicCalibration = false
    /// Passcode entry for the configuration card. Not persisted — the unlock
    /// itself is, so this is only ever in memory while somebody is typing.
    @State private var configPasscode = ""
    @State private var configPasscodeWrong = false
    @AppStorage("configMenuUnlocked") private var configUnlocked = false
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = "general"
    /// The two halves of the reset: the confirmation before it, and the notice
    /// after it — see `resetSection`.
    @State private var confirmingReset = false
    @State private var resetDone = false

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
                case "autoID":  AutoIDSettingsView(flags: flags, settings: settings, location: location)
                case "audio":   detectingTab
                default:        generalTab
                }
            }
            // **The strip above the tabs is part of the form's page** (Niall,
            // 2026-09-06). The picker sits outside the `Form`, so it was drawn
            // on the sheet's own `systemBackground` while everything below it
            // was on the grouped ground a form paints for itself — white
            // against grey in light mode, and a visible band across the top of
            // the sheet.
            //
            // Matched in this direction, and not by moving the form onto the
            // app's own page: a form's page and its section cards are a pair
            // (`systemGroupedBackground` behind `secondarySystemGroupedBackground`)
            // and repainting the page leaves every settings card white on
            // white. See `View.pageBackground()`.
            .background(Color(.systemGroupedBackground))
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
            // **First card, and only when there is one** (Niall, 2026-09-06).
            // The launch alert shows once per message by design — twenty-one
            // alerts for a three-week outage is an alert nobody reads — and
            // that design assumed the text stayed findable somewhere
            // afterwards. It did not: the only other copy was inside the
            // passcode-locked config menu, so anybody who tapped OK, or who
            // installed the app mid-outage and got the notice while a sheet was
            // covering it, had no way back to the explanation for why half the
            // app was missing.
            if let message = flags.maintenanceMessage {
                Section {
                    Text(message)
                        .font(.callout)
                } header: {
                    CardHeader("Maintenance", "Why something is unavailable.")
                }
            }

            // The quiet counterpart to the maintenance message: same reach,
            // none of the interruption. A maintenance notice explains why part
            // of the app is missing and has earned a launch alert; this one is
            // for everything worth telling everybody that is not worth stopping
            // them to say — a known issue, a release note, a thank-you — so it
            // simply stands here while the config file says something.
            if let notice = flags.notice {
                Section {
                    Text(notice)
                        .font(.callout)
                } header: {
                    CardHeader("Notice", "From the OpenBat team.")
                }
            }

            Section {
                // Labelled and bound as "Advanced mode", inverted from
                // `simplifiedMode` itself: simplified is the app's default, so
                // off is the state the toggle rests in until someone opts into
                // more. `simplifiedMode` elsewhere in the codebase keeps its own
                // polarity — only this control's presentation is flipped.
                SettingToggle("Advanced mode",
                              "Shows every control OpenBat has. Simplified is the default: it hides the "
                            + "tuning controls and picks sensible values for them. Nothing is lost either "
                            + "way — a setting you changed in advanced mode is still there when you come back.",
                              isOn: Binding(
                    get: { !simplifiedMode },
                    set: { simplifiedMode = !$0 }
                ))

                // The picker is the full width of the row, so its name sits
                // above it rather than beside it — the same shape as a slider's.
                SettingName("Appearance", "Light or dark, or follow the phone, which is the default.")
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
            resetSection
            configurationSection
            configFetchFooter
        }
        // `.task`, not `.onAppear`: reading the log size touches the logger's
        // own queue, and doing that synchronously here stalled the sheet's
        // presentation — see `ClassificationLogger.totalBytesOnDisk`.
        .task { logBytes = await ClassificationLogger.shared.totalBytesOnDisk() }
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
    /// Everything back to how a fresh install has it.
    ///
    /// **Last card but one, destructive role, and behind a confirmation.** It
    /// undoes a lot of small decisions at once and there is no undo for it —
    /// the same shape as "Delete NoID Recordings" in Storage, for the same
    /// reason.
    ///
    /// The list under the button is the point of the card. Somebody about to
    /// press this is worried about what else goes with it, and the honest
    /// answer — nothing you have recorded — is worth more than any warning.
    private var resetSection: some View {
        Section {
            HStack {
                Button("Reset all settings", role: .destructive) { confirmingReset = true }
                Spacer(minLength: 12)
                SettingInfo(title: "Reset all settings",
                            note: "Puts every setting back to the value a new install has. "
                                + "Your recordings, sessions and log are untouched, and so are "
                                + "your iNaturalist sign-in and your microphone calibration.")
            }
            .buttonStyle(.borderless)
        } header: {
            CardHeader("Reset", "Back to the settings a new install has.")
        }
        .confirmationDialog("Reset all settings?", isPresented: $confirmingReset,
                            titleVisibility: .visible) {
            Button("Reset Settings", role: .destructive) { resetAllSettings() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Every setting goes back to its default. Nothing you have recorded is deleted.")
        }
        .alert("Settings reset", isPresented: $resetDone) {
            Button("OK") { }
        } message: {
            // **Says to reopen, because some of it genuinely needs that**
            // (Niall, 2026-09-06). The stores that can be re-seeded in place are
            // re-seeded below, but `PulseDetector` reads its tuning once in
            // `init` and writes on change, so its live values would otherwise be
            // written back over the defaults this just restored. Promising a
            // clean slate and delivering most of one is the failure worth
            // avoiding here — especially for the reason this button exists,
            // which is making two devices agree.
            Text("Close and reopen OpenBat to finish putting everything back.")
        }
    }

    /// Clears the preferences, then re-seeds the stores that can re-read them
    /// without a relaunch — see `SettingsReset` for what is deliberately kept.
    private func resetAllSettings() {
        SettingsReset.eraseUserPreferences()
        // Before anything else: this sheet's Done writes `settings` back out, so
        // an AutoIDSettings still holding the old values in memory would undo
        // half of this on the way out. `loadPersisted()` cannot do that job —
        // it refuses to run twice, and after an erase there is nothing left to
        // read anyway. See `reloadAfterReset`.
        settings.reloadAfterReset()
        haptics.resetToDefaults()
        snippetExpansion.reset()
        heterodyne.reset()
        recorder.resetToDefaults()
        resetDone = true
    }



    /// The way into the configuration menu.
    ///
    /// **In Settings, not behind fifteen taps on the version number** (Niall,
    /// 2026-09-06). A menu hidden behind a gesture is the shape of Apple's
    /// guideline on undocumented features, and the hiding bought nothing — the
    /// people it kept out were the people it was for. Visible, explained, and
    /// behind a passcode is both more honest and more effective. The bat swarm
    /// on the tenth tap stays; it was always the better half of that gesture.
    ///
    /// The card disappears entirely when the config file locks it, which is the
    /// recourse if the passcode ever circulates — see
    /// `FeatureFlagStore.configMenuAvailable`.
    @ViewBuilder
    private var configurationSection: some View {
        if flags.configMenuAvailable {
            Section {
                if configUnlocked {
                    Button("Open configuration") { onOpenConfig() }
                    Button("Lock again") {
                        configUnlocked = false
                        configPasscode = ""
                    }
                    .foregroundStyle(.secondary)
                } else {
                    SecureField("Passcode", text: $configPasscode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(unlockConfig)
                    if configPasscodeWrong {
                        Text("That passcode isn't right.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Button("Unlock", action: unlockConfig)
                        .disabled(configPasscode.isEmpty)
                }
            } header: {
                CardHeader("Configuration", ConfigMenu.explanation)
            }
        }
    }

    /// When the app last managed to download the config file — the kill
    /// switches, the two messages and the remotely-set defaults all arrive in
    /// it (`FeatureFlagStore`).
    ///
    /// **Unadorned text at the foot of the form, not a card.** It answers a
    /// question rather than offering a control, and the question is one only
    /// this line can answer: a remote switch that has silently stopped arriving
    /// looks exactly like a switch nobody ever threw. A date here says which.
    ///
    /// Deliberately outside the passcode-locked configuration card, and phrased
    /// without naming any of the machinery: to a user this is "is my app in
    /// touch", which is worth knowing whether or not they know what a feature
    /// flag is.
    @ViewBuilder
    private var configFetchFooter: some View {
        Section {
            Text(configFetchText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    private var configFetchText: String {
        guard let fetched = flags.lastFetch else {
            // Not an error, and not phrased as one: a phone that has never had
            // signal since installing is running the app exactly as it shipped,
            // which is the safe state and needs no alarm.
            return "OpenBat hasn't checked for updated settings yet. It's running the settings it shipped with."
        }
        let stamp = fetched.formatted(date: .abbreviated, time: .shortened)
        if flags.lastRefreshError != nil {
            return "Settings last updated \(stamp). Today's check didn't get through, so these are the last ones received."
        }
        return "Settings last updated \(stamp)."
    }

    private func unlockConfig() {
        if ConfigPasscode.accepts(configPasscode) {
            configUnlocked = true
            configPasscodeWrong = false
            configPasscode = ""
        } else {
            configPasscodeWrong = true
        }
    }

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
                HStack {
                    Button("Delete NoID Recordings", role: .destructive) {
                        showDeleteNoIDConfirm = true
                    }
                    Spacer(minLength: 12)
                    SettingInfo(title: "Delete NoID Recordings",
                                note: "Deletes the recordings nothing was identified in — triggers that "
                                    + "turned out to be noise. The pass log is kept, so your record of "
                                    + "what was heard survives even where the audio doesn't.")
                }
                .buttonStyle(.borderless)

                HStack {
                    Button("Delete All Sessions", role: .destructive) {
                        showDeleteAllSessionsConfirmation = true
                    }
                    Spacer(minLength: 12)
                    SettingInfo(title: "Delete All Sessions",
                                note: "Deletes every session and the recordings inside them. Recordings "
                                    + "that are not part of a session are left alone.")
                }
                .buttonStyle(.borderless)
            } header: {
                CardHeader("Deleting in bulk", "Neither of these can be undone.")
            }
        }
    }

    // MARK: Community science

    @ViewBuilder
    private var privacySections: some View {
        Group {
            iNaturalistSection

            Section {
                Toggle("Contribute my recordings", isOn: .constant(false))
                    .disabled(true)
            } header: {
                // The description says why the switch is dead, because that is
                // the only question this card raises.
                CardHeader("Community science", "No project is running yet.")
            }

            // The iNaturalist account lives in the privacy tab rather than
            // next to the export settings because the question it answers is
            // "what does OpenBat have of mine, and how do I take it back" —
            // which is a privacy question, not a sharing one.

            // Device ID / consent erasure are hidden while contribution is
            // disabled (ConsentStore.uploadContributionEnabled == false):
            // consent can never be granted, so no record ever exists to erase,
            // and with the backend severed (UploadClient/ConsentAPIClient
            // baseURL == "") the Erase call would always fail with a
            // connection-style error that misrepresents a deliberate,
            // permanent severance as a network hiccup.
        }
    }

    // MARK: iNaturalist

    @State private var inatAuth = INatAuth.shared

    /// Sign-out only. Signing IN happens on the observation sheet, where there
    /// is a reason to do it; an account row in Settings that asks for a login
    /// before the user has anything to post is a wall in front of a feature
    /// they haven't met yet.
    @State private var inatLogCopied = false

    @ViewBuilder
    private var iNaturalistSection: some View {
        if inatAuth.isSignedIn {
            Section {
                HStack {
                    Button {
                        UIPasteboard.general.string = INatLog.shared.text
                        inatLogCopied = true
                    } label: {
                        Label(inatLogCopied ? "Copied" : "Copy the iNaturalist log",
                              systemImage: inatLogCopied ? "checkmark" : "doc.on.doc")
                    }
                    Spacer(minLength: 12)
                    // Sits with the account rather than with the classifier log
                    // because the two answer different questions: that one is
                    // "why did OpenBat call it that", this one is "why wouldn't
                    // it post".
                    SettingInfo(title: "The iNaturalist log",
                                note: "What was sent to iNaturalist and what came back, so a post that "
                                    + "was refused can be explained. No tokens, and locations are rounded.")
                }
                .buttonStyle(.borderless)

                HStack {
                    Button("Sign out of iNaturalist", role: .destructive) {
                        inatAuth.signOut()
                    }
                    Spacer(minLength: 12)
                    SettingInfo(title: "Sign out of iNaturalist",
                                note: "Observations you've already posted stay on iNaturalist — this only "
                                    + "forgets the credential on this phone. You can also revoke OpenBat "
                                    + "from your iNaturalist account settings, which stops it working even "
                                    + "if the phone is lost.")
                }
                .buttonStyle(.borderless)
            } header: {
                // **The card stays when posting is switched off, and only its
                // description changes** (Niall, 2026-09-06). Everything in it
                // is account and privacy — the log, and signing out — and
                // taking those away would leave somebody signed in to a service
                // with no way to sign out of it. What does change is the line
                // promising OpenBat posts when you tap Post, which is not true
                // while there is nothing to tap.
                CardHeader("iNaturalist", flags.isEnabled(.iNaturalistUpload)
                           ? "Signed in. OpenBat only ever posts when you tap Post."
                           : "Signed in. Posting is switched off at the moment.")
            }
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
            SettingValue("Size on this device", value: logSizeText)

            HStack {
                Button {
                    showShareLogConfirm = true
                } label: {
                    Label("Share Log", systemImage: "square.and.arrow.up")
                }
                Spacer(minLength: 12)
                SettingInfo(title: "Share Log",
                            note: "Send a copy when an identification looks wrong — it is what OpenBat "
                                + "heard and what it decided, which is the only way the model can be "
                                + "checked against a bat you know. Read the warning before you share it.")
            }
            .buttonStyle(.borderless)

            HStack {
                Button(role: .destructive) {
                    ClassificationLogger.shared.clearLog()
                    logCleared = true
                    // The clear runs on the logger's own queue, so re-read a beat
                    // later or the size still shows the old file.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        logBytes = await ClassificationLogger.shared.totalBytesOnDisk()
                    }
                } label: {
                    Label(logCleared ? "Cleared" : "Clear Log", systemImage: "trash")
                }
                Spacer(minLength: 12)
                SettingInfo(title: "Clear Log",
                            note: "Deletes the log only. Your recordings, sessions and identifications "
                                + "are untouched — this is the diary of what the classifier did, not the "
                                + "record of what you heard.")
            }
            .buttonStyle(.borderless)
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
            detectorSection
            microphoneSection
            hapticSections
            triggerSections
            liveListeningSection
            recordingSections
        }
        .sheet(isPresented: $showMicCalibration) {
            MicCalibrationView(audio: audio, settings: micCalSettings) { showMicCalibration = false }
        }
    }

    // MARK: Microphone

    /// Why the calibration button is unavailable, in order of precedence — "no
    /// mic attached" is the more fundamental blocker, and telling someone to
    /// stop detecting when they have nothing to detect with would send them
    /// round in a circle. `nil` when the button works.
    ///
    /// **A blocked button is the one case where the reason stays on screen**,
    /// so this is a status line under the button rather than something behind
    /// its ⓘ: a greyed-out button with no reason beside it reads as a bug, and
    /// nobody taps an ⓘ to ask why nothing happened. Same exception as the
    /// haptics card's Low Power Mode line — it reports a condition rather than
    /// explaining a control.
    private var calibrationBlockedReason: String? {
        if !audio.diagnostics.canCalibrate {
            return "Plug in your ultrasonic mic to calibrate."
        }
        if audio.isRunning {
            return "Stop detecting first, then calibrate."
        }
        return nil
    }

    @AppStorage("detector.model") private var detectorChoice = ""

    /// Named by the user rather than detected, because what iOS reports is the
    /// firmware's own port name — the Griff calls itself `bat_detector_usb` —
    /// and that is what was going into every recording's GUANO `Make` field and
    /// out to anyone the file was shared with.
    ///
    /// A fixed list with no "Other": the value is published, and a free-text
    /// box invites somebody to type something they did not think of as public.
    /// See `DetectorModel`.
    private var detectorSection: some View {
        Section {
            SettingRow("Detector",
                       "Written into your recordings' metadata and into any iNaturalist post, so somebody "
                     + "reading them knows what heard the bat. It is a fixed list because the value is "
                     + "published — there is no free-text box to type something into by accident.") {
                Picker("Detector", selection: $detectorChoice) {
                    Text("Not set").tag("")
                    ForEach(DetectorModel.known, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
            }
        } header: {
            CardHeader("What detector do you use?", "The microphone, not the phone.")
        }
    }

    @ViewBuilder
    private var microphoneSection: some View {
        Section {
            if let curve = micCalSettings.curve {
                SettingToggle("Apply calibration",
                              "Corrects the pitches your microphone hears unevenly, using the curve "
                            + "measured below. Off, you hear the mic exactly as it is.",
                              isOn: $micCalSettings.isEnabled)
                SettingValue("Measured for", value: curve.micName)
                SettingValue("Measured on",
                             value: curve.capturedAt.formatted(date: .abbreviated, time: .shortened))
            }
            HStack {
                Button {
                    showMicCalibration = true
                } label: {
                    Text(micCalSettings.curve == nil ? "Calibrate Microphone" : "Recalibrate Microphone")
                }
                .disabled(audio.isRunning || !audio.diagnostics.canCalibrate)
                Spacer(minLength: 12)
                SettingInfo(title: "Calibration",
                            note: "An affordable ultrasonic microphone hears some pitches louder than "
                                + "others. Calibration measures that unevenness against a known sound and "
                                + "corrects for it, so a call's loudness means the same thing wherever it "
                                + "sits in the band.")
            }
            .buttonStyle(.borderless)

            if let reason = calibrationBlockedReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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
                SettingToggle("Tap for every call",
                              "A tap you feel for each call OpenBat hears — stronger for a closer bat, "
                            + "sharper for a higher-pitched one, running together into a hum through a "
                            + "feeding buzz. For a user who can't hear the listening modes it is the only "
                            + "live output the app has.",
                              isOn: $haptics.isEnabled)

                if haptics.isEnabled {
                    SettingValue("Strength",
                                 "Raise it for gloves, or for a phone in a pocket.",
                                 value: String(format: "%.0f%%", haptics.strength * 100))
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
                // The mode's own description is what the ⓘ says, so it changes
                // with the selection — it is the one note here that isn't fixed.
                SettingName("Mode", pulseDetector.triggerMode.description)
                Picker("Mode", selection: $pulseDetector.triggerMode) {
                    ForEach(PulseDetector.TriggerMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                SettingValue("Loudness",
                             "How loud something has to be before OpenBat calls it a call. Lower it for "
                           + "faint or distant bats, and you will also catch more noise.",
                             value: String(format: "%.2f", pulseDetector.amplitudeThreshold))
                Slider(value: $pulseDetector.amplitudeThreshold, in: 0.1...0.95, step: 0.05)

                if pulseDetector.triggerMode == .ultrasonic {
                    SettingValue("Lowest pitch",
                                 "Anything below this pitch is ignored. 15–20 kHz clears wind, rustling "
                               + "and most of what a phone's own microphone picks up.",
                                 value: String(format: "%.0f kHz", pulseDetector.minFrequencyHz / 1000))
                    Slider(value: pulseMinFreqKHz, in: 5...150, step: 5)
                }
            } header: {
                CardHeader("What counts as a call",
                           "How loud, and how high, to trigger.")
            }

            Section {
                SettingValue("Shortest call",
                             "Anything briefer than this isn't a call. Raise it to reject clicks and pops, "
                           + "which are loud but over almost instantly.",
                             value: shortestCallLabel)
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

                SettingValue("Join gaps up to",
                             "A quiet patch shorter than this doesn't split a call in two — it stays one "
                           + "call with a dip in the middle.",
                             value: String(format: "%.0f ms", pulseDetector.maxGapMs))
                Slider(value: $pulseDetector.maxGapMs, in: 0...30, step: 1)

                SettingValue("Wait after a call",
                             "The shortest gap there can be between two separate calls. Nothing is "
                           + "counted as a new call until this much quiet has passed.",
                             value: String(format: "%.0f ms", pulseDetector.holdOffSeconds * 1000))
                Slider(value: $pulseDetector.holdOffSeconds, in: 0.02...1.0, step: 0.01)
            } header: {
                CardHeader("Telling calls apart",
                           "Stops one call being counted as several.")
            }
            .advancedOnly(simplifiedMode)
        }
    }

    // MARK: Live listening

    /// Which half of the live listening card is showing. Not persisted — it is
    /// a place in a sheet, not a preference, and the sheet opens fresh.
    private enum LiveChannel: String, CaseIterable {
        case expansion, heterodyne

        /// The glyphs the transport menu already uses for these two modes, so
        /// the pill and the listen-mode button name the same thing the same way
        /// — see `ContentView.listenIcon`.
        var symbol: String {
            switch self {
            case .expansion:  "tortoise"
            case .heterodyne: "antenna.radiowaves.left.and.right"
            }
        }

        var label: String {
            switch self {
            case .expansion:  "Time expansion"
            case .heterodyne: "Heterodyne"
            }
        }
    }

    @State private var liveChannel: LiveChannel = .expansion

    /// Replay speed for the live slow-replay mode, and only the speed. Buffer
    /// length, fade and re-arm stay in the live tuning overlay: those are
    /// judged by ear against a pass that is happening right now, which is what
    /// the overlay is for. Speed is decided once and left, so it belongs where
    /// a user goes looking for a setting.
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

    /// **One card for both channels, because they are one decision** (Niall,
    /// 2026-09-09). Time expansion had a card and heterodyne had nothing — its
    /// level and its background reduction existed only in the live tuning
    /// overlay, behind the config menu's passcode, and were not persisted, so
    /// anyone who found them lost them at the next launch. But a listener is
    /// not tuning two unrelated things: under `.both` routing they are the two
    /// halves of what comes out of the speaker, set against each other.
    ///
    /// The pill carries the transport menu's own glyphs (`LiveChannel.symbol`),
    /// so the tortoise and the antenna mean the same thing here as they do on
    /// the listen-mode button.
    @ViewBuilder
    private var liveListeningSection: some View {
        Section {
            Picker("Channel", selection: $liveChannel) {
                ForEach(LiveChannel.allCases, id: \.self) { channel in
                    // Interpolated into the `Text` rather than passed as a
                    // `Label`: a segmented picker renders a Label as its icon
                    // alone, and the whole point of the pill is that the glyph
                    // and the name arrive together.
                    Text("\(Image(systemName: channel.symbol)) \(channel.label)")
                        .tag(channel)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Listening channel")

            mixerRows

            switch liveChannel {
            case .expansion:  slowReplayRows
            case .heterodyne: heterodyneRows
            }
        } header: {
            CardHeader("Live listening", "What you hear when listening to bats.")
        }
    }

    /// The one control that used to be two volume sliders — see `ListenMixer`.
    ///
    /// Under the channel pill rather than inside it: it belongs to both channels,
    /// so it must not sit behind a switch that shows one of them.
    @ViewBuilder
    private var mixerRows: some View {
        SettingValue("Mixer",
                     "Which channel sits on top when you hear both. Volume itself is your "
                   + "phone's own buttons.",
                     value: mixerLabel)
        Slider(value: mixerBalance, in: ListenMixer.range, step: 1) {
            Text("Mixer")
        } minimumValueLabel: {
            Image(systemName: LiveChannel.expansion.symbol)
                .foregroundStyle(.secondary)
        } maximumValueLabel: {
            Image(systemName: LiveChannel.heterodyne.symbol)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Channel mixer")
        .accessibilityValue(mixerLabel)
    }

    /// Reads back as a balance and writes back as the pair of trims, so nothing
    /// else in the app has to know the mixer exists.
    private var mixerBalance: Binding<Double> {
        Binding(
            get: {
                ListenMixer.balance(expansionTrim: snippetExpansion.trimDB,
                                    heterodyneTrim: heterodyne.trimDB)
            },
            set: { balance in
                let trims = ListenMixer.trims(forBalance: balance)
                snippetExpansion.trimDB = trims.expansion
                heterodyne.trimDB = trims.heterodyne
                // Straight through to the running processors, so it is heard now
                // rather than at the next capture — the whole reason to set this
                // is that a bat is overhead. The stores are what make it survive
                // a launch; these two lines are what make it audible.
                audio.snippetExpansion.trimDB = trims.expansion
                heterodyne.apply(to: audio.heterodyne)
            }
        )
    }

    private var mixerLabel: String {
        let balance = ListenMixer.balance(expansionTrim: snippetExpansion.trimDB,
                                          heterodyneTrim: heterodyne.trimDB)
        if abs(balance) < 0.5 { return "Balanced" }
        let channel = balance < 0 ? LiveChannel.expansion : .heterodyne
        return String(format: "%@ +%.0f dB", channel.label, abs(balance))
    }

    @ViewBuilder
    private var slowReplayRows: some View {
        // The cost of a higher speed is deafness, and from Settings — with no
        // live readout beside it — that is invisible. It used to be a footer;
        // it now rides on the speed slider's own note, which is the only
        // control that changes it and the place a person is looking when they
        // do.
        SettingValue("Speed",
                     "How far a call is slowed down so you can hear it. The cost is deafness: while "
                   + "a call is replaying, OpenBat is not listening — about "
                   + "\(Int(snippetExpansion.replaySeconds.rounded())) s each time at this speed.",
                     value: slowReplaySpeedLabel)
        Slider(value: slowReplayIndex,
               in: 0...Double(slowReplaySteps.count - 1),
               step: 1)
            .accessibilityLabel("Time expansion speed")
            .accessibilityValue(slowReplaySpeedLabel)

        // No per-channel volume slider here any more: the app starts as loud as
        // it goes, the phone's buttons are the volume control, and what is left
        // — how the two channels sit against each other — is the Mixer above.
        // See `ListenMixer`.
        SettingName("Background",
                    "What to do with the hiss behind a replayed call. Normal cuts the steady "
                  + "background; High keeps only the call itself and silences everything else.")
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
    }

    @ViewBuilder
    private var heterodyneRows: some View {
        // Volume lives on the phone's own buttons and the balance lives in the
        // Mixer above — see `ListenMixer`.

        SettingName("Background",
                    "What to do with the hiss on the live channel. Normal measures the steady "
                  + "background and subtracts it. There is no High here: silencing everything that "
                  + "isn't plainly a call would make a missed bat sound like a quiet night.")
        Picker("Background", selection: Binding(
            get: { heterodyne.denoiseMode },
            set: {
                heterodyne.denoiseMode = $0
                heterodyne.apply(to: audio.heterodyne)
            }
        )) {
            // `liveChoices`, not `allCases` — see `SnippetDenoiseMode`.
            ForEach(SnippetDenoiseMode.liveChoices) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Recording

    @ViewBuilder
    private var recordingSections: some View {
        Group {
            Section {
                SettingToggle("Record automatically",
                              "Starting detection also arms the recorder, so a pass is saved without you "
                            + "having to think about it. Off, recording is a separate tap.",
                              isOn: $autoRecordOnSessionStart)
            } header: {
                CardHeader("Recording", "When OpenBat saves audio to a file.")
            }

            Section {
                SettingValue("Keep before a call",
                             "A recording starts this far back, so the first call is inside the file "
                           + "rather than at its very edge.",
                             value: String(format: "%.1f s", recorder.preRollSeconds))
                // Upper bound from the recorder, which sizes its pre-roll ring for
                // exactly this — a wider slider here than there would silently cap.
                Slider(value: $recorder.preRollSeconds,
                       in: 0.5...AudioRecorder.maxPreRollSeconds, step: 0.5)

                SettingValue("Stop after quiet for",
                             "Recording stops once it has been this quiet. Each new call extends the "
                           + "recording, so one pass is one file rather than a dozen.",
                             value: String(format: "%.1f s", recorder.postRollSeconds))
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

/// The ⓘ beside a setting's name, opening what used to be the grey line above
/// the control.
///
/// **A tap, not a caption** (Niall, 2026-09-09). A card carrying three or four
/// controls carried three or four explanations with them, and a page of those
/// reads as a wall of small grey type — the cards "look so messy" was the note.
/// A card is now its name, its one-line description, and rows of *just* the
/// option and the thing you touch; everything else is a tap away on the option's
/// own name, which is where somebody who wants it will look.
///
/// The explanation is not shortened on the way in. Freed from having to fit one
/// line under a control, a note can say the whole thing — which several of them
/// could not.
struct SettingInfo: View {
    let title: String
    let note: String

    @State private var showNote = false

    var body: some View {
        Button { showNote = true } label: {
            Image(systemName: "info.circle")
                .font(.footnote)
        }
        // `.borderless` rather than `.plain`: a row can hold this and a real
        // button (Share Log, Delete NoID), and a List makes two plain buttons in
        // one row ambiguous — tapping either fires both.
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel("About \(title)")
        .popover(isPresented: $showNote) {
            SettingExplainer(title: title, note: note)
                .presentationCompactAdaptation(.popover)
        }
    }
}

private struct SettingExplainer: View {
    let title: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                // A compact popover otherwise sizes to the text's intrinsic
                // single-line width and overflows — same fix as TuningExplainer.
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }
}

/// A setting's name, with its explanation behind the ⓘ when it has one.
struct SettingName: View {
    let title: String
    let note: String?

    init(_ title: String, _ note: String? = nil) {
        self.title = title
        self.note = note
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            if let note, !note.isEmpty {
                SettingInfo(title: title, note: note)
            }
        }
    }
}

/// One row of a settings card: the option's name on the left, the thing you
/// touch on the right, and nothing else.
///
/// Not `LabeledContent`, which greys and shrinks whatever it is given as a label
/// — the name here has a live control in it and has to stay legible and
/// tappable.
struct SettingRow<Control: View>: View {
    let title: String
    let note: String?
    let control: Control

    init(_ title: String, _ note: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.note = note
        self.control = control()
    }

    var body: some View {
        HStack {
            SettingName(title, note)
            Spacer(minLength: 12)
            control
        }
    }
}

/// A `SettingRow` whose control is a switch.
///
/// The title is handed to the `Toggle` as well as to the row and then hidden:
/// `.labelsHidden()` takes it off the screen but leaves it to VoiceOver, so the
/// switch still announces itself as the thing it turns on.
struct SettingToggle: View {
    let title: String
    let note: String?
    let isOn: Binding<Bool>

    init(_ title: String, _ note: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.note = note
        self.isOn = isOn
    }

    var body: some View {
        SettingRow(title, note) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
        }
    }
}

/// A number a card reports rather than a control — "Size on this device", a
/// slider's live readout. Same row shape, right-hand side is text.
struct SettingValue: View {
    let title: String
    let note: String?
    let value: String

    init(_ title: String, _ note: String? = nil, value: String) {
        self.title = title
        self.note = note
        self.value = value
    }

    var body: some View {
        SettingRow(title, note) {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// One short line ABOVE a control, saying what moving it does for the reader.
///
/// **Superseded in Settings and the configuration menu by `SettingInfo`** — see
/// there for why. It survives for the two screens that are not settings cards
/// and read as prose: the model detail page and the iNaturalist observation
/// sheet.
struct ControlNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
