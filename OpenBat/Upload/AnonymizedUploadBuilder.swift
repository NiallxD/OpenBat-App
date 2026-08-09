//
//  AnonymizedUploadBuilder.swift
//  OpenBat
//
//  THE anonymization boundary. Every transformation that makes a contributed
//  recording non-personal-data happens here and nowhere else: location
//  grid-snapping, timestamp bucketing, metadata allowlisting, and minting the
//  object identity the upload is stored under.
//
//  This exists as one module, with one entry point, because the project's
//  entire "uploaded recordings are not personal data" position rests on it.
//  It used to be four separate pieces of logic, each with its own leak. See
//  Context.md §11.
//
//  Two rules for anyone editing this file:
//
//  1. Nothing derived from `DeviceIdentity` may appear in the output. Not the
//     device id, not the device token, not anything computed from either. The
//     device id is used exactly once in the whole upload path — as a transient
//     request header the Worker checks consent against and then discards (see
//     RecordingUploader.upload and the Worker's handleUpload) — and it must
//     never reach this type at all. It isn't a parameter here on purpose.
//  2. `allowedGuanoKeys` is an allowlist, never a denylist. A field added to
//     AudioRecorder's GUANO must be *deliberately* admitted here before it can
//     ever be contributed. That inversion is the whole point: the failure mode
//     of a denylist is silent disclosure of a field nobody remembered to add.
//
//  See OpenBat App Store Review Notes §3 ("strip/fuzz at the edge") and §4
//  ("the join that must never exist").
//

import Foundation
import CoreLocation

/// Everything that goes over the wire for one contributed recording, with the
/// anonymizing transforms already applied. Deliberately has no `deviceID` and
/// no way to obtain one.
nonisolated struct AnonymizedUpload {
    /// Freshly minted per attempt, unrelated to the device id and unrelated to
    /// the local `Recording.id`. Deliberately NOT persisted anywhere on the
    /// device: a persisted key would be a complete join between a device and
    /// its uploads, sitting on the device, available to anyone holding it.
    ///
    /// Cost: a response lost after a successful upload gets re-sent as a
    /// second object (rare — R2 `put` is atomic), deduplicated server-side by
    /// content hash. A smaller problem than a persistent identifier.
    let objectID: UUID
    /// `{YYYY-MM-DD}/{objectID}.flac` — the R2 key, and the Worker's URL path
    /// after `/upload/`. The date comes from the *bucketed* timestamp in UTC, so
    /// the key can't disagree with the metadata inside the file.
    let objectKey: String
    /// Grid-snapped. `nil` when the source had no usable position at all.
    let coordinate: CLLocationCoordinate2D?
    /// Floored to `timestampBucketSeconds`.
    let recordedAt: Date
    /// The complete `guan` chunk for the derived WAV — allowlisted fields only.
    let guanoChunk: Data
    /// `x-openbat-*` request headers. Mirrored into R2 `customMetadata` by the
    /// Worker so recordings are filterable without a second database. Carries
    /// the same fuzzed coordinate as the GUANO, never the source one.
    let headers: [String: String]
}

/// `nonisolated`: called from `UploadConversionPipeline.convert`, which runs on
/// `RecordingUploader`'s `Task.detached` background work — see that type's own
/// doc comment for why the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// default has to be opted out of here.
nonisolated enum AnonymizedUploadBuilder {

    // MARK: Parameters

    /// Grid cell for the contributed coordinate: 0.001° of latitude is ~111 m
    /// everywhere, so this is the "~100 m" the consent copy and privacy notice
    /// commit to. Longitude cells narrow toward the poles (~65 m at UK
    /// latitudes), which errs toward *more* precision loss, never less.
    ///
    /// Grid-snapping rather than random jitter, deliberately: it's deterministic
    /// and therefore testable, and it collapses many recordings from one area
    /// onto identical coordinates (k-anonymity-style clustering). Jitter gives
    /// no clustering and can, by chance, land a point closer to the true
    /// position than the nominal radius suggests.
    static let locationGridDegrees = 0.001

    /// Contributed timestamps are floored to this. Five minutes is coarse enough
    /// that a recording can't be matched against someone's movements by time
    /// alone, and fine enough to stay ecologically useful (dusk emergence timing,
    /// activity-over-night curves).
    static let timestampBucketSeconds: TimeInterval = 300

    /// The complete set of GUANO keys a contributed recording may carry.
    /// Anything else is dropped — see rule 2 in the file header.
    ///
    /// Notable *exclusions*, each of which was previously being uploaded:
    ///   - `Original Filename` — AudioRecorder names files
    ///     `yyyy-MM-dd_HH-mm-ss-SSS_SPECIES.wav`. A millisecond-precision
    ///     timestamp in the filename defeats the whole point of bucketing the
    ///     `Timestamp` field beside it.
    ///   - `OpenBat|Session` — the session label is also a formatted start time,
    ///     and it additionally groups a night's recordings into one identifiable
    ///     survey run.
    ///   - `OpenBat|Device ID`, `OpenBat|Recordist` — the join from §4, and the
    ///     display name that used to be settable in Settings.
    ///   - `OpenBat|Consent Version` — non-identifying on its own, but the
    ///     consent table holds (device_id, consent_version), so a rare version
    ///     value plus a timestamp bucket is a narrowing join. §4 asks for the
    ///     relationship to be structurally absent, not merely weak.
    ///   - `Species Manual ID` — always written empty by AudioRecorder today,
    ///     but it's a free-text user field, which is a disclosure waiting to
    ///     happen the moment it becomes editable.
    ///   - `OpenBat|Host`, `OpenBat|App Version` — exact duplicates of `Model`
    ///     and `Firmware Version`.
    static let allowedGuanoKeys: Set<String> = [
        "GUANO|Version",
        "Make",                             // ultrasonic input device, model only
        "Model",                            // host iPhone model, e.g. "iPhone15,2"
        "Firmware Version",                 // "OpenBat 1.2" — the app version
        "Timestamp",                        // rewritten, bucketed
        "Length",
        "Samplerate",
        "Loc Position",                     // rewritten, grid-snapped
        "Species Auto ID",
        "OpenBat|Species Confidence",
        "OpenBat|Species Pulse Count",
        "OpenBat|AutoID Model",
        "OpenBat|HighPass Cutoff Hz",
        "OpenBat|Quality SNR dB",
        "OpenBat|Quality Clipping Fraction",
    ]

    /// Emission order for the allowlisted fields. Fixed rather than
    /// source-order-preserving for two reasons: GUANO requires the version line
    /// first, and a stable order means field ordering can't itself vary between
    /// devices and become a fingerprint.
    private static let guanoKeyOrder: [String] = [
        "GUANO|Version",
        "Make",
        "Model",
        "Firmware Version",
        "Timestamp",
        "Length",
        "Samplerate",
        "Loc Position",
        "Species Auto ID",
        "OpenBat|Species Confidence",
        "OpenBat|Species Pulse Count",
        "OpenBat|AutoID Model",
        "OpenBat|HighPass Cutoff Hz",
        "OpenBat|Quality SNR dB",
        "OpenBat|Quality Clipping Fraction",
    ]

    // MARK: Entry point

    /// Steps 3–7 of the pipeline in §3, in order, in one call.
    ///
    /// - Parameters:
    ///   - originalFields: GUANO read from the untouched on-device recording.
    ///     Treated as untrusted input to be filtered, not as a base to extend.
    ///   - recordedAt: the recording's true start time. Bucketed here; the
    ///     caller should never bucket it itself.
    ///   - fallbackCoordinate: the `Recording`'s own stored position, used only
    ///     when `originalFields` carries no parseable `Loc Position`. Goes
    ///     through exactly the same snap as a GUANO-sourced one — there is no
    ///     path by which an un-snapped coordinate reaches the output.
    static func build(
        originalFields: [String: String],
        recordedAt: Date,
        fallbackCoordinate: CLLocationCoordinate2D?,
        species: String,
        confidence: Float?,
        cutoffHz: Double,
        quality: UploadQualityGateResult
    ) -> AnonymizedUpload {
        let coordinate = anonymizedCoordinate(
            originalFields: originalFields, fallback: fallbackCoordinate)
        let bucketed = bucketedTimestamp(recordedAt)
        let objectID = UUID()

        var derived = originalFields.filter { allowedGuanoKeys.contains($0.key) }
        derived["Make"] = derived["Make"].map(sanitizedHardwareName)
        derived["Model"] = derived["Model"].map(sanitizedHardwareName)
        derived["Timestamp"] = iso8601.string(from: bucketed)
        derived["OpenBat|HighPass Cutoff Hz"] = String(Int(cutoffHz.rounded()))
        derived["OpenBat|Quality SNR dB"] = String(format: "%.1f", quality.snrDB)
        derived["OpenBat|Quality Clipping Fraction"] = String(format: "%.4f", quality.clippingFraction)
        if let coordinate {
            derived["Loc Position"] = formattedCoordinate(coordinate)
        } else {
            derived["Loc Position"] = nil
        }
        // A source WAV with no GUANO at all still has to produce a valid chunk.
        derived["GUANO|Version"] = derived["GUANO|Version"] ?? "1.0"

        var headers = ["x-openbat-species": species, "x-openbat-verified": "false"]
        if let confidence {
            headers["x-openbat-quality-score"] = String(format: "%.3f", confidence)
        }
        if let coordinate {
            headers["x-openbat-location"] = formattedCoordinate(coordinate)
        }

        return AnonymizedUpload(
            objectID: objectID,
            objectKey: "\(dayFormatter.string(from: bucketed))/\(objectID.uuidString).flac",
            coordinate: coordinate,
            recordedAt: bucketed,
            guanoChunk: guanoChunk(from: derived),
            headers: headers)
    }

    // MARK: Location

    /// Grid-snap. Exposed (rather than private) because it's the single most
    /// important thing in this file to be able to test directly.
    static func snapToGrid(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (coordinate.latitude / locationGridDegrees).rounded() * locationGridDegrees,
            longitude: (coordinate.longitude / locationGridDegrees).rounded() * locationGridDegrees)
    }

    /// Unconditional, regardless of iOS's own Precise Location toggle — an
    /// earlier version snapped only when that toggle was off, which meant the
    /// default configuration uploaded exact coordinates. iOS's reduced-accuracy
    /// region, when enabled, simply layers a much coarser area on top of this
    /// fuzz.
    ///
    /// An unparseable `Loc Position` is dropped rather than passed through: a
    /// string this can't parse is one it also can't snap, so forwarding it
    /// verbatim would be a way for an exact position to reach the server.
    private static func anonymizedCoordinate(
        originalFields: [String: String], fallback: CLLocationCoordinate2D?
    ) -> CLLocationCoordinate2D? {
        let parts = (originalFields["Loc Position"] ?? "")
            .split(separator: " ").compactMap { Double($0) }
        let source: CLLocationCoordinate2D
        if parts.count == 2 {
            source = CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
        } else if let fallback {
            source = fallback
        } else {
            return nil
        }
        return snapToGrid(source)
    }

    /// Three decimals, matching the grid — writing the snapped value back out at
    /// six decimals would produce `51.502000` and invite a reader to assume more
    /// precision than the number carries.
    private static func formattedCoordinate(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.3f %.3f", coordinate.latitude, coordinate.longitude)
    }

    // MARK: Hardware names

    /// Strips anything serial-number-shaped out of a device name before it's
    /// contributed.
    ///
    /// `Make` is whatever iOS reports as the audio input port's name, which for
    /// USB audio is the device's own USB product string — i.e. a value the
    /// *microphone vendor* chose, not one we control. Most report a clean model
    /// name, but nothing stops a device from appending a serial, and a serial
    /// would be a per-unit identifier riding along inside a file that has
    /// otherwise had every identifier removed. One badly-behaved mic model would
    /// silently de-anonymize every contribution made with it.
    ///
    /// The model name genuinely matters scientifically (frequency response
    /// differs between mics), so this trims rather than drops. Deliberately
    /// conservative — it removes token shapes that carry no model information
    /// anyway:
    ///   - explicit serial markers and everything after them ("S/N", "SN:", "#")
    ///   - runs of 6+ digits, and 8+ hex characters
    ///   - anything left over past a sane length
    ///
    /// Note this only affects the *contributed* copy. The on-device original
    /// keeps the true reported name, and Settings ▸ Diagnostics shows both the
    /// raw port name and its UID so the real value can be eyeballed with a mic
    /// attached — which is the only way to confirm what a given device reports.
    static func sanitizedHardwareName(_ raw: String) -> String {
        var name = raw
        if let marker = name.range(
            of: #"(?i)\b(s[/\-]?n|serial)\b\s*[:#]?.*$"#, options: .regularExpression) {
            name.removeSubrange(marker)
        }
        if let hash = name.range(of: #"#.*$"#, options: .regularExpression) {
            name.removeSubrange(hash)
        }
        name = name.replacingOccurrences(
            of: #"\b[0-9]{6,}\b"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(
            of: #"\b[0-9A-Fa-f]{8,}\b"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(
            of: #"\s{2,}"#, with: " ", options: .regularExpression)
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-–—_,:;"))
        // A name that was ENTIRELY serial is not a model name; say so rather
        // than contributing an empty field that reads as "no microphone".
        return name.isEmpty ? "unknown" : String(name.prefix(64))
    }

    // MARK: Timestamp

    /// Floors to the bucket. Floor rather than round, so a bucket label is
    /// always a time the recording was at or after — rounding up would produce a
    /// contributed timestamp in the future relative to the actual capture.
    static func bucketedTimestamp(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / timestampBucketSeconds).rounded(.down)
            * timestampBucketSeconds)
    }

    // MARK: GUANO

    private static func guanoChunk(from fields: [String: String]) -> Data {
        let ordered: [GuanoMetadata.Field] = guanoKeyOrder.compactMap { key in
            guard let value = fields[key] else { return nil }
            // `Loc Position` needs `Key:Value` with no space — some readers
            // (including the NABat notebook's) show a blank latitude otherwise.
            return GuanoMetadata.Field(key, value, tightColon: key == "Loc Position")
        }
        return GuanoMetadata.chunk(fields: ordered)
    }

    // MARK: Formatters

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
