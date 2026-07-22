//
//  PulseZoomView.swift
//  OpenBat
//
//  Photos-app-style pinch-to-zoom + drag-to-pan over PulseImageRenderer's wide
//  render (full spectrum vertically, tight-window-plus-margin horizontally —
//  see PulseImageRenderer.swift and PulseDetector's captured*Wide*/*TimeTight*
//  properties). Both axes use the same `.scaleEffect(anchor: .center)` +
//  `.offset()` composition:
//
//    screen(v) = 0.5 + (v − 0.5)·s + offset      (v, screen ∈ [0,1], top/left = 0)
//
//  `axisZoomGeometry` picks the (defaultScale, offset) pair that makes the tight
//  default window exactly fill the frame at rest; `pulsePanX`/`pulsePanY` START
//  at that value and are the SINGLE source of truth for the current offset from
//  then on (pinch only ever changes scale; drag only ever changes pan) — no
//  separate "baked default" + "user delta" to keep in sync, which is what
//  caused the earlier Y-only zoom bug (see git history). `clampOffsetFrac`
//  bounds pan so the visible window can never pan past the rendered content's
//  own edges ("hit walls").
//
//  A standalone leaf view (extracted from ContentView once it passed 1900
//  lines), which also scopes the high-rate `pulseDetector.captured*` reads to
//  this body instead of ContentView's — see the @Observable-churn note in
//  CLAUDE.md's architecture section.
//

import SwiftUI

struct PulseZoomView: View {
    let pulseDetector: PulseDetector

    /// Independent of the spectrogram's own log toggle — see PulseSettingsView.
    @AppStorage("display.pulseLogFrequency") private var pulseLogFrequency = false

    @State private var pulseZoomScale: CGFloat = 1
    @State private var pulseZoomBaseScale: CGFloat = 1
    @State private var pulsePanX: CGFloat = 0
    @State private var pulsePanY: CGFloat = 0
    @State private var pulsePanBaseX: CGFloat = 0
    @State private var pulsePanBaseY: CGFloat = 0

    /// Row-remapped copy of `pulseDetector.lastPulseImage` for log-frequency display.
    /// Cached (not recomputed every body evaluation, which happens on every pinch/pan
    /// frame) — only rebuilt when a new pulse arrives or the toggle flips.
    @State private var warpedImage: UIImage?

    private var displayedImage: UIImage? {
        pulseLogFrequency ? (warpedImage ?? pulseDetector.lastPulseImage) : pulseDetector.lastPulseImage
    }

    var body: some View {
        GeometryReader { geo in
            pulseZoomContent(geo: geo)
        }
        .onAppear { rebuildWarp() }
        .onChange(of: pulseDetector.lastDetectionDate) { _, _ in rebuildWarp() }
        .onChange(of: pulseLogFrequency) { _, _ in rebuildWarp() }
    }

    private func rebuildWarp() {
        guard pulseLogFrequency, let img = pulseDetector.lastPulseImage else {
            warpedImage = nil
            return
        }
        warpedImage = LogFrequencyWarp.warp(img,
                                            loHz: pulseDetector.capturedWideFreqMin,
                                            hiHz: pulseDetector.capturedWideFreqMax)
    }

    private func pulseZoomContent(geo: GeometryProxy) -> some View {
        // Each axis floors at scale 1 (its full rendered content) independently —
        // the shared pinch multiplier can drive one axis's raw product below 1
        // (e.g. an axis with a smaller "exact fit" scale) without that axis
        // rendering smaller than its own content, which wouldn't mean anything.
        let scaleX = max(1, timeZoomGeometry.defaultScale * pulseZoomScale)
        let scaleY = max(1, freqZoomGeometry.defaultScale * pulseZoomScale)

        return ZStack(alignment: .topLeading) {
            if let img = displayedImage {
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
        guard wideHi > wideLo, tightHi > tightLo else { return (1, 0.5) }
        let leftFrac = LogFrequencyWarp.hzToVFrac(tightHi, lo: wideLo, hi: wideHi, log: pulseLogFrequency)   // tight band's top edge
        let rightFrac = LogFrequencyWarp.hzToVFrac(tightLo, lo: wideLo, hi: wideHi, log: pulseLogFrequency)  // tight band's bottom edge
        return axisZoomGeometry(leftFrac: leftFrac, rightFrac: rightFrac)
    }

    private var timeZoomGeometry: (defaultScale: CGFloat, midFrac: Double) {
        axisZoomGeometry(leftFrac: pulseDetector.capturedTimeTightLeftFrac,
                         rightFrac: pulseDetector.capturedTimeTightRightFrac)
    }

    private var freqTightMidFrac: Double { freqZoomGeometry.midFrac }
    private var timeTightMidFrac: Double { timeZoomGeometry.midFrac }

    /// Screen-edge v-fractions (within the WIDE image's v-space, 0 = top/high,
    /// 1 = bottom/low) for the current zoom/pan. Shared by `visiblePulseFreqRange`
    /// (hi/lo labels) and `tickFreqValues` (evenly-spaced intermediate ticks).
    /// Inverts the same screen(v) relationship the render uses.
    private var visibleVRange: (top: Double, bottom: Double) {
        let s = Double(max(1, freqZoomGeometry.defaultScale * pulseZoomScale))
        guard s > 0 else { return (0, 1) }
        let offset = Double(pulsePanY)
        // screen(v) = 0.5 + (v-0.5)*s + offset; solving for v at screen = 0 / 1.
        return (top: 0.5 - (0.5 + offset) / s, bottom: 0.5 + (0.5 - offset) / s)
    }

    /// Effective visible frequency range for the current zoom/pan — used by
    /// `pulseFrequencyAxis` so the hi/lo labels track what's on screen, not just
    /// the default view.
    private var visiblePulseFreqRange: (lo: Double, hi: Double) {
        let wideLo = pulseDetector.capturedWideFreqMin
        let wideHi = pulseDetector.capturedWideFreqMax
        guard wideHi > wideLo else {
            return (pulseDetector.capturedFreqMin, pulseDetector.capturedFreqMax)
        }
        let (vTop, vBottom) = visibleVRange
        return (lo: LogFrequencyWarp.vFracToHz(vBottom, lo: wideLo, hi: wideHi, log: pulseLogFrequency),
                hi: LogFrequencyWarp.vFracToHz(vTop, lo: wideLo, hi: wideHi, log: pulseLogFrequency))
    }

    /// Evenly spaced (in screen position) tick Hz values across the currently
    /// visible window, top to bottom — same log/linear v→Hz mapping as the
    /// rendered (possibly warped) image, so labels line up with what's on screen.
    private func tickFreqValues(count: Int) -> [Double] {
        let wideLo = pulseDetector.capturedWideFreqMin
        let wideHi = pulseDetector.capturedWideFreqMax
        guard count > 1, wideHi > wideLo else {
            let (lo, hi) = visiblePulseFreqRange
            return [(lo + hi) / 2]
        }
        let (vTop, vBottom) = visibleVRange
        return (0..<count).map { i in
            let v = vTop + Double(i) / Double(count - 1) * (vBottom - vTop)
            return LogFrequencyWarp.vFracToHz(v, lo: wideLo, hi: wideHi, log: pulseLogFrequency)
        }
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
        let ticks = tickFreqValues(count: pulseLogFrequency ? 8 : 5)
        return VStack {
            ForEach(ticks.indices, id: \.self) { i in
                axisLabel(ticks[i])
                if i < ticks.count - 1 { Spacer() }
            }
        }
    }

    private func axisLabel(_ hz: Double) -> some View {
        Text(hz >= 1000 ? String(format: "%.0f kHz", hz / 1000)
                        : String(format: "%.0f Hz", hz))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
            .shadow(radius: 1)
    }
}
