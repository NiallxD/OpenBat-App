//
//  ContentView.swift
//  OpenBat
//
//  Main screen, and the wiring hub every subsystem is connected through.
//  Layout, bottom to top:
//    • Control bar   — play/stop, listen mode (fixed height)
//    • Live spectrogram — 50 % of the flexible area
//    • Pulse zoom    — 30 % — last detected pulse at 15 ms x-axis
//    • Stats strip   — 20 % — placeholder for future species / count data
//
//  Wiring lives in the `.onAppear` (around `audio.activate()`): the raw audio
//  tap fans out from `audio.bufferSink` into `processor` (spectrogram/FFT) and
//  `recorder` (WAV capture); `pulseDetector`'s callbacks (`onPulseStart`,
//  `onPulseClassified`, `onPulseActiveChanged`, `onPassFinalized`) push into
//  the recorder, the Live Activity controller and the audio engine's own
//  auto-tune; `recorder.onRecordingSaved` hands a finished bout to
//  `classStore` and then to `RecordingUploader`. Each store is a `@State`
//  object owned here and passed down by reference — this file is where their
//  lifetimes and cross-references are established, not where their own logic
//  lives.
//
//  `menuIsOpen` pauses the Metal render loop and suspends `processor` while a
//  full-screen sheet is up. `showBand`/`showPulseView`/`showTuningOverlay` are
//  deliberately excluded from it — see their own declarations.
//

import SwiftUI
import CoreLocation
import UIKit

/// Shared tints for the panel-header icon pills. Toggle-style buttons (species
/// ID, compress timeline, bat range, full screen, listen mode) are grey when
/// inactive, orange when active. Menu-style buttons (palette, config) that just
/// open something rather than being a state get plain white, matching the
/// leading/trailing nav-bar menus — they're not a toggle, so they don't get the
/// grey/orange treatment.
extension Color {
    /// The app's signature orange — the bat-glyph / logo colour. The single source
    /// of truth for it, reused for the "on" toggle tint here and the guided-tour
    /// accents in AppInfoView (the AccentColor asset is intentionally empty, so a
    /// bare `.tint` falls back to system blue — hence naming the colour explicitly).
    static let batAccent = Color(red: 0.914, green: 0.514, blue: 0.114) // #E9831D
    static let toggleOn = batAccent
    static let toggleOff = Color.secondary
}

struct ContentView: View {
    @State private var audio = AudioEngineController()
    @State private var processor = SpectrogramProcessor()
    @State private var pulseDetector = PulseDetector()
    @State private var recorder = AudioRecorder()
    @State private var autoIDSettings = AutoIDSettings()
    /// Live snippet-expansion settings. Threaded down (rather than owned by the
    /// tuning overlay) because the processor has to be seeded with them at
    /// capture start, not only when the overlay happens to be open.
    @State private var snippetSettings = SnippetExpansionSettings()
    @State private var micCalSettings = MicCalibrationSettings()
    @State private var classStore = ClassificationStore()
    @State private var liveActivity = LiveActivityController()
    @State private var detectionPump = BackgroundDetectionPump()
    @State private var location = LocationProvider()
    @State private var haptics = PulseHaptics()
    // Not `@State`: the store outlives any one screen and is shared with
    // onboarding. `@Observable` tracks property reads in `body` regardless of
    // how the reference is held, so this still updates the view.
    private let consent = ConsentStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showMicDeniedAlert = false
    // Easter eggs on the footer version number, both on the same tap counter:
    // 10 taps within the rolling window sends a swarm of bats across the screen
    // (see BatSwarmOverlay), carrying on to 15 toggles debug mode, which
    // reveals the Debug menu entry.
    @State private var versionTapCount = 0
    @State private var versionTapResetWork: DispatchWorkItem?
    @State private var showBatSwarm = false
    /// Persisted so the unlock survives a relaunch — the ten taps are a way in,
    /// not something to repeat every launch. Toggled by `registerVersionTap`.
    @AppStorage("debugModeEnabled") private var debugModeEnabled = false
    @State private var showDiagnostics = false
    @State private var showSettings = false
    /// Set once per launch when a previously-granted consent predates the
    /// current wording — see `ConsentStore.needsReconsent`.
    @State private var showReconsentPrompt = false
    @State private var hasCheckedReconsent = false
    @State private var showHelp = false
    @State private var showInfo = false
    @State private var showNearbySpecies = false
    @State private var showEndSessionConfirm = false
    // Guided spotlight tour (launched from Info). tourActive gates the overlay;
    // tourIndex is the current step. tourPending is set by the Info sheet's tour
    // button and consumed by its onDismiss, so the tour only starts once the
    // sheet is fully gone (no fixed-delay race with the dismiss animation).
    @State private var tourActive = false
    @State private var tourPending = false
    @State private var tourIndex = 0
    /// The nav-bar tour offer's popover — see `tourButton`.
    @State private var showTourOffer = false
    /// One self-opening attempt per launch — see `nudgeTourAfterDelay`.
    @State private var tourNudgeScheduled = false
    /// How long after the detector first appears the tour offers itself, and how
    /// long it keeps waiting for a clear moment before giving up.
    private static let tourNudgeDelay: TimeInterval = 5
    private static let tourNudgeWindow: TimeInterval = 120
    /// What's New, once per build. Copied out of `ReleaseState` in `.onAppear`
    /// rather than read from it live — see the sheet modifier for why.
    @State private var showWhatsNew = false
    /// Set once, on the first arrival here after onboarding, when the user's
    /// location suggests a model that isn't already active — drives
    /// `SuggestedModelSheet`. Standalone: dismissing it does NOT chain into
    /// anything else (see that sheet's own modifier below). It used to be raised
    /// at the end of the onboarding tour instead, which no longer auto-launches.
    @State private var suggestedModelToOffer: ModelDescriptor?
    /// Set in `.onAppear` when onboarding just finished but no location fix had
    /// landed yet to base a suggestion on — consumed by the `onChange` below the
    /// moment one arrives. See that flag's own history: checking
    /// `location.currentCoordinate` synchronously, immediately after firing
    /// `requestRegionFix()` in the same `.onAppear`, meant the fix essentially
    /// never existed yet, since it's a real CoreLocation round trip — so the
    /// suggestion silently never appeared after onboarding on the most common
    /// path, a cold first launch.
    @State private var pendingOnboardingModelOffer = false
    /// The first-connection calibration offer, and the capture it leads to. Two
    /// flags because they are two presentations: the offer is a compact sheet,
    /// and accepting it opens the real calibration sheet *after* the offer has
    /// finished dismissing — see `offerCalibrationIfAppropriate`.
    @State private var showCalibrationOffer = false
    @State private var showMicCalibration = false
    /// Set by the offer's Calibrate button and consumed by its `onDismiss`. The
    /// second sheet cannot be raised from inside the first's button action:
    /// presenting from within a dismissing presentation drops it silently, which
    /// CLAUDE.md lists as having already caused two separate bugs.
    @State private var calibrationAccepted = false
    /// The mic's display name, copied when the offer is raised rather than read
    /// live in the sheet. Reading any field of `audio.diagnostics` from inside
    /// `body` — the sheet's content closure included — registers a dependency on
    /// a struct that churns at the 15 Hz stats flush; see the note on
    /// `activeInputName` at the `onChange` below.
    @State private var calibrationOfferMicName = ""
    @State private var showPulseView = false
    @State private var showBand = false
    /// Live tuning overlay. Deliberately absent from `menuIsOpen` — see that
    /// property and `LiveTuningOverlay`'s header comment: adding it there would
    /// pause the render loop and the processor, which is the one thing the
    /// overlay exists to avoid.
    @State private var showTuningOverlay = false

    /// App-lifetime, so an export survives leaving the session it was started
    /// from — see `SessionExportManager`.
    @State private var exportManager = SessionExportManager.shared
    /// The vertical transport menu hanging off the session button — record,
    /// listen mode, end session. Only openable while a session is running; see
    /// `handleSessionButtonTap`. Deliberately absent from `menuIsOpen`: it is
    /// used mid-session, with a bat overhead, and pausing the render loop
    /// underneath it would stop the very thing it is controlling.
    @State private var showTransportMenu = false
    /// Where the system actually drew the session button. Everything anchored
    /// to that button reads it — see `SessionButtonLocator` for why none of
    /// this can be a constant.
    @State private var sessionButtonLocator = SessionButtonLocator()
    // The three display defaults below come from a field tuning session
    // (2026-08-17 dump), rounded off the slider positions they were dragged to.
    // The band is a fraction of Nyquist, so 0.02–0.45 is roughly 3.8–86 kHz at
    // 384 kHz: it drops the phone's own low-frequency noise off the bottom and
    // the empty top half off the top, which is most of what made a fresh
    // install's spectrogram look like static. Note simplified view — the
    // default mode — applies its own 15–90 kHz band once on entry
    // (`SimplifiedView.bandLowHz`), so these two are what ADVANCED view starts
    // at, not what most users see first.
    @State private var timeWindowSeconds: Double = 0.75
    @AppStorage("display.bandLow") private var bandLow = 0.02
    @AppStorage("display.bandHigh") private var bandHigh = 0.45
    /// Pulse-view pinch-to-zoom + pan (both axes), reset on each new capture —
    /// see the "Pulse zoom/pan" section further down for the geometry.
    /// Peak-hold state for the amplitude meters. Owned by a separate @Observable object
    /// (rather than plain @State read in ContentView.body) so the 15 Hz level updates that
    /// drive it are scoped to the leaf meter views — reading it here would invalidate the
    /// whole body on every tick while detecting.
    @State private var peakHold = PeakHoldTracker()
    /// When the current detecting run started — nil while stopped. Scopes the
    /// species ID feed to "this run only" (see SpeciesFeedView).
    @State private var feedSessionStart: Date?
    /// One-shot "you're not recording" nudge — see `checkNotRecordingNudge`.
    @State private var showNotRecordingNudge = false
    @State private var notRecordingNudgeShown = false
    @AppStorage("nudge.notRecording.suppressed") private var suppressNotRecordingNudge = false
    @AppStorage("recording.autoRecordOnSessionStart") private var autoRecordOnSessionStart = true
    // Toggled from each panel's own config popover (bandButton / pulseViewButton).
    @AppStorage("display.spectrogramShowsSpeciesID") private var spectrogramShowsSpeciesID = false
    @AppStorage("display.pulseShowsSpeciesID") private var pulseShowsSpeciesID = false
    /// Independent of the pulse view's own toggle (`display.pulseLogFrequency`,
    /// declared in PulseSettingsView) — set from the spectrogram's frequency-band popover.
    @AppStorage("display.spectrogramLogFrequency") private var spectrogramLogFrequency = false
    /// Hides the readouts and controls that only mean something to someone who
    /// already reads calls — see `SimplifiedView` for the list and for why some
    /// of what it changes is an override and some a one-time default.
    @AppStorage(SimplifiedView.key) private var simplifiedMode = true
    @AppStorage(SimplifiedView.defaultsAppliedKey) private var simplifiedDefaultsApplied = false

    /// Which view each panel shows, once simplified view has had its say. In
    /// simplified view the toggles that would change these are hidden, so the
    /// stored values are deliberately ignored rather than written over — the
    /// user's own choices are still there when they switch back.
    private var effectivePulseShowsSpeciesID: Bool {
        simplifiedMode ? true : pulseShowsSpeciesID
    }
    private var effectiveSpectrogramShowsSpeciesID: Bool {
        simplifiedMode ? false : spectrogramShowsSpeciesID
    }

    /// iPad landscape only, where the Species ID list already has its own
    /// permanent panel beside the pulse card. Simplified view's usual override
    /// above forces the pulse card to species ID too, which there draws the same
    /// list twice side by side — so this flips the override the other way and
    /// the pulse card stays a pulse card.
    ///
    /// This does not break the rule in `SimplifiedView`. That rule exists so a
    /// hidden toggle can never strand the user somewhere with no route to
    /// species ID; here the route is the panel immediately next to it. Advanced
    /// view is left alone, because its toggle is visible and overriding it would
    /// make a shown control inert.
    private var padLandscapePulseShowsSpeciesID: Bool {
        simplifiedMode ? false : pulseShowsSpeciesID
    }

    // "-startSection Species" launch argument jumps straight to a section —
    // lets automated runs exercise non-default sections without UI scripting.
    // `AppSection` itself now lives in AppTabBar.swift, with the bar that
    // presents it.
    @State private var section: AppSection =
        UserDefaults.standard.string(forKey: "startSection").flatMap(AppSection.init) ?? .detector
    /// Field-guide data (bundled → cached → GitHub). `init()` itself is cheap —
    /// the actual bundled/cached JSON decode happens off-main in `loadLocal()`,
    /// called from `.task` below, not here. This constructor expression runs
    /// inline as part of `ContentView.init()` (SwiftUI's `@State` default-value
    /// mechanism), which is itself invoked from `OpenBatApp`'s `WindowGroup`
    /// content closure and can re-evaluate more than once per app lifetime —
    /// putting real work in `init()` used to mean a synchronous ~328 KB
    /// `JSONDecoder` pass could land on the main thread at any of those points,
    /// not just once at launch.
    @State private var speciesGuide = SpeciesGuideStore()
    @State private var speciesPresence = SpeciesPresenceStore()

    var body: some View {
        tabHost
            // Keyed on the session start, so it re-arms for each new listening
            // run and cancels automatically if the user stops before 60 s.
            // A sleep beats polling here: there is exactly one deadline.
            .task(id: feedSessionStart) {
                notRecordingNudgeShown = false
                guard feedSessionStart != nil else { return }
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                checkNotRecordingNudge()
            }
            // Finds the system's session button so the glow and the tap
            // catcher can be placed on it rather than near it.
            .locatesSessionButton(sessionButtonLocator)
            // Swallows the tap before the system bar can act on it — see
            // `sessionButtonTapCatcher`. Above the bar, below the menu.
            .overlay(alignment: transportMenuAlignment) { sessionButtonTapCatcher }
            // The transport menu, drawn over the bar rather than inside it —
            // see `transportMenuOverlay` for why it can't be a popover.
            .overlay(alignment: transportMenuAlignment) { transportMenuOverlay }
            .overlay(alignment: transportMenuAlignment) { notRecordingNudgeOverlay }
            // Session exports outlive the screen that started them, so their
            // progress card and the share sheet at the end are hosted here —
            // see SessionExportManager.
            .overlay(alignment: exportPillAlignment) { sessionExportOverlay }
            .sheet(item: $exportManager.ready) { ready in
                ShareSheet(items: [ready.url])
            }
            .alert("Export failed", isPresented: Binding(
                get: { exportManager.failure != nil },
                set: { if !$0 { exportManager.failure = nil } }
            )) {
                Button("OK") { }
            } message: {
                Text(exportManager.failure ?? "")
            }
                .sheet(isPresented: $showDiagnostics) {
                    DiagnosticsView(audio: audio, recorder: recorder, classStore: classStore,
                                    onStartDemo: startDemo, onEndDemo: endDemo,
                                    onOpenTuning: { showTuningOverlay = true },
                                    onDumpSettings: dumpSettings,
                                    sessionButtonLocator: sessionButtonLocator)
                }
                .sheet(isPresented: $showHelp) {
                    SafariView(url: PrivacyLinks.helpURL)
                }
                .sheet(isPresented: $showNearbySpecies) {
                    NearbySpeciesSheet(guide: speciesGuide, presenceStore: speciesPresence,
                                       coordinate: location.currentCoordinate)
                        // The sheet's own card material defaults to a light
                        // translucent fill — flat black instead, matching the
                        // guide's push destination of the same grid.
                        .presentationBackground(Color.black)
                }
                // Ending stops live listening (and any in-progress recording)
                // outright — the logged IDs themselves aren't deleted, but the
                // mic goes silent and the Live Activity card disappears, which
                // matters if this was a stray tap mid-pass. Session deletion
                // already gets its own confirmation (see SessionsView); this is
                // the same pattern for the one step upstream of it.
                .confirmationDialog("End this session?",
                                    isPresented: $showEndSessionConfirm, titleVisibility: .visible) {
                    Button("End Session", role: .destructive) { stopDetecting() }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Listening and recording will stop. Anything already logged stays saved.")
                }
                // onDismiss (not just the Done button) so per-model AutoID edits
                // survive a swipe-down dismissal of the sheet too.
                .sheet(isPresented: $showSettings, onDismiss: {
                    autoIDSettings.save()
                    // minPassConfidence/minPassPulseCount are per-model and editable
                    // in this sheet — repush in case they changed.
                    recorder.setPassGates(minConfidence: autoIDSettings.minPassConfidence,
                                          minPulseCount: autoIDSettings.minPassPulseCount)
                }) {
                    SettingsView(settings: autoIDSettings,
                                 pulseDetector: pulseDetector, recorder: recorder,
                                 location: location, consent: consent, classStore: classStore,
                                 audio: audio, micCalSettings: micCalSettings,
                                 haptics: haptics)
                }
                // Someone who opted in, then had the terms change under them,
                // has silently stopped contributing. Settings carries the same
                // prompt, but relying on them to wander in there means their
                // participation just quietly ends. Asked once per launch, and
                // only of people who actually did opt in — `needsReconsent` is
                // false for anyone who declined or never decided.
                .sheet(isPresented: $showReconsentPrompt) {
                    NavigationStack {
                        ConsentView(consent: consent) { showReconsentPrompt = false }
                            .padding(.horizontal)
                            .navigationTitle("Terms Updated")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
                .sheet(isPresented: Binding(
            // `&& !tourActive`: this fires from AutoIDSettings.refreshPriors
            // (ContentView's own onChange(of: location.currentCoordinate)), which can land
            // squarely in the middle of the guided tour if a fix arrives while it runs.
            // A `.sheet` still presents over an active full-screen overlay, so without
            // this it visibly popped up on top of the dimmed tour. Suppressing it here
            // doesn't lose the summary — `pendingChangeSummary` stays set and the binding
            // re-evaluates once `tourActive` goes false, so it presents as soon as the
            // tour ends.
            //
            // `&& !shouldShowWhatsNew` is the same guard against the same hazard,
            // and it was found the same way — on the first launch after an
            // update this sheet won the race and What's New was silently
            // dropped. What's New goes first because it is a once-per-update
            // notice: this summary recurs whenever the user moves, and the
            // binding re-presents it as soon as the flag clears.
            // One expression, shared with `menuIsOpen` — see `showingChangeSummary`
            // for the bug that came of writing the condition out twice.
            get: { showingChangeSummary },
            set: { if !$0 { autoIDSettings.acknowledgeChangeSummary() } }
        )) {
            if let summary = autoIDSettings.pendingChangeSummary {
                // The same card the post-onboarding suggestion uses, deliberately:
                // this is the same offer, arriving for the same reason, and it used
                // to be a full `Form` sheet in its own visual language
                // (`LocationChangeSummaryView`, deleted 2026-08-17).
                SuggestedModelSheet(model: summary.recommendedModel,
                                    speciesChanged: summary.speciesChanged,
                                    onUse: { model in autoIDSettings.activeModelID = model.id })
            }
        }
        .sheet(isPresented: $showInfo, onDismiss: {
                    if tourPending {
                        tourPending = false
                        tourIndex = 0
                        // The tour's spotlight targets (`.tourTarget`) only exist inside
                        // `detectorLayout` — starting the tour from another section (e.g.
                        // Species) left it running with no real anchors to point at. Jump
                        // back to Detector first and let that frame land before revealing
                        // the overlay, so the targets are mounted by the time it reads them.
                        section = .detector
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.3)) { tourActive = true }
                        }
                    }
                }) {
                    AppInfoView(startTour: { tourPending = true })
                }
        // Collects the `.tourTarget` anchors from the controls below and, while the
        // tour is active, resolves them to on-screen rects for the spotlight overlay.
        .overlayPreferenceValue(TourTargetKey.self) { anchors in
            GeometryReader { proxy in
                if tourActive {
                    TourOverlay(targets: anchors.mapValues { proxy[$0] }
                                    .merging(tabBarTargets(in: proxy)) { _, fromBar in fromBar },
                                index: $tourIndex,
                                steps: TourScript.steps(simplified: simplifiedMode),
                                // The tour is only ever launched deliberately now — from
                                // Info & Tour — so finishing it just puts the screen
                                // back. It used to chain into a model suggestion and
                                // Start Detecting when it had been auto-launched by
                                // onboarding; the suggestion now happens on arrival
                                // instead (see the `justFinishedOnboarding` handoff in
                                // `.onAppear`), and starting a session was never ours to
                                // do unasked.
                                finish: { completed in
                                    withAnimation(.easeInOut(duration: 0.25)) { tourActive = false }
                                    // Only a tour seen to its last step retires the
                                    // button that offers it — see
                                    // `OnboardingState.recordTourCompleted`.
                                    if completed {
                                        OnboardingState.shared.recordTourCompleted(simplified: simplifiedMode)
                                    }
                                })
                    // Skip re-diffing the overlay on the constant anchor-preference
                    // churn from the live detector UI — see TourOverlay's ==.
                    .equatable()
                }
            }
            // Full-screen so the resolved anchor rects, the dim shape's cutout,
            // and the highlight ring all share ONE coordinate space. Previously
            // only the dim shape ignored the safe area, which shifted its local
            // origin to the physical screen's top-left while the hole rects were
            // resolved in the safe-area-inset space — the cutout drew a full
            // status-bar-plus-nav-bar height above the ring.
            .ignoresSafeArea()
            // Diagnostics only. The tab-bar targets are rebased from window
            // coordinates through this frame, so when a spotlight lands in the
            // wrong place this is half of the arithmetic to check.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                sessionButtonLocator.recordTourHostFrame($0)
            }
        }
        // Loads the bundled/cached guide off the main thread (see
        // `SpeciesGuideStore.init()`'s doc comment for why this can't just
        // happen in the `@State` initializer), then checks GitHub once per
        // launch for a newer dataVersion. Offline → the remote check no-ops.
        .task {
            await speciesGuide.loadLocal()
            await speciesGuide.refreshFromRemote()
            // Background priority and last in the chain: this is speculative
            // work for pages nobody has asked for, and it must never compete
            // with the guide load the UI is actually waiting on.
            await Task(priority: .background) { await speciesGuide.warmImageCache() }.value
        }
        // Same pattern for the species presence grid, except this one DOES ship
        // a bundled copy: it decides which species the classifier considers
        // plausible, so a cold offline install must not be left with no opinion.
        // The remote check only ever upgrades it.
        .task {
            await speciesPresence.loadLocal()
            // Derive priors as soon as there is data to derive them from. The
            // location fix and this load race, and `refreshPriors` deliberately
            // does nothing (and records nothing) when the grid hasn't loaded —
            // so whichever finishes second has to be the one that triggers it,
            // or a launch where the fix wins leaves every species unresolved.
            if let coordinate = location.currentCoordinate {
                await autoIDSettings.refreshPriors(at: coordinate, using: speciesPresence)
                recordPriorSnapshot()
            }
            await speciesPresence.refreshFromRemote()
        }
        // Classification history: three JSON files, decoded off the main thread.
        // Same reason as the two above — see `ClassificationStore.load()`.
        .task { await classStore.load() }
        .onAppear {
            // First, before anything below reads a persisted setting: the stores
            // are constructed EMPTY on purpose (see each type's `init()` doc
            // comment — their `@State` initializer expressions can re-run any
            // number of times, so nothing with a cost or a side effect may live
            // there). This is where they actually populate, exactly once.
            // `activeModelID` and the pass gates read further down depend on it.
            autoIDSettings.loadPersisted()
            // Before the first frame settles, so a fresh install in simplified
            // view opens already showing the 15–90 kHz band rather than
            // visibly snapping to it.
            applySimplifiedDefaultsIfNeeded()
            audio.activate()
            // Same contract as `audio.activate()` above, and for the same
            // reason — see PulseHaptics.init.
            haptics.activate()

            RecordingUploader.shared.activate()
            RecordingUploader.shared.classStore = classStore
            // Guarded so returning to this view (onAppear re-fires) doesn't
            // re-present a sheet the user has already dismissed this session.
            if !hasCheckedReconsent {
                hasCheckedReconsent = true
                // Contribution is paused (ConsentStore.uploadContributionEnabled
                // == false) — nothing in the current UI can grant consent, so
                // this is the one remaining live path to the full ConsentView.
                // Only matters for a device that granted under a pre-pause
                // build; gate it the same way every other entry point is gated.
                showReconsentPrompt = ConsentStore.uploadContributionEnabled && consent.needsReconsent
            }
            RecordingUploader.shared.retryContextProvider = { [consent] in
                UploadRetryContext(consent: consent)
            }
            // The fan-out point: every captured buffer goes to the spectrogram/FFT
            // pipeline and the WAV recorder in the same closure, so both stay in
            // lock-step with the tap regardless of listen mode.
            audio.bufferSink = { [processor, recorder] buffer in
                processor.process(buffer)
                recorder.append(buffer)
            }
            audio.autoTunePeakProvider = { [processor] in processor.peakFrequency }
            pulseDetector.onPulseStart = { [audio, haptics] freq, level in
                audio.notifyPulseDetected(frequency: freq)
                // Accessibility channel — see PulseHaptics. Deliberately not
                // conditional on a listen mode: for a deaf or hard-of-hearing
                // user this IS the output, not a garnish on the audio.
                haptics.pulse(frequency: freq, level: level)
            }
            pulseDetector.onPulseClassified = { [recorder] result, date in
                recorder.addClassifiedPulse(result: result, date: date)
            }
            pulseDetector.onPulseActiveChanged = { [recorder] active in
                recorder.setPulseActive(active)
            }
            recorder.onRecordingSaved = { [classStore, consent] report in
                // Shared between both calls so RecordingUploader's status
                // updates land on the exact Recording classStore just created.
                let recordingID = UUID()
                classStore.addRecording(id: recordingID, date: report.date, durationSeconds: report.durationSeconds,
                                        species: report.species, confidence: report.confidence,
                                        pulseCount: report.pulseCount, sessionID: report.sessionID,
                                        coordinate: report.coordinate.map {
                                            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                                        },
                                        relativeWavPath: report.relativeWavPath,
                                        spectrogramImage: report.spectrogramImage) { [consent] in
                    // Only runs once the Recording actually exists in classStore.recordings —
                    // see addRecording's doc comment on the race this closes.
                    let docs = CloudStorage.baseDirectory
                    RecordingUploader.shared.handleRecordingSaved(
                        recordingID: recordingID,
                        originalWavURL: docs.appendingPathComponent(report.relativeWavPath),
                        date: report.date, durationSeconds: report.durationSeconds,
                        species: report.species, confidence: report.confidence,
                        coordinate: report.coordinate,
                        consent: consent)
                }
            }
            processor.sampleRate = audio.diagnostics.actualSampleRate
            micCalSettings.load(forMicName: audio.diagnostics.inputName)
            processor.calibrationCurve = micCalSettings.currentCurve(forMicName: audio.diagnostics.inputName)
            pulseDetector.pcmProvider = { [processor] count, endAbsolute in
                processor.pcmSnapshot(count: count, endingAtAbsolute: endAbsolute)
            }
            pulseDetector.autoIDSettings = autoIDSettings
            pulseDetector.store = classStore
            recorder.setActiveModel(id: autoIDSettings.activeModelID)
            recorder.setPassGates(minConfidence: autoIDSettings.minPassConfidence,
                                  minPulseCount: autoIDSettings.minPassPulseCount)
            pulseDetector.coordinateProvider = { [location] in location.currentCoordinate }
            // Lock-screen card. `endOrphanedActivities` clears any card left behind by a
            // crash or force-quit in a previous run — those survive in the system and
            // would otherwise show a frozen readout from a session that ended days ago.
            liveActivity.detector = pulseDetector
            // Reads the controller's own weak detector reference rather than capturing
            // `pulseDetector` here — the closure is stored *on* the detector, so
            // capturing it would be a retain cycle.
            pulseDetector.onPassFinalized = { [liveActivity] in
                liveActivity.updateFromDetector(force: true)
            }
            LiveActivityController.endOrphanedActivities()
            location.store = classStore
            applyBand()
            // Region fix so species priors can be derived from the bundled
            // presence grid for where the user is (see the onChange below) — same
            // lightweight, one-shot fix AutoIDSettingsView already uses, just
            // requested proactively on launch instead of only when that screen is
            // opened. It was a live GBIF query until 2026-08-16.
            location.requestRegionFix()

            // Onboarding's last step sets this right before handing off to
            // ContentView — consumed once here, immediately, so a later
            // .onAppear re-fire (e.g. returning from the background) can't
            // repeat the offer.
            //
            // This used to auto-launch the guided tour; it now only makes the
            // one-off recommended-model offer, and only if the region fix
            // requested just above has already landed. It usually hasn't on a
            // cold first launch, in which case nothing is shown here and the
            // suggestion still reaches the user the way it always did — from
            // AutoID settings.
            // Decided back in `RootView.init`, acted on here — the detector is
            // the first thing that exists to present a sheet over.
            if ReleaseState.shared.shouldShowWhatsNew {
                showWhatsNew = true
            }

            if OnboardingState.shared.justFinishedOnboarding {
                OnboardingState.shared.justFinishedOnboarding = false
                // Not when What's New is about to present: that happens when an
                // update re-ran onboarding, and two sheets racing for the same
                // moment means one of them is silently dropped. The changelog
                // wins — it is the thing that explains why the intro reappeared
                // — and the model suggestion is still reachable from AutoID
                // settings, which is where it lived before this shortcut existed.
                if !ReleaseState.shared.shouldShowWhatsNew {
                    // `requestRegionFix()` just above is a real CoreLocation round
                    // trip — on a cold first launch (the common case) nothing has
                    // come back yet, so checking `location.currentCoordinate`
                    // right here found it nil essentially every time. Offer now
                    // if a fix already happened to land; otherwise flag it and
                    // let the `onChange(of: location.currentCoordinate)` below
                    // pick it up the moment one does.
                    if let coordinate = location.currentCoordinate {
                        offerSuggestedModelIfNeeded(at: coordinate)
                    } else {
                        pendingOnboardingModelOffer = true
                    }
                }
            }

            nudgeTourAfterDelay()
        }
        // Shown once, on the first arrival here after onboarding, if the user's
        // location suggests a model that isn't already active — see the
        // handoff in `.onAppear`. Standalone: dismissing it (either "Use" or "Not Now")
        // just closes it — it does NOT chain into Start Detecting, which stays a
        // separate, deliberate action from the transport bar.
        // Once per build, for someone who already had the app — see
        // `ReleaseState`. Presented from here rather than from `RootView` so it
        // arrives over the detector, with the app fully up, rather than over a
        // screen still assembling itself.
        //
        // Driven by plain `@State` copied out of `ReleaseState` in `.onAppear`,
        // NOT by a `Binding` reading the store directly. A read inside a
        // `Binding`'s getter happens outside `body`'s observation scope, so it
        // registers no dependency and the sheet never presents — which is
        // exactly what it did.
        .sheet(isPresented: $showWhatsNew, onDismiss: {
            ReleaseState.shared.markWhatsNewSeen()
        }) {
            WhatsNewSheet()
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $suggestedModelToOffer) { model in
            SuggestedModelSheet(model: model, speciesChanged: 0,
                                onUse: { autoIDSettings.activeModelID = $0.id })
        }
        // The first-connection calibration offer — see
        // `offerCalibrationIfAppropriate`. The capture it leads to is raised
        // from `onDismiss` rather than from the button, so it is presented over
        // a screen with nothing else on it.
        .sheet(isPresented: $showCalibrationOffer, onDismiss: {
            guard calibrationAccepted else { return }
            calibrationAccepted = false
            showMicCalibration = true
        }) {
            CalibrationOfferSheet(micName: calibrationOfferMicName) {
                calibrationAccepted = true
            }
        }
        .sheet(isPresented: $showMicCalibration) {
            MicCalibrationView(audio: audio, settings: micCalSettings) {
                showMicCalibration = false
            }
        }
        // AudioEngineController.start() sets this exact status string when
        // AVAudioApplication.requestRecordPermission (or a prior denial) blocks
        // capture — surfaced here as an actionable alert instead of leaving users
        // to find the silent "ear" button doing nothing. Pulled into a single
        // extension call (rather than chaining .onChange/.alert inline) because
        // this body's modifier chain is already long enough that the type
        // checker times out on any more inline closures added directly to it.
        .micPermissionAlert(status: audio.status, isPresented: $showMicDeniedAlert)
        // audio.activeSampleRate / activeInputName (not diagnostics.*) in the
        // onChange reads below and in `nyquist`: the diagnostics struct churns at
        // the 15 Hz stats flush, and reading ANY of its fields here invalidates
        // the whole body — which rebuilds the toolbar Menus mid-tap and drops
        // their button actions (same failure the meters/stat cells were scoped
        // out of body for). The mirrors only notify on actual change.
        .onChange(of: audio.activeSampleRate) { _, rate in
            processor.sampleRate = rate
        }
        .onChange(of: audio.activeInputName) { _, name in
            micCalSettings.load(forMicName: name)
            processor.calibrationCurve = micCalSettings.currentCurve(forMicName: name)
            recorder.setInputName(name)
            offerCalibrationIfAppropriate()
        }
        // Plugging the mic in is the moment worth catching, and it is not always
        // the same moment as the input name changing: iOS can report the new
        // port before it makes it the active route. Both hooks funnel into one
        // guarded function rather than one of them trying to be the only trigger.
        .onChange(of: audio.ultrasonicMicAttached) { _, _ in
            offerCalibrationIfAppropriate()
        }
        // **Never suspend a live session.** Suspending the processor behind a
        // full-screen sheet is free when nothing is running and it is what keeps
        // an idle detector cheap — but it stops the FFT outright, so with a
        // session in progress it meant no columns, nothing for the pump to
        // drain, and no detections for as long as Settings or Help was open. A
        // detector that goes deaf because the user opened Help is worse than one
        // that costs some battery while they read it.
        //
        // Paired with `updateColumnDrainOwner` below: the sheet still pauses the
        // *display* (there is nothing to see behind it), so the pump has to take
        // over the draining at the same moment.
        .onChange(of: menuIsOpen) { _, open in
            processor.suspended = open && !audio.isActive
            updateColumnDrainOwner()
        }
        .onChange(of: simplifiedMode) { _, _ in applySimplifiedDefaultsIfNeeded() }
        .onChange(of: bandLow)  { _, _ in applyBand() }
        .onChange(of: bandHigh) { _, _ in applyBand() }
        .onChange(of: autoIDSettings.activeModelID) { _, id in
            pulseDetector.refreshModel()
            recorder.setActiveModel(id: id)
            // minPassConfidence/minPassPulseCount are per-model — switching models
            // switches which values apply.
            recorder.setPassGates(minConfidence: autoIDSettings.minPassConfidence,
                                  minPulseCount: autoIDSettings.minPassPulseCount)
        }
        .onChange(of: audio.isRunning) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
            if !running {
                peakHold.reset()
                // Finalize any in-progress pass so it's saved regardless of why
                // audio stopped (user stop, interruption, listen-mode restart, etc.).
                pulseDetector.finalizePass()
                recorder.audioStopped()
                // Disarm only when the *session* is over, for the reason spelled
                // out below. Keyed to `running`, this fired on every listening
                // mode change too — the engine restart looked exactly like a
                // stop — so cycling the mode mid-pass silently stopped
                // recording, with nothing but `startDetecting` able to re-arm
                // it. Armed is an intent about the session, not a fact about
                // the engine, and it should survive an interruption the session
                // itself survives.
                if !audio.isActive, recorder.isArmed { recorder.setArmed(false) }
                // The menu only makes sense over a live session, and something
                // that ends one without going through the End button would
                // otherwise leave it open over nothing.
                //
                // `isActive`, not the `running` flag this block is keyed to.
                // Cycling listening mode across "off" stops and restarts the
                // engine, so `isRunning` dips false mid-session and this used to
                // shut the menu on every pass through the cycle — the one
                // control in it you are *meant* to tap repeatedly. The session
                // is what the menu belongs to, and `isActive` is the flag that
                // tracks the session rather than the engine. Same distinction,
                // same reason, as `handleSessionButtonTap`.
                if !audio.isActive { showTransportMenu = false }
                // A mic attached mid-session is refused by the calibration
                // offer's own guard — rightly, since calibrating needs the mic
                // and a quiet room — and being refused doesn't mark the offer
                // as made. Without asking again once the session is genuinely
                // over, the question would never come back this launch.
                // `isActive` for the same reason the line above uses it: the
                // engine dips out of `running` on every listening-mode change.
                if !audio.isActive { offerCalibrationIfAppropriate() }
                // Nothing to drain once the engine is down, and a timer left running in
                // the background is pure battery cost. Covers the interruption path too,
                // which deliberately doesn't go through stopDetecting().
                detectionPump.stop()
                // Session teardown is intentionally NOT done here. It's done explicitly
                // by stopDetecting(), which is only called on a deliberate user stop.
                // This preserves the session across transient audio interruptions
                // (phone call, Siri) and listen-mode engine restarts.
            } else {
                // The session button lives in the tab bar, so a run can now be
                // started from any tab — including one where nothing is drawing
                // and the pump has to take the columns.
                updateColumnDrainOwner()
            }
        }
        // CLLocationCoordinate2D isn't Equatable; key onChange off a derived string.
        .onChange(of: location.currentCoordinate.map { "\($0.latitude),\($0.longitude)" }) { _, _ in
            recorder.setCoordinate(location.currentCoordinate.map { ($0.latitude, $0.longitude) })
            // No-ops unless this is the first fix ever or the user has moved far
            // enough since the last one — see refreshPriors' doc comment. Safe to
            // call on every fix rather than gating the call site.
            if let coordinate = location.currentCoordinate {
                Task {
                    await autoIDSettings.refreshPriors(at: coordinate, using: speciesPresence)
                    // A refresh can land mid-outing (the user drove 10 km), which
                    // re-weights everything classified from here on. The store
                    // drops it if nothing actually changed.
                    recordPriorSnapshot()
                }
                if pendingOnboardingModelOffer {
                    pendingOnboardingModelOffer = false
                    offerSuggestedModelIfNeeded(at: coordinate)
                }
            }
        }
        // ContentView.onAppear only fires once per process lifetime (SwiftUI doesn't
        // recreate the WindowGroup's root view on background→foreground), so without
        // this the model/prior location check would only ever re-run if the user
        // happened to open AutoID settings (whose own onAppear re-requests a fix).
        // Re-requesting on every return to foreground makes "on app open" actually
        // mean "every time the app opens", not just the very first cold launch.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { location.requestRegionFix() }
            // Saves of the pass/recording/session logs are coalesced on a few
            // seconds' throttle (see ClassificationStore's persistence section).
            // Leaving the foreground is the last reliable moment to land a
            // deferred one — a force-quit or a jetsam kill from here on gets no
            // further notice, and on a long night that is exactly when it happens.
            if phase != .active { classStore.flushPendingWrites() }
            updateColumnDrainOwner()
        }
        // Switching tabs is now a second way for the render loop to stop
        // drawing — see `updateColumnDrainOwner`.
        .onChange(of: section) { _, _ in updateColumnDrainOwner() }
        // Opening the transport menu is how the tour shows the Record and Listen
        // controls, which otherwise only exist while it's open. Closed again for
        // every other step, so the menu isn't sitting over the panes the earlier
        // steps are pointing at.
        .onChange(of: tourIndex) { _, index in
            guard tourActive else { return }
            let steps = TourScript.steps(simplified: simplifiedMode)
            showTransportMenu = steps.indices.contains(index) && steps[index].opensTransportMenu
        }
        .onChange(of: tourActive) { _, active in
            if !active { showTransportMenu = false }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .overlayPreferenceValue(VersionFooterAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if showBatSwarm, let anchor {
                    let rect = proxy[anchor]
                    BatSwarmOverlay(origin: CGPoint(x: rect.midX, y: rect.midY))
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Adaptive layout

    /// Wraps whichever concrete layout applies so the tuning overlay floats over
    /// both of them — portrait and iPad landscape — from one place.
    @ViewBuilder private var detectorLayout: some View {
        ZStack {
            detectorLayoutBody
            if showTuningOverlay {
                LiveTuningOverlay(
                    audio: audio,
                    pulseDetector: pulseDetector,
                    haptics: haptics,
                    snippetSettings: snippetSettings,
                    bandLow: $bandLow, bandHigh: $bandHigh,
                    timeWindowSeconds: $timeWindowSeconds,
                    maxFrequency: nyquist,
                    onBandChange: applyBand,
                    onClose: { showTuningOverlay = false }
                )
                .transition(.opacity)
            }
        }
    }

    /// iPhone is portrait-only now (the supported orientations are set per-idiom
    /// in the build settings), so the only landscape left to serve is the iPad's
    /// — which has the width for its own two-panel arrangement. The old
    /// iPhone-landscape layout and its whole family of `landscape*` panels are
    /// gone: they cost a bottom bar the vertical space it needed, and they had
    /// never once been run against real bats.
    @ViewBuilder private var detectorLayoutBody: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad landscape gets its own dedicated 2-panel layout (below); iPad
            // portrait falls through to the same stacked layout iPhone uses.
            GeometryReader { geo in
                if geo.size.width > geo.size.height {
                    ipadLandscapeLayout
                } else {
                    portraitLayout
                }
            }
        } else {
            portraitLayout
        }
    }

    /// iPad-landscape default: same stacked structure as `portraitLayout` (full-width
    /// stats bar on top, spectrogram on bottom) — the only change is the middle row,
    /// where a permanently-visible Species ID list is split 50/50 with the pulse-view
    /// card, instead of the pulse card's own species-ID toggle.
    ///
    /// Species ID sits on the left and the pulse close-up on the right, fixed
    /// (Niall's call, 2026-08-17). The pair used to be the other way round, and
    /// in simplified view the pulse card was additionally forced to species ID —
    /// so the row was the same list twice. `padLandscapePulseShowsSpeciesID` is
    /// what stops that.
    private var ipadLandscapeLayout: some View {
        VStack(spacing: 10) {
            // Same arrangement as portrait — see its comment for why the
            // GeometryReader sits below the content-sized stats card.
            statsBlock
            GeometryReader { geo in
                let spacing: CGFloat = 10
                let flex = max(120, geo.size.height - spacing)
                VStack(spacing: spacing) {
                    HStack(spacing: spacing) {
                        speciesListBlock
                        pulseCard(showsSpeciesID: padLandscapePulseShowsSpeciesID)
                    }
                    .frame(height: flex * 0.42)
                    spectrogramBlock.frame(height: flex * 0.58)
                }
            }
            appFooter
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }

    /// Permanently-visible Species ID panel, the left half of the middle row in
    /// `ipadLandscapeLayout` — not toggled like the pulse/spectrogram cards'
    /// own species-ID views. No thumbnails here: the pulse close-up is the panel
    /// right next to it, which is the condition the thumbnails in
    /// `pulsePanelContent` exist to substitute for.
    private var speciesListBlock: some View {
        VStack(spacing: 0) {
            panelHeader("Species ID") { EmptyView() }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)
            SpeciesFeedView(store: classStore, guide: speciesGuide, presenceStore: speciesPresence, activeSessionID: classStore.activeSessionID, sessionStart: feedSessionStart, autoIDActive: autoIDSettings.activeModelID != nil)
        }
        .panelCard()
    }

    // MARK: The bar

    /// Real system tab bar on iOS 26, hand-built floating one below it. See
    /// AppTabBar.swift for why both exist and what each gives up.
    @ViewBuilder private var tabHost: some View {
        if #available(iOS 26.0, *) {
            systemTabs
        } else {
            legacyTabs
        }
    }

    /// One navigation path per section. Separate paths for the same reason the
    /// stacks are separate — a push in Sessions must not unwind when you visit
    /// Species — but held here, rather than left implicit inside each stack,
    /// because the guide's has to be EDITED and not only appended to: starting
    /// a comparison from a species page replaces that page.
    @State private var sectionPaths: [AppSection: NavigationPath] = [:]

    private func pathBinding(for section: AppSection) -> Binding<NavigationPath> {
        Binding(get: { sectionPaths[section] ?? NavigationPath() },
                set: { sectionPaths[section] = $0 })
    }

    /// Each section's screen. Each owns its own `NavigationStack` — the
    /// section views already set their own titles and toolbar items and assume
    /// they are inside one, and a tab bar wants a stack per tab so a push in
    /// Sessions doesn't unwind when you visit Species.
    @ViewBuilder private func sectionScreen(_ s: AppSection) -> some View {
        NavigationStack(path: pathBinding(for: s)) {
            Group {
                switch s {
                case .detector: detectorScreen
                case .sessions: SessionsView(store: classStore, settings: autoIDSettings, consent: consent,
                                            micCalSettings: micCalSettings)
                case .species:
                    SpeciesExplorerView(store: speciesGuide, presenceStore: speciesPresence, userCoordinate: location.currentCoordinate)
                        // Only the guide can offer this: it is the only stack
                        // whose path this view owns, and swapping a page for
                        // its comparison needs the path. See SpeciesCompareMode.
                        .environment(\.speciesCompareMode, .replacesPage { first, second in
                            var path = sectionPaths[.species] ?? NavigationPath()
                            // Drop the species page being compared FROM, so the
                            // comparison takes its place and Back reaches the
                            // list underneath rather than the page you left.
                            if !path.isEmpty { path.removeLast() }
                            path.append(SpeciesGuideDestination.compare(first, second))
                            sectionPaths[.species] = path
                        })
                }
            }
            // Reserves the height of the hand-built bar, so the last row of a
            // list isn't sitting underneath it. Zero from iOS 26, where the real
            // tab bar contributes its own height to the safe area and adding
            // this on top would reserve the space twice — see
            // `SessionButtonMetrics.clearance`. Applied inside the stack, not
            // around it: a `NavigationStack` does not forward a safe-area inset
            // applied outside it down to the content within.
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: SessionButtonMetrics.clearance)
            }
        }
    }

    /// Spotlight rects for the things the tab bar draws — the three tabs and the
    /// session button — converted from the locator's window coordinates into the
    /// overlay's own space.
    ///
    /// These cannot come from `.tourTarget` like every other target does. On
    /// iOS 26 a `Tab`'s label is rendered by the bar, outside the view tree the
    /// anchor preference travels through, so an anchor placed on one never
    /// arrives; the step would fall back to a centred card and the tour would
    /// talk about a button it wasn't pointing at. Below iOS 26 the bar is
    /// hand-built from ordinary views whose `.tourTarget` anchors work fine —
    /// the merge at the call site prefers these when present and keeps those
    /// otherwise, so both paths land on the real control.
    private func tabBarTargets(in proxy: GeometryProxy) -> [TourID: CGRect] {
        // The proxy's own global frame is the bridge between window space and
        // this overlay's space; they share an origin only when nothing insets
        // the overlay, which is not something to assume.
        let host = proxy.frame(in: .global)
        func local(_ windowRect: CGRect) -> CGRect {
            windowRect.offsetBy(dx: -host.minX, dy: -host.minY)
        }

        var targets: [TourID: CGRect] = [:]
        for (section, frame) in sessionButtonLocator.tabFramesInWindow {
            targets[.tab(section)] = local(frame)
        }
        if let button = sessionButtonLocator.frameInWindow {
            targets[.start] = local(button)
        }
        return targets
    }

    /// The detector, plus the nav-bar chrome that used to be written inline on
    /// the app's single shared stack.
    private var detectorScreen: some View {
        detectorLayout
            .navigationTitle("Detector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The slot the logo menu used to fill, before the bottom bar
                // took its job. A sun clock earns a permanent place there:
                // bats are busiest in the hours after sunset and before
                // sunrise, and this says which of those you are standing in.
                ToolbarItem(placement: .topBarLeading) {
                    SunWindowPill(coordinate: location.currentCoordinate)
                        .tourTarget(.sunClock)
                }
                // Left of the gear, and only until the tour has been seen — see
                // `OnboardingState.shouldOfferTour`. Declaration order is what
                // puts it there: trailing items are laid out left to right in the
                // order they're declared.
                //
                // "Bats near you" swaps in once the tour offer is gone rather
                // than sitting alongside it — someone who hasn't been shown
                // around the app yet doesn't need a second unexplained icon
                // competing with the tour prompt for the same trailing slot.
                if OnboardingState.shared.shouldOfferTour(simplified: simplifiedMode) {
                    ToolbarItem(placement: .topBarTrailing) { tourButton }
                } else {
                    ToolbarItem(placement: .topBarTrailing) { nearbySpeciesButton }
                }
                ToolbarItem(placement: .topBarTrailing) { optionsMenu }
            }
            // Pin the nav bar to a fully OPAQUE background instead of Liquid
            // Glass's default adaptive-on-scroll material. `.toolbarBackground(
            // .visible, for:)` alone (the boolean visibility API) only forces the
            // system's glass material to always render — that material is still
            // translucent, so the toolbar buttons kept sampling through it, and
            // any perpetually-animating content sitting near the bar (e.g.
            // MicStatusPill's repeatForever breathe/flash in statsStrip, which
            // sits right under the bar in portraitLayout) still shimmered through
            // the glass. An explicit solid Color background (the ShapeStyle
            // overload) blocks that sampling outright. Same root cause the tour
            // dim overlay hit.
            .toolbarBackground(Color.black, for: .navigationBar)
            // The bar STAYS UP during the tour (2026-08-17, Niall's call: the
            // tour should show the screen as it really is, and hiding the bar
            // took the sun clock with it — a permanent piece of the Detector
            // that the tour then couldn't point at).
            //
            // It used to be hidden, to stop the dim overlay's animating cutout
            // ring reading as motion to the buttons above it. What makes keeping
            // it safe is the opaque `.toolbarBackground` above: the buttons no
            // longer sample anything behind the bar, so there is nothing for the
            // ring's animation to show through. The `.animation(nil,
            // value: tourActive)` stays regardless — it keeps the bar out of the
            // 0.25 s dim-fade transaction, which is what stopped the pulsing
            // getting stuck oscillating.
            .animation(nil, value: tourActive)
    }

    /// The real system tab bar.
    ///
    /// The session button is the reason this looked impossible: the design needs
    /// a control detached to the trailing side of the bar, which is not something
    /// you can add to a `TabView`. But it is something the system already does —
    /// `Tab(role: .search)` is rendered as its own separate circle beside the bar
    /// rather than as another item inside it. That is the App Store's
    /// arrangement, and it is a real tab, so the bar stays entirely the system's.
    ///
    /// The session button is still not a destination: selecting it is intercepted
    /// in `tabSelection` below, so the selection never moves off the section you
    /// were on.
    @available(iOS 26.0, *)
    private var systemTabs: some View {
        TabView(selection: tabSelection) {
            ForEach(AppSection.allCases, id: \.self) { s in
                // A `Label` rather than `systemImage:`, because Species' glyph is
                // drawn artwork from the asset catalog rather than a symbol. The
                // system bar sizes and tints a `Tab` label itself, so the icon is
                // handed over bare — no `sized(_:)` here, unlike the legacy bar.
                Tab(value: TabSelection.section(s)) {
                    // The recording glow rides on the *screen*, not on the tab
                    // host, and that placement is the point: everything drawn
                    // here is under the bar, so the bar's glass ends up over the
                    // glow and occludes and refracts it for us. Hung off every
                    // section rather than the detector alone, because the
                    // session button is on every tab and so is what it says.
                    //
                    // The overlay is anchored to the screen's bottom edge, which
                    // stops above the bar — the glow reaches down past it
                    // because SwiftUI doesn't clip overlays to their parent's
                    // bounds. See `recordingGlowOverlay` for the offsets.
                    sectionScreen(s)
                        .overlay(alignment: transportMenuAlignment) { recordingGlowOverlay }
                } label: {
                    Label { Text(s.rawValue) } icon: { s.iconImage }
                        // So the tour can find this tab in the bar's own view
                        // tree and spotlight it — a `.tourTarget` here would not
                        // survive the trip out of a `Tab` label. Same mechanism
                        // as `sessionTabLabel` below.
                        .accessibilityIdentifier(SessionButtonLocator.tabIdentifier(s))
                }
            }
            // Never actually selected, so its content is never shown — the role
            // is being used for the *button* it produces, not for a screen.
            // `Color.clear` rather than `EmptyView()` because a tab with no
            // content is not a tab the system will lay out.
            Tab(value: TabSelection.sessionControl, role: .search) {
                Color.clear
            } label: {
                sessionTabLabel
            }
        }
    }

    /// Label for the system bar's detached circle. The system draws the glass
    /// and the circle; this is only what goes inside it.
    ///
    /// The listening-ear animation the old play/stop button used can't come
    /// along here — a `Tab`'s label is rendered by the bar, outside the normal
    /// view tree, so a Lottie view in it is not something to rely on. The glyph
    /// carries the state instead, which is what the VoiceOver label has always
    /// had to do anyway.
    private var sessionTabLabel: some View {
        Label {
            Text(audio.isActive ? "Session controls" : "Start session")
        } icon: {
            Image(uiImage: sessionGlyph)
                .renderingMode(.original)
                .tourTarget(.start)
        }
        // How `SessionButtonLocator` finds this button in the view hierarchy.
        // Both of these are load-bearing, not decoration: the identifier is the
        // exact match, and the label is the fallback for when the bar rebuilds
        // the item as its own view and carries only the accessibility text
        // across. Changing either string without changing the locator's copy
        // leaves the glow and the tap catcher with nothing to attach to.
        .accessibilityIdentifier(SessionButtonLocator.accessibilityIdentifier)
    }

    /// The session button's glyph, drawn into a bitmap rather than handed over
    /// as a `systemImage`.
    ///
    /// **Everything SwiftUI offers for styling a `Tab` label is ignored by the
    /// bar**, and each of these was tried and measured before this existed:
    /// `.imageScale` and `.font(.system(size:))` do not change its size;
    /// `.monochrome` is repainted white whatever colour it is given; a bare
    /// glyph with no enclosing circle loses a palette override and comes back
    /// white; and `.symbolEffect` never animates, because the bar renders the
    /// label as a still image.
    ///
    /// Baking the symbol into a `UIImage` with `.alwaysOriginal` settles all of
    /// them at once: the colour is in the pixels, so there is nothing left for
    /// the bar to override, and the point size is ours. It is also what lets
    /// the live state be bare waveform bars — with a `systemImage` the only way
    /// to hold a colour was to keep a circle behind the glyph, which made the
    /// bars small and put a disc around them.
    /// Sized per symbol, and sized *small*, because nothing downstream will
    /// rein this in: a baked bitmap is drawn at exactly the size it was made,
    /// so a point size that looks reasonable in isolation lands as a glyph
    /// filling most of the button. The reference is the system-drawn glyph
    /// this replaced, which measured **23pt across** in a 58pt circle. These
    /// numbers put all three marks within a couple of points of that.
    ///
    /// A point size is roughly the glyph's cap height, not its width, so they
    /// are not interchangeable between symbols: the same value gives a wide
    /// play triangle and a narrow set of waveform bars very different presence.
    private var sessionGlyph: UIImage {
        let pointSize: CGFloat = switch sessionSymbol {
        case "waveform": 21
        case "play.fill": 19
        default: 18
        }
        // The waveform is drawn heavier than the others on purpose. Its bars are
        // thin enough at this size that anti-aliasing eats their colour — at
        // semibold they came out a muddy half-strength orange rather than the
        // accent, measured at 45% of the intended value.
        let weight: UIImage.SymbolWeight = sessionSymbol == "waveform" ? .bold : .semibold
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return UIImage(systemName: sessionSymbol, withConfiguration: config)?
            .withTintColor(UIColor(sessionSymbolTint), renderingMode: .alwaysOriginal)
            ?? UIImage()
    }

    /// A play triangle when idle, waveform bars while live, a cross when its
    /// menu is open. All three are bare glyphs — no `.circle` enclosure — which
    /// only works because `sessionGlyph` bakes the colour in.
    private var sessionSymbol: String {
        if showTransportMenu { return "xmark" }
        return audio.isActive ? "waveform" : "play.fill"
    }

    /// Orange while a session runs, white when idle. Idle is deliberately the
    /// same white as the tab glyphs beside it: nothing is happening, so the
    /// button has nothing to shout about, and orange then means "live" and only
    /// that.
    ///
    /// This was `.primary` until 2026-08-16 and rendered near-black — a
    /// semantic colour is resolved in the *bar's* environment, not ours, and
    /// the bar resolves it as though its glass were light, which the app's
    /// `.preferredColorScheme(.dark)` does not reach into. It no longer matters
    /// now the glyph is a baked bitmap, but the rule is worth keeping: concrete
    /// colours only anywhere near this bar.
    private var sessionSymbolTint: Color {
        audio.isActive ? .batAccent : .white
    }

    /// Turns a tap on the session button into either starting a session or
    /// opening the transport menu, and lets every other tab select normally.
    ///
    /// Writing the selection is the only hook the system bar gives us, and it is
    /// enough: because `.sessionControl` is never stored, the bar keeps showing
    /// the tab you were on, which is the correct state — you did not go anywhere.
    private var tabSelection: Binding<TabSelection> {
        Binding(
            get: { .section(section) },
            set: { selected in
                switch selected {
                case .sessionControl:  handleSessionButtonTap()
                case .section(let s):
                    section = s
                    // Any tab change is a decision to look at something else;
                    // leaving the menu hanging over the new screen would be a
                    // control pointing at a session you've navigated away from.
                    showTransportMenu = false
                }
            }
        )
    }

    /// The pre-26 bar: every section kept alive at once, with a hand-built
    /// floating bar over them.
    ///
    /// A `ZStack` of every screen rather than a `switch` because every tab's
    /// view has to stay alive across switches — most of all the detector, whose
    /// `SpectrogramView` owns a Metal view and a live render loop that must not
    /// be torn down and rebuilt every time you glance at Sessions. Hidden screens
    /// are also removed from hit testing and from accessibility, so they can
    /// neither be tapped through nor read out.
    private var legacyTabs: some View {
        ZStack {
            ForEach(AppSection.allCases, id: \.self) { s in
                let isSelected = section == s
                sectionScreen(s)
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
            }
        }
        // Before the bar, so it lands underneath it — same arrangement as the
        // iOS 26 path, where the glow goes on the screen and the bar's glass
        // covers it.
        .overlay(alignment: transportMenuAlignment) { recordingGlowOverlay }
        .overlay(alignment: .bottom) { legacyFloatingBar }
    }

    /// Two separate glass objects, side by side, and deliberately NOT in a shared
    /// `GlassEffectContainer` — a container unions the glass of everything inside
    /// it into a single shape, and over the spectrogram that union reads as one
    /// wide slab behind both rather than a bar and a detached round button.
    private var legacyFloatingBar: some View {
        HStack(spacing: SessionButtonMetrics.gap) {
            LegacyTabBar(selection: Binding(
                get: { section },
                set: { section = $0; showTransportMenu = false }
            ))
            sessionButton
        }
        .padding(.horizontal, SessionButtonMetrics.horizontalPadding)
        .padding(.bottom, SessionButtonMetrics.bottomPadding)
        // The tour hides the nav bar for the same reason (see `detectorScreen`);
        // the bottom bar sits just as close to the dim overlay's cutout.
        .opacity(tourActive ? 0 : 1)
        .animation(nil, value: tourActive)
    }

    private var sessionButton: some View {
        SessionButton(isSessionActive: audio.isActive,
                      isMenuOpen: showTransportMenu,
                      action: handleSessionButtonTap)
    }

    // MARK: Transport menu

    /// First tap starts a session — the same action the old play button had, so
    /// whether the recorder arms itself is still the auto-record setting's call.
    /// Once one is running, the button is how you reach the controls that used to
    /// sit in the control bar.
    private func handleSessionButtonTap() {
        // `isActive`, not `isRunning` — a listen-mode change that crosses "off"
        // stops and restarts the engine, so `isRunning` flickers false for a
        // moment. Reading it here would let a tap in that window start a second
        // run on top of the live one. This is the same distinction the old
        // play/stop button drew for its icon. See AudioEngineController.isActive.
        if audio.isActive {
            withAnimation(.bouncy(duration: 0.35)) { showTransportMenu.toggle() }
        } else {
            startDetecting()
        }
    }

    /// Where the menu grows from. The system puts the tab bar at the bottom of
    /// the window on iPhone and at the top on iPad, so the menu has to hang off
    /// the correct end of the screen or it opens off the edge.
    private var transportMenuIsBelowBar: Bool {
        if #available(iOS 26.0, *) {
            return UIDevice.current.userInterfaceIdiom == .pad
        }
        // The legacy bar is hand-placed at the bottom on every idiom.
        return false
    }

    private var transportMenuAlignment: Alignment {
        transportMenuIsBelowBar ? .topTrailing : .bottomTrailing
    }

    /// Drawn as an overlay on the whole tab host rather than as a `.popover`:
    /// a popover on iPhone adapts into a sheet unless told not to, and brings
    /// its own arrow and chrome.
    ///
    /// It hangs off the button's *measured* frame (`SessionButtonAttached`), so
    /// it grows out of the button on every device. It was pinned to the
    /// window's trailing edge with the bar's own metrics until 2026-08-16,
    /// which is near enough on iPhone and plainly wrong on iPad, where the
    /// button sits in the middle of a pill at the top and the menu appeared
    /// over at the screen's edge with nothing above it.
    @ViewBuilder private var transportMenuOverlay: some View {
        if showTransportMenu {
            ZStack {
                // Tap-anywhere-else to dismiss. Behind the menu, and deliberately
                // not dimming: the spectrogram underneath is live, and this menu
                // is opened mid-pass to change what you're hearing.
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture {
                        withAnimation(.bouncy(duration: 0.35)) { showTransportMenu = false }
                    }

                SessionButtonAttached(locator: sessionButtonLocator,
                                      placement: transportMenuIsBelowBar ? .below : .above,
                                      gap: TransportMenuMetrics.gap) { buttonWidth in
                    TransportMenu(
                        recorder: recorder,
                        // Matched to the button it grows out of, so the two read
                        // as one object opening rather than a panel that happens
                        // to be nearby. Floored, because the button is only ~36pt
                        // on iPad and the captions have to survive.
                        width: max(buttonWidth, TransportMenuMetrics.minimumWidth),
                        listenIcon: listenIcon,
                        listenName: listenModeName,
                        isListening: audio.isListening,
                        // Arming is a single decision, so the menu gets out of the
                        // way and hands the screen back. Listening mode is the
                        // opposite: it is a cycle of four, found by ear, and
                        // reopening the menu between each tap would make choosing
                        // between them four times the work — so that one leaves the
                        // menu standing.
                        onToggleRecord: {
                            withAnimation(.bouncy(duration: 0.35)) { showTransportMenu = false }
                            toggleRecording()
                        },
                        onCycleListen: advanceListenMode,
                        onEndSession: {
                            withAnimation(.bouncy(duration: 0.35)) { showTransportMenu = false }
                            showEndSessionConfirm = true
                        }
                    )
                    .transition(.scale(scale: 0.6, anchor: transportMenuIsBelowBar ? .top : .bottom)
                        .combined(with: .opacity))
                }
            }
            .ignoresSafeArea(.keyboard)
        }
    }

    /// The one-shot "you're not recording" nudge. It used to be a popover on the
    /// record button in the control bar; with that button now living inside a
    /// menu that is usually closed, there is nothing to hang a popover on, so it
    /// is drawn against the bar in the same place the transport menu appears —
    /// which is where it is pointing anyway.
    /// Centred, not trailing like the rest of the chrome around the bar. The
    /// pill is a status readout rather than something hanging off the session
    /// button, and on the globe it is laid out centred alongside the "near you"
    /// pill (see `SpeciesExplorerView.globeFooter`) — it should not jump to the
    /// edge on every other tab.
    ///
    /// Vertical placement still follows the bar, which is why this borrows
    /// `transportMenuIsBelowBar`/`transportMenuInset` rather than inventing its
    /// own clearance.
    private var exportPillAlignment: Alignment {
        transportMenuIsBelowBar ? .top : .bottom
    }

    /// Cleared from the bar with the same inset as `notRecordingNudgeOverlay` —
    /// the bar it has to clear is the same bar.
    @ViewBuilder private var sessionExportOverlay: some View {
        // Nothing here while a screen is showing the pill in its own layout —
        // see SessionExportManager.inlineHosts.
        SessionExportBanner(manager: exportManager)
            .opacity(exportManager.inlineHosts == 0 ? 1 : 0)
            .allowsHitTesting(exportManager.inlineHosts == 0)
            .padding(.horizontal, SessionButtonMetrics.horizontalPadding)
            .padding(transportMenuIsBelowBar ? .top : .bottom, transportMenuInset)
            // Keyed on the job's identity, not the job: the fraction updates
            // several times a second and animating those would leave the card
            // permanently mid-transition.
            .animation(.easeInOut(duration: 0.25), value: exportManager.job?.id)
    }

    @ViewBuilder private var notRecordingNudgeOverlay: some View {
        if showNotRecordingNudge {
            VStack(alignment: .leading, spacing: 10) {
                Text("Just so you know, you're not recording.")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Tap the session button and arm Record.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Don't remind me") {
                        suppressNotRecordingNudge = true
                        showNotRecordingNudge = false
                    }
                    .font(.caption)
                    Spacer()
                    Button("Close") { showNotRecordingNudge = false }
                        .font(.caption.weight(.semibold))
                }
            }
            .padding(14)
            .frame(width: 260, alignment: .leading)
            .liquidGlass(in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .padding(.horizontal, SessionButtonMetrics.horizontalPadding)
            .padding(transportMenuIsBelowBar ? .top : .bottom, transportMenuInset)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    /// An invisible disc sitting exactly over the system's session button,
    /// taking the tap before the bar ever sees it.
    ///
    /// **This was meant to stop the Detector indicator blinking, and it does
    /// not. Don't spend an afternoon tuning it — it cannot work.** The button is
    /// a `Tab`, and the only hook a `TabView` gives us is its selection binding,
    /// so the bar moves its own indicator onto the tapped tab, we refuse to
    /// store that selection, and it animates back. Off and on, every time you
    /// open the transport menu.
    ///
    /// The idea was for the touch never to reach the bar. A SwiftUI overlay
    /// cannot do that. A hierarchy dump from an iPad (2026-08-17) shows the
    /// hosting view has three subviews — the locator's probe, the TabView's
    /// host, and a dimming view — and nothing for this catcher, because SwiftUI
    /// draws it into the hosting view's own layer rather than as a `UIView`.
    /// UIKit hit-tests through real subviews, reaches the bar's item cell inside
    /// the TabView's host, and gives it the touch. There is no view here to
    /// block with, so position is beside the point.
    ///
    /// Left in place on Niall's call (2026-08-17): the blink is cosmetic, the
    /// menu opens and the tab never changes. What would actually fix it is not
    /// making the button a `Tab` at all — see `Context.md` §16. **If the
    /// transport menu ever starts flicking open and shut on one tap, suspect
    /// this**: the tap gesture here still fires alongside the bar's own
    /// handling, which toggles the menu twice. Deleting this whole view is then
    /// the fix.
    ///
    /// Sized to the button, and positioned from the button's *measured* frame
    /// rather than from our metrics — see `SessionButtonLocator`. Until that
    /// frame is known it draws nothing at all, deliberately: an invisible tap
    /// target in a guessed position is the worst thing on this screen, and on
    /// iPad the guess landed on the Settings gear.
    ///
    /// The `.sessionControl` case in `tabSelection` stays as the fallback: this
    /// catcher is a plain tap gesture, so VoiceOver and keyboard activation
    /// still go through the real tab, and so does any tap this misses.
    @ViewBuilder private var sessionButtonTapCatcher: some View {
        if #available(iOS 26.0, *) {
            SessionButtonAnchored(locator: sessionButtonLocator) { size in
                Circle()
                    .fill(sessionTapCatcherTint)
                    // The button's own measured size, never padded outwards.
                    // It sits next to a real tab item, and a catcher that
                    // overhangs would swallow taps meant for that instead —
                    // far worse than the blink this exists to stop.
                    .frame(width: size.width, height: size.height)
                    .contentShape(.circle)
                    .onTapGesture { handleSessionButtonTap() }
                    // The real tab underneath carries the label and the traits;
                    // announcing this as well would read the control out twice.
                    .accessibilityHidden(true)
            }
        }
    }

    /// Normally clear. Flip to a visible colour to check the catcher is landing
    /// on the button — it cannot be verified by tapping in a simulator, but a
    /// coloured disc that covers the button exactly is the same proof.
    private var sessionTapCatcherTint: Color { .clear }

    /// The pulsing light behind the session button while listening, placed on
    /// the button's measured frame. Drawn on the *screen* rather than the tab
    /// host so it lands under the bar and the glass lights it — see
    /// `SessionGlow`.
    ///
    /// Mounted on `audio.isActive`, not `recorder.isArmed`: this glow reads as
    /// "the session is live," and listening can run with recording stopped.
    /// Gating on `isArmed` used to tear the glow's `@State` down the instant
    /// recording was stopped from the transport menu, even though listening
    /// carried on — the button's own icon still looked live while the glow
    /// behind it vanished.
    @ViewBuilder private var recordingGlowOverlay: some View {
        if audio.isActive {
            SessionButtonAnchored(locator: sessionButtonLocator) { size in
                SessionGlow(audio: audio, recorder: recorder, buttonSize: size)
                    // Fades in and out with listening rather than snapping —
                    // the glow appearing at full strength the instant a
                    // session starts reads as a glitch rather than a state
                    // change.
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: audio.isActive)
            }
        }
    }

    /// Clears the bar and the session button, so the menu starts where the
    /// button ends. On iOS 26 the system owns the bar's exact inset, so this is
    /// the closest honest approximation of it — worth checking on device.
    private var transportMenuInset: CGFloat {
        SessionButtonMetrics.bottomPadding
            + SessionButtonMetrics.diameter
            + TransportMenuMetrics.gap
    }

    /// Records the priors in force against the running session, if there is one.
    private func recordPriorSnapshot(sessionID: UUID? = nil) {
        guard let data = autoIDSettings.priorSnapshotData else { return }
        classStore.recordPriorSnapshot(modelID: data.modelID, priors: data.priors,
                                       disabled: data.disabled, sessionID: sessionID)
    }

    /// Offers to calibrate a microphone the first time it turns up, if this is a
    /// good moment to ask. Safe to call as often as you like — every condition
    /// is checked here rather than at the call sites.
    ///
    /// **Why this exists.** Calibration used to be a step in onboarding, which
    /// asked people to calibrate hardware they had not plugged in yet: a step
    /// that could only fail, and one that has since moved out to Settings. But
    /// "it's in Settings" only helps someone who knows to look. The moment the
    /// mic is actually attached is the first moment the offer makes any sense,
    /// and it is the moment the user is most likely to act on it.
    ///
    /// **What it deliberately will not interrupt.** Not while capture is
    /// running — calibration needs quiet and its own use of the mic, so asking
    /// mid-session is both wrong and destructive. Not over the guided tour, the
    /// What's New sheet, the model suggestion, or anything else already
    /// presented: a sheet raised over a sheet is dropped silently, and the one
    /// that would be lost here is the one the user is currently reading.
    /// Nothing is lost by waiting — the mic stays plugged in, and the next
    /// route change or launch asks again.
    private func offerCalibrationIfAppropriate() {
        // `isActive` as well as `isRunning`: the engine drops out of `running`
        // for a moment on every listening-mode change, and a session is very
        // much still in progress across that dip.
        guard audio.ultrasonicMicAttached, !audio.isRunning, !audio.isActive else { return }
        guard !tourActive, !showWhatsNew, !showCalibrationOffer, !showMicCalibration,
              suggestedModelToOffer == nil, !menuIsOpen else { return }

        let name = audio.activeInputName
        guard micCalSettings.shouldOfferCalibration(forMicName: name) else { return }

        micCalSettings.recordCalibrationOffered(forMicName: name)
        // Safe to read `diagnostics` here: this runs from an `onChange` closure,
        // not from `body`, so it registers no observation dependency.
        calibrationOfferMicName = audio.diagnostics.micDisplayName
        showCalibrationOffer = true
    }

    /// Exactly one owner drains FFT columns at a time (Context.md §7): the Metal
    /// render loop while it is actually drawing, the background pump in every
    /// other case.
    ///
    /// **The test is "is the render loop drawing", not "is the detector the
    /// selected tab".** Those came apart twice. The tab bar was the first: before
    /// it, leaving the detector destroyed the spectrogram outright and nothing
    /// took over, so a run kept capturing audio while quietly detecting nothing
    /// for as long as you were reading Sessions.
    ///
    /// The second was `menuIsOpen`, and it survived that fix (found 2026-08-17).
    /// A full-screen sheet — Settings, Help, the location-change summary —
    /// pauses the Metal view while the Detector is still the selected tab, so
    /// this function saw nothing wrong and left the pump stopped. A session ran
    /// on, deaf, for as long as the sheet was up. `SpectrogramView`'s own
    /// `isPaused` is the authority on whether it is drawing, and this now asks
    /// the same question it does.
    private func updateColumnDrainOwner() {
        if scenePhase == .active && section == .detector && !menuIsOpen {
            detectionPump.stop()
        } else if audio.isRunning {
            detectionPump.start(processor: processor, detector: pulseDetector)
        } else {
            detectionPump.stop()
        }
    }

    /// Raises `suggestedModelToOffer` if `coordinate` suggests a model that
    /// isn't already active. Shared by the `.onAppear` handoff from onboarding
    /// and, when that handoff finds no fix ready yet, by the
    /// `pendingOnboardingModelOffer` follow-up in the coordinate `onChange` —
    /// see that flag's doc comment for why a single synchronous check wasn't
    /// enough.
    private func offerSuggestedModelIfNeeded(at coordinate: CLLocationCoordinate2D) {
        guard let suggested = ModelRegistry.suggestedModel(for: coordinate),
              suggested.id != autoIDSettings.activeModelID else { return }
        suggestedModelToOffer = suggested
    }

    /// Opens the tour's popover by itself, once per install, `tourNudgeDelay`
    /// after the first arrival at the detector.
    ///
    /// The button alone was not enough: it is one small glyph in a nav bar, and a
    /// first-time user has no reason to suspect there is a tour behind it.
    /// `tourNudgeDelay` is chosen to land *after* the screen has stopped being
    /// brand new — long enough that the person has looked around and formed the
    /// question the tour answers, short enough that they have not yet given up
    /// on it.
    ///
    /// Three conditions, and all three are about not arriving rudely:
    ///
    /// - **The tour button must be on screen**, since that is what the popover is
    ///   anchored to. If the user has already finished the tour there is nothing
    ///   to nudge towards.
    /// - **Nothing else may be up.** A popover presented while a sheet is
    ///   dismissing is dropped silently (CLAUDE.md), and one presented over the
    ///   guided tour would be pointing at a screen the tour has taken over.
    /// - **The Detector must be the visible section.** The anchor lives in that
    ///   nav bar; from Species or Sessions the popover has nothing to hang on.
    ///
    /// If those aren't met at `tourNudgeDelay` it keeps checking, briefly, rather
    /// than giving up on the first miss — a first-run user is quite likely to be
    /// inside a sheet or on another tab at exactly that moment. After
    /// `tourNudgeWindow` it stops trying and leaves the button to do its job.
    private func nudgeTourAfterDelay() {
        guard !OnboardingState.shared.hasNudgedTour else { return }
        // `.onAppear` re-fires on return from the background; one scheduled
        // attempt per launch is enough.
        guard !tourNudgeScheduled else { return }
        tourNudgeScheduled = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.tourNudgeDelay))
            let deadline = Date().addingTimeInterval(Self.tourNudgeWindow)
            while Date() < deadline {
                if OnboardingState.shared.hasNudgedTour { return }
                if section == .detector, !tourActive, !menuIsOpen, !showTourOffer,
                   OnboardingState.shared.shouldOfferTour(simplified: simplifiedMode) {
                    OnboardingState.shared.hasNudgedTour = true
                    showTourOffer = true
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// The standing offer of a guided tour, left of the gear.
    ///
    /// A popover rather than a button that launches the tour outright: the tour
    /// takes over the whole screen, and something that does that should say so
    /// before it happens. It also gives the offer somewhere to explain itself —
    /// "tour" alone doesn't tell a first-time user whether this is a video, a
    /// help page, or the thing it actually is.
    ///
    /// It disappears once the tour has been finished (see
    /// `OnboardingState.shouldOfferTour`), so it is a first-run affordance that
    /// removes itself rather than permanent chrome. Info & Tour keeps the tour
    /// reachable forever afterwards.
    private var tourButton: some View {
        Button { showTourOffer = true } label: {
            Image(systemName: "sparkles")
        }
        .popover(isPresented: $showTourOffer) {
            TourOfferPopover(simplified: simplifiedMode) {
                showTourOffer = false
                // Deferred, for the reason CLAUDE.md gives: a presentation
                // started from inside a dismissing one is dropped silently. The
                // tour isn't a sheet, but it does re-lay-out the screen the
                // popover is anchored into, and starting it in the same frame as
                // the dismissal left the spotlight measuring a screen that was
                // still moving.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    tourIndex = 0
                    withAnimation(.easeInOut(duration: 0.3)) { tourActive = true }
                }
            }
            .presentationCompactAdaptation(.popover)
        }
        // Same reasoning as `optionsMenu` below — no animated state of its own,
        // so it must never ride along with an ambient `withAnimation`.
        .transaction { $0.animation = nil }
        .accessibilityLabel("Take the guided tour")
    }

    /// Which bats are plausible near the user right now — same presence data
    /// the field guide's "Nearby" view uses, just a button away from the
    /// detector instead of a tab switch.
    private var nearbySpeciesButton: some View {
        Button { showNearbySpecies = true } label: {
            Image("batIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
        }
        // Same reasoning as `tourButton`/`optionsMenu` — no animated state of
        // its own, so it must never ride along with an ambient withAnimation.
        .transaction { $0.animation = nil }
        .accessibilityLabel("Bats near you")
    }

    /// Settings / diagnostics menu — shown in the nav-bar trailing slot on the
    /// Detector section.
    ///
    /// Same iOS 26 FixedMenu workaround as `paletteButton`: without the
    /// `GlassEffectContainer` + `.glassEffect(.identity)` wrapping, Liquid
    /// Glass hides this Menu's label for the whole time it's open and then
    /// visibly fades/pulses it back in seconds after dismissal.
    private var optionsMenu: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer {
                    optionsMenuContent {
                        Image(systemName: "gearshape").glassEffect(.identity)
                    }
                    .clipped()
                }
            } else {
                optionsMenuContent { Image(systemName: "gearshape") }
            }
        }
        // Belt-and-braces against the inherited-animation bug documented on
        // `RecordPulse`: this button has no animated state of its own,
        // so clearing the transaction's animation here means it can never ride
        // along with an ambient animation set by an unrelated `withAnimation`
        // elsewhere in the same update — which is what left it slowly throbbing
        // during detection.
        .transaction { $0.animation = nil }
        .accessibilityLabel("Menu")
    }

    private func optionsMenuContent(@ViewBuilder label: () -> some View) -> some View {
        Menu {
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
            // Moved here from the leading section menu, which the tab bar
            // replaced. It was the only thing in that menu that wasn't
            // navigation, so there was nothing left to keep it company.
            Button { showInfo = true } label: {
                Label("Info & Tour", systemImage: "info.circle")
            }
            Button { showHelp = true } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            // Hidden until debug mode is unlocked by tapping the footer version
            // number 10x — see `registerVersionTap`.
            if debugModeEnabled {
                Divider()
                Button { showDiagnostics = true } label: {
                    Label("Debug", systemImage: "gauge.medium")
                }
            }
        } label: {
            label()
        }
    }

    /// Portrait: stacked panels with a fixed stats slot.
    ///
    /// The transport controls that used to sit in a row below the panes are now
    /// the session button in the tab bar and the menu it opens — which is close
    /// to a wash on vertical space, since the bar costs about what the control
    /// bar gave back.
    private var portraitLayout: some View {
        VStack(spacing: 10) {
            // The stats card takes whatever height it needs (see `statsStrip`),
            // and the two panes split what's left 42/58. The split has to be
            // measured against the space that actually remains, which is why
            // the GeometryReader is nested *below* the card rather than wrapped
            // around all three — wrapping it meant subtracting a guess at the
            // card's height, and that guess is exactly what used to crop it.
            statsBlock
            GeometryReader { geo in
                let spacing: CGFloat = 10
                let flex = max(120, geo.size.height - spacing)
                VStack(spacing: spacing) {
                    pulseBlock.frame(height: flex * 0.42)
                    spectrogramBlock.frame(height: flex * 0.58)
                }
            }
            appFooter
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }

    // The iPhone-landscape layout stood here: a three-column arrangement with a
    // narrow stats sidebar, a vertical amplitude meter, its own status-pill row
    // and a floating transport panel, plus a full-screen mode that moved the
    // transport controls into the spectrogram's header. All of it is gone with
    // the decision to make iPhone portrait-only — see `detectorLayoutBody`.

    // MARK: Reusable panel blocks

    private var statsBlock: some View {
        statsStrip
            .tourTarget(.stats)
    }


    /// Shared card scaffold for the pulse/spectrogram panel blocks: header row
    /// inside the card, then the panel body, wrapped in the hairline `panelCard`
    /// and tagged for the tour — the four blocks below only differ in title,
    /// trailing header buttons, body, and tour stop.
    private func panel(_ title: String,
                       tour: TourID,
                       @ViewBuilder trailing: () -> some View,
                       @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            panelHeader(title, trailing: trailing)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)
            content()
        }
        .panelCard()
        .tourTarget(tour)
    }

    private var pulseBlock: some View {
        pulseCard(showsSpeciesID: effectivePulseShowsSpeciesID)
    }

    /// Parameterised so the iPad-landscape layout can hand it a different answer
    /// from `effectivePulseShowsSpeciesID` — see `padLandscapePulseShowsSpeciesID`.
    private func pulseCard(showsSpeciesID: Bool) -> some View {
        panel(showsSpeciesID ? "Species ID" : "Pulse View", tour: .pulseView) {
            pulseHeaderTrailing
        } content: {
            pulsePanelContent(showsSpeciesID: showsSpeciesID)
        }
    }

    private var spectrogramBlock: some View {
        panel(effectiveSpectrogramShowsSpeciesID ? "Species ID" : "Spectrogram", tour: .spectrogram) {
            spectrogramHeaderTrailing
        } content: {
            spectrogramPanelContent
        }
    }

    /// Spectrogram panel body — the live Metal view, with the species feed overlaid
    /// on top (not branched in/out) when toggled from the frequency-range popover
    /// (bandButton). Keeping the SpectrogramView permanently mounted means its
    /// MTKView/Metal state is never torn down and rebuilt by the toggle — previously
    /// an if/else branch here would remove SpectrogramView from the tree entirely,
    /// which froze it (and the Metal draw loop) whenever the sibling panel's toggle
    /// forced this ViewBuilder to re-evaluate.
    ///
    /// `isPaused` now also covers being on another tab. With a tab bar the
    /// detector stays mounted when you leave it (which is what keeps the Metal
    /// view alive), so without this the render loop would keep drawing a screen
    /// nobody is looking at. `updateColumnDrainOwner` hands the column draining
    /// to the background pump at the same moment, so detection carries on.
    private var spectrogramPanelContent: some View {
        ZStack {
            SpectrogramView(processor: processor,
                            maxFrequency: nyquist,
                            bandLow: bandLow,
                            bandHigh: bandHigh,
                            timeWindowSeconds: timeWindowSeconds,
                            pulseDetector: pulseDetector,
                            isPaused: menuIsOpen || section != .detector,
                            isIdle: !audio.isActive,
                            logFrequency: spectrogramLogFrequency,
                            scrollEnabled: !simplifiedMode)
                .overlay(alignment: .topTrailing) { tunedPillOverlay }
                .overlay(alignment: .bottomTrailing) {
                    // Recording state only. `SnippetStatusPill` used to sit here
                    // beside it and now lives with the other status indicators in
                    // the STATS card header (`statsStrip`) — it reports which
                    // listening mode is doing what, which is a status, not a
                    // recording fact, and next to "Not recording" its idle ear
                    // read as a claim about the recorder.
                    RecordingStatusBadge(recorder: recorder, tourDemo: tourActive)
                        .padding(8)
                }
                .opacity(effectiveSpectrogramShowsSpeciesID ? 0 : 1)
                .allowsHitTesting(!effectiveSpectrogramShowsSpeciesID)

            if effectiveSpectrogramShowsSpeciesID {
                SpeciesFeedView(store: classStore, guide: speciesGuide, presenceStore: speciesPresence, activeSessionID: classStore.activeSessionID, sessionStart: feedSessionStart, autoIDActive: autoIDSettings.activeModelID != nil)
            }
        }
    }

    /// Pulse-zoom panel body — same always-mounted-plus-overlay pattern as
    /// `spectrogramPanelContent`, for the pulse-view popover (pulseViewButton).
    private func pulsePanelContent(showsSpeciesID: Bool) -> some View {
        ZStack {
            PulseZoomView(pulseDetector: pulseDetector)
                .opacity(showsSpeciesID ? 0 : 1)
                .allowsHitTesting(!showsSpeciesID)

            if showsSpeciesID {
                // Mirrors the spectrogram panel's species ID list, thumbnail
                // included — see `spectrogramPanelContent`.
                SpeciesFeedView(store: classStore, guide: speciesGuide, presenceStore: speciesPresence, activeSessionID: classStore.activeSessionID, sessionStart: feedSessionStart, autoIDActive: autoIDSettings.activeModelID != nil)
            }
        }
    }

    // MARK: Panels

    /// The horizontal row of stat readouts. A standalone View
    /// struct (not a computed property) — `pulseDetector.pulseCount`/`pulseRateHz`
    /// update on essentially every detected pulse, sometimes many times a second
    /// during an active pass, so reading them inline in ContentView.body invalidated
    /// (and froze the hit-testing of) the whole screen exactly like the amplitude
    /// meter's 15 Hz churn did before that was fixed. Scoping it here keeps updates
    /// confined to this small view.
    private var statCellsRow: some View {
        PulseStatsRow(pulseDetector: pulseDetector)
    }

    /// The card sizes to its own content — deliberately, and this is not a
    /// detail to undo.
    ///
    /// It used to be a `RoundedRectangle` with the readouts in an `.overlay`,
    /// poured into a hard-coded 126 pt frame. An overlay takes its host's size,
    /// so the moment the content needed more than 126 pt it overflowed and the
    /// `.clipShape` cut it off — and because an overlay is centred, it cut off
    /// the top and the bottom at once, which reads as the card being cropped
    /// rather than as content not fitting. Advanced view had quietly crossed
    /// that line when the species readout was given its own full-width row.
    ///
    /// Content-sized, there is no number left to be wrong: the pills, stat
    /// cells, species row and meter all have natural heights, so the card is as
    /// tall as whatever it is actually showing. That is also what makes
    /// simplified view work without a second magic number, and what stops
    /// Dynamic Type clipping the card the same way.
    private var statsStrip: some View {
        VStack(spacing: 4) {
            HStack {
                Text("STATS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 8) {
                    snippetStatusPill
                    speakerFeedbackWarning
                    sessionStatusPill
                    micStatusPill
                    resetButton
                }
            }
            if !simplifiedMode { statCellsRow }
            amplitudeMeter
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    /// Mic-connection pill, in the stats header. A standalone View struct because
    /// it reads `audio.diagnostics`, which mutates at the 15 Hz stats flush — same
    /// scoping rationale as the amplitude meters.
    private var micStatusPill: some View {
        MicStatusPill(audio: audio)
            .tourTarget(.micStatus)
    }

    /// Session-status pill (Off / Listening / Session) for the portrait stats
    /// header, next to the mic pill. Same scoping rationale — see
    /// `SessionStatusPillView`. Forced to read "Listening" during the guided
    /// tour for the same reason as `speakerFeedbackWarning` below — the tour is
    /// normally taken with detection off.
    private var sessionStatusPill: some View {
        SessionStatusPillView(audio: audio, classStore: classStore, tourDemo: tourActive)
            .tourTarget(.sessionStatus)
    }

    /// Slow-replay activity pill (listening / capturing / replaying), shown only
    /// while that listen mode is running — it renders nothing otherwise, so it
    /// simply isn't there in heterodyne or with listening off. Lives with the
    /// other status pills rather than in the spectrogram's corner, where sitting
    /// beside the "Not recording" badge made its idle ear look like a statement
    /// about the recorder.
    ///
    /// It drives a 0.25 s `TimelineView`, so it is the one pill in these rows
    /// that re-evaluates on a clock. That is only safe because its frame is fixed
    /// (`StatusPillMetrics.height` square, in every activity state) and so the row
    /// never reflows around it — and because `MicStatusPillContent`'s animated
    /// rate label is now contained with `.geometryGroup()`. Before that fix, this
    /// pill's ticking was exactly what sent "48 kHz" sliding across the row, which
    /// is why it was banished to the spectrogram corner in the first place. Keep
    /// both of those properties if this pill grows a text label.
    private var snippetStatusPill: some View {
        SnippetStatusPill(audio: audio, tourDemo: tourActive)
            .tourTarget(.slowReplayStatus)
    }

    /// Feedback-risk warning for listening audio on the speaker. See
    /// `SpeakerFeedbackWarningPill` — same scoping rationale as `sessionStatusPill`.
    /// Forced visible during the guided tour (it's normally conditional, and the
    /// tour is usually taken with nothing playing) so its step has a target.
    private var speakerFeedbackWarning: some View {
        SpeakerFeedbackWarningPill(audio: audio, tourDemo: tourActive)
            .tourTarget(.feedbackWarning)
    }

    private var resetButton: some View {
        Button {
            pulseDetector.resetStats()
            peakHold.reset()
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: StatusPillMetrics.height, height: StatusPillMetrics.height)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reset stats")
        .tourTarget(.resetStats)
    }

    /// Retro segmented level meter with a falling peak-hold dot, driven by the
    /// input RMS level. Segments run green → yellow → red across the scale. A
    /// standalone View struct for the same reason as `verticalAmplitudeMeter`.
    private var amplitudeMeter: some View {
        AmplitudeMeterView(audio: audio, peakHold: peakHold, detector: pulseDetector)
    }

    // MARK: Helpers

    private var nyquist: Double {
        // activeSampleRate, not diagnostics.actualSampleRate — see the comment
        // on the onChange block in body.
        let rate = audio.activeSampleRate
        // isActive, not isRunning: otherwise the axis falls back to the 192 kHz
        // default for the length of a listen-mode restart and then snaps back.
        return audio.isActive && rate > 0 ? rate / 2 : 192_000
    }

    /// True while a full-screen sheet covers the live view — none of them need
    /// the spectrogram's 60 Hz Metal render loop (which drains FFT columns and
    /// feeds the pulse detector inline on the main thread), and stopping it
    /// frees the main thread up for the sheet's own gesture handling instead of
    /// competing with it. Audio capture/recording itself is untouched — only
    /// live display + pulse detection pause. Deliberately excludes the pulse
    /// zoom (showPulseView) and frequency-band (showBand) popovers: those are
    /// meant to be used while watching the live feed.
    /// Whether the location-change summary is actually on screen.
    ///
    /// **The single source of truth for that question** — the sheet's own
    /// `isPresented` binding reads this, and so does `menuIsOpen`. They were two
    /// separate expressions and they drifted: the sheet grew `!tourActive` and
    /// then `!showWhatsNew` to stop it stealing a presentation it would have
    /// dropped, and `menuIsOpen` kept testing the bare `pendingChangeSummary`.
    /// So a location fix arriving during the tour paused the detector — render
    /// loop and processor both — with no sheet on screen and nothing to say why,
    /// for the whole length of the tour (found 2026-08-17).
    private var showingChangeSummary: Bool {
        autoIDSettings.pendingChangeSummary != nil && !tourActive && !showWhatsNew
    }

    /// Something full-screen is covering the detector. Pauses the render loop,
    /// and the processor too when no session is running — see the `onChange`
    /// above, and `updateColumnDrainOwner` for who drains columns meanwhile.
    ///
    /// Every entry must be a presentation that is *up*, never one that is merely
    /// wanted; see `showingChangeSummary`.
    private var menuIsOpen: Bool {
        showDiagnostics || showSettings || showHelp || showInfo || showWhatsNew || showingChangeSummary
    }

    private func applyBand() {
        processor.peakMinFraction = max(bandLow, 0.01)
        processor.peakMaxFraction = bandHigh
        audio.heterodyne.setBand(low: bandLow, high: bandHigh)
    }

    /// The one-time half of simplified view — see `SimplifiedView`'s header for
    /// why the frequency band is written once here rather than overridden on
    /// every read like the species-ID toggles are.
    ///
    /// Called from `onAppear` as well as on the toggle changing, because a fresh
    /// install that simply leaves onboarding's switch alone never fires an
    /// `onChange` at all. `simplifiedDefaultsApplied` is what stops it running
    /// twice, and clearing it on the way out is what lets a later return to
    /// simplified view set the band up again.
    private func applySimplifiedDefaultsIfNeeded() {
        guard simplifiedMode else {
            simplifiedDefaultsApplied = false
            return
        }
        guard !simplifiedDefaultsApplied else { return }
        simplifiedDefaultsApplied = true
        // Fractions of Nyquist, which is what bandLow/bandHigh store. `nyquist`
        // falls back to 192 kHz before the engine has reported a rate, which is
        // the Griff's own — and applyBand runs again on every rate change
        // regardless, so a different mic corrects itself.
        if nyquist > 0 {
            bandLow  = min(1, SimplifiedView.bandLowHz / nyquist)
            bandHigh = min(1, SimplifiedView.bandHighHz / nyquist)
        }
        // The compress-timeline button is hidden in simplified view, so the
        // mode has to start off — otherwise a user who left it on in advanced
        // view is stuck with a gap-dropped timeline and nothing to turn it off.
        pulseDetector.triggeredDisplayMode = false
    }

    // MARK: Panel headers + per-panel setting buttons

    private func panelHeader(_ title: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 4)
    }

    /// Groups panel-header icons into a rounded pill — used to visually separate
    /// the toggle-style icons (grey/orange, a mode you're IN) from the menu-style
    /// icons (white, opens something) instead of them all running together in one
    /// row. Keeps every control as a single tappable icon (no icon-count increase
    /// over what's already there), so it can't overflow on narrow iPhone widths.
    private func iconPill(spacing: CGFloat = 14, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: spacing) { content() }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }

    /// Pulse-view header trailing content: one toggle (species ID) pill, one menu
    /// (settings popover) pill. Both are advanced-only — in simplified view this
    /// panel is the species feed and nothing else, so there is no view to toggle
    /// between and no pulse-render settings to reach.
    private var pulseHeaderTrailing: some View {
        HStack(spacing: 8) {
            iconPill { pulseSpeciesIDButton }
                .advancedOnly(simplifiedMode)
            iconPill { pulseViewButton }
                .advancedOnly(simplifiedMode)
        }
    }

    /// Spectrogram header trailing content: toggles pill (species ID, compress
    /// timeline, bat range) + menu pill (palette, frequency-range settings).
    private var spectrogramHeaderTrailing: some View {
        HStack(spacing: 8) {
            // Elapsed-time pill for the active listening/session, sitting to the
            // left of the control pills. Renders nothing when not detecting.
            // tourDemo forces it on with a stand-in clock during the guided tour,
            // which is normally taken before detection has ever been started.
            SessionTimerPill(start: feedSessionStart, tourDemo: tourActive)
                .tourTarget(.sessionTimer)
            // Every toggle in this pill is advanced-only, so the pill itself
            // goes with them rather than sitting there empty.
            iconPill {
                spectrogramSpeciesIDButton
                compressTimelineButton
                batRangeButton
            }
            .advancedOnly(simplifiedMode)
            // The band settings survive into simplified view on their own —
            // which frequencies are shown is the one thing on this screen a
            // beginner may genuinely need to change, and with the bat-range
            // preset button hidden this is the only way left to do it.
            iconPill {
                paletteButton
                    .advancedOnly(simplifiedMode)
                bandButton
            }
        }
    }

    private var pulseViewButton: some View {
        Button { showPulseView.toggle() } label: {
            Image(systemName: "slider.horizontal.3").font(.callout)
                .frame(width: 18, height: 18)
        }
        .tint(.secondary)
        .accessibilityLabel("Pulse view settings")
        .popover(isPresented: $showPulseView) {
            PulseViewControls(detector: pulseDetector)
        }
        .tourTarget(.pulseSettings)
    }

    /// Species-ID view toggles, moved out of each panel's settings popover into
    /// its own toolbar button — icon swaps between the custom bat glyph (on) and
    /// a waveform (off) instead of just a tint change, so the mode reads at a
    /// glance. `batIcon` is a template-rendered vector asset (Assets.xcassets),
    /// so `.tint` recolors it exactly like an SF Symbol.
    private var spectrogramSpeciesIDButton: some View {
        Button { spectrogramShowsSpeciesID.toggle() } label: {
            Group {
                if spectrogramShowsSpeciesID {
                    // Outline-only (fill:none in the SVG) — template rendering then
                    // has a genuinely hollow interior, not a solid tinted blob.
                    Image("batIcon").resizable().scaledToFit()
                } else {
                    Image(systemName: "waveform.badge.magnifyingglass")
                }
            }
            .font(.callout)
            .frame(width: 18, height: 18)
        }
        .tint(spectrogramShowsSpeciesID ? .toggleOn : .toggleOff)
        .accessibilityLabel("Species ID view")
        .tourTarget(.spectrogramSpeciesToggle)
    }

    private var pulseSpeciesIDButton: some View {
        Button { pulseShowsSpeciesID.toggle() } label: {
            Group {
                if pulseShowsSpeciesID {
                    Image("batIcon").resizable().scaledToFit()
                } else {
                    Image(systemName: "waveform.badge.magnifyingglass")
                }
            }
            .font(.callout)
            .frame(width: 18, height: 18)
        }
        .tint(pulseShowsSpeciesID ? .toggleOn : .toggleOff)
        .accessibilityLabel("Species ID view")
        .tourTarget(.pulseSpeciesToggle)
    }

    /// Moved out of the hamburger menu into the spectrogram panel header, next to
    /// `bandButton` — a more discoverable spot for a toggle used mid-session.
    private var compressTimelineButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                pulseDetector.triggeredDisplayMode.toggle()
            }
        } label: {
            // Morphs with the state instead of just swapping tint: squashed 25%
            // narrower when compressed, stretched 25% wider when not — the icon
            // itself acts out what the toggle does to the timeline.
            Image(systemName: "lines.measurement.horizontal.aligned.bottom")
                .font(.callout)
                .scaleEffect(x: pulseDetector.triggeredDisplayMode ? 0.75 : 1.25, y: 1)
        }
        .tint(pulseDetector.triggeredDisplayMode ? .toggleOn : .toggleOff)
        .accessibilityLabel("Compress timeline")
        .tourTarget(.compressTimeline)
    }

    /// Most bat calls fall in this band — a one-tap preset instead of dragging the
    /// frequency-range popover's slider by hand. Moved out of that popover into
    /// the panel header, next to `compressTimelineButton`, for one-tap access.
    private let batLowHz: Double = 15_000
    private let batHighHz: Double = 90_000

    private var batLowFrac: Double { nyquist > 0 ? min(1, batLowHz / nyquist) : 0 }
    private var batHighFrac: Double { nyquist > 0 ? min(1, batHighHz / nyquist) : 1 }

    /// True when bandLow/bandHigh currently match the bat-range preset, so the
    /// button reflects itself as off if the user drags the range slider away
    /// from it manually.
    private var isBatRange: Bool {
        abs(bandLow - batLowFrac) < 0.01 && abs(bandHigh - batHighFrac) < 0.01
    }

    private var batRangeButton: some View {
        Button {
            if isBatRange {
                bandLow = 0
                bandHigh = 1
            } else {
                bandLow = batLowFrac
                bandHigh = batHighFrac
            }
        } label: {
            // Rotated -90° (mirrored from the first attempt so +/- land on the
            // left): a horizontal measurement bracket, turned sideways to read as
            // a frequency-band selection instead of a horizontal-axis one.
            Image(systemName: "minus.plus.lines.measurement.horizontal.aligned.bottom")
                .font(.callout)
                .rotationEffect(.degrees(-90))
        }
        .tint(isBatRange ? .toggleOn : .toggleOff)
        .accessibilityLabel("Bat range, 15 to 90 kilohertz")
        .tourTarget(.batRange)
    }

    /// Colour palette picker, moved out of the frequency-range popover into its
    /// own toolbar button — a Menu (not a cycle-on-tap button) since there are 7
    /// named options and jumping straight to one beats tapping through them.
    ///
    /// On iOS 26 the Liquid Glass menu morph hides a Menu's label the whole time
    /// the menu is open, then fades it back seconds after dismissal. Wrapping the
    /// menu in a `GlassEffectContainer` and giving the label `.glassEffect(.identity)`
    /// keeps the icon visible throughout (the FixedMenu workaround).
    private var paletteButton: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer {
                    paletteMenu {
                        paletteMenuLabel.glassEffect(.identity)
                    }
                    .clipped()
                }
            } else {
                paletteMenu { paletteMenuLabel }
            }
        }
        .tint(.secondary)
        .accessibilityLabel("Colour palette")
        .tourTarget(.palette)
    }

    private var paletteMenuLabel: some View {
        Image(systemName: "paintpalette").font(.callout)
            .frame(width: 18, height: 18)
    }

    private func paletteMenu(@ViewBuilder label: () -> some View) -> some View {
        Menu {
            Picker("Palette", selection: $pulseDetector.displayPalette) {
                ForEach(Palette.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
        } label: {
            label()
        }
    }

    private var bandButton: some View {
        Button { showBand.toggle() } label: {
            Image(systemName: "slider.horizontal.3").font(.callout)
                .frame(width: 18, height: 18)
        }
        .tint(.secondary)
        .accessibilityLabel("Frequency range")
        .popover(isPresented: $showBand) {
            FrequencyBandControl(low: $bandLow, high: $bandHigh,
                                 maxFrequency: nyquist,
                                 timeWindowSeconds: $timeWindowSeconds,
                                 noiseFloor: $pulseDetector.spectrogramNoiseFloor,
                                 logFrequency: $spectrogramLogFrequency)
        }
        .tourTarget(.bandSettings)
    }

    /// Heterodyne tuning pill, overlaid on the spectrogram only in that mode. A
    /// standalone View struct (see `TunedPillView`) — `audio.tunedFrequency`/
    /// `isAutoTune` update at 15 Hz (the same stats timer that drives the
    /// amplitude meter) while heterodyne listening is active, so reading them
    /// inline here would invalidate all of ContentView.body at that rate.
    ///
    /// Gated on `audio.isActive` as well as the mode: `listenMode` defaults to
    /// `.heterodyne` at rest (see its doc comment in AudioEngineController) so
    /// the app is ready to listen the instant it's told to, not so it can show
    /// live-tuning UI before anything has actually started capturing. Without
    /// this the pill showed on a cold launch, before the engine had run once.
    @ViewBuilder private var tunedPillOverlay: some View {
        if audio.listenMode == .heterodyne, audio.isActive {
            TunedPillView(audio: audio, nyquist: nyquist).padding(8)
        }
    }

    /// Credit + version/build line under the panels. Version/build come straight
    /// from the app's Info.plist (CFBundleShortVersionString / CFBundleVersion), which
    /// Xcode stamps from the target's Marketing Version / Current Project Version at
    /// build time — no manual syncing needed.
    private var appFooter: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return Text("Created by Niall Bell · v\(version) (\(build))")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture { registerVersionTap() }
            .versionFooterAnchor()
    }

    /// Counts taps on the version footer within a rolling window. Ten taps
    /// before the window lapses sends the bat swarm; keeping going to fifteen
    /// toggles debug mode (the Debug entry in the options menu). Each tap
    /// restarts the reset timer so a burst of slower-than-instant-but-still-
    /// rapid taps still counts, but a stray single tap days apart never does.
    private func registerVersionTap() {
        versionTapResetWork?.cancel()
        versionTapCount += 1
        switch versionTapCount {
        case 10:
            releaseBatSwarm()
        case 15:
            versionTapCount = 0
            debugModeEnabled.toggle()
            UINotificationFeedbackGenerator()
                .notificationOccurred(debugModeEnabled ? .success : .warning)
            return
        default:
            // A tick acknowledging the tap registered. Past the swarm the ticks
            // harden, so the five taps to the debug toggle feel like they're
            // building to something rather than trailing off after the payoff.
            let style: UIImpactFeedbackGenerator.FeedbackStyle =
                versionTapCount < 10 ? .light : (versionTapCount < 13 ? .medium : .heavy)
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        }
        let resetWork = DispatchWorkItem { versionTapCount = 0 }
        versionTapResetWork = resetWork
        // Wider window past the swarm: the flourish's own haptics run for ~1.1 s
        // and mask the tick, so the usual 1.2 s would ask the user to keep
        // tapping blind and on time.
        let window = versionTapCount < 10 ? 1.2 : 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + window, execute: resetWork)
    }

    /// The payoff for the tenth tap.
    private func releaseBatSwarm() {
        showBatSwarm = true
        flourishBatSwarmHaptics()
        DispatchQueue.main.asyncAfter(deadline: .now() + BatSwarmOverlay.totalDuration) {
            showBatSwarm = false
        }
    }

    /// A volley of impacts timed to the swarm's emergence trickle (bats leave
    /// the origin over roughly the first second — see `BatFlight.startDelay`),
    /// ramping light → heavy, capped off with a success notification once the
    /// last bat is airborne — so the haptic buildup rides the actual flight
    /// rather than the taps that triggered it.
    private func flourishBatSwarmHaptics() {
        let pulseCount = 10
        for i in 0..<pulseCount {
            let delay = Double(i) / Double(pulseCount - 1) * 1.0
            let style: UIImpactFeedbackGenerator.FeedbackStyle =
                i < 4 ? .light : (i < 8 ? .medium : .heavy)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                UIImpactFeedbackGenerator(style: style).impactOccurred()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    /// Captures every live tunable and persisted setting to a JSON file and
    /// returns its URL, for the Debug sheet's "Dump Settings to File". Lives here
    /// rather than in `DiagnosticsView` because this is the only place that holds
    /// every processor, the band/window bindings and `autoIDSettings` at once —
    /// and it reuses `LiveTuningSnapshot.capture` so the overlay's register of
    /// knobs stays the single list to keep up to date.
    private func dumpSettings() -> URL? {
        let snapshot = LiveTuningSnapshot.capture(
            audio: audio,
            pulse: pulseDetector,
            haptics: haptics,
            snippet: snippetSettings,
            bandLow: bandLow,
            bandHigh: bandHigh,
            timeWindowSeconds: timeWindowSeconds
        )
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let json = SettingsDump.makeJSON(tuning: snapshot,
                                         autoID: autoIDSettings,
                                         appVersion: "\(short) (\(build))")
        return SettingsDump.write(json)
    }

    /// Stop detection and tear down the active session. Called only on explicit user
    /// action so that transient audio interruptions and listen-mode restarts don't
    /// accidentally end the session.
    private func stopDetecting() {
        pulseDetector.finalizePass()  // save any in-progress pass before session ends
        // After finalizePass, so the pass that just closed isn't lost, but before
        // audio.stop() — ending the card is the user's explicit intent here and
        // shouldn't wait on teardown.
        liveActivity.end()
        audio.stop()
        // End any buzz immediately rather than letting the watchdog time it out
        // — the user just stopped detecting, so the phone should go still now.
        haptics.reset()
        recorder.setCoordinate(nil)
        feedSessionStart = nil
        if classStore.activeSessionID != nil {
            classStore.endSession()
            pulseDetector.activeSessionID = nil
            recorder.setActiveSession(id: nil, startDate: nil, label: "Not detecting")
        }
    }

    /// Switch the pipeline over to `url` and start feeding. Tears down whatever
    /// was running first — including any GPS session, since a demo is not a
    /// survey and shouldn't leave a location track behind. The demo itself runs
    /// in the Listening bucket, which combined with the recorder block (below)
    /// means it writes nothing to Sessions at all.
    private func startDemo(url: URL, name: String) {
        if audio.isRunning || classStore.activeSessionID != nil { stopDetecting() }
        recorder.setBlocked(true)
        pulseDetector.resetStats()
        recorder.setActiveSession(id: nil, startDate: nil, label: "Demo")
        feedSessionStart = Date()
        // Demo runs get a card too — flagged as DEMO so a synthetic ID is never mistaken
        // for field data, the same reasoning that blocks recording and session creation
        // here. It's also the only way to exercise this on the simulator, where there's
        // no mic (see Context.md §6).
        liveActivity.start(sessionTitle: "Demo", isDemo: true, startDate: feedSessionStart ?? Date())
        Task { await audio.startDemo(url: url, name: name) }
    }

    /// Leave demo mode and hand the pipeline back to the microphone. Detection
    /// is left stopped — see `AudioEngineController.endDemo`.
    private func endDemo() {
        pulseDetector.finalizePass()
        liveActivity.end()
        audio.endDemo()
        recorder.setBlocked(false)
        feedSessionStart = nil
    }

    /// Begin detection inside a new session (logged IDs + map pins). Also the
    /// session button's first-tap action — see `handleSessionButtonTap`.
    private func startDetecting() {
        // Before resetStats(), which discards the accumulator: a pass can still be
        // open here, because an unexpected audio stop (interruption, route error)
        // stops `feed()` being called and so the silence timeout that normally
        // closes a pass never runs — the same case the session cleanup below
        // exists for. Without this the evidence is dropped silently, against the
        // "NoID is recorded, not dropped" rule in Context.md §9. `stopDetecting`
        // and `endDemo` both already do this; this path was the odd one out.
        pulseDetector.finalizePass()
        pulseDetector.resetStats()
        recorder.setInputName(audio.diagnostics.inputName)
        feedSessionStart = Date()
        // Close any session that was left open by an unexpected audio stop (interruption,
        // route error) — the user is deliberately starting a new run.
        if classStore.activeSessionID != nil {
            classStore.endSession()
            pulseDetector.activeSessionID = nil
        }
        // Demo mode is the one run that never opens a session: no Session row,
        // nothing in Sessions afterwards. Combined with the recorder block set
        // in `startDemo`, a demo leaves no trace in the user's data.
        if !audio.isDemoMode {
            let id = classStore.startSession()
            // Stamp the classifier's weights onto the session the moment it
            // opens — see PriorSnapshot for why an export is unreadable without
            // them, and `refreshPriors` below for the mid-session case.
            recordPriorSnapshot(sessionID: id)
            let session = classStore.sessions.first(where: { $0.id == id })
            let label = session?.title ?? "Session"
            pulseDetector.activeSessionID = id
            recorder.setActiveSession(id: id, startDate: session?.startDate ?? Date(), label: label)
            // Names the session after where it happened, from the region fix
            // the app already takes. No continuous tracking is involved.
            location.geocodeNextFix(into: id)
            if autoRecordOnSessionStart {
                recorder.setArmed(true)
            }
        } else {
            recorder.setActiveSession(id: nil, startDate: nil, label: "Demo")
        }
        // Title matches what the recorder was just handed, so the lock screen names the
        // run the same way Sessions will.
        liveActivity.start(
            sessionTitle: audio.isDemoMode
                ? "Demo"
                : (classStore.sessions.first(where: { $0.id == classStore.activeSessionID })?.title
                   ?? "Session"),
            isDemo: audio.isDemoMode,
            startDate: feedSessionStart ?? Date()
        )
        // Seed the snippet processor before capture opens. `reset` clears DSP
        // state but not these, and the routing atomic is independent of the
        // settings object, so both have to be pushed here or a fresh launch
        // would run the defaults regardless of what was persisted.
        snippetSettings.apply(to: audio.snippetExpansion)
        audio.setSnippetRouting(snippetSettings.routing)
        Task { await audio.start() }
    }

    /// Fires once per run, 60 s into a listening session in which recording was
    /// never armed. Deliberately a one-shot: a repeating nag for a deliberate
    /// choice is worse than the mistake it prevents, and "Don't remind me"
    /// silences it for good.
    ///
    /// Armed (not writing) counts as recording for this purpose — the user has
    /// made the decision, and whether a call has arrived yet is not their doing.
    private func checkNotRecordingNudge() {
        guard !suppressNotRecordingNudge, !notRecordingNudgeShown,
              audio.isRunning, !recorder.isArmed, !recorder.isWriting,
              let started = feedSessionStart,
              Date().timeIntervalSince(started) >= 60
        else { return }
        notRecordingNudgeShown = true
        showNotRecordingNudge = true
    }

    /// Record button arms/disarms the triggered WAV recorder. No-op while demo
    /// mode blocks recording — the buttons are disabled too, this is the
    /// backstop for any other path that reaches here.
    private func toggleRecording() {
        guard !recorder.isBlocked else { return }
        recorder.setArmed(!recorder.isArmed)
    }

    /// One tap advances live listening through four states:
    ///
    ///     off → heterodyne → slow replay → slow replay + heterodyne → off
    ///
    /// The last two are the same `ListenMode` (`.snippetExpansion`) differing only
    /// in `SnippetOutputRouting`, which is why this is a method over two pieces of
    /// state rather than a `nextListenMode` computed property.
    ///
    /// It absorbed what used to be a separate antenna toggle beside this button.
    /// That button had no layout width — it was hung off this one's trailing edge
    /// as an overlay so the row wouldn't shift when slow replay was selected — and
    /// so in landscape it simply ran past the edge of the 26 %-wide controls panel
    /// and was clipped away. Folding it into the cycle makes the control a fixed
    /// width in every state, which is what actually removes that failure rather
    /// than deferring it to the next device or the next button.
    ///
    /// **The cycle now owns `routing`.** Entering slow replay forces
    /// `.expansionOnly`, overwriting whatever the live tuning overlay's Output
    /// control last persisted. That is the price of putting routing in the cycle:
    /// there can only be one authority for it, and this is the one the user
    /// reaches in the field. `.heterodyneOnly` stays unreachable from here — it is
    /// what `.heterodyne` already is — so a tap from that state (only settable in
    /// the overlay) exits to off.
    private func advanceListenMode() {
        switch (audio.listenMode, snippetSettings.routing) {
        case (.off, _):
            audio.setListenMode(.heterodyne)
        case (.heterodyne, _):
            applySnippetRouting(.expansionOnly)
            audio.setListenMode(.snippetExpansion)
        case (.snippetExpansion, .expansionOnly):
            // Routing only — deliberately NOT a mode change, so this step alone
            // skips `setListenMode`'s stop-and-restart and the audio keeps running
            // through it. Turning the heterodyne bed on mid-pass is the one
            // transition most likely to be made with a bat overhead.
            applySnippetRouting(.both)
        case (.snippetExpansion, _):
            audio.setListenMode(.off)
        // Playback-only (see ListenMode's doc comment); handled explicitly rather
        // than via `default:` so `ListenMode` stays exhaustively checked.
        case (.timeExpansion, _):
            audio.setListenMode(.off)
        }
    }

    /// Writes routing to both the persisted settings and the running engine — the
    /// two the old antenna button always set together.
    private func applySnippetRouting(_ routing: SnippetOutputRouting) {
        snippetSettings.routing = routing
        audio.setSnippetRouting(routing)
    }

    // Spelled out because this string is the VoiceOver label on the listen-mode
    // button, whose only visible cue is an icon — and with four states behind one
    // glyph, that label is now the only unambiguous statement of which one is on.
    private var listenModeName: String {
        switch audio.listenMode {
        case .off:              "Off"
        case .heterodyne:       "Heterodyne"
        case .snippetExpansion: snippetSettings.routing == .expansionOnly
                                    ? "Slow replay"
                                    : "Slow replay with heterodyne"
        case .timeExpansion:    "Time expansion (file)"
        }
    }

    /// Outline vs filled tortoise is the whole visual difference between the two
    /// slow-replay states. It is a fine distinction, and it is deliberate: a badged
    /// or composed glyph reads better in daylight but adds a second element inside
    /// a 24×22 icon frame, and this row is used one-handed in the dark where the
    /// tint (grey off / orange on) and the VoiceOver label carry more than the
    /// glyph does. `listenModeName` is the authority for anyone who needs certainty.
    private var listenIcon: String {
        switch audio.listenMode {
        case .off:              "headphones"
        case .heterodyne:       "antenna.radiowaves.left.and.right"
        case .snippetExpansion: snippetSettings.routing == .expansionOnly
                                    ? "tortoise"
                                    : "tortoise.fill"
        case .timeExpansion:    "tortoise"
        }
    }

}

/// The app's one "a model suits where you are" card. Two things present it:
/// the first arrival at the detector after onboarding (the
/// `justFinishedOnboarding` handoff in ContentView), and a location move far
/// enough to re-derive priors (`AutoIDSettings.pendingChangeSummary`).
///
/// **It used to be two unrelated screens** — this card, and a full `Form` sheet
/// with a navigation bar and per-species sections
/// (`LocationChangeSummaryView`), deleted 2026-08-17 on Niall's call. They were
/// the same offer in two visual languages, and the `Form` one was the one that
/// turned up on a clean install.
///
/// `model` is optional because a move can change the species list without
/// changing which model covers the area. With no model there is nothing to
/// activate, so the card becomes a notice with one button.
private struct SuggestedModelSheet: View {
    let model: ModelDescriptor?
    /// How many species the refresh switched on or off, 0 when this is the
    /// post-onboarding offer (nothing has changed yet — it is the first
    /// derivation). Only ever shown as a count: the list itself is AutoID
    /// settings, and a card is the wrong place to reproduce it.
    let speciesChanged: Int
    let onUse: (ModelDescriptor) -> Void
    @Environment(\.dismiss) private var dismiss

    private var message: String {
        var lines: [String] = []
        if let model {
            lines.append("\(model.displayName) covers your area (\(model.region)). "
                       + "Activate it to start identifying species here.")
        }
        if speciesChanged > 0 {
            lines.append(speciesChanged == 1
                ? "One species has been switched on or off for your new area."
                : "\(speciesChanged) species have been switched on or off for your new area.")
        }
        return lines.joined(separator: "\n\n")
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 72, height: 72)
                    .background(Color.accentColor.opacity(0.15), in: Circle())
                Text(model == nil ? "New Area" : "Suggested Model")
                    .font(.title2.weight(.semibold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .wrapsFully()
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            if let model {
                Button {
                    onUse(model)
                    dismiss()
                } label: {
                    Text("Use \(model.displayName)")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.batAccent)

                Button("Not Now", role: .cancel) { dismiss() }
                    .padding(.top, 4)
            } else {
                Button {
                    dismiss()
                } label: {
                    Text("OK")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.batAccent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .contentSizedDetent()
        .presentationDragIndicator(.visible)
    }
}

/// Shown the first time a given ultrasonic microphone is attached, offering to
/// calibrate it — see `ContentView.offerCalibrationIfAppropriate`.
///
/// Same compact-sheet visual language as `SuggestedModelSheet`, deliberately:
/// the two are the same kind of thing, a one-off contextual offer that arrives
/// because the app noticed something, and they should be recognisable as such.
///
/// A sheet rather than an alert because the *why* takes a sentence and an alert
/// has no room for one. "Calibrate your microphone?" with two buttons tells
/// someone who has never heard of calibration nothing about whether they want
/// it, and the honest answer to "can I skip this" is yes — which is why the
/// dismiss is a plain "Not Now" rather than anything discouraging.
private struct CalibrationOfferSheet: View {
    let micName: String
    let onCalibrate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Image(systemName: "tuningfork")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 72, height: 72)
                    .background(Color.accentColor.opacity(0.15), in: Circle())
                Text("Calibrate \(micName)?")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Affordable ultrasonic mics hear some frequencies louder than others, which shows up as fixed bands across the spectrogram and skews the measurements. OpenBat can listen to this one's noise floor for 15 seconds and correct for it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .wrapsFully()
                    .multilineTextAlignment(.center)
                // Both of the things someone hesitating wants to know, and the
                // second is the one that makes "Not Now" a real answer rather
                // than a decision they might regret.
                Text("Find somewhere quiet first. You can do this any time from Settings instead.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .wrapsFully()
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            Button {
                // Only flags intent; the host opens the capture from this
                // sheet's onDismiss. See `ContentView.calibrationAccepted`.
                onCalibrate()
                dismiss()
            } label: {
                Text("Calibrate")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.batAccent)

            Button("Not Now", role: .cancel) { dismiss() }
                .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .contentSizedDetent()
        .presentationDragIndicator(.visible)
    }
}

private extension View {
    /// See the call site in `ContentView.body` for why this is a single extension
    /// call rather than inline `.onChange`/`.alert` modifiers.
    func micPermissionAlert(status: String, isPresented: Binding<Bool>) -> some View {
        onChange(of: status) { _, newValue in
            if newValue.contains("permission denied") { isPresented.wrappedValue = true }
        }
        .alert("Microphone Access Needed", isPresented: isPresented) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("OpenBat can't detect or record without microphone access. Enable it for OpenBat in the Settings app.")
        }
    }

}

#Preview { ContentView() }
