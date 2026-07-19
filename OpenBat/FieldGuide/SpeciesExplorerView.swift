//
//  SpeciesExplorerView.swift
//  OpenBat
//
//  The Species section — a field-guide explorer. A prominent fuzzy-search bar
//  sits at the top (common + scientific names); below it, an interactive globe
//  (MapKit satellite imagery with realistic elevation renders as a true 3D
//  globe when zoomed out) shows one pin per species region. Tapping a pin
//  pushes the region's species list; each species pushes a (placeholder)
//  detail page.
//

import SwiftUI
import MapKit

/// Both region pins and species rows push through this single enum so the
/// explorer only ever registers one `.navigationDestination(for:)` — mixing
/// that with a separate `.navigationDestination(item:)` for regions caused
/// NavigationStack to desync (pushed view showed the previous destination's
/// content until a back-then-forward "caught it up").
enum SpeciesGuideDestination: Hashable {
    case region(GuideRegion)
    case species(GuideSpecies)
}

struct SpeciesExplorerView: View {
    let store: SpeciesGuideStore
    let rangeStore: SpeciesRangeStore
    /// Where to pre-pan the globe — the user's current location, if known.
    /// Falls back to a fixed mid-Atlantic center when nil (no fix yet / denied).
    let userCoordinate: CLLocationCoordinate2D?

    @State private var query = ""
    @State private var showSources = false
    @FocusState private var searchFieldFocused: Bool
    /// Start far enough out that the realistic-elevation imagery style renders
    /// the whole planet as a spinnable globe — just pre-panned toward the user
    /// rather than a fixed point, so the globe opens already facing home.
    @State private var camera: MapCameraPosition
    /// Guards the one-time pin-layout nudge in `globe`'s `.onAppear` — without
    /// this it re-fires every time the globe reappears (e.g. popping back
    /// from a region/species page), snapping the camera back to
    /// `userCoordinate` instead of staying wherever the user last panned it to.
    @State private var hasNudgedCameraOnce = false

    private static let fallbackCenter = CLLocationCoordinate2D(latitude: 30, longitude: -10)

    init(store: SpeciesGuideStore, rangeStore: SpeciesRangeStore, userCoordinate: CLLocationCoordinate2D? = nil) {
        self.store = store
        self.rangeStore = rangeStore
        self.userCoordinate = userCoordinate
        _camera = State(initialValue: .camera(
            MapCamera(centerCoordinate: userCoordinate ?? Self.fallbackCenter, distance: 40_000_000)
        ))
    }

    private var results: [GuideSpecies] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return store.guide.species
            .compactMap { s in s.searchScore(for: trimmed).map { (s, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal)
                .padding(.vertical, 10)
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                globe
                    // Tapping anywhere on the globe dismisses the keyboard. Scoped to
                    // just this branch — applying the same gesture to an ancestor of
                    // `searchResults`' List (as this used to) silently ate
                    // NavigationLink taps on list rows; `simultaneousGesture` doesn't
                    // actually avoid that conflict for List-backed content the way
                    // its name implies.
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { searchFieldFocused = false })
            } else {
                searchResults
                    // The List-native way to dismiss the keyboard on interaction —
                    // doesn't compete with row taps the way a custom tap gesture does.
                    .scrollDismissesKeyboard(.immediately)
            }
        }
        .navigationDestination(for: SpeciesGuideDestination.self) { destination in
            switch destination {
            case .region(let region):
                RegionSpeciesView(region: region, store: store)
            case .species(let species):
                SpeciesDetailView(species: species, store: store, rangeStore: rangeStore)
            }
        }
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search species or scientific name", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searchFieldFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
    }

    @ViewBuilder private var searchResults: some View {
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(results) { species in
                NavigationLink(value: SpeciesGuideDestination.species(species)) {
                    GuideSpeciesRow(species: species)
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: Globe

    private var globe: some View {
        Map(position: $camera) {
            ForEach(store.guide.regions) { region in
                Annotation(region.name, coordinate: region.coordinate) {
                    NavigationLink(value: SpeciesGuideDestination.region(region)) {
                        RegionPin(count: store.guide.species(in: region).count)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(.imagery(elevation: .realistic))
        .overlay(alignment: .bottom) { globeFooter }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            guard !hasNudgedCameraOnce else { return }
            hasNudgedCameraOnce = true
            // MapKit's realistic-elevation globe doesn't lay out `Annotation`
            // pins on first render — they stay invisible until the camera
            // moves at least once. A negligible programmatic nudge right
            // after appearing forces that first layout pass so pins show up
            // without the user needing to pan the globe themselves. Guarded to
            // fire only once (not on every return from a pushed region/species
            // page) so the camera otherwise just keeps whatever position the
            // user last panned/tapped it to.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                camera = .camera(MapCamera(centerCoordinate: userCoordinate ?? Self.fallbackCenter,
                                            distance: 39_999_999))
            }
        }
    }

    private static let updatedAtFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private var globeFooter: some View {
        VStack(spacing: 4) {
            Text("Tap a region to explore its species")
                .font(.footnote)
            HStack(spacing: 4) {
                Text("Guide v\(store.guide.dataVersion) · \(store.source.rawValue)")
                if let updated = store.guide.updatedDate {
                    Text("· updated \(Self.updatedAtFormatter.string(from: updated))")
                }
                if store.isRefreshing {
                    ProgressView().controlSize(.mini)
                }
                Text("·")
                // Credits the field guide's data (GBIF/Wikipedia) and the
                // classifier models — including BatDetect2's CC BY-NC
                // non-commercial licence — from within the guide itself, so it's
                // reachable without going to the app-info sheet.
                Button("Sources") { showSources = true }
                    .buttonStyle(.plain)
                    .underline()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 24)
        .sheet(isPresented: $showSources) {
            NavigationStack {
                ScrollView {
                    DataModelSourcesView()
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("Sources & Licences")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showSources = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// Bat pin used for regions on the globe — species count badged alongside.
private struct RegionPin: View {
    let count: Int

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(.orange.gradient)
                    .frame(width: 36, height: 36)
                    .shadow(radius: 3)
                Image("batIcon")
                    .resizable().scaledToFit()
                    .foregroundStyle(.white)
                    .padding(7)
                    .frame(width: 36, height: 36)
                Text("\(count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.blue, in: Circle())
                    .offset(x: 6, y: -6)
            }
        }
    }
}

/// IUCN Red List category → (short badge text, color). Free text in the data
/// (`SpeciesConservation.iucnStatus`), matched case-insensitively; anything
/// unrecognized (or absent) falls back to a neutral gray "?" rather than
/// hiding the badge, since a wrong-but-visible status is easier to notice and
/// fix in the guide JSON than a silently-missing one.
private enum IUCNBadge {
    static func forStatus(_ status: String?) -> (text: String, color: Color) {
        guard let status else { return ("?", .gray) }
        switch status.lowercased() {
        case "least concern":         return ("LC", .green)
        case "near threatened":       return ("NT", .yellow)
        case "vulnerable":            return ("VU", .orange)
        case "endangered":            return ("EN", .red)
        case "critically endangered": return ("CR", .purple)
        case "extinct in the wild":   return ("EW", .black)
        case "extinct":               return ("EX", .black)
        case "data deficient":        return ("DD", .gray)
        default:                      return ("?", .gray)
        }
    }
}

/// Species row thumbnail — tries a real photo from Wikipedia's open media
/// first (same fetch pattern the Birding_Data companion app uses for its
/// species detail pages, see WikipediaSpeciesImageService), falling back to a
/// themed silhouette icon (tinted per-family) while loading, on a species
/// with no usable Wikipedia photo, or if the request fails.
private struct GuideSpeciesThumbnail: View {
    let species: GuideSpecies
    static let size: CGFloat = 50

    @State private var imageURL: URL?

    private var tint: Color {
        // Deterministic (not random) so the same family always gets the same
        // color across launches and across rows.
        let hash = abs((species.family ?? species.order ?? "Chiroptera").hashValue)
        let palette: [Color] = [.orange, .teal, .indigo, .pink, .brown, .mint]
        return palette[hash % palette.count]
    }

    var body: some View {
        Group {
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
        .frame(width: Self.size, height: Self.size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: species.scientificName) {
            imageURL = await WikipediaSpeciesImageService.fetchImageURL(for: species.scientificName)
        }
    }

    private var placeholder: some View {
        Image("batIcon")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .padding(10)
            .frame(width: Self.size, height: Self.size)
            .background(tint.gradient)
    }
}

/// Shared species row (search results + region lists) — mirrors the
/// thumbnail + headline/subtitle/caption + trailing-badge layout used by the
/// life-list/checklist rows in the Birding_Data companion app, adapted to
/// what the field guide actually has on hand (no per-species photos, but
/// echolocation stats and an IUCN conservation status).
struct GuideSpeciesRow: View {
    let species: GuideSpecies

    private var peakFreqCaption: String? {
        guard let range = species.echolocation?.peakFreqHzRange else { return nil }
        let lo = range.min / 1000, hi = range.max / 1000
        return "Peak freq: \(String(format: "%.0f", lo))–\(String(format: "%.0f", hi)) kHz"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            GuideSpeciesThumbnail(species: species)

            VStack(alignment: .leading, spacing: 4) {
                Text(species.commonName)
                    .font(.headline)
                Text(species.scientificName)
                    .font(.subheadline.italic())
                    .foregroundStyle(.secondary)
                if let peakFreqCaption {
                    Text(peakFreqCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let iucn = species.conservation?.iucnStatus {
                let badge = IUCNBadge.forStatus(iucn)
                Text(badge.text)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(badge.color.gradient, in: Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Region page

struct RegionSpeciesView: View {
    let region: GuideRegion
    let store: SpeciesGuideStore

    private static let unclassified = "Other"
    /// Repo the community-editable guide JSON (SpeciesGuideData.json) lives
    /// in — same repo `SpeciesGuideStore.remoteURL` fetches from.
    private static let repoURL = "https://github.com/NiallxD/OpenBat"

    /// Species in this region grouped by family — a lightweight stand-in for
    /// the full taxonomy browser planned later (see CLAUDE.md future work);
    /// this just gives the region list some taxonomic structure today.
    /// Families sort alphabetically; species lacking a `family` land in an
    /// "Other" group pinned last.
    private var families: [(name: String, species: [GuideSpecies])] {
        let present = store.guide.species(in: region)
        let grouped = Dictionary(grouping: present) { $0.family ?? Self.unclassified }
        return grouped.keys.sorted { lhs, rhs in
            if lhs == Self.unclassified { return false }
            if rhs == Self.unclassified { return true }
            return lhs < rhs
        }.map { (name: $0, species: grouped[$0]!) }
    }

    var body: some View {
        let present = store.guide.species(in: region)
        VStack(spacing: 0) {
            if !present.isEmpty {
                Text("Species in region: \(present.count)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
            List {
                if present.isEmpty {
                    ContentUnavailableView("No species yet",
                                           systemImage: "book.closed",
                                           description: Text("This region has no entries in the guide yet! As a community-sourced guide, contributions are always welcome — [get started here](\(Self.repoURL))."))
                } else {
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
        }
        .navigationTitle(region.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// Species detail page lives in SpeciesDetailView.swift.
