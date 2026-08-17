//
//  SunTimes.swift
//  OpenBat
//
//  Sunrise/sunset (and civil dusk/dawn) from latitude, longitude and date —
//  the NOAA/Wikipedia "sunrise equation", computed entirely on-device.
//
//  No network call and no request budget: WeatherKit's sun-event data is
//  rate-limited per developer account (shared across every user), which is
//  the wrong shape for a value every session start needs and that a field
//  app with no signal still has to produce. This is closed-form astronomy —
//  latitude, longitude, day of year in, two timestamps out — accurate to
//  about a minute, which is what's needed for "is it near dusk".
//

import CoreLocation
import Foundation

enum SunTimes {

    /// Standard geometric horizon, corrected for atmospheric refraction and
    /// the sun's apparent radius — the zenith angle that defines sunrise/sunset.
    static let sunriseSunsetZenith = 90.833

    /// Civil twilight — the sun 6° below the horizon. Closer to when bats
    /// actually start emerging than sunset itself.
    static let civilTwilightZenith = 96.0

    /// Sunrise and sunset for the given coordinate on the given date, as
    /// absolute `Date`s (convert with the caller's `TimeZone` for display).
    /// `nil` for either edge means the sun doesn't cross that zenith that
    /// day — polar day or polar night at that latitude/season.
    static func sunriseSunset(for coordinate: CLLocationCoordinate2D, on date: Date) -> (sunrise: Date?, sunset: Date?) {
        times(for: coordinate, on: date, zenith: sunriseSunsetZenith)
    }

    /// Civil dawn/dusk — see `civilTwilightZenith`.
    static func civilTwilight(for coordinate: CLLocationCoordinate2D, on date: Date) -> (dawn: Date?, dusk: Date?) {
        times(for: coordinate, on: date, zenith: civilTwilightZenith)
    }

    /// The general form both convenience methods above call: when the sun
    /// crosses `zenith` degrees, ascending (first) and descending (second).
    static func times(for coordinate: CLLocationCoordinate2D, on date: Date, zenith: Double) -> (Date?, Date?) {
        let jd = julianDayNumber(for: date)
        let lw = -coordinate.longitude   // the equation wants west-positive longitude
        let phi = coordinate.latitude * .pi / 180
        let zenithRad = zenith * .pi / 180

        // Mean solar noon, then the sun's position at that instant.
        let nStar = jd - 2451545.0 + 0.0009 - lw / 360.0
        let n = nStar.rounded()
        let solarNoon = 2451545.0 + 0.0009 + lw / 360.0 + n

        let meanAnomalyDeg = (357.5291 + 0.98560028 * (solarNoon - 2451545.0)).truncatingRemainder(dividingBy: 360)
        let m = meanAnomalyDeg * .pi / 180
        let centerDeg = 1.9148 * sin(m) + 0.0200 * sin(2 * m) + 0.0003 * sin(3 * m)
        let eclipticLongitudeDeg = (meanAnomalyDeg + 102.9372 + centerDeg + 180).truncatingRemainder(dividingBy: 360)
        let lambda = eclipticLongitudeDeg * .pi / 180

        let transit = solarNoon + 0.0053 * sin(m) - 0.0069 * sin(2 * lambda)
        let declination = asin(sin(lambda) * sin(23.4397 * .pi / 180))

        let cosHourAngle = (cos(zenithRad) - sin(phi) * sin(declination)) / (cos(phi) * cos(declination))
        guard cosHourAngle >= -1, cosHourAngle <= 1 else {
            // Sun never reaches (or never leaves) this zenith today.
            return (nil, nil)
        }
        let hourAngleDeg = acos(cosHourAngle) * 180 / .pi

        // `Self.` is required, not stylistic: this function's own `date`
        // parameter shadows the static helper below, so the unqualified call
        // resolves to the `Date` value and fails to compile.
        return (Self.date(fromJulianDay: transit - hourAngleDeg / 360),
                Self.date(fromJulianDay: transit + hourAngleDeg / 360))
    }

    /// Built ONCE. `Calendar(identifier:)` sets up an ICU calendar and is
    /// expensive — this used to be constructed, along with a `TimeZone`, on every
    /// call to `julianDayNumber`, which is three times per `SunWindow.phase`, which
    /// is once per evaluation of any view showing the sun clock. It is immutable
    /// after this, so sharing it is safe.
    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Julian day number for the calendar date `date` falls on in UTC (the
    /// standard Fliegel & Van Flandern formula) — the algorithm above only
    /// needs which day it is, not the time within it.
    private static func julianDayNumber(for date: Date) -> Double {
        let c = utcCalendar.dateComponents([.year, .month, .day], from: date)
        let y = c.year!, m = c.month!, d = c.day!
        let a = (14 - m) / 12
        let y2 = y + 4800 - a
        let m2 = m + 12 * a - 3
        let jdn = d + (153 * m2 + 2) / 5 + 365 * y2 + y2 / 4 - y2 / 100 + y2 / 400 - 32045
        return Double(jdn)
    }

    private static func date(fromJulianDay jd: Double) -> Date {
        Date(timeIntervalSince1970: (jd - 2440587.5) * 86400)
    }
}
