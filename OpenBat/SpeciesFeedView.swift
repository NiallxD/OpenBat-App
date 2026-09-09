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
    /// True when identification is switched off remotely rather than simply
    /// unselected. The two look identical in the feed and need opposite
    /// messages: one is a thing the user can fix in Settings, the other is not.
    var identificationDisabled: Bool = false

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
            emptyMessage
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityLabel(emptyMessageAccessibilityLabel)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `Text`, not `String`, so the pre-session message can carry the start
    /// button's own glyph inline (Niall, 2026-09-09). "Start detecting to see
    /// species here" named an action without saying where it is; the card is
    /// the first thing a new user looks at in simplified view, and the button
    /// it means is in the tab bar. `play.fill` is the glyph that button
    /// actually shows when idle — see `sessionButtonSymbol`.
    private var emptyMessage: Text {
        if identificationDisabled {
            // No instruction, because there is nothing the user can do — and no
            // reason either, because the launch notice already gave one.
            return Text("Identification is switched off.")
        }
        if !autoIDActive {
            return Text("No AutoID model is active. Turn one on in Settings ▸ AutoID to identify species.")
        }
        guard sessionStart == nil else { return Text("No species detected yet") }
        return Text("Tap the play button (\(Image(systemName: "play.fill"))) to start detecting, species detected will appear here")
    }

    /// VoiceOver reads an `Image` interpolated into a `Text` as nothing at all,
    /// so the glyph is spelled out here rather than leaving a sentence with a
    /// hole in the middle of it.
    private var emptyMessageAccessibilityLabel: String {
        if identificationDisabled { return "Identification is switched off." }
        if !autoIDActive {
            return "No AutoID model is active. Turn one on in Settings, AutoID, to identify species."
        }
        guard sessionStart == nil else { return "No species detected yet" }
        return "Tap the play button to start detecting, species detected will appear here"
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
            VStack(alignment: .leading, spacing: 2) {
                // Name and score on one line. The two badges sit beside each
                // other rather than stacked: stacked, a row with both of them
                // was taller than the photo beside it for no reason, and the
                // score and the caveat about it belong together.
                HStack(alignment: .top, spacing: 8) {
                    titleAndTime(now: context.date)
                    Spacer(minLength: 4)
                    trailingBadges
                }
                // The runner-up/noise lines and the two destinations share the
                // bottom line — the text explains the ID, the buttons leave for
                // the animal (guide) or the evidence (pulses).
                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) { secondaryLines }
                    Spacer(minLength: 4)
                    actionButtons
                }
            }
            .opacity(isStale ? 0.5 : 1)
            .animation(.easeInOut(duration: 0.6), value: isStale)
            .padding(.vertical, 10)
            .padding(.trailing, 10)
            // Room for the photo, which is drawn behind rather than beside the
            // text: a `.background` is handed the text block's own height, so
            // the photo fills the row's full height whatever the runner-up
            // lines do to it. In an HStack it could only match by being given a
            // height nothing here knows in advance.
            .padding(.leading, showsThumbnail ? Self.photoWidth + 10 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                if showsThumbnail { thumbnail }
            }
        }
        .background(.ultraThinMaterial)
        // Clips the photo as well as the fill, which is what lets the picture
        // run into the card's leading edge and pick up its corners.
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // The row goes to the animal, not to the evidence (Niall, 2026-09-02).
        // A row that has just named a bat is read as that bat, and the guide
        // page is what nearly every tap on it was after; the pulses behind the
        // ID are one deliberate tap away on the button. Falls back to the
        // pulses for a species the guide has no page for — the models name far
        // more bats than the guide describes, and a dead tap is worse than the
        // wrong destination.
        .onTapGesture {
            if let page = guidePage { profile = page } else { showDetail = true }
        }
        // No thumbnail decode here any more: the row shows the guide photo when
        // there is a species and the app's own mark when there is not, so the
        // pulse image it used to load was being decoded and then never drawn.
        // The shared modal wrapper rather than a stack of its own: this row and
        // the stats strip were presenting the same page two ways, and the bar
        // treatment only has to be decided once.
        .sheet(item: $profile) { page in
            SpeciesProfileSheet(species: page, store: guide, presenceStore: presenceStore)
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

    /// The leading photo's width. The row's height comes out close to it, so the
    /// picture reads as the square end of the card.
    private static let photoWidth: CGFloat = 78

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

    // No NoID line here: `ClassificationStore.speciesFeed` filters those out
    // before they reach a row, so a case for them would describe a state this
    // view cannot be in.
    @ViewBuilder private var secondaryLines: some View {
        if pass.isNoise {
            Text("NOISE means it wasn't a bat")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        if let runnerUp = pass.runnerUpSpecies {
            // Two lines rather than one wrapped one: the label is fixed and the
            // name is not, so wrapping broke the species across lines and put
            // half of "Runner-up:" on the second one.
            Text("Runner-up:")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text((SpeciesInfo.commonName[runnerUp] ?? runnerUp)
                 + (pass.runnerUpConfidence.map { String(format: " (%.0f%%)", $0 * 100) } ?? ""))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    @ViewBuilder private var trailingBadges: some View {
        // A NOID pass has no meaningful confidence number (it's exactly the case
        // where the model never settled on anything) — showing "0%" would read as
        // a real score rather than "we don't know".
        if !pass.isNoID {
            HStack(spacing: 6) {
                ConfidenceBadge(confidence: pass.confidence)
                ComplexIndicator(pass: pass)
            }
        }
    }

    /// The row's two destinations. The guide button repeats what a tap on the
    /// row does; the pulses button is the only way to the evidence behind the
    /// identification, which the row itself used to open.
    ///
    /// Absent in the narrow placement (`showsThumbnail == false`, the pulse-view
    /// column of the iPad-landscape layout) — there is about 100pt of row there
    /// and the badges already have it.
    @ViewBuilder private var actionButtons: some View {
        if showsThumbnail {
            HStack(spacing: 8) {
                guideButton
                actionButton(systemImage: "waveform.badge.magnifyingglass",
                             label: "Pulses behind this identification") {
                    showDetail = true
                }
            }
        }
    }

    private func actionButton(systemImage: String,
                              label: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.batAccent)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Opens the species' field-guide page from the detector, without leaving
    /// it. This shortcut used to live on the species cell in the stats card;
    /// it came back here when that cell was removed (2026-08-16), which is the
    /// better home for it anyway — this row already IS the species.
    ///
    /// Now the same destination as a tap on the row, kept because it is the only
    /// thing on the row that SAYS a species page is there to be opened.
    @ViewBuilder private var guideButton: some View {
        if let page = guidePage {
            actionButton(systemImage: "book.closed",
                         label: "Field guide page for \(page.commonName)") {
                profile = page
            }
        }
    }

    /// **The guide photo, when the guide has one — the bat, not the sound it
    /// made.** This used to be the pulse spectrogram unconditionally, which is
    /// the evidence rather than the answer: at 44pt a pulse reads as a smear,
    /// and a row that says "Common Pipistrelle" is far better illustrated by a
    /// picture of one (Niall, 2026-09-01). The spectrogram hasn't gone anywhere
    /// — it's still what the pass-detail screen a tap away is made of.
    ///
    /// Falls back to the pulse for a species the guide doesn't describe, which
    /// is the common case rather than the exceptional one: the models name far
    /// more bats than the community guide covers (see `guidePage`). A row with
    /// no photo available keeps showing what it always did instead of a blank
    /// tile.
    @ViewBuilder private var thumbnail: some View {
        if let guidePage {
            GuideSpeciesThumbnail(species: guidePage, size: Self.photoWidth, fillsHeight: true)
        } else {
            // No guide page means no species — see `UnknownSpeciesThumbnail` for
            // why this no longer falls back to the pass's own spectrogram.
            UnknownSpeciesThumbnail(reason: pass.isNoise ? .notABat : .unidentified,
                                    size: Self.photoWidth, fillsHeight: true)
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
