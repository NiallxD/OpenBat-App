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

import Foundation

final class ClassificationLogger {

    static let shared = ClassificationLogger()

    private(set) var fileURL: URL
    private let queue = DispatchQueue(label: "bat.ClassificationLogger", qos: .background)

    // Ordered class names — must match BatClassifier.classNames
    private let classNames = BatClassifier.classNames

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("bat_classifier_log.csv")
        writeHeaderIfNeeded()
    }

    // MARK: - Public

    /// Log a single-pulse classification result.
    func logPulse(_ result: ClassificationResult, at date: Date = Date()) {
        let row = makeRow(type: "pulse", date: date, result: result, pulseCount: 1)
        append(row)
    }

    /// Log the aggregated pass result.
    func logPass(_ result: ClassificationResult, pulseCount: Int, at date: Date = Date()) {
        let row = makeRow(type: "pass", date: date, result: result, pulseCount: pulseCount)
        append(row)
    }

    /// Delete the log file and recreate the header.
    func clearLog() {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: fileURL)
            writeHeaderIfNeeded()
        }
    }

    // MARK: - Private

    private func writeHeaderIfNeeded() {
        queue.async { [self] in
            guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
            let speciesCols = classNames.joined(separator: ",")
            let header = "timestamp,type,species,confidence_pct,pulse_count,\(speciesCols)\n"
            try? header.write(to: fileURL, atomically: false, encoding: .utf8)
        }
    }

    private static let iso8601 = ISO8601DateFormatter()

    private func makeRow(type: String, date: Date, result: ClassificationResult, pulseCount: Int) -> String {
        let ts = Self.iso8601.string(from: date)
        let conf = String(format: "%.1f", result.confidence * 100)
        let scores = classNames.map { name in
            String(format: "%.4f", result.allScores[name] ?? 0)
        }.joined(separator: ",")
        return "\(ts),\(type),\(result.species),\(conf),\(pulseCount),\(scores)\n"
    }

    private func append(_ row: String) {
        queue.async { [self] in
            guard let data = row.data(using: .utf8) else { return }
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
