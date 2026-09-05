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
            // Orange sun, plain readout. The glyph carries the colour because
            // it is the sun; the number takes the page's own ink so it reads as
            // a value at a glance, which is the whole job — it was literally
            // white, which is the same thing in the dark and invisible in a
            // light-mode toolbar.
            Image(systemName: Self.icon(phase))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.batAccent)
            Text(Self.label(phase, now: now))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
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
/// Tonight's times are computed once when the popover opens — they do not move
/// while it is read. The sun riding the arc does, on the minute; that tick lives
/// in `SunArcView`.
private struct SunWindowExplainer: View {
    let coordinate: CLLocationCoordinate2D

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()

    /// Full screen width bar a margin on a phone, within sensible bounds. A
    /// popover sizes itself to its content, so this has to be stated — there is
    /// no "fill the screen" for content that is measured before it is placed.
    ///
    /// The cap is what keeps this sane on an iPad, where the popover is a small
    /// panel hanging off the toolbar and full width would be absurd: the screen
    /// term only ever binds on a phone.
    private static var width: CGFloat {
        let screen = UIScreen.main.bounds.width
        return min(max(screen - 40, 280), 420)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sun Clock")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .center)

            if let night = SunWindow.dayAndNight(at: Date(), coordinate: coordinate) {
                SunArcView(dayStart: night.dayStart, sunset: night.sunset, sunrise: night.sunrise)
                    .padding(.vertical, 2)

                Text("Most bats emerge soon after sunset and are most active for the first couple of hours, with a second, quieter burst before sunrise as they return to the roost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Names the actual window length rather than "15%" — a fraction is
                // the implementation, and what the user wants to know is how long
                // they have got.
                Text("This timer counts through those two windows, which for tonight is about \(SunWindowPill.compact(minutes: Int(SunWindow.activityWindowFraction * night.sunrise.timeIntervalSince(night.sunset) / 60))) after sunset and before sunrise. Night time is about \(SunWindowPill.compact(minutes: Int(night.sunrise.timeIntervalSince(night.sunset) / 60))) long tonight.")
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
        // As wide as the screen allows rather than a fixed 280: the arc is the
        // point of this popover and it is a wide drawing — three markers, two
        // half-waves and their labels — so every point of width buys legibility.
        // Capped so it does not sprawl on an iPad.
        .frame(width: Self.width, alignment: .leading)
    }

}

// MARK: - Sun arc

/// Tonight's shape of the sky, end to end: the day the user is standing in
/// rising to noon, dipping into sunset, and the night trough running on to the
/// next sunrise — with the sun (or the moon, once it is dark) riding the curve
/// at wherever `now` actually falls.
///
/// **The span is sunrise → sunset → sunrise, not sunset → sunrise, and that is
/// the fix.** The first cut of this drew the night only, so every daylight hour
/// — the hours someone is most likely to open the app and plan an evening —
/// clamped to the same end point, and the sun sat parked on the sunset marker
/// from dawn to dusk. Nothing moved until it was already dark. Spanning the day
/// too means the glyph is somewhere honest at every hour, and "how long until
/// sunset" is a distance you can see rather than a number to read.
///
/// Live, unlike the rest of the explainer: it advances on the minute through the
/// same `@State` tick the pill uses, never a `TimelineView` — see
/// `SunWindowPill.tick()` for why that distinction is load-bearing here.
private struct SunArcView: View {
    /// The sunrise that opened the current day — the left end of the curve.
    let dayStart: Date
    let sunset: Date
    /// The sunrise that ends the night — the right end.
    let sunrise: Date

    @State private var now = Date()

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()

    // MARK: Geometry

    /// y of the horizon line: the two sunrises, the sunset, and their labels all
    /// sit on it, the day dome above and the night trough below.
    private static let baseline: CGFloat = 46
    /// How far the curve travels either side of the horizon. Day and night share
    /// it so neither reads as the more important half.
    private static let amplitude: CGFloat = 32
    private static let totalHeight: CGFloat = 100
    /// Inset from each edge so an end label's full width doesn't clip against the
    /// popover's padding.
    private static let edgeInset: CGFloat = 20
    /// Gap between an anchor icon and where a horizon segment resumes.
    private static let anchorGap: CGFloat = 16
    /// Distance from the horizon to the centre of an anchor's time label.
    private static let labelOffset: CGFloat = 20
    /// How far from a glyph's centre the curve stops — a little wider than the
    /// glyph itself, so the line ends short of it rather than touching.
    private static let gapRadius: CGFloat = 13
    /// The same gap on the night half, which needs a touch more: the trough
    /// arrives at each anchor from below and shallowly, so it runs alongside the
    /// icon for longer than the day curve does before it clears it.
    private static let nightGapRadius: CGFloat = 15

    /// Where `now` sits, as a position on one of the two half-waves.
    /// Clamped: a popover held open across an event pins the glyph to the marker
    /// it is passing rather than running off the end of the curve.
    private var marker: (isDay: Bool, u: Double) {
        if now < sunset {
            let day = sunset.timeIntervalSince(dayStart)
            guard day > 0 else { return (true, 1) }
            return (true, min(max(now.timeIntervalSince(dayStart) / day, 0), 1))
        }
        let night = sunrise.timeIntervalSince(sunset)
        guard night > 0 else { return (false, 1) }
        return (false, min(max(now.timeIntervalSince(sunset) / night, 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            let leftX: CGFloat = Self.edgeInset
            let rightX: CGFloat = geo.size.width - Self.edgeInset
            // Half the width each, NOT the real day/night proportion. Unequal
            // halves make two visibly different curves — a squashed dome beside a
            // stretched trough — and the drawing stops reading as one sine wave,
            // which is the thing it is a picture of. The hours are on the labels;
            // what the shape has to carry is "up, over, down, under, up". The
            // glyph's position inside its own half is still the true fraction of
            // that half elapsed, so tracking is unaffected.
            let midX: CGFloat = (leftX + rightX) / 2
            let place = marker
            let markerPoint = Self.point(at: place.u,
                                         from: place.isDay ? leftX : midX,
                                         to: place.isDay ? midX : rightX,
                                         below: !place.isDay)

            horizonSegment("Day", from: leftX, to: midX)
            horizonSegment("Night", from: midX, to: rightX)

            // The curve is drawn with real gaps in it rather than covered or
            // punched through. A dark disc behind each glyph is a visible dark
            // disc, and `destinationOut` through a compositing group leaves a
            // grey one — the popover's material does not survive being cut out of
            // (Niall, 2026-09-02, twice). Leaving those samples out of the path
            // has nothing behind it to get wrong on any background.
            Path { path in
                for run in Self.gaps(in: Self.curve(from: leftX, to: midX, below: false)
                                       + Self.curve(from: midX, to: rightX, below: true),
                                     around: [CGPoint(x: leftX, y: Self.baseline),
                                              CGPoint(x: midX, y: Self.baseline),
                                              CGPoint(x: rightX, y: Self.baseline),
                                              markerPoint]) {
                    path.addLines(run)
                }
            }
            .stroke(Color.batAccent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

            Image(systemName: place.isDay ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 14))
                .foregroundStyle(place.isDay ? Color.batAccent : Color.primary)
                .position(markerPoint)

            // Times below the first two, above the last: the curve leaves the
            // right-hand sunrise from underneath, so a time below it would sit in
            // the night trough.
            endLabel(icon: "sunrise.fill", time: dayStart, above: false)
                .position(x: leftX, y: Self.baseline)
            endLabel(icon: "sunset.fill", time: sunset, above: false)
                .position(x: midX, y: Self.baseline)
            endLabel(icon: "sunrise.fill", time: sunrise, above: true)
                .position(x: rightX, y: Self.baseline)
        }
        .frame(height: Self.totalHeight)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .task { await tick() }
    }

    /// The horizon line for one half, split around its own label — no plate
    /// behind the text, which over the popover's material would read as a patch
    /// of grey rather than as a break in the line.
    private func horizonSegment(_ title: String, from x0: CGFloat, to x1: CGFloat) -> some View {
        HStack(spacing: 6) {
            rule
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
            rule
        }
        .frame(width: max(x1 - x0 - 2 * Self.anchorGap, 1))
        .position(x: (x0 + x1) / 2, y: Self.baseline)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.4))
            .frame(height: 1)
    }

    /// Icon on the horizon, its time stacked directly above or below it.
    ///
    /// Nothing behind either: the horizon and the curve are already broken around
    /// the icon by `hole(at:)`, and the times sit clear of both lines, so a plate
    /// would only be a dark shape on a page that has none.
    private func endLabel(icon: String, time: Date, above: Bool) -> some View {
        let time = Text(Self.clock.string(from: time))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        let glyph = Image(systemName: icon)
            .font(.system(size: 13))
            .foregroundStyle(Color.batAccent)

        // The icon holds the baseline whichever way the pair is stacked, so all
        // three anchors line up on the horizon rather than on their own bounds —
        // an offset rather than a stack, because an offset doesn't change the
        // view's own bounds and `position` is placing that.
        return ZStack {
            glyph
            time.offset(y: above ? -Self.labelOffset : Self.labelOffset)
        }
        .fixedSize()
    }

    /// Half a sine wave sampled into points — a quad curve can't hold the
    /// shoulders of a dome and a trough meeting cleanly at the horizon, and the
    /// sun has to ride the same geometry the stroke draws, which is far easier to
    /// evaluate from the closed form than from a Bézier.
    private static func curve(from x0: CGFloat, to x1: CGFloat, below: Bool) -> [CGPoint] {
        stride(from: 0.0, through: 1.0, by: 1.0 / 96).map {
            point(at: $0, from: x0, to: x1, below: below)
        }
    }

    /// Splits a sampled curve into the runs that stay clear of the glyphs,
    /// so the stroke breaks around each one instead of running through it.
    private static func gaps(in points: [CGPoint], around glyphs: [CGPoint]) -> [[CGPoint]] {
        var runs: [[CGPoint]] = []
        var run: [CGPoint] = []
        for p in points {
            let radius = p.y >= baseline ? nightGapRadius : gapRadius
            let clear = glyphs.allSatisfy { hypot($0.x - p.x, $0.y - p.y) > radius }
            if clear {
                run.append(p)
            } else if run.count > 1 {
                runs.append(run); run = []
            } else {
                run = []
            }
        }
        if run.count > 1 { runs.append(run) }
        return runs
    }

    private static func point(at u: Double, from x0: CGFloat, to x1: CGFloat, below: Bool) -> CGPoint {
        let offset = amplitude * sin(.pi * u)
        return CGPoint(x: x0 + CGFloat(u) * (x1 - x0),
                       y: baseline + (below ? offset : -offset))
    }

    // MARK: Tick

    /// Advances the sun on the minute for as long as the popover is open. Same
    /// `@State`-write mechanism as the pill, deliberately — see
    /// `SunWindowPill.tick()`.
    private func tick() async {
        while !Task.isCancelled {
            let instant = Date()
            now = instant
            let intoMinute = instant.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
            do { try await Task.sleep(for: .seconds(60 - intoMinute)) } catch { return }
        }
    }

    /// One sentence for VoiceOver: the three markers are meaningless read out as
    /// separate glyphs and times.
    private var accessibilityLabel: String {
        let sunsetTime = Self.clock.string(from: sunset)
        let sunriseTime = Self.clock.string(from: sunrise)
        if now < sunset {
            let mins = max(0, Int((sunset.timeIntervalSince(now) / 60).rounded(.up)))
            return "Daytime. Sunset at \(sunsetTime), in \(SunWindowPill.spoken(minutes: mins)). Sunrise at \(sunriseTime)."
        }
        let mins = max(0, Int((sunrise.timeIntervalSince(now) / 60).rounded(.up)))
        return "Night. Sunset was at \(sunsetTime). Sunrise at \(sunriseTime), in \(SunWindowPill.spoken(minutes: mins))."
    }
}

// MARK: - Giving the slot back

/// A screen's request to have the sun clock taken out of its leading toolbar
/// slot for a while.
///
/// The pill is declared once, on every section's stack root (`ContentView`'s
/// `sectionScreen`), so the screens themselves have no say over it — and one of
/// them needs one: the sessions list puts Delete in the same leading slot while
/// a selection is running. A preference travels up from the screen to the stack
/// that owns the toolbar, which is the direction this information has to go.
///
/// `||` rather than last-wins, so a nested view asking for the slot is not
/// overruled by a sibling that doesn't care.
struct SunClockHiddenKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    /// Ask for the sun clock to be dropped from this screen's toolbar while
    /// `hidden` is true.
    func hidesSunClock(_ hidden: Bool) -> some View {
        preference(key: SunClockHiddenKey.self, value: hidden)
    }
}
