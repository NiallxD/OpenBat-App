//
//  RecordingImporter.swift
//  OpenBat
//
//  Brings a WAV the user picks with the system document picker into the
//  recordings library, so an external file — a reference recording, something
//  from another detector, a call library download — opens in WavPlayerView and
//  auditions through the listening modes exactly like a recording the app made
//  itself.
//
//  This is the only way to get a known-good bat call through the listening modes
//  without a live bat. `PlaybackEngine` drives heterodyne / time expansion from
//  a file at its NATIVE sample rate (see
//  `PlaybackEngine.load`, which passes the file's rate straight into each
//  processor's `reset`), so importing a 384 kHz recording exercises the real DSP
//  path with no microphone, speaker or signal generator in the loop — none of
//  which can reproduce ultrasound faithfully enough to judge the result.
//
//  SPLIT IN TWO ON PURPOSE, and the split matters:
//
//    • `copyIntoLibrary` must run SYNCHRONOUSLY inside the `.fileImporter`
//      completion handler. The sandbox extension the document picker grants is
//      scoped to that call; an earlier version of this file did the copy inside
//      a `Task.detached`, by which point the extension was gone,
//      `startAccessingSecurityScopedResource()` was useless and `copyItem` failed
//      with a permissions error. A file copy is fast enough to accept on the
//      main actor — even 23 MB is a few tens of milliseconds.
//
//    • `renderOverview` is the genuinely slow part (a full FFT pass over the
//      file) and takes a URL inside our OWN container, so it needs no sandbox
//      extension and belongs on a background task.
//

import AVFoundation
import CoreLocation
import Foundation
import UIKit

nonisolated enum RecordingImporter {

    enum ImportError: LocalizedError {
        case noAccess
        case notAudio(String)
        case emptyFile
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAccess:
                return "The file could not be opened. If it's stored in iCloud Drive, open it in the Files app once to download it, then try again."
            case .notAudio(let why):
                return "That file could not be read as audio. \(why)"
            case .emptyFile:
                return "That file contains no audio."
            case .copyFailed(let why):
                return "The file could not be copied into the recordings library. \(why)"
            }
        }
    }

    /// A file already copied into our container, ready for `renderOverview` and
    /// then `ClassificationStore.addRecording`. `Sendable` so it can cross into
    /// the background render task.
    struct Copied: Sendable {
        let url: URL
        let relativeWavPath: String
        let date: Date
        let durationSeconds: Double
        let sampleRate: Double
        /// From the file's own GUANO chunk when it has one. `species` is "NOID"
        /// for a file with no usable metadata.
        let species: String
        let confidence: Float?
        let pulseCount: Int
        let coordinate: CLLocationCoordinate2D?
    }

    /// Copies the picked file into `Recordings/Imported/<day>/` and probes its
    /// format. **Call this synchronously from the `.fileImporter` completion
    /// handler** — see the file comment for why deferring it breaks.
    static func copyIntoLibrary(source: URL) throws -> Copied {
        // A document-picker URL points outside the app container and needs an
        // explicit sandbox extension held across the read.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        // A URL already inside our container isn't security-scoped and
        // `startAccessing...` correctly returns false for it, so failing on
        // that alone would be wrong — test actual readability instead.
        guard scoped || FileManager.default.isReadableFile(atPath: source.path) else {
            throw ImportError.noAccess
        }

        let probe: AVAudioFile
        do {
            probe = try AVAudioFile(forReading: source)
        } catch {
            throw ImportError.notAudio(error.localizedDescription)
        }
        let sampleRate = probe.fileFormat.sampleRate
        let frames = probe.length
        guard sampleRate > 0, frames > 0 else { throw ImportError.emptyFile }

        // Deliberately its own `Imported/` tree rather than mixing into
        // `Listening/` or `Sessions/`: `RecordingMigration` scans those to
        // re-adopt WAVs the store lost track of, and inferring a session or a
        // capture date from an imported filename would be wrong.
        let docs = CloudStorage.baseDirectory
        let dayFormatter = ISO8601DateFormatter()
        dayFormatter.formatOptions = [.withFullDate]
        let dir = docs.appendingPathComponent(
            "Recordings/Imported/\(dayFormatter.string(from: Date()))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let base = source.deletingPathExtension().lastPathComponent
        var dest = dir.appendingPathComponent("\(base).wav")
        var suffix = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base)-\(suffix).wav")
            suffix += 1
        }
        do {
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }

        // Same relative-path derivation `AudioRecorder` uses.
        let relative = String(dest.path.dropFirst(docs.path.count + 1))

        // Read the file's own GUANO chunk if it has one, so re-importing a
        // recording OpenBat exported round-trips its species, confidence, pulse
        // count, capture timestamp and GPS position instead of arriving as a
        // dateless "NoID". Shared with RecordingMigration — see
        // GuanoRecordingFields.
        //
        // Falls back to the file's modification date so an imported file with no
        // metadata still sorts by roughly when it was recorded rather than when
        // it was imported.
        let fallbackDate = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let guano = GuanoMetadata.read(from: dest).map {
            GuanoRecordingFields.parse($0, wavURL: dest, fallbackDate: fallbackDate)
        }

        // Unlike RecordingMigration, a NOISE tag is not grounds for rejection
        // here: the user deliberately picked this file, and silently refusing it
        // would be baffling. Demote it to NOID and let them listen.
        let species = (guano?.isNoise ?? true) ? "NOID" : (guano?.species ?? "NOID")

        // GUANO's own "Length" is authoritative when present, but the frame count
        // we just probed is measured from the actual data chunk, so prefer that.
        let measured = Double(frames) / sampleRate

        return Copied(url: dest,
                      relativeWavPath: relative,
                      date: guano?.date ?? fallbackDate,
                      durationSeconds: measured > 0 ? measured : (guano?.durationSeconds ?? 0),
                      sampleRate: sampleRate,
                      species: species,
                      confidence: species == "NOID" ? nil : guano?.confidence,
                      pulseCount: guano?.pulseCount ?? 0,
                      coordinate: guano?.coordinate)
    }

    /// Overview thumbnail for an already-copied file. Slow (a full FFT pass), so
    /// call it off the main actor — but safe to defer, because the URL is inside
    /// our own container and needs no sandbox extension.
    ///
    /// maxWidth 4096 matches what `AudioRecorder` requests and what
    /// `WavSpectrogramEngine.renderOverview` looks for, so the WAV player's cache
    /// hits instead of re-rendering on first open.
    static func renderOverview(at url: URL) -> UIImage? {
        RecordingSpectrogramRenderer.render(wavURL: url, maxWidth: 4096)
    }
}
