//
//  ChangeLog.swift
//  OpenBat
//
//  Reads the bundled `Resources/CHANGELOG.md` and turns its newest release into
//  the What's New screen. The Markdown file is the single source of truth: the
//  release title, the sections, every item, and whether the release should
//  re-run onboarding all come out of it, so shipping a release note is editing
//  one file rather than editing one file and remembering to mirror it in code.
//
//  The format is documented at the top of the changelog itself, where whoever
//  is writing a release note will actually be looking. Two things about the
//  parser worth knowing from this side:
//
//  • **Only the first `##` block is read for What's New.** Newest release first
//    is not a convention here, it is the contract — the parser stops at the
//    second `##` it sees.
//  • **The re-onboarding directive is only honoured inside a release block.**
//    That is what lets the file's own header comment name the directive while
//    explaining it, without arming it. Anything above the first `##` is
//    documentation, not configuration.
//

import Foundation

// MARK: - Model

/// One parsed release: everything What's New needs to draw itself.
struct ChangeLogRelease: Equatable {
    /// The `##` heading, verbatim — "v0.8.9 (Build 89)". Shown as the screen's
    /// subtitle rather than being picked apart, so the heading is whatever the
    /// person writing the note decided it should be.
    let title: String
    let sections: [ChangeLogSection]
    /// The release asked, in the changelog, for onboarding to be shown again.
    /// Acting on this is `ReleaseState`'s job, not this type's.
    let requiresReonboarding: Bool

    var isEmpty: Bool { sections.allSatisfy(\.items.isEmpty) }
}

struct ChangeLogSection: Equatable, Identifiable {
    let id = UUID()
    /// The `###` heading, verbatim. Not mapped onto a fixed set of categories:
    /// a release that wants a section called "For iPad" should get one.
    let heading: String
    let items: [ChangeLogItem]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.heading == rhs.heading && lhs.items == rhs.items
    }
}

struct ChangeLogItem: Equatable, Identifiable {
    let id = UUID()
    let title: String
    /// Empty when the bullet had no em dash — a short item is allowed to be a
    /// title on its own.
    let detail: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.detail == rhs.detail
    }
}

// MARK: - Parser

enum ChangeLog {
    /// The directive that arms re-onboarding, matched case-insensitively inside
    /// an HTML comment. Spelled out here once so the file and the parser cannot
    /// drift apart.
    static let reonboardDirective = "openbat: reonboard"

    /// The newest release, parsed once. A missing or unreadable changelog gives
    /// an empty release rather than throwing: a broken release note must not be
    /// able to stop the app launching, and What's New simply doesn't appear.
    static let latest: ChangeLogRelease = parseLatest(from: rawText ?? "")

    /// The whole file, comments stripped, for the full change log screen.
    static var allReleasesMarkdown: String { stripComments(rawText ?? "") }

    static var isAvailable: Bool { rawText != nil }

    private static let rawText: String? = {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return raw
    }()

    // MARK: Release parsing

    static func parseLatest(from raw: String) -> ChangeLogRelease {
        var title = ""
        var sections: [ChangeLogSection] = []
        var heading = ""
        var items: [ChangeLogItem] = []
        var insideRelease = false
        var reonboard = false
        // HTML comments are spread over several lines in this file, so comment
        // state has to be carried between them rather than tested per line.
        var insideComment = false

        func closeSection() {
            guard !items.isEmpty else { items = []; return }
            sections.append(ChangeLogSection(heading: heading, items: items))
            items = []
        }

        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Comment handling first: a `##` inside a comment is an example, not
            // a release, and the header comment of the shipped file contains
            // exactly that.
            if insideComment {
                if insideRelease, line.lowercased().contains(reonboardDirective) {
                    reonboard = true
                }
                if line.contains("-->") { insideComment = false }
                continue
            }
            if line.hasPrefix("<!--") {
                if insideRelease, line.lowercased().contains(reonboardDirective) {
                    reonboard = true
                }
                // A single-line comment opens and closes on the same line.
                if !line.contains("-->") { insideComment = true }
                continue
            }

            if line.hasPrefix("## ") {
                // The second release heading ends the newest release.
                if insideRelease { break }
                title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                insideRelease = true
                continue
            }
            guard insideRelease else { continue }

            if line.hasPrefix("### ") {
                closeSection()
                heading = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                items.append(parseItem(String(line.dropFirst(2))))
            }
        }
        closeSection()

        return ChangeLogRelease(title: title, sections: sections, requiresReonboarding: reonboard)
    }

    /// Splits `**Title** — detail` into its two halves.
    ///
    /// Three dash characters are accepted because all three get typed: a real em
    /// dash, an en dash, and a hyphen with spaces round it. Only the FIRST one
    /// splits, so a detail containing its own dash survives intact.
    static func parseItem(_ bullet: String) -> ChangeLogItem {
        let text = bullet.replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespaces)
        for separator in [" — ", " – ", " - "] {
            guard let range = text.range(of: separator) else { continue }
            let title = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let detail = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty && !detail.isEmpty {
                return ChangeLogItem(title: title, detail: detail)
            }
        }
        return ChangeLogItem(title: text, detail: "")
    }

    /// Drops HTML comment blocks, so the authoring instructions at the top of
    /// the file never appear on the full change log screen.
    static func stripComments(_ raw: String) -> String {
        var output: [String] = []
        var insideComment = false
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if insideComment {
                if trimmed.contains("-->") { insideComment = false }
                continue
            }
            if trimmed.hasPrefix("<!--") {
                if !trimmed.contains("-->") { insideComment = true }
                continue
            }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }
}

// MARK: - Icons

extension ChangeLogSection {
    /// A glyph for the section, chosen from its heading. Deliberately only three
    /// buckets plus a default: the point is that "Fixed" reads differently from
    /// "New" at a glance, not that every heading gets bespoke art.
    var symbol: String {
        let text = heading.lowercased()
        if text.contains("fix") { return "wrench.and.screwdriver.fill" }
        if text.contains("improve") || text.contains("better") { return "arrow.up.circle.fill" }
        if text.contains("new") || text.contains("added") { return "sparkles" }
        return "circle.fill"
    }
}
