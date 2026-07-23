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
//  Interaction model: ZOOM is both a gesture AND the ticker wheels — a
//  two-finger PER-AXIS pinch (horizontal spread = time, vertical spread =
//  frequency width; see TwoAxisPinchView for why it's a UIKit overlay, not
//  a composed SwiftUI MagnifyGesture) on top of WavPlayerView's "Zoom"/
//  "Range" ticker wheels, which remain as the precise/deterministic
//  controls and as readouts. PAN (position) is a gesture on this view too:
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
    /// Non-nil while hide-silence is on: `overview` is then the COMPRESSED
    /// overview and every sample coordinate in this view (viewport, tiles,
    /// seeks) is a VIRTUAL sample on the compressed timeline — the only
    /// thing this view does differently is route detail renders through
    /// `renderRawTileStitched` (and hand `onSeek` a virtual position, which
    /// WavPlayerView's closure maps back to real time).
    let silenceMap: SilenceMap?
    @Binding var viewport: WavViewport
    @Binding var selection: ClosedRange<Int>?
    /// Measured call landmarks (Hi f / Peak / Fc / Lo f) for the current
    /// selection, in this view's display-sample domain — drawn by
    /// `CallAnnotationOverlay`. Empty when nothing is selected/measured.
    let annotations: [CallAnnotation]
    let isSelecting: Bool
    let palette: Palette
    let noiseFloor: Float
    /// Display-only Y-axis remap (see `LogFrequencyWarp`) — independent of
    /// the underlying data, which stays linear-frequency throughout.
    let logFrequency: Bool
    /// True while playback is scrolling the view (WavPlayerView's follow
    /// loop is writing `viewport` at ~30Hz). Switches viewport-change
    /// rendering from the resetting debounce (which never fires under
    /// continuous change, leaving only the coarse overview crop — the
    /// "very blurry while playing" report) to a throttled scheduler that
    /// fires periodically DURING the scroll, so a medium-res margined tile
    /// stays resident and the scroll rides it sharp instead.
    let isPlaying: Bool
    let onSeek: (Double) -> Void
    /// Debug-only red/green buffer visualization surfaced on the minimap —
    /// see `renderChunkedStep` (writer) and `WavMinimapView` (reader).
    let bufferDebugStatus: BufferDebugStatus

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

    /// True while a background prefetch render (see `maybePrefetchTile`) is
    /// in flight — prevents a fast/long drag from spawning a new margined
    /// render on every single frame while one is already computing; the
    /// throttle (`lastPrefetchTime`/`minPrefetchInterval`) alone isn't
    /// enough since a render can legitimately take longer than the throttle
    /// interval.
    @State private var prefetchInFlight = false
    @State private var lastPrefetchTime: Date?

    @State private var detailTile: WavSpectrogramEngine.DetailTile?
    /// The raw (un-colorized) STFT grid behind `detailTile` — covers a TIME
    /// MARGIN around whatever viewport it was rendered for (see
    /// `scheduleDetailRender`'s doc comment), not just the exact requested
    /// span, and (regardless of margin) always has every one of STFTGrid's
    /// 1024 frequency bins, since the FFT stage never crops bins away —
    /// only `colorize` does, for display. Kept around so ANY of the
    /// following can reuse it instead of re-reading PCM and re-running the
    /// FFT: a noise-floor/palette change, a frequency-only pan (the raw grid
    /// already has every bin), or a time-pan that's still within the
    /// tile's own margin.
    @State private var cachedRawTile: WavSpectrogramEngine.RawTile?
    @State private var renderGeneration = 0
    @State private var commitTask: Task<Void, Never>?
    /// Debounces `scheduleDetailRender` for ANY trigger — a viewport change
    /// (pan settling, either ticker wheel) OR a noise-floor/palette change —
    /// confirmed necessary on-device: e.g. the time-zoom ticker writes
    /// `viewport` directly on every settled tick with no debounce upstream,
    /// so a single drag fired `scheduleDetailRender` well over 100 times,
    /// almost all immediately superseded before even finishing.
    /// `renderGeneration` already discards a STALE RESULT once computed, but
    /// does nothing to stop the wasted computation from starting in the
    /// first place — this is what actually stops that. Safe to debounce
    /// unconditionally: the always-instant overview crop (`rebuildWarpedImage`,
    /// called separately and NOT debounced) keeps the view visually
    /// responsive while this settles.
    @State private var renderDebounceTask: Task<Void, Never>?
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

    // Live two-axis pinch state (see TwoAxisPinchView) — identity (scale 1,
    // offset 0) whenever no pinch is active, so `commitPan`/`liveViewport`
    // can always fold these in unconditionally. The offsets hold the
    // anchor-preserving term `(anchor - 0.5) * (1 - scale)` plus any
    // two-finger centroid drag, in the same screen-fraction space as
    // `gestureOffsetX`/`gestureOffsetY`.
    @State private var pinchScaleX: Double = 1
    @State private var pinchScaleY: Double = 1
    @State private var pinchOffsetX: Double = 0
    @State private var pinchOffsetY: Double = 0
    /// True from the pinch recognizer's .began to its .ended — the pan
    /// DragGesture (which tracks ONE of the same two fingers) checks this to
    /// stand down while the pinch owns the touch (see panGesture's guards).
    @State private var isPinching = false
    /// Set at pinch END, cleared by the drag's FIRST event afterwards. The
    /// in-pinch rebase in `panGesture.onChanged` only runs when drag events
    /// actually arrive during the pinch — on a FAST pinch SwiftUI often
    /// delivers none, then flushes one late event AFTER the pinch commits,
    /// carrying the tracked finger's whole cumulative movement (the entire
    /// pinch spread). Without this flag that event was applied as a pan
    /// (`dxSinceCommit` against a stale baseline) — the "fast pinch jumps
    /// back/away on release" bug — or, via `onEnded`, seeded a bogus
    /// coast/tap from pinch-contaminated translation and velocity.
    @State private var postPinchRebasePending = false

    /// Which axis THIS touch has committed to, decided once total movement
    /// clears `axisLockThreshold` — nil beforehand (movement too small to
    /// tell intent yet). A real touch is never perfectly straight; without
    /// this, ANY drag — including one the user experiences as "just
    /// scrolling through time" — always had some incidental vertical
    /// component, which `commitPan` applied to the frequency window every
    /// time (see `resolvedViewport`'s `freqOffset`). That's what was behind
    /// "why does panning change the range": a horizontal drag nudging the
    /// frequency window by a few Hz on every single pan, invisible most of
    /// the time but occasionally enough (combined with the independent-
    /// clamp bug `resolvedViewport` used to have at the 0/Nyquist edges) to
    /// visibly shift the Range value — and enough, even without hitting an
    /// edge, to leave the cached detail tile's `minFreqHz/maxFreqHz`
    /// slightly off from the newly committed viewport, so the very next
    /// touch's live crop (`tileCovers`) immediately missed and fell back to
    /// the overview. Locking to whichever axis clearly dominates once the
    /// touch is unambiguous (matching `UIScrollView`'s own directional-lock
    /// behavior) means a horizontal pan now writes ZERO frequency offset,
    /// not just a small one.
    @State private var lockedAxis: PanAxis? = nil
    private enum PanAxis { case horizontal, vertical }
    private static let axisLockThreshold: CGFloat = 8

    private static let liveDebounceSeconds = 0.2
    private static let targetColumns = 1536
    /// Hard ceiling on a rendered tile's column count, margin included. The
    /// margin logic below sizes the buffer in SECONDS of audio
    /// (`minBufferSeconds`), but every step renders at `targetColumns`-per-
    /// viewport-span density — so at deep zoom the two multiply into
    /// unbounded tiles: a ~50ms viewport with a 3s-per-side buffer wanted
    /// ~190k columns (~10k after the nFrames clamp), and each one of those
    /// columns costs FFT work, a ~4KB grid row, and colorize time.
    /// Measured on-device: the staged chain ran 1536->2895->...->9688-wide
    /// steps, each fully re-rendered, ~7s of background churn per settle.
    /// Capping total columns instead caps the margin at deep zoom to
    /// whatever this many columns can cover (4x the viewport span at the
    /// 4x-targetColumns value below) — less runway than 3s, but every tile
    /// stays cheap enough (~150-400ms raw render) that the prefetch
    /// re-centers fast enough to keep up with a drag anyway, which the
    /// multi-second unbounded tiles never could.
    private static let maxTileColumns = targetColumns * 4
    /// Coast distance = `dragVelocityX * coastTimeConstant` — how many
    /// seconds' worth of the release-moment velocity the momentum carries
    /// forward. Tuned for feel, not physically derived — bumped up from an
    /// initial 0.15 (barely perceptible) to give a clearly noticeable glide
    /// on a brisk flick; downstream clamping (`liveSampleRange`/
    /// `resolvedViewport`) already keeps an overshoot at the file's edges
    /// from looking broken, so there's no correctness reason to keep this
    /// conservative.
    private static let coastTimeConstant: Double = 0.4

    /// How much wider (in samples) a rendered detail tile is than the
    /// viewport it was rendered for — e.g. 3.0 renders 3x the visible span,
    /// centered on the same point. This is the actual "buffer" a pan can
    /// move through before a brand new render is needed: same idea as the
    /// live Metal spectrogram's `ringTextureWidth = maxVisibleColumns + 512
    /// guard`, sized here as a multiple of the viewport rather than a fixed
    /// pixel margin since detail-tile viewports span many different zoom
    /// levels.
    private static let tileMarginFactor: Double = 3.0
    /// Absolute floor on the buffer beyond the visible frame, regardless of
    /// zoom — `tileMarginFactor` alone ties the margin to the CURRENT
    /// viewport's own span, which collapses to almost nothing at the zoom
    /// levels this player is actually used at: a typical echolocation call
    /// view (tens to a couple hundred ms wide) only got tens to a couple
    /// hundred ms of real buffered audio beyond it (`tileMarginFactor - 1`
    /// = 2x that span) — an ordinary screen drag covers that much real time
    /// in well under a second, so the margin was exhausted almost the
    /// instant a drag started, falling back to the coarse overview crop
    /// immediately. This floor is expressed in real SECONDS of audio, not a
    /// multiple of the viewport, so deep zoom gets a genuinely useful
    /// amount of runway too — whichever of the two (proportional or this
    /// floor) is larger wins, so a WIDE zoom (where 3x the span already
    /// exceeds 3 seconds) is unaffected. Whichever wins is then capped by
    /// `maxTileColumns` (see its doc comment) — at deep zoom this floor
    /// would otherwise multiply with per-span column density into
    /// unboundedly wide tiles.
    private static let minBufferSeconds: Double = 3.0
    /// Size of one staged buffer-build step (see `renderChunkedStep`) — the
    /// visible frame renders first (fastest, since it carries no margin
    /// yet), then the tile grows by this much at a time toward the full
    /// margin computed in `scheduleDetailRender`, instead of gating on one
    /// single multi-second render before anything sharper than the overview
    /// shows at all.
    private static let chunkSeconds: Double = 1.0
    /// Once the NEARER edge of the live (uncommitted) pan position gets
    /// this close — as a fraction of the current viewport span — to the
    /// edge of the cached tile's own margin, kick off a background render
    /// for a freshly re-centered tile. Firing well before the margin is
    /// actually exhausted (not at the exact edge) gives the new tile time
    /// to land before it's needed; 0.35 empirically leaves enough runway
    /// for a `tileMarginFactor = 3.0` tile (each edge starts with a full
    /// viewport-span of margin either side) without re-triggering on every
    /// frame near the middle of a long drag.
    private static let prefetchMarginFraction: Double = 0.35
    private static let minPrefetchInterval: TimeInterval = 0.25

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

                if !annotations.isEmpty {
                    CallAnnotationOverlay(annotations: annotations, viewport: viewport,
                                          sampleRate: sampleRate, logFrequency: logFrequency,
                                          geoSize: geo.size)
                }

                // Two-finger, per-axis pinch zoom — a UIKit overlay rather
                // than a composed SwiftUI gesture; see TwoAxisPinchView's
                // doc comment for why. Pan-mode only: while selecting, two
                // fingers should do nothing rather than silently rescale
                // the view mid-measurement.
                if !isSelecting {
                    TwoAxisPinchView(onBegan: pinchBegan,
                                     onChanged: pinchChanged,
                                     onEnded: pinchEnded)
                }
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
            // During playback scroll the debounce never fires (continuous
            // change keeps resetting it), so a throttled scheduler renders
            // periodically instead — see `isPlaying`'s doc comment.
            if isPlaying {
                scheduleDetailRenderThrottled()
            } else if renderImmediatelyOnCommit {
                // A gesture just SETTLED (pinch/pan commit) — render the
                // sharp tile now instead of waiting out the debounce. Since
                // the ticker wheels were removed, `viewport` only changes at
                // a settled commit or a minimap scrub, so there's nothing
                // mid-gesture to protect against here; skipping the ~150ms
                // wait shrinks the window where the coarse overview crop
                // (positioned slightly differently than the sharp tile —
                // see the alignment discussion) is what's on screen.
                renderImmediatelyOnCommit = false
                renderDebounceTask?.cancel()
                scheduleDetailRender(for: newValue)
            } else {
                // Not a gesture commit (e.g. a minimap scrub, which DOES
                // fire rapidly on every drag frame) — keep debouncing.
                scheduleDetailRenderDebounced(for: newValue)
            }
            rebuildWarpedImage()
        }
        .onChange(of: isPlaying) { _, nowPlaying in
            // Playback just stopped: the last scroll position was rendered
            // via the throttle (which may have a trailing render pending or
            // none), so kick a normal debounced render to guarantee a final
            // sharp tile at the paused position.
            if !nowPlaying { scheduleDetailRenderDebounced(for: viewport) }
        }
        // A noise-floor/palette change reuses the SAME debounced scheduler
        // as a viewport change — `scheduleDetailRender`'s cheap path (the
        // cached raw tile already covers the CURRENT viewport, since
        // nothing about it changed) recolors directly instead of re-reading
        // PCM/re-running the FFT. Only matters once a detail tile is
        // already showing (zoomed in); the zoomed-out (overview) case is
        // handled by WavPlayerView recoloring `overview.image` in place
        // directly — see its own `.onChange(of: overview.image)` below.
        .onChange(of: noiseFloor) { old, new in
            WavPlayerDebugLog.log("WavSpectrogram", "noiseFloor onChange fired: \(old) -> \(new)")
            scheduleDetailRenderDebounced(for: viewport)
        }
        .onChange(of: palette) { old, new in
            WavPlayerDebugLog.log("WavSpectrogram", "palette onChange fired: \(old) -> \(new)")
            scheduleDetailRenderDebounced(for: viewport)
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
        .onChange(of: silenceMap) { _, _ in
            // Hide-silence toggled or its sensitivity changed: the sample
            // DOMAIN itself changed (real <-> virtual, or a different
            // compression), so every cached tile's coordinates are
            // meaningless now — never let the cheap-recolor path resurrect
            // one. WavPlayerView remaps `viewport` in the same update, and
            // the debounced render below picks up the new domain.
            cachedRawTile = nil
            detailTile = nil
            scheduleDetailRenderDebounced(for: viewport)
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

    /// True when `tile` has pixel data for the ENTIRE `[start, end) x
    /// [minHz, maxHz]` rectangle being asked for — not an exact-bounds
    /// match. A detail tile's time bounds are now a MARGIN around whatever
    /// viewport it was rendered for (see `scheduleDetailRender`), so a live
    /// pan that's drifted within that margin should still crop straight
    /// from the tile instead of falling back to the coarse overview — this
    /// containment check is what makes that possible. The small epsilon on
    /// the frequency check absorbs `colorize`'s bin quantization (its
    /// returned `minFreqHz/maxFreqHz` are always AT LEAST as wide as
    /// whatever was requested, never narrower, but not always bit-identical
    /// to it).
    private func tileCovers(_ tile: WavSpectrogramEngine.DetailTile, start: Int, end: Int, minHz: Double, maxHz: Double) -> Bool {
        start >= tile.startSample && end <= tile.endSample
            && minHz >= tile.minFreqHz - 1 && maxHz <= tile.maxFreqHz + 1
    }

    /// Whichever image is currently the right one to display, along with the
    /// ACTUAL frequency bounds it covers.
    ///
    /// Previously this always fell back to the whole-file overview crop
    /// while `isInteracting` (mid-drag/coast), on the reasoning that a
    /// detail tile only ever had pixel data for its own exact,
    /// already-committed bounds — showing it during a live pan that had
    /// since diverged meant either stale content or a distorted `.offset()`
    /// transform. Detail tiles now carry a TIME MARGIN wider than the
    /// viewport they were rendered for (see `scheduleDetailRender`), so
    /// that's no longer true in general: as long as the live range is still
    /// WITHIN the cached tile's own bounds (`tileCovers`), cropping straight
    /// from it is exactly as valid as cropping from the overview, just
    /// sharper — this is what keeps a long continuous drag looking sharp
    /// instead of reverting to the coarse overview the instant a finger
    /// moves. Once the live range outgrows the tile's margin, `tileCovers`
    /// naturally fails and this falls back to the overview crop, same as
    /// before — `maybePrefetchTile` exists precisely to keep a fresh,
    /// re-centered tile arriving before that happens during a long drag.
    private func currentSourceImage() -> (image: UIImage, loHz: Double, hiHz: Double)? {
        let start: Int, end: Int
        let minHz: Double, maxHz: Double
        if isInteracting {
            (start, end) = liveSampleRange()
            (minHz, maxHz) = liveFreqRangeFromPan()
        } else {
            start = viewport.startSample; end = viewport.endSample
            minHz = viewport.minFreqHz; maxHz = viewport.maxFreqHz
        }
        if let tile = detailTile, tileCovers(tile, start: start, end: end, minHz: minHz, maxHz: maxHz),
           let cropped = crop(image: tile.image, imageStartSample: tile.startSample, imageEndSample: tile.endSample,
                              imageMinHz: tile.minFreqHz, imageMaxHz: tile.maxFreqHz,
                              cropStart: start, cropEnd: end, minHz: minHz, maxHz: maxHz) {
            return (cropped, minHz, maxHz)
        }
        // Map against the overview's ACTUAL frame-covered span
        // (`rawTile.endSample`), not the file length — same reason detail
        // tiles do (see `renderRawTile`). The error is tiny on a whole-file
        // overview but keeping it consistent means the overview crop and a
        // detail tile place a given sample at the same x, so swapping between
        // them doesn't nudge the image.
        if let cropped = crop(image: overview.image, imageStartSample: overview.rawTile.startSample,
                              imageEndSample: overview.rawTile.endSample,
                              imageMinHz: 0, imageMaxHz: overview.maxFreqHz,
                              cropStart: start, cropEnd: end, minHz: minHz, maxHz: maxHz) {
            return (cropped, minHz, maxHz)
        }
        return nil
    }

    /// The viewport implied by ALL live (not-yet-committed) gesture state —
    /// pan offsets AND pinch scale/offset — via the same
    /// `WavViewportMath.resolvedViewport` call `commitPan` makes, evaluated
    /// live for display instead of only at commit time. Replaces the old
    /// hand-rolled `liveSampleRange`/`liveFreqRangeFromPan` shift math,
    /// which was exactly `resolvedViewport` at scale 1 (same "clamp both
    /// edges together, never independently" behavior — see that function's
    /// doc comment for the balloon-outward bug independent clamping causes);
    /// going through the shared function is what lets the pinch's live
    /// preview reuse the identical path with scales != 1.
    ///
    /// Pan sign conventions (unchanged, now enforced by `resolvedViewport`):
    /// `gestureOffsetX`/`gestureOffsetY` are fractions of the view's
    /// width/height; content follows the finger on both axes — drag right
    /// reveals earlier time, drag down reveals higher frequency (top =
    /// high frequency throughout this view).
    private func liveViewport() -> WavViewport {
        WavViewportMath.resolvedViewport(
            committed: viewport,
            timeScale: pinchScaleX, timeOffset: Double(gestureOffsetX) + pinchOffsetX,
            freqScale: pinchScaleY, freqOffset: Double(gestureOffsetY) + pinchOffsetY,
            totalSamples: overview.totalSamples, nyquistHz: sampleRate / 2)
    }

    private func liveSampleRange() -> (start: Int, end: Int) {
        let live = liveViewport()
        return (live.startSample, live.endSample)
    }

    private func liveFreqRangeFromPan() -> (min: Double, max: Double) {
        let live = liveViewport()
        return (live.minFreqHz, live.maxFreqHz)
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

    /// Crops `image` — which is understood to span `[imageStartSample,
    /// imageEndSample)` samples and `[imageMinHz, imageMaxHz]` Hz across its
    /// full width/height — down to the `[cropStart, cropEnd) x [minHz,
    /// maxHz]` sub-rectangle. General enough to crop EITHER the whole-file
    /// overview (`imageStartSample: 0, imageEndSample: overview.totalSamples,
    /// imageMinHz: 0, imageMaxHz: overview.maxFreqHz`) or a detail tile
    /// (using ITS OWN, possibly time-margined, bounds) with the same code —
    /// both are just "an image covering some known rectangle", and cropping
    /// only needs the requested sub-rectangle to be a subset of it
    /// (`tileCovers` is what checks that for a tile; the overview's bounds
    /// are the whole file, so any viewport is always a subset).
    private func crop(image: UIImage, imageStartSample: Int, imageEndSample: Int,
                      imageMinHz: Double, imageMaxHz: Double,
                      cropStart: Int, cropEnd: Int, minHz: Double, maxHz: Double) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let sampleSpan = imageEndSample - imageStartSample
        guard sampleSpan > 0 else { return nil }
        let width = cg.width, height = cg.height
        let leftFrac = Double(cropStart - imageStartSample) / Double(sampleSpan)
        let rightFrac = Double(cropEnd - imageStartSample) / Double(sampleSpan)
        let x0 = max(0, min(width - 1, Int((leftFrac * Double(width)).rounded())))
        let x1 = max(x0 + 1, min(width, Int((rightFrac * Double(width)).rounded())))

        let hzSpan = max(imageMaxHz - imageMinHz, 1)
        let topFrac = 1 - (maxHz - imageMinHz) / hzSpan
        let bottomFrac = 1 - (minHz - imageMinHz) / hzSpan
        let y0 = max(0, min(height - 1, Int((topFrac * Double(height)).rounded())))
        let y1 = max(y0 + 1, min(height, Int((bottomFrac * Double(height)).rounded())))

        guard let cropped = cg.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        else { return nil }
        return UIImage(cgImage: cropped)
    }

    // MARK: Viewport commit + detail-tile rendering

    private static let viewportRenderDebounceSeconds = 0.15

    private func scheduleDetailRenderDebounced(for target: WavViewport) {
        renderDebounceTask?.cancel()
        renderDebounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.viewportRenderDebounceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { scheduleDetailRender(for: target) }
        }
    }

    /// Minimum spacing between renders while playback is scrolling the view.
    /// Unlike the debounce (which fires `interval` after motion STOPS, i.e.
    /// never during a continuous scroll), this fires periodically DURING the
    /// scroll: a leading render immediately if enough time has passed, else
    /// a single trailing one. Each render carries the usual time margin, so
    /// the playhead scrolls SHARPLY through the resident tile between fires,
    /// only briefly touching the coarse overview when it outruns the margin
    /// just before the next fire lands. ~0.3s keeps the tile fresh without
    /// spawning renders faster than they complete (~150-400ms each).
    private static let playbackRenderThrottleSeconds = 0.3
    @State private var lastPlaybackRenderTime: Date?
    @State private var playbackRenderTask: Task<Void, Never>?
    /// Set by `commitPan` (a settled gesture) so the next `viewport`
    /// `.onChange` renders the sharp tile immediately instead of debouncing
    /// — see that `.onChange` for why this is safe now that the ticker
    /// wheels are gone.
    @State private var renderImmediatelyOnCommit = false

    private func scheduleDetailRenderThrottled() {
        let now = Date()
        if let last = lastPlaybackRenderTime, now.timeIntervalSince(last) < Self.playbackRenderThrottleSeconds {
            // Too soon — schedule a single trailing render for the position
            // the scroll has reached by then (reads the current `viewport`,
            // not a captured stale one).
            playbackRenderTask?.cancel()
            let delay = Self.playbackRenderThrottleSeconds - now.timeIntervalSince(last)
            playbackRenderTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    lastPlaybackRenderTime = Date()
                    scheduleDetailRender(for: viewport)
                }
            }
        } else {
            lastPlaybackRenderTime = now
            scheduleDetailRender(for: viewport)
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
        // Pinch scale/offset fold in here too (identity when no pinch is
        // active) — a pinch that began mid-drag commits the frozen pan
        // offset and the pinch's own scale+offset as ONE resolvedViewport
        // application, same math the live preview (`liveViewport`) shows.
        // Captured BEFORE the reset below so the log reflects the actual
        // inputs, not the zeroed-out state.
        let inScaleX = pinchScaleX, inScaleY = pinchScaleY
        let inOffX = Double(gestureOffsetX) + pinchOffsetX
        let inOffY = Double(gestureOffsetY) + pinchOffsetY
        let resolved = WavViewportMath.resolvedViewport(
            committed: viewport,
            timeScale: pinchScaleX, timeOffset: Double(gestureOffsetX) + pinchOffsetX,
            freqScale: pinchScaleY, freqOffset: Double(gestureOffsetY) + pinchOffsetY,
            totalSamples: overview.totalSamples, nyquistHz: sampleRate / 2)
        gestureOffsetX = 0; gestureBaseOffsetX = 0
        gestureOffsetY = 0; gestureBaseOffsetY = 0
        pinchScaleX = 1; pinchScaleY = 1
        pinchOffsetX = 0; pinchOffsetY = 0
        isInteracting = false
        dragTranslationXAtLastCommit = lastDragTranslationX
        dragTranslationYAtLastCommit = lastDragTranslationY
        WavPlayerDebugLog.log("WavSpectrogram", "commitPan: inputs[scaleX=\(String(format: "%.3f", inScaleX)) offX=\(String(format: "%.3f", inOffX)) scaleY=\(String(format: "%.3f", inScaleY)) offY=\(String(format: "%.3f", inOffY))] \(viewport.startSample)-\(viewport.endSample)/\(Int(viewport.minFreqHz))-\(Int(viewport.maxFreqHz))Hz -> \(resolved.startSample)-\(resolved.endSample)/\(Int(resolved.minFreqHz))-\(Int(resolved.maxFreqHz))Hz (span \(viewport.sampleSpan)->\(resolved.sampleSpan))")
        // Only flag an immediate render when the commit actually MOVES the
        // viewport — otherwise `.onChange` won't fire and the flag would
        // leak onto the next (possibly non-settle) viewport change.
        if resolved != viewport { renderImmediatelyOnCommit = true }
        viewport = resolved   // triggers .onChange -> scheduleDetailRender
    }

    /// Single place responsible for detail-tile fetching, reacting to ANY
    /// viewport change regardless of source (pan commit, zoom/frequency
    /// slider, minimap recenter), a noise-floor/palette change, AND a
    /// background prefetch (`isPrefetch: true` — see `maybePrefetchTile`) —
    /// kept separate from `commitPan` so those other callers don't need to
    /// know anything about rendering.
    ///
    /// Renders a TIME-MARGINED span around `target` (`tileMarginFactor`x
    /// wider, centered on the same point) rather than `target`'s own exact
    /// bounds — see the cheap-path check below, which is what actually pays
    /// off that margin: any LATER call whose `target` still falls inside
    /// the cached raw tile's bounds (a small pan, a frequency-only change, a
    /// noise-floor/palette tick) recolors directly instead of re-reading
    /// PCM and re-running the FFT. That one check now covers what used to
    /// be three separate code paths:
    ///  - a noise-floor/palette change (`target == viewport`, unchanged —
    ///    trivially covered),
    ///  - a frequency-only pan settling (the raw STFT grid always has every
    ///    one of its bins regardless of what was last colorized — only
    ///    `colorize` crops those away for display — so a pure frequency
    ///    change never needs a new FFT either),
    ///  - a horizontal pan/prefetch that's still within the cached tile's
    ///    time margin.
    private func scheduleDetailRender(for target: WavViewport, isPrefetch: Bool = false) {
        renderGeneration += 1
        let myGeneration = renderGeneration

        // Containment alone isn't enough to take the cheap path: `colorize`
        // never re-buckets columns, so recoloring a WIDE raw tile (say, one
        // rendered as the margin around a much-less-zoomed-in previous
        // viewport) produces an image whose column density still matches
        // THAT wider span — cropping it down to a much narrower `target`
        // just blows up the same coarse pixels rather than showing more
        // detail. This is what was actually causing "the high-res tile
        // never pops in": containment held (a zoom-in's narrower target
        // sits well within the previous tile's bounds), so every zoom kept
        // taking the cheap path and reusing stale, too-coarse column data
        // forever, never triggering the fresh, denser FFT render the new
        // zoom level actually needed. Requiring the raw tile's OWN density
        // (its columns, scaled down to just `target`'s share of its span)
        // to still clear the same threshold `needsDetailTile` uses is what
        // makes a real zoom-in fall through to a full re-render instead.
        let rawStillSharpEnough: Bool = {
            guard let raw = cachedRawTile, target.startSample >= raw.startSample, target.endSample <= raw.endSample else { return false }
            let rawSpan = max(raw.endSample - raw.startSample, 1)
            let colsForTarget = Double(raw.nCols) * Double(target.sampleSpan) / Double(rawSpan)
            // Cap the density requirement by how many native STFT frames the
            // target span physically contains — at deep zoom that's fewer
            // than `targetColumns` (e.g. ~980 frames for a ~80ms span), and
            // a raw tile already holding every one of them is as sharp as a
            // re-render could ever be. Without this cap the fixed
            // `targetColumns * 0.8` threshold was unreachable at exactly
            // those zoom levels, so EVERY frequency-only Range tick and
            // noise-floor/palette change re-read PCM and re-ran the FFT
            // (confirmed in the on-device log: eight consecutive full
            // staged renders during one Range drag) instead of taking the
            // recolor path this check exists to enable.
            let nativeFrames = Double(max(1, 1 + (target.sampleSpan - STFTGrid.windowLen) / STFTGrid.hop))
            return colsForTarget >= min(Double(Self.targetColumns) * 0.8, nativeFrames)
        }()

        if rawStillSharpEnough, let raw = cachedRawTile {
            WavPlayerDebugLog.log("WavSpectrogram", "scheduleDetailRender: cheap recolor path (raw \(raw.startSample)-\(raw.endSample) covers \(target.startSample)-\(target.endSample), density OK), isPrefetch=\(isPrefetch), generation=\(myGeneration)")
            let sr = sampleRate, pal = palette, floor = noiseFloor
            let minHz = target.minFreqHz, maxHz = target.maxFreqHz
            Task.detached(priority: .userInitiated) {
                let tile = WavPlayerDebugLog.time("WavSpectrogram", "detail tile recolor (cached raw)") {
                    WavSpectrogramEngine.colorize(raw, sampleRate: sr, minFreqHz: minHz, maxFreqHz: maxHz,
                                                  palette: pal, noiseFloor: floor)
                }
                await MainActor.run {
                    if isPrefetch { self.prefetchInFlight = false }
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

        let needsDetail = Self.needsDetailTile(
            viewport: target, overviewTotalSamples: overview.totalSamples,
            overviewWidth: Int(overview.image.size.width),
            overviewHeight: Int(overview.image.size.height),
            nyquistHz: sampleRate / 2, targetColumns: Self.targetColumns)
        WavPlayerDebugLog.log("WavSpectrogram", "scheduleDetailRender: span=\(target.sampleSpan) freqSpan=\(target.freqSpan) needsDetailTile=\(needsDetail), isPrefetch=\(isPrefetch), generation=\(myGeneration)")
        guard needsDetail else {
            if isPrefetch { prefetchInFlight = false }
            return
        }
        if isPrefetch {
            guard !prefetchInFlight else { return }
            prefetchInFlight = true
        }
        // Deliberately NOT clearing `detailTile` here (an earlier version
        // did, unconditionally, to fall back to the overview crop while a
        // new render was in flight) — `currentSourceImage`'s own
        // `tileCovers` check already falls back to the overview the moment
        // the EXISTING tile stops covering whatever's on screen, so there's
        // no window where a stale tile could wrongly be shown instead.
        // Leaving it in place means the still-valid tile keeps displaying,
        // uninterrupted, while a wider/re-centered replacement renders in
        // the background — the whole point of the margin below.

        let span = max(target.sampleSpan, 1)
        let center = (target.startSample + target.endSample) / 2

        // Bias the EXTRA buffer (everything beyond the visible span itself)
        // toward whichever direction the view has actually been moving —
        // 75/25 rather than all-or-nothing: an earlier version put 100% of
        // the margin ahead and ZERO behind, which meant the instant a pan
        // REVERSED direction it exited the tile and fell back to the blurry
        // overview — the "even the pulse I'm looking at re-renders" flicker
        // during back-and-forth panning at deep zoom. The trailing quarter
        // keeps a reversal sharp long enough for the re-centered render to
        // land.
        // Direction is inferred by comparing this render's center to the
        // last rendered raw tile's own center: the side just come FROM was
        // either already covered a moment ago or is trivially cheap to
        // re-render if the user reverses, while the side headed TOWARD is
        // what actually determines whether a continued pan in the same
        // direction keeps hitting the cheap-recolor path instead of falling
        // back to the overview. A steady pan previously got the same 1x
        // margin behind as ahead — wasted, since "behind" is the ground
        // already scrolled past. No prior tile (the very first render) means
        // no known direction, so the split stays even, same as before.
        var bias: Double = 0
        if let raw = cachedRawTile {
            let oldCenter = (raw.startSample + raw.endSample) / 2
            if center > oldCenter { bias = 1 } else if center < oldCenter { bias = -1 }
        }

        let proportionalExtra = max(0, min(overview.totalSamples, Int(Double(span) * Self.tileMarginFactor)) - span)
        let absoluteFloorExtra = min(max(0, overview.totalSamples - span), Int(Self.minBufferSeconds * sampleRate) * 2)
        // Cap the margin so the full tile never exceeds `maxTileColumns` at
        // this zoom's EFFECTIVE column density — see that constant's doc
        // comment for the unbounded-growth pathology this prevents. The
        // effective density is the requested one (`targetColumns` per
        // viewport span) OR the native hop density, whichever is LOWER:
        // `streamPooledGridFromFile` clamps its width to the span's native
        // frame count, so at deep zoom (where the whole viewport holds
        // fewer than `targetColumns` native frames) the same column budget
        // buys far more margin than the requested-density formula alone
        // suggests — ~0.5s of real audio at `maxTileColumns = 6144`, hop
        // 32. Using the requested density unconditionally (as this
        // originally did) shrank the deep-zoom buffer to ~4 viewport spans
        // (tens of ms), which a pan blew through almost immediately —
        // constant fallback to the blurry overview crop, "flickers on
        // every touch".
        let requestedColsPerSample = Double(Self.targetColumns) / Double(span)
        let nativeColsPerSample = 1.0 / Double(STFTGrid.hop)
        let colsPerSample = min(requestedColsPerSample, nativeColsPerSample)
        let maxTileSpanForColumnCap = Int(Double(Self.maxTileColumns) / colsPerSample)
        let maxExtraForColumnCap = max(0, maxTileSpanForColumnCap - span)
        let totalExtra = min(max(proportionalExtra, absoluteFloorExtra), maxExtraForColumnCap)
        let rightExtra = Int((Double(totalExtra) * (1 + 0.5 * bias) / 2).rounded())
        let leftExtra = totalExtra - rightExtra
        let halfSpan = span / 2
        var finalStart = center - halfSpan - leftExtra
        var finalEnd = center + (span - halfSpan) + rightExtra
        finalStart = max(0, finalStart)
        finalEnd = min(overview.totalSamples, finalEnd)

        WavPlayerDebugLog.log("WavSpectrogram", "scheduleDetailRender: staging buffer toward \(finalStart)-\(finalEnd) (target \(target.startSample)-\(target.endSample)), isPrefetch=\(isPrefetch), generation=\(myGeneration)")

        // Stage the render in `chunkSeconds` steps instead of one big
        // multi-second render: the VISIBLE FRAME (`target`'s own bounds)
        // renders FIRST — the fastest possible render, since it carries no
        // margin at all yet — and becomes the displayed tile the instant it
        // lands, rather than gating on the full margin finishing before
        // anything sharper than the overview shows. See `renderChunkedStep`
        // for how each subsequent step grows it further.
        renderChunkedStep(myGeneration: myGeneration, isPrefetch: isPrefetch, target: target,
                          currentStart: target.startSample, currentEnd: target.endSample,
                          finalStart: finalStart, finalEnd: finalEnd)
    }

    /// One step of the staged buffer build-out `scheduleDetailRender` kicks
    /// off: renders exactly `[currentStart, currentEnd)` and displays it
    /// immediately, then — if that's not yet the full desired
    /// `[finalStart, finalEnd)` margin — grows by one more `chunkSeconds`
    /// toward WHICHEVER SIDE HAS MORE REMAINING distance to cover (so a
    /// steady one-directional pan gets its next second, then the one after
    /// that, before any budget goes toward the side just come from) and
    /// schedules itself again. Each step is a complete, independently
    /// useful render, not a fragment needing to be stitched with others —
    /// nothing waits for the whole chain before showing something sharper
    /// than the previous step.
    ///
    /// Deliberately re-renders `[currentStart, currentEnd)` from scratch
    /// every step (not just the newly-added slice) — the simpler
    /// alternative to splicing raw grids together column-wise, at the cost
    /// of redundant work on the already-covered inner portion. Each step
    /// stays individually fast (a bounded, disk-native read — see
    /// `STFTGrid.streamPooledGridFromFile`'s own doc comment), so this
    /// trades some total compute for a much simpler, easier-to-reason-about
    /// chain, which is what actually needs to be robust against being
    /// abandoned mid-flight.
    ///
    /// The generation is checked twice per step — once between the raw
    /// render and the colorize (so a superseded step skips the pixel pass
    /// entirely, see the inline comment there), and once when applying the
    /// result — if a newer `scheduleDetailRender` call (a fresh pan, zoom,
    /// or prefetch) has bumped `renderGeneration` in the meantime, this
    /// step is discarded and NO FURTHER STEPS are scheduled: a rapid direction
    /// change or a fresh zoom cleanly abandons whatever was left of the old
    /// buffer plan instead of continuing to spend background work on a
    /// buffer nobody wants anymore.
    private func renderChunkedStep(myGeneration: Int, isPrefetch: Bool, target: WavViewport,
                                   currentStart: Int, currentEnd: Int, finalStart: Int, finalEnd: Int) {
        let span = max(target.sampleSpan, 1)
        let stepSpan = max(currentEnd - currentStart, 1)
        // Proportionally more columns than `targetColumns` so this step's
        // density matches what a non-margined render of `target`'s own span
        // would have had — same reasoning the original one-shot margin used.
        // The `maxTileColumns` clamp is belt-and-suspenders: the margin
        // `scheduleDetailRender` computes is already capped to this many
        // columns' worth of span, so only rounding could ever push past it.
        let cols = min(Self.maxTileColumns,
                       max(Self.targetColumns, Int((Double(Self.targetColumns) * Double(stepSpan) / Double(span)).rounded())))

        let url = wavURL, sr = sampleRate, pal = palette, floor = noiseFloor
        let minHz = target.minFreqHz, maxHz = target.maxFreqHz
        let map = silenceMap
        bufferDebugStatus.renderingStart = currentStart
        bufferDebugStatus.renderingEnd = currentEnd
        bufferDebugStatus.isRendering = true

        Task.detached(priority: .userInitiated) {
            guard let raw = WavPlayerDebugLog.time("WavSpectrogram", "renderRawTile step \(currentStart)-\(currentEnd) (target \(target.startSample)-\(target.endSample), final \(finalStart)-\(finalEnd), stitched=\(map != nil))", {
                map.map { WavSpectrogramEngine.renderRawTileStitched(wavURL: url, virtualStart: currentStart, virtualEnd: currentEnd, map: $0, targetColumns: cols) }
                    ?? WavSpectrogramEngine.renderRawTile(wavURL: url, startSample: currentStart, endSample: currentEnd, targetColumns: cols)
            })
            else {
                WavPlayerDebugLog.log("WavSpectrogram", "renderRawTile step FAILED for span \(currentStart)-\(currentEnd)")
                await MainActor.run {
                    self.bufferDebugStatus.isRendering = false
                    if isPrefetch { self.prefetchInFlight = false }
                }
                return
            }
            // Check the generation BETWEEN the two halves of the render, not
            // just at the end: previously a superseded step still ran its
            // full colorize before discovering it was stale, and during a
            // rapid pan several of those stale colorizes ran concurrently —
            // measured on-device inflating a ~180ms colorize to 4-5s through
            // sheer CPU contention, which then starved the CURRENT render
            // too. Bailing here costs one main-actor hop and saves the
            // entire pixel pass.
            let stillCurrent = await MainActor.run { () -> Bool in
                guard myGeneration == self.renderGeneration else {
                    WavPlayerDebugLog.log("WavSpectrogram", "detail tile step SUPERSEDED before colorize (generation \(myGeneration) != \(self.renderGeneration)) — chain abandoned")
                    self.bufferDebugStatus.isRendering = false
                    if isPrefetch { self.prefetchInFlight = false }
                    return false
                }
                return true
            }
            guard stillCurrent else { return }
            let tile = WavPlayerDebugLog.time("WavSpectrogram", "detail tile colorize (step)") {
                WavSpectrogramEngine.colorize(raw, sampleRate: sr, minFreqHz: minHz, maxFreqHz: maxHz, palette: pal, noiseFloor: floor)
            }
            await MainActor.run {
                self.bufferDebugStatus.isRendering = false
                guard myGeneration == self.renderGeneration else {
                    WavPlayerDebugLog.log("WavSpectrogram", "detail tile step SUPERSEDED (generation \(myGeneration) != \(self.renderGeneration)) — chain abandoned")
                    if isPrefetch { self.prefetchInFlight = false }
                    return
                }
                WavPlayerDebugLog.log("WavSpectrogram", "detail tile step APPLIED \(currentStart)-\(currentEnd), image=\(tile?.image.size ?? .zero)")
                self.cachedRawTile = raw
                self.detailTile = tile
                self.bufferDebugStatus.readyStart = currentStart
                self.bufferDebugStatus.readyEnd = currentEnd
                self.bufferDebugStatus.hasReady = true
                self.rebuildWarpedImage()

                let chunkSamples = max(1, Int(Self.chunkSeconds * sr))
                let remainingRight = max(0, finalEnd - currentEnd)
                let remainingLeft = max(0, currentStart - finalStart)
                guard remainingRight > 0 || remainingLeft > 0 else {
                    if isPrefetch { self.prefetchInFlight = false }
                    return
                }
                var nextStart = currentStart
                var nextEnd = currentEnd
                if remainingRight >= remainingLeft {
                    nextEnd = currentEnd + min(chunkSamples, remainingRight)
                } else {
                    nextStart = currentStart - min(chunkSamples, remainingLeft)
                }
                self.renderChunkedStep(myGeneration: myGeneration, isPrefetch: isPrefetch, target: target,
                                       currentStart: nextStart, currentEnd: nextEnd,
                                       finalStart: finalStart, finalEnd: finalEnd)
            }
        }
    }

    /// Checks whether the live pan position (mid-drag or mid-momentum-coast)
    /// has drifted close enough to the edge of the CACHED tile's own time
    /// margin that a fresh, re-centered tile should start rendering now, in
    /// the background — rather than waiting for the drag to settle
    /// (`scheduleDetailRenderDebounced`, which only fires after
    /// `liveDebounceSeconds` of no movement) or for the margin to run out
    /// entirely, which would otherwise mean falling back to the coarse
    /// overview crop for the remainder of a long, continuous drag. Called
    /// on every gesture/momentum frame, so throttled
    /// (`lastPrefetchTime`/`minPrefetchInterval`) and deduplicated
    /// (`prefetchInFlight`).
    private func maybePrefetchTile() {
        guard let tile = detailTile, !prefetchInFlight else { return }
        let (start, end) = liveSampleRange()
        let marginLeft = start - tile.startSample
        let marginRight = tile.endSample - end
        let remaining = min(marginLeft, marginRight)
        let span = max(end - start, 1)
        let threshold = Int(Double(span) * Self.prefetchMarginFraction)
        guard remaining < threshold else { return }
        if let last = lastPrefetchTime, Date().timeIntervalSince(last) < Self.minPrefetchInterval { return }
        lastPrefetchTime = Date()

        let center = (start + end) / 2
        let halfSpan = span / 2
        var newStart = center - halfSpan
        var newEnd = newStart + span
        if newStart < 0 { newEnd -= newStart; newStart = 0 }
        if newEnd > overview.totalSamples { newStart -= (newEnd - overview.totalSamples); newEnd = overview.totalSamples }
        newStart = max(0, newStart)
        newEnd = min(overview.totalSamples, newEnd)
        let target = WavViewport(startSample: newStart, endSample: newEnd,
                                 minFreqHz: viewport.minFreqHz, maxFreqHz: viewport.maxFreqHz)
        WavPlayerDebugLog.log("WavSpectrogram", "maybePrefetchTile: margin remaining=\(remaining) < threshold=\(threshold) (tile \(tile.startSample)-\(tile.endSample), live \(start)-\(end)) -> prefetching \(newStart)-\(newEnd)")
        scheduleDetailRender(for: target, isPrefetch: true)
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

    // MARK: Two-axis pinch (see TwoAxisPinchView)

    private func pinchBegan() {
        WavPlayerDebugLog.log("WavSpectrogram", "PINCH began: viewport \(viewport.startSample)-\(viewport.endSample)/\(Int(viewport.minFreqHz))-\(Int(viewport.maxFreqHz))Hz | isDragging=\(isDragging) postPinchPending=\(postPinchRebasePending) gestureOffX=\(String(format: "%.3f", gestureOffsetX))")
        momentum.cancel()
        commitTask?.cancel()
        isPinching = true
        isInteracting = true
    }

    private func pinchChanged(_ value: TwoAxisPinchValue) {
        pinchScaleX = value.scaleX
        pinchScaleY = value.scaleY
        WavPlayerDebugLog.log("WavSpectrogram", "PINCH changed: scaleX=\(String(format: "%.3f", value.scaleX)) scaleY=\(String(format: "%.3f", value.scaleY)) centroidDX=\(String(format: "%.3f", value.centroidDXFrac)) anchorX=\(String(format: "%.3f", value.anchorXFrac))")
        // Anchor-preserving offset: solving `screen(v) = 0.5 + (v-0.5)*scale
        // + offset` for "the content point that started under the pinch
        // centroid stays under it" gives `offset = (anchor - 0.5)*(1 -
        // scale)` (anchor as a screen fraction); the centroid-drag term on
        // top lets a two-finger drag pan while it zooms, same content-
        // follows-finger convention as the one-finger pan.
        pinchOffsetX = (value.anchorXFrac - 0.5) * (1 - value.scaleX) + value.centroidDXFrac
        pinchOffsetY = (value.anchorYFrac - 0.5) * (1 - value.scaleY) + value.centroidDYFrac
        isInteracting = true
    }

    private func pinchEnded() {
        WavPlayerDebugLog.log("WavSpectrogram", "PINCH ended: finalScaleX=\(String(format: "%.3f", pinchScaleX)) scaleY=\(String(format: "%.3f", pinchScaleY)) offX=\(String(format: "%.3f", pinchOffsetX)) offY=\(String(format: "%.3f", pinchOffsetY)) | isDragging=\(isDragging) -> committing + setting postPinchPending")
        isPinching = false
        postPinchRebasePending = true   // see the property's doc comment
        commitPan()   // folds the pinch terms in and resets them — see commitPan
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
                // While a two-finger pinch is active, the pinch owns ALL
                // movement — this drag is tracking one of the same two
                // fingers, so panning from it here would double-count the
                // centroid drag the pinch already applies. Rebase the
                // commit baselines continuously so that when the pinch ends
                // with one finger still down, the drag resumes from HERE
                // with no jump (same reasoning as the new-touch rebase
                // below). `isDragging = true` keeps the new-touch block
                // from re-running (and zeroing those baselines) on the
                // first post-pinch frame.
                if isPinching {
                    WavPlayerDebugLog.log("WavSpectrogram", "pan.onChanged: SWALLOW (isPinching) transl=(\(Int(value.translation.width)),\(Int(value.translation.height)))")
                    isDragging = true
                    lockedAxis = nil
                    lastDragTranslationX = value.translation.width
                    lastDragTranslationY = value.translation.height
                    dragTranslationXAtLastCommit = value.translation.width
                    dragTranslationYAtLastCommit = value.translation.height
                    lastVelocitySampleTime = nil
                    dragVelocityX = 0
                    return
                }
                // After a pinch ends, a finger usually lingers (the two
                // fingers rarely lift on the exact same frame), and the pan
                // gesture keeps tracking it. Every event from that lingering
                // finger must be swallowed — not just the first — or it
                // pans and, worse, seeds a momentum coast that drifts the
                // view after the zoom (the "snap back when zooming" bug).
                // `isDragging` is still true here for a continuation of the
                // pinch's own finger (set during the pinch); a genuinely NEW
                // touch after a full lift has `isDragging == false` (cleared
                // by the previous touch's onEnded), so it clears the flag and
                // falls through to normal handling rather than being eaten.
                if postPinchRebasePending {
                    if isDragging {
                        WavPlayerDebugLog.log("WavSpectrogram", "pan.onChanged: SWALLOW (postPinch, isDragging=true — lingering finger) transl=(\(Int(value.translation.width)),\(Int(value.translation.height)))")
                        lockedAxis = nil
                        lastDragTranslationX = value.translation.width
                        lastDragTranslationY = value.translation.height
                        dragTranslationXAtLastCommit = value.translation.width
                        dragTranslationYAtLastCommit = value.translation.height
                        lastVelocitySampleTime = nil
                        dragVelocityX = 0
                        return
                    }
                    // *** SUSPECTED SNAPBACK PATH *** if this fires right
                    // after a pinch with a large transl, the lingering finger
                    // was misclassified as a fresh touch and will pan by the
                    // whole pinch translation.
                    WavPlayerDebugLog.log("WavSpectrogram", "pan.onChanged: postPinch CLEAR (isDragging=false -> treated as FRESH touch) transl=(\(Int(value.translation.width)),\(Int(value.translation.height))) <<< watch for snapback")
                    postPinchRebasePending = false   // fresh touch — resume normally
                }
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
                    WavPlayerDebugLog.log("WavSpectrogram", "pan.onChanged: NEW touch begins, transl=(\(Int(value.translation.width)),\(Int(value.translation.height))) — will commit + zero baselines")
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
                    lockedAxis = nil
                }
                lastDragTranslationX = value.translation.width
                lastDragTranslationY = value.translation.height
                // Decide (once) which axis this touch belongs to, as soon as
                // total movement is unambiguous — see `lockedAxis`'s doc
                // comment. Below the threshold neither offset has moved far
                // from 0 anyway, so leaving it undecided a little longer
                // costs nothing.
                if lockedAxis == nil {
                    let absX = abs(value.translation.width), absY = abs(value.translation.height)
                    if max(absX, absY) > Self.axisLockThreshold {
                        lockedAxis = absX >= absY ? .horizontal : .vertical
                    }
                }
                // Delta since the last commit (identity if none happened yet
                // this touch) — see the state doc comment above.
                if lockedAxis != .vertical {
                    let dxSinceCommit = value.translation.width - dragTranslationXAtLastCommit
                    gestureOffsetX = gestureBaseOffsetX + dxSinceCommit / geoSize.width
                }
                if lockedAxis != .horizontal, geoSize.height > 0 {
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
                maybePrefetchTile()
            }
            .onEnded { value in
                // A drag ending while the pinch still owns the touch (e.g.
                // SwiftUI cancels the drag when the second finger lands, or
                // the drag's finger lifts first) must neither coast nor
                // commit — the pinch's own .ended does the committing.
                if isPinching {
                    WavPlayerDebugLog.log("WavSpectrogram", "pan.onEnded: ignored (isPinching) transl=(\(Int(value.translation.width)),\(Int(value.translation.height)))")
                    isDragging = false
                    return
                }
                // The drag ending right after a fast pinch (both fingers up
                // before any post-pinch drag event) — its translation and
                // velocity are pinch-contaminated, so neither a coast nor a
                // tap-to-seek should fire; the pinch already committed.
                if postPinchRebasePending {
                    WavPlayerDebugLog.log("WavSpectrogram", "pan.onEnded: ignored (postPinch) transl=(\(Int(value.translation.width)),\(Int(value.translation.height))) — clearing flag")
                    postPinchRebasePending = false
                    isDragging = false
                    return
                }
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
                //
                // Scaled DOWN with zoom depth: the residual is measured in
                // screen-widths, and while "N screen-widths of coast" feels
                // the same at every zoom in screen terms, at deep zoom each
                // screen-width is a full re-render of new content — a brisk
                // flick coasted 3+ screens through a buffer only a few
                // screens wide, flying far past whatever was being examined
                // (and flickering through overview fallbacks on the way).
                // Linear taper from full coast when zoomed out to 20% at
                // the maximum zoom (`zoomFraction`: 0 = whole file, 1 =
                // minSampleSpan).
                let zoomFrac = WavViewportMath.zoomFraction(
                    forSampleSpan: viewport.sampleSpan, totalSamples: overview.totalSamples)
                let coastScale = 1.0 - 0.8 * zoomFrac
                let residual = Double(dragVelocityX) * Self.coastTimeConstant * coastScale / Double(geoSize.width)
                WavPlayerDebugLog.log("WavSpectrogram", "panGesture: released, velocity=\(dragVelocityX)pt/s residual=\(residual)")
                let base = gestureOffsetX
                momentum.start(residual: residual) { delta in
                    isInteracting = true
                    gestureOffsetX = base + delta
                    scheduleGestureCommit(after: Self.liveDebounceSeconds)
                    maybePrefetchTile()
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
