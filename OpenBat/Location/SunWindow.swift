//
//  SunWindow.swift
//  OpenBat
//
//  Which part of the bat-activity night we are in, as one value — the state
//  machine behind `SunWindowPill`.
//
//  Bats are busiest in the few hours after sunset and again in the hours before
//  sunrise, so a sun clock is worth a permanent slot in the detector's nav bar.
//  What that slot should say changes through the night:
//
//    • daylight            → when the sun sets
//    • first 15% of night  → how long ago it set, counting up ("+1h 45m")
//    • middle of night     → when the sun rises (a plain reference)
//    • last 15% of night   → how long until it rises, counting down ("in 1h 45m")
//
//  **The two windows are fractions of the night, not fixed hours** (Niall's
//  revision, 2026-08-16). The first cut of this counted up until local midnight
//  and down for a fixed two hours before sunrise, and midnight was doing the job
//  badly: it is a calendar accident, not a fact about the night. On a UK June
//  night — sunset 21:22, sunrise 04:44 — 00:30 is three hours past sunset and
//  four short of sunrise, and the old rule had already stopped counting purely
//  because the date had rolled.
//
//  Measuring each window against the night it belongs to fixes that at every
//  latitude and season, and removes the calendar from the problem completely:
//  there is no `Calendar`, no time zone and no DST question anywhere in this file
//  now. It also loses nothing biologically — 15% of a spring or autumn night is
//  around 1½ hours, close to the fixed lead it replaced.
//
//  Everything here is pure: dates and a coordinate in, one enum out, no clock
//  and no location manager. `SunWindowTests` drives it at chosen instants.
//

import CoreLocation
import Foundation

enum SunWindow {

    /// Each activity window is this fraction of the night it belongs to — the
    /// first 15% after sunset, and the last 15% before sunrise.
    ///
    /// A *fraction* rather than a fixed number of hours because the night itself
    /// changes length by a factor of two over a UK year, and a constant lead is
    /// wrong at one end of that or the other. In practice it lands close to the
    /// 2 hours this started as: a 12-hour equinox night gives 1h 48m each side, a
    /// 9-hour August night 1h 21m.
    static let activityWindowFraction: Double = 0.15

    /// Where `now` sits in the night. Each case carries the sun event it is
    /// measured against, so the view formats without recomputing anything.
    enum Phase: Equatable {
        /// Daylight (or before tonight's sunset, at least). The sun sets then.
        case beforeSunset(sunset: Date)
        /// Inside the first `activityWindowFraction` of the night — the evening
        /// emergence window, counted up from the sunset that opened it.
        case afterSunset(sunset: Date)
        /// The quiet middle of the night: past the evening window, not yet into
        /// the dawn one. Shows when the night ends.
        case night(sunrise: Date)
        /// Inside the last `activityWindowFraction` of the night — counted down
        /// to the sunrise that closes it.
        case dawnCountdown(sunrise: Date)

        /// True for the two windows bats are actually busiest in. Drives the
        /// pill's filled-vs-hollow glyph, and nothing else.
        var isActivityWindow: Bool {
            switch self {
            case .afterSunset, .dawnCountdown: true
            case .beforeSunset, .night:        false
            }
        }
    }

    /// `nil` when there is nothing honest to show: no sun event to anchor to at
    /// this latitude and season (polar day or polar night). The pill renders
    /// nothing rather than inventing a time.
    ///
    /// No `Calendar` and no time zone anywhere in here — the boundaries are all
    /// positions within one measured night, so the local calendar has nothing to
    /// contribute. That is what replacing the midnight cut with a fraction bought:
    /// the DST and time-zone questions stopped existing rather than being handled.
    static func phase(at now: Date, coordinate: CLLocationCoordinate2D) -> Phase? {
        let (sunrises, sunsets) = solarEvents(around: now, coordinate: coordinate)

        // Day or night is decided by which kind of event happened most recently,
        // never by clock hour — that holds at any latitude and in any time zone.
        let lastSunset = sunsets.last { $0 <= now }
        let lastSunrise = sunrises.last { $0 <= now }
        let isNight = lastSunset != nil && (lastSunrise == nil || lastSunset! > lastSunrise!)

        guard isNight, let sunset = lastSunset else {
            guard let nextSunset = sunsets.first(where: { $0 > now }) else { return nil }
            return .beforeSunset(sunset: nextSunset)
        }

        // Both ends of THIS night, so each window is a fraction of the night the
        // user is actually standing in rather than of an average one.
        guard let sunrise = sunrises.first(where: { $0 > now }) else { return nil }
        let window = sunrise.timeIntervalSince(sunset) * activityWindowFraction

        if now.timeIntervalSince(sunset) <= window { return .afterSunset(sunset: sunset) }
        if sunrise.timeIntervalSince(now) <= window { return .dawnCountdown(sunrise: sunrise) }
        return .night(sunrise: sunrise)
    }

    /// Both ends of the night the pill is currently describing — the one in
    /// progress, or tonight's if it is still daylight — plus how long each of its
    /// activity windows is.
    ///
    /// For the explainer popover, which shows the pair; `phase` only ever carries
    /// the single event it is measuring against. Same event-picking as `phase`, so
    /// the two cannot disagree about which night is meant.
    static func night(at now: Date, coordinate: CLLocationCoordinate2D)
        -> (sunset: Date, sunrise: Date, window: TimeInterval)? {
        let (sunrises, sunsets) = solarEvents(around: now, coordinate: coordinate)

        let lastSunset = sunsets.last { $0 <= now }
        let lastSunrise = sunrises.last { $0 <= now }
        let isNight = lastSunset != nil && (lastSunrise == nil || lastSunset! > lastSunrise!)

        // Mid-night: the sunset behind us. Daylight: the one ahead.
        guard let sunset = isNight ? lastSunset : sunsets.first(where: { $0 > now }),
              let sunrise = sunrises.first(where: { $0 > sunset })
        else { return nil }

        return (sunset, sunrise,
                sunrise.timeIntervalSince(sunset) * activityWindowFraction)
    }

    /// The whole arc the explainer draws: the daylight that leads into tonight,
    /// then tonight itself — the sunrise that opened the current day, the sunset
    /// that closes it, and the sunrise that ends the night.
    ///
    /// `night` alone is not enough to draw a sun that *tracks*: in daylight every
    /// instant is simply "before sunset", and a curve spanning only sunset→sunrise
    /// has nowhere to put it but parked on one end. The day is the part of the
    /// span the user is standing in for most of the hours they might open this.
    ///
    /// `nil` on the same terms as `night`, plus when the day's opening sunrise is
    /// outside the three-day event window (polar edges).
    static func dayAndNight(at now: Date, coordinate: CLLocationCoordinate2D)
        -> (dayStart: Date, sunset: Date, sunrise: Date)? {
        guard let night = night(at: now, coordinate: coordinate) else { return nil }
        let (sunrises, _) = solarEvents(around: now, coordinate: coordinate)
        guard let dayStart = sunrises.last(where: { $0 < night.sunset }) else { return nil }
        return (dayStart, night.sunset, night.sunrise)
    }

    /// Sunrises and sunsets for the solar day around `now` and its two
    /// neighbours, ascending.
    ///
    /// Three days, rather than asking for "today", because `SunTimes` resolves
    /// which solar day it means from the UTC date it is handed — so near either
    /// end of a day, in a time zone far from UTC, "today" is a day out. Reading a
    /// window and then picking the events that actually bracket `now` sidesteps
    /// the question: whichever day each event belongs to, the nearest one either
    /// side of `now` is the one we want.
    /// **Memoised, and that is not an optimisation — it is what makes this safe to
    /// call from a view body.** The answer only changes once a day, but the work is
    /// three runs of the sunrise equation plus the `Calendar` arithmetic under them,
    /// and `phase` is called on *every* evaluation of any view showing the sun
    /// clock. A `TimelineView` re-runs its content whenever its parent invalidates,
    /// not only when its own schedule fires, and the sun pill's parent is the
    /// detector's toolbar — chrome that re-evaluates with the live audio stats. So
    /// "once a minute" was never the real call rate.
    private static var cache: (key: CacheKey, events: (sunrises: [Date], sunsets: [Date]))?

    /// Coordinate rounded to ~1 km and time to the day. Sun times do not
    /// meaningfully differ across a kilometre, and rounding stops ordinary GPS
    /// jitter from evicting the entry on every fix.
    private struct CacheKey: Equatable {
        let day: Int, lat: Int, lon: Int
        init(_ now: Date, _ coordinate: CLLocationCoordinate2D) {
            day = Int((now.timeIntervalSince1970 / 86_400).rounded(.down))
            lat = Int((coordinate.latitude * 100).rounded())
            lon = Int((coordinate.longitude * 100).rounded())
        }
    }

    private static func solarEvents(around now: Date,
                                    coordinate: CLLocationCoordinate2D) -> (sunrises: [Date], sunsets: [Date]) {
        let key = CacheKey(now, coordinate)
        if let cache, cache.key == key { return cache.events }

        var sunrises: [Date] = []
        var sunsets: [Date] = []
        for dayOffset in -1...1 {
            let (sunrise, sunset) = SunTimes.sunriseSunset(
                for: coordinate,
                on: now.addingTimeInterval(Double(dayOffset) * 86_400))
            if let sunrise { sunrises.append(sunrise) }
            if let sunset { sunsets.append(sunset) }
        }
        let events = (sortedDeduped(sunrises), sortedDeduped(sunsets))

        // One entry, not a dictionary: there is exactly one place the user is
        // standing, and the day rolls over once. Keying on the UTC day means the
        // window is recomputed at UTC midnight rather than at local midnight —
        // harmless, because the window is three days wide and always contains the
        // events either side of `now`.
        cache = (key, events)
        return events
    }

    /// Two of the three days above can resolve to the same solar day, so the
    /// same event can arrive twice. Bucketed to the minute: distinct events are
    /// ~24 h apart, so nothing real collapses.
    private static func sortedDeduped(_ dates: [Date]) -> [Date] {
        var seen = Set<Int>()
        return dates.sorted().filter { seen.insert(Int($0.timeIntervalSince1970 / 60)).inserted }
    }
}
