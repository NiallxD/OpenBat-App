//
//  SpeciesComparisonView.swift
//  OpenBat
//
//  Two species pages on screen at once, for telling a pair of similar bats
//  apart without holding one of them in your head while you read the other.
//  Reached from any species collection: the compare button in the toolbar arms
//  the mode, then you tap the two species (see `SpeciesCollectionView`).
//
//  The panes are the real `SpeciesDetailView`, not a summary of it — every
//  card, in the same order, so whatever you learn to look for on one page is in
//  the same place on the other.
//
//  **The scrolls are linked, and only one direction at a time.** Whichever pane
//  your finger is on leads; the other follows by snapping its matching section
//  to the top as the leading pane reaches it. So a slow read down one bat's
//  page walks the other bat's page through the same headings, and the fact you
//  are reading is always beside the fact you would compare it with. Following
//  is by SECTION, never by offset — the two pages are different heights and a
//  proportional follow would drift apart within a screen or two. A section the
//  other species has no entry for is simply not there to scroll to, so that
//  pane holds still rather than jumping somewhere arbitrary.
//
//  The toolbar unlinks them, for reading two pages at once rather than
//  comparing them point by point.
//
//  Deliberately unfinished in one respect: each pane still opens with the full
//  260pt hero photo, which on a phone is most of a pane's height before a
//  single fact. A thumbnail-in-the-header variant is the obvious next move —
//  left as-is for now so the split can be judged on its own (Niall,
//  2026-08-26).
//

import SwiftUI

struct SpeciesComparisonView: View {
    let first: GuideSpecies
    let second: GuideSpecies
    let store: SpeciesGuideStore
    let presenceStore: SpeciesPresenceStore

    /// Side by side on a regular width, stacked on a compact one. Keyed on
    /// width alone rather than on orientation or idiom: iPhone landscape does
    /// not exist in this app (see `AppTabBar`), so "wide" and "iPad landscape"
    /// are the same condition, and one that Split View and Slide Over already
    /// answer correctly.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Off means the panes scroll on their own, as they did before linking
    /// existed. Persisted: whichever way someone reads a comparison, they read
    /// every comparison that way.
    @AppStorage("guide.compareLinkedScroll") private var linked = true

    /// Where each pane has been told to scroll to. Written for the FOLLOWER
    /// only; the leader is never pushed around by the pane it is driving.
    @State private var scrollTarget: [Side: GuideSection] = [:]

    /// The pane the finger is on. Nothing follows anything until someone
    /// actually scrolls, and only the other pane ever follows — without this
    /// the follower's own movement would drive the leader straight back and the
    /// two would shove each other down the page.
    @State private var leader: Side?

    private enum Side: Hashable { case first, second }

    var body: some View {
        // **A `GeometryReader`, and it has to be.** The panes were sized by
        // measuring themselves and handing that width back down to the pages
        // inside them, which fed back on itself: with no width yet, a page asks
        // for its container's width, so the pane inherited that demand, measured
        // the container's width, and handed the container's width back. Both
        // halves ended up a full window wide, the split overflowed the screen,
        // and each page hung off an outer edge with its middle hidden behind the
        // other pane. A reader takes the space it is OFFERED and ignores what
        // its content asks for, which breaks the loop at the only point it can
        // be broken.
        GeometryReader { geometry in
            let sideBySide = horizontalSizeClass == .regular
            // The 1pt is the divider's. Without subtracting it the two halves
            // add up to a point more than there is, and the split overflows
            // again — by much less, but visibly.
            let paneWidth = sideBySide ? (geometry.size.width - 1) / 2 : geometry.size.width
            let paneHeight = sideBySide ? geometry.size.height : (geometry.size.height - 1) / 2

            if sideBySide {
                HStack(spacing: 0) {
                    pane(first, side: .first, width: paneWidth, height: paneHeight)
                    Divider()
                    pane(second, side: .second, width: paneWidth, height: paneHeight)
                }
            } else {
                VStack(spacing: 0) {
                    pane(first, side: .first, width: paneWidth, height: paneHeight)
                    Divider()
                    pane(second, side: .second, width: paneWidth, height: paneHeight)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        // No title. Two species pages need every point of height they can get,
        // and a large-title bar saying "Compare" over a screen that visibly is
        // one buys nothing — the pane strips already name what you are looking
        // at. Inline mode keeps the bar itself (Back, and the link button) at
        // its shortest.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    linked.toggle()
                    leader = nil
                } label: {
                    // Plain `link`. It has no fill and `link.slash` is not a
                    // symbol at all, so the state is carried entirely by the
                    // tint below — orange for linked, default for not.
                    //
                    // Not rotated with the layout, unlike the compare button:
                    // this one is about SCROLLING, and the pages scroll
                    // vertically whether they are stacked or side by side.
                    Image(systemName: "link")
                }
                .tint(linked ? Color.batAccent : nil)
                .accessibilityLabel(linked
                                    ? "Scrolling is linked. Turn off to scroll each page on its own."
                                    : "Scrolling is separate. Turn on to keep the two pages together.")
            }
        }
    }

    private func pane(_ species: GuideSpecies, side: Side,
                      width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            paneHeader(species)
            SpeciesDetailView(species: species, store: store,
                              presenceStore: presenceStore,
                              isEmbedded: true, contentWidth: width,
                              link: SectionScrollLink(
                                scrollTo: linked ? scrollTarget[side] : nil,
                                onUserScroll: { leader = side },
                                onTopSection: { section in follow(from: side, to: section) }))
        }
        .frame(width: width, height: height)
        // Belt and braces after the overflow above: whatever a page decides it
        // wants to be, it is not allowed to paint outside its half.
        .clipped()
    }

    /// One pane reached a section — move the other one to match.
    private func follow(from side: Side, to section: GuideSection) {
        guard linked, leader == side else { return }
        let other: Side = side == .first ? .second : .first
        guard scrollTarget[other] != section else { return }
        scrollTarget[other] = section
    }

    private func paneHeader(_ species: GuideSpecies) -> some View {
        HStack(spacing: 6) {
            Text(species.commonName)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            Text(species.scientificName)
                .font(.caption2.italic())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        // The two panes are one comparison, not two pages — VoiceOver should
        // say which half it has landed in.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(species.commonName), \(species.scientificName)")
    }
}

/// How comparison is offered on the screens inside one navigation stack.
///
/// A species page cannot answer this for itself. What "compare" should do
/// depends entirely on where the page is sitting, and it sits in four different
/// stacks — the guide's, Bats Near You, the Detector's species feed, and the
/// profile sheet — which have different answers and no way to ask each other.
enum SpeciesCompareMode {
    /// Not offered at all, and no compare control drawn.
    case unavailable

    /// The host owns its stack's path and will SWAP the species page for the
    /// comparison rather than stacking one on the other.
    ///
    /// This is what makes Back land on the guide. A comparison started from a
    /// species page is a better view of that same page, not a place you went
    /// afterwards, so leaving the page behind to return to puts a screen in the
    /// way that nobody wants to visit — you have to go back twice to reach the
    /// list you were browsing.
    case replacesPage(@MainActor (GuideSpecies, GuideSpecies) -> Void)

    /// No path to swap, so the comparison is presented over the page instead.
    /// The fallback, and what every stack did before the guide grew a path.
    case presentsOverPage

    var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

private struct SpeciesCompareModeKey: EnvironmentKey {
    nonisolated static let defaultValue: SpeciesCompareMode = .presentsOverPage
}

extension EnvironmentValues {
    var speciesCompareMode: SpeciesCompareMode {
        get { self[SpeciesCompareModeKey.self] }
        set { self[SpeciesCompareModeKey.self] = newValue }
    }
}
