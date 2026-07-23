//
//  WavPlayerView.swift
//  OpenBat
//
//  The rebuilt WAV player — replaces PlaybackPlayerView (which reused the
//  live Detector screen's scrolling Metal SpectrogramView, restarted on
//  every load). This is a purpose-built player: a static, whole-file,
//  two-axis zoomable spectrogram (WavSpectrogramView) flanked by a minimap
//  (WavMinimapView, which also doubles as the scrub bar — see its own doc
//  comment), call-parameter analysis on a manual drag-selection
//  (CallAnalysisPanel), and inline heterodyne/RTE tuning + display options
//  (WavTuningControl) — composed around the SAME PlaybackEngine (audio
//  decode + heterodyne + RTE playback, fixed separately for the LO auto-tune
//  bug) and the SAME transport buttons (PlaybackControlsView) the old player
//  used; only the spectrogram visualization half (and the scrub bar, now the
//  minimap) changed.
//
//  Zoom (time) and Range (frequency span) are two `TickerWheelControl` pills
//  at the bottom of the screen — replaces the old horizontal `Slider` and the
//  two-thumb `VerticalRangeSlider`. The frequency axis is now POSITION
//  (panned by dragging directly on the spectrogram — see
//  WavSpectrogramView's vertical-pan handling) crossed with WIDTH (the Range
//  ticker, zooming around whatever center the pan left it at, not the
//  file's fixed midpoint — see `WavViewportMath.viewportForFreqZoom`).
//  Detected calls were also once tappable marker dots — pulled, same as the
//  trim slider, in favour of explicit controls: no gesture-recognition
//  ambiguity to get wrong, no unlabelled marker dots to explain. See
//  WavViewport.swift's doc comment.
//

import SwiftUI

struct WavPlayerView: View {
    let recording: Recording
    @Bindable var store: ClassificationStore
    let rteSettings: RTESettings

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
    @State private var viewport = WavViewport(startSample: 0, endSample: 1, minFreqHz: 0, maxFreqHz: 1)
    @State private var selection: ClosedRange<Int>?
    /// Default (false) is pan/zoom via drag + the ticker pills below; true
    /// switches the spectrogram's drag gesture to drawing a selection box
    /// instead.
    @State private var isSelecting = false
    @State private var analysisResult: CallAnalysis.Result?
    /// Call landmarks (Hi f / Peak / Fc / Lo f) for the current measurement,
    /// mapped into the display-sample domain for CallAnnotationOverlay.
    @State private var annotations: [CallAnnotation] = []
    @State private var analysisGeneration = 0
    @State private var showTuning = false
    /// Debounces `applyBand()` (a heterodyne/RTE DSP filter recalculation)
    /// after ANY viewport change, regardless of source (Range ticker, a
    /// vertical pan on the spectrogram, the minimap, Zoom) — `viewport`
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
    private struct ShareItem: Identifiable { let id = UUID(); let url: URL }

    @State private var silenceMap: SilenceMap?
    @State private var compressedOverview: WavSpectrogramEngine.Overview?
    @State private var silenceRebuildTask: Task<Void, Never>?
    @State private var silenceGeneration = 0

    /// Live playhead-follow loop — runs only while `engine.isPlaying`, at
    /// ~20Hz, recentering `viewport` on the playback position so the
    /// spectrogram scrolls with the audio. Detail renders stay naturally
    /// suppressed while scrolling (each viewport write resets
    /// WavSpectrogramView's 150ms render debounce), so the scroll rides the
    /// cheap overview crop; pausing stops the writes, the debounce fires,
    /// and the normal tile/buffer logic takes over — exactly the
    /// "low-res while moving, sharp on pause" behavior wanted. Reads
    /// `engine.currentTimeSeconds` inside the task (NOT in body), so the
    /// ~20-25Hz progress updates don't invalidate this view's body — same
    /// isolation rule WavPlayheadOverlay documents.
    @State private var followTask: Task<Void, Never>?

    /// Shared with every other palette/log-scale control in the app.
    @AppStorage("pulse.displayPalette") private var palette: Palette = .inferno
    /// Same frequency-band crop the live Heterodyne/RTE listening uses —
    /// kept in sync with `viewport.minFreqHz/maxFreqHz` (as fractions of
    /// Nyquist) by `scheduleBandSyncDebounced`/`syncBandFromViewport`.
    @AppStorage("display.bandLow") private var bandLow = 0.0
    @AppStorage("display.bandHigh") private var bandHigh = 1.0
    /// Reused from the Playback/Sessions thumbnail tuning — same "gate faint
    /// background energy" role, just applied to detail tiles here too. Now
    /// also exposed as a live slider directly on this screen (below), not
    /// just buried in Settings, since it's most useful to adjust while
    /// looking at the actual spectrogram.
    @AppStorage("display.playbackThumbnailNoiseFloor") private var noiseFloor = 0.5
    @AppStorage("display.cfTailFraction") private var cfTailFraction = CallAnalysis.defaultCFTailFraction
    /// Independent of the live Detector/pulse-view log toggles (their own
    /// `display.spectrogramLogFrequency`/`display.pulseLogFrequency`) — same
    /// "each spectrogram view owns its own toggle" pattern those follow.
    @AppStorage("display.wavPlayerLogFrequency") private var logFrequency = false
    /// Hide-silence toggle + its detection sensitivity (0...1, mapped to a
    /// dB threshold by `silenceThresholdDB`) — toolbar button and tuning
    /// popover respectively.
    @AppStorage("display.wavPlayerHideSilence") private var hideSilence = false
    @AppStorage("display.wavPlayerSilenceSensitivity") private var silenceSensitivity = 0.5
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
    /// of this (viewport, minimap, tickers, tile renders) works in whichever
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

    var body: some View {
        VStack(spacing: 8) {
            // Above the spectrogram, not below: the stat grid is now a
            // fixed-height card regardless of whether a selection has been
            // measured yet (see CallAnalysisPanel's doc comment) — moving it
            // here is what that fix is actually for, since this VStack's
            // only OTHER flexible-height element is the spectrogram itself
            // (`frame(maxHeight: .infinity)` below); a fixed-size sibling
            // above it can't push it around the way a resizing one below
            // it (in the old order) could.
            CallAnalysisPanel(result: analysisResult)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            spectrogramSection
                .frame(maxHeight: .infinity)

            if let displayOverview {
                WavMinimapView(overview: displayOverview, viewport: viewport, engine: engine,
                              silenceMap: silenceMap, onRecenter: recenter,
                              bufferDebugStatus: bufferDebugStatus)
                    .frame(height: 32)
                    .padding(.horizontal, 8)
                MinimapTimeLabel(engine: engine)
                    .padding(.horizontal, 8)

                WavFileInfoCard(wavURL: store.wavURL(for: recording))
                    .padding(.horizontal, 8)
            }

            // No `frame(maxHeight: .infinity)` here (unlike before) — that
            // stretched this to fill whatever space was left and centered
            // the button row within it, reading as floating in the middle
            // of the screen rather than sitting with the transport controls
            // where they belong: snug under the minimap/time readout.
            PlaybackControlsView(engine: engine, onShare: shareRecording)
                .padding(.bottom, 8)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
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
                .accessibilityLabel("Heterodyne / RTE tuning")
                .popover(isPresented: $showTuning) {
                    WavTuningControl(rteSettings: rteSettings, logFrequency: $logFrequency, noiseFloor: $noiseFloor,
                                     hideSilence: $hideSilence, silenceSensitivity: $silenceSensitivity,
                                     silencePadding: $silencePadding)
                }
            }
        }
        .onAppear { load() }
        .onDisappear {
            followTask?.cancel()
            engine.stop()
        }
        .onChange(of: hideSilence) { _, _ in rebuildSilenceMap() }
        .onChange(of: silenceSensitivity) { _, _ in scheduleSilenceRebuildDebounced() }
        .onChange(of: silencePadding) { _, _ in scheduleSilenceRebuildDebounced() }
        .onChange(of: engine.isPlaying) { _, playing in
            if playing {
                // Playback runs on the REAL, linear timeline: suspend
                // hide-silence (rebuildSilenceMap tears the compressed
                // timeline down while `isPlaying`, see its guard) and leave
                // selection mode so a two-finger measurement drag can't fight
                // the scrolling playhead.
                isSelecting = false
                selection = nil
                rebuildSilenceMap()
                startFollowingPlayhead()
            } else {
                followTask?.cancel()
                followTask = nil
                // Restore the compressed timeline if hide-silence is on.
                rebuildSilenceMap()
            }
        }
        .onChange(of: selection) { _, newValue in
            guard let newValue else { analysisResult = nil; annotations = []; return }
            requestAnalysis(startSample: newValue.lowerBound, endSample: newValue.upperBound)
        }
        .onChange(of: viewport) { _, _ in scheduleBandSyncDebounced() }
        .onChange(of: noiseFloor) { _, _ in scheduleRecolorDebounced() }
        .onChange(of: palette) { _, _ in scheduleRecolorDebounced() }
        // RTESettings is a reference type edited in-place by WavTuningControl's
        // sliders (bound via @Bindable) — those mutations don't reach
        // `engine.timeExpansion` on their own, so without these the RTE
        // gain/sensitivity sliders in this player's tuning popover had no
        // audible effect until the player was reloaded. Same 5-property
        // onChange list ContentView already uses for the live Detector screen.
        .onChange(of: rteSettings.minFrequencyKHz) { _, _ in rteSettings.apply(to: engine.timeExpansion) }
        .onChange(of: rteSettings.marginDB)    { _, _ in rteSettings.apply(to: engine.timeExpansion) }
        .onChange(of: rteSettings.holdMs)      { _, _ in rteSettings.apply(to: engine.timeExpansion) }
        .onChange(of: rteSettings.gain)        { _, _ in rteSettings.apply(to: engine.timeExpansion) }
        .onChange(of: rteSettings.gateBlockMs) { _, _ in rteSettings.apply(to: engine.timeExpansion) }
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
                                       viewport: $viewport,
                                       selection: $selection, annotations: annotations, isSelecting: isSelecting,
                                       palette: palette, noiseFloor: effectiveNoiseFloor,
                                       logFrequency: logFrequency,
                                       isPlaying: engine.isPlaying,
                                       onSeek: { displaySeconds in
                                           // The spectrogram hands back a DISPLAY-domain
                                           // time; map through the silence map (if any)
                                           // to the real position the engine plays.
                                           let sr = displayOverview.sampleRate
                                           let displaySample = Int(displaySeconds * sr)
                                           let realSample = silenceMap?.virtualToReal(displaySample) ?? displaySample
                                           engine.seek(toSeconds: Double(realSample) / sr)
                                       },
                                       bufferDebugStatus: bufferDebugStatus)
                    WavPlayheadOverlay(engine: engine, viewport: viewport, silenceMap: silenceMap,
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
            } else {
                ProgressView("Rendering spectrogram…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .panelCard()
        .padding(.horizontal, 8)
    }

    // MARK: Band sync (heterodyne/RTE)

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
        engine.load(url: url)
        rteSettings.apply(to: engine.timeExpansion)
        applyBand()

        let pal = palette, floor = effectiveNoiseFloor
        WavPlayerDebugLog.log("WavPlayer", "load: starting renderOverview for \(url.lastPathComponent)")
        Task.detached(priority: .userInitiated) {
            let result = WavPlayerDebugLog.time("WavPlayer", "renderOverview") {
                WavSpectrogramEngine.renderOverview(wavURL: url, palette: pal, noiseFloor: floor)
            }
            await MainActor.run {
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
                // gives a useful view immediately. `viewportForTimeZoom` at
                // fraction 0.5 is the same value the Zoom ticker defaults to,
                // so it reads correctly centered too, not stuck at "0.1".
                let whole = WavViewport.wholeFile(totalSamples: result.totalSamples, maxFreqHz: result.maxFreqHz)
                viewport = WavViewportMath.viewportForTimeZoom(
                    committed: whole, zoomFraction: 0.5, totalSamples: result.totalSamples)
                // Persisted hide-silence: build its compressed timeline now
                // that the overview (its data source) exists.
                if hideSilence { rebuildSilenceMap() }
            }
        }
    }

    // MARK: Hide-silence (compressed timeline — see SilenceMap)

    /// Builds (or tears down) the compressed timeline to match `hideSilence`,
    /// preserving the currently-centered REAL sample across the domain
    /// switch so the view doesn't jump. Detection + the compressed-overview
    /// colorize run off the main actor (the colorize is the same bounded
    /// pixel pass the normal overview uses); generation-guarded against a
    /// rapid toggle/sensitivity change superseding an in-flight build.
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

        // The real-sample center to preserve, read in whatever domain the
        // viewport is currently in.
        let oldCenter = (viewport.startSample + viewport.endSample) / 2
        let centerReal = silenceMap?.virtualToReal(oldCenter) ?? oldCenter

        // Suspended entirely while PLAYING — playback runs on the real,
        // linear timeline (see the `engine.isPlaying` onChange). The map is
        // rebuilt when playback stops.
        guard hideSilence, !engine.isPlaying, let overview else {
            // Turning OFF (or suspended for playback): drop the compressed
            // timeline and recenter the real-domain viewport on the same audio.
            silenceMap = nil
            compressedOverview = nil
            if overview != nil { recenter(sample: centerReal) }
            return
        }

        let raw = overview.rawTile
        let sr = overview.sampleRate
        let realTotal = overview.totalSamples
        let pal = palette, floor = effectiveNoiseFloor
        let sensitivity = silenceSensitivity
        let padSeconds = silencePadding
        let minHz = Self.minAnalysisFrequencyHz
        WavPlayerDebugLog.log("WavPlayer", "rebuildSilenceMap: sensitivity=\(sensitivity) padSeconds=\(padSeconds), generation=\(myGeneration)")
        Task.detached(priority: .userInitiated) {
            let map = WavPlayerDebugLog.time("WavPlayer", "SilenceMap.compute") {
                SilenceMap.compute(grid: raw.grid, nCols: raw.nCols, binCount: STFTGrid.binCount,
                                   totalSamples: realTotal, sampleRate: sr,
                                   sensitivity: sensitivity, minFreqHz: minHz, padSeconds: padSeconds)
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
                WavPlayerDebugLog.log("WavPlayer", "rebuildSilenceMap: \(map.segments.count) segments, virtualTotal=\(map.virtualTotal) (of \(map.realTotal)), \(String(format: "%.0f", Double(map.virtualTotal) / Double(max(map.realTotal, 1)) * 100))%")
                self.silenceMap = map
                self.compressedOverview = WavSpectrogramEngine.Overview(
                    rawTile: compRaw, image: tile.image, sampleRate: sr, totalSamples: map.virtualTotal)
                // Recenter on the preserved audio, now in the virtual domain
                // (displayOverview already returns the compressed one).
                self.recenter(sample: map.realToVirtual(centerReal))
            }
        }
    }

    /// While playing, keep `viewport` centred on the playback position so the
    /// spectrogram scrolls under a stationary playhead. Each ~20Hz recenter
    /// resets WavSpectrogramView's detail-render debounce, so the scroll
    /// rides the cheap overview crop (low-res, as intended); pausing stops
    /// the writes and the debounce then fires the sharp tile render. When
    /// hide-silence is on and playback crosses into a hidden gap, skip the
    /// engine straight to the next active segment. Reads
    /// `engine.currentTimeSeconds` inside the loop (never in body) so its
    /// ~20-25Hz updates don't invalidate this view — same isolation rule
    /// WavPlayheadOverlay documents.
    private func startFollowingPlayhead() {
        followTask?.cancel()
        followTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)   // ~30Hz
                if Task.isCancelled { break }
                await MainActor.run {
                    guard engine.isPlaying, let displayOverview else { return }
                    let sr = displayOverview.sampleRate
                    let realSample = Int(engine.currentTimeSeconds * sr)
                    if let map = silenceMap, let skipTo = map.nextActiveRealStart(after: realSample) {
                        // In a hidden gap — jump to the next real activity.
                        // seek() sets currentTimeSeconds synchronously into
                        // that (active) segment, so the next tick sees an
                        // active position and this fires at most once per gap.
                        engine.seek(toSeconds: Double(skipTo) / sr)
                        return
                    }
                    let displaySample = silenceMap?.realToVirtual(realSample) ?? realSample
                    recenter(sample: displaySample)
                }
            }
        }
    }

    // MARK: Navigation + analysis

    /// `sample` is in the DISPLAY domain (virtual while hide-silence is on)
    /// — callers doing real-domain work (the playhead follow loop) map first.
    private func recenter(sample: Int) {
        guard let total = displayOverview?.totalSamples else { return }
        let span = min(viewport.sampleSpan, total)
        var start = sample - span / 2
        var end = start + span
        if start < 0 { end -= start; start = 0 }
        if end > total { start -= (end - total); end = total }
        viewport = WavViewport(startSample: max(0, start), endSample: min(total, end),
                               minFreqHz: viewport.minFreqHz, maxFreqHz: viewport.maxFreqHz)
    }

    private func requestAnalysis(startSample: Int, endSample: Int) {
        guard let overview else { analysisResult = nil; return }
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
        WavPlayerDebugLog.log("WavPlayer", "requestAnalysis: \(startSample)-\(endSample) (\(String(format: "%.1f", Double(endSample - startSample) / sr * 1000))ms), generation=\(myGeneration)")
        Task.detached(priority: .userInitiated) {
            let result = WavPlayerDebugLog.time("WavPlayer", "CallAnalysis.analyze") {
                CallAnalysis.analyze(wavURL: url, sampleRate: sr,
                                     startSample: startSample, endSample: endSample,
                                     minFrequencyHz: Self.minAnalysisFrequencyHz, noiseFloor: floor,
                                     cfTailFraction: tail)
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
