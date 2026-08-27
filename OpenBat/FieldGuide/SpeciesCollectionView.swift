//
//  SpeciesCollectionView.swift
//  OpenBat
//
//  "Here is a set of species, browse it" — the one page behind every such view
//  in the guide: a region's species, the bats near you (both from the globe and
//  from the Detector's own sheet). They differ only in how the set was chosen
//  and what to say about an empty one, so this takes a resolved `species` array
//  rather than a `GuideRegion`; the near-you set isn't a region at all, just a
//  coordinate matched against the presence grid.
//
//  Two layouts, user's choice, remembered across launches — see `SpeciesLayout`.
//  Both group by family, so the toggle changes only how a species is drawn and
//  never which ones are shown or in what order.
//

import SwiftUI

/// How a species collection is drawn. Persisted, so the choice survives
/// relaunches and applies to every species collection at once — a per-page
/// memory would mean the same toggle in the same corner meaning different
/// things on two pages that look identical.
///
/// `String`-backed rather than `Int`: this lands in UserDefaults where it is
/// readable by hand (and by `simctl launch -guide.speciesLayout list`), and a
/// raw value that says "list" survives someone reordering the cases.
enum SpeciesLayout: String, CaseIterable {
    case cards
    case list

    /// The layout tapping the toggle moves to.
    var toggled: SpeciesLayout { self == .cards ? .list : .cards }

    /// Named for the layout itself, not for the action — the button decides
    /// whether it is showing the current mode or the destination one.
    var symbolName: String {
        switch self {
        case .cards: "square.grid.2x2"
        case .list:  "list.bullet"
        }
    }

    var actionLabel: String {
        switch self {
        case .cards: "Show as cards"
        case .list:  "Show as list"
        }
    }
}

struct SpeciesCollectionView: View {
    let title: String
    let species: [GuideSpecies]
    /// "in region" / "near you" — filled into "Species \(countSuffix): N"
    /// above the collection.
    let countSuffix: String
    /// Shown only when `species` is empty; differs between callers (a region
    /// with no guide entries yet vs no presence data covering this exact
    /// spot), so it's supplied rather than owned here.
    let emptyStateDescription: Text

    @AppStorage("guide.speciesLayout") private var layout: SpeciesLayout = .cards

    /// Only for orienting the compare glyph — see `compareToggle`.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Compare mode: armed from the toolbar, then two taps pick the pair.
    /// Deliberately not a long-press on a species — that gesture is invisible,
    /// has no VoiceOver equivalent, and a mode you can see you are in beats one
    /// you can only discover (Niall, 2026-08-26).
    @State private var isComparing = false
    /// The first of the pair, once picked. Tapping it again puts it back.
    @State private var firstPick: GuideSpecies?

    private static let unclassified = "Other"

    private static let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    /// Species grouped by family — a lightweight stand-in for the full
    /// taxonomy browser planned later (see Context.md §16); this just gives
    /// the collection some taxonomic structure today. Families sort
    /// alphabetically; species lacking a `family` land in an "Other" group
    /// pinned last.
    private var families: [(name: String, species: [GuideSpecies])] {
        let grouped = Dictionary(grouping: species) { $0.family ?? Self.unclassified }
        return grouped.keys.sorted { lhs, rhs in
            if lhs == Self.unclassified { return false }
            if rhs == Self.unclassified { return true }
            return lhs < rhs
        }.map { (name: $0, species: grouped[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !species.isEmpty {
                Text("Species \(countSuffix): \(species.count)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }

            if species.isEmpty {
                // Outside the layout branch: an empty collection has nothing to
                // lay out either way, and showing the toggle over an empty page
                // would offer a choice that changes nothing on screen.
                List {
                    ContentUnavailableView("No species yet",
                                           systemImage: "book.closed",
                                           description: emptyStateDescription)
                }
            } else {
                switch layout {
                case .list:  listLayout
                case .cards: cardLayout
                }
            }
        }
        // Floats over the collection rather than pushing it down. A banner in
        // the flow shoved every card down the screen the moment compare mode
        // was armed, which is a lot of movement to say one sentence — and the
        // sentence stops being news after the first pick. Same treatment as the
        // globe's "Tap here to see bats near you" (Niall, 2026-08-26).
        .overlay(alignment: .bottom) {
            if isComparing { comparePill }
        }
        .animation(.snappy(duration: 0.25), value: isComparing)
        .animation(.snappy(duration: 0.25), value: firstPick)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Two species are the minimum for a comparison to mean anything, so
            // the button isn't offered on a page that can't satisfy it.
            if species.count > 1 {
                ToolbarItem(placement: .topBarTrailing) { compareToggle }
            }
            if !species.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { layoutToggle }
            }
        }
        // Covers both directions: pushing the comparison, and coming back from
        // it. Either way the mode is spent — leaving it armed would mean a tap
        // on a species after returning silently starting a second comparison
        // instead of opening the page.
        .onDisappear(perform: exitCompare)
    }

    // MARK: Compare

    private var compareToggle: some View {
        Button {
            if isComparing { exitCompare() } else { isComparing = true }
        } label: {
            Image(systemName: "chevron.up.chevron.down.square")
                .symbolVariant(isComparing ? .fill : .none)
                // Turned on its side where the comparison itself is: the glyph
                // shows the two halves you are about to get, so it should be
                // split the way they will be — stacked on a phone, beside each
                // other on an iPad.
                .rotationEffect(.degrees(horizontalSizeClass == .regular ? 90 : 0))
        }
        .tint(isComparing ? Color.batAccent : nil)
        .accessibilityLabel(isComparing ? "Cancel comparing" : "Compare two species")
    }

    /// Says which of the two taps you are on, and carries the way out. Without
    /// it, an armed mode with nothing picked yet looks exactly like an ordinary
    /// page whose taps have stopped opening anything.
    ///
    /// A glass capsule floating at the bottom, matching the globe's footer pill
    /// — it sits against the safe area, so it clears the tab bar rather than
    /// hiding under it.
    private var comparePill: some View {
        HStack(spacing: 12) {
            Text(firstPick.map { "\($0.commonName) — now tap another" }
                 ?? "Tap two species to compare")
                .font(.footnote)
                .lineLimit(1)
            Button("Cancel") { exitCompare() }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.batAccent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .liquidGlass(in: Capsule())
        .padding(.bottom, 12)
        // Rises into place rather than fading in on the spot, so it reads as
        // arriving from the bottom edge like the rest of the app's pills.
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func exitCompare() {
        isComparing = false
        firstPick = nil
    }

    /// Wraps a card or a row in whatever tapping it should do right now.
    ///
    /// **One structure, always — an enabled `NavigationLink` with a tap catcher
    /// laid over it when the tap should pick rather than push.** The obvious
    /// spelling is an `if`/`else` choosing between a link and a button, and it
    /// was: each branch of an `if` is a DIFFERENT view as far as SwiftUI's
    /// structural identity goes, so arming compare mode — and then picking the
    /// first species — tore every card down and built it again. Each card holds
    /// its resolved photo URL in `@State`, so every one of them dropped back to
    /// its placeholder and re-resolved, and the whole page visibly flashed
    /// twice on the way into a comparison (Niall, 2026-08-26).
    ///
    /// The catcher is an overlay rather than `.disabled` on the link: disabling
    /// a control dims its label in some button styles, and the point here is
    /// that nothing about the card should change except what a tap does.
    ///
    /// The second pick is a `NavigationLink` to the comparison rather than a
    /// button that pushes a path — the value carries both species, so the
    /// existing `SpeciesGuideDestination` routing does the push and this view
    /// needs no binding to the stack it happens to be inside. That matters
    /// because it is inside two different stacks (the guide's, and
    /// `NearbySpeciesSheet`'s).
    @ViewBuilder
    private func speciesTile<Content: View>(_ species: GuideSpecies,
                                            @ViewBuilder content: () -> Content) -> some View {
        NavigationLink(value: destination(for: species)) { content() }
            .overlay {
                if picksOnTap(species) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Tapping the pick again puts it back rather than
                            // trapping you into comparing it with something.
                            firstPick = (firstPick == species) ? nil : species
                        }
                }
            }
    }

    /// True while a tap should choose this species instead of opening it:
    /// compare mode is armed and this card is either the one already picked or
    /// one of the candidates waiting for a first pick.
    private func picksOnTap(_ species: GuideSpecies) -> Bool {
        isComparing && (firstPick == nil || firstPick == species)
    }

    /// Where the link under the card goes. Unused whenever `picksOnTap` is
    /// true — the catcher takes the tap first — but it still has to be a real
    /// destination, because the link itself is always there.
    private func destination(for species: GuideSpecies) -> SpeciesGuideDestination {
        if let firstPick, isComparing, firstPick != species {
            return .compare(firstPick, species)
        }
        return .species(species)
    }

    private func isPicked(_ species: GuideSpecies) -> Bool { firstPick == species }

    /// Shows the icon for the layout you will GET, not the one you are looking
    /// at — the page itself already tells you which layout is showing, so
    /// repeating that in the button wastes the only affordance there is. The
    /// accessibility label says the same thing in words.
    private var layoutToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { layout = layout.toggled }
        } label: {
            Image(systemName: layout.toggled.symbolName)
        }
        .accessibilityLabel(layout.toggled.actionLabel)
    }

    private var listLayout: some View {
        List {
            ForEach(families, id: \.name) { family in
                Section(family.name) {
                    ForEach(family.species) { species in
                        speciesTile(species) {
                            GuideSpeciesRow(species: species)
                                .comparePick(isPicked(species), cornerRadius: 10)
                        }
                    }
                }
            }
        }
    }

    private var cardLayout: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 14) {
                ForEach(families, id: \.name) { family in
                    Section {
                        ForEach(family.species) { species in
                            speciesTile(species) {
                                GuideSpeciesCard(species: species)
                                    // 18 to match the card's own corner radius —
                                    // a rounder or squarer outline reads as a
                                    // second object sitting on top of the card
                                    // rather than the card being selected.
                                    .comparePick(isPicked(species), cornerRadius: 18)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(family.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
            }
            .padding(14)
        }
    }
}

/// One card tile — the species' photo fills the whole glass card, with the
/// common and scientific name legible over a bottom scrim. Same
/// contributor-URL-then-Wikipedia resolution `GuideSpeciesThumbnail`
/// (SpeciesExplorerView.swift) uses for the list layout's row thumbnails, just
/// sized to fill a card instead of a small row icon.
struct GuideSpeciesCard: View {
    let species: GuideSpecies

    @State private var imageURL: URL?

    private var tint: Color {
        // Deterministic (not random) so the same family always gets the same
        // color across launches and across cards — matches
        // `GuideSpeciesThumbnail`'s placeholder.
        let hash = abs((species.family ?? species.order ?? "Chiroptera").hashValue)
        let palette: [Color] = [.orange, .teal, .indigo, .pink, .brown, .mint]
        return palette[hash % palette.count]
    }

    var body: some View {
        // `Color.clear` sizes the card from the grid column via the aspect
        // ratio; the photo and nameplate are hung off it as overlays rather
        // than sized by the image itself. Same reasoning as
        // `SpeciesDetailView.cardHeroPhoto`: an image-driven size blows the
        // layout out on a wide photo, and overlays can't expand their parent.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                CachedSpeciesImage(url: imageURL, size: .thumbnail) {
                    placeholder
                }
            }
            .clipped()
            .overlay(alignment: .bottom) { nameplate }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .task(id: species.scientificName) {
                // Contributor-set URL first — see `GuideSpecies.imageURL`'s
                // doc comment for why that's preferred over the live
                // Wikipedia lookup, which stays only as a fallback.
                if let urlString = species.imageURL, let url = URL(string: urlString) {
                    imageURL = url
                } else {
                    imageURL = await WikipediaSpeciesImageService.fetchImageURL(for: species.scientificName)
                }
            }
    }

    private var nameplate: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(species.commonName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(species.scientificName)
                .font(.caption2.italic())
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.75)],
                            startPoint: .top, endPoint: .bottom)
        )
    }

    private var placeholder: some View {
        Image("batIcon")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tint.gradient)
    }
}


/// The orange outline on the first of a compared pair. An outline rather than a
/// checkmark or a dimming of everything else: it marks the one thing that
/// changed without redrawing the page around it, and the accent is the same
/// orange the session button glows, which is this app's colour for "this is the
/// live one".
private struct ComparePickOutline: ViewModifier {
    let isPicked: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.batAccent, lineWidth: 3)
                    .opacity(isPicked ? 1 : 0)
            }
            .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}

extension View {
    func comparePick(_ isPicked: Bool, cornerRadius: CGFloat) -> some View {
        modifier(ComparePickOutline(isPicked: isPicked, cornerRadius: cornerRadius))
    }
}
