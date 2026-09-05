//
//  INatLog.swift
//  OpenBat
//
//  What OpenBat said to iNaturalist and what came back.
//
//  WHY THIS EXISTS
//  ---------------
//  The first live post failed with "iNaturalist returned HTTP 404", which was
//  true and useless: the reason was that every request had been going to
//  `api.inaturalist.org/observations` instead of `.../v2/observations`, and
//  nothing on the screen or in the code could have told you that. A status code
//  without the URL that produced it is not a diagnosis. Network failures out in
//  a field at 1 a.m. are not reproducible on a desk, so the log has to be
//  written while it happens and readable afterwards.
//
//  WHAT IS DELIBERATELY NOT IN IT
//  ------------------------------
//  The log is written to be handed to somebody else — that is its whole point —
//  so it must be safe to hand over:
//
//    • No tokens. Not the OAuth access token, not the JWT, not the PKCE
//      verifier. Authorization headers are logged as present or absent.
//    • No exact coordinates. They are rounded to 2 decimal places (~1 km),
//      because a bat record's precise location is the one piece of this that
//      could disclose a roost.
//
//  Everything else is fair game, including the response body, because that is
//  where iNaturalist explains itself.
//
//  IN MEMORY, NOT ON DISK
//  ----------------------
//  A ring of the last few hundred lines, lost when the app closes. Posting is a
//  foreground action somebody is watching, so the log only has to outlive the
//  request — and a file would be one more thing holding location data that
//  nobody remembered to delete.
//

import Foundation
import os

nonisolated final class INatLog {

    static let shared = INatLog()

    private let lock = OSAllocatedUnfairLock(initialState: [String]())
    private static let capacity = 300

    private init() {}

    /// Also goes to the unified log, so a session attached to Xcode shows this
    /// live rather than only after somebody thinks to copy it out.
    private static let system = Logger(subsystem: "com.openbat", category: "iNaturalist")

    func append(_ line: String) {
        let stamped = "\(Self.stamp.string(from: .now))  \(line)"
        Self.system.debug("\(line, privacy: .public)")
        lock.withLock { lines in
            lines.append(stamped)
            if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
        }
    }

    var isEmpty: Bool { lock.withLock { $0.isEmpty } }

    /// The whole log, oldest first, ready to paste into a bug report.
    var text: String {
        let body = lock.withLock { $0.joined(separator: "\n") }
        return """
        OpenBat — iNaturalist log
        \(Self.stamp.string(from: .now))
        Tokens are never logged; coordinates are rounded to ~1 km.

        \(body)
        """
    }

    func clear() {
        lock.withLock { $0.removeAll() }
    }

    // MARK: What the client calls

    func request(_ method: String, _ url: URL, authorized: Bool, body: String? = nil) {
        append("→ \(method) \(url.absoluteString)\(authorized ? "" : "  [no auth header]")")
        if let body { append("   body: \(Self.redact(body))") }
    }

    func response(_ method: String, _ url: URL, status: Int, seconds: TimeInterval, body: Data?) {
        let mark = (200..<300).contains(status) ? "✓" : "✗"
        append(String(format: "← %@ %d  %@ %@  (%.2fs)", mark, status, method, url.path, seconds))
        // Only failures carry their body. A successful reply is confirmation,
        // not evidence, and pasting a whole observation into the log every time
        // would push the interesting lines off the end of the ring.
        guard !(200..<300).contains(status), let body, !body.isEmpty else { return }
        let text = String(decoding: body.prefix(2048), as: UTF8.self)
        append("   said: \(Self.redact(text))")
    }

    func failure(_ method: String, _ url: URL, error: Error) {
        let nsError = error as NSError
        append("← ✗ \(method) \(url.path) — \(nsError.domain) \(nsError.code): \(error.localizedDescription)")
    }

    func note(_ message: String) {
        append("· \(message)")
    }

    // MARK: Redaction

    /// Blunt on purpose. A regex that tries to be clever about which JSON field
    /// holds a credential is a regex that will one day miss one; these patterns
    /// cover everything the app sends or receives that must not be in a log, and
    /// the cost of over-redacting is a slightly less useful line.
    private static func redact(_ text: String) -> String {
        var out = text
        for key in ["access_token", "api_token", "code_verifier", "refresh_token", "code"] {
            out = out.replacingOccurrences(
                of: "\"\(key)\"\\s*:\\s*\"[^\"]*\"",
                with: "\"\(key)\":\"<redacted>\"",
                options: .regularExpression)
        }
        // Coordinates, in the JSON the app posts: keep enough to see that a
        // location was sent and that it is the right order of magnitude.
        out = out.replacingOccurrences(
            of: "\"(latitude|longitude)\"\\s*:\\s*(-?\\d+\\.\\d\\d)\\d*",
            with: "\"$1\":$2…",
            options: .regularExpression)
        return out
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
