//
//  LocationProvider.swift
//  OpenBat
//
//  CoreLocation wrapper providing occasional one-shot fixes: which classifier
//  model suits the user's region, which species are plausible there, the
//  coordinate stamped on each detection, and a place name for a session title.
//
//  NO CONTINUOUS TRACKING, and never "Always" authorization (2026-08-16).
//  Sessions used to record a GPS course — continuous background updates,
//  breadcrumbs every ~5 m, escalating to Always so it kept running with the
//  phone locked. It was removed rather than made optional: every detection
//  already carries a coordinate and a timestamp, so a track can be reconstructed
//  from the exported points by any GIS tool. Keeping a second, denser copy of
//  the user's movements cost battery and privacy to duplicate data the app
//  already had.
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
    /// your area"), and to tag detections. Only ever requests when-in-use
    /// authorization — never Always — and asks for a single fix rather than
    /// continuous updates. Safe to call repeatedly; a no-op once denied.
    func requestRegionFix() {
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
    /// return its first cheap cell/wifi estimate immediately; Nothing puts it back:
    /// every fix this class takes is a region fix now.
    private func requestCoarseLocation() {
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.requestLocation()
    }

    /// Reverse-geocode the next good fix into `sessionID`'s title, so a session is
    /// named for where it happened rather than only when.
    ///
    /// Sessions used to get this from the first breadcrumb of a continuous GPS
    /// track. Tracking is gone (2026-08-16 — see the type's header), so the
    /// single region fix does the job instead: one fix, one geocode, no
    /// background location.
    func geocodeNextFix(into sessionID: UUID) {
        pendingGeocodeSessionID = sessionID
        requestRegionFix()
        // A fix from the last few minutes is already good enough to name a
        // place, and asking for a fresh one would leave the session untitled
        // until CoreLocation felt like answering.
        if let coordinate = currentCoordinate {
            geocodeTitleIfNeeded(CLLocation(latitude: coordinate.latitude,
                                            longitude: coordinate.longitude))
        }
    }

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
    }

    /// Fixes worse than this (metres) are rejected outright. Deliberately loose:
    /// every fix taken here is single-shot, and its jobs — which model suits this
    /// region, which species are plausible (a 1-degree grid), a place name for a
    /// title, a coordinate on a detection — need region-scale precision, not
    /// GPS-grade. The strict 50 m bar this replaced belonged to continuous
    /// tracking, and applying it to a one-shot fix left `currentCoordinate` nil
    /// for ~30 s after permission was granted, waiting for a lock the app had no
    /// use for.
    private let maxAcceptableRegionAccuracyMeters: Double = 5000

    /// CoreLocation can hand back a fix cached from well before this call — good
    /// accuracy doesn't mean fresh. With no continuous updates to fall back on,
    /// rejecting a slightly stale fix means having none at all, and a fifteen-
    /// minute-old position is still the right answer to every question asked of
    /// it here.
    private let maxAcceptableRegionAgeSeconds: TimeInterval = 900

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        guard loc.horizontalAccuracy > 0,
              loc.horizontalAccuracy <= maxAcceptableRegionAccuracyMeters else { return }
        guard -loc.timestamp.timeIntervalSinceNow <= maxAcceptableRegionAgeSeconds else { return }
        currentCoordinate = loc.coordinate
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
