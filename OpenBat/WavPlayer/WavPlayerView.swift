//
//  WavPlayerView.swift
//  OpenBat
//
//  A static, whole-file, two-axis zoomable spectrogram (WavSpectrogramView)
//  flanked by a minimap (WavMinimapView, which also doubles as the scrub bar
//  — see its own doc comment), call-parameter analysis on a manual
//  drag-selection (CallAnalysisPanel), and inline heterodyne/time-expansion
//  tuning + display options (WavTuningControl), composed around
//  PlaybackEngine (audio decode + heterodyne + time-expansion playback) and
//  PlaybackControlsView for transport.
//
//  Zoom and pan are gesture-driven directly on the spectrogram (two-axis
//  pinch for zoom, drag for pan/frequency position) rather than separate
//  ticker/slider controls — see WavSpectrogramView's and WavViewport.swift's
//  doc comments, and Context.md for what this replaced. Detected-call marker
//  dots were tried and dropped for the same reason: explicit gestures over
//  ambiguous hit-targets.
//

import SwiftUI

struct WavPlayerView: View {
    let recording: Recording
    @Bindable var store: ClassificationStore
    let micCalSettings: MicCalibrationSettings
    /// Owned locally, unlike the shared listen-mode settings — playback-only
    /// (see ListenMode's doc comment), so there's no live-detector counterpart
    /// to keep in sync with.
    @State private var timeExpSettings = TimeExpansionSettings()

    /// iPhone landscape reports a compact vertical size class — the signal we
    /// use to switch from the stacked portrait layout to the two-column
    /// landscape one (spectrogram/minimap/controls left, stats/metadata right).
    /// iPad (regular in both classes) and portrait phones keep the single
    /// column.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var engine = PlaybackEngine()
    /// Holds both the whole-file raw dB grid AND its colorized `image`
    /// together (see WavSpectrogramEngine's doc comment for why one
    /// pipeline now produces both) — a noise-floor/palette change recolors
    /// `overview.rawTile` and mutates `overview.image` in place, so
    /// WavSpectrogramView and WavMinimapView (which both just read
    /// `overview.image`) automatically show the same up-to-date recolor
    /// with no separate "recolored image" property to keep in sync.
    @State private var overview: WavSpectrogramEngine.Overview?
    @State private var recolorDebounceTask: Task<Void, Never>?
    @State private var recolorGeneration = 0
    /// Set when `WavSpectrogramEngine.renderOverview` itself fails (distinct
    /// from `engine.loadError`, which only covers PlaybackEngine's own
    /// load path) — without this, a render failure left `overview` nil with
    /// no error set at all, so the UI sat on "Rendering spectrogram…" forever.
    @State private var overviewError: String?
    /// Non-nil while this recording's WAV is still coming down from iCloud —
    /// the fraction landed so far, or nil-within-non-nil (see `DownloadState`)
    /// when iCloud isn't reporting one yet. Drives the "Downloading…" branch of
    /// `spectrogramSection`; see `load()` for why the wait is explicit.
    @State private var downloadState: DownloadState?
    /// Owns the download-then-render sequence so leaving the screen (or opening
    /// a different recording) cancels a wait that could otherwise run minutes.
    @State private var loadTask: Task<Void, Never>?

    /// `fraction` nil = iCloud hasn't reported a percentage yet, which is
    /// normal for the first seconds and for a file whose placeholder hasn't
    /// been created — the UI shows indeterminate progress rather than 0%.
    struct DownloadState { var fraction: Double? }
    @State private var viewport = WavViewport(startSample: 0, endSample: 1, minFreqHz: 0, maxFreqHz: 1)
    @State private var selection: AnalysisBox?
    /// Default (false) is pan/zoom via drag on the spectrogram; true switches
    /// its drag gesture to drawing a selection box instead.
    @State private var isSelecting = false
    @State private var analysisResult: CallAnalysis.Result?
    /// Call landmarks (Hi f / Peak / Fc / Lo f) for the current measurement,
    /// mapped into the display-sample domain for CallAnnotationOverlay.
    @State private var annotations: [CallAnnotation] = []
    @State private var analysisGeneration = 0
    @State private var showTuning = false
    /// Debounces `applyBand()` (a heterodyne DSP filter recalculation)
    /// after ANY viewport change, regardless of source (a pinch/pan on the
    /// spectrogram, or the minimap) — `viewport`
    /// itself is written immediately for instant visual feedback (its own
    /// consumers are already cheap or separately debounced — see
    /// WavSpectrogramView's `scheduleDetailRenderDebounced`), but recomputing
    /// filter coefficients on every drag frame was real, avoidable work.
    @State private var bandSyncTask: Task<Void, Never>?
    /// Debug-only red/green buffer visualization shared between
    /// WavSpectrogramView (which writes it as it stages the pan buffer —
    /// see `renderChunkedStep`) and WavMinimapView (which draws it).
    @State private var bufferDebugStatus = BufferDebugStatus()

    // Hide-silence (compressed timeline — see SilenceMap's doc comment for
    // the virtual/real domain model). `silenceMap` and `compressedOverview`
    // are always set/cleared TOGETHER (with the viewport remapped in the
    // same update), so `displayOverview` can never pair a compressed
    // overview with a stale map or vice versa.
    /// Share/export: the prepared item URL (a zip of WAV + spectrogram PNG,
    /// or the plain WAV as a fallback) drives the presented share sheet.
    @State private var shareItem: ShareItem?
    @State private var inatObservation: INatObservation?
    private struct ShareItem: Identifiable { let id = UUID(); let url: URL }

    @State private var silenceMap: SilenceMap?
    @State private var compressedOverview: WavSpectrogramEngine.Overview?
    @State private var silenceRebuildTask: Task<Void, Never>?
    @State private var silenceGeneration = 0

    /// Live playhead-follow loop — runs only while `engine.isPlaying`, at
    /// ~30Hz, updating `followState.displaySample` (NOT `viewport` — see
    /// PlaybackFollowState's doc comment for why) so WavSpectrogramView and
    /// WavMinimapView can scroll with the audio without this screen's own
    /// body re-running on every tick. Pausing commits the final position
    /// into `viewport` ONCE (see the `engine.isPlaying` onChange below), at
    /// which point the normal debounce/sharp-tile logic takes over — same
    /// "low-res while moving, sharp on pause" behavior as before, just
    /// scoped correctly now. Reads `engine.currentTimeSeconds` inside the
    /// task (NOT in body), so the ~20-25Hz progress updates don't invalidate
    /// this view's body — same isolation rule WavPlayheadOverlay documents.
    @State private var followTask: Task<Void, Never>?
    /// Never reassigned, only mutated (`displaySample`) — and never read in
    /// THIS view's own body (only handed to leaves), so those mutations
    /// don't invalidate this body. See PlaybackFollowState's doc comment.
    @State private var followState = PlaybackFollowState()

    /// Microphone response correction for THIS recording, resolved once in
    /// `load()` from the mic its own GUANO names (`Make`) — not from whatever
    /// is plugged in while you're reviewing it, which is usually nothing. Nil
    /// until resolved, and nil for good on a recording made with a mic this
    /// device has no curve for; see `MicCalibrationSettings.storedCurve`.
    @State private var calibrationCurve: MicCalibrationCurve?

    /// Shared with every other palette/log-scale control in the app.
    @AppStorage("pulse.displayPalette") private var palette: Palette = .inferno
    /// Same frequency-band crop the live Heterodyne listening uses —
    /// kept in sync with `viewport.minFreqHz/maxFreqHz` (as fractions of
    /// Nyquist) by `scheduleBandSyncDebounced`/`syncBandFromViewport`.
    /// Defaults must match `ContentView`'s for the same two keys — they are the
    /// same stored setting, so a disagreement shows up as the player and the
    /// detector cropping differently until whichever one is touched first
    /// writes the key.
    @AppStorage("display.bandLow") private var bandLow = 0.02
    @AppStorage("display.bandHigh") private var bandHigh = 0.45
    /// Reused from the Playback/Sessions thumbnail tuning — same "gate faint
    /// background energy" role, just applied to detail tiles here too. Now
    /// also exposed as a live slider directly on this screen (below), not
    /// just buried in Settings, since it's most useful to adjust while
    /// looking at the actual spectrogram. That live slider is now the ONLY
    /// control for it — the duplicate in Settings was removed 2026-08-18.
    @AppStorage("display.playbackThumbnailNoiseFloor") private var noiseFloor = 0.40
    /// Fixed, not stored. This was an `@AppStorage` slider in Settings, removed
    /// 2026-08-18 with the rest of that sheet's research parameters: it has no
    /// meaning that can be stated plainly to a general user, and no calibration
    /// exists to tune it against anyway (see `CallAnalysis`'s doc comment). Read
    /// as a constant rather than left reading `display.cfTailFraction`, so a
    /// value some earlier build stored can't go on silently shifting every Fc
    /// measurement with nothing on screen to reveal or reset it.
    private let cfTailFraction = CallAnalysis.defaultCFTailFraction
    /// Independent of the live Detector/pulse-view log toggles (their own
    /// `display.spectrogramLogFrequency`/`display.pulseLogFrequency`) — same
    /// "each spectrogram view owns its own toggle" pattern those follow.
    @AppStorage("display.wavPlayerLogFrequency") private var logFrequency = false
    /// Hide-silence toggle — deliberately session-only (`@State`, not
    /// persisted): silence is NEVER removed by default, so every recording
    /// opens on the full timeline and the user turns it on per-view when they
    /// want it. Its detection sensitivity/padding still persist as tuning
    /// preferences below.
    @State private var hideSilence = false
    /// Collapsed by default so the spectrogram — the reason this screen exists
    /// — gets the whole height it can. The GUANO card is reference material
    /// consulted occasionally, not while reading a call, and on a small phone
    /// it was taking a fifth of the screen permanently. Persisted, so a user
    /// who wants it open keeps it open across recordings; the DEFAULT is what
    /// "closed by default" means, not a per-recording reset.
    @AppStorage("display.wavPlayerShowFileInfo") private var showFileInfo = false
    /// The per-pulse ID sheet (RecordingPulsesSheet) — NOT persisted, unlike the
    /// GUANO card's disclosure: it covers the screen, so a remembered "open" would
    /// mean every recording opens with its spectrogram hidden behind a sheet.
    @State private var showPulses = false
    /// dB above the recording's own noise floor — see SilenceMap.compute for
    /// why the setting is in dB rather than the abstract 0...1 "sensitivity"
    /// this replaced. A NEW key on purpose: the old one holds 0...1 values
    /// that would read as a nonsense threshold here.
    @AppStorage("display.wavPlayerSilenceThresholdDB") private var silenceThresholdDB = 12.0
    /// Player-local playback speed for time expansion, independent of the
    /// detector — see PlaybackEngine.expansionFactor.
    @AppStorage("display.wavPlayerExpansionFactor") private var expansionFactor = 8.0
    /// What the last detection run did, for the tuning panel (see
    /// WavTuningControl.silenceSummary).
    @State private var silenceSummary: String?
    /// Seconds of audio kept each side of a pulse before cutting silence —
    /// SilenceMap.compute's `padSeconds`. Small by default so silence is cut
    /// tight; larger keeps more context and merges nearby pulses.
    @AppStorage("display.wavPlayerSilencePadding") private var silencePadding = 0.02

    /// Calls below this frequency are excluded from analysis search — matches
    /// PulseDetector's own default floor for rejecting wind/handling rumble.
    /// Also the floor for hide-silence detection (SilenceMap.compute), for
    /// the same reason: rumble shouldn't keep a gap "active".
    private static let minAnalysisFrequencyHz = 5_000.0

    /// The overview all DISPLAY consumers use: the compressed one while
    /// hide-silence is active, the real one otherwise. Everything downstream
    /// of this (viewport, minimap, tile renders) works in whichever
    /// domain this overview is in; only seeks/playhead/analysis translate.
    private var displayOverview: WavSpectrogramEngine.Overview? {
        silenceMap != nil ? compressedOverview : overview
    }

    /// The stored noise-floor slider value (0...0.9) softened before it
    /// becomes `colorize`'s gate point. That gate is a contrast stretch
    /// relative to the file's loudest call, and — measured on real
    /// recordings — the noise band lands around norm 0.05-0.17 while the
    /// weakest calls sit near norm 0.5, so a LINEAR slider put the gate
    /// right on the weakest calls by mid-travel (and the stored default is
    /// 0.5), clipping them. Squaring makes the low/mid slider gentle
    /// (0.5 -> gate 0.25, dead centre of the noise/call gap) so cleaning up
    /// background stops eating calls until the slider is pushed high, while
    /// 0 stays exactly 0 (unchanged) and the top of the range is still
    /// reachable for genuinely noisy files. Display paths only — call
    /// analysis (`requestAnalysis`) keeps the raw value, its own gating
    /// being a separate concern.
    private var effectiveNoiseFloor: Float {
        let s = Float(min(max(noiseFloor, 0), 0.99))
        return s * s
    }

    /// Palette menu styled as a header pill — same ultraThinMaterial capsule
    /// the Detector screen's header pills use.
    private var palettePill: some View {
        Menu {
            Picker("Palette", selection: $palette) {
                ForEach(Palette.allCases) { p in Text(p.displayName).tag(p) }
            }
        } label: {
            Image(systemName: "paintpalette").font(.callout).frame(width: 18, height: 18)
        }
        .tint(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityLabel("Colour palette")
    }

    /// Prepares the export item off the main actor (file copy + PNG encode +
    /// zip), then presents the share sheet. Bundles the whole-file overview
    /// image regardless of hide-silence, so the shared PNG is the full
    /// recording.
    private func shareRecording() {
        let url = store.wavURL(for: recording)
        let image = overview?.image
        let baseName = url.deletingPathExtension().lastPathComponent
        WavPlayerDebugLog.log("WavPlayer", "shareRecording: preparing export for \(baseName)")
        Task.detached(priority: .userInitiated) {
            let item = WavExport.makeShareItem(wavURL: url, overview: image, baseName: baseName)
            await MainActor.run { shareItem = ShareItem(url: item) }
        }
    }

    /// Builds the iNaturalist hand-off and opens the sheet. The text is cheap
    /// and built here; the files are prepared by the sheet itself, off the main
    /// actor — see `INatExport.prepareFiles`.
    private func addToINaturalist() {
        inatObservation = INatExport.draft(recording: recording,
                                           passes: store.passes(forRecording: recording))
    }

    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                landscapeLayout
            } else {
                portraitLayout
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(item: $inatObservation) { observation in
            INatObservationSheet(observation: observation,
                                 wavURL: store.wavURL(for: recording),
                                 overviewPNG: overview?.image.pngData())
        }
        .navigationTitle(recording.commonName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isSelecting.toggle()
                    // Leaving selection mode without an explicit clear-tap
                    // (see WavSpectrogramView.selectGesture) left a stale
                    // selection box + analysis result showing over the pan
                    // view, with no way to dismiss it short of re-entering
                    // selection mode just to tap it away — clear it here too.
                    if !isSelecting { selection = nil }
                    WavPlayerDebugLog.log("WavPlayer", "isSelecting toggled: \(isSelecting)")
                } label: {
                    Label("Select Region", systemImage: isSelecting ? "rectangle.dashed.badge.record" : "rectangle.dashed")
                }
                .tint(isSelecting ? Color.accentColor : nil)
                .accessibilityLabel(isSelecting
                    ? "Selection mode on — drag to select a call to measure"
                    : "Selection mode off — drag to pan")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    hideSilence.toggle()
                } label: {
                    Image(systemName: "speaker.slash")
                }
                // App-orange only when ON; a neutral tint when off (not the
                // default blue, which read as "active").
                .tint(hideSilence ? Color.batAccent : Color.secondary)
                .accessibilityLabel(hideSilence
                    ? "Hide silence on — timeline is compressed to activity only"
                    : "Hide silence off — full timeline shown")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showTuning = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Heterodyne / time expansion tuning")
                .popover(isPresented: $showTuning) {
                    WavTuningControl(timeExpSettings: timeExpSettings,
                                     timeExpansionSlowdownFactor: engine.expansionFactor,
                                     logFrequency: $logFrequency, noiseFloor: $noiseFloor,
                                     hideSilence: $hideSilence, silenceThresholdDB: $silenceThresholdDB,
                                     silenceSummary: silenceSummary,
                                     silencePadding: $silencePadding)
                }
            }
        }
        .onAppear { load() }
        .onDisappear {
            followTask?.cancel()
            // Leaving the screen must end an in-flight iCloud wait too — it
            // polls for up to five minutes otherwise. The download itself is
            // already requested and carries on in the background.
            loadTask?.cancel()
            engine.stop()
        }
        .onChange(of: hideSilence) { _, _ in rebuildSilenceMap() }
        .onChange(of: silenceThresholdDB) { _, _ in scheduleSilenceRebuildDebounced() }
        .onChange(of: expansionFactor) { _, factor in engine.expansionFactor = factor }
        .onChange(of: engine.expansionFactor) { _, factor in expansionFactor = factor }
        .onChange(of: silencePadding) { _, _ in scheduleSilenceRebuildDebounced() }
        .onChange(of: engine.isPlaying) { _, playing in
            if playing {
                // The compressed timeline now survives playback — the pacing
                // thread walks its segments (see PlaybackEngine.setSilenceMap),
                // so there is nothing to tear down here. Leave selection mode
                // so a two-finger measurement drag can't fight the scrolling
                // playhead.
                isSelecting = false
                selection = nil
                startFollowingPlayhead()
            } else {
                followTask?.cancel()
                followTask = nil
                // Commit the follow loop's last position into `viewport`
                // ONCE — the only write to `viewport` playback ever causes
                // now — so gestures/ticks resume from where playback left
                // off instead of the stale pre-play position.
                recenter(sample: followState.displaySample)
            }
        }
        .onChange(of: selection) { _, newValue in
            guard let newValue else { analysisResult = nil; annotations = []; return }
            requestAnalysis(startSample: newValue.samples.lowerBound,
                            endSample: newValue.samples.upperBound,
                            minFreqHz: newValue.freqHz.lowerBound,
                            maxFreqHz: newValue.freqHz.upperBound)
        }
        .onChange(of: viewport) { _, _ in scheduleBandSyncDebounced() }
        .onChange(of: noiseFloor) { _, _ in scheduleRecolorDebounced() }
        .onChange(of: palette) { _, _ in scheduleRecolorDebounced() }
        .onChange(of: timeExpSettings.gain)     { _, _ in timeExpSettings.apply(to: engine.timeExpansion) }
    }

    // MARK: Layouts

    /// Portrait / iPad: everything stacked in one column, the original layout.
    @ViewBuilder private var portraitLayout: some View {
        VStack(spacing: 8) {
            // Above the spectrogram, not below: the stat grid is now a
            // fixed-height card regardless of whether a selection has been
            // measured yet (see CallAnalysisPanel's doc comment) — moving it
            // here is what that fix is actually for, since this VStack's
            // only OTHER flexible-height element is the spectrogram itself
            // (`frame(maxHeight: .infinity)` below); a fixed-size sibling
            // above it can't push it around the way a resizing one below
            // it (in the old order) could.
            statsPanel
                .padding(.horizontal, 8)
                .padding(.top, 8)

            spectrogramSection
                .frame(maxHeight: .infinity)

            minimapBlock
            fileInfoBlock

            // No `frame(maxHeight: .infinity)` here (unlike before) — that
            // stretched this to fill whatever space was left and centered
            // the button row within it, reading as floating in the middle
            // of the screen rather than sitting with the transport controls
            // where they belong: snug under the minimap/time readout.
            PlaybackControlsView(engine: engine, onShare: shareRecording,
                                 onAddToINaturalist: addToINaturalist)
                .padding(.bottom, 8)
        }
    }

    /// iPhone landscape: two columns. Left is the interactive half —
    /// spectrogram (taking all the vertical room), then the minimap scrub bar,
    /// time readout, and transport controls stacked beneath it. Right is the
    /// reference half — the call-analysis stat grid and the file metadata card,
    /// scrollable since together they can exceed the short landscape height.
    @ViewBuilder private var landscapeLayout: some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 8) {
                // Left column. Every card carries the SAME 8pt horizontal inset
                // (the minimap/file cards already used it) so the spectrogram,
                // minimap and transport row all line up on both edges instead
                // of the spectrogram bleeding wider than the rest. The
                // spectrogram takes all the vertical slack, pushing the (now
                // compact) transport row snug to the bottom.
                VStack(spacing: 6) {
                    spectrogramSection
                        .frame(maxHeight: .infinity)
                        .padding(.horizontal, 8)
                    minimapBlock
                    PlaybackControlsView(engine: engine, onShare: shareRecording,
                                     onAddToINaturalist: addToINaturalist, compact: true)
                }
                .frame(maxWidth: .infinity)

                // Right column. `statsPanel` gets the same 8pt inset the file
                // card already has so both align; `.top` on the HStack + no top
                // padding here means the stats card's top edge lines up with the
                // spectrogram card's.
                ScrollView {
                    VStack(spacing: 8) {
                        statsPanel
                            .padding(.horizontal, 8)
                        fileInfoBlock
                    }
                    .padding(.bottom, 8)
                }
                // A fixed-ish sidebar: enough for the stat grid to read, but
                // capped so the spectrogram keeps the majority of the width.
                .frame(width: min(max(geo.size.width * 0.34, 260), 360))
            }
            .padding(.top, 4)
        }
    }

    private var statsPanel: some View {
        CallAnalysisPanel(result: analysisResult)
    }

    /// Minimap scrub bar + elapsed/duration readout. Shared by both layouts;
    /// renders nothing until the overview exists.
    @ViewBuilder private var minimapBlock: some View {
        if let displayOverview {
            WavMinimapView(overview: displayOverview, viewport: viewport, engine: engine,
                          followState: followState,
                          // Explicit closure, not `recenter` by name: the span
                          // override is a domain-crossing concern and the minimap
                          // never crosses domains.
                          onRecenter: { recenter(sample: $0) },
                          bufferDebugStatus: bufferDebugStatus)
                .frame(height: 32)
                .padding(.horizontal, 8)
            MinimapTimeLabel(engine: engine)
                .padding(.horizontal, 8)
        }
    }

    /// The GUANO card behind a disclosure row. Collapsed, this is one ~28pt
    /// row; expanded, the card appears beneath it. Because the spectrogram is
    /// the only `maxHeight: .infinity` element in either layout's stack, that
    /// difference is taken from and given back to the spectrogram directly —
    /// there is nothing else here that can absorb it, which is what makes
    /// closing it fill the screen with spectrogram on a small phone.
    @ViewBuilder private var fileInfoBlock: some View {
        if displayOverview != nil {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        // Animated so the spectrogram grows/shrinks into the space
                        // rather than jumping. `.snappy` matches the other
                        // disclosure-style transitions in the app (see
                        // MicCalibrationView/OnboardingView).
                        withAnimation(.snappy(duration: 0.28)) { showFileInfo.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Text("GUANO Metadata")
                                .font(.caption.weight(.semibold))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(showFileInfo ? 90 : 0))
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showFileInfo ? "Hide file metadata" : "Show file metadata")

                    // The per-pulse IDs for this recording. Deliberately a plain
                    // text button rather than another disclosure: unlike the
                    // GUANO card it is a LIST that pushes its own detail screens,
                    // and inlining it here would cost the spectrogram the height
                    // this card's collapse is there to protect.
                    Button("Pulses") { showPulses = true }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.batAccent)
                        .accessibilityLabel("Show every pulse detected in this recording")
                }

                if showFileInfo {
                    WavFileInfoCard(wavURL: store.wavURL(for: recording), recording: recording, store: store)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, 8)
            // Presented from HERE, not from `body`, which already carries the
            // share sheet: two `.sheet` modifiers on the same view is a shape
            // SwiftUI has historically resolved by honouring only one of them.
            // This is also simply where the button that opens it lives.
            .sheet(isPresented: $showPulses) {
                RecordingPulsesSheet(recording: recording, store: store)
            }
        }
    }

    @ViewBuilder private var spectrogramSection: some View {
        // Same hairline `panelCard()` the Detector screen's own spectrogram/
        // pulse-view panels use (ContentView.panel), title included — this
        // is the "match the main Detector page's card format" half of the
        // request; the stats panel above uses the OTHER (filled) card
        // variant, mirroring that screen's STATS strip specifically.
        VStack(spacing: 0) {
            PanelTitle("Spectrogram") {
                // Palette pill in the header, matching the Detector screen's
                // spectrogram header (its palette lives in a header pill too);
                // this slot used to hold nothing and the palette lived down in
                // the transport controls (now the Share button).
                palettePill
            }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if let displayOverview {
                // Zoom/pan is entirely gesture-driven now (two-axis pinch +
                // drag on the spectrogram itself — see WavSpectrogramView),
                // so the old "Zoom"/"Range" ticker-wheel pills that used to
                // sit under the spectrogram here have been removed.
                ZStack {
                    WavSpectrogramView(wavURL: store.wavURL(for: recording), sampleRate: displayOverview.sampleRate,
                                       overview: displayOverview, silenceMap: silenceMap,
                                       calibrationCurve: calibrationCurve,
                                       viewport: $viewport,
                                       selection: $selection, annotations: annotations, isSelecting: isSelecting,
                                       palette: palette, noiseFloor: effectiveNoiseFloor,
                                       logFrequency: logFrequency,
                                       isPlaying: engine.isPlaying, followState: followState,
                                       // A DISPLAY-domain time, which is the domain the
                                       // engine seeks in too — nothing to map (see
                                       // PlaybackEngine.setSilenceMap).
                                       onSeek: { engine.seek(toSeconds: $0) },
                                       bufferDebugStatus: bufferDebugStatus)
                    WavPlayheadOverlay(engine: engine, viewport: viewport,
                                       totalSamples: displayOverview.totalSamples)
                }
                .frame(maxHeight: .infinity)
                .padding(8)
            } else if let loadError = engine.loadError {
                ContentUnavailableView("Can't play this recording", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
                    .padding(8)
            } else if let overviewError {
                ContentUnavailableView("Can't render spectrogram", systemImage: "exclamationmark.triangle",
                                       description: Text(overviewError))
                    .padding(8)
            } else if let downloadState {
                // Distinct from "Rendering spectrogram…" on purpose: this wait
                // is a network transfer of the whole WAV (see `load()`), can
                // legitimately take minutes on a big file, and used to look
                // identical to a frozen app.
                VStack(spacing: 10) {
                    if let fraction = downloadState.fraction {
                        ProgressView(value: fraction) {
                            Text("Downloading from iCloud…")
                        }
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 260)
                    } else {
                        ProgressView("Downloading from iCloud…")
                    }
                    Text("This recording was restored from iCloud and its audio is still being fetched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Rendering spectrogram…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .panelCard()
        .padding(.horizontal, 8)
    }

    // MARK: Band sync (heterodyne)

    private static let bandSyncDebounceSeconds = 0.1

    private func scheduleBandSyncDebounced() {
        bandSyncTask?.cancel()
        bandSyncTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.bandSyncDebounceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { syncBandFromViewport() }
        }
    }

    private func syncBandFromViewport() {
        guard let overview else { return }
        let nyquist = max(overview.maxFreqHz, 1)
        bandLow = min(max(viewport.minFreqHz / nyquist, 0), 1)
        bandHigh = min(max(viewport.maxFreqHz / nyquist, 0), 1)
        applyBand()
    }

    private func applyBand() {
        engine.heterodyne.setBand(low: bandLow, high: bandHigh)
        engine.timeExpansion.setBand(low: bandLow, high: bandHigh)
    }

    // MARK: Overview recolor (shared by the spectrogram and the minimap)

    private static let recolorDebounceSeconds = 0.12

    private func scheduleRecolorDebounced() {
        recolorDebounceTask?.cancel()
        recolorDebounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.recolorDebounceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { recolorOverviewIfPossible() }
        }
    }

    /// Recolors `overview.image` at the current noise-floor/palette from the
    /// already-resident `overview.rawTile` — bounded, in-memory pixel math
    /// (see `DisplayColormap.makeLUT`'s doc comment for why this is now
    /// fast; it used to take 1.6-5.3 SECONDS per pass before that fix), no
    /// file IO, no FFT. Debounced (a real on-device drag through six 0.05
    /// noise-floor steps once fired six undebounced recolors here, all
    /// racing concurrently) and generation-guarded against whichever still
    /// manages to overlap.
    private func recolorOverviewIfPossible() {
        guard let raw = overview?.rawTile else { return }
        recolorGeneration += 1
        let myGeneration = recolorGeneration
        let pal = palette, floor = effectiveNoiseFloor, sr = overview?.sampleRate ?? 0
        // Recolor the compressed overview too when it exists — it holds its
        // OWN raw grid (the silence-stripped columns), independent of color,
        // so this is the same bounded pixel pass on a second, narrower grid.
        let compRaw = compressedOverview?.rawTile
        WavPlayerDebugLog.log("WavPlayer", "recolorOverviewIfPossible: recoloring \(raw.nCols) cols at floor=\(floor) palette=\(pal), generation=\(myGeneration)")
        Task.detached(priority: .userInitiated) {
            let tile = WavPlayerDebugLog.time("WavPlayer", "overview colorize \(raw.nCols) cols") {
                WavSpectrogramEngine.colorize(raw, sampleRate: sr, minFreqHz: 0, maxFreqHz: sr / 2,
                                              palette: pal, noiseFloor: floor)
            }
            let compTile = compRaw.flatMap { r in
                WavSpectrogramEngine.colorize(r, sampleRate: sr, minFreqHz: 0, maxFreqHz: sr / 2,
                                              palette: pal, noiseFloor: floor)
            }
            await MainActor.run {
                guard myGeneration == self.recolorGeneration else {
                    WavPlayerDebugLog.log("WavPlayer", "recolor SUPERSEDED (generation \(myGeneration) != \(self.recolorGeneration))")
                    return
                }
                guard let tile else {
                    WavPlayerDebugLog.log("WavPlayer", "colorize returned nil")
                    return
                }
                WavPlayerDebugLog.log("WavPlayer", "colorize succeeded, size=\(tile.image.size), updating overview.image")
                self.overview?.image = tile.image
                if let compTile { self.compressedOverview?.image = compTile.image }
            }
        }
    }

    // MARK: Load

    private func load() {
        let url = store.wavURL(for: recording)
        overviewError = nil
        overview = nil
        // A previous recording's compressed timeline must not survive into
        // this one — clear before the new overview lands, and let the
        // completion below rebuild it if hide-silence is (persisted) on.
        silenceMap = nil
        compressedOverview = nil
        silenceSummary = nil
        downloadState = nil

        let pal = palette, floor = effectiveNoiseFloor
        calibrationCurve = nil          // belongs to the outgoing recording
        loadTask?.cancel()
        loadTask = Task { @MainActor in
            // Nothing may touch this file until its bytes are actually here.
            // On a cloud-backed library after a delete/reinstall the WAV is an
            // iCloud placeholder, and every reader below (PlaybackEngine.load's
            // header read, renderOverview's whole-file scan) opens it with
            // FileHandle/AVAudioFile — which does not fail on a placeholder, it
            // BLOCKS while iCloud pulls down the whole multi-megabyte 384 kHz
            // file. PlaybackEngine.load blocking that way on the main actor is
            // what made tapping a recording appear to hang with no explanation.
            // Waiting here instead keeps the wait off the main thread, makes it
            // visible ("Downloading from iCloud…"), and makes it cancellable.
            if !CloudStorage.isDownloaded(url) {
                WavPlayerDebugLog.log("WavPlayer", "load: \(url.lastPathComponent) is an iCloud placeholder — downloading first")
                downloadState = DownloadState(fraction: CloudStorage.downloadFraction(url))
                let progressTask = Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { return }
                        downloadState = DownloadState(fraction: CloudStorage.downloadFraction(url))
                    }
                }
                let arrived = await CloudStorage.awaitDownload(url)
                progressTask.cancel()
                downloadState = nil
                guard !Task.isCancelled else { return }
                guard arrived else {
                    WavPlayerDebugLog.log("WavPlayer", "load: iCloud download did not complete for \(url.lastPathComponent)")
                    overviewError = "This recording is still in iCloud and hasn't finished downloading. Check your connection and open it again."
                    return
                }
            }
            guard !Task.isCancelled else { return }

            engine.load(url: url)
            engine.expansionFactor = expansionFactor
            timeExpSettings.apply(to: engine.timeExpansion)
            applyBand()

            // Before the overview render below, which bakes the correction into
            // the grid it produces. Reading the GUANO chunk is a seek plus a few
            // hundred bytes, but it is still file IO on a file that may have
            // just come down from iCloud, so it goes off the main actor.
            let settings = micCalSettings
            let calCurve = await Task.detached(priority: .userInitiated) {
                guard let make = GuanoMetadata.read(from: url)?["Make"] else { return nil as MicCalibrationCurve? }
                return await settings.storedCurve(forMicName: make)
            }.value
            guard !Task.isCancelled else { return }
            calibrationCurve = calCurve

            WavPlayerDebugLog.log("WavPlayer", "load: starting renderOverview for \(url.lastPathComponent)")
            let result = await Task.detached(priority: .userInitiated) {
                WavPlayerDebugLog.time("WavPlayer", "renderOverview") {
                    WavSpectrogramEngine.renderOverview(wavURL: url, palette: pal, noiseFloor: floor, calibrationCurve: calCurve)
                }
            }.value
            guard !Task.isCancelled else { return }
            guard let result else {
                WavPlayerDebugLog.log("WavPlayer", "renderOverview FAILED for \(url.lastPathComponent)")
                overviewError = "Couldn't render a spectrogram for this recording."
                return
            }
            WavPlayerDebugLog.log("WavPlayer", "renderOverview OK: \(Int(result.image.size.width))x\(Int(result.image.size.height)), totalSamples=\(result.totalSamples), sampleRate=\(result.sampleRate)")
            overview = result
            // Default to a half-zoomed view rather than the whole file —
            // most recordings are long enough that "whole file" shows no
            // usable call detail at all until the user zooms in manually;
            // starting already zoomed in (centered on the file's middle)
            // gives a useful view immediately.
            let whole = WavViewport.wholeFile(totalSamples: result.totalSamples, maxFreqHz: result.maxFreqHz)
            viewport = WavViewportMath.viewportForTimeZoom(
                committed: whole, zoomFraction: 0.5, totalSamples: result.totalSamples)
            // Persisted hide-silence: build its compressed timeline now
            // that the overview (its data source) exists.
            if hideSilence { rebuildSilenceMap() }
        }
    }

    // MARK: Hide-silence (compressed timeline — see SilenceMap)

    /// Builds (or tears down) the compressed timeline to match `hideSilence`,
    /// preserving the currently-centered REAL sample across the domain
    /// switch so the view doesn't jump, and handing the result to the engine
    /// so playback follows the same timeline. Detection + the
    /// compressed-overview colorize run off the main actor (the colorize is
    /// the same bounded pixel pass the normal overview uses);
    /// generation-guarded against a rapid toggle/threshold change superseding
    /// an in-flight build.
    /// Debounced rebuild for the sensitivity/padding sliders — both fire
    /// continuously while dragging and each rebuild recomputes the map +
    /// compressed overview (cheap but not free).
    private func scheduleSilenceRebuildDebounced() {
        guard hideSilence else { return }
        silenceRebuildTask?.cancel()
        silenceRebuildTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { rebuildSilenceMap() }
        }
    }

    private func rebuildSilenceMap() {
        silenceGeneration += 1
        let myGeneration = silenceGeneration

        // The real-sample window to preserve, read in whatever domain the
        // viewport is currently in. BOTH EDGES, not just the centre: the span has
        // to be re-derived in the destination domain too, or the zoom level is
        // reinterpreted as if real and virtual samples were 1:1 — see
        // `WavViewportMath.recentered`'s `span` parameter.
        let oldStartReal = silenceMap?.virtualToReal(viewport.startSample) ?? viewport.startSample
        let oldEndReal   = silenceMap?.virtualToReal(viewport.endSample) ?? viewport.endSample
        let centerReal = (oldStartReal + oldEndReal) / 2

        // Playback is NOT a reason to drop the compressed timeline any more —
        // the engine plays it (see PlaybackEngine.setSilenceMap), so the only
        // way out of this domain is the user turning the toggle off.
        guard hideSilence, let overview else {
            silenceMap = nil
            compressedOverview = nil
            silenceSummary = nil
            engine.setSilenceMap(nil)
            // Leaving the compressed domain: the preserved window is already in
            // real samples, so its span is the real span.
            if overview != nil {
                recenter(sample: centerReal, span: oldEndReal - oldStartReal)
            }
            return
        }

        let raw = overview.rawTile
        let sr = overview.sampleRate
        let realTotal = overview.totalSamples
        let pal = palette, floor = effectiveNoiseFloor
        let thresholdDB = silenceThresholdDB
        let padSeconds = silencePadding
        let minHz = Self.minAnalysisFrequencyHz
        WavPlayerDebugLog.log("WavPlayer", "rebuildSilenceMap: thresholdDB=\(thresholdDB) padSeconds=\(padSeconds), generation=\(myGeneration)")
        Task.detached(priority: .userInitiated) {
            let map = WavPlayerDebugLog.time("WavPlayer", "SilenceMap.compute") {
                SilenceMap.compute(grid: raw.grid, nCols: raw.nCols, binCount: STFTGrid.binCount,
                                   totalSamples: realTotal, sampleRate: sr,
                                   thresholdAboveFloorDB: thresholdDB, minFreqHz: minHz,
                                   padSeconds: padSeconds)
            }
            let compRaw = WavSpectrogramEngine.compressedOverviewRawTile(from: raw, map: map)
            let tile = WavPlayerDebugLog.time("WavPlayer", "compressed overview colorize \(compRaw.nCols) cols") {
                WavSpectrogramEngine.colorize(compRaw, sampleRate: sr, minFreqHz: 0, maxFreqHz: sr / 2,
                                              palette: pal, noiseFloor: floor)
            }
            await MainActor.run {
                guard myGeneration == self.silenceGeneration, self.hideSilence, let tile else {
                    WavPlayerDebugLog.log("WavPlayer", "rebuildSilenceMap SUPERSEDED/cancelled (generation \(myGeneration))")
                    return
                }
                WavPlayerDebugLog.log("WavPlayer", "rebuildSilenceMap: \(map.segments.count) segments, virtualTotal=\(map.virtualTotal) (of \(map.realTotal)), \(String(format: "%.0f", map.keptFraction * 100))%")
                self.silenceMap = map
                self.silenceSummary = Self.summary(for: map)
                self.compressedOverview = WavSpectrogramEngine.Overview(
                    rawTile: compRaw, image: tile.image, sampleRate: sr, totalSamples: map.virtualTotal)
                // Hand the SAME map to playback, so what is heard and what is
                // drawn are one timeline. This also re-derives the play
                // position, which is why it comes before the recenter below.
                self.engine.setSilenceMap(map)
                // Recenter on the preserved audio, now in the virtual domain
                // (displayOverview already returns the compressed one). The span
                // is re-derived by mapping both edges through the NEW map, so the
                // window covers the same audio rather than the same sample count.
                self.recenter(sample: map.realToVirtual(centerReal),
                              span: map.realToVirtual(oldEndReal) - map.realToVirtual(oldStartReal))
            }
        }
    }

    /// One line saying what detection did to this recording. The fallback case
    /// is called out explicitly: a map that hides nothing looks exactly like a
    /// broken toggle otherwise, and there was no way at all to tell them apart.
    private static func summary(for map: SilenceMap) -> String {
        guard !map.isFallback else {
            return "Nothing rose above the threshold — showing the whole recording. Try a lower dB setting."
        }
        let kept = Int((map.keptFraction * 100).rounded())
        let regions = map.segments.count
        return "Kept \(kept)% of the recording · \(regions) region\(regions == 1 ? "" : "s")."
    }

    /// While playing, keep `followState.displaySample` centred on the
    /// playback position so the spectrogram scrolls under a stationary
    /// playhead — see PlaybackFollowState's doc comment for why this writes
    /// THAT instead of `viewport` directly. When hide-silence is on and
    /// playback crosses into a hidden gap, skip the engine straight to the
    /// next active segment. Reads `engine.currentTimeSeconds` inside the
    /// loop (never in body) so its ~20-25Hz updates don't invalidate this
    /// view — same isolation rule WavPlayheadOverlay documents.
    private func startFollowingPlayhead() {
        followTask?.cancel()
        // Seed immediately (not just on the first tick) — without this the
        // first ~33ms of playback showed `followState.displaySample` at
        // whatever it was left at by a PREVIOUS playback run (or 0 on the
        // very first play), which briefly snapped the spectrogram to the
        // wrong place before the loop's first tick corrected it.
        updateFollowPosition()
        followTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)   // ~30Hz
                if Task.isCancelled { break }
                await MainActor.run { updateFollowPosition() }
            }
        }
    }

    private func updateFollowPosition() {
        guard engine.isPlaying, let displayOverview else { return }
        // Straight through: the engine reports its position on the same
        // timeline this screen draws — compressed while silence removal is on,
        // because the pacing thread is playing the compressed timeline rather
        // than being scrubbed across the gaps of the full one.
        followState.displaySample = Int(engine.currentTimeSeconds * displayOverview.sampleRate)
    }

    // MARK: Navigation + analysis

    /// `sample` is in the DISPLAY domain (virtual while hide-silence is on)
    /// — callers doing real-domain work (the playhead follow loop) map first.
    private func recenter(sample: Int, span: Int? = nil) {
        guard let total = displayOverview?.totalSamples else { return }
        viewport = WavViewportMath.recentered(viewport, on: sample, totalSamples: total, span: span)
    }

    private func requestAnalysis(startSample: Int, endSample: Int,
                                 minFreqHz: Double, maxFreqHz: Double) {
        guard let overview else { analysisResult = nil; return }
        // The box's low edge, floored so a drag to the very bottom can't drop
        // the measurement into sub-ultrasonic rumble/DC; the high edge is the
        // Kaleidoscope-style ceiling handed straight to CallAnalysis.
        let boxMinHz = max(Self.minAnalysisFrequencyHz, minFreqHz)
        let boxMaxHz = maxFreqHz
        analysisGeneration += 1
        let myGeneration = analysisGeneration
        let url = store.wavURL(for: recording)
        let sr = overview.sampleRate
        let floor = Float(noiseFloor)
        let tail = cfTailFraction
        // Selections are made in the display domain — map to the REAL range
        // before reading PCM. A selection spanning a hidden seam covers the
        // real gap too; harmless, since analysis hunts for the strongest
        // call within the range anyway.
        let realStart = silenceMap?.virtualToReal(startSample) ?? startSample
        let realEnd = max(realStart + 1, silenceMap?.virtualToReal(endSample) ?? endSample)
        let startSample = realStart, endSample = realEnd
        let calCurve = calibrationCurve
        WavPlayerDebugLog.log("WavPlayer", "requestAnalysis: \(startSample)-\(endSample) (\(String(format: "%.1f", Double(endSample - startSample) / sr * 1000))ms), generation=\(myGeneration)")
        Task.detached(priority: .userInitiated) {
            let result = WavPlayerDebugLog.time("WavPlayer", "CallAnalysis.analyze") {
                CallAnalysis.analyze(wavURL: url, sampleRate: sr,
                                     startSample: startSample, endSample: endSample,
                                     minFrequencyHz: boxMinHz, maxFrequencyHz: boxMaxHz,
                                     noiseFloor: floor, cfTailFraction: tail,
                                     calibrationCurve: calCurve)
            }
            await MainActor.run {
                guard myGeneration == self.analysisGeneration else {
                    WavPlayerDebugLog.log("WavPlayer", "CallAnalysis SUPERSEDED (generation \(myGeneration) != \(self.analysisGeneration))")
                    return
                }
                if let result {
                    WavPlayerDebugLog.log("WavPlayer", "CallAnalysis result: peak=\(Int(result.peakFreqHz))Hz duration=\(String(format: "%.1f", result.durationMs))ms quality=\(String(format: "%.0f", result.quality * 100))%")
                    // Landmarks are real-sample offsets from the analyzed
                    // start — add that start back and map to the display
                    // (virtual) domain the spectrogram positions against.
                    self.annotations = result.points.map { p in
                        let real = startSample + p.sampleOffset
                        let display = self.silenceMap?.realToVirtual(real) ?? real
                        return CallAnnotation(label: p.label, sample: display, freqHz: p.freqHz)
                    }
                } else {
                    WavPlayerDebugLog.log("WavPlayer", "CallAnalysis returned nil")
                    self.annotations = []
                }
                self.analysisResult = result
            }
        }
    }
}

/// Compact elapsed/duration text under the minimap — the minimap+playhead
/// now does the scrubbing `PlaybackScrubberView` used to (see
/// `WavMinimapView`), but the elapsed/remaining-time readout it also showed
/// is still useful, just relocated here. A separate leaf View for the same
/// reason `WavPlayheadOverlay`/`PlaybackScrubberView` are: `currentTimeSeconds`
/// updates at ~20-25 Hz, and reading it inline in a parent's `body` would
/// invalidate that entire body at that rate.
private struct MinimapTimeLabel: View {
    let engine: PlaybackEngine

    var body: some View {
        HStack {
            Text(Self.timeString(engine.currentTimeSeconds))
            Spacer()
            Text(Self.timeString(engine.durationSeconds))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
