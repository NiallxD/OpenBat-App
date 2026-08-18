//
//  GBIFRangeMapView.swift
//  OpenBat
//
//  Range map for the species detail page. Draws the species' presence grid —
//  the same bundled `SpeciesPresenceData.json` the classifier uses to decide
//  which species are plausible near the user — as filled cells on a fixed,
//  non-interactive `Map`.
//
//  WHAT THIS REPLACED, AND WHY (2026-08-16)
//  ----------------------------------------
//  Previously: fetch up to 3000 raw occurrence points per species (from a
//  committed snapshot when it had them, otherwise a live GBIF call), bin them
//  into H3 hexagons on-device, and re-bin at a finer resolution every time the
//  user zoomed. Three things were wrong with it.
//
//  1. It needed the network. The point snapshot deliberately had no bundled
//     tier, so a cold install fell through to a live per-species fetch and a
//     spinner — and offline, to "Distribution unavailable".
//  2. It only covered species the guide has pages for. The presence data covers
//     every species the classifiers can name, which is a much larger set.
//  3. Zooming was fiddly and, per Niall, not informative — and the re-binning
//     machinery existed only to serve it.
//
//  It also quietly showed the wrong thing. Occurrence points are where people
//  went looking and filed a record; a well-surveyed county outshines a
//  well-populated one. The presence grid is closer to where the bat lives: it
//  aggregates every record GBIF holds rather than a sample, and drops isolated
//  one-off records that are usually misidentifications or specimens catalogued
//  at the museum holding them. (It is still built from occurrence data, so the
//  caveat in the info popover stays — it is honest, not modelled range.)
//
//  Cells are merged into horizontal runs before drawing: a widespread species
//  covers ~1100 one-degree cells, and MapKit does not need 1100 polygons to
//  draw what is mostly a handful of solid blocks.
//

import SwiftUI
import MapKit

/// Card shown on the species detail page — a fixed view of where this species
/// lives, or an explanation when there is no range data for it.
struct GBIFDistributionCard: View {
    let species: GuideSpecies
    /// Bundled presence grid. Ships in the app, so this card has no loading
    /// state and no network path — see SpeciesPresenceStore's header.
    let presenceStore: SpeciesPresenceStore
    /// Height of the "no data" placeholder only — the map itself is square (see
    /// `Self.aspect`) and takes its height from its width. Callers own this
    /// rather than the card hardcoding one so the placeholder doesn't tower over
    /// a short caller's layout.
    var mapHeight: CGFloat = 220

    @State private var showInfoPopover = false
    /// Re-framed from the map's REAL size rather than set once up front.
    /// `initialPosition` is evaluated before the final layout width is known, and
    /// is never re-applied when it changes — so the camera ends up framed for a
    /// width the view never had, and the range clips.
    @State private var camera: MapCameraPosition = .automatic
    /// Last size the camera was framed for, purely so the re-frame runs once per
    /// real size change instead of on every geometry callback. It no longer
    /// feeds a height calculation — the map is square now and takes its height
    /// from its width, so there is no size → height → size loop to converge.
    @State private var mapSize: CGSize = .zero

    /// The map is square, and that is what makes cropping impossible rather
    /// than merely unlikely.
    ///
    /// Fitting a rect into a view means matching their aspect ratios, so a range
    /// that is tall relative to the view forces the map to show more longitude
    /// than the world has — MapKit clamps the zoom there and crops the latitude
    /// instead. Padding cannot fix that; only a taller frame can.
    ///
    /// **In Mercator map points the world is square**, so any range's height is
    /// at most `MKMapRect.world.height`, which equals `MKMapRect.world.width`.
    /// At aspect 1 the longitude a range needs is exactly its height — therefore
    /// never more than one world-width, for any range that can exist. A square
    /// map fits everything.
    ///
    /// This replaced a grow-the-height-as-needed calculation capped at 340pt
    /// (2026-08-17). The cap was the bug: measured against the real data, hoary
    /// bat needs 1.30 world-widths in a wide card, eastern red 1.26, Mexican
    /// free-tailed 1.12 — and any cap short of square leaves the tallest ranges
    /// clipped no matter how it is tuned.
    private static let aspect: CGFloat = 1

    /// One drawn block: a run of horizontally adjacent cells in a single row.
    private struct RangeBlock: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let range = resolvedRange {
                    Map(position: $camera, interactionModes: []) {
                        ForEach(range.blocks) { block in
                            // No stroke: blocks are only merged into runs
                            // horizontally (see `blocks(for:cellDegrees:)`), so
                            // a bordered row reads as a stripe at every row
                            // boundary even where the range is one solid mass
                            // top to bottom. Fill-only reads as a single shape.
                            MapPolygon(coordinates: block.coordinates)
                                .foregroundStyle(Color.purple.opacity(0.55))
                        }
                    }
                    // **Square, and that is a correctness fix rather than a
                    // taste one** — see `Self.aspect`.
                    .aspectRatio(Self.aspect, contentMode: .fit)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        // Re-frames on a real size change (first layout,
                        // rotation) — see `camera`, which cannot be set correctly
                        // up front because the layout width isn't known then.
                        guard size.width > 0, size != mapSize else { return }
                        mapSize = size
                        camera = .rect(range.rect)
                    }
                    .onChange(of: species.id) {
                        if let rect = resolvedRange?.rect { camera = .rect(rect) }
                    }
                } else {
                    ContentUnavailableView("No distribution data",
                                           systemImage: "globe.desk",
                                           description: Text(unavailableReason))
                        .frame(height: mapHeight)
                        .frame(maxWidth: .infinity)
                }
            }
            .overlay(alignment: .topTrailing) { infoButton }
            attributionFooter
        }
    }

    /// Why there is no map, said precisely — "we have no data for this bat" and
    /// "no code to look data up under" are different facts, and the second is
    /// a gap in coverage rather than a gap in knowledge.
    private var unavailableReason: String {
        guard presenceStore.isLoaded else {
            return "Range data hasn't loaded yet."
        }
        guard species.presenceCode != nil else {
            return "This species has no presence-grid code assigned in the field guide yet, so there's no range data for it."
        }
        return "There aren't enough records of this species to map where it lives."
    }

    private var resolvedRange: (rect: MKMapRect, blocks: [RangeBlock])? {
        guard let code = species.presenceCode,
              let cells = presenceStore.presence[code], !cells.isEmpty else { return nil }
        let degrees = presenceStore.cellDegrees
        let blocks = Self.blocks(for: Set(cells.keys), cellDegrees: degrees)
        guard let rect = Self.mapRect(for: Set(cells.keys), cellDegrees: degrees) else { return nil }
        return (rect, blocks)
    }

    // MARK: - Grid geometry

    /// Cell index back to its south-west corner, matching
    /// `SpeciesPresenceStore.cellIndex` and the generator's `cell_index`.
    private static func corner(of index: Int, cellDegrees: Double) -> (lat: Double, lon: Double) {
        let cols = Int((360 / cellDegrees).rounded())
        let (row, col) = index.quotientAndRemainder(dividingBy: cols)
        return (Double(row) * cellDegrees - 90, Double(col) * cellDegrees - 180)
    }

    /// Merges cells into horizontal runs, one polygon per run.
    ///
    /// Purely a drawing optimisation — the shape is identical, there are just
    /// far fewer polygons. Runs are not merged vertically as well: the extra
    /// bookkeeping buys little once the horizontal pass has collapsed the big
    /// solid regions, and rectangles are what MapPolygon wants anyway.
    private static func blocks(for indices: Set<Int>, cellDegrees: Double) -> [RangeBlock] {
        let cols = Int((360 / cellDegrees).rounded())
        var byRow: [Int: [Int]] = [:]
        for index in indices {
            let (row, col) = index.quotientAndRemainder(dividingBy: cols)
            byRow[row, default: []].append(col)
        }

        var blocks: [RangeBlock] = []
        for (row, columns) in byRow {
            var run: [Int] = []
            for col in columns.sorted() {
                if let last = run.last, col != last + 1 {
                    blocks.append(block(row: row, from: run[0], to: last, cellDegrees: cellDegrees))
                    run = []
                }
                run.append(col)
            }
            if let first = run.first, let last = run.last {
                blocks.append(block(row: row, from: first, to: last, cellDegrees: cellDegrees))
            }
        }
        return blocks
    }

    /// Each block is expanded by this fraction of a cell on every side, so
    /// adjacent blocks overlap slightly instead of exactly sharing an edge.
    ///
    /// MapKit anti-aliases every polygon's edge on its own: two translucent
    /// fills that exactly abut each leave their shared edge pixel only
    /// partly covered, and a partly-covered pixel of a translucent fill is
    /// lighter than a fully-covered one — which is what still read as a
    /// border between rows even after the explicit stroke was removed. A
    /// small overlap covers that seam with full fill from both sides instead
    /// of a partial one from each, and is small enough not to visibly round
    /// off the range's true outer edge (which the 8% padding in `mapRect`
    /// already keeps clear of anyway).
    private static let blockOverlapFraction = 0.06

    private static func block(row: Int, from startCol: Int, to endCol: Int,
                              cellDegrees: Double) -> RangeBlock {
        let overlap = cellDegrees * blockOverlapFraction
        let south = Double(row) * cellDegrees - 90 - overlap
        let north = south + cellDegrees + 2 * overlap
        let west = Double(startCol) * cellDegrees - 180 - overlap
        let east = Double(endCol + 1) * cellDegrees - 180 + overlap
        let cols = Int((360 / cellDegrees).rounded())
        return RangeBlock(
            id: row * cols + startCol,
            coordinates: [
                CLLocationCoordinate2D(latitude: south, longitude: west),
                CLLocationCoordinate2D(latitude: north, longitude: west),
                CLLocationCoordinate2D(latitude: north, longitude: east),
                CLLocationCoordinate2D(latitude: south, longitude: east),
            ])
    }

    /// A fixed frame around the whole range, with a margin so the outermost
    /// cells aren't flush against the edge.
    ///
    /// WHY THIS WORKS IN MAP POINTS AND NOT DEGREES
    /// Two earlier versions of this padded in degrees, via `MKCoordinateRegion`,
    /// and both clipped. Degrees of latitude are not a constant height on screen
    /// — Mercator stretches them towards the poles — so a span expressed in
    /// degrees does not translate to the area MapKit actually shows. For a
    /// species spanning most of the Americas the error is enormous, and the
    /// range ran off the top, bottom and sides at once.
    ///
    /// `MKMapRect` is the projected space the map is actually drawn in, so a
    /// rect that contains the cells keeps containing them, and an inset of N%
    /// is N% of what the viewer sees. `Map` fits the rect by expanding whichever
    /// axis the aspect ratio needs, and expanding only ever adds margin.
    ///
    /// Species spanning the antimeridian would need the union computed the long
    /// way round; none of the 47 species the models name does, and a
    /// wrong-but-visible world view is a better failure than a crash, so this
    /// takes the simple union deliberately.
    private static func mapRect(for indices: Set<Int>, cellDegrees: Double) -> MKMapRect? {
        var union: MKMapRect?
        for index in indices {
            let (lat, lon) = corner(of: index, cellDegrees: cellDegrees)
            // Latitude clamps just inside the Mercator limit: MKMapPoint is
            // undefined beyond it, and no bat is up there anyway.
            let south = max(-85, lat)
            let north = min(85, lat + cellDegrees)
            let a = MKMapPoint(CLLocationCoordinate2D(latitude: north, longitude: lon))
            let b = MKMapPoint(CLLocationCoordinate2D(latitude: south,
                                                      longitude: min(180, lon + cellDegrees)))
            let cell = MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                 width: abs(b.x - a.x), height: abs(b.y - a.y))
            union = union.map { $0.union(cell) } ?? cell
        }
        guard var rect = union, rect.width > 0, rect.height > 0 else { return nil }

        // 8% of the larger dimension on every side, so the margin reads the same
        // whether the range is tall or wide.
        let padding = max(rect.width, rect.height) * 0.08
        rect = rect.insetBy(dx: -padding, dy: -padding)
        return rect.intersects(.world) ? rect.intersection(.world) : rect
    }

    // MARK: - Chrome

    private static let updatedAtFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    /// Explains what the shading actually represents — occurrence records
    /// reported to GBIF, aggregated, not a modelled range — since a filled map
    /// otherwise reads as an authoritative range boundary, and recording effort
    /// varies wildly by region.
    private var infoButton: some View {
        Button {
            showInfoPopover = true
        } label: {
            Image(systemName: "info.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white, .black.opacity(0.55))
        }
        .buttonStyle(.plain)
        .padding(8)
        .accessibilityLabel("About this map")
        .popover(isPresented: $showInfoPopover) {
            VStack(alignment: .leading, spacing: 8) {
                Text("About this map")
                    .font(.headline)
                Text("This map is built from records reported to biodiversity databases (GBIF), grouped into blocks of roughly 100 km. It shows where the species has been recorded, not a modelled range — under-surveyed areas may still have the species present. It's the same data OpenBat uses to decide which species to expect near you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            // A popover's content sizes to its ideal (unconstrained) width
            // unless given one explicitly — `frame(maxWidth:)` alone only caps
            // an already-wide layout, it doesn't make Text wrap in the first
            // place. A fixed width here, paired with the Text's `fixedSize`
            // above (grow vertically, not horizontally), is what actually
            // forces the wrap.
            .frame(width: 280)
            .presentationCompactAdaptation(.popover)
        }
    }

    /// GBIF credit — required, and still accurate: the presence grid is derived
    /// from their occurrence records. Version and date come from the presence
    /// data so a user can see how stale the map is.
    private var attributionFooter: some View {
        HStack(spacing: 4) {
            Text("Distribution data via GBIF.org")
            if presenceStore.isLoaded {
                Text("· v\(presenceStore.dataVersion)")
                if let updated = presenceStore.updatedDate {
                    Text("· \(Self.updatedAtFormatter.string(from: updated))")
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
