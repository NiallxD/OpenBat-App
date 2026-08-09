//
//  AnonymizedUploadBuilderTests.swift
//  OpenBatTests
//
//  The project's position that contributed recordings are not personal data
//  rests entirely on AnonymizedUploadBuilder doing what it says. These tests are
//  the evidence for that claim, so they're written to fail loudly on a
//  regression rather than to cover lines.
//
//  The most important test in this file is `noIdentifierSurvivesAnywhere`: it
//  asserts on the ABSENCE of things, scanning the entire emitted output rather
//  than checking individual fields, so a future field that reintroduces an
//  identifier fails here without anyone having remembered to add a case for it.
//

import Testing
import Foundation
import CoreLocation
@testable import OpenBat

struct AnonymizedUploadBuilderTests {

    // MARK: Fixtures

    /// A realistic GUANO set as `AudioRecorder.makeGuanoChunk` writes it, plus
    /// the fields the old upload path used to append. Everything a source file
    /// could plausibly carry, so the allowlist is exercised against the real
    /// shape rather than a curated one.
    private func sourceFields(
        timestamp: String = "2026-07-14T22:37:41+01:00",
        position: String? = "51.5074231 -0.1277653"
    ) -> [String: String] {
        var fields = [
            "GUANO|Version": "1.0",
            "Make": "Griff Ultrasonic Mic",
            "Model": "iPhone15,2",
            "Firmware Version": "OpenBat 1.4",
            "Timestamp": timestamp,
            "Length": "3.250",
            "Samplerate": "384000",
            "Original Filename": "2026-07-14_22-37-41-892_PIPI.wav",
            "Species Auto ID": "PIPI",
            "Species Manual ID": "",
            "OpenBat|Species Confidence": "0.910",
            "OpenBat|Species Pulse Count": "14",
            "OpenBat|AutoID Model": "NABat v2.0",
            "OpenBat|Session": "2026-07-14_21-58-03",
            "OpenBat|App Version": "1.4",
            "OpenBat|Host": "iPhone15,2",
            // Fields the pre-anonymization upload path used to add itself.
            "OpenBat|Device ID": "8B1F2C4E-33A9-4F70-9C2D-6E5A1B0D7788",
            "OpenBat|Recordist": "Niall Bell",
            "OpenBat|Consent Version": "1.0",
        ]
        if let position { fields["Loc Position"] = position }
        return fields
    }

    private func quality() -> UploadQualityGateResult {
        UploadQualityGateResult(passed: true, snrDB: 18.4, clippingFraction: 0.0002, pulseCount: 14)
    }

    private func build(
        fields: [String: String]? = nil,
        recordedAt: Date = Date(timeIntervalSince1970: 1_784_500_661),
        fallback: CLLocationCoordinate2D? = nil
    ) -> AnonymizedUpload {
        AnonymizedUploadBuilder.build(
            originalFields: fields ?? sourceFields(),
            recordedAt: recordedAt,
            fallbackCoordinate: fallback,
            species: "PIPI",
            confidence: 0.91,
            cutoffHz: 12_500,
            quality: quality())
    }

    /// The emitted GUANO chunk parsed back into key/value pairs. Asserting on
    /// the encoded bytes (rather than on an intermediate dictionary) is
    /// deliberate: it's what actually ships inside the file.
    private func emittedFields(_ upload: AnonymizedUpload) -> [String: String] {
        // Chunk layout is FOURCC + LE32 size + UTF-8 text (+ pad) — see
        // GuanoMetadata.chunk.
        let text = String(decoding: upload.guanoChunk.dropFirst(8), as: UTF8.self)
        var parsed: [String: String] = [:]
        for line in text.split(separator: "\n") {
            if let range = line.range(of: ": ") {
                parsed[String(line[..<range.lowerBound])] = String(line[range.upperBound...])
            } else if let colon = line.firstIndex(of: ":") {
                parsed[String(line[..<colon])] = String(line[line.index(after: colon)...])
            }
        }
        return parsed
    }

    // MARK: The load-bearing test

    /// Scans everything that leaves the device for anything identifying. Written
    /// as a substring sweep over the whole serialized output rather than as
    /// per-field assertions, so a newly-added field that leaks fails this test
    /// without anyone updating it.
    @Test func noIdentifierSurvivesAnywhere() {
        let upload = build()

        let everything = [
            String(decoding: upload.guanoChunk, as: UTF8.self),
            upload.objectKey,
            upload.headers.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "&"),
        ].joined(separator: "\n")

        // The device id, in the casing it's stored in and lowercased — a
        // well-meaning `.lowercased()` somewhere must not slip past this.
        #expect(!everything.contains("8B1F2C4E-33A9-4F70-9C2D-6E5A1B0D7788"))
        #expect(!everything.lowercased().contains("8b1f2c4e-33a9-4f70-9c2d-6e5a1b0d7788"))
        // Display name.
        #expect(!everything.contains("Niall Bell"))
        // Original filename: a millisecond-precision capture time, which would
        // defeat the timestamp bucketing sitting right next to it.
        #expect(!everything.contains("2026-07-14_22-37-41-892"))
        #expect(!everything.contains("Original Filename"))
        // Session label — also a formatted start time, and it groups a night's
        // recordings into one identifiable survey run.
        #expect(!everything.contains("2026-07-14_21-58-03"))
        // Precise coordinate, to any precision finer than the grid.
        #expect(!everything.contains("51.5074"))
        #expect(!everything.contains("-0.12776"))
        // Keys that must not appear at all, whatever their values.
        for forbidden in ["Device ID", "Recordist", "Consent Version", "Session"] {
            #expect(!everything.contains(forbidden), "\(forbidden) reached the upload")
        }
    }

    /// The allowlist is an allowlist. A field nobody has thought about must be
    /// dropped by default rather than carried through.
    @Test func unknownSourceFieldsAreDropped() {
        var fields = sourceFields()
        fields["OpenBat|Some Future Field"] = "leaked"
        fields["Note"] = "recorded from my back garden, 14 Elm Road"

        let emitted = emittedFields(build(fields: fields))

        #expect(emitted["OpenBat|Some Future Field"] == nil)
        #expect(emitted["Note"] == nil)
        #expect(Set(emitted.keys).isSubset(of: AnonymizedUploadBuilder.allowedGuanoKeys))
    }

    /// Everything the allowlist admits should actually survive — a filter that
    /// drops the science along with the identifiers is also a failure.
    @Test func scientificFieldsSurvive() {
        let emitted = emittedFields(build())

        #expect(emitted["Species Auto ID"] == "PIPI")
        #expect(emitted["OpenBat|Species Confidence"] == "0.910")
        #expect(emitted["OpenBat|Species Pulse Count"] == "14")
        #expect(emitted["OpenBat|AutoID Model"] == "NABat v2.0")
        #expect(emitted["Samplerate"] == "384000")
        #expect(emitted["Length"] == "3.250")
        #expect(emitted["Make"] == "Griff Ultrasonic Mic")
        #expect(emitted["GUANO|Version"] == "1.0")
        // Applied by the builder, not carried from the source.
        #expect(emitted["OpenBat|HighPass Cutoff Hz"] == "12500")
        #expect(emitted["OpenBat|Quality SNR dB"] == "18.4")
    }

    // MARK: Location

    /// Baseline: a coordinate snaps down to the 0.001° grid, not to itself.
    @Test func coordinateSnapsToGrid() {
        let snapped = AnonymizedUploadBuilder.snapToGrid(
            CLLocationCoordinate2D(latitude: 51.5074231, longitude: -0.1277653))
        #expect(abs(snapped.latitude - 51.507) < 1e-9)
        #expect(abs(snapped.longitude - (-0.128)) < 1e-9)
    }

    /// Grid-snapping was chosen over jitter partly for this: nearby recordings
    /// collapse onto one coordinate, which is what gives the anonymity set its
    /// size. A jitter implementation would pass a "is it fuzzed" test and fail
    /// this one.
    @Test func nearbyCoordinatesCollapseTogether() {
        let a = AnonymizedUploadBuilder.snapToGrid(.init(latitude: 51.50741, longitude: -0.12776))
        let b = AnonymizedUploadBuilder.snapToGrid(.init(latitude: 51.50748, longitude: -0.12779))
        #expect(a.latitude == b.latitude)
        #expect(a.longitude == b.longitude)
    }

    /// Same input, same output — the anonymity set depends on that.
    @Test func snappingIsDeterministic() {
        let source = CLLocationCoordinate2D(latitude: 51.5074231, longitude: -0.1277653)
        let first = AnonymizedUploadBuilder.snapToGrid(source)
        let second = AnonymizedUploadBuilder.snapToGrid(source)
        #expect(first.latitude == second.latitude)
        #expect(first.longitude == second.longitude)
    }

    /// Fuzzing used to be conditional on the OS "Precise Location" toggle, which
    /// meant the default configuration uploaded exact coordinates. There is no
    /// longer any input that produces an unsnapped output.
    @Test func emittedPositionIsNeverPrecise() {
        let emitted = emittedFields(build())
        #expect(emitted["Loc Position"] == "51.507 -0.128")
        #expect(emitted["Loc Position"]?.contains("51.5074") == false)
    }

    /// The fallback path (no GUANO position, coordinate taken from the
    /// `Recording`) has to go through the same snap — it was a plausible way for
    /// a precise coordinate to arrive by a side door.
    @Test func fallbackCoordinateIsSnappedToo() {
        var fields = sourceFields()
        fields["Loc Position"] = nil
        let upload = build(
            fields: fields,
            fallback: CLLocationCoordinate2D(latitude: 51.5074231, longitude: -0.1277653))

        #expect(emittedFields(upload)["Loc Position"] == "51.507 -0.128")
        #expect(upload.headers["x-openbat-location"] == "51.507 -0.128")
    }

    /// A position string the parser can't read is one it also can't snap, so it
    /// must be dropped rather than forwarded verbatim.
    @Test func unparseablePositionIsDroppedNotForwarded() {
        let upload = build(fields: sourceFields(position: "51°30'26.7\"N 0°07'39.9\"W"))
        let emitted = emittedFields(upload)

        #expect(emitted["Loc Position"] == nil)
        #expect(upload.headers["x-openbat-location"] == nil)
        #expect(!String(decoding: upload.guanoChunk, as: UTF8.self).contains("51°30"))
    }

    /// No source position must not be papered over with a fabricated one.
    @Test func missingPositionProducesNoLocationAtAll() {
        var fields = sourceFields()
        fields["Loc Position"] = nil
        let upload = build(fields: fields)

        #expect(upload.coordinate == nil)
        #expect(emittedFields(upload)["Loc Position"] == nil)
        #expect(upload.headers["x-openbat-location"] == nil)
    }

    /// The header and the file have to agree. They didn't, once: the file got
    /// the fuzzed coordinate and the header got the raw one, so the server
    /// received an exact position regardless.
    @Test func headerAndGuanoLocationAgree() {
        let upload = build()
        #expect(upload.headers["x-openbat-location"] == emittedFields(upload)["Loc Position"])
    }

    // MARK: Timestamp

    /// Bucketed to the 5-minute grid, e.g. 22:37:41Z -> 22:35:00Z.
    @Test func timestampFloorsToFiveMinutes() {
        let recorded = Date(timeIntervalSince1970: 1_784_500_661)
        let bucketed = AnonymizedUploadBuilder.bucketedTimestamp(recorded)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.minute, .second], from: bucketed)
        #expect(parts.minute! % 5 == 0)
        #expect(parts.second == 0)
        #expect(bucketed <= recorded)
        #expect(recorded.timeIntervalSince(bucketed) < 300)
    }

    /// Floor, not round: a bucketed timestamp must never claim the recording
    /// happened later than it did.
    @Test func timestampNeverRoundsForward() {
        for offset in stride(from: 0.0, to: 3600.0, by: 37.0) {
            let recorded = Date(timeIntervalSince1970: 1_784_500_000 + offset)
            #expect(AnonymizedUploadBuilder.bucketedTimestamp(recorded) <= recorded)
        }
    }

    /// The emitted file carries the bucketed time, never the precise source one.
    @Test func emittedTimestampIsBucketedNotSourceValue() {
        let emitted = emittedFields(build())
        #expect(emitted["Timestamp"] != "2026-07-14T22:37:41+01:00")
        #expect(emitted["Timestamp"]?.hasSuffix(":00Z") == true)
    }

    // MARK: Object identity

    /// Mirrors `UPLOAD_KEY_PATTERN` in `backend/consent-worker/src/index.ts`. A
    /// change on either side that isn't made on both produces a 400 at upload.
    @Test func objectKeyMatchesTheWorkersPattern() {
        let pattern = try! NSRegularExpression(
            pattern: #"^\d{4}-\d{2}-\d{2}/[0-9A-Fa-f-]{36}\.flac$"#)
        let key = build().objectKey
        let range = NSRange(key.startIndex..., in: key)
        #expect(pattern.firstMatch(in: key, range: range) != nil, "bad key: \(key)")
    }

    /// The key's date must come from the bucketed timestamp, not from anything
    /// finer — and must not disagree with the timestamp inside the file.
    @Test func objectKeyDateAgreesWithBucketedTimestamp() {
        let upload = build()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        #expect(upload.objectKey.hasPrefix(formatter.string(from: upload.recordedAt) + "/"))
    }

    /// Two uploads of the same recording must not share an object id. A stable
    /// id would make retries idempotent, but it would also mean the device
    /// holds a durable pointer to its own contributions — see the `objectID`
    /// doc comment for why the duplicate is the cheaper problem.
    @Test func objectIDIsFreshPerBuild() {
        #expect(build().objectID != build().objectID)
    }

    /// Belt and braces on the ordering contract GUANO itself requires.
    @Test func versionLineComesFirst() {
        let text = String(decoding: build().guanoChunk.dropFirst(8), as: UTF8.self)
        #expect(text.hasPrefix("GUANO|Version: 1.0"))
    }

    /// A source WAV with no readable GUANO at all still has to produce a valid
    /// chunk rather than an empty or malformed one.
    @Test func emptySourceStillProducesValidGuano() {
        let upload = build(fields: [:])
        let emitted = emittedFields(upload)
        #expect(emitted["GUANO|Version"] == "1.0")
        #expect(emitted["Timestamp"] != nil)
    }

    // MARK: Hardware names

    /// The microphone name is a vendor-chosen USB product string, so a serial in
    /// it is possible and would be a per-unit identifier inside an otherwise
    /// anonymous file.
    @Test func serialLikeTokensAreStrippedFromHardwareNames() {
        let cases: [(String, String)] = [
            ("Griff Ultrasonic Mic", "Griff Ultrasonic Mic"),         // clean, untouched
            ("Griff Mic S/N 12345678", "Griff Mic"),
            ("Griff Mic SN: A1B2C3D4E5", "Griff Mic"),
            ("Griff Mic #00417723", "Griff Mic"),
            ("Griff Mic 000123456789", "Griff Mic"),
            ("Griff Mic DEADBEEFCAFE", "Griff Mic"),
            ("Griff Mic Serial 998877", "Griff Mic"),
        ]
        for (raw, expected) in cases {
            #expect(AnonymizedUploadBuilder.sanitizedHardwareName(raw) == expected,
                    "sanitizing \"\(raw)\"")
        }
    }

    /// Model designations often contain short digit groups that carry real
    /// information — those must survive, or the filter destroys the scientific
    /// value it exists to preserve.
    @Test func modelNumbersSurviveSanitizing() {
        #expect(AnonymizedUploadBuilder.sanitizedHardwareName("iPhone15,2") == "iPhone15,2")
        #expect(AnonymizedUploadBuilder.sanitizedHardwareName("Griff M500") == "Griff M500")
        #expect(AnonymizedUploadBuilder.sanitizedHardwareName("UM192K") == "UM192K")
    }

    /// A name that's nothing but serial becomes "unknown", not an empty string
    /// that would render as a blank field.
    @Test func anEntirelySerialNameBecomesUnknownNotEmpty() {
        #expect(AnonymizedUploadBuilder.sanitizedHardwareName("884213770941") == "unknown")
        #expect(AnonymizedUploadBuilder.sanitizedHardwareName("") == "unknown")
    }

    /// The sanitizer isn't just a unit-tested function sitting unused — its
    /// output is what actually reaches the emitted GUANO chunk.
    @Test func sanitizingIsAppliedToTheEmittedFile() {
        var fields = sourceFields()
        fields["Make"] = "Griff Ultrasonic Mic S/N 90210447"
        let emitted = emittedFields(build(fields: fields))
        #expect(emitted["Make"] == "Griff Ultrasonic Mic")
        #expect(!String(decoding: build(fields: fields).guanoChunk, as: UTF8.self).contains("90210447"))
    }

    // MARK: Headers

    /// Headers are an allowlist too, same reasoning as the GUANO key list.
    @Test func headersCarryOnlyAllowedFields() {
        let allowed: Set<String> = [
            "x-openbat-species", "x-openbat-quality-score",
            "x-openbat-location", "x-openbat-verified",
        ]
        #expect(Set(build().headers.keys).isSubset(of: allowed))
    }

    /// The device id travels as a request header set at the call site
    /// (RecordingUploader.upload) purely so the Worker can check consent, and is
    /// never persisted. It must not come from here — anything in `headers` is
    /// mirrored into R2 customMetadata by the Worker.
    @Test func headersNeverIncludeADeviceIdentifier() {
        let keys = build().headers.keys.map { $0.lowercased() }
        #expect(!keys.contains { $0.contains("device") })
        #expect(!keys.contains { $0.contains("recordist") })
    }
}
