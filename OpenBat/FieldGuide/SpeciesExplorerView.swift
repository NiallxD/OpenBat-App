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

    @State private var query = ""
    @FocusState private var searchFieldFocused: Bool
    /// Start far enough out that the realistic-elevation imagery style renders
    /// the whole planet as a spinnable globe.
    @State private var camera: MapCameraPosition = .camera(
        MapCamera(centerCoordinate: .init(latitude: 30, longitude: -10),
                  distance: 40_000_000)
    )

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
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    globe
                } else {
                    searchResults
                }
            }
            // Tapping anywhere below the search bar dismisses the keyboard.
            // `simultaneousGesture` (rather than `onTapGesture`) so it doesn't
            // swallow taps meant for list rows or the globe's region pins.
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { searchFieldFocused = false })
        }
        .navigationDestination(for: SpeciesGuideDestination.self) { destination in
            switch destination {
            case .region(let region):
                RegionSpeciesView(region: region, store: store)
            case .species(let species):
                SpeciesDetailView(species: species, store: store)
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
            // MapKit's realistic-elevation globe doesn't lay out `Annotation`
            // pins on first render — they stay invisible until the camera
            // moves at least once. A negligible programmatic nudge right
            // after appearing forces that first layout pass so pins show up
            // without the user needing to pan the globe themselves.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                camera = .camera(MapCamera(centerCoordinate: .init(latitude: 30, longitude: -10),
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
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 24)
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

/// Shared species row (search results + region lists).
struct GuideSpeciesRow: View {
    let species: GuideSpecies

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(species.commonName)
                .font(.body.weight(.medium))
            Text(species.scientificName)
                .font(.subheadline.italic())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Region page

struct RegionSpeciesView: View {
    let region: GuideRegion
    let store: SpeciesGuideStore

    private static let unclassified = "Other"

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
        List {
            let present = store.guide.species(in: region)
            if present.isEmpty {
                ContentUnavailableView("No species yet",
                                       systemImage: "book.closed",
                                       description: Text("This region has no entries in the guide yet — contributions welcome!"))
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
        .navigationTitle(region.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// Species detail page lives in SpeciesDetailView.swift.
