//
//  RecordingMigration.swift
//  OpenBat
//
//  One-time backfill: `Recording` (see ClassificationStore) only started being
//  created going forward once that model landed — WAVs saved before that (or by a
//  build in between that had the new bout scheme but not yet the Recording model)
//  are orphaned files on disk with no entry in recordings.json, so they don't show
//  up in the Listening tab or Playback. This walks Documents/Recordings, reads each
//  WAV's embedded GUANO chunk back out (species/timestamp/session/location), and
//  adds the missing `Recording` entries. Triggered manually from PlaybackListView
//  (a button, not automatic on launch — this does real file IO and FFT work per
//  file, and only needs to run once per orphaned file).
//

import Foundation
import CoreLocation
import UIKit

@MainActor
enum RecordingMigration {

    /// Result of scanning+importing — shown to the user as a summary.
    struct Result {
        var imported = 0
        var skippedNoMetadata = 0
        /// Legacy WAVs tagged NOISE by an earlier build, from before AudioRecorder
        /// started rejecting (deleting) those at save time — left on disk untouched
        /// rather than imported, so the reason the noise-reject feature exists
        /// doesn't get quietly reintroduced through the back door.
        var skippedNoise = 0
    }

    static func run(store: ClassificationStore) async -> Result {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent("Recordings", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return Result() }

        let known = Set(store.recordings.map { $0.relativeWavPath })
        // Snapshot on the main actor — Parsed work below runs off it, so it can't
        // read `store` live; a session's start/end can't change mid-scan anyway.
        let sessions = store.sessions

        var wavURLs: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "wav" {
            let relativePath = String(url.path.dropFirst(docs.path.count + 1))
            guard !known.contains(relativePath) else { continue }
            wavURLs.append(url)
        }

        var result = Result()
        for url in wavURLs {
            let task = Task.detached(priority: .utility) {
                parseAndRender(url: url, docsPath: docs.path, sessions: sessions)
            }
            switch await task.value {
            case .noMetadata:
                result.skippedNoMetadata += 1
            case .rejectedNoise:
                result.skippedNoise += 1
            case .parsed(let parsed):
                store.addRecording(date: parsed.date, durationSeconds: parsed.durationSeconds,
                                   species: parsed.species, confidence: parsed.confidence,
                                   pulseCount: parsed.pulseCount, sessionID: parsed.sessionID,
                                   coordinate: parsed.coordinate, relativeWavPath: parsed.relativeWavPath,
                                   spectrogramImage: parsed.image)
                result.imported += 1
            }
        }
        return result
    }

    // MARK: Off-main-actor work (GUANO parse + spectrogram render)

    private struct Parsed {
        let date: Date
        let durationSeconds: Double
        let species: String
        let confidence: Float?
        let pulseCount: Int
        let sessionID: UUID?
        let coordinate: CLLocationCoordinate2D?
        let relativeWavPath: String
        let image: UIImage?
    }

    private enum ParseOutcome {
        case parsed(Parsed)
        case noMetadata
        case rejectedNoise
    }

    private nonisolated static func parseAndRender(url: URL, docsPath: String, sessions: [RecordingSession]) -> ParseOutcome {
        let relativePath = String(url.path.dropFirst(docsPath.count + 1))
        // No GUANO chunk at all (a corrupt file, or one from before GUANO existed) —
        // nothing reliable to import; skip rather than guess.
        guard let fields = GuanoMetadata.read(from: url) else { return .noMetadata }

        let date = fields["Timestamp"].flatMap { isoFormatter.date(from: $0) }
            ?? (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            ?? Date()
        let durationSeconds = fields["Length"].flatMap(Double.init) ?? 0
        // "Species Auto ID" is "No ID" (with a space, GUANO-readable text) in the
        // chunk but "NOID" (filesystem-safe, matches the filename) as Recording.species
        // everywhere else in the app — see AudioRecorder.AutoIDOutcome.
        let rawSpecies = fields["Species Auto ID"] ?? speciesFromFilename(url) ?? "No ID"
        // Legacy WAVs from before AudioRecorder rejected (deleted) NOISE at save
        // time — don't reintroduce them through the back door; leave the file on
        // disk untouched rather than importing it as a first-class Recording.
        guard rawSpecies != "NOISE" else { return .rejectedNoise }
        let species = rawSpecies == "No ID" ? "NOID" : rawSpecies
        let confidence = fields["OpenBat|Species Confidence"].flatMap { Float($0) }
        let pulseCount = fields["OpenBat|Species Pulse Count"].flatMap { Int($0) } ?? 0
        let coordinate = parseLocPosition(fields["Loc Position"])

        // A GUANO "Listening only" tag is authoritative for what the recorder
        // actually intended at the time; otherwise place it in whichever session's
        // [start, end] window contains the WAV's own timestamp — sessions.json
        // already exists independent of the Recording model, so this is reliable
        // even for a file recorded before Recording existed.
        let sessionID: UUID?
        if fields["OpenBat|Session"] == "Listening only" {
            sessionID = nil
        } else {
            sessionID = sessions.first {
                date >= $0.startDate && date <= ($0.endDate ?? .distantFuture)
            }?.id
        }

        let image = RecordingSpectrogramRenderer.render(wavURL: url)
        return .parsed(Parsed(date: date, durationSeconds: durationSeconds, species: species,
                              confidence: confidence, pulseCount: pulseCount, sessionID: sessionID,
                              coordinate: coordinate, relativeWavPath: relativePath, image: image))
    }

    /// "<yyyy-MM-dd_HH-mm-ss-SSS>_<SPECIES>.wav" → SPECIES — fallback for a WAV
    /// whose GUANO chunk is present but missing (or predates) the species field.
    private nonisolated static func speciesFromFilename(_ url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let lastUnderscore = name.lastIndex(of: "_") else { return nil }
        return String(name[name.index(after: lastUnderscore)...])
    }

    private nonisolated static func parseLocPosition(_ value: String?) -> CLLocationCoordinate2D? {
        guard let value else { return nil }
        let parts = value.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }

    private nonisolated static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
