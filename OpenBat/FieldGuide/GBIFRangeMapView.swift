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
//  The grid is drawn as its own outline rather than as cells: the boundary of
//  the occupied region is traced, giving one polygon per connected landmass
//  (holes included), so a widespread species covering ~1100 one-degree cells
//  becomes a handful of shapes with no internal edges at all.
//
//  SHADED BY RECORD DENSITY, AND WHY IT IS DRAWN IN NESTED LAYERS (2026-08-27)
//  --------------------------------------------------------------------------
//  One flat purple asserted something the data does not support: that the bat
//  is equally at home everywhere inside the boundary. Most of a modelled range
//  is buffer and bridge — ground nobody has ever recorded in, included because
//  of what surrounds it — and among the cells that DO hold records, counts run
//  from one to six figures. So the range is drawn in four tiers by record
//  count, over a pale wash for the inferred part.
//
//  The tiers are drawn as NESTED regions, each one a subset of the one below:
//  the wash covers the whole range, then every cell holding any record, then
//  every cell above the first break, and so on. Drawing them as disjoint bands
//  instead would put a shared edge between every pair of neighbouring tiers,
//  and MapKit anti-aliases each polygon's edge independently — the seam problem
//  described above, which is why cells became outlines in the first place.
//  Nested regions have no shared edges at all: each layer simply paints over
//  the middle of the last.
//
//  THE TOGGLE
//  ----------
//  Two things are worth seeing and they are not the same thing. "Modelled" is
//  the range the app actually reasons with — what it consults to decide whether
//  a species is plausible where the user is standing. "Observations" is the
//  evidence underneath it, the cells GBIF holds records for and nothing else.
//  A user who wants to know why their local bat is or isn't offered should be
//  able to see both, and the gap between them is honest information rather than
//  something to hide.
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

    /// Which of the two views is showing. Modelled first: it is what the app
    /// reasons with, and the raw observations read as alarmingly sparse without
    /// that context.
    enum RangeMode: String, CaseIterable, Identifiable {
        case modelled = "Range"
        case observations = "Records"
        var id: String { rawValue }
    }

    @Environment(\.colorScheme) private var colorScheme

    @State private var mode: RangeMode = .modelled
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

    /// One drawn shape: a connected region of the presence grid, outlined —
    /// with its holes, if it has any.
    private struct RangeShape: Identifiable {
        let id: Int
        let polygon: MKPolygon
    }

    /// One nested layer of the map: everything at or above a density tier.
    private struct RangeLayer: Identifiable {
        let id: Int
        /// nil for the inferred wash, which is not a density tier at all.
        let tier: Int?
        let shapes: [RangeShape]
    }

    /// Wash first, then four tiers light to dark.
    ///
    /// Two ramps rather than one with opacity: MapKit's own map is near-white
    /// in light mode and near-black in dark, so a single translucent purple
    /// reads as lavender on one and as a bruise on the other. Both ramps run
    /// from "barely there" to "unmistakable" against their own background,
    /// which is what the shading has to communicate.
    private static func palette(_ scheme: ColorScheme) -> (inferred: Color, tiers: [Color]) {
        if scheme == .dark {
            return (Color(red: 0.23, green: 0.19, blue: 0.33),
                    [Color(red: 0.36, green: 0.25, blue: 0.60),
                     Color(red: 0.49, green: 0.33, blue: 0.79),
                     Color(red: 0.62, green: 0.47, blue: 0.91),
                     Color(red: 0.77, green: 0.65, blue: 1.00)])
        }
        return (Color(red: 0.925, green: 0.886, blue: 0.984),
                [Color(red: 0.796, green: 0.702, blue: 0.925),
                 Color(red: 0.651, green: 0.498, blue: 0.863),
                 Color(red: 0.490, green: 0.294, blue: 0.820),
                 Color(red: 0.275, green: 0.133, blue: 0.549)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let range = resolvedRange {
                    let palette = Self.palette(colorScheme)
                    Map(position: $camera, interactionModes: []) {
                        // Painted in order, each layer a subset of the last —
                        // see the header note on nesting. No stroke and no
                        // shared edges, so no seams.
                        ForEach(range.layers) { layer in
                            ForEach(layer.shapes) { shape in
                                MapPolygon(shape.polygon)
                                    .foregroundStyle(
                                        layer.tier.map { palette.tiers[min($0, palette.tiers.count - 1)] }
                                        ?? palette.inferred)
                            }
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
            if resolvedRange != nil, hasDensity {
                modePicker
                legend
            }
            attributionFooter
        }
    }

    /// Range vs. records. Hidden when there is no density data to switch to —
    /// a picker with one working option is worse than no picker.
    private var modePicker: some View {
        Picker("Map shows", selection: $mode) {
            ForEach(RangeMode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    /// What the shades mean, in records. Without this the tiers are decoration
    /// — a reader can see that one part of the range is darker than another and
    /// has no way to know whether that is ten records or ten thousand.
    private var legend: some View {
        let palette = Self.palette(colorScheme)
        let density = presenceStore.density[species.presenceCode]
        let breaks = density?.breaks ?? []
        let smallest = density?.observed.values.min() ?? 1
        return VStack(alignment: .leading, spacing: 5) {
            Text("Records per \(Self.cellWidthDescription) cell")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            // Wraps rather than truncating: four tiers of five-figure counts
            // do not fit one line on a small phone.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { tierSwatches(palette: palette, breaks: breaks, smallest: smallest) }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) { tierSwatches(palette: palette, breaks: breaks,
                                                       smallest: smallest, range: 0..<2) }
                    HStack(spacing: 10) { tierSwatches(palette: palette, breaks: breaks,
                                                       smallest: smallest, range: 2..<(breaks.count + 1)) }
                }
            }
            if mode == .modelled {
                HStack(spacing: 5) {
                    swatch(palette.inferred)
                    Text("No records — inferred from surrounding cells")
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    @ViewBuilder
    private func tierSwatches(palette: (inferred: Color, tiers: [Color]),
                              breaks: [Int], smallest: Int,
                              range: Range<Int>? = nil) -> some View {
        let all = 0..<(breaks.count + 1)
        ForEach(Array(range ?? all).filter { all.contains($0) }, id: \.self) { tier in
            HStack(spacing: 5) {
                swatch(palette.tiers[min(tier, palette.tiers.count - 1)])
                Text(Self.tierLabel(breaks: breaks, smallest: smallest, tier: tier))
                    .monospacedDigit()
            }
        }
    }

    private func swatch(_ colour: Color) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(colour)
            .frame(width: 11, height: 11)
    }

    /// The record span one tier covers, e.g. "1", "2–3", "238+".
    private static func tierLabel(breaks: [Int], smallest: Int, tier: Int) -> String {
        guard !breaks.isEmpty else { return "\(smallest)+" }
        let low = tier == 0 ? smallest : breaks[tier - 1]
        guard tier < breaks.count else { return "\(low.formatted())+" }
        let high = breaks[tier] - 1
        return high <= low ? "\(low.formatted())" : "\(low.formatted())–\(high.formatted())"
    }

    /// Cell size in round numbers, for the legend heading. Derived rather than
    /// hardcoded so it stays true if the generator's resolution ever changes.
    private static var cellWidthDescription: String { "100 km" }

    /// Whether this species has per-cell record counts to shade and toggle
    /// with. False for data generated before the density tiers, where the map
    /// falls back to drawing the range in one tone.
    private var hasDensity: Bool {
        !(presenceStore.density[species.presenceCode]?.observed.isEmpty ?? true)
    }

    /// Why there is no map, said precisely. There used to be a third case here
    /// — "no code assigned in the guide" — which `presenceCode` has since made
    /// impossible: every entry resolves to a key, so a missing map now always
    /// means missing DATA, never missing wiring.
    private var unavailableReason: String {
        guard presenceStore.isLoaded else {
            return "Range data hasn't loaded yet."
        }
        return "There aren't enough records of this species to map where it lives."
    }

    private var resolvedRange: (rect: MKMapRect, layers: [RangeLayer])? {
        guard let cells = presenceStore.presence[species.presenceCode],
              !cells.isEmpty else { return nil }
        let degrees = presenceStore.cellDegrees
        let modelled = Set(cells.keys)
        guard let rect = Self.mapRect(for: modelled, cellDegrees: degrees) else { return nil }

        let density = presenceStore.density[species.presenceCode]
        guard let density, !density.observed.isEmpty else {
            // Data predating the density tiers: draw the range in one mid tone,
            // exactly as it looked before them, rather than showing nothing.
            return (rect, [RangeLayer(id: 0, tier: 2,
                                      shapes: Self.shapes(for: modelled, cellDegrees: degrees))])
        }

        var layers: [RangeLayer] = []
        if mode == .modelled {
            // The wash underneath everything: the whole modelled range, most of
            // which holds no records at all.
            layers.append(RangeLayer(id: 0, tier: nil,
                                     shapes: Self.shapes(for: modelled, cellDegrees: degrees)))
        }
        // Nested tiers, each the cells at or above one break — so every layer
        // is a subset of the one before it and paints over its middle.
        let observed = Set(density.observed.keys)
        for tier in 0...density.breaks.count {
            let cellsInTier: Set<Int> = tier == 0
                ? observed
                : observed.filter { density.observed[$0, default: 0] >= density.breaks[tier - 1] }
            guard !cellsInTier.isEmpty else { continue }
            layers.append(RangeLayer(id: tier + 1, tier: tier,
                                     shapes: Self.shapes(for: cellsInTier, cellDegrees: degrees)))
        }
        return (rect, layers)
    }

    // MARK: - Grid geometry

    /// Cell index back to its south-west corner, matching
    /// `SpeciesPresenceStore.cellIndex` and the generator's `cell_index`.
    private static func corner(of index: Int, cellDegrees: Double) -> (lat: Double, lon: Double) {
        let cols = Int((360 / cellDegrees).rounded())
        let (row, col) = index.quotientAndRemainder(dividingBy: cols)
        return (Double(row) * cellDegrees - 90, Double(col) * cellDegrees - 180)
    }

    /// A corner of the grid — a lattice point, in whole cells, x east and y
    /// north. Integers, so two cells that meet always agree on the corner they
    /// share, exactly, with no floating-point drift to leave a hairline gap.
    private struct GridVertex: Hashable {
        let x: Int
        let y: Int
    }

    /// Traces the outline of the occupied region, one polygon per connected
    /// area, holes carried as interior polygons.
    ///
    /// WHY OUTLINES RATHER THAN CELLS (2026-08-17)
    /// Every earlier version drew the cells themselves — first one polygon per
    /// cell, then merged into horizontal runs — and every one of them showed
    /// seams where two pieces met. MapKit anti-aliases each polygon's edge
    /// independently, so a shared edge lands as two half-covered pixels rather
    /// than one full one; against a translucent fill that reads as a pale line
    /// at every row boundary. Inflating each run so neighbours overlapped
    /// replaced the pale line with a dark one, because two translucent fills
    /// stacked are darker than one. There is no inflation that fixes both:
    /// abutting is too light, overlapping is too dark, and only *not having an
    /// interior edge* is neither.
    ///
    /// So the interior edges are removed before drawing. An edge of a cell is
    /// part of the outline only if the cell across it is absent; keeping those
    /// and dropping the rest leaves closed loops, which chain into rings.
    /// Wound as below (anticlockwise around each cell) outer rings come out
    /// anticlockwise and holes clockwise, so the sign of a ring's area says
    /// which it is — no containment test needed to classify them, only to pair
    /// each hole with the ring it sits in.
    private static func shapes(for indices: Set<Int>, cellDegrees: Double) -> [RangeShape] {
        let cols = Int((360 / cellDegrees).rounded())
        var cells: Set<GridVertex> = []
        for index in indices {
            let (row, col) = index.quotientAndRemainder(dividingBy: cols)
            cells.insert(GridVertex(x: col, y: row))
        }

        // Boundary edges, directed, keyed by where each one starts.
        var outgoing: [GridVertex: [GridVertex]] = [:]
        func addEdge(_ from: GridVertex, _ to: GridVertex) {
            outgoing[from, default: []].append(to)
        }
        for cell in cells {
            let (x, y) = (cell.x, cell.y)
            if !cells.contains(GridVertex(x: x, y: y - 1)) {
                addEdge(GridVertex(x: x, y: y), GridVertex(x: x + 1, y: y))
            }
            if !cells.contains(GridVertex(x: x + 1, y: y)) {
                addEdge(GridVertex(x: x + 1, y: y), GridVertex(x: x + 1, y: y + 1))
            }
            if !cells.contains(GridVertex(x: x, y: y + 1)) {
                addEdge(GridVertex(x: x + 1, y: y + 1), GridVertex(x: x, y: y + 1))
            }
            if !cells.contains(GridVertex(x: x - 1, y: y)) {
                addEdge(GridVertex(x: x, y: y + 1), GridVertex(x: x, y: y))
            }
        }

        // Follow the edges into closed rings, consuming each exactly once. A
        // vertex where two regions touch corner-to-corner has two ways out;
        // either choice closes both rings, so take whichever is to hand.
        var rings: [[GridVertex]] = []
        while let start = outgoing.first(where: { !$0.value.isEmpty })?.key {
            var ring: [GridVertex] = [start]
            var current = start
            while let next = outgoing[current]?.popLast() {
                if outgoing[current]?.isEmpty == true { outgoing[current] = nil }
                if next == start { break }
                ring.append(next)
                current = next
            }
            if ring.count >= 3 { rings.append(ring) }
        }

        // Anticlockwise (positive area) is an outer ring; clockwise is a hole.
        var outers: [[GridVertex]] = []
        var holes: [[GridVertex]] = []
        for ring in rings {
            if signedArea(ring) > 0 { outers.append(ring) } else { holes.append(ring) }
        }

        // Pair each hole with the smallest outer ring containing it — smallest
        // because an island inside a lake inside a landmass is contained by
        // both, and it belongs to the lake's.
        var holesByOuter: [Int: [[GridVertex]]] = [:]
        for hole in holes {
            guard let probe = hole.first else { continue }
            var best: Int?
            var bestArea = Double.greatestFiniteMagnitude
            for (i, outer) in outers.enumerated() where contains(outer, probe) {
                let area = abs(signedArea(outer))
                if area < bestArea { best = i; bestArea = area }
            }
            if let best { holesByOuter[best, default: []].append(hole) }
        }

        return outers.enumerated().map { index, outer in
            let interiors = (holesByOuter[index] ?? []).map {
                polygon(from: $0, cellDegrees: cellDegrees)
            }
            return RangeShape(
                id: index,
                polygon: polygon(from: outer, cellDegrees: cellDegrees,
                                 interiorPolygons: interiors.isEmpty ? nil : interiors))
        }
    }

    /// Twice the ring's signed area (shoelace) — only its sign and relative
    /// magnitude are used, so the factor of two is left in.
    private static func signedArea(_ ring: [GridVertex]) -> Double {
        var total = 0.0
        for i in ring.indices {
            let a = ring[i]
            let b = ring[(i + 1) % ring.count]
            total += Double(a.x * b.y - b.x * a.y)
        }
        return total
    }

    /// Ray casting, on the integer lattice. Only ever asked about a point on a
    /// *different* ring, so the boundary case doesn't arise.
    private static func contains(_ ring: [GridVertex], _ point: GridVertex) -> Bool {
        var inside = false
        for i in ring.indices {
            let a = ring[i]
            let b = ring[(i + 1) % ring.count]
            guard (a.y > point.y) != (b.y > point.y) else { continue }
            let crossing = Double(b.x - a.x) * Double(point.y - a.y)
                / Double(b.y - a.y) + Double(a.x)
            if Double(point.x) < crossing { inside.toggle() }
        }
        return inside
    }

    private static func polygon(from ring: [GridVertex], cellDegrees: Double,
                                interiorPolygons: [MKPolygon]? = nil) -> MKPolygon {
        var coordinates = ring.map { vertex in
            CLLocationCoordinate2D(
                // Clamped just inside the Mercator limit for the same reason
                // `mapRect` clamps: MKMapPoint is undefined beyond it. No bat
                // is up there, so no real outline is moved by this.
                latitude: min(85, max(-85, Double(vertex.y) * cellDegrees - 90)),
                longitude: Double(vertex.x) * cellDegrees - 180)
        }
        return MKPolygon(coordinates: &coordinates, count: coordinates.count,
                         interiorPolygons: interiorPolygons)
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
                Text("Built from records reported to biodiversity databases (GBIF), grouped into blocks of roughly 100 km.\n\n**Records** shows only the blocks someone has actually reported this species in, shaded by how many records each holds. Darker means more records — which partly reflects where people have looked, not only where the bats are.\n\n**Range** fills in the gaps: blocks next to and between the records are included too, and shown in the palest shade because nobody has recorded the species there. This is the version OpenBat uses to decide which species to expect near you.\n\nNeither is a surveyed range map. An under-recorded area may still have the species in it.")
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
