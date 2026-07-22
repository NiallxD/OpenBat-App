//
//  ScrollMomentum.swift
//  OpenBat
//
//  Frame-driven "coast to a stop" helper for drag-to-scroll gestures whose
//  scroll position feeds something SwiftUI's `withAnimation` won't
//  interpolate frame-by-frame on its own — e.g. a plain @State Double
//  threaded into a UIViewRepresentable's updateUIView (SpectrogramView's
//  scrollColumnOffset). Runs its own ~60 Hz loop, easing towards the
//  residual distance a flick's release velocity implies, so a flick coasts
//  instead of stopping dead when the finger lifts.
//
//  Built on `CADisplayLink` rather than a `Task.sleep` polling loop — an
//  earlier `Task`-based version reliably ran its FIRST tick (proven by
//  on-device console logging: the initial `apply` call always fired) but
//  then silently never resumed from `try await Task.sleep(...)` — no
//  cancellation, no thrown error, just no second tick, ever. That matches a
//  known class of issue where a plain `Task { @MainActor in ... }`'s
//  continuation doesn't get serviced while the main run loop is in
//  UIKit's gesture-tracking run loop mode right after a touch ends.
//  `CADisplayLink` added with `.common` run loop modes is the traditional,
//  guaranteed-safe way to drive a continuous per-frame update through
//  exactly that situation, and is arguably the more appropriate primitive
//  for a frame-synced animation in the first place.
//

import QuartzCore

@MainActor
final class ScrollMomentum {
    private static let duration: CFTimeInterval = 0.5

    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var residual: Double = 0
    private var apply: ((Double) -> Void)?
    private var completion: (() -> Void)?

    /// Cancels any in-flight coast — call at the start of a new drag so a
    /// fresh touch always wins over a still-decelerating one.
    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        apply = nil
        completion = nil
    }

    /// Eases `apply(delta)` from 0 to `residual` on a cubic ease-out curve,
    /// then calls `completion`. `residual` is the caller's own units
    /// (columns, offset fraction, etc) — typically release velocity times a
    /// fixed time constant.
    func start(residual: Double, apply: @escaping (Double) -> Void, completion: (() -> Void)? = nil) {
        cancel()
        guard abs(residual) > 0.0005 else { completion?(); return }
        self.residual = residual
        self.apply = apply
        self.completion = completion
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // `.common`, not `.default` — without it, this stops ticking the
        // instant the run loop enters tracking mode (e.g. another gesture
        // becoming active), the same class of stall this class exists to
        // avoid in the first place.
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        let t = min(1, (CACurrentMediaTime() - startTime) / Self.duration)
        let eased = 1 - pow(1 - t, 3)
        apply?(residual * eased)
        if t >= 1 {
            let finished = completion
            cancel()
            finished?()
        }
    }
}
