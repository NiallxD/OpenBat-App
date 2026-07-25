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

    /// The OS-native per-app "Precise Location" toggle — read by
    /// UploadConversionPipeline to decide whether the upload copy's GUANO
    /// location gets fuzzed. Not something this app has any custom UI for;
    /// the system permission dialog/Settings own this choice entirely.
    var accuracyAuthorization: CLAccuracyAuthorization { manager.accuracyAuthorization }

    /// Set by ContentView so fixes append to the active session's track / title.
    @ObservationIgnored weak var store: ClassificationStore?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let geocoder = CLGeocoder()
    @ObservationIgnored private var tracking = false
    @ObservationIgnored private var lastTrackPoint: CLLocation?
    @ObservationIgnored private var pendingGeocodeSessionID: UUID?
    @ObservationIgnored private var pendingRegionFix = false
    @ObservationIgnored private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .otherNavigation
        authorization = manager.authorizationStatus
    }

    /// Requests when-in-use authorization and suspends until the OS dialog has actually
    /// been resolved (granted/denied/restricted) — used by onboarding so the soft-ask
    /// screen stays on screen behind the real system alert instead of advancing the
    /// instant the request fires. A no-op wait (returns immediately) if authorization
    /// was already decided before this is called.
    func requestAuthorizationDecision() async -> CLAuthorizationStatus {
        guard manager.authorizationStatus == .notDetermined else { return manager.authorizationStatus }
        // Timed out rather than waiting unconditionally: if the delegate
        // callback never arrives (already-resolved status racing the guard
        // above, or a restricted-profile edge case), onboarding would suspend
        // here forever with its Continue button disabled and no way forward.
        // Whatever the status actually is at that point is a fine answer —
        // nothing branches on it synchronously.
        let timeout = Task {
            try? await Task.sleep(for: .seconds(60))
            resumeAuthorizationContinuation(with: manager.authorizationStatus)
        }
        defer { timeout.cancel() }

        return await withCheckedContinuation { continuation in
            // A second caller must not strand the first one's continuation —
            // a checked continuation that is never resumed leaks its task.
            resumeAuthorizationContinuation(with: manager.authorizationStatus)
            authorizationContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Resumes the pending authorization continuation exactly once, if there is
    /// one. Every resume path goes through here so none can double-resume
    /// (a runtime crash) or drop one.
    private func resumeAuthorizationContinuation(with status: CLAuthorizationStatus) {
        guard let continuation = authorizationContinuation else { return }
        authorizationContinuation = nil
        continuation.resume(returning: status)
    }

    /// One-shot fix for region-based feature suggestions (e.g. "a model is available for
    /// your area") — deliberately lighter weight than `startTracking`: only requests
    /// when-in-use authorization (never escalates to Always) and asks for a single fix
    /// rather than continuous updates. Safe to call repeatedly; a no-op once denied.
    /// No-ops while `tracking`, since continuous updates are already feeding
    /// `currentCoordinate` at that point.
    func requestRegionFix() {
        guard !tracking else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            pendingRegionFix = true
            manager.requestWhenInUseAuthorization()   // fix follows once granted (delegate below)
        case .authorizedWhenInUse, .authorizedAlways:
            requestCoarseLocation()
        default:
            break                                      // denied/restricted — no fix
        }
    }

    /// `desiredAccuracy` governs what CoreLocation itself waits to converge on before
    /// calling the delegate back at all — independent of the accuracy floor
    /// `didUpdateLocations` then accepts. Left at `kCLLocationAccuracyBest` (the
    /// default set for tracking), `requestLocation()` can sit for tens of seconds
    /// waiting for a GPS-grade fix even though a region-fix decision only needs
    /// ~100 km precision. Dropping it to kilometre-scale here lets CoreLocation
    /// return its first cheap cell/wifi estimate immediately; `beginUpdates()` puts
    /// it back to `.best` before a tracked session's continuous updates begin.
    private func requestCoarseLocation() {
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.requestLocation()
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
        // Undo requestCoarseLocation()'s kilometre-scale relaxation — a tracked
        // session's breadcrumbs need the strict accuracy floor in didUpdateLocations.
        manager.desiredAccuracy = kCLLocationAccuracyBest
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
        resumeAuthorizationContinuation(with: manager.authorizationStatus)
        if pendingRegionFix {
            pendingRegionFix = false
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: requestCoarseLocation()
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

    /// Looser bar used only when not `tracking` — i.e. a one-shot `requestRegionFix()`
    /// for model/prior suggestions, which only ever need country/region-scale (~100 km)
    /// precision. Requiring the strict 50 m bar here made `currentCoordinate` sit nil
    /// for ~30 s after granting permission, waiting for GPS to lock past the first
    /// coarse cell/wifi fix, even though that first fix was already far more precise
    /// than a 100 km-radius decision needs.
    private let maxAcceptableRegionAccuracyMeters: Double = 5000

    /// CoreLocation can hand back a cached fix from well before this call — good
    /// accuracy doesn't mean fresh. Rejecting a stale one during tracking just waits
    /// for the next continuous update; a tracked session's breadcrumbs, GUANO tags,
    /// and map pins would otherwise get a plausible-looking but wrong "current"
    /// location if the phone had a strong old fix cached from, say, indoors an hour
    /// earlier.
    private let maxAcceptableAgeSeconds: TimeInterval = 30

    /// Looser than `maxAcceptableAgeSeconds` for the same reason
    /// `maxAcceptableRegionAccuracyMeters` is looser than `maxAcceptableAccuracyMeters`:
    /// `requestLocation()` is single-shot with no retry, and a region/prior suggestion
    /// only needs country-scale precision, so a somewhat-old cached fix is still
    /// useful rather than worth discarding outright.
    private let maxAcceptableRegionAgeSeconds: TimeInterval = 900

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let accuracyThreshold = tracking ? maxAcceptableAccuracyMeters : maxAcceptableRegionAccuracyMeters
        guard loc.horizontalAccuracy > 0, loc.horizontalAccuracy <= accuracyThreshold else { return }
        let ageThreshold = tracking ? maxAcceptableAgeSeconds : maxAcceptableRegionAgeSeconds
        guard -loc.timestamp.timeIntervalSinceNow <= ageThreshold else { return }
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
