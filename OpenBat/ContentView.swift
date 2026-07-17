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
private extension Color {
    static let toggleOn = Color(red: 0.914, green: 0.514, blue: 0.114) // #E9831D
    static let toggleOff = Color.secondary
}

struct ContentView: View {
    @State private var audio = AudioEngineController()
    @State private var processor = SpectrogramProcessor()
    @State private var pulseDetector = PulseDetector()
    @State private var recorder = AudioRecorder()
    @State private var screenRecorder = ScreenRecorder()
    @State private var autoIDSettings = AutoIDSettings()
    @State private var rteSettings = RTESettings()
    @State private var classStore = ClassificationStore()
    @State private var location = LocationProvider()
    @State private var showStartPrompt = false
    @State private var showDiagnostics = false
    @State private var showSettings = false
    @State private var showInfo = false
    // Guided spotlight tour (launched from Info). tourActive gates the overlay;
    // tourIndex is the current step. tourPending is set by the Info sheet's tour
    // button and consumed by its onDismiss, so the tour only starts once the
    // sheet is fully gone (no fixed-delay race with the dismiss animation).
    @State private var tourActive = false
    @State private var tourPending = false
    @State private var tourIndex = 0
    @State private var showPulseView = false
    @State private var showBand = false
    @State private var landscapePulseVisible = true
    @State private var timeWindowSeconds: Double = 0.5
    @AppStorage("display.bandLow") private var bandLow = 0.0
    @AppStorage("display.bandHigh") private var bandHigh = 1.0
    /// Pulse-view pinch-to-zoom + pan (both axes), reset on each new capture —
    /// see the "Pulse zoom/pan" section further down for the geometry.
    @State private var pulseZoomScale: CGFloat = 1
    @State private var pulseZoomBaseScale: CGFloat = 1
    @State private var pulsePanX: CGFloat = 0
    @State private var pulsePanY: CGFloat = 0
    @State private var pulsePanBaseX: CGFloat = 0
    @State private var pulsePanBaseY: CGFloat = 0
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
    // When on, arming the recorder also starts ReplayKit screen capture.
    @AppStorage("recording.screenCaptureEnabled") private var screenCaptureEnabled = false
    @AppStorage("recording.autoRecordOnSessionStart") private var autoRecordOnSessionStart = true
    // Toggled from each panel's own config popover (bandButton / pulseViewButton).
    @AppStorage("display.spectrogramShowsSpeciesID") private var spectrogramShowsSpeciesID = false
    @AppStorage("display.pulseShowsSpeciesID") private var pulseShowsSpeciesID = false

    /// Top-level sections, switched from the leading toolbar menu (replaces the old
    /// bottom tab bar). The audio pipeline keeps running across switches.
    private enum AppSection: String, CaseIterable {
        case detector  = "Detector"
        case sessions  = "Sessions"
        case species   = "Species"
        var icon: String {
            switch self {
            case .detector:  "waveform"
            case .sessions:  "square.stack.3d.up"
            case .species:   "book.closed"
            }
        }
    }
    // "-startSection Species" launch argument jumps straight to a section —
    // lets automated runs exercise non-default sections without UI scripting.
    @State private var section: AppSection =
        UserDefaults.standard.string(forKey: "startSection").flatMap(AppSection.init) ?? .detector
    /// Field-guide data (bundled → cached → GitHub). Created lazily so app
    /// startup isn't gated on JSON decode; the remote check runs in .task below.
    @State private var speciesGuide = SpeciesGuideStore()

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
                // Hidden during the tour: the Liquid Glass toolbar buttons sit
                // above the dim and keep re-adapting to the animated backdrop
                // beneath them (random-looking pulsing). They're not usable
                // mid-tour anyway; the bar returns when the tour ends.
                //
                // The reveal must NOT be animated: finish() flips tourActive
                // inside a 0.25 s withAnimation so the dim overlay can fade out,
                // and if the toolbar's .hidden→.visible rode along in that same
                // transaction, the Liquid Glass buttons would fade back in while
                // the busy dim backdrop was still animating underneath them —
                // re-triggering the same adaptive-material pulsing, except this
                // time it got stuck oscillating instead of settling. Snapping
                // the toolbar in instantly (no shared animation with the dim
                // fade) keeps the buttons still while any backdrop motion is
                // happening, so Liquid Glass never has a moving backdrop to
                // react to.
                .toolbar(tourActive ? .hidden : .visible, for: .navigationBar)
                .animation(nil, value: tourActive)
                .sheet(isPresented: $showDiagnostics) {
                    DiagnosticsView(audio: audio, recorder: recorder)
                }
                // onDismiss (not just the Done button) so per-model AutoID edits
                // survive a swipe-down dismissal of the sheet too.
                .sheet(isPresented: $showSettings, onDismiss: { autoIDSettings.save() }) {
                    SettingsView(settings: autoIDSettings, rteSettings: rteSettings,
                                 pulseDetector: pulseDetector, recorder: recorder,
                                 location: location)
                }
                .sheet(isPresented: $showInfo, onDismiss: {
                    if tourPending {
                        tourPending = false
                        tourIndex = 0
                        withAnimation(.easeInOut(duration: 0.3)) { tourActive = true }
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
        // Once per launch: see if the community species-guide JSON on GitHub
        // has a newer dataVersion than what's bundled/cached. Offline → no-op.
        .task { await speciesGuide.refreshFromRemote() }
        .onAppear {
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
            processor.sampleRate = audio.diagnostics.actualSampleRate
            pulseDetector.pcmProvider = { [processor] count, endAbsolute in
                processor.pcmSnapshot(count: count, endingAtAbsolute: endAbsolute)
            }
            pulseDetector.autoIDSettings = autoIDSettings
            pulseDetector.store = classStore
            pulseDetector.coordinateProvider = { [location] in location.currentCoordinate }
            location.store = classStore
            applyBand()
            rteSettings.apply(to: audio.timeExpansion)
        }
        .confirmationDialog("Start detecting", isPresented: $showStartPrompt, titleVisibility: .visible) {
            Button("New Session") { startDetecting(newSession: true) }
            Button("Just Listening") { startDetecting(newSession: false) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("A session logs IDs and a GPS track on a map. Listening just records to the Listening log.")
        }
        .onChange(of: audio.diagnostics.actualSampleRate) { _, rate in
            processor.sampleRate = rate
        }
        .onChange(of: bandLow)  { _, _ in applyBand() }
        .onChange(of: bandHigh) { _, _ in applyBand() }
        .onChange(of: autoIDSettings.activeModelID) { _, _ in pulseDetector.refreshModel() }
        .onChange(of: rteSettings.thresholdDB) { _, _ in rteSettings.apply(to: audio.timeExpansion) }
        .onChange(of: rteSettings.holdMs)      { _, _ in rteSettings.apply(to: audio.timeExpansion) }
        .onChange(of: rteSettings.gain)        { _, _ in rteSettings.apply(to: audio.timeExpansion) }
        .onChange(of: rteSettings.gateBlockMs) { _, _ in rteSettings.apply(to: audio.timeExpansion) }
        .onChange(of: audio.isRunning) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
            if !running {
                peakHold.reset()
                // Finalize any in-progress pass so it's saved regardless of why
                // audio stopped (user stop, interruption, listen-mode restart, etc.).
                pulseDetector.finalizePass()
                recorder.audioStopped()
                if recorder.isArmed { recorder.setArmed(false); screenRecorder.stop() }
                // Session teardown is intentionally NOT done here. It's done explicitly
                // by stopDetecting(), which is only called on a deliberate user stop.
                // This preserves the session across transient audio interruptions
                // (phone call, Siri) and listen-mode engine restarts.
            }
        }
        // CLLocationCoordinate2D isn't Equatable; key onChange off a derived string.
        .onChange(of: location.currentCoordinate.map { "\($0.latitude),\($0.longitude)" }) { _, _ in
            recorder.setCoordinate(location.currentCoordinate.map { ($0.latitude, $0.longitude) })
        }
        .onChange(of: audio.diagnostics.inputName) { _, name in
            recorder.setInputName(name)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: Adaptive layout

    @ViewBuilder private var detectorLayout: some View {
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
            SpeciesFeedView(store: classStore, activeSessionID: classStore.activeSessionID, sessionStart: feedSessionStart)
        }
        .panelCard()
    }

    /// The active section's content. The audio pipeline lives on the enclosing
    /// NavigationStack, so switching to Sessions doesn't stop detection.
    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .detector:  detectorLayout
        case .sessions:  SessionsView(store: classStore, settings: autoIDSettings)
        case .species:   SpeciesExplorerView(store: speciesGuide)
        }
    }

    /// Leading-toolbar switcher between Detector and Sessions (replaces the bottom tabs).
    private var sectionMenu: some View {
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
            Image(systemName: section.icon)
        }
        .accessibilityLabel("Switch view")
    }

    /// Settings / diagnostics menu — shown in the nav-bar trailing slot on the
    /// Detector section.
    private var optionsMenu: some View {
        Menu {
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Divider()
            Button { showDiagnostics = true } label: {
                Label("Diagnostics", systemImage: "gauge.medium")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Menu")
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
                landscapeSpectrogramBlock

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

    private var pulseBlock: some View {
        VStack(spacing: 0) {
            panelHeader(pulseShowsSpeciesID ? "Species ID" : "Pulse View") {
                pulseHeaderTrailing
            }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)
            pulsePanelContent
        }
        .panelCard()
        .tourTarget(.pulseView)
    }

    private var spectrogramBlock: some View {
        VStack(spacing: 0) {
            panelHeader(spectrogramShowsSpeciesID ? "Species ID" : "Spectrogram") {
                spectrogramHeaderTrailing(showFullScreen: false)
            }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)
            spectrogramPanelContent
        }
        .panelCard()
        .tourTarget(.spectrogram)
    }

    /// Landscape spectrogram panel with its header inside the card. Gets the extra
    /// full-screen button the portrait header doesn't need (portrait has no
    /// sidebar-hiding concept — the panels are already stacked full-width).
    private var landscapeSpectrogramBlock: some View {
        VStack(spacing: 0) {
            panelHeader(spectrogramShowsSpeciesID ? "Species ID" : "Spectrogram") {
                spectrogramHeaderTrailing(showFullScreen: true)
            }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)
            spectrogramPanelContent
        }
        .panelCard()
        .tourTarget(.spectrogram)
    }

    /// Landscape pulse panel with its header inside the card.
    private var landscapePulseBlock: some View {
        VStack(spacing: 0) {
            panelHeader(pulseShowsSpeciesID ? "Species ID" : "Pulse View") {
                pulseHeaderTrailing
            }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)
            pulsePanelContent
        }
        .panelCard()
        .tourTarget(.pulseView)
    }

    /// Spectrogram panel body — the live Metal view, with the species feed overlaid
    /// on top (not branched in/out) when toggled from the frequency-range popover
    /// (bandButton). Keeping the SpectrogramView permanently mounted means its
    /// MTKView/Metal state is never torn down and rebuilt by the toggle — previously
    /// an if/else branch here would remove SpectrogramView from the tree entirely,
    /// which froze it (and the Metal draw loop) whenever the sibling panel's toggle
    /// forced this ViewBuilder to re-evaluate.
    private var spectrogramPanelContent: some View {
        ZStack {
            SpectrogramView(processor: processor,
                            maxFrequency: nyquist,
                            bandLow: bandLow,
                            bandHigh: bandHigh,
                            timeWindowSeconds: timeWindowSeconds,
                            pulseDetector: pulseDetector)
                .overlay(alignment: .topTrailing) { tunedPillOverlay }
                .opacity(spectrogramShowsSpeciesID ? 0 : 1)
                .allowsHitTesting(!spectrogramShowsSpeciesID)

            if spectrogramShowsSpeciesID {
                SpeciesFeedView(store: classStore, activeSessionID: classStore.activeSessionID, sessionStart: feedSessionStart)
            }
        }
    }

    /// Pulse-zoom panel body — same always-mounted-plus-overlay pattern as
    /// `spectrogramPanelContent`, for the pulse-view popover (pulseViewButton).
    private var pulsePanelContent: some View {
        ZStack {
            pulseZoomPanel
                .opacity(pulseShowsSpeciesID ? 0 : 1)
                .allowsHitTesting(!pulseShowsSpeciesID)

            if pulseShowsSpeciesID {
                // No pulse thumbnail here — this panel's landscape column is too
                // narrow, and the live pulse view already shows the same image.
                SpeciesFeedView(store: classStore, activeSessionID: classStore.activeSessionID, sessionStart: feedSessionStart, showsThumbnail: false)
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
                    recordButton
                    Spacer()
                    listenModeCycleButton
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
        PulseStatsRow(pulseDetector: pulseDetector)
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
        PulseStatsColumn(pulseDetector: pulseDetector)
    }

    /// Vertical amplitude meter for the landscape sidebar. A standalone View struct
    /// (not a computed property) so its 15 Hz `currentLevelDB` read is tracked as its
    /// own body's dependency, not ContentView.body's — see PeakHoldTracker.
    private var verticalAmplitudeMeter: some View {
        VerticalAmplitudeMeterView(audio: audio, peakHold: peakHold, detector: pulseDetector)
    }

    /// Mic-connection pill for the portrait stats header (the landscape sidebar is
    /// too narrow for it). A standalone View struct because it reads
    /// `audio.diagnostics`, which mutates at the 15 Hz stats flush — same scoping
    /// rationale as the amplitude meters.
    private var micStatusPill: some View {
        MicStatusPill(audio: audio)
            .tourTarget(.micStatus)
    }

    private var resetButton: some View {
        Button {
            pulseDetector.resetStats()
            peakHold.reset()
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(6)
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

    // MARK: Pulse zoom/pan
    //
    // Photos-app-style pinch-to-zoom + drag-to-pan over PulseImageRenderer's wide
    // render (full spectrum vertically, tight-window-plus-margin horizontally —
    // see PulseImageRenderer.swift and PulseDetector's captured*Wide*/*TimeTight*
    // properties). Both axes use the same `.scaleEffect(anchor: .center)` +
    // `.offset()` composition:
    //
    //   screen(v) = 0.5 + (v − 0.5)·s + offset      (v, screen ∈ [0,1], top/left = 0)
    //
    // `axisZoomGeometry` picks the (defaultScale, offset) pair that makes the tight
    // default window exactly fill the frame at rest; `pulsePanX`/`pulsePanY` START
    // at that value and are the SINGLE source of truth for the current offset from
    // then on (pinch only ever changes scale; drag only ever changes pan) — no
    // separate "baked default" + "user delta" to keep in sync, which is what
    // caused the earlier Y-only zoom bug (see git history). `clampOffsetFrac`
    // bounds pan so the visible window can never pan past the rendered content's
    // own edges ("hit walls").

    private var pulseZoomPanel: some View {
        GeometryReader { geo in
            pulseZoomContent(geo: geo)
        }
    }

    private func pulseZoomContent(geo: GeometryProxy) -> some View {
        // Each axis floors at scale 1 (its full rendered content) independently —
        // the shared pinch multiplier can drive one axis's raw product below 1
        // (e.g. an axis with a smaller "exact fit" scale) without that axis
        // rendering smaller than its own content, which wouldn't mean anything.
        let scaleX = max(1, timeZoomGeometry.defaultScale * pulseZoomScale)
        let scaleY = max(1, freqZoomGeometry.defaultScale * pulseZoomScale)

        return ZStack(alignment: .topLeading) {
            if let img = pulseDetector.lastPulseImage {
                // .high interpolation looks crisp instead of a blurry upscale.
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(x: scaleX, y: scaleY, anchor: .center)
                    .offset(x: pulsePanX * geo.size.width, y: pulsePanY * geo.size.height)
                    .clipped()
            } else {
                Text("No pulse detected")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            pulseGrid

            if pulseDetector.capturedFreqMax > 0 {
                pulseFrequencyAxis.padding(6)
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(pulseDetector.capturedDurationMs > 0
                         ? String(format: "%.0f ms", pulseDetector.capturedDurationMs)
                         : "–")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(6)
                }
            }
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .contentShape(Rectangle())
        .gesture(pulseZoomPanGesture(geoSize: geo.size, scaleX: scaleX, scaleY: scaleY))
        // A new capture resets to the default (reduced-zoom, centred) view —
        // otherwise a leftover zoom/pan from the previous pulse would crop into an
        // unrelated new one.
        .onChange(of: pulseDetector.lastDetectionDate) { _, _ in
            pulseZoomScale = pulseZoomDefaultMultiplier
            pulseZoomBaseScale = pulseZoomDefaultMultiplier
            let sx = max(1, timeZoomGeometry.defaultScale * pulseZoomDefaultMultiplier)
            let sy = max(1, freqZoomGeometry.defaultScale * pulseZoomDefaultMultiplier)
            pulsePanBaseX = centeringOffset(midFrac: timeTightMidFrac, scale: sx)
            pulsePanBaseY = centeringOffset(midFrac: freqTightMidFrac, scale: sy)
            pulsePanX = pulsePanBaseX
            pulsePanY = pulsePanBaseY
        }
    }

    /// Multiplier applied to each axis's "exact fit" scale (see `axisZoomGeometry`)
    /// for the DEFAULT view — under 1 shows some context around the tight call
    /// crop instead of filling the frame with just the crop, which read as too
    /// tightly zoomed in by default.
    private let pulseZoomDefaultMultiplier: CGFloat = 0.6

    /// Given where the default (tight) window sits within the wider rendered
    /// content — as a [leftFrac, rightFrac] pair, 0…1, matching the content's own
    /// top→bottom or left→right order — returns the scale that exactly fills the
    /// frame with just that window (used as the reference "1×" for pinch, and
    /// scaled down by `pulseZoomDefaultMultiplier` for the actual default view).
    private func axisZoomGeometry(leftFrac: Double, rightFrac: Double) -> (defaultScale: CGFloat, midFrac: Double) {
        let span = max(0.02, rightFrac - leftFrac)
        return (CGFloat(1 / span), (leftFrac + rightFrac) / 2)
    }

    /// The `.offset()` fraction that centres wide-image point `midFrac` on screen
    /// at the given scale: solving `screen(midFrac) = 0.5 + (midFrac-0.5)·scale +
    /// offset = 0.5` for offset. Re-derived at whatever the CURRENT scale is
    /// (rather than only at the "exact fit" scale) so it stays centred as pinch
    /// zooms in/out, and so the reduced-zoom default (`pulseZoomDefaultMultiplier`
    /// ≠ 1) is centred too.
    private func centeringOffset(midFrac: Double, scale: CGFloat) -> CGFloat {
        CGFloat(-(midFrac - 0.5)) * scale
    }

    /// Bounds a total offset fraction (centring + user pan) so the visible window
    /// never pans past the edge of the rendered content, at the given effective
    /// scale. At scale 1 the window already fills the content exactly, so the
    /// bound is 0 (no pan room); it grows as you zoom in.
    private func clampOffsetFrac(_ offset: CGFloat, scale: CGFloat) -> CGFloat {
        let bound = max(0, 0.5 * (scale - 1))
        return min(max(offset, -bound), bound)
    }

    private var freqZoomGeometry: (defaultScale: CGFloat, midFrac: Double) {
        let wideLo = pulseDetector.capturedWideFreqMin
        let wideHi = pulseDetector.capturedWideFreqMax
        let tightLo = pulseDetector.capturedFreqMin
        let tightHi = pulseDetector.capturedFreqMax
        let span = wideHi - wideLo
        guard span > 0, tightHi > tightLo else { return (1, 0.5) }
        let leftFrac = (wideHi - tightHi) / span     // tight band's top edge, high freq = top = 0
        let rightFrac = (wideHi - tightLo) / span    // tight band's bottom edge
        return axisZoomGeometry(leftFrac: leftFrac, rightFrac: rightFrac)
    }

    private var timeZoomGeometry: (defaultScale: CGFloat, midFrac: Double) {
        axisZoomGeometry(leftFrac: pulseDetector.capturedTimeTightLeftFrac,
                         rightFrac: pulseDetector.capturedTimeTightRightFrac)
    }

    private var freqTightMidFrac: Double { freqZoomGeometry.midFrac }
    private var timeTightMidFrac: Double { timeZoomGeometry.midFrac }

    /// Effective visible frequency range for the current zoom/pan — used by
    /// `pulseFrequencyAxis` so the labels track what's on screen, not just the
    /// default view. Inverts the same screen(v) relationship the render uses.
    private var visiblePulseFreqRange: (lo: Double, hi: Double) {
        let wideLo = pulseDetector.capturedWideFreqMin
        let wideHi = pulseDetector.capturedWideFreqMax
        let span = wideHi - wideLo
        let s = Double(max(1, freqZoomGeometry.defaultScale * pulseZoomScale))
        guard span > 0, s > 0 else {
            return (pulseDetector.capturedFreqMin, pulseDetector.capturedFreqMax)
        }
        let offset = Double(pulsePanY)
        // screen(v) = 0.5 + (v-0.5)*s + offset; solving for v at screen = 0 / 1.
        let vTop = 0.5 - (0.5 + offset) / s
        let vBottom = 0.5 + (0.5 - offset) / s
        return (lo: wideHi - vBottom * span, hi: wideHi - vTop * span)
    }

    /// Pinch range: down to whichever axis's full-wide-content multiplier is
    /// smaller (so pinching out far enough always reaches "show everything" on at
    /// least one axis — the other, if its own default scale is smaller, will hit
    /// its own scale-1 floor first; see the `max(1, ...)` clamps on scaleX/scaleY),
    /// up to generous zoom-in headroom above the exact-fit scale.
    private var pulseZoomLowerBound: CGFloat {
        1 / max(timeZoomGeometry.defaultScale, freqZoomGeometry.defaultScale)
    }
    private var pulseZoomUpperBound: CGFloat {
        max(timeZoomGeometry.defaultScale, freqZoomGeometry.defaultScale) * 5
    }

    private func pulseZoomPanGesture(geoSize: CGSize, scaleX: CGFloat, scaleY: CGFloat) -> some Gesture {
        let magnification = MagnificationGesture()
            .onChanged { value in
                // Preserve the CURRENT on-screen centre point as scale changes —
                // without this, changing scale while the `.offset()` pan stays
                // fixed drifts the view back toward the wide image's own centre
                // (screen = 0.5 + (v-0.5)·s + offset ⇒ the visible centre
                // v = 0.5 − offset/s moves whenever s changes unless offset is
                // re-derived for the new s at the same v).
                let oldScaleX = max(1, timeZoomGeometry.defaultScale * pulseZoomScale)
                let oldScaleY = max(1, freqZoomGeometry.defaultScale * pulseZoomScale)
                let vCenterX = 0.5 - Double(pulsePanX) / Double(oldScaleX)
                let vCenterY = 0.5 - Double(pulsePanY) / Double(oldScaleY)

                pulseZoomScale = min(max(pulseZoomBaseScale * value, pulseZoomLowerBound), pulseZoomUpperBound)

                let newScaleX = max(1, timeZoomGeometry.defaultScale * pulseZoomScale)
                let newScaleY = max(1, freqZoomGeometry.defaultScale * pulseZoomScale)
                pulsePanX = clampOffsetFrac(CGFloat((0.5 - vCenterX) * Double(newScaleX)), scale: newScaleX)
                pulsePanY = clampOffsetFrac(CGFloat((0.5 - vCenterY) * Double(newScaleY)), scale: newScaleY)
            }
            .onEnded { _ in
                pulseZoomBaseScale = pulseZoomScale
                pulsePanBaseX = pulsePanX
                pulsePanBaseY = pulsePanY
            }
        // Pan reads scaleX/scaleY fresh from the closure each call (captured by
        // reference via `self`), so it stays correctly bounded even while a
        // simultaneous pinch is changing the scale mid-drag.
        let pan = DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard geoSize.width > 0, geoSize.height > 0 else { return }
                let dxFrac = value.translation.width / geoSize.width
                let dyFrac = value.translation.height / geoSize.height
                pulsePanX = clampOffsetFrac(pulsePanBaseX + dxFrac, scale: scaleX)
                pulsePanY = clampOffsetFrac(pulsePanBaseY + dyFrac, scale: scaleY)
            }
            .onEnded { _ in
                pulsePanBaseX = pulsePanX
                pulsePanBaseY = pulsePanY
            }
        return SimultaneousGesture(magnification, pan)
    }

    /// Faint analysis grid over the pulse capture. Vertical lines mark time
    /// (the brighter dashed one is the locked pulse onset, at the detector's
    /// onsetFraction); horizontal lines mark frequency, aligned with the
    /// hi / mid / lo axis labels.
    private var pulseGrid: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let onsetX = w * CGFloat(pulseDetector.onsetFraction)
            ZStack {
                Path { p in
                    for f in [0.25, 0.5, 0.75] as [CGFloat] {   // time divisions
                        p.move(to: CGPoint(x: w * f, y: 0)); p.addLine(to: CGPoint(x: w * f, y: h))
                    }
                    for f in [0.25, 0.5, 0.75] as [CGFloat] {   // frequency divisions
                        p.move(to: CGPoint(x: 0, y: h * f)); p.addLine(to: CGPoint(x: w, y: h * f))
                    }
                }
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)

                Path { p in                                      // onset marker
                    p.move(to: CGPoint(x: onsetX, y: 0)); p.addLine(to: CGPoint(x: onsetX, y: h))
                }
                .stroke(Color.white.opacity(0.30), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
            }
        }
        .allowsHitTesting(false)
    }

    private var pulseFrequencyAxis: some View {
        let (lo, hi) = visiblePulseFreqRange
        return VStack {
            axisLabel(hi)
            Spacer()
            axisLabel((lo + hi) / 2)
            Spacer()
            axisLabel(lo)
        }
    }

    private func axisLabel(_ hz: Double) -> some View {
        Text(hz >= 1000 ? String(format: "%.0f kHz", hz / 1000)
                        : String(format: "%.0f Hz", hz))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
            .shadow(radius: 1)
    }

    // MARK: Helpers

    private var nyquist: Double {
        let rate = audio.diagnostics.actualSampleRate
        return audio.isRunning && rate > 0 ? rate / 2 : 192_000
    }

    private func applyBand() {
        processor.peakMinFraction = max(bandLow, 0.01)
        processor.peakMaxFraction = bandHigh
        audio.heterodyne.setBand(low: bandLow, high: bandHigh)
        audio.timeExpansion.setBand(low: bandLow, high: bandHigh)
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
            // Full-screen landscape only: transport controls (play/record/listen)
            // morph into a third pill here instead of floating over the
            // spectrogram — same icons and colors as landscapeControlsPanel,
            // just relocated so everything lives in one row.
            if showFullScreen && !landscapePulseVisible {
                iconPill { playStopButtonCompact; recordButtonCompact; listenModeCycleButtonCompact }
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
        }
        .tint(.secondary)
        .accessibilityLabel("Frequency range")
        .popover(isPresented: $showBand) {
            FrequencyBandControl(low: $bandLow, high: $bandHigh,
                                 maxFrequency: nyquist,
                                 timeWindowSeconds: $timeWindowSeconds,
                                 noiseFloor: $pulseDetector.spectrogramNoiseFloor)
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
            recordButton
            Spacer()
            listenModeCycleButton
            Spacer()
        }
        .controlSize(.regular)
        .padding(.vertical, 6)
    }

    private var playStopButton: some View {
        Button {
            if audio.isRunning { stopDetecting() }
            else { showStartPrompt = true }
        } label: {
            Image(systemName: audio.isRunning ? "stop.fill" : "ear")
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
            if audio.isRunning { stopDetecting() }
            else { showStartPrompt = true }
        } label: {
            Image(systemName: audio.isRunning ? "stop.fill" : "ear").font(.callout)
        }
        .tint(audio.isRunning ? .red : .accentColor)
        .accessibilityLabel(audio.isRunning ? "Stop" : "Start")
        .tourTarget(.start)
    }

    /// Stop detection and tear down the active session. Called only on explicit user
    /// action so that transient audio interruptions and listen-mode restarts don't
    /// accidentally end the session.
    private func stopDetecting() {
        pulseDetector.finalizePass()  // save any in-progress pass before session ends
        audio.stop()
        recorder.setCoordinate(nil)
        feedSessionStart = nil
        if classStore.activeSessionID != nil {
            classStore.endSession()
            location.stopTracking()
            pulseDetector.activeSessionID = nil
            recorder.setActiveSession(id: nil, label: "Listening only")
            screenRecorder.activeSessionID = nil
        }
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
        if newSession {
            let id = classStore.startSession()
            let label = classStore.sessions.first(where: { $0.id == id })?.title ?? "Session"
            pulseDetector.activeSessionID = id
            recorder.setActiveSession(id: id, label: label)
            screenRecorder.activeSessionID = id
            location.startTracking(geocodeSessionID: id)
            if autoRecordOnSessionStart {
                recorder.setArmed(true)
                if screenCaptureEnabled { screenRecorder.start() }
            }
        } else {
            recorder.setActiveSession(id: nil, label: "Listening only")
            screenRecorder.activeSessionID = nil
        }
        Task { await audio.start() }
    }

    private var recordButton: some View {
        Button { toggleRecording() } label: {
            Image(systemName: recorder.isWriting ? "record.circle.fill" : "record.circle")
                .controlIcon()
        }
        .buttonStyle(.bordered)
        .tint(recorder.isArmed ? .red : .secondary)
        .accessibilityLabel(recorder.isArmed ? "Stop recording" : "Record")
        .tourTarget(.record)
    }

    /// Compact variant for the full-screen transport pill — see
    /// `playStopButtonCompact`.
    private var recordButtonCompact: some View {
        Button { toggleRecording() } label: {
            Image(systemName: recorder.isWriting ? "record.circle.fill" : "record.circle")
                .font(.callout)
        }
        .tint(recorder.isArmed ? .red : .secondary)
        .accessibilityLabel(recorder.isArmed ? "Stop recording" : "Record")
        .tourTarget(.record)
    }

    /// Record button arms the triggered WAV recorder and starts/stops the
    /// whole-session ReplayKit screen capture together.
    private func toggleRecording() {
        let willArm = !recorder.isArmed
        recorder.setArmed(willArm)
        if willArm {
            if screenCaptureEnabled { screenRecorder.start() }
        } else {
            screenRecorder.stop()
        }
    }

    private var triggeredDisplayButton: some View {
        Button { pulseDetector.triggeredDisplayMode.toggle() } label: {
            Image(systemName: "rectangle.compress.vertical").controlIcon()
        }
        .buttonStyle(.bordered)
        .tint(pulseDetector.triggeredDisplayMode ? .green : .secondary)
        .accessibilityLabel("Triggered display")
    }

    /// Cycles off → heterodyne → RTE → off on tap, icon changing with it — replaces
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

    private var nextListenMode: ListenMode {
        switch audio.listenMode {
        case .off:           .heterodyne
        case .heterodyne:    .timeExpansion
        case .timeExpansion: .off
        }
    }

    private var listenModeName: String {
        switch audio.listenMode {
        case .off:           "Off"
        case .heterodyne:    "Heterodyne"
        case .timeExpansion: "RTE"
        }
    }

    private var listenIcon: String {
        switch audio.listenMode {
        case .off:           "headphones"
        case .heterodyne:    "antenna.radiowaves.left.and.right"
        case .timeExpansion: "tortoise"
        }
    }

}

// MARK: - Pulse stat cells

/// One labelled stat readout (title, big value, small unit) — a leaf View so it
/// carries no dependencies of its own; used by `PulseStatsRow`/`PulseStatsColumn`.
private struct StatCell: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title3.monospacedDigit().weight(.semibold))
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .minimumScaleFactor(0.6)
        .lineLimit(1)
    }
}

/// Last-ID readout with a stale-after-30s red tint. `TimelineView` re-evaluates
/// once a second so the ID turns red as it ages without needing a pulse (or any
/// other state change) to trigger a redraw — already self-contained (the
/// `pulseDetector.lastPassResult`/`lastPassDate` reads happen inside the
/// `TimelineView` content closure, not synchronously during the parent's body).
private struct SpeciesStatCell: View {
    let pulseDetector: PulseDetector

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let isStale = pulseDetector.lastPassDate
                .map { context.date.timeIntervalSince($0) > staleIDSeconds } ?? false
            VStack(spacing: 2) {
                Text("SPECIES")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let pass = pulseDetector.lastPassResult {
                    HStack(alignment: .center, spacing: 4) {
                        Text(pass.species)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isStale ? .red : .primary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(pulseDetector.lastPassPulseCount)p")
                            Text(String(format: "%.0f%%", pass.confidence * 100))
                        }
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text("–")
                        .font(.title3.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
        }
    }
}

/// Horizontal stat row for portrait. A standalone View struct: `pulseDetector`'s
/// `pulseCount`/`pulseRateHz`/`capturedPeakFreq`/`capturedDurationMs`/
/// `capturedFreqMin`/`capturedFreqMax` update on essentially every detected pulse
/// (sometimes many times a second during an active pass) — reading them inline in
/// ContentView.body invalidated (and froze the hit-testing of) the whole screen,
/// the same failure mode the amplitude meter had before it was scoped down.
private struct PulseStatsRow: View {
    let pulseDetector: PulseDetector

    var body: some View {
        // 1 Hz TimelineView so the last-pulse stats age out on their own —
        // without it they'd freeze at their final values until the next pulse.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let values = PulseStatValues(pulseDetector, now: context.date)
            HStack(spacing: 0) {
                StatCell(title: "Fpeak", value: values.fpeak, unit: "kHz")
                statDivider
                StatCell(title: "Bndwth", value: values.bandwidth, unit: "kHz")
                statDivider
                StatCell(title: "Dur", value: values.duration, unit: "ms")
                statDivider
                StatCell(title: "Rate", value: values.rate, unit: "/s")
                statDivider
                StatCell(title: "Pulses", value: "\(pulseDetector.pulseCount)", unit: "")
                statDivider
                SpeciesStatCell(pulseDetector: pulseDetector)
            }
        }
    }

    private var statDivider: some View {
        Divider().frame(height: 28)
    }
}

/// Vertical stat column for the landscape sidebar. Same scoping rationale as
/// `PulseStatsRow`.
private struct PulseStatsColumn: View {
    let pulseDetector: PulseDetector

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let values = PulseStatValues(pulseDetector, now: context.date)
            VStack(spacing: 0) {
                StatCell(title: "Fpeak", value: values.fpeak, unit: "kHz").frame(maxHeight: .infinity)
                Divider()
                StatCell(title: "Bndwth", value: values.bandwidth, unit: "kHz").frame(maxHeight: .infinity)
                Divider()
                StatCell(title: "Dur", value: values.duration, unit: "ms").frame(maxHeight: .infinity)
                Divider()
                StatCell(title: "Rate", value: values.rate, unit: "/s").frame(maxHeight: .infinity)
                Divider()
                StatCell(title: "Pulses", value: "\(pulseDetector.pulseCount)", unit: "").frame(maxHeight: .infinity)
                Divider()
                SpeciesStatCell(pulseDetector: pulseDetector).frame(maxHeight: .infinity)
            }
        }
    }
}

/// Display strings for the last-pulse stat cells (Fpeak/Bndwth/Dur/Rate),
/// shared by the portrait row and landscape column. All four describe the most
/// recent pulse (or, for Rate, the window around it), so once nothing has been
/// captured for `staleIDSeconds` — the same threshold that turns the species ID
/// red — they revert to "–" instead of freezing at values from a long-gone pass.
/// The Pulses counter is cumulative and deliberately exempt.
private struct PulseStatValues {
    let fpeak: String
    let bandwidth: String
    let duration: String
    let rate: String

    init(_ d: PulseDetector, now: Date) {
        let stale = d.lastDetectionDate
            .map { now.timeIntervalSince($0) > staleIDSeconds } ?? true
        fpeak = !stale && d.capturedPeakFreq > 0
            ? String(format: "%.0f", d.capturedPeakFreq / 1000) : "–"
        let bw = d.capturedFreqMax - d.capturedFreqMin
        bandwidth = !stale && bw > 0 ? String(format: "%.0f", bw / 1000) : "–"
        duration = !stale && d.capturedDurationMs > 0
            ? String(format: "%.0f", d.capturedDurationMs) : "–"
        rate = !stale && d.pulseRateHz > 0
            ? String(format: "%.1f", d.pulseRateHz) : "–"
    }
}

/// An ID/capture older than this is stale: the species cell turns red and the
/// last-pulse stat cells clear — it's from a previous pass, not whatever is
/// flying now.
private let staleIDSeconds: TimeInterval = 30

// MARK: - Heterodyne tuning pill

/// Draggable pill showing the heterodyne LO frequency. A standalone View struct:
/// `audio.tunedFrequency`/`isAutoTune` update at 15 Hz (the same stats timer that
/// drives the amplitude meter) while heterodyne listening is active, so this keeps
/// that churn from invalidating all of ContentView.body. Owns its own drag-gesture
/// state instead of borrowing @State from the parent.
private struct TunedPillView: View {
    let audio: AudioEngineController
    let nyquist: Double

    @State private var dragBaseFrequency: Double?
    @State private var dragBaseHeight: CGFloat = 0

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: audio.isAutoTune ? "a.circle.fill" : "hand.draw.fill")
                .font(.system(size: 11))
            Text(audio.tunedFrequency > 0
                 ? String(format: "%.1f kHz", audio.tunedFrequency / 1000)
                 : "tuning…")
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(audio.isAutoTune ? .green : .orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .gesture(tuneGesture)
    }

    private var tuneGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let dy = value.translation.height
                if dragBaseFrequency == nil {
                    guard abs(dy) > 6 else { return }
                    dragBaseFrequency = audio.tunedFrequency > 0 ? audio.tunedFrequency : nyquist * 0.25
                    dragBaseHeight = dy
                }
                guard let base = dragBaseFrequency else { return }
                let hzPerPoint = max(nyquist / 500, 50)
                audio.setManualTune(frequency: base - Double(dy - dragBaseHeight) * hzPerPoint)
            }
            .onEnded { _ in
                if dragBaseFrequency == nil { audio.enableAutoTune() }
                dragBaseFrequency = nil
            }
    }
}

// MARK: - Mic status pill

/// External-mic connection indicator: a green connector icon that slowly pulses
/// while a USB mic (the Griff) is attached, or a red slashed connector when only
/// the built-in mic is available. While capturing, also shows the delivered feed
/// rate in kHz, flashing red if iOS hands us less than the required 384 kHz.
private struct MicStatusPill: View {
    let audio: AudioEngineController
    @State private var slowPulse = false   // ~1.4 s breathe for the connected icon
    @State private var fastFlash = false   // ~0.4 s blink for a clamped feed rate

    private static let requiredRate: Double = 384_000

    var body: some View {
        let d = audio.diagnostics
        let connected = d.usbMicAvailable
        let rateKnown = audio.isRunning && d.actualSampleRate > 0
        let rateBad = rateKnown && d.actualSampleRate < Self.requiredRate
        HStack(spacing: 4) {
            Image(systemName: connected ? "cable.connector" : "cable.connector.slash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(connected ? Color.green : .red)
                .opacity(connected && slowPulse ? 0.35 : 1)
            if rateKnown {
                Text("\(Int((d.actualSampleRate / 1000).rounded())) kHz")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(rateBad ? Color.red : .secondary)
                    .opacity(rateBad && fastFlash ? 0.25 : 1)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { slowPulse = true }
            withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) { fastFlash = true }
        }
        .accessibilityLabel(connected ? "External microphone connected" : "No external microphone")
    }
}

// MARK: - Amplitude meter

/// Shared math for the amplitude meters. Free functions rather than ContentView
/// methods so the standalone meter View structs below can use them too.
private enum MeterMath {
    /// Meter floor in dBFS. Higher than the −80 capture floor because the ambient
    /// noise floor sits near −60, so the useful swing is −60…0.
    static let floorDB: Double = -60

    /// Maps a dBFS value to 0…1 over the meter's [floorDB, 0] range.
    static func normalized(_ db: Double) -> Double {
        min(max((db - floorDB) / (0 - floorDB), 0), 1)
    }

    /// Samples the user-selected display palette so the meter matches the
    /// spectrogram. Skewed toward the bright end (t = 0.35…1) because most
    /// palettes start near-black, which would make the low segments invisible.
    static func color(_ frac: Double, palette: Palette) -> Color {
        let f = min(max(frac, 0), 1)
        let (r, g, b) = DisplayColormap.rgb(Float(0.35 + 0.65 * f), palette: palette)
        return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

/// Owns the peak-hold position for the amplitude meters. Held as `@State` in
/// ContentView but only ever read/written from inside the meter leaf views below,
/// so its 15 Hz updates never invalidate ContentView.body.
@Observable
final class PeakHoldTracker {
    private(set) var peakHold: Double = 0    // 0–1 peak-hold position for the VU meter
    private var peakHoldAt: Date = .distantPast

    func update(db: Double) {
        let n = MeterMath.normalized(db)
        if n >= peakHold {
            peakHold = n                       // jump up to a new peak and hold
            peakHoldAt = Date()
        } else if Date().timeIntervalSince(peakHoldAt) > 0.8 {
            peakHold = max(n, peakHold - 0.02) // then fall back gradually (~0.3/s at 15 Hz)
        }
    }

    func reset() { peakHold = 0 }
}

/// Retro segmented level meter with a falling peak-hold dot, driven by the input
/// RMS level. Segments sample the selected display palette. A standalone
/// View (not a ContentView computed property) so reading `currentLevelDB` at
/// 15 Hz only invalidates this small view, not the whole screen.
private struct AmplitudeMeterView: View {
    let audio: AudioEngineController
    let peakHold: PeakHoldTracker
    let detector: PulseDetector

    var body: some View {
        let palette = detector.displayPalette
        let level = MeterMath.normalized(Double(audio.diagnostics.currentLevelDB))
        let segments = 40
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("AMPLITUDE")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f dBFS", audio.diagnostics.currentLevelDB))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        ForEach(0..<segments, id: \.self) { i in
                            let frac = Double(i) / Double(segments - 1)
                            let lit = frac <= level
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(MeterMath.color(frac, palette: palette).opacity(lit ? 1 : 0.12))
                        }
                    }
                    if peakHold.peakHold > 0 {
                        Circle()
                            .fill(MeterMath.color(peakHold.peakHold, palette: palette))
                            .frame(width: 7, height: 7)
                            .shadow(color: MeterMath.color(peakHold.peakHold, palette: palette).opacity(0.8), radius: 2)
                            .position(x: max(3, min(geo.size.width - 3, geo.size.width * peakHold.peakHold)),
                                      y: geo.size.height / 2)
                    }
                }
            }
            .frame(height: 13)

            HStack {
                meterScaleLabel("-60")
                Spacer()
                meterScaleLabel("-30")
                Spacer()
                meterScaleLabel("0 dB")
            }
        }
        .onChange(of: audio.diagnostics.currentLevelDB) { _, db in
            peakHold.update(db: Double(db))
        }
    }

    private func meterScaleLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 8).monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// Vertical amplitude meter for the landscape sidebar. Same scoping rationale as
/// `AmplitudeMeterView`.
private struct VerticalAmplitudeMeterView: View {
    let audio: AudioEngineController
    let peakHold: PeakHoldTracker
    let detector: PulseDetector

    var body: some View {
        let palette = detector.displayPalette
        let level = MeterMath.normalized(Double(audio.diagnostics.currentLevelDB))
        let segments = 20
        VStack(spacing: 2) {
            Text(String(format: "%.0f", audio.diagnostics.currentLevelDB))
                .font(.system(size: 6).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            GeometryReader { geo in
                ZStack {
                    VStack(spacing: 1) {
                        ForEach((0..<segments).reversed(), id: \.self) { i in
                            let frac = Double(i) / Double(segments - 1)
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(MeterMath.color(frac, palette: palette).opacity(frac <= level ? 1 : 0.12))
                        }
                    }
                    if peakHold.peakHold > 0 {
                        Circle()
                            .fill(MeterMath.color(peakHold.peakHold, palette: palette))
                            .frame(width: 6, height: 6)
                            .shadow(color: MeterMath.color(peakHold.peakHold, palette: palette).opacity(0.8), radius: 2)
                            .position(x: geo.size.width / 2,
                                      y: geo.size.height * (1.0 - CGFloat(peakHold.peakHold)))
                    }
                }
            }
            Text("dB")
                .font(.system(size: 6))
                .foregroundStyle(.secondary)
        }
        .onChange(of: audio.diagnostics.currentLevelDB) { _, db in
            peakHold.update(db: Double(db))
        }
    }
}

private extension View {
    /// Transparent rounded card with a thin hairline border — used to tighten up
    /// the spectrogram and pulse-view panels without a heavy filled background.
    /// Fixed-size control-bar icon: keeps every button the same width and stops it
    /// resizing when the SF Symbol swaps (play↔stop, the listen-mode icons, etc.).
    func controlIcon() -> some View {
        font(.body)
            .frame(width: 24, height: 22)
    }

    func panelCard(cornerRadius: CGFloat = 10) -> some View {
        clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            )
    }
}

#Preview { ContentView() }
