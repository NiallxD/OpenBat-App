//
//  BatSwarmEasterEgg.swift
//  OpenBat
//
//  Hidden reward for tapping the footer version number 10x fast — a swarm of
//  bat glyphs bursts outward from the tapped text. Purely cosmetic, no
//  dependencies. ContentView resolves the footer's on-screen anchor (see
//  VersionFooterFrameKey below, same anchor-preference technique AppInfoView's
//  guided tour uses for `.tourTarget`) and passes it in as `origin`.
//

import SwiftUI

/// Publishes the footer version text's on-screen bounds so the swarm knows
/// where to burst from — same anchor-preference technique AppInfoView's
/// guided tour uses for `.tourTarget`, resolved the same way via
/// `.overlayPreferenceValue` + `GeometryReader` so it's correct regardless of
/// safe-area insets.
struct VersionFooterAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

extension View {
    func versionFooterAnchor() -> some View {
        anchorPreference(key: VersionFooterAnchorKey.self, value: .bounds) { $0 }
    }
}

/// One bat's outward flight from the swarm's origin point: launches after
/// `startDelay`, travels along `angle` for `duration` with an ease-IN climb
/// (slow leaving the origin, gradually picking up speed) — bats emerging
/// from a cave mouth, not shrapnel from an explosion — plus a perpendicular
/// sinusoidal wobble and a squash-based wing "flap" (there's no wing
/// geometry to animate on a single glyph, so flap reads as a rapid vertical
/// scale pulse instead).
private struct BatFlight: Identifiable {
    let id = UUID()
    let angle: Double            // radians, direction away from the origin
    let reachFactor: Double      // travel distance as a multiple of the screen diagonal
    let startDelay: Double
    let duration: Double
    let wobbleAmplitude: Double
    let wobbleFrequency: Double
    let flapFrequency: Double
    let fontSize: CGFloat
    let mirrored: Bool

    /// Straight up from the origin, in the coordinate space `angle` below is
    /// measured in (0 = +x/right, increasing clockwise since y grows downward).
    private static let coneCenter = -Double.pi / 2
    /// Half-width of the flight cone — bats spread out towards the top-left
    /// and top-right corners rather than flying in every direction.
    private static let coneHalfAngle = 0.85   // ≈ 49°

    /// Spread `count` bats evenly across the upward cone (with jitter per
    /// bat, plus each one's own in-flight wobble) so the burst reads as a
    /// directional stream rather than a radial explosion or a clumpy scatter.
    static func randomSwarm(count: Int) -> [BatFlight] {
        (0..<count).map { i in
            let spread = 2 * coneHalfAngle * Double(i) / Double(max(count - 1, 1))
            let baseAngle = coneCenter - coneHalfAngle + spread
            let angle = baseAngle + .random(in: -0.1...0.1)
            return BatFlight(angle: angle,
                              reachFactor: .random(in: 0.55...0.95),
                              // Wide, staggered start so bats trickle out one
                              // after another rather than all launching at once.
                              startDelay: .random(in: 0...1.0),
                              duration: .random(in: 1.3...2.2),
                              wobbleAmplitude: .random(in: 10...28),
                              wobbleFrequency: .random(in: 2.5...4.5),
                              flapFrequency: .random(in: 6...10),
                              fontSize: .random(in: 20...32),
                              mirrored: Bool.random())
        }
    }
}

/// Full-screen, non-interactive overlay — the swarm bursts from `origin`
/// (screen coordinates) and flies over whatever's currently on screen
/// without ever intercepting touches.
struct BatSwarmOverlay: View {
    /// Time the swarm needs before every bat has finished its flight — the
    /// caller uses this to know when it's safe to remove the overlay.
    static let totalDuration: Double = 3.4

    let origin: CGPoint

    private let bats = BatFlight.randomSwarm(count: 50)
    private let startDate = Date()

    var body: some View {
        GeometryReader { geo in
            let travelUnit = hypot(geo.size.width, geo.size.height)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let elapsed = context.date.timeIntervalSince(startDate)
                ForEach(bats) { bat in
                    batView(bat, elapsed: elapsed, travelUnit: travelUnit)
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func batView(_ bat: BatFlight, elapsed: Double, travelUnit: Double) -> some View {
        let t = elapsed - bat.startDelay
        if t >= 0, t <= bat.duration {
            let progress = t / bat.duration
            let eased = pow(progress, 1.6)   // ease-in: slow leaving the roost, gathers speed
            let distance = travelUnit * bat.reachFactor * eased
            let dx = cos(bat.angle) * distance
            let dy = sin(bat.angle) * distance
            let perp = (x: -sin(bat.angle), y: cos(bat.angle))
            let wobble = sin(t * bat.wobbleFrequency) * bat.wobbleAmplitude
            let x = origin.x + dx + perp.x * wobble
            let y = origin.y + dy + perp.y * wobble
            let flap = 0.65 + 0.35 * abs(sin(t * bat.flapFrequency))
            // Fade in over the first tenth of the flight (starts effectively
            // invisible right at the origin) and out over the last fifth (so
            // it never visibly clips at the edge of its travel).
            let fadeIn = min(1, progress / 0.1)
            let fadeOut = min(1, (1 - progress) / 0.2)
            Text("🦇")
                .font(.system(size: bat.fontSize))
                .opacity(min(fadeIn, fadeOut))
                .scaleEffect(x: bat.mirrored ? -1 : 1, y: flap)
                .position(x: x, y: y)
        }
    }
}
