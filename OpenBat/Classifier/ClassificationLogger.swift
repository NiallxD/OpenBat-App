//
//  ClassificationLogger.swift
//  OpenBat
//
//  Appends classification events to Documents/bat_classifier_log.csv.
//  Visible in the Files app under OpenBat once UIFileSharingEnabled is set.
//
//  Each row is one event. Two event types:
//    pulse  — single-pulse raw + adjusted scores (for per-call inspection)
//    pass   — aggregated result after silence timeout (the field ID)
//
//  The score columns are the UNION of every registered model's class codes (NABat's
//  4-letter codes and BatDetect2's 6-letter codes don't overlap), and each row also
//  carries a `model` column. Previously the columns were hard-wired to NABat's class
//  list, so every score logged for any other active model landed under names that
//  didn't exist in its output and came out as 0.0000 — a silently empty score matrix
//  for BatDetect2. The superset keeps one stable, analysis-friendly CSV that's correct
//  for whichever model produced the row.
//
//  Kept as CSV, deliberately. It is a wide, fully-rectangular table of numbers —
//  the shape CSV is smallest for. JSON would repeat all 48 score-column names on
//  every single row, several times the size for the same content; the honest
//  wins here are not re-encoding but writing "0" rather than "0.0000" for the
//  columns belonging to the model that didn't produce the row (see `makeRow`),
//  the size cap below, and zipping on the way out (see `makeShareItem`).
//
//  Size management: the active file is capped at `maxLogBytes`. When an append would
//  push it past that, the current file is rolled to a timestamped archive
//  (`bat_classifier_log_v2-<stamp>.csv`) and a fresh header-only file takes over, so
//  no single file grows without bound over a long survey season. At most `maxArchives`
//  rolled files are kept; older ones are pruned. (Separate from the header-change
//  rotation, which starts a fresh file when the column set changes.)
//

import Foundation

final class ClassificationLogger {

    static let shared = ClassificationLogger()

    private(set) var fileURL: URL
    private let queue = DispatchQueue(label: "bat.ClassificationLogger", qos: .background)

    /// Roll the active file once it reaches this size. 5 MB is thousands of rows —
    /// plenty of recent context for inspection — while capping worst-case disk use
    /// at `maxLogBytes * (maxArchives + 1)` (~30 MB) no matter how long the app runs.
    private static let maxLogBytes = 5 * 1024 * 1024
    /// Rolled files kept before the oldest is pruned.
    private static let maxArchives = 5
    /// Sortable, filesystem-safe stamp so archive names order lexically by age.
    private static let archiveStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let archivePrefix = "bat_classifier_log_v2-"

    /// Ordered union of every registered model's class codes — the stable superset of
    /// score columns (see the file header). Deduped across models, sorted so the column
    /// order is deterministic regardless of registry order.
    private let classNames: [String] = {
        var seen = Set<String>()
        for model in ModelRegistry.all { for code in model.classNames { seen.insert(code) } }
        return seen.sorted()
    }()

    private init() {
        let docs = CloudStorage.baseDirectory
        // v2: the header (and thus column layout) changed with the model column + union
        // score columns, so use a fresh filename rather than appending rows with a new
        // shape onto a pre-fix `bat_classifier_log.csv`.
        fileURL = docs.appendingPathComponent("bat_classifier_log_v2.csv")
        writeHeaderIfNeeded()
    }

    // MARK: - Public

    /// Log a single-pulse classification result. `modelID` names the classifier that
    /// produced it (for the `model` column) — pass `AutoIDSettings.activeModelID`.
    func logPulse(_ result: ClassificationResult, modelID: String?, at date: Date = Date()) {
        append(makeRow(type: "pulse", date: date, result: result, pulseCount: 1, modelID: modelID))
    }

    /// Log the aggregated pass result.
    func logPass(_ result: ClassificationResult, pulseCount: Int, modelID: String?, at date: Date = Date()) {
        append(makeRow(type: "pass", date: date, result: result, pulseCount: pulseCount, modelID: modelID))
    }

    /// The whole log — the active file plus every rolled archive — staged into a
    /// temp folder and zipped, for the share sheet. Returns the zip, or the bare
    /// active CSV if zipping fails.
    ///
    /// Zipped, and not just because these are big: the archives are the older
    /// half of the picture and a share that silently dropped them would be
    /// misleading to anyone reading the log. CSV of this shape compresses by
    /// well over ten to one, so a season's worth arrives as a small attachment.
    /// Same `NSFileCoordinator(.forUploading)` trick as `WavExport` — no zip
    /// dependency.
    func makeShareItem() -> URL {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("OpenBat-classifier-log", isDirectory: true)
        try? fm.removeItem(at: stage)
        guard (try? fm.createDirectory(at: stage, withIntermediateDirectories: true)) != nil else {
            return fileURL
        }
        // Copies taken ON `queue`, so none of them can catch a half-written row.
        queue.sync {
            for url in [fileURL] + archiveURLs() {
                try? fm.copyItem(at: url, to: stage.appendingPathComponent(url.lastPathComponent))
            }
        }

        var zipURL: URL?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: stage, options: [.forUploading], error: &coordError) { tempZip in
            // `tempZip` is system-managed and deleted when this closure returns.
            let dest = fm.temporaryDirectory.appendingPathComponent("OpenBat-classifier-log.zip")
            try? fm.removeItem(at: dest)
            if (try? fm.moveItem(at: tempZip, to: dest)) != nil { zipURL = dest }
        }
        return zipURL ?? fileURL
    }

    /// Bytes on disk for the active file and every archive together — what the
    /// log actually costs, which is what the settings row reports.
    func totalBytesOnDisk() -> Int {
        queue.sync {
            ([fileURL] + archiveURLs()).reduce(0) { total, url in
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                return total + ((attrs?[.size] as? Int) ?? 0)
            }
        }
    }

    /// Delete the active log and every rolled archive, then recreate the header.
    func clearLog() {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: fileURL)
            for url in archiveURLs() { try? FileManager.default.removeItem(at: url) }
            writeHeaderSyncIfNeeded()
        }
    }

    // MARK: - Private

    // `internal` (not private) so OpenBatTests can assert the column layout directly —
    // the union-of-class-codes header is exactly what regressed once before (scores
    // logged under a hardwired NABat column list). See ClassificationLoggerTests.
    var expectedHeader: String {
        "timestamp,type,model,species,confidence_pct,pulse_count," + classNames.joined(separator: ",") + "\n"
    }

    private func writeHeaderIfNeeded() {
        queue.async { [self] in writeHeaderSyncIfNeeded() }
    }

    /// Header-write body, run synchronously on `queue`. Split out so rotation (also
    /// on `queue`) can lay down the fresh file's header inline without a nested
    /// async hop that could interleave with the append that triggered it.
    private func writeHeaderSyncIfNeeded() {
        let headerData = Data(expectedHeader.utf8)
        // Recreate if absent, or if the leading bytes no longer match the expected
        // header (e.g. a later app version registered a new model, widening the union
        // of score columns) — appending under a stale header would misalign every
        // subsequent row. This is a diagnostic log, so a rare column-set change
        // starting a fresh file is acceptable.
        // Same trap as `append` — see the note there. Absent is the NORMAL case
        // on a first run, so this path takes it constantly.
        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forReadingFrom: fileURL) {
            let existing = try? handle.read(upToCount: headerData.count)
            try? handle.close()
            if existing == headerData { return }
        }
        try? expectedHeader.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Rolls the active file to a timestamped archive once it reaches `maxLogBytes`,
    /// then reopens a fresh header-only file and prunes old archives. Runs on `queue`
    /// (called from `append`), so file-size check → move → recreate → prune is atomic
    /// with respect to the writes around it.
    private func rotateIfNeeded() {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let bytes = attrs[.size] as? Int, bytes >= Self.maxLogBytes
        else { return }

        let stamp = Self.archiveStamp.string(from: Date())
        let archiveURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(Self.archivePrefix)\(stamp).csv")
        do {
            try FileManager.default.moveItem(at: fileURL, to: archiveURL)
        } catch {
            // Couldn't roll (rare) — leave the current file in place rather than
            // risk losing rows; it'll just exceed the cap until the next attempt.
            return
        }
        writeHeaderSyncIfNeeded()   // fresh active file
        pruneArchives()
    }

    /// Rolled archives, oldest first (names sort lexically by their timestamp stamp).
    private func archiveURLs() -> [URL] {
        let dir = fileURL.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(Self.archivePrefix) && $0.pathExtension == "csv" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func pruneArchives() {
        let archives = archiveURLs()
        let excess = archives.count - Self.maxArchives
        guard excess > 0 else { return }
        for url in archives.prefix(excess) { try? FileManager.default.removeItem(at: url) }
    }

    private static let iso8601 = ISO8601DateFormatter()

    // `internal` for the same reason as `expectedHeader` — the regression test asserts
    // the `model` column is populated and score columns align with the header.
    func makeRow(type: String, date: Date, result: ClassificationResult,
                 pulseCount: Int, modelID: String?) -> String {
        let ts = Self.iso8601.string(from: date)
        let conf = String(format: "%.1f", result.confidence * 100)
        // A bare "0" for absent/zero classes rather than "0.0000". Every row
        // carries the UNION of both models' class codes, so 17 or 31 of the 48
        // score columns are real and the rest are structurally zero — at five
        // wasted bytes each that was roughly half the file. Same columns, same
        // parse, about half the bytes. (Encoding the whole log as JSON would go
        // the other way: it repeats all 48 column NAMES on every row.)
        let scores = classNames.map { name in
            let score = result.allScores[name] ?? 0
            return score == 0 ? "0" : String(format: "%.4f", score)
        }.joined(separator: ",")
        return "\(ts),\(type),\(modelID ?? "—"),\(result.species),\(conf),\(pulseCount),\(scores)\n"
    }

    private func append(_ row: String) {
        queue.async { [self] in
            rotateIfNeeded()
            guard let data = row.data(using: .utf8) else { return }
            // The existence check is not belt-and-braces, it is the whole point.
            // `FileHandle(forWritingTo:)` on a path that isn't there does not
            // reliably throw: the Objective-C initialiser can return nil without
            // setting an error, and Swift's failable-init bridging then traps
            // with "invalid reuse after initialization failure" — a crash, from
            // inside a `try?` that looks like it has already handled failure.
            // The file genuinely can be missing here: Clear Log removes it, and
            // it lives in iCloud Drive (`CloudStorage.baseDirectory`), where it
            // can be evicted underneath a running app.
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                try? data.write(to: fileURL)
                return
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
