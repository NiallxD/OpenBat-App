//
//  LocationProvider.swift
//  OpenBat
//
//  CoreLocation wrapper that drives a session's GPS course. While a "New Session" is
//  detecting, it streams fixes into the active session's track (throttled to ~5 m /
//  ~3 s breadcrumbs) and reverse-geocodes the first fix into the session title.
//
//  Background capable: tracking escalates to "Always" authorization and enables
//  background location updates so the course keeps recording with the phone locked
//  (requires the `location` UIBackgroundMode — set in the target's Info.plist keys).
//

import CoreLocation
import Observation

@Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {

    private(set) var currentCoordinate: CLLocationCoordinate2D?
    private(set) var authorization: CLAuthorizationStatus = .notDetermined

    /// Set by ContentView so fixes append to the active session's track / title.
    @ObservationIgnored weak var store: ClassificationStore?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let geocoder = CLGeocoder()
    @ObservationIgnored private var tracking = false
    @ObservationIgnored private var lastTrackPoint: CLLocation?
    @ObservationIgnored private var pendingGeocodeSessionID: UUID?
    @ObservationIgnored private var pendingRegionFix = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .otherNavigation
        authorization = manager.authorizationStatus
    }

    /// One-shot fix for region-based feature suggestions (e.g. "a model is available for
    /// your area") — deliberately lighter weight than `startTracking`: only requests
    /// when-in-use authorization (never escalates to Always) and asks for a single fix
    /// rather than continuous updates. Safe to call repeatedly; a no-op once denied.
    func requestRegionFix() {
        switch manager.authorizationStatus {
        case .notDetermined:
            pendingRegionFix = true
            manager.requestWhenInUseAuthorization()   // fix follows once granted (delegate below)
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break                                      // denied/restricted — no fix
        }
    }

    /// Begin recording a course for the active session. Escalates to Always so the
    /// track keeps recording with the phone locked, and geocodes the first fix.
    func startTracking(geocodeSessionID sessionID: UUID?) {
        tracking = true
        lastTrackPoint = nil
        pendingGeocodeSessionID = sessionID
        requestAndStart()
    }

    func stopTracking() {
        tracking = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    private func requestAndStart() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()   // fixes begin once granted (delegate below)
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            beginUpdates()
        case .authorizedAlways:
            beginUpdates()
        default:
            break                                      // denied/restricted — no track
        }
    }

    private func beginUpdates() {
        // `allowsBackgroundLocationUpdates = true` THROWS unless UIBackgroundModes contains
        // "location"; only enable background updates when that mode is actually declared, so
        // a misconfigured build degrades to foreground tracking instead of crashing.
        if Self.hasLocationBackgroundMode {
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = false
        }
        manager.startUpdatingLocation()
    }

    private static let hasLocationBackgroundMode: Bool = {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("location") ?? false
    }()

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if pendingRegionFix {
            pendingRegionFix = false
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
            default: break
            }
        }
        guard tracking else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
            beginUpdates()
        case .authorizedAlways:
            beginUpdates()
        default:
            break
        }
    }

    /// Fixes worse than this (metres) are rejected outright — a negative or very
    /// large `horizontalAccuracy` is common on the first fix or two right after
    /// `startUpdatingLocation()`, before GPS has locked past a coarse cell/wifi
    /// estimate. Accepting those made `currentCoordinate` (and everything it feeds:
    /// GUANO tagging, session pins, breadcrumbs, reverse-geocoded titles) noticeably
    /// inaccurate right at the start of a session.
    private let maxAcceptableAccuracyMeters: Double = 50

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        guard loc.horizontalAccuracy > 0, loc.horizontalAccuracy <= maxAcceptableAccuracyMeters else { return }
        currentCoordinate = loc.coordinate
        guard tracking else { return }

        // Throttle: a breadcrumb only after ~5 m moved or ~3 s elapsed.
        if let last = lastTrackPoint {
            let moved = loc.distance(from: last)
            let elapsed = loc.timestamp.timeIntervalSince(last.timestamp)
            guard moved >= 5 || elapsed >= 3 else { return }
        }
        lastTrackPoint = loc
        store?.appendTrackPoint(TrackPoint(lat: loc.coordinate.latitude,
                                           lon: loc.coordinate.longitude, t: loc.timestamp))
        geocodeTitleIfNeeded(loc)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { }

    /// On the first good fix of a session, reverse-geocode a place name into the title.
    private func geocodeTitleIfNeeded(_ loc: CLLocation) {
        guard let id = pendingGeocodeSessionID else { return }
        pendingGeocodeSessionID = nil
        geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            guard let self,
                  let place = placemarks?.first,
                  let name = place.locality ?? place.name ?? place.administrativeArea
            else { return }
            self.store?.setPlaceName(name, for: id)
        }
    }
}
