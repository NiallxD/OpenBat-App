//
//  WavMinimapView.swift
//  OpenBat
//
//  A small always-visible strip showing the whole-file overview image with a
//  rectangle marking the main WavSpectrogramView's current viewport position
//  and a playhead line marking the current playback position — doubling as
//  the player's scrub bar (replaces the old PlaybackScrubberView): dragging
//  anywhere on the strip seeks playback AND recenters the detail viewport on
//  the same point, so the zoomed-in view follows along with what's playing.
//

import SwiftUI

struct WavMinimapView: View {
    /// `overview.image` is kept current by WavPlayerView (mutated in place
    /// on a noise-floor/palette change), so this always shows the same
    /// recolor the main spectrogram does with nothing extra to pass through.
    let overview: WavSpectrogramEngine.Overview
    let viewport: WavViewport
    let engine: PlaybackEngine
    /// Live playback-follow position — read here (instead of relying on
    /// `viewport`, which no longer updates during playback — see
    /// PlaybackFollowState's doc comment) so the position rectangle below
    /// keeps tracking playback; this leaf's own body re-running at ~30Hz to
    /// do so is exactly the isolation `followState` exists to provide.
    let followState: PlaybackFollowState
    let onRecenter: (Int) -> Void   // new center sample (display domain)
    /// Debug-only red/green pan-buffer visualization — see its own doc
    /// comment and `WavSpectrogramView.renderChunkedStep` (the writer).
    let bufferDebugStatus: BufferDebugStatus

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Image(uiImage: displayImage)
                    .resizable()
                    .interpolation(.low)
                    .frame(width: geo.size.width, height: geo.size.height)

                let effectiveViewport = engine.isPlaying ? liveViewport(center: followState.displaySample) : viewport
                let x0 = CGFloat(Double(effectiveViewport.startSample) / Double(max(overview.totalSamples, 1))) * geo.size.width
                let x1 = CGFloat(Double(effectiveViewport.endSample) / Double(max(overview.totalSamples, 1))) * geo.size.width
                Rectangle()
                    .stroke(Color.batAccent.opacity(0.7), lineWidth: 1)
                    .background(Color.batAccent.opacity(0.15))
                    .frame(width: max(2, x1 - x0), height: geo.size.height)
                    .position(x: (x0 + x1) / 2, y: geo.size.height / 2)
                    .allowsHitTesting(false)

                BufferDebugOverlay(status: bufferDebugStatus, totalSamples: overview.totalSamples, geoSize: geo.size)

                MinimapPlayheadOverlay(engine: engine, totalSamples: overview.totalSamples,
                                       sampleRate: overview.sampleRate, geoSize: geo.size)
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture(geoSize: geo.size))
        }
    }

    /// The overview image cropped to the viewport's CURRENT frequency
    /// window — so the minimap's vertical extent always represents whatever
    /// band the main spectrogram is showing (e.g. zoomed to 50–90kHz) rather
    /// than always the full 0–Nyquist range regardless of zoom. Time
    /// (horizontal) is left alone — this stays the scrub bar for the WHOLE
    /// recording, just frequency-scoped to match the current view, same
    /// "position AND range" both matter the way the time rectangle already
    /// shows position within the full time axis.
    private var displayImage: UIImage {
        croppedToFreqRange(overview.image) ?? overview.image
    }

    /// `viewport` re-centered on `center` (a display-domain sample) — see
    /// `WavViewportMath.recentered`'s doc comment for why this shares its
    /// math with WavPlayerView's `recenter(sample:)` and
    /// WavSpectrogramView's own `liveTargetViewport`.
    private func liveViewport(center: Int) -> WavViewport {
        WavViewportMath.recentered(viewport, on: center, totalSamples: overview.totalSamples)
    }

    private func croppedToFreqRange(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let nyquist = overview.maxFreqHz
        guard nyquist > 0 else { return nil }
        let height = cg.height
        let topFrac = 1 - viewport.maxFreqHz / nyquist
        let bottomFrac = 1 - viewport.minFreqHz / nyquist
        let y0 = max(0, min(height - 1, Int((topFrac * Double(height)).rounded())))
        let y1 = max(y0 + 1, min(height, Int((bottomFrac * Double(height)).rounded())))
        guard let cropped = cg.cropping(to: CGRect(x: 0, y: y0, width: cg.width, height: y1 - y0))
        else { return nil }
        return UIImage(cgImage: cropped)
    }

    /// `minimumDistance: 0` covers a plain tap (one `onChanged` at the touch
    /// point) as well as a drag — both should scrub, matching a real
    /// scrub-bar/scrollbar's behavior.
    private func scrubGesture(geoSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in scrub(to: value.location.x, width: geoSize.width) }
    }

    private func scrub(to x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let frac = min(max(Double(x / width), 0), 1)
        let sample = Int((frac * Double(overview.totalSamples)).rounded())
        onRecenter(sample)
        // `engine.seek` calls `driver.stop()`, which is a synchronous
        // semaphore wait (bounded 200ms — see PlaybackDriver.stop's doc
        // comment) — and this fires on EVERY `onChanged` frame of the drag,
        // unthrottled, on the main thread (gesture callbacks run there).
        // Timed here specifically because that's a plausible "minimap
        // scrubbing stutters" cause of the exact same shape as the
        // noise-floor/zoom-slider bugs already found this session — confirm
        // with real numbers before touching scrub behavior, since unlike
        // those, throttling this would change what the user hears while
        // dragging (continuous audio feedback vs. silent-until-release),
        // a real UX tradeoff and not a pure bug fix.
        // Seeks in the SAME domain this strip draws: while silence removal is
        // on, both this overview and the engine's timeline are the compressed
        // one, so there is nothing to map (see PlaybackEngine.setSilenceMap).
        WavPlayerDebugLog.time("WavMinimapView", "scrub -> engine.seek") {
            engine.seek(toSeconds: Double(sample) / max(overview.sampleRate, 1))
        }
    }
}

/// Draws the playback position across the WHOLE FILE width (unlike
/// `WavPlayheadOverlay`, which is scoped to the main spectrogram's current
/// viewport window) — a separate leaf View reading `engine.currentTimeSeconds`
/// inside its own `TimelineView`, same isolation rule `WavPlayheadOverlay`
/// documents: `PlaybackDriver.onProgress` posts at ~20-25 Hz, and reading it
/// inline in a parent's `body` would invalidate that entire body (and with
/// it the drag-to-scrub gesture state) at that rate.
private struct MinimapPlayheadOverlay: View {
    let engine: PlaybackEngine
    let totalSamples: Int
    let sampleRate: Double
    let geoSize: CGSize

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            if let x = playheadX() {
                Rectangle()
                    .fill(Color.batAccent)
                    .frame(width: 1.5)
                    .position(x: x, y: geoSize.height / 2)
                    .frame(height: geoSize.height)
            }
        }
        .allowsHitTesting(false)
    }

    private func playheadX() -> CGFloat? {
        guard totalSamples > 0, sampleRate > 0, geoSize.width > 0 else { return nil }
        let currentSample = engine.currentTimeSeconds * sampleRate
        let frac = min(max(currentSample / Double(totalSamples), 0), 1)
        return CGFloat(frac) * geoSize.width
    }
}

/// DEBUGGING AID: two thin strips along the bottom edge of the minimap
/// showing the pan buffer's actual state — GREEN for the current detail
/// tile's own bounds (already rendered), RED for whatever span the
/// background stepper (`WavSpectrogramView.renderChunkedStep`) is
/// currently computing. Stacked (not overlaid) so both stay visible even
/// when they overlap in time, since the "rendering" step is usually
/// growing right at the edge of the "ready" region. A separate leaf View
/// for the same isolation reason as `MinimapPlayheadOverlay`: `status` is
/// `@Observable` and updates on every render step, so reading it inline in
/// the parent's body would invalidate the whole minimap (and its scrub
/// gesture) on every step instead of just this thin strip.
private struct BufferDebugOverlay: View {
    let status: BufferDebugStatus
    let totalSamples: Int
    let geoSize: CGSize

    private static let barHeight: CGFloat = 2.5

    var body: some View {
        ZStack(alignment: .bottom) {
            if status.hasReady {
                bar(start: status.readyStart, end: status.readyEnd, color: .green, bottomInset: 0)
            }
            if status.isRendering {
                bar(start: status.renderingStart, end: status.renderingEnd, color: .red, bottomInset: Self.barHeight)
            }
        }
        .allowsHitTesting(false)
    }

    private func bar(start: Int, end: Int, color: Color, bottomInset: CGFloat) -> some View {
        let x0 = CGFloat(Double(start) / Double(max(totalSamples, 1))) * geoSize.width
        let x1 = CGFloat(Double(end) / Double(max(totalSamples, 1))) * geoSize.width
        return Rectangle()
            .fill(color.opacity(0.85))
            .frame(width: max(1, x1 - x0), height: Self.barHeight)
            .position(x: (x0 + x1) / 2, y: geoSize.height - bottomInset - Self.barHeight / 2)
    }
}
