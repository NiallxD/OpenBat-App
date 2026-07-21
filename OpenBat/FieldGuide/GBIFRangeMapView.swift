//
//  GBIFRangeMapView.swift
//  OpenBat
//
//  Interactive GBIF occurrence range map for the species detail page. Renders
//  a species' occurrence points (see GBIFService.fetchOccurrencePoints),
//  binned on-device into H3 hexagons (github.com/uber/h3, via the SwiftyH3
//  package), as native SwiftUI `Map` content — one hexagon per H3 cell,
//  rather than a GBIF-hosted raster tile overlay. See GBIFService.swift's
//  file header for why raster tiles were dropped: three iterations of
//  tile-overlay fixes each ran into a different symptom of the same root
//  problem (GBIF's point tiles draw fixed-PIXEL-size markers that don't scale
//  with zoom).
//
//  H3 over a flat lat/lon grid: a fixed-degree grid distorts cell area badly
//  away from the equator (a 1°×1° cell near a pole covers a fraction of the
//  area it does at the equator) and has no notion of zoom — H3's hexagons
//  are near-uniform in area globally, and its resolution hierarchy lets the
//  displayed grid get coarser or finer as the user zooms, binned fresh
//  on-device from the same cached raw points each time (no re-fetch).
//

import SwiftUI
import MapKit
import SwiftyH3

/// Card shown on the species detail page — resolves the taxon key, fetches
/// its occurrence points, then shows the map, a loading spinner, or an
/// "unavailable" state.
struct GBIFDistributionCard: View {
    let species: GuideSpecies
    /// Committed/versioned snapshot of species range points — checked first,
    /// before any live GBIF network call. See SpeciesRangeStore's header for
    /// why this has no bundled tier (unlike SpeciesGuideStore): a cold install
    /// with no cache and no network yet just falls through to the live
    /// per-species fetch below, same as before this store existed.
    let rangeStore: SpeciesRangeStore
    /// Height of the map/placeholder area. Callers own this rather than the
    /// card hardcoding one, so the same card can sit at a fixed height in the
    /// normal stacked layout or be squared off next to the overview text on
    /// iPad landscape (see SpeciesDetailView).
    var mapHeight: CGFloat = 220

    private enum LoadState {
        case loading
        case loaded([GBIFService.GBIFOccurrencePoint])
        case noData
        case error
    }

    /// One H3 cell in the currently-displayed grid and how many occurrence
    /// points fell inside it — recomputed (cheaply, on-device) whenever
    /// `resolution` changes, not on every camera-drag frame.
    private struct H3BinnedCell: Identifiable {
        let cell: H3Cell
        let count: Int
        var id: UInt64 { cell.id }
    }

    @State private var state: LoadState = .loading
    @State private var camera: MapCameraPosition = .automatic
    @State private var resolution: H3Cell.Resolution = .res2
    @State private var binnedCells: [H3BinnedCell] = []
    /// Bumped by the "Try Again" button on the error state to force `.task(id:)`
    /// to re-run — a network error is never written into `resolvedCache` (see
    /// below), so without this the view would just sit on `.error` forever
    /// since `species.id` alone doesn't change on retry.
    @State private var retryToken = 0
    /// Whether the currently-shown points came from the committed
    /// SpeciesRangeStore snapshot rather than a live per-species GBIF fetch —
    /// only the snapshot has a meaningful dataVersion/date to show next to
    /// the attribution footer.
    @State private var usedSnapshot = false

    /// In-memory cache of the resolved state per species, keyed by scientific
    /// name — same reasoning as the identical pattern in GBIFDistributionCard's
    /// previous version: a List row scrolled off-screen and back on gets its
    /// `@State` reset and `.task(id:)` re-fired from scratch, and without this
    /// that would re-decode (though not re-fetch, thanks to the on-device
    /// cache in GBIFService) and flash the loading spinner every time.
    private static var resolvedCache: [String: (state: LoadState, usedSnapshot: Bool)] = [:]

    /// Density scaling shared by a cell's opacity: a cell with
    /// `densityReferenceCount` or more sampled records renders at full
    /// opacity; below that it scales down smoothly. Square-root keeps a
    /// handful of very densely-sampled cells (recording effort, not
    /// necessarily true abundance) from making every lightly-sampled cell
    /// look negligible by comparison.
    private static let densityReferenceCount = 20.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch state {
                case .loaded:
                    Map(position: $camera) {
                        ForEach(binnedCells) { bin in
                            bin.cell
                                .foregroundStyle(Color.purple.opacity(opacity(for: bin)))
                        }
                    }
                    .onMapCameraChange(frequency: .onEnd) { context in
                        resolution = Self.resolution(forSpanDegrees: context.region.span.latitudeDelta)
                    }
                    .frame(height: mapHeight)
                case .noData:
                    ContentUnavailableView("No distribution data",
                                           systemImage: "globe.desk",
                                           description: Text("GBIF has no recorded occurrences for this species."))
                        .frame(height: mapHeight)
                        .frame(maxWidth: .infinity)
                case .error:
                    ContentUnavailableView {
                        Label("Distribution unavailable", systemImage: "globe.desk")
                    } description: {
                        Text("Couldn't reach GBIF for this species.")
                    } actions: {
                        Button("Try Again") { retryToken += 1 }
                    }
                        .frame(height: mapHeight)
                        .frame(maxWidth: .infinity)
                case .loading:
                    loadingPlaceholder
                }
            }
            attributionFooter
        }
        .task(id: "\(species.id)#\(retryToken)") {
            if let cached = Self.resolvedCache[species.scientificName] {
                state = cached.state
                usedSnapshot = cached.usedSnapshot
                if case .loaded(let points) = cached.state {
                    if let region = GBIFService.region(for: points) {
                        camera = .region(region)
                        resolution = Self.resolution(forSpanDegrees: region.span.latitudeDelta)
                    }
                    binnedCells = Self.bin(points, at: resolution)
                }
                return
            }
            // Committed/versioned snapshot (SpeciesRangeStore) wins over a live
            // fetch when it has this species — instant, offline, no GBIF call.
            if let points = rangeStore.ranges[species.scientificName] {
                if let region = GBIFService.region(for: points) {
                    camera = .region(region)
                    resolution = Self.resolution(forSpanDegrees: region.span.latitudeDelta)
                }
                binnedCells = Self.bin(points, at: resolution)
                state = points.isEmpty ? .noData : .loaded(points)
                usedSnapshot = true
                Self.resolvedCache[species.scientificName] = (state, usedSnapshot)
                return
            }

            usedSnapshot = false
            state = .loading
            guard let key = await GBIFService.fetchTaxonKey(for: species.scientificName) else {
                state = .error
                return
            }
            switch await GBIFService.fetchOccurrencePoints(taxonKey: key) {
            case .success(let points):
                if let region = GBIFService.region(for: points) {
                    camera = .region(region)
                    resolution = Self.resolution(forSpanDegrees: region.span.latitudeDelta)
                }
                binnedCells = Self.bin(points, at: resolution)
                state = .loaded(points)
                Self.resolvedCache[species.scientificName] = (state, usedSnapshot)
            case .noData:
                state = .noData
                Self.resolvedCache[species.scientificName] = (state, usedSnapshot)
            case .networkError:
                // Deliberately not cached: a flaky-network failure shouldn't
                // permanently wedge this species' map for the rest of the app
                // session. Falling through re-fetches next visit / on retry.
                state = .error
            }
        }
        .onChange(of: resolution) { _, newResolution in
            guard case .loaded(let points) = state else { return }
            binnedCells = Self.bin(points, at: newResolution)
        }
    }

    private static let updatedAtFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    /// GBIF credit, plus the range snapshot's version/date when the map is
    /// showing the committed SpeciesRangeStore data rather than a live
    /// per-species fetch — a live fetch has no meaningful "version".
    private var attributionFooter: some View {
        HStack(spacing: 4) {
            Text("Distribution data via GBIF.org")
            if usedSnapshot {
                Text("· v\(rangeStore.dataVersion)")
                if let updated = rangeStore.updatedDate {
                    Text("· \(Self.updatedAtFormatter.string(from: updated))")
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// A faded, non-interactive world map behind the spinner — reads as "a map
    /// is coming" rather than a flat grey box while the taxon key resolves and
    /// the occurrence sample downloads.
    private var loadingPlaceholder: some View {
        ZStack {
            Map(initialPosition: .automatic)
                .disabled(true)
                .allowsHitTesting(false)
                .opacity(0.3)
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading distribution data…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(height: mapHeight)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    /// Bins raw occurrence points into H3 cells at `resolution`, counting
    /// records per cell. Cheap enough to re-run on every resolution change —
    /// occurrence samples here are at most a few thousand points, and
    /// `latLngToCell` is an O(1) C call per point.
    private static func bin(_ points: [GBIFService.GBIFOccurrencePoint],
                            at resolution: H3Cell.Resolution) -> [H3BinnedCell] {
        var counts: [H3Cell: Int] = [:]
        for point in points {
            let latLng = H3LatLng(latitudeDegs: point.lat, longitudeDegs: point.lon)
            guard let cell = try? latLng.cell(at: resolution) else { continue }
            counts[cell, default: 0] += 1
        }
        return counts.map { H3BinnedCell(cell: $0.key, count: $0.value) }
    }

    /// Maps the map's current latitude span (degrees) to an H3 resolution —
    /// coarser hexagons zoomed out (world/continent scale), finer ones zoomed
    /// in, so the grid always reads as a sensible density of cells rather
    /// than either a handful of huge hexagons or thousands of invisible ones.
    /// Thresholds are chosen against H3's average hexagon edge length per
    /// resolution (res1 ≈ 418 km, res2 ≈ 158 km, res3 ≈ 60 km, res4 ≈ 23 km,
    /// res5 ≈ 8.5 km).
    private static func resolution(forSpanDegrees latitudeDelta: Double) -> H3Cell.Resolution {
        switch latitudeDelta {
        case ..<3:   return .res5
        case ..<10:  return .res4
        case ..<30:  return .res3
        case ..<80:  return .res2
        default:     return .res1
        }
    }

    private func density(for bin: H3BinnedCell) -> Double {
        min(1.0, sqrt(Double(bin.count) / Self.densityReferenceCount))
    }

    private func opacity(for bin: H3BinnedCell) -> Double {
        0.35 + 0.45 * density(for: bin)
    }
}
