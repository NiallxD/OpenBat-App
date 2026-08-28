//
//  SessionExport.swift
//  OpenBat
//
//  Bundles one session into a single .zip for the share sheet: every recording's
//  WAV plus three CSVs of everything else the session holds.
//
//    • <title>.csv            — a row per recording: the file, its ID, when and
//                               where, with the session's own fields repeated.
//    • <title>-detections.csv — a row per pass, which is where the evidence
//                               lives: BOTH confidences (see below), runner-up,
//                               complex, pulse count.
//    • <title>-priors.csv     — what the classifier was weighted with, stamped
//                               when the session opened and again on any
//                               mid-session re-derivation.
//    • <title>-pulses.csv     — a row per species score per pulse: the finest
//                               grain OpenBat keeps, and what a pass's numbers
//                               are actually made of.
//
//  TWO CONFIDENCES, AND WHY BOTH SHIP
//  ----------------------------------
//  `confidence` is prior-adjusted: it has the user's location and species
//  settings baked into it, so the same call recorded by two people can carry two
//  different numbers. `raw_confidence` is the model's own top score before any
//  of that. Only the raw figure is comparable across users, across settings, and
//  against a re-run of the same file — and only the priors CSV explains the gap
//  between the two. Exporting either alone would be exporting a number nobody
//  downstream can interpret.
//
//  Zips the same way `WavExport` does — NSFileCoordinator's `.forUploading`
//  coordinated read hands back a zipped copy of a directory, so no third-party
//  zip dependency is needed.
//

import Foundation

nonisolated enum SessionExport {

    /// A recording flattened to plain values, so the export can run off the main
    /// actor without touching `ClassificationStore`.
    struct Row: Sendable {
        let recordingID: UUID
        let wavURL: URL
        let date: Date
        let durationSeconds: Double
        let species: String
        let commonName: String
        let confidence: Float?
        let pulseCount: Int
        let latitude: Double?
        let longitude: Double?
        let uploadStatus: String
    }

    /// One pass — PulseDetector's "run of pulses" grouping, finer than a
    /// recording and the level the classifier actually reasons at.
    struct Detection: Sendable {
        let passID: UUID
        let date: Date
        let species: String
        let commonName: String
        /// Prior-adjusted mean posterior for the reported species.
        let confidence: Float
        /// Mean top RAW score across the pass's pulses, before priors. nil for
        /// passes recorded before OpenBat kept it.
        let rawConfidence: Float?
        let pulseCount: Int
        let runnerUpSpecies: String?
        let runnerUpConfidence: Float?
        let complexID: String?
        let complexAmbiguous: Bool?
        let latitude: Double?
        let longitude: Double?
    }

    /// One species' weight in one snapshot — the priors table flattened, so it
    /// opens as a table rather than as nested JSON.
    struct PriorRow: Sendable {
        let takenAt: Date
        let modelID: String
        let species: String
        let prior: Float
        let enabled: Bool
    }

    /// One species score on one pulse. Long format — a pulse's six scores are
    /// six rows repeating the pulse's own columns — matching `PriorRow`. Wide
    /// format would need `score_1_species`…`score_6_value` columns that mean
    /// something different in every row, which no tool groups or filters on.
    ///
    /// **These are the prior-adjusted scores.** The per-pulse RAW scores are not
    /// persisted — they exist only long enough for `PassAggregation` to run its
    /// NoID gate, so the raw figure OpenBat keeps is the pass-level mean in
    /// `Detection.rawConfidence`, not anything per pulse.
    struct PulseScore: Sendable {
        let passID: UUID
        let pulseID: UUID
        let date: Date
        /// The pulse's own winning species and its renormalized posterior.
        let pulseSpecies: String
        let pulseConfidence: Float
        let peakFreqHz: Double
        let durationMs: Double
        /// 1-based position in the pulse's score list, strongest first. nil on
        /// the placeholder row written for a pulse that stored no scores.
        let rank: Int?
        let species: String?
        let score: Float?
    }

    struct Input: Sendable {
        let sessionID: UUID
        let title: String
        let notes: String
        let startDate: Date
        let endDate: Date?
        let rows: [Row]
        let detections: [Detection]
        let priors: [PriorRow]
        let pulseScores: [PulseScore]
    }

    /// How far along an export is. `bytesTotal` is the size of the WAVs going
    /// in, which is the only quantity known up front — see `Phase` for what that
    /// does and doesn't buy in each leg.
    struct Progress: Sendable {
        enum Phase: Sendable {
            /// Copying WAVs into the staging folder. Real, byte-accurate
            /// progress: both numbers are known.
            case copying
            /// Zipping the staging folder. **No progress is available here** —
            /// `NSFileCoordinator`'s coordinated read is one opaque call that
            /// returns when it returns, so this phase reports its start and then
            /// nothing until it's done. Anything shown against it is the
            /// caller's own estimate (see `SessionExportManager`).
            case compressing
        }
        let phase: Phase
        let bytesDone: Int64
        let bytesTotal: Int64
    }

    /// Total size of the WAVs going into the zip — what the progress bar
    /// measures itself against. Cheap: attribute reads, no data.
    static func inputBytes(_ input: Input) -> Int64 {
        input.rows.reduce(0) { total, row in
            let size = (try? row.wavURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    /// Builds the zip and returns its URL. Pure file IO — call it off the main
    /// actor, since copying a night's worth of WAVs and zipping them is slow.
    ///
    /// A WAV that can't be copied (an iCloud file whose bytes haven't landed on
    /// this device yet) is left out rather than failing the whole export; its row
    /// still appears in the CSV, with an empty `wav_file` cell to say so.
    ///
    /// Cancellable between files, and once more before the zip starts. **Not
    /// during the zip**: the coordinated read is a single blocking call with no
    /// interruption point, so a cancel that lands there takes effect only when it
    /// returns — the staging folder is cleaned up and nothing is handed back.
    ///
    /// Cancellation arrives as a closure rather than being read off
    /// `Task.isCancelled`, because this runs on a plain dispatch queue where
    /// there is no task to ask — see `SessionExportManager.build`.
    static func makeShareItem(_ input: Input,
                              isCancelled: @Sendable () -> Bool = { false },
                              onProgress: @Sendable (Progress) -> Void = { _ in }) -> URL? {
        let fm = FileManager.default
        let baseName = safeName(input.title)
        let stage = fm.temporaryDirectory.appendingPathComponent(baseName, isDirectory: true)
        try? fm.removeItem(at: stage)
        guard (try? fm.createDirectory(at: stage, withIntermediateDirectories: true)) != nil else {
            return nil
        }

        // Ask iCloud for anything that's still a placeholder before doing
        // anything else, so the downloads run while the rest of this works.
        for row in input.rows where !CloudStorage.isDownloaded(row.wavURL) {
            CloudStorage.ensureDownloaded(row.wavURL)
        }

        let totalBytes = inputBytes(input)
        var copiedBytes: Int64 = 0
        onProgress(Progress(phase: .copying, bytesDone: 0, bytesTotal: totalBytes))

        let recordingsDir = stage.appendingPathComponent("Recordings", isDirectory: true)
        try? fm.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        var includedNames: [UUID: String] = [:]
        for row in input.rows {
            if isCancelled() { try? fm.removeItem(at: stage); return nil }
            let name = row.wavURL.lastPathComponent
            let size = Int64((try? row.wavURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            defer {
                copiedBytes += size
                onProgress(Progress(phase: .copying, bytesDone: copiedBytes, bytesTotal: totalBytes))
            }
            guard CloudStorage.isDownloaded(row.wavURL),
                  (try? fm.copyItem(at: row.wavURL, to: recordingsDir.appendingPathComponent(name))) != nil
            else { continue }
            includedNames[row.recordingID] = name
        }
        // An export with no audio at all is still worth making — the CSV is the
        // point for a session whose files live on another device — but the empty
        // folder would just be noise in the zip.
        if includedNames.isEmpty { try? fm.removeItem(at: recordingsDir) }

        let csv = csvText(input, includedNames: includedNames)
        try? Data(csv.utf8).write(to: stage.appendingPathComponent("\(baseName).csv"))
        // Written even when empty — a header row with nothing under it says "no
        // passes were logged", where a missing file says "this export is old" or
        // "something went wrong".
        try? Data(detectionsCSV(input).utf8)
            .write(to: stage.appendingPathComponent("\(baseName)-detections.csv"))
        try? Data(priorsCSV(input).utf8)
            .write(to: stage.appendingPathComponent("\(baseName)-priors.csv"))
        try? Data(pulsesCSV(input).utf8)
            .write(to: stage.appendingPathComponent("\(baseName)-pulses.csv"))

        if isCancelled() { try? fm.removeItem(at: stage); return nil }
        onProgress(Progress(phase: .compressing, bytesDone: copiedBytes, bytesTotal: totalBytes))

        var zipURL: URL?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: stage, options: [.forUploading], error: &coordError) { tempZip in
            // `tempZip` is system-managed and deleted when this closure returns —
            // move it somewhere we control and hand that back.
            let dest = fm.temporaryDirectory.appendingPathComponent("\(baseName).zip")
            try? fm.removeItem(at: dest)
            if (try? fm.moveItem(at: tempZip, to: dest)) != nil { zipURL = dest }
        }
        try? fm.removeItem(at: stage)
        if isCancelled() {
            if let zipURL { try? fm.removeItem(at: zipURL) }
            return nil
        }
        return zipURL
    }

    /// One row per recording, with the session's own fields repeated on each —
    /// a flat table opens in a spreadsheet or R without anyone having to join
    /// anything back together.
    private static func csvText(_ input: Input, includedNames: [UUID: String]) -> String {
        let columns = [
            "session_id", "session_title", "session_start", "session_end", "session_notes",
            "recording_id", "wav_file", "recorded_at", "duration_seconds",
            "species", "common_name", "confidence", "pulse_count",
            "latitude", "longitude", "upload_status",
        ]
        var lines = [columns.joined(separator: ",")]
        for row in input.rows {
            let fields = [
                input.sessionID.uuidString,
                input.title,
                stamp(input.startDate),
                input.endDate.map(stamp) ?? "",
                input.notes,
                row.recordingID.uuidString,
                includedNames[row.recordingID] ?? "",
                stamp(row.date),
                String(format: "%.3f", row.durationSeconds),
                row.species,
                row.commonName,
                row.confidence.map { String(format: "%.4f", $0) } ?? "",
                String(row.pulseCount),
                row.latitude.map { String(format: "%.6f", $0) } ?? "",
                row.longitude.map { String(format: "%.6f", $0) } ?? "",
                row.uploadStatus,
            ]
            lines.append(fields.map(escaped).joined(separator: ","))
        }
        // Trailing newline: a CSV without one is a valid file that some tools
        // still read as a truncated last row.
        return lines.joined(separator: "\n") + "\n"
    }

    /// A row per pass. Separate from the recordings table because the two don't
    /// line up one-to-one: a recording is one saved WAV (a whole bout), and it
    /// can contain several passes — a bat making more than one approach.
    private static func detectionsCSV(_ input: Input) -> String {
        let columns = [
            "session_id", "session_title", "pass_id", "detected_at",
            "species", "common_name", "confidence", "raw_confidence", "pulse_count",
            "runner_up_species", "runner_up_confidence",
            "complex_id", "complex_ambiguous", "latitude", "longitude",
        ]
        var lines = [columns.joined(separator: ",")]
        for d in input.detections {
            let fields = [
                input.sessionID.uuidString,
                input.title,
                d.passID.uuidString,
                stamp(d.date),
                d.species,
                d.commonName,
                String(format: "%.4f", d.confidence),
                d.rawConfidence.map { String(format: "%.4f", $0) } ?? "",
                String(d.pulseCount),
                d.runnerUpSpecies ?? "",
                d.runnerUpConfidence.map { String(format: "%.4f", $0) } ?? "",
                d.complexID ?? "",
                d.complexAmbiguous.map { $0 ? "true" : "false" } ?? "",
                d.latitude.map { String(format: "%.6f", $0) } ?? "",
                d.longitude.map { String(format: "%.6f", $0) } ?? "",
            ]
            lines.append(fields.map(escaped).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A row per species per snapshot. `taken_at` is what ties a detection to
    /// the weights in force when it happened: use the latest snapshot at or
    /// before the detection's own timestamp.
    private static func priorsCSV(_ input: Input) -> String {
        let columns = ["session_id", "taken_at", "model_id", "species", "prior", "enabled"]
        var lines = [columns.joined(separator: ",")]
        for p in input.priors {
            let fields = [
                input.sessionID.uuidString,
                stamp(p.takenAt),
                p.modelID,
                p.species,
                String(format: "%.4f", p.prior),
                p.enabled ? "true" : "false",
            ]
            lines.append(fields.map(escaped).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A row per score per pulse — see `PulseScore` for the shape and for what
    /// "score" means here (prior-adjusted, not raw).
    private static func pulsesCSV(_ input: Input) -> String {
        let columns = [
            "session_id", "pass_id", "pulse_id", "detected_at",
            "pulse_species", "pulse_confidence", "peak_freq_hz", "duration_ms",
            "score_rank", "score_species", "score",
        ]
        var lines = [columns.joined(separator: ",")]
        lines.reserveCapacity(input.pulseScores.count + 1)
        for p in input.pulseScores {
            let fields = [
                input.sessionID.uuidString,
                p.passID.uuidString,
                p.pulseID.uuidString,
                stamp(p.date),
                p.pulseSpecies,
                String(format: "%.4f", p.pulseConfidence),
                String(format: "%.1f", p.peakFreqHz),
                String(format: "%.2f", p.durationMs),
                p.rank.map(String.init) ?? "",
                p.species ?? "",
                p.score.map { String(format: "%.4f", $0) } ?? "",
            ]
            lines.append(fields.map(escaped).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Local time with its UTC offset, not plain UTC — when a bat was heard is
    /// read against dusk, and a reader shouldn't have to convert back.
    private static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }

    private static func escaped(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Session titles carry a place name ("29 Jun 2026 · Mendip Hills") and a
    /// middle dot, which are fine in a filename — path separators and colons are
    /// not.
    private static func safeName(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Session" : cleaned
    }
}
