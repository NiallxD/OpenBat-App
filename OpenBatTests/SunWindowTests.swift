//
//  SunWindowTests.swift
//  OpenBatTests
//
//  The four-state night machine behind the detector's sun pill. Tested here
//  rather than through the UI because every one of its transitions is a
//  boundary in time, and none of them is reachable by tapping anything.
//
//  Deliberately NOT a test of the astronomy: the phases are asserted at instants
//  built *relative to* whatever `SunTimes` says the sun does, so a future
//  refinement of the sunrise equation cannot break them. One test does check the
//  astronomy, loosely, against a published value.
//
//  The window boundaries are likewise asserted as *fractions of the night these
//  dates actually have*, never as clock times — the whole point of
//  `activityWindowFraction` is that the boundary moves with the season, so a test
//  that hard-coded "two hours before sunrise" would be asserting the bug the
//  fraction replaced.
//

import Testing
import Foundation
import CoreLocation
@testable import OpenBat

struct SunWindowTests {

    /// London, and a calendar in London's own zone. `SunWindow` itself needs no
    /// calendar any more; this one is only used to BUILD test instants ("00:30 on
    /// the midsummer night") and to assert that a boundary is not the calendar
    /// day's, which is the rule the fraction replaced.
    private let london = CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }

    /// A winter night, deliberately the longest available: at ~16 hours its 15%
    /// windows are ~2.4 h, which puts the end of the evening window (~18:20) hours
    /// before local midnight — so a test can tell the fraction and the old
    /// midnight cut apart.
    private func decemberSun() -> (sunrise: Date, sunset: Date) { sun(month: 12, day: 10) }

    /// Sunrise and sunset at London on the given 2026 date.
    private func sun(month: Int, day: Int) -> (sunrise: Date, sunset: Date) {
        var c = DateComponents()
        c.year = 2026; c.month = month; c.day = day; c.hour = 12
        c.timeZone = TimeZone(identifier: "Europe/London")
        let noon = calendar.date(from: c)!
        let (sunrise, sunset) = SunTimes.sunriseSunset(for: london, on: noon)
        return (sunrise!, sunset!)
    }

    private func phase(_ now: Date) -> SunWindow.Phase? {
        SunWindow.phase(at: now, coordinate: london)
    }

    /// The night `sunset` opens: its end, and how long each activity window is.
    private func night(from sunset: Date) -> (sunrise: Date, window: TimeInterval) {
        let sunrise = sunriseAfter(sunset)
        return (sunrise, sunrise.timeIntervalSince(sunset) * SunWindow.activityWindowFraction)
    }

    // MARK: The four states

    @Test func daylightShowsTheComingSunset() {
        let sun = decemberSun()
        let midAfternoon = sun.sunset.addingTimeInterval(-2 * 3600)
        #expect(phase(midAfternoon) == .beforeSunset(sunset: sun.sunset))
    }

    @Test func theEveningWindowCountsUpFromSunset() {
        let sun = decemberSun()
        let n = night(from: sun.sunset)
        // Just inside the window, and at its very edge.
        #expect(phase(sun.sunset.addingTimeInterval(60)) == .afterSunset(sunset: sun.sunset))
        #expect(phase(sun.sunset.addingTimeInterval(n.window - 60)) == .afterSunset(sunset: sun.sunset))
    }

    /// Past the evening window the pill stops counting and names the sunrise —
    /// and the boundary is a share of the night, NOT midnight. This december
    /// night is long enough that the two are far apart, which is what makes the
    /// distinction visible: 15% of a ~16 h night is ~2.4 h, so the switch happens
    /// around 18:20, hours before the date rolls.
    @Test func pastTheEveningWindowShowsTheSunriseTime() {
        let sun = decemberSun()
        let n = night(from: sun.sunset)
        let justPast = sun.sunset.addingTimeInterval(n.window + 60)

        #expect(phase(justPast) == .night(sunrise: n.sunrise))
        // The regression guard for the rule this replaced: still the same
        // calendar day as the sunset, and already out of the evening window.
        #expect(calendar.isDate(justPast, inSameDayAs: sun.sunset))
    }

    @Test func theDawnWindowCountsDownToSunrise() {
        let sun = decemberSun()
        let n = night(from: sun.sunset)

        // Just outside the window is still a plain time; just inside it counts.
        #expect(phase(n.sunrise.addingTimeInterval(-n.window - 60))
                == .night(sunrise: n.sunrise))
        #expect(phase(n.sunrise.addingTimeInterval(-n.window + 60))
                == .dawnCountdown(sunrise: n.sunrise))
        #expect(phase(n.sunrise.addingTimeInterval(-5 * 60))
                == .dawnCountdown(sunrise: n.sunrise))
    }

    /// A minute past sunrise is daylight again, and the cycle restarts on that
    /// evening's sunset.
    @Test func pastSunriseReturnsToTheSunsetSide() {
        let sun = decemberSun()
        let afterSunrise = night(from: sun.sunset).sunrise.addingTimeInterval(120)
        guard case .beforeSunset(let sunset)? = phase(afterSunrise) else {
            Issue.record("expected daylight, got \(String(describing: phase(afterSunrise)))")
            return
        }
        #expect(sunset > afterSunrise)
    }

    /// Only the two counting states are drawn with a filled glyph.
    @Test func activityWindowsAreTheTwoCountingStates() {
        let now = Date()
        #expect(SunWindow.Phase.afterSunset(sunset: now).isActivityWindow)
        #expect(SunWindow.Phase.dawnCountdown(sunrise: now).isActivityWindow)
        #expect(!SunWindow.Phase.beforeSunset(sunset: now).isActivityWindow)
        #expect(!SunWindow.Phase.night(sunrise: now).isActivityWindow)
    }

    // MARK: The windows scale with the night

    /// The reason the fraction exists. A UK midsummer night is less than half the
    /// length of a midwinter one, so its windows must be shorter — and crucially,
    /// midsummer's 00:30 (three hours past sunset, four short of sunrise) must
    /// read as the quiet middle rather than as either window. Under the fixed-lead
    /// rule this replaced, that instant was still "counting up from sunset" purely
    /// because it was the same calendar day.
    @Test func windowsShrinkWithTheNightAndMidsummerMidnightIsQuiet() {
        let june = sun(month: 6, day: 21)
        let december = decemberSun()
        let juneNight = night(from: june.sunset)
        let decemberNight = night(from: december.sunset)

        #expect(juneNight.window < decemberNight.window / 1.8)

        // 00:30 on the midsummer night: outside both windows.
        let halfPastMidnight = calendar.date(
            byAdding: .minute, value: 30,
            to: calendar.date(byAdding: .day, value: 1,
                              to: calendar.startOfDay(for: june.sunset))!)!
        #expect(phase(halfPastMidnight) == .night(sunrise: juneNight.sunrise))
    }

    /// The three states inside one night are contiguous and in order: no instant
    /// between sunset and sunrise falls outside them, and none is `nil`.
    @Test func theNightIsFullyCoveredInOrder() {
        let sun = decemberSun()
        let n = night(from: sun.sunset)
        let total = n.sunrise.timeIntervalSince(sun.sunset)

        var seen: [String] = []
        for step in 0...100 {
            let now = sun.sunset.addingTimeInterval(total * Double(step) / 100 + 30)
            guard now < n.sunrise else { break }
            let name: String
            switch phase(now) {
            case .afterSunset:   name = "evening"
            case .night:         name = "middle"
            case .dawnCountdown: name = "dawn"
            case .beforeSunset:  name = "daylight"   // would be a failure below
            case nil:            name = "nil"
            }
            if seen.last != name { seen.append(name) }
        }
        #expect(seen == ["evening", "middle", "dawn"])
    }

    // MARK: The explainer's view of the night

    /// `night(at:)` feeds the explainer popover and `phase(at:)` feeds the pill,
    /// and they pick their events separately — so the thing to pin down is that
    /// they never disagree about WHICH night is meant. Checked from both sides of
    /// sunset, since that is where "tonight" changes meaning.
    @Test func explainerAndPillAgreeOnTheSameNight() {
        let sun = decemberSun()
        let expected = night(from: sun.sunset)

        for (offset, label) in [(-3 * 3600.0, "afternoon"), (60.0, "just after sunset"),
                                (6 * 3600.0, "middle of the night")] {
            let now = sun.sunset.addingTimeInterval(offset)
            guard let n = SunWindow.night(at: now, coordinate: london) else {
                Issue.record("no night at \(label)")
                continue
            }
            #expect(n.sunset == sun.sunset, "sunset differs at \(label)")
            #expect(n.sunrise == expected.sunrise, "sunrise differs at \(label)")
            #expect(n.window == expected.window, "window differs at \(label)")
        }
    }

    /// In daylight it must name the night AHEAD, not the one just finished.
    @Test func explainerNamesTheComingNightDuringTheDay() {
        let sun = decemberSun()
        let breakfast = sun.sunrise.addingTimeInterval(3600)
        guard let n = SunWindow.night(at: breakfast, coordinate: london) else {
            Issue.record("no night in daylight")
            return
        }
        #expect(n.sunset > breakfast)
        #expect(n.sunrise > n.sunset)
    }

    // MARK: The arc's span

    /// The bug the arc was rebuilt for: drawn across sunset→sunrise only, every
    /// daylight hour clamped to the same end and the sun sat parked on the sunset
    /// marker all day. The span has to CONTAIN `now` at every hour, which is what
    /// lets the glyph move.
    @Test func theArcSpanContainsTheMomentItIsDrawnFor() {
        let sun = decemberSun()
        let hours: [(Double, String)] = [(-7 * 3600, "morning"), (-4 * 3600, "midday"),
                                         (-30 * 60, "just before sunset"), (60, "just after sunset"),
                                         (6 * 3600, "middle of the night")]
        for (offset, label) in hours {
            let now = sun.sunset.addingTimeInterval(offset)
            guard let span = SunWindow.dayAndNight(at: now, coordinate: london) else {
                Issue.record("no span at \(label)")
                continue
            }
            #expect(span.dayStart <= now, "span starts after now at \(label)")
            #expect(span.sunrise >= now, "span ends before now at \(label)")
            #expect(span.dayStart < span.sunset && span.sunset < span.sunrise,
                    "span out of order at \(label)")
        }
    }

    /// And it is the SAME night the pill is counting against — the arc and the
    /// readout above it must not describe different evenings.
    @Test func theArcSpanAgreesWithTheNight() {
        let sun = decemberSun()
        for offset in [-4 * 3600.0, 60.0, 6 * 3600.0] {
            let now = sun.sunset.addingTimeInterval(offset)
            let night = SunWindow.night(at: now, coordinate: london)
            let span = SunWindow.dayAndNight(at: now, coordinate: london)
            #expect(span?.sunset == night?.sunset)
            #expect(span?.sunrise == night?.sunrise)
        }
    }

    /// The day the arc draws is the one leading into that night, not the one
    /// before it: a December day in London is ~8 hours, never 32.
    @Test func theArcDayIsTheOneEndingAtThatSunset() {
        let sun = decemberSun()
        guard let span = SunWindow.dayAndNight(at: sun.sunset.addingTimeInterval(-4 * 3600),
                                               coordinate: london) else {
            Issue.record("no span in daylight")
            return
        }
        #expect(span.dayStart == sun.sunrise)
        #expect(span.sunset.timeIntervalSince(span.dayStart) < 24 * 3600)
    }

    @Test func polarNightHasNoSpanEither() {
        let svalbard = CLLocationCoordinate2D(latitude: 78.22, longitude: 15.65)
        var c = DateComponents()
        c.year = 2026; c.month = 12; c.day = 21; c.hour = 12
        c.timeZone = TimeZone(identifier: "UTC")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(SunWindow.dayAndNight(at: utc.date(from: c)!, coordinate: svalbard) == nil)
    }

    @Test func polarNightHasNoNightForTheExplainerEither() {
        let svalbard = CLLocationCoordinate2D(latitude: 78.22, longitude: 15.65)
        var c = DateComponents()
        c.year = 2026; c.month = 12; c.day = 21; c.hour = 12
        c.timeZone = TimeZone(identifier: "UTC")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(SunWindow.night(at: utc.date(from: c)!, coordinate: svalbard) == nil)
    }

    // MARK: Time zones and the poles

    // MARK: Time zones and the poles

    /// The regression this file exists for. `SunTimes` resolves which solar day
    /// it means from the UTC date it is handed, so anywhere far from UTC the
    /// evening belongs to a different UTC day than the local one — and asking it
    /// for "today" gave the wrong night's events. `SunWindow` reads a three-day
    /// window and picks the events bracketing `now` instead, so an evening in New
    /// York must still read as an evening.
    @Test func eveningFarFromUTCIsStillAnEvening() {
        let newYork = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!

        var c = DateComponents()
        c.year = 2026; c.month = 12; c.day = 10; c.hour = 12
        c.timeZone = TimeZone(identifier: "America/New_York")
        let noon = cal.date(from: c)!
        let sunset = SunTimes.sunriseSunset(for: newYork, on: noon).sunset!

        let evening = sunset.addingTimeInterval(30 * 60)
        #expect(SunWindow.phase(at: evening, coordinate: newYork) == .afterSunset(sunset: sunset))
    }

    /// Polar night: no sun event to anchor to, so the pill shows nothing rather
    /// than a made-up time.
    @Test func polarNightHasNoPhase() {
        let svalbard = CLLocationCoordinate2D(latitude: 78.22, longitude: 15.65)
        var c = DateComponents()
        c.year = 2026; c.month = 12; c.day = 21; c.hour = 12
        c.timeZone = TimeZone(identifier: "UTC")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let midwinterNoon = utc.date(from: c)!

        #expect(SunWindow.phase(at: midwinterNoon, coordinate: svalbard) == nil)
    }

    // MARK: The astronomy, loosely

    /// One sanity check that the equation underneath is pointed at the right sky:
    /// London sunset on 10 December 2026 is published as about 15:52 GMT. A
    /// ten-minute tolerance — this is here to catch a sign error or a wrong
    /// hemisphere, not to pin the algorithm's precision.
    @Test func londonDecemberSunsetIsAboutFourInTheAfternoon() {
        let sunset = decemberSun().sunset
        let parts = calendar.dateComponents([.hour, .minute], from: sunset)
        let minutesIntoDay = parts.hour! * 60 + parts.minute!
        #expect(abs(minutesIntoDay - (15 * 60 + 52)) <= 10)
    }

    // MARK: Helpers

    /// The first sunrise strictly after `date`, taken from `SunTimes` directly so
    /// the expectation is independent of `SunWindow`'s own event picking.
    private func sunriseAfter(_ date: Date) -> Date {
        for offset in 0...2 {
            let probe = date.addingTimeInterval(Double(offset) * 86_400)
            if let sunrise = SunTimes.sunriseSunset(for: london, on: probe).sunrise,
               sunrise > date {
                return sunrise
            }
        }
        fatalError("no sunrise found after \(date)")
    }
}
