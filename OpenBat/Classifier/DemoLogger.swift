//
//  DemoLogger.swift
//  OpenBat
//
//  One CSV per demo run, written only when "Demo log" is on in the config menu.
//
//  WHAT IT IS FOR
//  --------------
//  The demo plays a fixed recording through the whole live pipeline, which makes
//  it the one input two phones can be given identically. This writes down what
//  each phone then did with it, in enough detail that two files can be diffed:
//  every pulse the detector kept, every pulse it declined to classify and why it
//  could, every score the model produced, and every pass those pulses were
//  aggregated into.
//
//  WHY IT IS NOT THE CLASSIFIER LOG
//  --------------------------------
//  `ClassificationLogger` is a season-long field record: one rolling file,
//  classified pulses and passes only, capped and archived so it never grows
//  without bound. Comparing two devices needs the opposite of all of that — one
//  self-contained file per run, starting empty, carrying the settings and the
//  hardware it ran on in its own header, and holding the pulses that were NEVER
//  classified too, because "this phone dropped four calls the other one kept" is
//  exactly the finding being looked for and the field log cannot express it.
//
//  Mixing the two would also have meant a demo's rows landing in the middle of
//  somebody's survey data, which is the reason the demo is otherwise kept out of
//  everything persistent (see `ClassificationStore.demoRun`).
//
//  THE HEADER IS HALF THE POINT
//  ----------------------------
//  A run is only comparable if you know what it ran as. The `#` lines at the top
//  carry the device, the OS, the build, the active model and every detector and
//  quality-gate threshold in force, so a difference in the rows can be traced to
//  a difference in the settings rather than argued about. Two files whose
//  headers differ in one line and whose rows differ everywhere have explained
//  themselves.
//
//  OFF UNLESS ASKED, AND ONLY DURING A DEMO
//  ----------------------------------------
//  Nothing here runs unless the switch is on AND a demo is running: `begin` is
//  called from `ContentView.startDemo` and `end` from `endDemo`, and every
//  logging call is a no-op outside that window. Live capture writes nothing here
//  however the switch is set.
//

import Foundation
import UIKit

final class DemoLogger {

    static let shared = DemoLogger()

    /// The config menu's switch. Read at `begin` and not thereafter — a run
    /// logs, or it does not, rather than acquiring a hole in the middle.
    static let enabledKey = "config.demoLog"

    /// Files are named for the clip and the device, so two phones' runs of the
    /// same clip sit side by side in a folder and sort together.
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private let queue = DispatchQueue(label: "bat.DemoLogger", qos: .utility)
    /// nil whenever no run is being logged, which is the whole gate.
    private var fileURL: URL?
    private var runStart: Date?

    /// Ordered union of every model's class codes — the same superset
    /// `ClassificationLogger` uses, and for the same reason: one stable column
    /// layout whichever model produced the row.
    private let classNames: [String] = {
        var seen = Set<String>()
        for model in ModelRegistry.all { for code in model.classNames { seen.insert(code) } }
        return seen.sorted()
    }()

    private init() {}

    var isLogging: Bool { queue.sync { fileURL != nil } }

    /// The file this run is writing, once `begin` has actually opened it. Also
    /// what the tests read back.
    var currentLogURL: URL? { queue.sync { fileURL } }

    /// Waits for every row handed over so far to be on disk.
    ///
    /// Writing is asynchronous on purpose — a row must never make the audio
    /// thread wait — which means "log a row then read the file" is a race, and
    /// the tests do exactly that. Not called by the app.
    func flush() { queue.sync { } }

    // MARK: - The run

    /// Opens a file for this run, or does nothing at all if the switch is off.
    ///
    /// `context` is whatever the caller knows that this type should not go
    /// looking for — the clip, the active model, the detector's thresholds. It
    /// is written verbatim into the header as `# key: value`, in the order
    /// given, so adding a line to the header is adding a pair at the call site.
    ///
    /// `directory` is a parameter only so the tests can write somewhere they can
    /// clean up; the app always takes the default.
    func begin(clip: String, context: [(String, String)],
               defaults: UserDefaults = .standard,
               directory: URL = CloudStorage.baseDirectory) {
        guard defaults.bool(forKey: Self.enabledKey) else { return }
        let start = Date()
        let safeClip = clip.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-",
                                                 options: .regularExpression)
        let name = "demo_\(safeClip)_\(Self.deviceModel)_\(Self.stamp.string(from: start)).csv"
        let url = directory.appendingPathComponent(name)

        queue.async { [self] in
            var header = ""
            for (key, value) in Self.runContext(start: start) + context {
                header += "# \(key): \(value)\n"
            }
            header += columnHeader + "\n"
            try? header.write(to: url, atomically: true, encoding: .utf8)
            fileURL = url
            runStart = start
        }
    }

    /// Closes the run. The file is already on disk — this only stops further
    /// rows, so a live session started straight after a demo cannot append to
    /// it. Returns nothing: the file is found in Files, or shared from the
    /// config menu.
    func end() {
        queue.async { [self] in
            fileURL = nil
            runStart = nil
        }
    }

    // MARK: - Rows

    /// A pulse the detector kept and the model named.
    func logClassifiedPulse(_ result: ClassificationResult,
                            peakFreqHz: Double, durationMs: Double,
                            modelID: String?, at date: Date = Date()) {
        appendRow(kind: "pulse", date: date, species: result.species,
                  confidence: result.confidence, pulseCount: 1, modelID: modelID,
                  peakFreqHz: peakFreqHz, durationMs: durationMs,
                  adjusted: result.allScores, raw: result.rawScores, note: "")
    }

    /// A pulse the detector kept that was never put to a model — identification
    /// switched off, no model active, or a sample rate the model cannot be asked
    /// about. **The row that the field log cannot write**, and the one that
    /// answers "did this phone hear fewer calls, or just name fewer".
    func logUnclassifiedPulse(peakFreqHz: Double, durationMs: Double,
                              note: String, at date: Date = Date()) {
        appendRow(kind: "pulse-unclassified", date: date, species: "UNID",
                  confidence: nil, pulseCount: 1, modelID: nil,
                  peakFreqHz: peakFreqHz, durationMs: durationMs,
                  adjusted: [:], raw: [:], note: note)
    }

    /// The aggregate the pass came to, after the silence timeout closed it.
    func logPass(_ result: ClassificationResult, pulseCount: Int,
                 modelID: String?, at date: Date = Date()) {
        appendRow(kind: "pass", date: date, species: result.species,
                  confidence: result.confidence, pulseCount: pulseCount,
                  modelID: modelID, peakFreqHz: nil, durationMs: nil,
                  adjusted: result.allScores, raw: result.rawScores, note: "")
    }

    /// A pass that closed with nothing classified in it.
    func logUnclassifiedPass(pulseCount: Int, species: String, at date: Date = Date()) {
        appendRow(kind: "pass-unclassified", date: date, species: species,
                  confidence: nil, pulseCount: pulseCount, modelID: nil,
                  peakFreqHz: nil, durationMs: nil, adjusted: [:], raw: [:], note: "")
    }

    // MARK: - Writing

    /// `internal` so the tests can assert the layout, the way
    /// `ClassificationLogger.expectedHeader` is.
    var columnHeader: String {
        (["time", "elapsed_s", "kind", "species", "confidence", "pulse_count",
          "model", "peak_khz", "duration_ms", "note"]
         + classNames.map { "adj_\($0)" }
         + classNames.map { "raw_\($0)" }).joined(separator: ",")
    }

    private func appendRow(kind: String, date: Date, species: String,
                           confidence: Float?, pulseCount: Int, modelID: String?,
                           peakFreqHz: Double?, durationMs: Double?,
                           adjusted: [String: Float], raw: [String: Float],
                           note: String) {
        queue.async { [self] in
            guard let fileURL, let runStart else { return }
            var fields = [
                Self.timeFormatter.string(from: date),
                String(format: "%.3f", date.timeIntervalSince(runStart)),
                kind,
                species,
                confidence.map { String(format: "%.4f", $0) } ?? "",
                String(pulseCount),
                modelID ?? "",
                peakFreqHz.map { String(format: "%.2f", $0 / 1000) } ?? "",
                durationMs.map { String(format: "%.2f", $0) } ?? "",
                // Commas are the only character a note could plausibly carry
                // that would break the row, and quoting one field is not worth a
                // CSV writer.
                note.replacingOccurrences(of: ",", with: ";"),
            ]
            // "0" and not "0.0000" for a class the row's model does not have —
            // the same economy `ClassificationLogger.makeRow` makes, and on a
            // 48-column double table it is most of the file.
            fields += classNames.map { adjusted[$0].map { String(format: "%.4f", $0) } ?? "0" }
            fields += classNames.map { raw[$0].map { String(format: "%.4f", $0) } ?? "0" }

            guard let data = (fields.joined(separator: ",") + "\n").data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - What this device is

    /// The hardware string — "iPhone16,2" — not the marketing name, because the
    /// point of a comparison is knowing exactly which two machines are being
    /// compared and `UIDevice.model` says "iPhone" on every one of them.
    static let deviceModel: String = {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        // Read as bytes and stop at the first NUL, rather than rebinding the
        // tuple to a `CChar` pointer and handing it to `String(validatingUTF8:)`
        // — the usual spelling of this, and wrong: the capacity it passes is the
        // size of the POINTER, not of the 256-byte field, so the string is read
        // past the end of what was bound. It happens to work until it doesn't.
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        // Commas separate columns and this string has one in it.
        return machine.isEmpty ? "unknown" : machine.replacingOccurrences(of: ",", with: "-")
    }()

    private static func runContext(start: Date) -> [(String, String)] {
        let bundle = Bundle.main.infoDictionary
        return [
            ("started", timeFormatter.string(from: start)),
            ("device", deviceModel),
            ("os", "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"),
            ("app", "\(bundle?["CFBundleShortVersionString"] as? String ?? "?")"
                  + " (\(bundle?["CFBundleVersion"] as? String ?? "?"))"),
            ("processors", String(ProcessInfo.processInfo.processorCount)),
            ("thermal_state", String(describing: ProcessInfo.processInfo.thermalState)),
        ]
    }

    // MARK: - Getting them off the phone

    /// Every demo log there is, zipped. Same `NSFileCoordinator(.forUploading)`
    /// trick as `ClassificationLogger.makeShareItem` — no zip dependency.
    /// Returns nil when there are none, so the caller can say so rather than
    /// sharing an empty folder.
    func makeShareItem() -> URL? {
        let fm = FileManager.default
        let logs = existingLogs()
        guard !logs.isEmpty else { return nil }
        let stage = fm.temporaryDirectory.appendingPathComponent("OpenBat-demo-logs", isDirectory: true)
        try? fm.removeItem(at: stage)
        guard (try? fm.createDirectory(at: stage, withIntermediateDirectories: true)) != nil else {
            return logs.first
        }
        queue.sync {
            for url in logs {
                try? fm.copyItem(at: url, to: stage.appendingPathComponent(url.lastPathComponent))
            }
        }
        var zipURL: URL?
        NSFileCoordinator().coordinate(readingItemAt: stage, options: [.forUploading], error: nil) { tempZip in
            let dest = fm.temporaryDirectory.appendingPathComponent("OpenBat-demo-logs.zip")
            try? fm.removeItem(at: dest)
            if (try? fm.moveItem(at: tempZip, to: dest)) != nil { zipURL = dest }
        }
        return zipURL ?? logs.first
    }

    func existingLogs() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: CloudStorage.baseDirectory, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix("demo_") && $0.pathExtension == "csv" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func deleteAllLogs() {
        queue.async { [self] in
            for url in existingLogs() where url != fileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
