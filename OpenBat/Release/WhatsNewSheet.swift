//
//  WhatsNewSheet.swift
//  OpenBat
//
//  The screen the bundled changelog becomes. Shown once after an update, and
//  reachable any time from Info & Tour.
//
//  Built in OpenBat's own idiom rather than as a grouped `List`: a dark
//  scrolling column, an accent glyph per row, a section heading in plain type —
//  the same shape `AppInfoView`'s feature list and onboarding's cards already
//  use. A `List` with `.insetGrouped` would be the quickest way to render this,
//  and it would be the only screen in the app that looked like Settings.
//

import SwiftUI

// MARK: - What's New

/// The scrolling body, without a `NavigationStack` of its own, so it can be
/// both a sheet (after an update) and a pushed screen (from Info & Tour)
/// without either one nesting a stack inside another.
struct WhatsNewContent: View {
    @State private var showFullLog = false

    private var release: ChangeLogRelease { ChangeLog.latest }

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    if release.isEmpty {
                        // A release with no notes is a mistake in the changelog,
                        // not a state to design for — but it must not present as
                        // an empty white void either.
                        Text("No release notes for this version.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(release.sections) { section in
                            sectionView(section)
                        }
                    }

                    Button { showFullLog = true } label: {
                        Label("Everything that's changed", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.top, 4)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("What's New")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showFullLog) { ChangeLogView() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 30))
                .foregroundStyle(Color.batAccent)
                .frame(width: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(release.title.isEmpty ? "This release" : release.title)
                    .font(.title3.bold())
                Text("Here's what changed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sectionView(_ section: ChangeLogSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.heading)
                .font(.headline)
            ForEach(section.items) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: section.symbol)
                        .font(.system(size: 18))
                        .foregroundStyle(Color.batAccent)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if !item.detail.isEmpty {
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

// MARK: - Sheet presentation

/// What's New as a sheet — the once-per-update presentation.
struct WhatsNewSheet: View {
    /// Called on dismissal, however it happens: the button, the drag indicator,
    /// or a swipe down. Stamping the build as seen lives with the caller, and it
    /// has to happen on all three routes out, which is what `.onDisappear` here
    /// buys over doing the work inside the button.
    var onDismiss: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WhatsNewContent()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Got it!") { dismiss() }
                            .fontWeight(.semibold)
                    }
                }
        }
        .onDisappear(perform: onDismiss)
    }
}

// MARK: - Full change log

/// Every release, rendered as ordinary Markdown. Deliberately plainer than
/// What's New: this is a reference someone scrolls looking for when a thing
/// changed, not a screen selling the release.
struct ChangeLogView: View {
    private var lines: [String] {
        ChangeLog.allReleasesMarkdown.components(separatedBy: .newlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    ChangeLogLine(line: line)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Change Log")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ChangeLogLine: View {
    let line: String

    var body: some View {
        Group {
            if line.hasPrefix("### ") {
                Text(line.dropFirst(4))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.batAccent)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
            } else if line.hasPrefix("## ") {
                Text(line.dropFirst(3))
                    .font(.headline)
                    .padding(.top, 18)
                    .padding(.bottom, 2)
            } else if line.hasPrefix("# ") {
                // The file's own "# Changelog" title, which the navigation bar
                // already says. Dropped rather than drawn twice.
                EmptyView()
            } else if line.hasPrefix("---") {
                Divider().padding(.vertical, 10)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(Color.batAccent)
                    inlineText(String(line.dropFirst(2)))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                Spacer().frame(height: 4)
            } else {
                inlineText(line)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline Markdown — bold, italic, code — via `AttributedString`. Falls back
    /// to the raw text if the line won't parse, which is better than showing
    /// nothing for one malformed release note.
    private func inlineText(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text) {
            return Text(attributed)
        }
        return Text(text)
    }
}
