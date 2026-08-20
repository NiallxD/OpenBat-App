//
//  SpeciesFeedView.swift
//  OpenBat
//
//  Merlin Sound ID-style "recently detected" stack: one row per species, the
//  most recently heard on top. Swaps in for the spectrogram or pulse-zoom panel
//  when the matching Settings toggle is on (see SettingsView).
//
//  Backed by ClassificationStore.speciesFeed(sessionID:), which dedupes
//  `passes` (already newest-first) by species — no separate ordering state to
//  maintain here, a re-detection just bumps its row back to the top on the
//  next addPass.
//

import SwiftUI

struct SpeciesFeedView: View {
    let store: ClassificationStore
    /// Only used to resolve a species code to a field-guide page for the book
    /// button on each row — held as references and never read in this body, so
    /// they add no invalidation of their own.
    let guide: SpeciesGuideStore
    let presenceStore: SpeciesPresenceStore
    let activeSessionID: UUID?
    /// When the current run started (nil when nothing is running) — see
    /// ClassificationStore.speciesFeed(sessionID:since:) for why this matters.
    let sessionStart: Date?
    /// A narrow host — the pulse-view panel, and its column in the iPad-landscape
    /// layout — has no room for the pulse thumbnail, text and badge to share a
    /// row, so that placement passes false.
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
                        // Keyed by species, not `pass.id`: a re-detection of an
                        // already-listed species produces a brand-new PassRecord
                        // (fresh UUID, see ClassificationStore.addPass), and keying
                        // on that would make SwiftUI tear down and recreate the row
                        // out from under the user — silently closing its pulse-detail
                        // sheet mid-view. The feed already dedupes to one entry per
                        // species (speciesFeed(sessionID:since:)), so species is a
                        // stable identity across re-detections; the row survives and
                        // just receives the newer `pass` value.
                        ForEach(entries, id: \.species) { pass in
                            SpeciesFeedRow(pass: pass, store: store, guide: guide,
                                           presenceStore: presenceStore,
                                           showsThumbnail: showsThumbnail)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(8)
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: entries.map(\.species))
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
    let guide: SpeciesGuideStore
    let presenceStore: SpeciesPresenceStore
    let showsThumbnail: Bool

    /// Tapping a row opens the same pass-detail screen the Sessions list uses —
    /// the pulses behind the ID, per-pulse score bars, runner-up, complex notes.
    @State private var showDetail = false
    /// The field-guide page for this species, when the guide has one. Opened by
    /// the book button rather than by the row itself, so the two destinations —
    /// "what did the app hear" and "what is this animal" — stay distinct.
    @State private var profile: GuideSpecies?
    @State private var image: UIImage?

    /// nil whenever the guide has no page for this code, which is the common
    /// case: the models name far more bats than the community guide describes.
    /// The button is simply absent then — offering a link to a page that doesn't
    /// exist is worse than offering none.
    private var guidePage: GuideSpecies? {
        pass.isNoID ? nil : guide.guide.species(forCode: pass.species)
    }

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
            // this feed is in a narrow panel (e.g. the pulse-view column of the
            // iPad-landscape layout).
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
        .task(id: representativePulse?.id) {
            guard let pulse = representativePulse else { return }
            image = await store.loadImage(for: pulse)
        }
        .sheet(item: $profile) { page in
            NavigationStack {
                SpeciesDetailView(species: page, store: guide, presenceStore: presenceStore)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { profile = nil }
                        }
                    }
            }
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
    // pulse-view column there's ~100 pt for this text and
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
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 4) {
                    ConfidenceBadge(confidence: pass.confidence)
                    ComplexIndicator(pass: pass)
                }
                guideButton
            }
        }
    }

    /// Opens the species' field-guide page from the detector, without leaving
    /// it. This shortcut used to live on the species cell in the stats card;
    /// it came back here when that cell was removed (2026-08-16), which is the
    /// better home for it anyway — this row already IS the species.
    ///
    /// Its own tap target rather than a second gesture on the row: the row goes
    /// to the pass detail (the evidence behind this identification), and the
    /// book goes to the profile (the animal itself). Those are different
    /// questions and a single tap can't serve both.
    @ViewBuilder private var guideButton: some View {
        if let page = guidePage {
            Button { profile = page } label: {
                Image(systemName: "book.closed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.batAccent)
                    .frame(width: 30, height: 30)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Field guide page for \(page.commonName)")
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

    /// Optional, and the `?? pulses.first` matters: `max(by:)` returns nil
    /// EXACTLY when the array is empty, so the old `?? pass.pulses[0]` fallback
    /// could only ever run in the one case where index 0 is out of bounds — a
    /// guaranteed crash dressed as a default. Live construction always guards
    /// against an empty `pulses` (PulseDetector.finalizePass, and again in
    /// ClassificationStore.addPass), but a PassRecord decoded from a corrupt or
    /// future-schema recordings.json has no such guarantee. The thumbnail view
    /// already renders a placeholder for a nil image.
    private var representativePulse: PulseRecord? {
        pass.pulses.max(by: { $0.confidence < $1.confidence }) ?? pass.pulses.first
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
