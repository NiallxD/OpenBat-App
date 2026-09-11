//
//  DiagnosticsView.swift
//  OpenBat
//
//  The configuration menu, reached from Settings once the passcode has been
//  entered (`ConfigMenu`). Says what is switched off, what the microphone is
//  actually doing, and holds the three tools that get a tuning session or a
//  comparison off a phone.
//
//  **Built like a settings page, because it is one** (Niall, 2026-09-09). It
//  used to be hand-rolled `VStack` cards on a `.quaternary` rounded rectangle,
//  which is a settings form drawn worse: no Dynamic Type behaviour, no grouped
//  insets, and a description above AND a paragraph below every control. It is
//  now `Form`/`Section` under the same three-part card rule as `SettingsView`
//  — name, one-line description, control — see that file's header.
//
//  THINGS THAT WERE HERE AND ARE NOT
//  ---------------------------------
//  * **Demo mode.** It is a real feature now: started from the app-info sheet,
//    ended from the mic pill. A second entry behind a passcode was the last
//    trace of the days when it was a debug tool.
//  * **The session button card.** It existed to settle whether the button was
//    being found in the view hierarchy; it was, and the glow/menu/tap-catcher
//    story it was built for is closed (see `SessionButtonLocator`).
//  * **The iNaturalist posting-limit overrides.** Not gone — they are two of
//    the Overrides card's rules-lifted-for-testing switches.
//  * **The classifier log**, which went to Settings → General in 2026-08-26,
//    where a user reporting a wrong identification can find it.
//

import SwiftUI
import UIKit

struct DiagnosticsView: View {
    let audio: AudioEngineController
    let recorder: AudioRecorder
    /// Opens the floating live tuning card over the detector screen. Dismisses
    /// this sheet on the way — the card is useless behind a sheet, which also
    /// pauses the render loop it needs running.
    let onOpenTuning: () -> Void
    /// Captures every live tunable + persisted setting and writes it to a file,
    /// returning the URL. Owned by ContentView, which is the only place holding
    /// all the processors and the AutoID settings at once — see `dumpSettings`
    /// there.
    let onDumpSettings: () -> URL?
    /// The remote kill switches, listed at the top so the first thing this
    /// screen answers is "what is currently switched off".
    let flags: FeatureFlagStore
    @Environment(\.dismiss) private var dismiss
    /// For the jump to OpenBat's page in the Settings app — see
    /// `overridesSection`.
    @Environment(\.openURL) private var openURL
    /// Last file written by the dump button, so it can be shared without
    /// re-capturing (a second capture would be a different moment in time).
    @State private var dumpedFile: URL?
    @State private var dumpFailed = false
    /// See `demoLogSection`. The switch is read by `DemoLogger` at the start of
    /// a run, not by anything here.
    @AppStorage(DemoLogger.enabledKey) private var demoLogEnabled = false
    /// See `overridesSection`. Read at launch by `OnboardingState`, not here.
    @AppStorage(OnboardingState.forceEveryLaunchKey) private var forceOnboarding = false
    /// Read by `INatUploadAssessment.overrideLimits`, and cleared along with
    /// everything else if the config file ever locks this menu — which is why
    /// the key is named in `FeatureFlagStore`.
    @AppStorage(FeatureFlagStore.postingCapOverrideKey) private var inatIgnoreLimits = false
    @State private var inatLedgerCleared = false
    @State private var demoLogShare: DemoLogShare?
    @State private var demoLogsCleared = false

    private struct DemoLogShare: Identifiable { let id = UUID(); let url: URL }

    var body: some View {
        NavigationStack {
            Form {
                ConfigFeatureSection(flags: flags)
                overridesSection
                microphoneSection
                demoLogSection
                tuningSection
                settingsDumpSection
            }
            // On the Form, not on the card that owns it: a `.sheet` written on
            // a `Section` is handed down to each of the section's rows, so one
            // binding ends up with several presenters racing and the share
            // sheet animates straight back out. Same trap as the classifier
            // log's share sheet — see the note in `SettingsView`.
            .sheet(item: $demoLogShare) { item in
                ShareSheet(items: [item.url])
            }
            // The form paints its own grouped page; the sheet's default ground
            // is the plain one, and the seam shows at the top — same fix, and
            // the same reason, as `SettingsView.body`.
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Rules the app normally enforces on itself, lifted for testing.
    ///
    /// **Not with the feature switches above** (Niall, 2026-09-09). Those say
    /// whether a feature exists on this device; these change how one behaves
    /// while it does, which is a different question — and the iNaturalist pair
    /// sitting under the posting switch read as part of that feature's own
    /// definition rather than as a rule being suspended.
    ///
    /// Onboarding is here for the same reason: it happens on the first launch
    /// and no other, so the only way to look at a change to it was to delete the
    /// app and reinstall, taking the recordings, the sessions and the
    /// iNaturalist sign-in along with it. That flag is read at launch
    /// (`OnboardingState.applyEveryLaunchOverrideOnce`), so it takes effect the
    /// next time the app starts, not now.
    ///
    /// The two iNaturalist controls are deliberately not in Settings. They lift
    /// the rules that protect iNaturalist's records from a stream of near
    /// duplicates, and that protection is worth nothing if any user can switch
    /// it off — there is no user-facing "post anyway", and there should not be.
    /// Testing the posting path against the live API means posting a known
    /// recording, deleting it there, and posting it again, which the
    /// already-posted blocker otherwise makes impossible.
    private var overridesSection: some View {
        Section {
            SettingToggle("Always show onboarding",
                          "Starts at the welcome flow on the next launch and every one after it, so a "
                        + "change to onboarding can be looked at without deleting the app — which would "
                        + "take the recordings, the sessions and the iNaturalist sign-in with it.",
                          isOn: $forceOnboarding)

            SettingToggle("Ignore iNaturalist posting limits",
                          "Posts anyway when a recording is already posted, over the nightly cap, too "
                        + "big, or has no location. The blockers stay on screen and the score is still "
                        + "worked out honestly, so a test post looks like a real one.",
                          isOn: $inatIgnoreLimits)

            HStack {
                Button {
                    INatPostLedger.forgetEverythingPosted()
                    inatLedgerCleared = true
                } label: {
                    Label(inatLedgerCleared ? "Forgotten" : "Forget what's been posted",
                          systemImage: inatLedgerCleared ? "checkmark" : "arrow.counterclockwise")
                }
                Spacer(minLength: 12)
                SettingInfo(title: "Forget what's been posted",
                            note: "Clears this phone's record of what it has posted, so the nightly cap "
                                + "and the already-posted check start again. Nothing on iNaturalist is "
                                + "touched — delete those there.")
            }
            .buttonStyle(.borderless)

            HStack {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Label("Revoke microphone & location", systemImage: "hand.raised")
                }
                Spacer(minLength: 12)
                SettingInfo(title: "Revoke microphone & location",
                            note: "iOS gives an app no way to withdraw its own permissions, so this "
                                + "opens OpenBat's page in the Settings app — switch Microphone and "
                                + "Location off there.\n\niOS quits OpenBat the moment you do, so the "
                                + "next launch is a fresh one: with \"Always show onboarding\" on, it "
                                + "starts at the welcome flow with both rows showing as refused.\n\n"
                                + "That is the refused path, not the first-run one. The permission "
                                + "dialogs themselves only come back on a device that has never been "
                                + "asked — a fresh install, or `xcrun simctl privacy <device> reset all "
                                + "Niall.OpenBat` on a simulator.")
            }
            .buttonStyle(.borderless)
        } header: {
            CardHeader("Overrides", "Rules lifted, for testing.")
        }
    }

    /// Everything measured about the input, in one card: what is attached, what
    /// rate it is really delivering, how loud it is right now, and the QA
    /// numbers that let two microphones be compared.
    ///
    /// **One card, not four** (Niall, 2026-09-09). The stream, the level meter
    /// and the "Mic QA" panel were three cards plus a loose status line, and a
    /// reader had to know which of them to believe about the same microphone.
    ///
    /// Its rows live in `MicrophoneRows`, which is the churn fix the old cards
    /// had for the same reason: `audio.diagnostics` updates at ~15 Hz, and read
    /// from this body it would re-render the sheet's whole form — toolbar,
    /// share buttons and all — fifteen times a second. Reading it one level
    /// down keeps the invalidation there. Same pattern as ContentView's
    /// RecordButton; see Context.md §13.
    private var microphoneSection: some View {
        Section {
            MicrophoneRows(audio: audio, recorder: recorder)
        } header: {
            CardHeader("Microphone", "What the input is really doing.")
        }
    }

    /// The switch that makes a demo run write a file, and the way to get the
    /// files off the phone.
    ///
    /// It changes nothing about how the demo runs — a run with it on and a run
    /// with it off must produce the same detections or the log is worthless.
    /// Why it exists: the demo is the one input two phones can be given
    /// identically, so it is the only fair way to ask whether they behave the
    /// same. See `DemoLogger` for what a file holds and why it is not the
    /// classifier log.
    private var demoLogSection: some View {
        Section {
            SettingToggle("Log demo runs",
                          "Writes one CSV per demo run: every pulse the detector kept, every pulse "
                        + "nothing was asked to name, every score the model produced, and every pass they "
                        + "were aggregated into. The header carries the device, the OS, the build and "
                        + "every threshold in force.\n\nSwitched on or off, a demo detects exactly the "
                        + "same things. Live capture never writes here.",
                          isOn: $demoLogEnabled)

            let logs = DemoLogger.shared.existingLogs()
            HStack {
                Button {
                    if let url = DemoLogger.shared.makeShareItem() {
                        demoLogShare = DemoLogShare(url: url)
                    }
                } label: {
                    Label(logs.isEmpty ? "No demo logs yet" : "Share \(logs.count) demo log\(logs.count == 1 ? "" : "s")",
                          systemImage: "square.and.arrow.up")
                }
                .disabled(logs.isEmpty)
                Spacer(minLength: 12)
                SettingInfo(title: "Demo logs",
                            note: "Files are named demo_<clip>_<device>_<time>.csv and sit alongside your "
                                + "recordings, so the Files app or a Mac reaches them without going "
                                + "through the share sheet at all.")
            }
            .buttonStyle(.borderless)

            Button(role: .destructive) {
                DemoLogger.shared.deleteAllLogs()
                demoLogsCleared = true
            } label: {
                Label(demoLogsCleared ? "Deleted" : "Delete demo logs",
                      systemImage: demoLogsCleared ? "checkmark" : "trash")
            }
            .disabled(logs.isEmpty && !demoLogsCleared)
        } header: {
            CardHeader("Demo log", "Two phones, one clip, compared line by line.")
        }
    }

    /// Entry point for the live tuning card. Available during a demo and during
    /// live capture — tuning against real bats matters as much as tuning against
    /// the demo clip; the demo is just the repeatable case.
    private var tuningSection: some View {
        Section {
            HStack {
                Button {
                    dismiss()
                    onOpenTuning()
                } label: {
                    Label("Open tuning panel", systemImage: "slider.horizontal.3")
                }
                Spacer(minLength: 12)
                SettingInfo(title: "Live tuning",
                            note: "A floating panel of live controls over the detector. The spectrogram "
                                + "and the audio keep running, so changes are heard and seen as you make "
                                + "them. Drag it out of the way; close it from its own ✕.")
            }
            .buttonStyle(.borderless)
        } header: {
            CardHeader("Live tuning", "A floating panel over the detector.")
        }
    }

    /// Writes the current value of every slider, toggle and per-species prior to
    /// a JSON file so a tuning session can be turned into code defaults without
    /// transcribing knob positions by hand. Deliberately captures on tap rather
    /// than continuously — the file is meant to be a dated record of one
    /// configuration, not a live mirror.
    private var settingsDumpSection: some View {
        Section {
            HStack {
                Button {
                    dumpFailed = false
                    if let url = onDumpSettings() {
                        dumpedFile = url
                    } else {
                        dumpedFile = nil
                        dumpFailed = true
                    }
                } label: {
                    Label("Dump settings to file", systemImage: "square.and.arrow.down.on.square")
                }
                Spacer(minLength: 12)
                SettingInfo(title: "Settings snapshot",
                            note: "Every tuning slider, display preference and per-species prior, as JSON "
                                + "in Documents. Captured on tap rather than continuously — it is a dated "
                                + "record of one configuration. Tap again for a fresh, separately "
                                + "timestamped capture.")
            }
            .buttonStyle(.borderless)

            if dumpFailed {
                Label("Couldn't write the file.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if let dumpedFile {
                ShareLink(item: dumpedFile) {
                    Label(dumpedFile.lastPathComponent, systemImage: "square.and.arrow.up")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } header: {
            CardHeader("Settings snapshot", "Every setting and prior, as JSON.")
        }
    }
}

/// The microphone card's rows. A view of its own so `audio.diagnostics`'s ~15 Hz
/// churn invalidates this and nothing above it — see `microphoneSection`.
private struct MicrophoneRows: View {
    let audio: AudioEngineController
    let recorder: AudioRecorder

    var body: some View {
        let d = audio.diagnostics
        Group {
            Text(audio.status)
                .font(.footnote)
                .foregroundStyle(.secondary)

            // Both shown raw, unsanitized, so the values a real microphone
            // reports can be inspected directly — the only reliable way to
            // confirm a given mic doesn't put a serial in its product string.
            // Neither is ever contributed in this form (see
            // AnonymizedUploadBuilder.sanitizedHardwareName); the UID is never
            // contributed at all.
            row("Input", d.inputName, badge: d.isUSBInput ? "USB" : nil)
            row("Contributed as", AnonymizedUploadBuilder.sanitizedHardwareName(d.inputName))
            row("Input UID (local only)", d.inputUID)
            row("Session rate",
                d.sessionSampleRate > 0 ? "\(Int(d.sessionSampleRate)) Hz" : "—",
                emphasis: d.sessionSampleRate >= 60_000 ? .green : (d.sessionSampleRate > 0 ? .orange : .secondary))
            row("Capture rate",
                d.actualSampleRate > 0 ? "\(Int(d.actualSampleRate)) Hz" : "—",
                emphasis: d.isNativeRate ? .green : (d.actualSampleRate > 0 ? .orange : .secondary))
            row("Channels", d.channelCount > 0 ? "\(d.channelCount)" : "—")
            // Whether hold-to-ear is even armed, and what the sensor says right
            // now — the two things that separate "the feature is broken" from
            // "this device has no sensor" / "it is switched off".
            // Sampled once a minute by `PowerLogger`, not read live — this is a
            // window onto the row it just wrote, so the log can be sanity-checked
            // without exporting it.
            row("Power (last sample)", PowerLogger.shared.lastSummary)
            row("Hold to ear",
                UIDevice.current.isProximityMonitoringEnabled
                    ? (UIDevice.current.proximityState ? "watching · near" : "watching · far")
                    : "off")
            row("Output", d.outputName,
                badge: d.outputChannelCount > 1 ? "\(d.outputChannelCount) ch" : nil,
                emphasis: d.outputChannelCount > 1 ? .orange : .secondary)
            row("Buffers", "\(d.bufferCount)")
            if recorder.lastWrittenSampleRate > 0 {
                row("Written rate", "\(Int(recorder.lastWrittenSampleRate)) Hz",
                    emphasis: recorder.lastWrittenSampleRate >= 192_000 ? .green : .orange)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Input level")
                    .foregroundStyle(.secondary)
                ProgressView(value: AudioLevel.normalized(d.currentLevelDB))
                    .tint(.green)
                Text(String(format: "%.0f dBFS", d.currentLevelDB))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // The QA numbers. They only mean something over a fixed, repeatable
            // test — so many seconds quiet, then so many seconds of a known
            // source — which is what the button below is for. The demo case
            // stays on screen: it says the numbers are about something else
            // entirely, which is not a thing to hide behind a tap.
            if audio.isDemoMode {
                Label("A demo file is playing: these describe the file, not the mic.",
                      systemImage: "play.rectangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            row("Noise floor",
                d.hasNoiseFloor ? String(format: "%.0f dBFS", d.noiseFloorDB) : "—",
                emphasis: !d.hasNoiseFloor ? .secondary : (d.noiseFloorDB <= -50 ? .green : .orange))
            row("Peak level",
                d.totalSampleCount > 0 ? String(format: "%.0f dBFS", d.peakLevelDB) : "—",
                emphasis: d.totalSampleCount == 0 ? .secondary : (d.peakLevelDB < -3 ? .green : .orange))
            row("DC offset",
                d.totalSampleCount > 0 ? String(format: "%.2f%%", d.dcOffsetPercent) : "—",
                emphasis: d.totalSampleCount == 0 ? .secondary : (abs(d.dcOffsetPercent) < 1 ? .green : .red))
            row("Clipped samples",
                d.totalSampleCount > 0
                    ? "\(d.clippedSampleCount) (\(String(format: "%.3f%%", d.clipRate * 100)))"
                    : "—",
                emphasis: d.clippedSampleCount == 0 ? .green : .red)

            HStack {
                Button {
                    audio.resetMicQA()
                } label: {
                    Label("Start measuring again", systemImage: "arrow.counterclockwise")
                }
                Spacer(minLength: 12)
                SettingInfo(title: "Start measuring again",
                            note: "The four numbers above accumulate from the moment measuring started. "
                                + "They only compare two microphones if both were asked the same "
                                + "question, so start again here and run a fixed test on each — so many "
                                + "seconds quiet, then so many seconds of a known loud source.")
            }
            .buttonStyle(.borderless)
        }
    }

    private func row(
        _ label: String,
        _ value: String,
        badge: String? = nil,
        emphasis: Color = .primary
    ) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                if let badge {
                    Text(badge)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.2), in: Capsule())
                }
                Text(value)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(emphasis)
            }
        } label: {
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}
