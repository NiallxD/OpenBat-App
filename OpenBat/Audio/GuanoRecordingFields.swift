//
//  GuanoRecordingFields.swift
//  OpenBat
//
//  Interprets a raw GUANO key/value dictionary (what `GuanoMetadata.read`
//  returns) as the fields a `Recording` needs. One layer above
//  `GuanoMetadata`, which only knows the chunk format, not what the keys mean.
//
//  Shared deliberately. This parsing carries several conventions that are easy
//  to get subtly wrong and impossible to notice afterwards:
//
//    • "Species Auto ID" is "No ID" — with a space, GUANO-readable text — in the
//      chunk, but `Recording.species` is "NOID" everywhere in the app so it
//      matches the filename and is filesystem-safe.
//    • "Loc Position" is space-separated "lat lon", and OpenBat writes its key
//      with no space after the colon (see AnonymizedUploadBuilder's `tightColon`).
//    • Confidence and pulse count live under vendor-namespaced `OpenBat|` keys.
//
//  `RecordingMigration` (re-adopting orphaned WAVs) and `RecordingImporter`
//  (user-picked files) both need exactly this, so it lives here once rather
//  than being duplicated and left to drift apart.
//

import CoreLocation
import Foundation

nonisolated struct GuanoRecordingFields {
    let date: Date
    let durationSeconds: Double
    /// Normalized to the `Recording.species` convention — "NOID", never "No ID".
    let species: String
    let confidence: Float?
    let pulseCount: Int
    let coordinate: CLLocationCoordinate2D?
    /// The chunk explicitly says this was recorded outside any survey session.
    let listeningOnly: Bool

    /// Legacy WAVs from before `AudioRecorder` rejected NOISE at save time.
    var isNoise: Bool { species == "NOISE" }

    static func parse(_ fields: [String: String],
                      wavURL: URL,
                      fallbackDate: Date) -> GuanoRecordingFields {
        // A fresh formatter per call, not a shared static — `ISO8601DateFormatter`
        // isn't Sendable/thread-safe for concurrent use (a real Swift 6 mode
        // error, not just a strictness warning), and both callers run this off
        // the main actor. Construction is cheap.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        let rawSpecies = fields["Species Auto ID"] ?? speciesFromFilename(wavURL) ?? "No ID"
        return GuanoRecordingFields(
            date: fields["Timestamp"].flatMap { iso.date(from: $0) } ?? fallbackDate,
            durationSeconds: fields["Length"].flatMap(Double.init) ?? 0,
            species: rawSpecies == "No ID" ? "NOID" : rawSpecies,
            confidence: fields["OpenBat|Species Confidence"].flatMap { Float($0) },
            pulseCount: fields["OpenBat|Species Pulse Count"].flatMap { Int($0) } ?? 0,
            coordinate: parseLocPosition(fields["Loc Position"]),
            listeningOnly: fields["OpenBat|Session"] == "Listening only")
    }

    /// "<yyyy-MM-dd_HH-mm-ss-SSS>_<SPECIES>.wav" → SPECIES — fallback for a WAV
    /// whose GUANO chunk is present but missing (or predates) the species field.
    static func speciesFromFilename(_ url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let lastUnderscore = name.lastIndex(of: "_") else { return nil }
        return String(name[name.index(after: lastUnderscore)...])
    }

    static func parseLocPosition(_ value: String?) -> CLLocationCoordinate2D? {
        guard let value else { return nil }
        let parts = value.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }
}
