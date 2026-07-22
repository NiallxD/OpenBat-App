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

    /// Calls below this frequency are excluded from analysis search — matches
    /// PulseDetector's own default floor for rejecting wind/handling rumble.
    private static let minAnalysisFrequencyHz = 5_000.0

    var body: some View {
        VStack(spacing: 0) {
            spectrogramSection
                .frame(maxHeight: .infinity)

            if let overview {
                WavMinimapView(overview: overview, viewport: viewport, engine: engine, onRecenter: recenter)
                    .frame(height: 32)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                MinimapTimeLabel(engine: engine)
                    .padding(.horizontal, 8)
            }

            Divider().padding(.top, 6)
            CallAnalysisPanel(result: analysisResult, isSelecting: isSelecting)
            Divider()

            PlaybackControlsView(engine: engine, palette: $palette)
                .frame(maxHeight: .infinity)
        }
        .navigationTitle(recording.commonName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isSelecting.toggle()
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
                    showTuning = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Heterodyne / RTE tuning")
                .popover(isPresented: $showTuning) {
                    WavTuningControl(rteSettings: rteSettings, logFrequency: $logFrequency, noiseFloor: $noiseFloor)
                }
            }
        }
        .onAppear { load() }
        .onDisappear { engine.stop() }
        .onChange(of: selection) { _, newValue in
            guard let newValue else { analysisResult = nil; return }
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
        if let overview {
            VStack(spacing: 10) {
                ZStack {
                    WavSpectrogramView(wavURL: store.wavURL(for: recording), sampleRate: overview.sampleRate,
                                       overview: overview, viewport: $viewport,
                                       selection: $selection, isSelecting: isSelecting,
                                       palette: palette, noiseFloor: Float(noiseFloor),
                                       logFrequency: logFrequency,
                                       onSeek: { engine.seek(toSeconds: $0) })
                    WavPlayheadOverlay(engine: engine, viewport: viewport)
                }
                .frame(maxHeight: .infinity)

                tickerControls(nyquistHz: overview.maxFreqHz)
            }
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

    /// The two ticker-wheel pills — pulled out of `spectrogramSection` into
    /// their own function (rather than an inline `HStack` there) purely to
    /// keep the compiler's type-checking scope small; the combined
    /// expression (ZStack + this HStack, each with several generic-heavy
    /// modifiers/closures) was timing out type-checking as one expression.
    @ViewBuilder
    private func tickerControls(nyquistHz: Double) -> some View {
        HStack(spacing: 24) {
            TickerWheelControl(title: "Zoom", value: zoomBinding, range: 0.1...1.0, step: 0.01,
                               format: zoomFormat)
            TickerWheelControl(title: "Range", value: rangeBinding,
                               range: WavViewportMath.minFreqSpanHz...nyquistHz, step: 500,
                               format: Self.rangeFormat)
        }
    }

    private func zoomFormat(_ v: Double) -> String { String(format: "%.2f×", v) }
    private static func rangeFormat(_ v: Double) -> String { String(format: "%.1f kHz", v / 1000) }

    // MARK: Ticker bindings

    /// The Zoom pill — 0.1 (least zoomed) ... 1.0 (most zoomed in). Written
    /// straight to `viewport` on every settled tick, no separate live/
    /// debounce layer needed here: WavSpectrogramView already debounces the
    /// expensive part of a viewport change (the detail-tile re-render, see
    /// `scheduleDetailRenderDebounced`) independent of who's writing
    /// `viewport`, and the cheap part (the overview crop) is fine to update
    /// at full gesture rate — same reasoning removed the old separate
    /// live-value split this control's predecessor (`Slider`) didn't need
    /// either, once that debounce existed.
    private var zoomBinding: Binding<Double> {
        Binding(
            get: { overview.map { WavViewportMath.zoomFraction(forSampleSpan: viewport.sampleSpan, totalSamples: $0.totalSamples) } ?? 0.5 },
            set: { newValue in
                guard let overview else { return }
                let resolved = WavViewportMath.viewportForTimeZoom(
                    committed: viewport, zoomFraction: newValue, totalSamples: overview.totalSamples)
                WavPlayerDebugLog.log("WavPlayer", "zoomBinding: fraction=\(newValue) -> span=\(resolved.sampleSpan)")
                viewport = resolved
            })
    }

    /// The Range pill — the frequency axis's WIDTH (in Hz), independent of
    /// its POSITION (panned by dragging on the spectrogram itself — see
    /// WavSpectrogramView's vertical-pan handling). Zooms around whichever
    /// center the pan already left `viewport` at
    /// (`WavViewportMath.viewportForFreqZoom`), not the file's fixed
    /// midpoint — narrowing the range after panning up to a high-frequency
    /// call keeps that call in view instead of snapping back to center.
    private var rangeBinding: Binding<Double> {
        Binding(
            get: { viewport.freqSpan },
            set: { newValue in
                guard let overview else { return }
                let resolved = WavViewportMath.viewportForFreqZoom(
                    committed: viewport, spanHz: newValue, nyquistHz: overview.maxFreqHz)
                WavPlayerDebugLog.log("WavPlayer", "rangeBinding: spanHz=\(newValue) -> \(Int(resolved.minFreqHz))-\(Int(resolved.maxFreqHz))Hz")
                viewport = resolved
            })
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
        let pal = palette, floor = Float(noiseFloor), sr = overview?.sampleRate ?? 0
        WavPlayerDebugLog.log("WavPlayer", "recolorOverviewIfPossible: recoloring \(raw.nCols) cols at floor=\(floor) palette=\(pal), generation=\(myGeneration)")
        Task.detached(priority: .userInitiated) {
            let tile = WavPlayerDebugLog.time("WavPlayer", "overview colorize \(raw.nCols) cols") {
                WavSpectrogramEngine.colorize(raw, sampleRate: sr, minFreqHz: 0, maxFreqHz: sr / 2,
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
            }
        }
    }

    // MARK: Load

    private func load() {
        let url = store.wavURL(for: recording)
        overviewError = nil
        overview = nil
        engine.load(url: url)
        rteSettings.apply(to: engine.timeExpansion)
        applyBand()

        let pal = palette, floor = Float(noiseFloor)
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
            }
        }
    }

    // MARK: Navigation + analysis

    private func recenter(sample: Int) {
        guard let overview else { return }
        let span = viewport.sampleSpan
        var start = sample - span / 2
        var end = start + span
        if start < 0 { end -= start; start = 0 }
        if end > overview.totalSamples { start -= (end - overview.totalSamples); end = overview.totalSamples }
        WavPlayerDebugLog.log("WavPlayer", "recenter: sample=\(sample) span=\(span) -> \(max(0, start))-\(min(overview.totalSamples, end))")
        viewport = WavViewport(startSample: max(0, start), endSample: min(overview.totalSamples, end),
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
                } else {
                    WavPlayerDebugLog.log("WavPlayer", "CallAnalysis returned nil")
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
