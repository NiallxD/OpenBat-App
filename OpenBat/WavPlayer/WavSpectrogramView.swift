//
//  WavSpectrogramView.swift
//  OpenBat
//
//  The whole-file, static, two-axis zoomable spectrogram — the core of the
//  rebuilt WAV player. Replaces PlaybackPlayerView's live-scrolling Metal
//  SpectrogramView (fed in real time from PlaybackEngine) with a fully
//  navigable, tile-rendered view of the WHOLE recording (see
//  WavSpectrogramEngine/WavViewport doc comments for the two-tier
//  overview+detail rendering strategy and the viewport/gesture model).
//
//  Displayed content, in priority order:
//    1. A `DetailTile` matching the current COMMITTED viewport exactly, if one
//       has finished rendering.
//    2. A cropped/scaled slice of the always-resident overview image — shown
//       IMMEDIATELY on every viewport change (never blank), while a detail
//       tile (if the zoom level warrants one — see `needsDetailTile`) renders
//       in the background and swaps in once ready.
//
//  Interaction model: ZOOM is NOT a gesture here — the time axis via
//  WavPlayerView's "Zoom" ticker wheel, the frequency axis's WIDTH via its
//  "Range" ticker wheel. PAN (position) IS a gesture on this view, though:
//  a two-axis drag — horizontal shifts time (with momentum/coast), vertical
//  shifts the frequency window (no momentum on that axis) — or a
//  drag-to-select box when `isSelecting`, plus tap-to-seek in pan mode. Both
//  ticker wheels and the pan gesture write `viewport` directly and
//  immediately (see `commitPan`/WavPlayerView's ticker bindings) rather than
//  through a separate live-preview parameter — WavSpectrogramView's own
//  `scheduleDetailRenderDebounced` already protects the one genuinely
//  expensive consumer of a `viewport` change, so nothing upstream needs its
//  own debounce just to avoid a redundant render. An earlier version drove
//  zoom through a pinch gesture (`MagnifyGesture`) composed simultaneously
//  with the pan drag, and frequency WIDTH through a two-thumb trim slider —
//  both pulled in favour of the explicit ticker wheels (deterministic, no
//  gesture-recognition ambiguity) — see WavViewport.swift's doc comment.
//

import SwiftUI

struct WavSpectrogramView: View {
    let wavURL: URL
    let sampleRate: Double
    /// `overview.image`/`overview.rawTile` are kept current by WavPlayerView
    /// (mutated in place on a noise-floor/palette change — see its
    /// `recolorOverviewIfPossible`), so this view and `WavMinimapView`
    /// automatically show the same up-to-date recolor with nothing extra to
    /// pass through here.
    let overview: WavSpectrogramEngine.Overview
    @Binding var viewport: WavViewport
    @Binding var selection: ClosedRange<Int>?
    let isSelecting: Bool
    let palette: Palette
    let noiseFloor: Float
    /// Display-only Y-axis remap (see `LogFrequencyWarp`) — independent of
    /// the underlying data, which stays linear-frequency throughout.
    let logFrequency: Bool
    let onSeek: (Double) -> Void

    // Live pan state — transient, reset to identity every time a new
    // viewport commits (see `commitPan`). `DragGesture.translation` is
    // cumulative from the physical touch-down, not resettable mid-touch, so
    // a commit firing while the finger is still down (the debounced case)
    // rebases against `dragTranslationAtLastCommit`/`lastDragTranslationX` —
    // same reasoning PulseZoomView's gesture handlers document.
    @State private var gestureOffsetX: CGFloat = 0
    @State private var gestureBaseOffsetX: CGFloat = 0
    @State private var dragTranslationXAtLastCommit: CGFloat = 0
    @State private var lastDragTranslationX: CGFloat = 0
    @State private var lastDragTranslationY: CGFloat = 0
    @State private var momentum = ScrollMomentum()
    /// Self-tracked horizontal velocity (points/sec), fed by `onChanged` and
    /// consumed at `onEnded` to seed the momentum coast — see the property's
    /// use at `onEnded` for why this replaced `DragGesture.predictedEndTranslation`.
    @State private var dragVelocityX: CGFloat = 0
    @State private var lastVelocitySampleTime: Date?
    @State private var lastVelocitySampleX: CGFloat = 0
    /// True from the first `onChanged` of a physical touch to its `onEnded` —
    /// lets `onChanged` detect "this is a BRAND NEW touch" and reset the
    /// rebase baseline, rather than rebasing against a stale value left over
    /// from a previous, separate touch (see the `onChanged` doc comment).
    @State private var isDragging = false
    /// True while `gestureOffsetX` is meaningful to display (actively being
    /// dragged, or coasting) — false the instant `commitPan()` bakes it into
    /// `viewport`. The displayed offset (`spectrogramImageLayer`) uses this
    /// rather than `gestureOffsetX` directly: `gestureOffsetX` is reset to 0
    /// inside `commitPan()` too, but that reset and this flag are set
    /// together in the SAME place, so even if some future change to the
    /// commit/coast bookkeeping left `gestureOffsetX` transiently stale,
    /// the image can never render offset (partially clipped off-screen,
    /// showing black past its edge) once a gesture is no longer live —
    /// belt-and-suspenders on top of `gestureOffsetX` itself always being
    /// reset at every commit.
    @State private var isInteracting = false

    @State private var detailTile: WavSpectrogramEngine.DetailTile?
    /// The raw (un-colorized) STFT grid behind `detailTile`, kept around so a
    /// noise-floor/palette-only change (`forceRender`) can recolor it
    /// directly instead of re-reading PCM and re-running the FFT just to
    /// change a tone-mapping parameter that step doesn't even depend on —
    /// see `scheduleDetailRender`.
    @State private var cachedRawTile: WavSpectrogramEngine.RawTile?
    @State private var renderGeneration = 0
    @State private var commitTask: Task<Void, Never>?
    /// Debounces `scheduleDetailRender` itself for ANY `viewport` change,
    /// regardless of source — confirmed necessary on-device: the time-zoom
    /// slider (a plain continuous `Slider`, unlike the frequency-trim
    /// slider's own already-debounced live-value split) writes `viewport`
    /// directly on every tick with no debounce upstream, so a single drag
    /// fired `scheduleDetailRender` — a real `WavPCMReader` read +
    /// `STFTGrid.streamPooledGrid` FFT — well over 100 times, almost all
    /// immediately superseded before even finishing. `renderGeneration`
    /// already discards a STALE RESULT once computed, but does nothing to
    /// stop the wasted computation from starting in the first place — this
    /// is what actually stops that. Safe to debounce unconditionally: the
    /// always-instant overview crop (`rebuildWarpedImage`, called
    /// separately and NOT debounced) keeps the view visually responsive
    /// while this settles.
    @State private var viewportRenderTask: Task<Void, Never>?
    /// Debounces the noise-floor/palette-triggered `forceRender` — without
    /// this, each step of the (0.05-step) noise-floor slider fired its own
    /// `scheduleDetailRender(forceRender: true)` immediately. At the default
    /// whole-file zoom there's no `cachedRawTile` yet, so every one of those
    /// went through the FULL renderRawTile path (a whole-file
    /// `WavPCMReader.readSamples` plus `STFTGrid.streamPooledGrid`) — and
    /// since `renderGeneration` invalidates the previous in-flight render the
    /// moment a new one is scheduled, a continuous drag meant no render ever
    /// won the race before being superseded: the spectrogram looked like it
    /// was ignoring the slider entirely. Coalescing rapid ticks into one
    /// render after they settle (same pattern WavPlayerView's frequency-trim
    /// slider already uses) fixes that without touching the render itself.
    @State private var forceRenderTask: Task<Void, Never>?
    @State private var liveSelection: ClosedRange<Int>?
    /// Log-frequency-remapped copy of whichever source image
    /// (`currentSourceImage()`) is currently displayed — cached, not
    /// recomputed per body evaluation (which happens on every drag frame via
    /// `gestureOffsetX`), same reasoning as `PulseZoomView.warpedImage`.
    /// Rebuilt in `rebuildWarpedImage()` on the few things that actually
    /// change the source (viewport commit, a detail tile arriving, the
    /// toggle itself) — never on an offset-only re-render.
    @State private var warpedDisplayImage: UIImage?

    // Live vertical-pan state — mirrors gestureOffsetX/gestureBaseOffsetX
    // above, minus momentum (a flick-to-coast feel wasn't asked for on this
    // axis, and skipping it keeps the vertical addition much smaller than
    // duplicating the X-axis's full velocity-tracking/momentum apparatus).
    // Panning the frequency axis replaces the old two-thumb frequency-trim
    // slider entirely: the trim slider set an absolute [min,max] window
    // directly, whereas this shifts the CURRENT window (whatever span the
    // range-zoom control set) up/down — `resolvedViewport`'s `freqOffset`
    // parameter already existed for exactly this (previously always passed
    // 0), so this is wiring, not new viewport math.
    @State private var gestureOffsetY: CGFloat = 0
    @State private var gestureBaseOffsetY: CGFloat = 0
    @State private var dragTranslationYAtLastCommit: CGFloat = 0

    private static let liveDebounceSeconds = 0.2
    private static let targetColumns = 1536
    /// Coast distance = `dragVelocityX * coastTimeConstant` — how many
    /// seconds' worth of the release-moment velocity the momentum carries
    /// forward. Tuned for feel, not physically derived — bumped up from an
    /// initial 0.15 (barely perceptible) to give a clearly noticeable glide
    /// on a brisk flick; downstream clamping (`liveSampleRange`/
    /// `resolvedViewport`) already keeps an overshoot at the file's edges
    /// from looking broken, so there's no correctness reason to keep this
    /// conservative.
    private static let coastTimeConstant: Double = 0.4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                spectrogramImageLayer(geoSize: geo.size)

                if isSelecting, let liveSelection {
                    SelectionOverlay(range: liveSelection, viewport: viewport, geoSize: geo.size)
                } else if let selection {
                    SelectionOverlay(range: selection, viewport: viewport, geoSize: geo.size)
                }

                WavAxisOverlay(viewport: viewport, sampleRate: sampleRate, geoSize: geo.size,
                               logFrequency: logFrequency)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(currentGesture(geoSize: geo.size))
        }
        .onAppear {
            scheduleDetailRender(for: viewport)
            rebuildWarpedImage()
        }
        .onChange(of: viewport) { _, newValue in
            // `rebuildWarpedImage` stays immediate — it only re-crops the
            // already-resident overview (cheap), keeping the view visually
            // responsive. `scheduleDetailRenderDebounced` is the expensive
            // part (real PCM read + FFT) and is debounced — see its doc
            // comment for why: confirmed on-device via the generation
            // counter reaching 238 during a single zoom-slider drag, each
            // one a real render spawned and then immediately discarded.
            scheduleDetailRenderDebounced(for: newValue)
            rebuildWarpedImage()
        }
        // `scheduleForceRenderDebounced` — only matters once a detail tile is
        // already showing (zoomed in); its own cheap path
        // (`scheduleDetailRender`'s `cachedRawTile` branch) recolors that
        // tile from PCM already read for the current viewport, not a fresh
        // whole-file read. The zoomed-out (overview) case is handled by
        // WavPlayerView recoloring `overview.image` in place directly — see
        // its own `.onChange(of: overview.image)` below.
        .onChange(of: noiseFloor) { old, new in
            WavPlayerDebugLog.log("WavSpectrogram", "noiseFloor onChange fired: \(old) -> \(new)")
            scheduleForceRenderDebounced()
        }
        .onChange(of: palette) { old, new in
            WavPlayerDebugLog.log("WavSpectrogram", "palette onChange fired: \(old) -> \(new)")
            scheduleForceRenderDebounced()
        }
        .onChange(of: overview.image) { _, _ in
            // WavPlayerView just recolored the overview (noise-floor/palette
            // change, or the initial render just landed) — only matters for
            // display here if we're currently showing the overview crop
            // rather than a detail tile, but `rebuildWarpedImage` is cheap
            // enough (a crop + optional log-warp) that it's simpler to
            // always refresh than to duplicate the "which one is showing"
            // check `currentSourceImage` already does.
            rebuildWarpedImage()
        }
        .onChange(of: logFrequency) { _, new in
            WavPlayerDebugLog.log("WavSpectrogram", "logFrequency onChange fired: \(new)")
            rebuildWarpedImage()
        }
    }


    // MARK: Display layer

    // `.resizable()`/`.interpolation()` are Image-only, so each branch below
    // applies the full modifier chain itself (matching PulseZoomView's
    // pulseZoomContent, which does the same) rather than sharing a wrapper —
    // a `Group` mixing an `Image` branch with a plain `Color` branch can't
    // have `.resizable()` applied to it afterward, since `Group`'s inferred
    // content type isn't `Image`.
    @ViewBuilder
    private func spectrogramImageLayer(geoSize: CGSize) -> some View {
        if let source = currentSourceImage() {
            Image(uiImage: displayedImage(source: source))
                .resizable()
                .interpolation(.high)
                .frame(width: geoSize.width, height: geoSize.height)
                .clipped()
        } else {
            Color.black
                .frame(width: geoSize.width, height: geoSize.height)
        }
    }

    private func tileMatchesViewport(_ tile: WavSpectrogramEngine.DetailTile) -> Bool {
        tile.startSample == viewport.startSample && tile.endSample == viewport.endSample
    }

    /// Whichever image is currently the right one to display, along with the
    /// ACTUAL frequency bounds it covers (a detail tile's own
    /// `minFreqHz/maxFreqHz` may be bin-quantized slightly differently from
    /// the live `viewport`'s exact request; a crop's bounds are exactly
    /// whatever Y-bounds were asked for).
    ///
    /// A pan/coast in progress (`isInteracting`) makes the COMMITTED
    /// `viewport` stale for display purposes, on BOTH axes at once (time via
    /// `liveSampleRange`, frequency via `liveFreqRangeFromPan`) — a detail
    /// tile or a crop only ever has pixel data for the exact range it was
    /// rendered for — showing one anyway (via a CSS-style `.offset()`
    /// transform, or just leaving Y-bounds stale) means the displayed image
    /// silently stops tracking the input the moment it diverges from what
    /// was last committed. Recropping the whole-file overview at whatever
    /// the live bounds currently are sidesteps that entirely: it has no
    /// "edge" to fall off (except the file's own real start/end/0/Nyquist),
    /// so it's always valid to show, at the cost of resolution during the
    /// live interaction itself — expected/matches this view's own stated
    /// design (coarse-but-immediate while live, sharp once settled).
    private func currentSourceImage() -> (image: UIImage, loHz: Double, hiHz: Double)? {
        // A live pan in progress (drag on the spectrogram, both axes
        // together) always recrops the overview live — a detail tile only
        // ever has pixel data for its own fixed, already-committed bounds,
        // so it can't track a live drag.
        if isInteracting {
            let (start, end) = liveSampleRange()
            let (minHz, maxHz) = liveFreqRangeFromPan()
            guard let cropped = croppedOverviewImage(start: start, end: end, minHz: minHz, maxHz: maxHz) else { return nil }
            return (cropped, minHz, maxHz)
        }
        if let tile = detailTile, tileMatchesViewport(tile) {
            return (tile.image, tile.minFreqHz, tile.maxFreqHz)
        }
        if let cropped = croppedOverviewImage(start: viewport.startSample, end: viewport.endSample,
                                              minHz: viewport.minFreqHz, maxHz: viewport.maxFreqHz) {
            return (cropped, viewport.minFreqHz, viewport.maxFreqHz)
        }
        return nil
    }

    /// `viewport` shifted by the live (not-yet-committed) drag/coast offset.
    /// `gestureOffsetX` is already a FRACTION of the view's width (not raw
    /// points); since `viewport.sampleSpan` maps onto exactly that width on
    /// screen, the sample-domain shift is `gestureOffsetX * sampleSpan` —
    /// same relationship `WavViewportMath.resolvedViewport` uses to turn a
    /// gesture offset into a new committed viewport, evaluated live here
    /// instead of only at commit time.
    ///
    /// Clamped to `[0, totalSamples]` WITHOUT changing the span: dragging
    /// past the start (or end) of the file shifts BOTH edges back into
    /// bounds together, same "if start < 0 { end -= start; start = 0 }"
    /// pattern `WavPlayerView.recenter`/`viewportForTimeZoom` already use.
    /// Clamping `start`/`end` independently (each just `min(max(_,0),
    /// total)` on its own) silently SHRINKS the span the instant either
    /// edge goes out of bounds — the cropped sample range narrows while
    /// still being stretched across the full screen width, so whatever's
    /// on screen balloons outward. That's the "dragging past the edge
    /// makes it expand" bug: the fix isn't "clamp the numbers", it's "clamp
    /// the numbers together."
    private func liveSampleRange() -> (start: Int, end: Int) {
        let shift = Double(gestureOffsetX) * Double(viewport.sampleSpan)
        var start = Double(viewport.startSample) - shift
        var end = Double(viewport.endSample) - shift
        let total = Double(overview.totalSamples)
        if start < 0 { end -= start; start = 0 }
        if end > total { start -= (end - total); end = total }
        start = max(0, start)
        end = min(total, end)
        return (Int(start.rounded()), Int(end.rounded()))
    }

    /// `viewport`'s frequency window shifted by the live (not-yet-committed)
    /// vertical drag offset — the frequency-axis analog of `liveSampleRange`
    /// above, same "clamp both edges together" reasoning (shrinking the span
    /// independently at an edge is the same balloon-outward bug on this axis
    /// too). `gestureOffsetY` is a fraction of the view's HEIGHT; since
    /// `viewport.freqSpan` maps onto exactly that height on screen, the
    /// Hz-domain shift is `gestureOffsetY * freqSpan` — mirrors how
    /// `gestureOffsetX * sampleSpan` gives the time-domain shift.
    /// Sign convention: dragging DOWN (positive translation.height, see
    /// `panGesture`) shifts the window UP in frequency — "content follows
    /// finger" the same way horizontal pan does (drag right reveals earlier
    /// time content sliding in from the left; drag down reveals higher-
    /// frequency content sliding in from the top, since top=high-frequency
    /// throughout this view).
    private func liveFreqRangeFromPan() -> (min: Double, max: Double) {
        let range = viewport.freqSpan
        let shift = Double(gestureOffsetY) * range
        var newMin = viewport.minFreqHz + shift
        var newMax = viewport.maxFreqHz + shift
        let nyquist = sampleRate / 2
        if newMin < 0 { newMax -= newMin; newMin = 0 }
        if newMax > nyquist { newMin -= (newMax - nyquist); newMax = nyquist }
        newMin = max(0, newMin)
        newMax = min(nyquist, newMax)
        return (newMin, newMax)
    }

    /// True whenever the source image is changing every frame (a live pan/
    /// coast) rather than being settled — see `displayedImage`, which uses
    /// this to decide whether the cached `warpedDisplayImage` is even valid
    /// to reuse.
    private var isLivePreviewing: Bool { isInteracting }

    /// The image actually handed to `Image(uiImage:)` — applies the
    /// log-frequency warp on top of whatever `currentSourceImage()` picked.
    /// At rest, reuses the cached `warpedDisplayImage` (rebuilt only on
    /// real changes — see its doc comment). While live-previewing, the
    /// source image itself changes every frame (a fresh live crop — see
    /// `currentSourceImage`), so there's nothing valid to cache; warping
    /// inline here is the only option, accepted because it only costs
    /// anything for the (live-previewing AND log-mode-on) combination — the
    /// common linear case skips it entirely, same as before.
    private func displayedImage(source: (image: UIImage, loHz: Double, hiHz: Double)) -> UIImage {
        guard logFrequency else { return source.image }
        if isLivePreviewing {
            return LogFrequencyWarp.warp(source.image, loHz: source.loHz, hiHz: source.hiHz) ?? source.image
        }
        return warpedDisplayImage ?? source.image
    }

    /// Rebuilds `warpedDisplayImage` from whatever `currentSourceImage()`
    /// currently returns — called on viewport commits, a detail tile
    /// arriving, and the toggle itself, never on a live-preview frame
    /// (see the property's doc comment).
    private func rebuildWarpedImage() {
        guard logFrequency, let source = currentSourceImage() else {
            warpedDisplayImage = nil
            return
        }
        warpedDisplayImage = LogFrequencyWarp.warp(source.image, loHz: source.loHz, hiHz: source.hiHz)
    }

    /// Cheap, always-available fallback: crops the whole-file overview image
    /// to `[start, end)` (in samples) and `[minHz, maxHz]` — coarser than a
    /// detail tile once zoomed in, but instant and never blank. Takes
    /// explicit bounds rather than always reading `viewport` directly so
    /// `currentSourceImage` can crop at LIVE (not-yet-committed) positions
    /// during a pan or a frequency-trim drag, not just the last committed
    /// one — see its doc comment.
    private func croppedOverviewImage(start: Int, end: Int, minHz: Double, maxHz: Double) -> UIImage? {
        guard let cg = overview.image.cgImage, overview.totalSamples > 0 else { return nil }
        let width = cg.width, height = cg.height
        let leftFrac = Double(start) / Double(overview.totalSamples)
        let rightFrac = Double(end) / Double(overview.totalSamples)
        let x0 = max(0, min(width - 1, Int((leftFrac * Double(width)).rounded())))
        let x1 = max(x0 + 1, min(width, Int((rightFrac * Double(width)).rounded())))

        let nyquist = overview.maxFreqHz
        let topFrac = 1 - maxHz / max(nyquist, 1)
        let bottomFrac = 1 - minHz / max(nyquist, 1)
        let y0 = max(0, min(height - 1, Int((topFrac * Double(height)).rounded())))
        let y1 = max(y0 + 1, min(height, Int((bottomFrac * Double(height)).rounded())))

        guard let cropped = cg.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        else { return nil }
        return UIImage(cgImage: cropped)
    }

    // MARK: Viewport commit + detail-tile rendering

    private static let forceRenderDebounceSeconds = 0.12

    private func scheduleForceRenderDebounced() {
        forceRenderTask?.cancel()
        forceRenderTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.forceRenderDebounceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { scheduleDetailRender(for: viewport, forceRender: true) }
        }
    }

    private static let viewportRenderDebounceSeconds = 0.15

    private func scheduleDetailRenderDebounced(for target: WavViewport) {
        viewportRenderTask?.cancel()
        viewportRenderTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.viewportRenderDebounceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { scheduleDetailRender(for: target) }
        }
    }

    private func scheduleGestureCommit(after delay: Double) {
        commitTask?.cancel()
        commitTask = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await MainActor.run { commitPan() }
        }
    }

    @MainActor
    private func commitPan() {
        let resolved = WavViewportMath.resolvedViewport(
            committed: viewport,
            timeScale: 1, timeOffset: Double(gestureOffsetX),
            freqScale: 1, freqOffset: Double(gestureOffsetY),
            totalSamples: overview.totalSamples, nyquistHz: sampleRate / 2)
        gestureOffsetX = 0; gestureBaseOffsetX = 0
        gestureOffsetY = 0; gestureBaseOffsetY = 0
        isInteracting = false
        dragTranslationXAtLastCommit = lastDragTranslationX
        dragTranslationYAtLastCommit = lastDragTranslationY
        WavPlayerDebugLog.log("WavSpectrogram", "commitPan: \(viewport.startSample)-\(viewport.endSample)/\(Int(viewport.minFreqHz))-\(Int(viewport.maxFreqHz))Hz -> \(resolved.startSample)-\(resolved.endSample)/\(Int(resolved.minFreqHz))-\(Int(resolved.maxFreqHz))Hz")
        viewport = resolved   // triggers .onChange -> scheduleDetailRender
    }

    /// Single place responsible for detail-tile fetching, reacting to ANY
    /// viewport change regardless of source (pan commit, zoom/frequency
    /// slider, minimap recenter) — kept separate from `commitPan` so those
    /// other callers don't need to know anything about rendering.
    ///
    /// `forceRender` (fired by a noise-floor/palette change — see the
    /// `.onChange` handlers above) ONLY matters when a detail tile is
    /// already showing: it takes the cheap `cachedRawTile` recolor branch
    /// below. It deliberately does NOT bypass `needsDetailTile`'s zoom
    /// check the way an earlier version of this function did — that
    /// version forced a FULL render (a fresh `WavPCMReader.readSamples` +
    /// FFT over the whole committed viewport) on every tick even when
    /// zoomed out to the whole file, which meant reading the entire
    /// recording into memory on every noise-floor tick. That's now handled
    /// for free by `recolorOverviewIfPossible` recoloring the cached
    /// whole-file grid instead — nothing here needs to re-derive a detail
    /// tile just to reflect a floor/palette change when there isn't one to
    /// begin with.
    private func scheduleDetailRender(for target: WavViewport, forceRender: Bool = false) {
        renderGeneration += 1
        let myGeneration = renderGeneration

        // Cheap path: `forceRender` fired for a noise-floor/palette change,
        // not a viewport change, and we already have the raw STFT grid for
        // this exact time range — recolor it directly instead of re-reading
        // PCM and re-running the FFT (the expensive part) just to change a
        // parameter that step doesn't even feed into. Skipping this used to
        // mean every tick of the noise-floor slider queued a full re-render,
        // so the LAST tick's result sat behind a pile of redundant ones
        // still computing — "takes an age to apply". Deliberately doesn't
        // clear `detailTile` first: recoloring is fast enough that doing so
        // would just flash the (differently-graded) overview crop for one
        // frame before the recolored tile replaced it.
        if forceRender, let raw = cachedRawTile,
           raw.startSample == target.startSample, raw.endSample == target.endSample {
            WavPlayerDebugLog.log("WavSpectrogram", "scheduleDetailRender: cheap recolor path, generation=\(myGeneration)")
            let sr = sampleRate, pal = palette, floor = noiseFloor
            let minHz = target.minFreqHz, maxHz = target.maxFreqHz
            Task.detached(priority: .userInitiated) {
                let tile = WavPlayerDebugLog.time("WavSpectrogram", "detail tile recolor (cached raw)") {
                    WavSpectrogramEngine.colorize(raw, sampleRate: sr, minFreqHz: minHz, maxFreqHz: maxHz,
                                                  palette: pal, noiseFloor: floor)
                }
                await MainActor.run {
                    guard myGeneration == self.renderGeneration else {
                        WavPlayerDebugLog.log("WavSpectrogram", "cheap recolor SUPERSEDED (generation \(myGeneration) != \(self.renderGeneration))")
                        return
                    }
                    self.detailTile = tile
                    self.rebuildWarpedImage()
                }
            }
            return
        }

        detailTile = nil   // fall back to the overview crop immediately
        // No `forceRender ||` bypass here — a floor/palette change with no
        // detail tile in play (the cheap branch above already handles the
        // case where one exists) means we're showing the overview crop,
        // which `recolorOverviewIfPossible` already keeps current. Nothing
        // to gain from deriving a detail tile just because the floor moved.
        let needsDetail = Self.needsDetailTile(
            viewport: target, overviewTotalSamples: overview.totalSamples,
            overviewWidth: Int(overview.image.size.width),
            overviewHeight: Int(overview.image.size.height),
            nyquistHz: sampleRate / 2, targetColumns: Self.targetColumns)
        WavPlayerDebugLog.log("WavSpectrogram", "scheduleDetailRender: span=\(target.sampleSpan) freqSpan=\(target.freqSpan) overviewSize=\(Int(overview.image.size.width))x\(Int(overview.image.size.height)) needsDetailTile=\(needsDetail), generation=\(myGeneration)")
        guard needsDetail else { return }

        let url = wavURL, sr = sampleRate, pal = palette, floor = noiseFloor, cols = Self.targetColumns
        Task.detached(priority: .userInitiated) {
            guard let raw = WavPlayerDebugLog.time("WavSpectrogram", "renderRawTile span \(target.startSample)-\(target.endSample)", {
                WavSpectrogramEngine.renderRawTile(
                    wavURL: url, startSample: target.startSample, endSample: target.endSample, targetColumns: cols)
            })
            else {
                WavPlayerDebugLog.log("WavSpectrogram", "renderRawTile FAILED for span \(target.startSample)-\(target.endSample)")
                return
            }
            WavPlayerDebugLog.log("WavSpectrogram", "renderRawTile OK: nCols=\(raw.nCols) for span \(target.startSample)-\(target.endSample)")
            let tile = WavPlayerDebugLog.time("WavSpectrogram", "detail tile colorize") {
                WavSpectrogramEngine.colorize(raw, sampleRate: sr, minFreqHz: target.minFreqHz,
                                              maxFreqHz: target.maxFreqHz, palette: pal, noiseFloor: floor)
            }
            await MainActor.run {
                guard myGeneration == self.renderGeneration else {
                    WavPlayerDebugLog.log("WavSpectrogram", "detail tile SUPERSEDED (generation \(myGeneration) != \(self.renderGeneration))")
                    return
                }
                WavPlayerDebugLog.log("WavSpectrogram", "detail tile APPLIED, image=\(tile?.image.size ?? .zero)")
                self.cachedRawTile = raw
                self.detailTile = tile
                self.rebuildWarpedImage()
            }
        }
    }

    /// Whether the overview's own (pooled, whole-file) column/row density would
    /// already look blocky for `viewport`'s time span OR frequency span,
    /// warranting a fresh native-resolution detail-tile render instead of just
    /// cropping+scaling the overview image. Checking only the time axis missed
    /// a zoom that narrows mostly the FREQUENCY axis (e.g. the Y-axis
    /// frequency-trim slider narrowed to a narrow band at a near-full time
    /// span) — at the 500 Hz minimum frequency span that's ~3 rows of the
    /// overview's 1024-row image stretched to fill the whole view,
    /// permanently, since `overviewColumnsForSpan` alone stayed above
    /// threshold.
    private static func needsDetailTile(viewport: WavViewport, overviewTotalSamples: Int,
                                        overviewWidth: Int, overviewHeight: Int, nyquistHz: Double,
                                        targetColumns: Int) -> Bool {
        guard viewport.sampleSpan > 0, overviewTotalSamples > 0 else { return false }
        let timeFrac = Double(viewport.sampleSpan) / Double(overviewTotalSamples)
        let overviewColumnsForSpan = Double(overviewWidth) * timeFrac
        if overviewColumnsForSpan < Double(targetColumns) * 0.8 { return true }

        guard nyquistHz > 0, overviewHeight > 0 else { return false }
        let freqFrac = viewport.freqSpan / nyquistHz
        let overviewRowsForSpan = Double(overviewHeight) * freqFrac
        // A detail tile crops to STFTGrid.binCount (1024) bins across whatever
        // frequency window it renders — used here as the frequency axis's
        // equivalent of `targetColumns`, same 0.8-of-target threshold.
        return overviewRowsForSpan < Double(STFTGrid.binCount) * 0.8
    }

    // MARK: Gestures

    private func committedSampleAt(frac: Double) -> Int {
        viewport.startSample + Int((frac * Double(viewport.sampleSpan)).rounded())
    }

    private func currentGesture(geoSize: CGSize) -> AnyGesture<Void> {
        isSelecting
            ? AnyGesture(selectGesture(geoSize: geoSize).map { _ in () })
            : AnyGesture(panGesture(geoSize: geoSize).map { _ in () })
    }

    /// Below this much total movement (either axis), `onEnded` treats the
    /// touch as a tap (seek, or clear-selection in `selectGesture`) rather
    /// than a pan/select release.
    private static let tapMovementThreshold: CGFloat = 4

    /// A single `DragGesture(minimumDistance: 0)` doing double duty as both
    /// pan AND tap-to-seek, rather than the previous `SimultaneousGesture`
    /// composing a `DragGesture` with a separate `SpatialTapGesture`. That
    /// composition was the actual cause of the coast/momentum "stops dead"
    /// bug diagnosed on-device: with two recognizers arbitrating the SAME
    /// touch, the `DragGesture` itself would spuriously re-fire
    /// `onEnded`/`onChanged` mid-swipe — not just corrupt
    /// `predictedEndTranslation` as originally suspected (see the
    /// now-removed comment this replaced) — so a real flick got fragmented
    /// into several sub-drags, each one's `onEnded` cancelling the previous
    /// one's just-started momentum coast before it could show. `minimumDistance:
    /// 0` here (was 2) is required for this single gesture to still recognize
    /// a near-zero-movement tap at all — see `onEnded`'s `isTap` check.
    private func panGesture(geoSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard geoSize.width > 0 else { return }
                // `value.translation` is cumulative from THIS touch's own
                // touch-down and resets to ~0 whenever a new physical touch
                // begins — but `dragTranslationXAtLastCommit` doesn't, unless
                // we reset it here. Without this guard, starting a new drag
                // right after a previous one rebases against the PREVIOUS
                // touch's leftover translation, producing a sudden jump equal
                // to that touch's total distance before any real movement —
                // "jumps back to where it was". Same fix SpectrogramView's
                // own dragGesture already applies via its `isScrolling` guard.
                if !isDragging {
                    WavPlayerDebugLog.log("WavSpectrogram", "panGesture: new touch begins")
                    isDragging = true
                    momentum.cancel()
                    commitTask?.cancel()
                    // Bank any still-coasting momentum position instead of
                    // dropping it — a no-op when gestureOffsetX is already 0
                    // (the common, non-coasting case), since `commitPan()`
                    // assigning an unchanged `viewport` doesn't fire
                    // `.onChange`.
                    commitPan()
                    dragTranslationXAtLastCommit = 0
                    dragTranslationYAtLastCommit = 0
                    gestureBaseOffsetX = 0
                    gestureBaseOffsetY = 0
                    lastVelocitySampleTime = nil
                    dragVelocityX = 0
                }
                lastDragTranslationX = value.translation.width
                lastDragTranslationY = value.translation.height
                // Delta since the last commit (identity if none happened yet
                // this touch) — see the state doc comment above.
                let dxSinceCommit = value.translation.width - dragTranslationXAtLastCommit
                gestureOffsetX = gestureBaseOffsetX + dxSinceCommit / geoSize.width
                if geoSize.height > 0 {
                    let dySinceCommit = value.translation.height - dragTranslationYAtLastCommit
                    gestureOffsetY = gestureBaseOffsetY + dySinceCommit / geoSize.height
                }
                isInteracting = true
                // Track our own velocity from consecutive translation
                // samples, exponentially smoothed — used at `onEnded` to
                // seed the momentum coast INSTEAD of
                // `DragGesture.predictedEndTranslation`, which wasn't
                // reliably producing a meaningful residual (this is a plain
                // distance/time measurement we fully control instead of an
                // opaque system prediction).
                let now = Date()
                if let lastTime = lastVelocitySampleTime {
                    let dt = now.timeIntervalSince(lastTime)
                    if dt > 0.001 {
                        let instant = Double(value.translation.width - lastVelocitySampleX) / dt
                        // Lighter smoothing (was 0.7/0.3) — heavier smoothing
                        // averaged in enough older, slower samples that a
                        // real flick's true release-moment speed got diluted
                        // by the time onEnded read it, understating the
                        // coast. Still enough to reject single-frame noise,
                        // not enough to meaningfully lag a real flick.
                        let smoothed = Double(dragVelocityX) * 0.4 + instant * 0.6
                        dragVelocityX = CGFloat(min(max(smoothed, -4000), 4000))
                    }
                }
                lastVelocitySampleTime = now
                lastVelocitySampleX = value.translation.width
                scheduleGestureCommit(after: Self.liveDebounceSeconds)
            }
            .onEnded { value in
                isDragging = false
                lastDragTranslationX = value.translation.width
                lastDragTranslationY = value.translation.height
                // No Y-momentum (see the state doc comment) — bank it here
                // unconditionally so the next drag rebases from wherever
                // this one left off, same as X does at every one of its own
                // exit points below.
                gestureBaseOffsetY = gestureOffsetY
                guard geoSize.width > 0 else {
                    gestureBaseOffsetX = gestureOffsetX
                    scheduleGestureCommit(after: 0)
                    return
                }
                let isTap = abs(value.translation.width) < Self.tapMovementThreshold
                         && abs(value.translation.height) < Self.tapMovementThreshold
                if isTap {
                    WavPlayerDebugLog.log("WavSpectrogram", "panGesture: tap-to-seek at frac=\(value.location.x / geoSize.width)")
                    momentum.cancel()
                    gestureBaseOffsetX = gestureOffsetX
                    scheduleGestureCommit(after: 0)
                    let frac = Double(value.location.x / geoSize.width)
                    onSeek(Double(committedSampleAt(frac: frac)) / sampleRate)
                    return
                }
                // Let the release coast the rest of the way, instead of
                // stopping dead — same rationale as SpectrogramView's
                // drag-to-scroll. Coast distance = velocity × a fixed time
                // constant (a simple "how far would this speed carry it"
                // model). Vertical (frequency) pan has no equivalent coast —
                // it settles exactly where released.
                let residual = Double(dragVelocityX) * Self.coastTimeConstant / Double(geoSize.width)
                WavPlayerDebugLog.log("WavSpectrogram", "panGesture: released, velocity=\(dragVelocityX)pt/s residual=\(residual)")
                let base = gestureOffsetX
                momentum.start(residual: residual) { delta in
                    isInteracting = true
                    gestureOffsetX = base + delta
                    scheduleGestureCommit(after: Self.liveDebounceSeconds)
                } completion: {
                    WavPlayerDebugLog.log("WavSpectrogram", "panGesture: momentum coast finished")
                    gestureBaseOffsetX = gestureOffsetX
                    scheduleGestureCommit(after: 0)
                }
            }
    }

    /// Same single-gesture (no `SimultaneousGesture`+`SpatialTapGesture`)
    /// shape as `panGesture`, for the same reason — see its doc comment.
    /// A tap while selecting clears the current selection instead of
    /// seeking — seeking already lives in pan mode's own tap; a
    /// selection-mode tap is for dismissing a measurement, not transport.
    private func selectGesture(geoSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard geoSize.width > 0 else { return }
                let f0 = Double(value.startLocation.x / geoSize.width)
                let f1 = Double(value.location.x / geoSize.width)
                let s0 = committedSampleAt(frac: min(f0, f1))
                let s1 = committedSampleAt(frac: max(f0, f1))
                guard s1 > s0 else { return }
                liveSelection = s0...s1
            }
            .onEnded { value in
                let isTap = abs(value.translation.width) < Self.tapMovementThreshold
                         && abs(value.translation.height) < Self.tapMovementThreshold
                if isTap {
                    WavPlayerDebugLog.log("WavSpectrogram", "selectGesture: tap clears selection")
                    selection = nil
                } else if let liveSelection {
                    WavPlayerDebugLog.log("WavSpectrogram", "selectGesture: committed \(liveSelection.lowerBound)-\(liveSelection.upperBound)")
                    selection = liveSelection
                }
                liveSelection = nil
            }
    }
}

/// Translucent rectangle showing a manual (or just-committed) selection range.
private struct SelectionOverlay: View {
    let range: ClosedRange<Int>
    let viewport: WavViewport
    let geoSize: CGSize

    var body: some View {
        let x0Frac = Double(range.lowerBound - viewport.startSample) / Double(max(viewport.sampleSpan, 1))
        let x1Frac = Double(range.upperBound - viewport.startSample) / Double(max(viewport.sampleSpan, 1))
        let x0 = CGFloat(max(0, min(1, x0Frac))) * geoSize.width
        let x1 = CGFloat(max(0, min(1, x1Frac))) * geoSize.width
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .overlay(Rectangle().stroke(Color.white.opacity(0.6), lineWidth: 1))
            .frame(width: max(2, x1 - x0), height: geoSize.height)
            .position(x: (x0 + x1) / 2, y: geoSize.height / 2)
            .allowsHitTesting(false)
    }
}
