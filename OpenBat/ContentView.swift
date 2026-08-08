//
//  ContentView.swift
//  OpenBat
//
//  Main screen. From bottom to top:
//    • Control bar   — play/stop, listen mode (fixed height)
//    • Live spectrogram — 50 % of the flexible area
//    • Pulse zoom    — 30 % — last detected pulse at 15 ms x-axis
//    • Stats strip   — 20 % — placeholder for future species / count data
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
    @State private var micCalSettings = MicCalibrationSettings()
    @State private var adaptiveTESettings = AdaptiveTimeExpansionSettings()
    @State private var classStore = ClassificationStore()
    @State private var liveActivity = LiveActivityController()
    @State private var detectionPump = BackgroundDetectionPump()
    @State private var location = LocationProvider()
    // Not `@State`: the store outlives any one screen and is shared with
    // onboarding. `@Observable` tracks property reads in `body` regardless of
    // how the reference is held, so this still updates the view.
    private let consent = ConsentStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showStartPrompt = false
    @State private var showMicDeniedAlert = false
    // Easter egg: tap the footer version number 10x within the reset window
    // below to send a swarm of bats across the screen — see BatSwarmOverlay.
    @State private var versionTapCount = 0
    @State private var versionTapResetWork: DispatchWorkItem?
    @State private var showBatSwarm = false
    @State private var showDiagnostics = false
    @State private var showSettings = false
    /// Set once per launch when a previously-granted consent predates the
    /// current wording — see `ConsentStore.needsReconsent`.
    @State private var showReconsentPrompt = false
    @State private var hasCheckedReconsent = false
    @State private var showHelp = false
    @State private var showInfo = false
    // Guided spotlight tour (launched from Info). tourActive gates the overlay;
    // tourIndex is the current step. tourPending is set by the Info sheet's tour
    // button and consumed by its onDismiss, so the tour only starts once the
    // sheet is fully gone (no fixed-delay race with the dismiss animation).
    @State private var tourActive = false
    @State private var tourPending = false
    @State private var tourIndex = 0
    /// Set when the CURRENT tour run was auto-launched from onboarding's "Take
    /// the Tour" step (see OnboardingState.shouldAutoStartTour) — on that path
    /// only, finishing the tour opens ONE follow-up sheet: `SuggestedModelSheet`
    /// if the user's location suggests a model, otherwise Start Detecting
    /// directly — so the tour leads straight into something actionable instead
    /// of dropping the user back on an idle screen. Not set for a tour launched
    /// from the Info sheet mid-use, where popping either sheet up unsolicited
    /// would be unwelcome.
    @State private var tourWillPromptStart = false
    /// Set from `finish` (below) when the onboarding tour just ended and the
    /// user's location suggests a model — drives `SuggestedModelSheet`. Standalone:
    /// dismissing it does NOT also open Start Detecting (see that sheet's own
    /// modifier below) — the two are deliberately independent.
    @State private var suggestedModelToOffer: ModelDescriptor?
    @State private var showPulseView = false
    @State private var showBand = false
    /// Live tuning overlay. Deliberately absent from `menuIsOpen` — see that
    /// property and `LiveTuningOverlay`'s header comment: adding it there would
    /// pause the render loop and the processor, which is the one thing the
    /// overlay exists to avoid.
    @State private var showTuningOverlay = false
    @State private var landscapePulseVisible = true
    @State private var timeWindowSeconds: Double = 0.5
    @AppStorage("display.bandLow") private var bandLow = 0.0
    @AppStorage("display.bandHigh") private var bandHigh = 1.0
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
    // .compact vertical size class == iPhone landscape → use the wide layout.
    @Environment(\.verticalSizeClass) private var vSizeClass
    @AppStorage("recording.autoRecordOnSessionStart") private var autoRecordOnSessionStart = true
    // Toggled from each panel's own config popover (bandButton / pulseViewButton).
    @AppStorage("display.spectrogramShowsSpeciesID") private var spectrogramShowsSpeciesID = false
    @AppStorage("display.pulseShowsSpeciesID") private var pulseShowsSpeciesID = false
    /// Independent of the pulse view's own toggle (`display.pulseLogFrequency`,
    /// declared in PulseSettingsView) — set from the spectrogram's frequency-band popover.
    @AppStorage("display.spectrogramLogFrequency") private var spectrogramLogFrequency = false

    /// Top-level sections, switched from the leading toolbar menu (replaces the old
    /// bottom tab bar). The audio pipeline keeps running across switches.
    private enum AppSection: String, CaseIterable {
        case detector  = "Detector"
        case sessions  = "Sessions"
        case playback  = "Playback"
        case species   = "Species"
        var icon: String {
            switch self {
            case .detector:  "waveform"
            case .sessions:  "square.stack.3d.up"
            case .playback:  "play.circle"
            case .species:   "book.closed"
            }
        }
    }
    // "-startSection Species" launch argument jumps straight to a section —
    // lets automated runs exercise non-default sections without UI scripting.
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
    @State private var speciesRange = SpeciesRangeStore()

    var body: some View {
        NavigationStack {
            sectionContent
                .navigationTitle(section.rawValue)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { sectionMenu }
                    if section == .detector {
                        ToolbarItem(placement: .topBarTrailing) { optionsMenu }
                    }
                }
                // Pin the nav bar to a fully OPAQUE background instead of Liquid
                // Glass's default adaptive-on-scroll material. `.toolbarBackground(
                // .visible, for:)` alone (the boolean visibility API) only forces the
                // system's glass material to always render — that material is still
                // translucent, so the leading/trailing toolbar buttons kept sampling
                // through it, and any perpetually-animating content sitting near the
                // bar (e.g. MicStatusPill's repeatForever breathe/flash in statsStrip,
                // which sits right under the bar in portraitLayout) still shimmered
                // through the glass. An explicit solid Color background (the
                // ShapeStyle overload) blocks that sampling outright. Same root cause
                // the tour dim overlay hit below.
                .toolbarBackground(Color.black, for: .navigationBar)
                // Hidden during the tour: even with a fixed toolbar background, the
                // dim overlay's cutout ring sits directly under the bar and its own
                // animation still reads as motion to the buttons. They're not usable
                // mid-tour anyway; the bar returns when the tour ends.
                //
                // The reveal must NOT be animated: finish() flips tourActive
                // inside a 0.25 s withAnimation so the dim overlay can fade out,
                // and if the toolbar's .hidden→.visible rode along in that same
                // transaction, the buttons would fade back in while the busy dim
                // backdrop was still animating underneath them — re-triggering the
                // same pulsing, except this time it got stuck oscillating instead of
                // settling. Snapping the toolbar in instantly (no shared animation
                // with the dim fade) keeps the buttons still while any backdrop
                // motion is happening.
                .toolbar(tourActive ? .hidden : .visible, for: .navigationBar)
                .animation(nil, value: tourActive)
                .sheet(isPresented: $showDiagnostics) {
                    DiagnosticsView(audio: audio, recorder: recorder, classStore: classStore,
                                    onStartDemo: startDemo, onEndDemo: endDemo,
                                    onOpenTuning: { showTuningOverlay = true })
                }
                .sheet(isPresented: $showHelp) {
                    SafariView(url: PrivacyLinks.helpURL)
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
                                 adaptiveTESettings: adaptiveTESettings)
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
            // `&& !tourActive`: this fires from AutoIDSettings.refreshPriorsFromGBIFIfNeeded
            // (ContentView's own onChange(of: location.currentCoordinate)), which can land
            // squarely in the middle of the guided tour — most obviously right after
            // onboarding, when the tour auto-starts at the same moment the very first
            // location fix comes in. A `.sheet` still presents over an active full-screen
            // overlay, so without this it visibly popped up on top of the dimmed tour.
            // Suppressing it here doesn't lose the summary — `pendingChangeSummary` stays
            // set and the binding re-evaluates once `tourActive` goes false, so it still
            // presents normally after a tour NOT heading into `tourWillPromptStart`'s own
            // post-tour sheet (which explicitly acknowledges it first — see `finish` below
            // — since that sheet already surfaces the same recommended-model information).
            get: { autoIDSettings.pendingChangeSummary != nil && !tourActive },
            set: { if !$0 { autoIDSettings.acknowledgeChangeSummary() } }
        )) {
            if let summary = autoIDSettings.pendingChangeSummary {
                LocationChangeSummaryView(settings: autoIDSettings, summary: summary)
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
        }
        // Collects the `.tourTarget` anchors from the controls below and, while the
        // tour is active, resolves them to on-screen rects for the spotlight overlay.
        .overlayPreferenceValue(TourTargetKey.self) { anchors in
            GeometryReader { proxy in
                if tourActive {
                    TourOverlay(targets: anchors.mapValues { proxy[$0] },
                                index: $tourIndex,
                                steps: TourScript.steps,
                                finish: {
                                    withAnimation(.easeInOut(duration: 0.25)) { tourActive = false }
                                    if tourWillPromptStart {
                                        tourWillPromptStart = false
                                        // Acknowledge any pending GBIF-prior-refresh summary
                                        // first — it was suppressed while the tour ran (see
                                        // the sheet above), and would otherwise still be
                                        // sitting there ready to pop up alongside the two
                                        // sheets below. SuggestedModelSheet covers the same
                                        // recommended-model information on its own terms, so
                                        // there's nothing lost by not showing the old one too.
                                        autoIDSettings.acknowledgeChangeSummary()
                                        // Let the dim overlay's own dismiss animation finish
                                        // before presenting a sheet on top of it. Suggestion
                                        // first if the location fix landed in time and found
                                        // one — its own onDismiss chains into Start Detecting;
                                        // otherwise go straight there.
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                            if let coordinate = location.currentCoordinate,
                                               let suggested = ModelRegistry.suggestedModel(for: coordinate),
                                               suggested.id != autoIDSettings.activeModelID {
                                                suggestedModelToOffer = suggested
                                            } else {
                                                showStartPrompt = true
                                            }
                                        }
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
        }
        // Loads the bundled/cached guide off the main thread (see
        // `SpeciesGuideStore.init()`'s doc comment for why this can't just
        // happen in the `@State` initializer), then checks GitHub once per
        // launch for a newer dataVersion. Offline → the remote check no-ops.
        .task { await speciesGuide.loadLocal(); await speciesGuide.refreshFromRemote() }
        // Same pattern for the committed GBIF range snapshot — no bundled
        // fallback here, so offline-with-no-cache just leaves
        // `speciesRange.ranges` empty and GBIFDistributionCard falls back to
        // its live per-species GBIF fetch.
        .task { await speciesRange.loadLocal(); await speciesRange.refreshFromRemote() }
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
            audio.activate()

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
            audio.bufferSink = { [processor, recorder] buffer in
                processor.process(buffer)
                recorder.append(buffer)
            }
            audio.autoTunePeakProvider = { [processor] in processor.peakFrequency }
            pulseDetector.onPulseStart = { [audio] freq in
                audio.notifyPulseDetected(frequency: freq)
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
            adaptiveTESettings.apply(to: audio.adaptiveTimeExpansion)
            // Region fix so species priors can be suggested from GBIF occurrence
            // data near the user (see the onChange below) — same lightweight,
            // one-shot fix AutoIDSettingsView already uses, just requested
            // proactively on launch instead of only when that screen is opened.
            location.requestRegionFix()

            // Onboarding's last step sets this right before handing off to
            // ContentView — consumed once here, immediately, so a later
            // .onAppear re-fire (e.g. returning from the background) can't
            // relaunch the tour a second time.
            if OnboardingState.shared.shouldAutoStartTour {
                OnboardingState.shared.shouldAutoStartTour = false
                tourIndex = 0
                tourWillPromptStart = true
                // Let this frame land — the tour's `.tourTarget` anchors only exist
                // once `detectorLayout` has actually mounted — same reasoning as the
                // Info sheet's tour launch above.
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.3)) { tourActive = true }
                }
            }
        }
        .sheet(isPresented: $showStartPrompt) {
            StartDetectingSheet(
                onNewSession: { startDetecting(newSession: true) },
                onJustListening: { startDetecting(newSession: false) }
            )
        }
        // Shown once, right after an onboarding-triggered tour finishes, if the
        // user's location suggests a model that isn't already active — see
        // `finish` below. Standalone: dismissing it (either "Use" or "Not Now")
        // just closes it — it does NOT chain into Start Detecting, which stays a
        // separate, deliberate action from the transport bar.
        .sheet(item: $suggestedModelToOffer) { model in
            SuggestedModelSheet(model: model, onUse: { autoIDSettings.activeModelID = model.id })
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
        }
        .onChange(of: menuIsOpen) { _, open in
            processor.suspended = open
        }
        .onChange(of: bandLow)  { _, _ in applyBand() }
        .onChange(of: bandHigh) { _, _ in applyBand() }
        // One modifier for all of the adaptive-TE tunables, not one each — see
        // `AdaptiveTimeExpansionSettings.Snapshot` for why that matters here.
        .onChange(of: adaptiveTESettings.snapshot) { _, _ in
            adaptiveTESettings.apply(to: audio.adaptiveTimeExpansion)
        }
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
                if recorder.isArmed { recorder.setArmed(false) }
                // Nothing to drain once the engine is down, and a timer left running in
                // the background is pure battery cost. Covers the interruption path too,
                // which deliberately doesn't go through stopDetecting().
                detectionPump.stop()
                // Session teardown is intentionally NOT done here. It's done explicitly
                // by stopDetecting(), which is only called on a deliberate user stop.
                // This preserves the session across transient audio interruptions
                // (phone call, Siri) and listen-mode engine restarts.
            }
        }
        // CLLocationCoordinate2D isn't Equatable; key onChange off a derived string.
        .onChange(of: location.currentCoordinate.map { "\($0.latitude),\($0.longitude)" }) { _, _ in
            recorder.setCoordinate(location.currentCoordinate.map { ($0.latitude, $0.longitude) })
            // No-ops unless this is the first fix ever or the user has moved far
            // enough since the last one — see refreshPriorsFromGBIFIfNeeded's doc
            // comment. Safe to call on every fix rather than gating the call site.
            if let coordinate = location.currentCoordinate {
                Task { await autoIDSettings.refreshPriorsFromGBIFIfNeeded(coordinate: coordinate) }
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
            // Hand draining between the Metal render loop and the background pump. Exactly
            // one of them owns it: `draw(in:)` only runs while active, the pump only while
            // not. Without the pump, backgrounding (or just locking the screen) silently
            // stops pulse detection even though audio keeps flowing — see
            // BackgroundDetectionPump for the full reasoning.
            if phase == .active {
                detectionPump.stop()
            } else if audio.isRunning {
                detectionPump.start(processor: processor, detector: pulseDetector)
            }
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
    /// all of them — portrait, landscape and both iPad variants — from one place.
    @ViewBuilder private var detectorLayout: some View {
        ZStack {
            detectorLayoutBody
            if showTuningOverlay {
                LiveTuningOverlay(
                    audio: audio,
                    adaptiveTESettings: adaptiveTESettings,
                    pulseDetector: pulseDetector,
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

    @ViewBuilder private var detectorLayoutBody: some View {
        if vSizeClass == .compact {
            landscapeLayout
        } else if UIDevice.current.userInterfaceIdiom == .pad {
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
    /// where the pulse-view card is split 50/50 with a permanently-visible Species ID
    /// list alongside it, instead of the pulse card's own species-ID toggle.
    private var ipadLandscapeLayout: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let spacing: CGFloat = 10
                let statsHeight: CGFloat = 126
                let flex = max(120, geo.size.height - statsHeight - spacing * 2)
                VStack(spacing: spacing) {
                    statsBlock.frame(height: statsHeight)
                    HStack(spacing: spacing) {
                        pulseBlock
                        speciesListBlock
                    }
                    .frame(height: flex * 0.42)
                    spectrogramBlock.frame(height: flex * 0.58)
                }
            }
            controlBar
            appFooter
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }

    /// Permanently-visible Species ID panel, used alongside `pulseBlock` in
    /// `ipadLandscapeLayout` — not toggled like the pulse/spectrogram cards'
    /// own species-ID views.
    private var speciesListBlock: some View {
        VStack(spacing: 0) {
            panelHeader("Species ID") { EmptyView() }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)
            SpeciesFeedView(store: classStore, activeSessionID: classStore.activeSessionID, sessionStart: feedSessionStart, autoIDActive: autoIDSettings.activeModelID != nil)
        }
        .panelCard()
    }

    /// The active section's content. The audio pipeline lives on the enclosing
    /// NavigationStack, so switching to Sessions doesn't stop detection.
    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .detector:  detectorLayout
        case .sessions:  SessionsView(store: classStore, settings: autoIDSettings, consent: consent)
        case .playback:  PlaybackListView(store: classStore, micCalSettings: micCalSettings, consent: consent)
        case .species:   SpeciesExplorerView(store: speciesGuide, rangeStore: speciesRange, userCoordinate: location.currentCoordinate)
        }
    }

    /// Leading-toolbar switcher between Detector and Sessions (replaces the bottom tabs).
    ///
    /// Same iOS 26 FixedMenu workaround as `optionsMenu`/`paletteButton`: without the
    /// `GlassEffectContainer` + `.glassEffect(.identity)` wrapping, Liquid Glass hides
    /// this Menu's label for the whole time it's open and then visibly fades/pulses it
    /// back in seconds after dismissal.
    private var sectionMenu: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer {
                    sectionMenuContent {
                        Image(systemName: section.icon).glassEffect(.identity)
                    }
                    .clipped()
                }
            } else {
                sectionMenuContent { Image(systemName: section.icon) }
            }
        }
        // Belt-and-braces against the inherited-animation bug documented on
        // `recordPulseAnimation`: this button has no animated state of its own (the
        // icon swap on a section change is meant to be instant), so clearing the
        // transaction's animation here means it can never ride along with an ambient
        // animation set by an unrelated `withAnimation` elsewhere in the same update
        // — which is what left it slowly throbbing during detection.
        .transaction { $0.animation = nil }
        .accessibilityLabel("Switch view")
    }

    private func sectionMenuContent(@ViewBuilder label: () -> some View) -> some View {
        Menu {
            Picker("View", selection: $section) {
                ForEach(AppSection.allCases, id: \.self) { s in
                    Label(s.rawValue, systemImage: s.icon).tag(s)
                }
            }
            Divider()
            Button { showInfo = true } label: {
                Label("Info & Tour", systemImage: "info.circle")
            }
        } label: {
            label()
        }
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
        // See sectionMenu — same guard, same reason.
        .transaction { $0.animation = nil }
        .accessibilityLabel("Menu")
    }

    private func optionsMenuContent(@ViewBuilder label: () -> some View) -> some View {
        Menu {
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Button { showHelp = true } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            Divider()
            Button { showDiagnostics = true } label: {
                Label("Diagnostics", systemImage: "gauge.medium")
            }
        } label: {
            label()
        }
    }

    /// Portrait: stacked panels with a fixed stats slot and the control bar below.
    private var portraitLayout: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let spacing: CGFloat = 10
                let statsHeight: CGFloat = 126
                let flex = max(120, geo.size.height - statsHeight - spacing * 2)
                VStack(spacing: spacing) {
                    statsBlock.frame(height: statsHeight)
                    pulseBlock.frame(height: flex * 0.42)
                    spectrogramBlock.frame(height: flex * 0.58)
                }
            }
            controlBar
            appFooter
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }

    /// Landscape: three columns.
    ///   Left  — narrow stats sidebar: stat cells stacked vertically, amplitude
    ///           meter running down the right edge of the sidebar.
    ///   Centre — spectrogram fills all remaining width.
    ///   Right  — single-row transport bar on top, pulse zoom below.
    ///            Hidden via the hamburger menu → slides off trailing edge; controls
    ///            then float over the top-right corner of the spectrogram.
    private var landscapeLayout: some View {
        GeometryReader { geo in
            let pad: CGFloat = 8
            let spacing: CGFloat = 8
            let w = geo.size.width  - pad * 2
            let h = geo.size.height - pad * 2
            let rightColW = w * 0.26
            HStack(spacing: spacing) {
                landscapeStatsSidePanel
                    .frame(width: w * 0.15)

                // In full screen (landscapePulseVisible == false) the transport
                // controls move into the spectrogram's own header as a third pill
                // (see spectrogramHeaderTrailing) instead of floating here — one
                // less thing overlaid on the view, same controls.
                VStack(spacing: spacing) {
                    landscapeStatusPillRow
                    landscapeSpectrogramBlock
                }

                if landscapePulseVisible {
                    VStack(spacing: spacing) {
                        landscapePulseBlock
                        landscapeControlsPanel
                            .frame(height: 52)
                    }
                    .frame(width: rightColW)
                    .transition(.move(edge: .trailing))
                }
            }
            .frame(width: w, height: h)
            .padding(pad)
            .clipped()
        }
    }

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
        panel(pulseShowsSpeciesID ? "Species ID" : "Pulse View", tour: .pulseView) {
            pulseHeaderTrailing
        } content: {
            pulsePanelContent
        }
    }

    private var spectrogramBlock: some View {
        panel(spectrogramShowsSpeciesID ? "Species ID" : "Spectrogram", tour: .spectrogram) {
            spectrogramHeaderTrailing(showFullScreen: false)
        } content: {
            spectrogramPanelContent()
        }
    }

    /// Landscape spectrogram panel with its header inside the card. Gets the extra
    /// full-screen button the portrait header doesn't need (portrait has no
    /// sidebar-hiding concept — the panels are already stacked full-width).
    private var landscapeSpectrogramBlock: some View {
        panel(spectrogramShowsSpeciesID ? "Species ID" : "Spectrogram", tour: .spectrogram) {
            spectrogramHeaderTrailing(showFullScreen: true)
        } content: {
            spectrogramPanelContent(showTunedOverlay: false)
        }
    }

    /// Landscape pulse panel with its header inside the card.
    private var landscapePulseBlock: some View {
        panel(pulseShowsSpeciesID ? "Species ID" : "Pulse View", tour: .pulseView) {
            pulseHeaderTrailing
        } content: {
            pulsePanelContent
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
    /// `showTunedOverlay` is false in landscape: the heterodyne tuning pill moves
    /// into `landscapeStatusPillRow` above the panel there instead of floating over
    /// the spectrogram's own corner — see that row's doc comment.
    private func spectrogramPanelContent(showTunedOverlay: Bool = true) -> some View {
        ZStack {
            SpectrogramView(processor: processor,
                            maxFrequency: nyquist,
                            bandLow: bandLow,
                            bandHigh: bandHigh,
                            timeWindowSeconds: timeWindowSeconds,
                            pulseDetector: pulseDetector,
                            isPaused: menuIsOpen,
                            logFrequency: spectrogramLogFrequency)
                .overlay(alignment: .topTrailing) { if showTunedOverlay { tunedPillOverlay } }
                .opacity(spectrogramShowsSpeciesID ? 0 : 1)
                .allowsHitTesting(!spectrogramShowsSpeciesID)

            if spectrogramShowsSpeciesID {
                SpeciesFeedView(store: classStore, activeSessionID: classStore.activeSessionID, sessionStart: feedSessionStart, autoIDActive: autoIDSettings.activeModelID != nil)
            }
        }
    }

    /// Pulse-zoom panel body — same always-mounted-plus-overlay pattern as
    /// `spectrogramPanelContent`, for the pulse-view popover (pulseViewButton).
    private var pulsePanelContent: some View {
        ZStack {
            PulseZoomView(pulseDetector: pulseDetector)
                .opacity(pulseShowsSpeciesID ? 0 : 1)
                .allowsHitTesting(!pulseShowsSpeciesID)

            if pulseShowsSpeciesID {
                // No pulse thumbnail here — this panel's landscape column is too
                // narrow, and the live pulse view already shows the same image.
                SpeciesFeedView(store: classStore, activeSessionID: classStore.activeSessionID, sessionStart: feedSessionStart, showsThumbnail: false, autoIDActive: autoIDSettings.activeModelID != nil)
            }
        }
    }

    /// Landscape top-right: single-row transport bar. Pulse-view visibility lives
    /// as a "full screen" button in the spectrogram panel's own header instead of
    /// here — same underlying toggle, but framed as "make the spectrogram full
    /// screen" rather than "hide the pulse view", which reads more clearly.
    private var landscapeControlsPanel: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.ultraThinMaterial)
            .overlay {
                HStack(spacing: 0) {
                    Spacer()
                    playStopButton
                    Spacer()
                    // Always present (not conditional on audio.isRunning) — see
                    // controlBar's matching comment: `setListenMode` stops and
                    // restarts the engine to switch modes, so isRunning flickers
                    // false→true on every mode switch, and a conditionally-shown
                    // button with a slide/fade transition animated that flicker as
                    // a visible glitch on every single toggle. Disabled instead of
                    // hidden while detection isn't running — same information,
                    // no layout churn.
                    recordButton
                        .disabled(!audio.isRunning)
                    Spacer()
                    listenModeCycleButton
                        .geometryGroup()
                    Spacer()
                }
                .controlSize(.regular)
                .padding(.horizontal, 12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Panels

    /// The horizontal row of stat readouts used in portrait. A standalone View
    /// struct (not a computed property) — `pulseDetector.pulseCount`/`pulseRateHz`
    /// update on essentially every detected pulse, sometimes many times a second
    /// during an active pass, so reading them inline in ContentView.body invalidated
    /// (and froze the hit-testing of) the whole screen exactly like the amplitude
    /// meter's 15 Hz churn did before that was fixed. Scoping it here keeps updates
    /// confined to this small view.
    private var statCellsRow: some View {
        PulseStatsRow(pulseDetector: pulseDetector, guide: speciesGuide,
                      rangeStore: speciesRange, tourDemo: tourActive)
    }

    private var statsStrip: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.ultraThinMaterial)
            .overlay {
                VStack(spacing: 4) {
                    HStack {
                        Text("STATS")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 8) {
                            speakerFeedbackWarning
                            adaptiveTEStatePill
                            sessionStatusPill
                            micStatusPill
                            resetButton
                        }
                    }
                    statCellsRow
                    amplitudeMeter
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Landscape-only status row above the spectrogram panel: the session-status
    /// (Off/Listening/Session) pill, the speaker-feedback warning, the
    /// time-expansion drain/missed-pulse pill, the heterodyne tuning pill, and the
    /// mic-connection pill — moved out of the narrow stats sidebar header (see
    /// `landscapeStatsSidePanelBody`), which had no room for them once the mic pill
    /// needed a landscape home too. Sits in its own row rather than overlaid on the
    /// spectrogram (the tuning pill's old spot) so nothing crowds the spectrogram's
    /// own header controls. Same top edge as the sidebar's header row — both start
    /// at y=0 in `landscapeLayout`'s HStack.
    private var landscapeStatusPillRow: some View {
        HStack(spacing: 8) {
            sessionStatusPill
            speakerFeedbackWarning
            adaptiveTEStatePill
            if audio.listenMode == .heterodyne {
                TunedPillView(audio: audio, nyquist: nyquist)
            }
            Spacer()
            micStatusPill
        }
    }

    /// Landscape left sidebar: stat cells stacked vertically with the amplitude
    /// meter running as a vertical bar on the right edge. Header lives inside the card.
    private var landscapeStatsSidePanel: some View {
        landscapeStatsSidePanelBody
            .tourTarget(.stats)
    }

    private var landscapeStatsSidePanelBody: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.ultraThinMaterial)
            .overlay {
                VStack(spacing: 0) {
                    HStack {
                        Text("STATS")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        resetButton
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 2)

                    HStack(spacing: 4) {
                        statCellsColumn
                            .frame(maxWidth: .infinity)
                        Divider()
                        verticalAmplitudeMeter
                            .frame(width: 22)
                    }
                    .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Stat cells arranged in a vertical column for the landscape sidebar. Same
    /// scoping rationale as `statCellsRow`.
    private var statCellsColumn: some View {
        PulseStatsColumn(pulseDetector: pulseDetector, guide: speciesGuide,
                         rangeStore: speciesRange, tourDemo: tourActive)
    }

    /// Vertical amplitude meter for the landscape sidebar. A standalone View struct
    /// (not a computed property) so its 15 Hz `currentLevelDB` read is tracked as its
    /// own body's dependency, not ContentView.body's — see PeakHoldTracker.
    private var verticalAmplitudeMeter: some View {
        VerticalAmplitudeMeterView(audio: audio, peakHold: peakHold, detector: pulseDetector)
    }

    /// Mic-connection pill: the portrait stats header, and `landscapeStatusPillRow`
    /// above the spectrogram in landscape (the stats sidebar itself is still too
    /// narrow for it). A standalone View struct because it reads
    /// `audio.diagnostics`, which mutates at the 15 Hz stats flush — same scoping
    /// rationale as the amplitude meters.
    private var micStatusPill: some View {
        MicStatusPill(audio: audio)
            .tourTarget(.micStatus)
    }

    /// Session-status pill (Off / Listening / Session) for the portrait stats
    /// header, next to the mic pill. Same scoping rationale — see
    /// `SessionStatusPillView`. Forced to read "Listening" during the guided
    /// tour for the same reason as `speakerFeedbackWarning`/`adaptiveTEStatePill`
    /// below — the tour is normally taken with detection off.
    private var sessionStatusPill: some View {
        SessionStatusPillView(audio: audio, classStore: classStore, tourDemo: tourActive)
            .tourTarget(.sessionStatus)
    }

    /// Feedback-risk warning for listening audio on the speaker. See
    /// `SpeakerFeedbackWarningPill` — same scoping rationale as `sessionStatusPill`.
    /// Forced visible during the guided tour (it's normally conditional, and the
    /// tour is usually taken with nothing playing) so its step has a target.
    private var speakerFeedbackWarning: some View {
        SpeakerFeedbackWarningPill(audio: audio, tourDemo: tourActive)
            .tourTarget(.feedbackWarning)
    }

    /// Live capturing/draining indicator for the adaptive time-expansion listen
    /// mode. Same scoping rationale as `speakerFeedbackWarning` — see
    /// `AdaptiveTimeExpansionStatePill`. Forced visible during the guided tour for
    /// the same reason as `speakerFeedbackWarning`.
    private var adaptiveTEStatePill: some View {
        AdaptiveTimeExpansionStatePill(audio: audio, tourDemo: tourActive)
            .tourTarget(.timeExpansionCounter)
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
        return audio.isRunning && rate > 0 ? rate / 2 : 192_000
    }

    /// True while a full-screen sheet covers the live view — none of them need
    /// the spectrogram's 60 Hz Metal render loop (which drains FFT columns and
    /// feeds the pulse detector inline on the main thread), and stopping it
    /// frees the main thread up for the sheet's own gesture handling instead of
    /// competing with it. Audio capture/recording itself is untouched — only
    /// live display + pulse detection pause. Deliberately excludes the pulse
    /// zoom (showPulseView) and frequency-band (showBand) popovers: those are
    /// meant to be used while watching the live feed.
    private var menuIsOpen: Bool {
        showDiagnostics || showSettings || showHelp || showInfo || autoIDSettings.pendingChangeSummary != nil
    }

    private func applyBand() {
        processor.peakMinFraction = max(bandLow, 0.01)
        processor.peakMaxFraction = bandHigh
        audio.heterodyne.setBand(low: bandLow, high: bandHigh)
        audio.adaptiveTimeExpansion.setBand(low: bandLow, high: bandHigh)
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
    /// (settings popover) pill.
    private var pulseHeaderTrailing: some View {
        HStack(spacing: 8) {
            iconPill { pulseSpeciesIDButton }
            iconPill { pulseViewButton }
        }
    }

    /// Spectrogram header trailing content: toggles pill (species ID, compress
    /// timeline, bat range, and — landscape only — full screen) + menu pill
    /// (palette, frequency-range settings).
    private func spectrogramHeaderTrailing(showFullScreen: Bool) -> some View {
        HStack(spacing: 8) {
            // Elapsed-time pill for the active listening/session, sitting to the
            // left of the control pills. Renders nothing when not detecting.
            // tourDemo forces it on with a stand-in clock during the guided tour,
            // which is normally taken before detection has ever been started.
            SessionTimerPill(start: feedSessionStart, tourDemo: tourActive)
                .tourTarget(.sessionTimer)
            // Full-screen landscape only: transport controls (play/record/listen)
            // morph into a third pill here instead of floating over the
            // spectrogram — same icons and colors as landscapeControlsPanel,
            // just relocated so everything lives in one row.
            if showFullScreen && !landscapePulseVisible {
                iconPill {
                    playStopButtonCompact
                    // Always present, disabled rather than hidden while not running —
                    // see controlBar's matching comment for why (setListenMode's
                    // stop+restart flickers audio.isRunning on every mode switch).
                    recordButtonCompact
                        .disabled(!audio.isRunning)
                    listenModeCycleButtonCompact
                        .geometryGroup()
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            iconPill {
                spectrogramSpeciesIDButton
                compressTimelineButton
                batRangeButton
                if showFullScreen { fullScreenSpectrogramButton }
            }
            iconPill { paletteButton; bandButton }
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

    /// Landscape-only: makes the spectrogram fill the screen by hiding the pulse
    /// sidebar (`landscapePulseVisible`) — same underlying state as before, but
    /// framed here as "full screen spectrogram" rather than "hide pulse view",
    /// which is what it actually accomplishes from the user's point of view.
    private var fullScreenSpectrogramButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                landscapePulseVisible.toggle()
            }
        } label: {
            Image(systemName: landscapePulseVisible
                  ? "arrow.up.left.and.arrow.down.right"
                  : "arrow.down.right.and.arrow.up.left")
                .font(.callout)
                // The layout's own spring (the pulse column sliding away) comes
                // from the withAnimation() above; without this, that SAME
                // transaction also implicitly cross-fades this icon's SF Symbol
                // swap and tint change, on a different effective timing than the
                // layout slide — that mismatch was the "icon fades in place while
                // the UI slides" glitch. Suppressing animation on just this view
                // for this value keeps the icon swap instant while the
                // surrounding layout still springs normally.
                .animation(nil, value: landscapePulseVisible)
        }
        .tint(landscapePulseVisible ? .toggleOff : .toggleOn)
        .accessibilityLabel(landscapePulseVisible ? "Full screen spectrogram" : "Show pulse view")
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
    @ViewBuilder private var tunedPillOverlay: some View {
        if audio.listenMode == .heterodyne {
            TunedPillView(audio: audio, nyquist: nyquist).padding(8)
        }
    }

    // MARK: Control bar

    private var controlBar: some View {
        HStack(spacing: 0) {
            Spacer()
            playStopButton
            Spacer()
            // Recording only makes sense once detection is actually running, but the
            // button is always present (not conditionally shown) — see
            // landscapeControlsPanel's matching comment: `setListenMode` stops and
            // restarts the engine to switch modes, so `audio.isRunning` flickers
            // false→true on every heterodyne/time-expansion/off toggle, and a
            // conditionally-shown button with a slide/fade transition animated that
            // flicker as a glitch on every single mode switch. Disabled instead of
            // hidden — same information, no layout churn, and the tour's Record
            // step always has something to point at.
            recordButton
                .disabled(!audio.isRunning)
            Spacer()
            listenModeCycleButton
                // Without this, the listen button's icon animated its own geometry
                // independently of its button chrome during the Spacer reflow above —
                // the glyph visibly lagged/shrank in place while the chrome had
                // already slid to its new position. `.geometryGroup()` (iOS 17+)
                // makes the button's whole subtree move as one rigid unit instead of
                // each descendant computing its own interpolation.
                .geometryGroup()
            Spacer()
        }
        .controlSize(.regular)
        .padding(.vertical, 6)
    }

    /// Credit + version/build line under the control bar. Version/build come straight
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

    /// Counts taps on the version footer within a rolling window; 10 taps
    /// before the window lapses triggers the bat swarm. Each tap restarts
    /// the reset timer so a burst of slower-than-instant-but-still-rapid
    /// taps still counts, but a stray single tap days apart never does.
    private func registerVersionTap() {
        versionTapResetWork?.cancel()
        versionTapCount += 1
        if versionTapCount >= 10 {
            versionTapCount = 0
            showBatSwarm = true
            flourishBatSwarmHaptics()
            DispatchQueue.main.asyncAfter(deadline: .now() + BatSwarmOverlay.totalDuration) {
                showBatSwarm = false
            }
            return
        }
        // A light tick just acknowledges the tap registered — the real payoff
        // is the haptic flourish timed to the bats actually flying out below.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let resetWork = DispatchWorkItem { versionTapCount = 0 }
        versionTapResetWork = resetWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: resetWork)
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

    private var playStopButton: some View {
        Button {
            toggleDetecting()
        } label: {
            Image(systemName: audio.isRunning ? "stop.fill" : "ear")
                .contentTransition(.symbolEffect(.replace))
                .controlIcon()
        }
        .buttonStyle(.borderedProminent)
        .tint(audio.isRunning ? .red : .accentColor)
        .accessibilityLabel(audio.isRunning ? "Stop" : "Start")
        .tourTarget(.start)
    }

    /// Same action, sized to match the other panel-header pill icons (plain
    /// `.callout`, no bordered chrome) instead of the control bar's larger
    /// `.controlIcon()` buttons — used only in the full-screen transport pill.
    private var playStopButtonCompact: some View {
        Button {
            toggleDetecting()
        } label: {
            Image(systemName: audio.isRunning ? "stop.fill" : "ear")
                .contentTransition(.symbolEffect(.replace))
                .font(.callout)
        }
        .tint(audio.isRunning ? .red : .accentColor)
        .accessibilityLabel(audio.isRunning ? "Stop" : "Start")
        .tourTarget(.start)
    }

    /// Shared action for both play/stop button variants. A demo skips the
    /// session/listening chooser — there's nothing to log, and `startDetecting`
    /// refuses to open a session while demo mode is armed anyway — so Start just
    /// resumes the file feed.
    private func toggleDetecting() {
        if audio.isRunning { stopDetecting() }
        else if audio.isDemoMode { startDetecting(newSession: false) }
        else { showStartPrompt = true }
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
        recorder.setCoordinate(nil)
        feedSessionStart = nil
        if classStore.activeSessionID != nil {
            classStore.endSession()
            location.stopTracking()
            pulseDetector.activeSessionID = nil
            recorder.setActiveSession(id: nil, startDate: nil, label: "Listening only")
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
        // no mic (see CLAUDE.md § Demo mode).
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

    /// Begin detection, optionally inside a new located session (GPS track + map pins).
    private func startDetecting(newSession: Bool) {
        pulseDetector.resetStats()
        recorder.setInputName(audio.diagnostics.inputName)
        feedSessionStart = Date()
        // Close any session that was left open by an unexpected audio stop (interruption,
        // route error) — the user is deliberately starting a new run.
        if classStore.activeSessionID != nil {
            classStore.endSession()
            location.stopTracking()
            pulseDetector.activeSessionID = nil
        }
        // Demo mode never opens a session: no GPS track, no Session row, nothing
        // in Sessions afterwards. Combined with the recorder block set in
        // `startDemo`, a demo leaves no trace in the user's data.
        if newSession && !audio.isDemoMode {
            let id = classStore.startSession()
            let session = classStore.sessions.first(where: { $0.id == id })
            let label = session?.title ?? "Session"
            pulseDetector.activeSessionID = id
            recorder.setActiveSession(id: id, startDate: session?.startDate ?? Date(), label: label)
            location.startTracking(geocodeSessionID: id)
            if autoRecordOnSessionStart {
                recorder.setArmed(true)
            }
        } else {
            recorder.setActiveSession(id: nil, startDate: nil, label: "Listening only")
        }
        // Title matches what the recorder was just handed, so the lock screen names the
        // run the same way Sessions will.
        liveActivity.start(
            sessionTitle: audio.isDemoMode
                ? "Demo"
                : (classStore.sessions.first(where: { $0.id == classStore.activeSessionID })?.title
                   ?? "Listening only"),
            isDemo: audio.isDemoMode,
            startDate: feedSessionStart ?? Date()
        )
        Task { await audio.start() }
    }

    private var recordButton: some View {
        RecordButton(recorder: recorder, action: toggleRecording)
    }

    /// Compact variant for the full-screen transport pill — see
    /// `playStopButtonCompact`.
    private var recordButtonCompact: some View {
        RecordButtonCompact(recorder: recorder, action: toggleRecording)
    }

    /// Record button arms/disarms the triggered WAV recorder. No-op while demo
    /// mode blocks recording — the buttons are disabled too, this is the
    /// backstop for any other path that reaches here.
    private func toggleRecording() {
        guard !recorder.isBlocked else { return }
        recorder.setArmed(!recorder.isArmed)
    }

    /// Cycles off → heterodyne → adaptive time expansion → off on tap, icon
    /// changing with it — replaces
    /// the old Menu-based picker, which buried listen mode two taps deep and read
    /// as unresponsive (open menu, then tap an item) even once the underlying
    /// engine restart got faster.
    private var listenModeCycleButton: some View {
        Button {
            audio.setListenMode(nextListenMode)
        } label: {
            Image(systemName: listenIcon).controlIcon()
        }
        .buttonStyle(.bordered)
        // Off = grey, matching recordButton's non-recording state — listen mode's
        // "off" isn't a configurable preset like the other orange toggles, it's
        // just inactive, same as the record button when not recording.
        .tint(audio.isListening ? .toggleOn : .toggleOff)
        .accessibilityLabel("Listening mode: \(listenModeName)")
        .tourTarget(.listen)
    }

    /// Compact variant for the full-screen transport pill — see
    /// `playStopButtonCompact`.
    private var listenModeCycleButtonCompact: some View {
        Button {
            audio.setListenMode(nextListenMode)
        } label: {
            Image(systemName: listenIcon).font(.callout)
        }
        .tint(audio.isListening ? .toggleOn : .toggleOff)
        .accessibilityLabel("Listening mode: \(listenModeName)")
        .tourTarget(.listen)
    }

    // `.timeExpansion` is playback-only (see ListenMode's doc comment) and this
    // cycle never lands on it — live listening cycles off → heterodyne →
    // adaptive time expansion → off. Handled explicitly below (rather than via
    // `default:`) purely so `ListenMode` stays exhaustively checked here.
    private var nextListenMode: ListenMode {
        switch audio.listenMode {
        case .off:                   .heterodyne
        case .heterodyne:            .adaptiveTimeExpansion
        case .adaptiveTimeExpansion: .off
        case .timeExpansion:         .off
        }
    }

    // Spelled out because this string is the VoiceOver label on the listen-mode
    // button, whose only visible cue is an icon.
    private var listenModeName: String {
        switch audio.listenMode {
        case .off:                   "Off"
        case .heterodyne:            "Heterodyne"
        case .adaptiveTimeExpansion: "Time expansion"
        // Disambiguated from the live `.adaptiveTimeExpansion` label above —
        // this one is the playback-only file mode (see ListenMode's doc comment).
        case .timeExpansion:         "Time expansion (file)"
        }
    }

    private var listenIcon: String {
        switch audio.listenMode {
        case .off:                   "headphones"
        case .heterodyne:            "antenna.radiowaves.left.and.right"
        case .adaptiveTimeExpansion: "tortoise"
        case .timeExpansion:         "tortoise"
        }
    }

}

/// Ring/dot color math shared by `RecordButton`/`RecordButtonCompact`. The two
/// layers of the `record.circle` glyph (outer ring, inner dot — palette-rendered,
/// not the single flat tint the plain glyph gets by default) swap which one is
/// "faded" depending on state: armed-and-waiting pulses the ring between faded
/// and full red (using the dot's own resting color as the pulse's peak), so the
/// static dot reads as the reference tone the ring is breathing towards. Once a
/// detection actually opens a WAV segment, the ring settles solid at that same
/// full red and the dot flips to faded instead, for contrast against the now-
/// solid ring. Disarmed uses `.secondary` for both, indistinguishable from the
/// old flat-tint icon.
private enum RecordButtonTone {
    static let faded = Color.red.opacity(0.35)

    static func ring(armed: Bool, writing: Bool, pulseBright: Bool) -> Color {
        guard armed else { return .secondary }
        if writing { return .red }
        return pulseBright ? .red : faded
    }

    static func dot(armed: Bool, writing: Bool) -> Color {
        guard armed else { return .secondary }
        return writing ? faded : .red
    }
}

/// Starts/stops the ring's breathing pulse to match armed/writing state — active
/// only while armed and waiting (not yet writing); frozen (no visible jump, since
/// `RecordButtonTone.ring` ignores `pulseBright` whenever `writing` is true) once
/// a segment opens, and restarts when it closes but the recorder is still armed.
///
/// Sets the flag with NO animation of its own. The repeating animation is attached
/// to the glyph itself via `.animation(_:value:)` (see `recordPulseAnimation`) —
/// it must NOT be started with `withAnimation`, for the reason documented there.
private func syncRecordPulse(armed: Bool, writing: Bool, pulseBright: Binding<Bool>) {
    pulseBright.wrappedValue = armed && !writing
}

/// The pulse's animation, applied to the record glyph's own subtree.
///
/// This deliberately isn't a `withAnimation(.repeatForever(autoreverses: true))`
/// wrapped around the state change. `withAnimation` installs its animation on the
/// WHOLE current transaction, so every other view that happens to change in that
/// same update cycle inherits it too — and an inherited `repeatForever` +
/// `autoreverses` has nothing to end it, so whatever caught it oscillates for the
/// rest of the run. That's what put the leading/trailing nav-bar Menu buttons into
/// a permanent slow throb while detecting: `syncRecordPulse` fires on every
/// `isArmed`/`isWriting` flip, i.e. on every WAV pass opened by a passing bat, and
/// the toolbar's Liquid Glass chrome re-lays-out constantly, so sooner or later a
/// toolbar update lands in the same transaction as one of those flips and latches
/// the repeat. Scoping the animation here means the transaction never carries it,
/// so there is nothing for the toolbar to inherit.
private func recordPulseAnimation(armed: Bool, writing: Bool) -> Animation {
    armed && !writing
        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
        : .easeInOut(duration: 0.2)
}

/// The main record toggle: arms/disarms the triggered WAV recorder. A standalone
/// `View` struct, not a computed property on `ContentView` — see CLAUDE.md's
/// `@Observable` churn note. `recorder.isWriting` flips on every WAV pass open/close
/// during active detection; reading it directly in a `ContentView.body` computed
/// property invalidated the whole screen at that rate, dropping taps on the transport
/// buttons and both toolbar menus mid-tap.
struct RecordButton: View {
    let recorder: AudioRecorder
    let action: () -> Void
    @State private var pulseBright = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "record.circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    RecordButtonTone.ring(armed: recorder.isArmed, writing: recorder.isWriting, pulseBright: pulseBright),
                    RecordButtonTone.dot(armed: recorder.isArmed, writing: recorder.isWriting)
                )
                .controlIcon()
                .animation(recordPulseAnimation(armed: recorder.isArmed, writing: recorder.isWriting),
                           value: pulseBright)
        }
        .buttonStyle(.bordered)
        .tint(recorder.isArmed ? .red : .secondary)
        .disabled(recorder.isBlocked)
        .accessibilityLabel(recorder.isArmed ? "Stop recording" : "Record")
        .accessibilityHint(recorder.isBlocked ? "Unavailable during a demo" : "")
        .tourTarget(.record)
        .onAppear { syncRecordPulse(armed: recorder.isArmed, writing: recorder.isWriting, pulseBright: $pulseBright) }
        .onChange(of: recorder.isArmed) { _, armed in
            syncRecordPulse(armed: armed, writing: recorder.isWriting, pulseBright: $pulseBright)
        }
        .onChange(of: recorder.isWriting) { _, writing in
            syncRecordPulse(armed: recorder.isArmed, writing: writing, pulseBright: $pulseBright)
        }
    }
}

/// Compact variant for the full-screen transport pill — see `RecordButton`.
struct RecordButtonCompact: View {
    let recorder: AudioRecorder
    let action: () -> Void
    @State private var pulseBright = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "record.circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    RecordButtonTone.ring(armed: recorder.isArmed, writing: recorder.isWriting, pulseBright: pulseBright),
                    RecordButtonTone.dot(armed: recorder.isArmed, writing: recorder.isWriting)
                )
                .font(.callout)
                .animation(recordPulseAnimation(armed: recorder.isArmed, writing: recorder.isWriting),
                           value: pulseBright)
        }
        .tint(recorder.isArmed ? .red : .secondary)
        .disabled(recorder.isBlocked)
        .accessibilityLabel(recorder.isArmed ? "Stop recording" : "Record")
        .accessibilityHint(recorder.isBlocked ? "Unavailable during a demo" : "")
        .tourTarget(.record)
        .onAppear { syncRecordPulse(armed: recorder.isArmed, writing: recorder.isWriting, pulseBright: $pulseBright) }
        .onChange(of: recorder.isArmed) { _, armed in
            syncRecordPulse(armed: armed, writing: recorder.isWriting, pulseBright: $pulseBright)
        }
        .onChange(of: recorder.isWriting) { _, writing in
            syncRecordPulse(armed: recorder.isArmed, writing: writing, pulseBright: $pulseBright)
        }
    }
}

/// Start-detecting chooser, replacing a plain `.confirmationDialog` with a wider
/// custom sheet — two circular icon buttons side by side read faster than a
/// stacked list of text rows, and give "New Session" and "Just Listening" equal
/// visual weight instead of implying one is the default/primary action.
private struct StartDetectingSheet: View {
    let onNewSession: () -> Void
    let onJustListening: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("Start Detection")
                    .font(.title2.weight(.semibold))
                Text("Sessions group your recordings together and plot detections on a map. Just listening still tracks location but doesn't group the data.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 32) {
                startOption(icon: "point.bottomleft.forward.to.point.topright.scurvepath.fill",
                            title: "New Session", action: onNewSession)
                startOption(icon: "person.spatialaudio.stereo.fill",
                            title: "Just Listening", action: onJustListening)
            }

            Button("Cancel", role: .cancel) { dismiss() }
                .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
    }

    private func startOption(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 72, height: 72)
                    .background(Color.accentColor.opacity(0.15), in: Circle())
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Shown once, right after an onboarding-triggered tour finishes, when the
/// user's location suggests a model that isn't already active — see
/// ContentView's `finish` closure. Same compact-sheet visual language as
/// StartDetectingSheet (centered title/subtitle, accent circle, drag
/// indicator) but its own sheet rather than folded into that one, so each can
/// be dismissed independently and chained via `onDismiss`.
private struct SuggestedModelSheet: View {
    let model: ModelDescriptor
    let onUse: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 72, height: 72)
                    .background(Color.accentColor.opacity(0.15), in: Circle())
                Text("Suggested Model")
                    .font(.title2.weight(.semibold))
                Text("\(model.displayName) covers your area (\(model.region)). Activate it to start identifying species here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            Button {
                onUse()
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
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
    }
}

private extension View {
    /// Fixed-size control-bar icon: keeps every button the same width and stops it
    /// resizing when the SF Symbol swaps (play↔stop, the listen-mode icons, etc.).
    func controlIcon() -> some View {
        font(.body)
            .frame(width: 24, height: 22)
    }

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
