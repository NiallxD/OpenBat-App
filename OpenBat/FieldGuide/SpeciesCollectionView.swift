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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !species.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { layoutToggle }
            }
        }
    }

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
                        NavigationLink(value: SpeciesGuideDestination.species(species)) {
                            GuideSpeciesRow(species: species)
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
                            NavigationLink(value: SpeciesGuideDestination.species(species)) {
                                GuideSpeciesCard(species: species)
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
                if let imageURL {
                    AsyncImage(url: imageURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            placeholder
                        }
                    }
                } else {
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
