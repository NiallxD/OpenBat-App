//
//  LocationFuzzing.swift
//  OpenBat
//
//  Snaps a coordinate to a ~5km grid for the upload copy's GUANO location field
//  when the user hasn't granted Precise Location to OpenBat. Deliberately a
//  plain grid-round rather than a geo library — the spec only calls for
//  "fuzz to a ~5km block", not survey-grade obfuscation.
//

import CoreLocation

/// `nonisolated`: called from `UploadConversionPipeline.convert` off the main
/// actor — see that type's own `nonisolated` doc comment for why.
nonisolated enum LocationFuzzing {
    /// ~0.045° latitude ≈ 5 km everywhere; longitude spacing shrinks toward the
    /// poles, so this rounds to a slightly-wider-than-5km box at high latitudes
    /// rather than a true 5km circle — an acceptable approximation for the
    /// "approximate area" privacy goal, not a precision guarantee.
    private static let gridDegrees = 0.045

    static func fuzz(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (coordinate.latitude / gridDegrees).rounded() * gridDegrees,
            longitude: (coordinate.longitude / gridDegrees).rounded() * gridDegrees)
    }

    /// Whether the *upload copy* should get an accurate or fuzzed location, per
    /// the OS-native per-app "Precise Location" toggle rather than any custom
    /// in-app setting — reduced accuracy means the user turned that off for
    /// OpenBat specifically.
    static func shouldFuzzForUpload(authorization: CLAccuracyAuthorization) -> Bool {
        authorization == .reducedAccuracy
    }
}
