//
//  SunWindowPill.swift
//  OpenBat
//
//  The sun clock in the detector's leading nav-bar slot — the slot the logo menu
//  used to occupy before the bottom tab bar took its job (2026-08-16).
//
//  Four states, from `SunWindow.Phase`, in one small visual language:
//
//    hollow sun + "at 20:24"   the event is scheduled, nothing to watch yet
//    filled sun + "+1h 45m"    past sunset, and counting
//    filled sun + "in 1h 45m"  sunrise approaching, and counting
//
//  **Bare content, with no background of its own.** It sits inside the nav bar,
//  and the nav bar already has a material — an `ultraThinMaterial` capsule here
//  (which is what the in-panel status pills use, and what this started as)
//  composites over that and reads as a grey slab inside the glass. The bar is the
//  pill's background; nothing needs to be drawn behind the label.
//
//  **Orange glyph, white readout**, Niall's call, 2026-08-16. So the accent
//  colour no longer distinguishes an activity window from a reference state —
//  that signal now rests entirely on the filled-vs-hollow glyph, which is the
//  same distinction SF Symbols uses for active-vs-inactive throughout iOS.
//  Keeping the number white is deliberate: it is the value being read, at night,
//  at a glance, and white holds up against the spectrogram behind the glass
//  better than the accent does.
//
//  The clock states read "at <time>" rather than a bare time on purpose: a bare
//  "05:12" beside a sunrise glyph is ambiguous about whether it already happened,
//  and in the middle of the night it has not.
//
//  Tapping it opens `SunWindowExplainer` (below) — tonight's sunset and sunrise,
//  and why those hours matter. The pill on its own never says why a bat detector
//  is showing a sun clock at all.
//
//  Shown in simplified view as well as advanced. It is not instrumentation —
//  knowing to go out at dusk is more use to a beginner than to anyone else.
//

import CoreLocation
import SwiftUI

struct SunWindowPill: View {
    /// The user's last known position; `nil` before the first fix, or when
    /// location is denied. The pill renders nothing then — there is no sensible
    /// default sunset.
    let coordinate: CLLocationCoordinate2D?

    // No `tourDemo` stand-in, unlike the other status pills. It used to be that
    // the nav bar was hidden for the whole tour, so a forced phase had nowhere
    // to appear; the bar stays up now (2026-08-17) and the tour spotlights this
    // pill directly, which is better than a demo phase — it points at the real
    // readout rather than a staged one.

    @State private var showExplainer = false
    /// The instant the readout is drawn for, advanced once a minute by `tick()`.
    /// Plain `@State` deliberately — **NOT a `TimelineView`**; see `tick()`.
    ///
    /// This is the pill's ONLY stored state, and the phase is derived from it in
    /// `body` rather than stored alongside it. That is load-bearing — see
    /// `phase`.
    @State private var asOf = Date()

    /// Where we are in the night, computed during `body` from `asOf`.
    ///
    /// **Derived rather than stored, because a toolbar item that renders empty
    /// may never be hosted at all — and then nothing attached to it, `.task`
    /// included, ever runs.** This was stored `@State`, filled in by the tick
    /// loop, which made the first render of the pill empty by construction: no
    /// phase yet, so nothing to draw, so (apparently) no item, so no task, so no
    /// phase. A deadlock that resolves itself only if SwiftUI happens to mount an
    /// empty item, which is not a guarantee to rest a permanent piece of chrome
    /// on. Deriving it means the very first evaluation with a coordinate in hand
    /// already has something to draw, and the tick loop only has to keep it
    /// current once the item is definitely on screen.
    ///
    /// Safe to call from a body: `SunWindow.phase` is memoised precisely so it
    /// can be (see its `solarEvents` cache). The bug that started all this was
    /// the *update mechanism* — a `TimelineView` dragging the nav bar into its
    /// cycle — not the cost of the computation.
    private var phase: SunWindow.Phase? {
        coordinate.flatMap { SunWindow.phase(at: asOf, coordinate: $0) }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()

    var body: some View {
        // Empty until there is a location to anchor to — there is no sensible
        // default sunset. Both of these come straight from the arguments and
        // `asOf` now, so this is non-empty on the first evaluation after a fix
        // lands rather than on the first tick after that; see `phase`.
        Group {
            if let coordinate, let phase {
                Button { showExplainer = true } label: { pill(phase, now: asOf) }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showExplainer) {
                        SunWindowExplainer(coordinate: coordinate)
                            .presentationCompactAdaptation(.popover)
                    }
            }
        }
        // Only keeps `asOf` current — it no longer has to run for the pill to
        // appear, which is the whole point of deriving `phase`. Moving is picked
        // up without it too: a new coordinate re-evaluates `body` directly.
        .task { await tick() }
    }

    /// Updates the readout on the minute, for as long as the pill is on screen.
    ///
    /// **This was a `TimelineView(.everyMinute)` and that is what broke the
    /// detector** (2026-08-16). The pill lives in a `ToolbarItem`, and a
    /// `TimelineView` there pulls the whole navigation bar into its update cycle:
    /// the entire Detector screen — Metal spectrogram included — dropped to
    /// roughly one update a second, while every other screen stayed smooth. Even
    /// dragging the spectrogram only redrew once a second, which is what gave it
    /// away: no amount of work in *this* view could throttle a gesture, so the
    /// problem had to be the update mechanism rather than its cost.
    ///
    /// A `@State` write invalidates this view and nothing above it, which is the
    /// property a toolbar needs. Sleeping to the next wall-clock minute keeps the
    /// digits changing on the minute rather than a minute after launch.
    private func tick() async {
        while !Task.isCancelled {
            let now = Date()
            asOf = now
            let intoMinute = now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
            do { try await Task.sleep(for: .seconds(60 - intoMinute)) } catch { return }
        }
    }

    private func pill(_ phase: SunWindow.Phase, now: Date) -> some View {
        HStack(spacing: 4) {
            // Orange sun, white readout. The glyph carries the colour because it
            // is the sun; the number stays white so it reads as a value at a
            // glance in the dark, which is the whole job.
            Image(systemName: Self.icon(phase))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.batAccent)
            Text(Self.label(phase, now: now))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        // Hold intrinsic width: the number is the whole point of the pill, so it
        // wins the layout rather than being squeezed to just the icon. Same
        // reasoning as `SessionTimerPill`.
        .fixedSize()
        // Breathing room INSIDE the bar's own glass. A toolbar item is fitted to
        // its content, so with none of this the glyph and digits sit hard against
        // the capsule's edges and the whole thing reads as crammed. It is padding
        // rather than a `frame(height:)` because the height has to stay the
        // system's — the bar sizes its own chrome, and forcing a height here
        // fights it.
        .accessibilityHint("Tap for details")
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .accessibilityLabel(Self.accessibilityLabel(phase, now: now))
    }

    // MARK: Formatting

    /// Sunset or sunrise for which event we are measuring against, filled or
    /// hollow for whether it is an activity window. Composed from
    /// `isActivityWindow` rather than written out per case so the fill and the
    /// meaning cannot drift apart — this is the ONLY thing distinguishing an
    /// active window now that both states share the accent glyph colour.
    static func icon(_ phase: SunWindow.Phase) -> String {
        let base: String
        switch phase {
        case .beforeSunset, .afterSunset:   base = "sunset"
        case .night, .dawnCountdown:        base = "sunrise"
        }
        return phase.isActivityWindow ? "\(base).fill" : base
    }

    static func label(_ phase: SunWindow.Phase, now: Date) -> String {
        switch phase {
        case .beforeSunset(let sunset):
            "at \(clock.string(from: sunset))"
        case .afterSunset(let sunset):
            "+\(compact(minutes: elapsedMinutes(since: sunset, now: now)))"
        case .night(let sunrise):
            "at \(clock.string(from: sunrise))"
        case .dawnCountdown(let sunrise):
            "in \(compact(minutes: remainingMinutes(until: sunrise, now: now)))"
        }
    }

    static func accessibilityLabel(_ phase: SunWindow.Phase, now: Date) -> String {
        switch phase {
        case .beforeSunset(let sunset):
            "Sunset at \(clock.string(from: sunset))"
        case .afterSunset(let sunset):
            "\(spoken(minutes: elapsedMinutes(since: sunset, now: now))) since sunset"
        case .night(let sunrise):
            "Sunrise at \(clock.string(from: sunrise))"
        case .dawnCountdown(let sunrise):
            "Sunrise in \(spoken(minutes: remainingMinutes(until: sunrise, now: now)))"
        }
    }

    /// Elapsed rounds DOWN — "+1h 45m" should not claim a minute that has not
    /// finished passing.
    private static func elapsedMinutes(since date: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(date) / 60))
    }

    /// Remaining rounds UP, for the mirror-image reason: "in 0m" should mean the
    /// last minute before sunrise, not the whole of the final minute.
    private static func remainingMinutes(until date: Date, now: Date) -> Int {
        max(0, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// "1h 45m", or "45m" inside the first hour.
    static func compact(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// Spelled out for VoiceOver, which reads "1h 45m" as letters.
    static func spoken(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        let hours = h == 1 ? "1 hour" : "\(h) hours"
        let mins = m == 1 ? "1 minute" : "\(m) minutes"
        if h == 0 { return mins }
        return m == 0 ? hours : "\(hours) \(mins)"
    }
}

// MARK: - Explainer

/// What the pill is for, why those hours, and tonight's actual times.
///
/// The pill alone is a number beside a sun; it never says *why* it is being shown
/// in a bat detector, and the answer — go out at dusk, and again before dawn — is
/// the most actionable thing in the app for someone who has not been out yet.
/// It leads with tonight's real times rather than the general advice, because
/// that is the part a user acts on tonight.
///
/// Computed once when the popover opens rather than on a timeline: a popover is
/// read in a few seconds and the times inside it do not move.
private struct SunWindowExplainer: View {
    let coordinate: CLLocationCoordinate2D

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bat activity tonight")
                .font(.subheadline.weight(.semibold))

            if let night = SunWindow.night(at: Date(), coordinate: coordinate) {
                VStack(spacing: 4) {
                    row("sunset.fill", "Sunset", Self.clock.string(from: night.sunset))
                    row("sunrise.fill", "Sunrise", Self.clock.string(from: night.sunrise))
                }

                Text("Most bats emerge soon after sunset and are most active for the first couple of hours, with a second, quieter burst before sunrise as they return to the roost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Names the actual window length rather than "15%" — a fraction is
                // the implementation, and what the user wants to know is how long
                // they have got.
                Text("This timer counts through those two windows, which for tonight is about \(SunWindowPill.compact(minutes: Int(night.window / 60))) after sunset and before sunrise. Night time is about \(SunWindowPill.compact(minutes: Int(night.sunrise.timeIntervalSince(night.sunset) / 60))) long tonight.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Polar day or night — the pill itself is hidden then, so this is
                // only reachable if the sun stops crossing the horizon while the
                // popover is open. Still worth saying rather than showing a blank.
                Text("The sun doesn't rise or set at your location today so you're either really far north or south, or astrophage has eaten the Sun.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("These times are calculated on-device and are accurate to within a few minutes.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    private func row(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Color.batAccent)
                .frame(width: 16)
            Text(label).font(.caption)
            Spacer(minLength: 12)
            Text(value).font(.caption.monospacedDigit().weight(.semibold))
        }
    }
}
