//
//  SpeciesFeedView.swift
//  OpenBat
//
//  Merlin Sound ID-style "recently detected" stack: one row per species, the
//  most recently heard on top. Swaps in for the spectrogram or pulse-zoom panel
//  when the matching Settings toggle is on (see SettingsView's Display tab).
//
//  Backed by ClassificationStore.speciesFeed(sessionID:), which dedupes
//  `passes` (already newest-first) by species — no separate ordering state to
//  maintain here, a re-detection just bumps its row back to the top on the
//  next addPass.
//

import SwiftUI

struct SpeciesFeedView: View {
    let store: ClassificationStore
    let activeSessionID: UUID?
    /// When the current run started (nil when nothing is running) — see
    /// ClassificationStore.speciesFeed(sessionID:since:) for why this matters.
    let sessionStart: Date?
    /// The pulse-view column in iPhone landscape is too narrow for the pulse
    /// thumbnail + text + badge to share a row — that placement passes false.
    var showsThumbnail: Bool = true
    /// False when no AutoID model is active (`AutoIDSettings.activeModelID == nil`) —
    /// the feed can never populate in that state, so the empty view explains how to
    /// turn a classifier on instead of implying the app is just waiting for a bat.
    var autoIDActive: Bool = true

    private var entries: [PassRecord] {
        store.speciesFeed(sessionID: activeSessionID, since: sessionStart)
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(entries) { pass in
                            SpeciesFeedRow(pass: pass, store: store, showsThumbnail: showsThumbnail)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(8)
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: entries.map(\.id))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 6) {
            if autoIDActive {
                Image("batIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Text(emptyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        if !autoIDActive {
            return "No AutoID model is active. Turn one on in Settings ▸ AutoID to identify species."
        }
        return sessionStart == nil ? "Start detecting to see species here" : "No species detected yet"
    }
}

private struct SpeciesFeedRow: View {
    let pass: PassRecord
    let store: ClassificationStore
    let showsThumbnail: Bool

    /// Tapping a row opens the same pass-detail screen the Sessions list uses —
    /// the pulses behind the ID, per-pulse score bars, runner-up, complex notes.
    @State private var showDetail = false
    @State private var image: UIImage?

    var body: some View {
        // Re-evaluates every second so "3s ago" keeps counting up without needing a
        // new detection to trigger a redraw.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // Ages out on the same `staleIDSeconds` clock that reds the species
            // stat cell — a dimmed row reads as "heard earlier", matching the
            // stat panel instead of implying the bat is still overhead.
            let isStale = context.date.timeIntervalSince(pass.date) > staleIDSeconds
            // The runner-up/noise lines sit below the main row at full width —
            // sharing the middle column with the name scrunches everything when
            // this feed is in a narrow panel (e.g. the pulse-view column in
            // iPhone landscape).
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    if showsThumbnail {
                        thumbnail
                    }
                    titleAndTime(now: context.date)
                    Spacer(minLength: 4)
                    trailingBadges
                }
                secondaryLines
            }
            .opacity(isStale ? 0.5 : 1)
            .animation(.easeInOut(duration: 0.6), value: isStale)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { showDetail = true }
        .task(id: representativePulse.id) {
            image = await store.loadImage(for: representativePulse)
        }
        .sheet(isPresented: $showDetail) {
            NavigationStack {
                PassDetailView(pass: pass, store: store)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showDetail = false }
                        }
                    }
            }
        }
    }

    // Both lines shrink a little rather than wrap or truncate — in the narrow
    // pulse-view column (iPhone landscape) there's ~100 pt for this text and
    // "Spotted Bat" / "EUMA · 29s ago" would otherwise become "Spo…" and a
    // three-line caption.
    private func titleAndTime(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pass.commonName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(pass.species) · \(Self.timeAgo(pass.date, now: now))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    @ViewBuilder private var secondaryLines: some View {
        if pass.isNoise {
            Text("NOISE means it wasn't a bat")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        if pass.isNoID {
            Text("Triggered, but couldn't be classified")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        if let runnerUp = pass.runnerUpSpecies {
            Text("Runner-up: \(SpeciesInfo.commonName[runnerUp] ?? runnerUp)"
                 + (pass.runnerUpConfidence.map { String(format: " (%.0f%%)", $0 * 100) } ?? ""))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var trailingBadges: some View {
        // A NOID pass has no meaningful confidence number (it's exactly the case
        // where the model never settled on anything) — showing "0%" would read as
        // a real score rather than "we don't know".
        if !pass.isNoID {
            VStack(alignment: .trailing, spacing: 4) {
                ConfidenceBadge(confidence: pass.confidence)
                ComplexIndicator(pass: pass)
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(width: 44, height: 44)
                .overlay { Image(systemName: "waveform").font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private var representativePulse: PulseRecord {
        pass.pulses.max(by: { $0.confidence < $1.confidence }) ?? pass.pulses[0]
    }

    /// Natural, exact-at-short-intervals relative time. `RelativeDateTimeFormatter`
    /// reads oddly for sub-minute deltas (rounds to "in 0 seconds"/"now" oddly and
    /// doesn't tick smoothly second-by-second); a plain seconds/minutes/hours
    /// switch is simpler and exact, and pairs with the `TimelineView` above to
    /// stay live.
    private static func timeAgo(_ d: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(d)))
        switch s {
        case 0..<60:     return "\(s)s ago"
        case 60..<3600:  return "\(s / 60)m ago"
        case 3600..<86400: return "\(s / 3600)h ago"
        default:         return "\(s / 86400)d ago"
        }
    }
}
