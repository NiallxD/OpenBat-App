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
    let onRecenter: (Int) -> Void   // new center sample

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Image(uiImage: overview.image)
                    .resizable()
                    .interpolation(.low)
                    .frame(width: geo.size.width, height: geo.size.height)

                let x0 = CGFloat(Double(viewport.startSample) / Double(max(overview.totalSamples, 1))) * geo.size.width
                let x1 = CGFloat(Double(viewport.endSample) / Double(max(overview.totalSamples, 1))) * geo.size.width
                Rectangle()
                    .stroke(Color.white, lineWidth: 1.5)
                    .background(Color.white.opacity(0.08))
                    .frame(width: max(2, x1 - x0), height: geo.size.height)
                    .position(x: (x0 + x1) / 2, y: geo.size.height / 2)
                    .allowsHitTesting(false)

                MinimapPlayheadOverlay(engine: engine, totalSamples: overview.totalSamples,
                                       sampleRate: overview.sampleRate, geoSize: geo.size)
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture(geoSize: geo.size))
        }
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
                    .fill(Color.white.opacity(0.9))
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
