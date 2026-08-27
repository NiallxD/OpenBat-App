//
//  SpeciesPresenceStore.swift
//  OpenBat
//
//  Loads SpeciesPresenceData.json — a coarse global grid of where each species
//  the classifiers can name actually lives, generated offline by
//  tools/generate_species_presence_data.py — and answers, for a coordinate,
//  whether a species belongs there.
//
//  This replaces asking GBIF at runtime how many times a species has been
//  recorded near the user. That approach had three failures this one doesn't:
//
//    1. It measured recording effort, not bats. A museum-heavy county outranked
//       a well-populated one.
//    2. A query that failed (about half of them, fired ~50 at once) left the
//       species at its factory default of "enabled, full weight", so not
//       knowing was indistinguishable from being certain. See Context.md.
//    3. It queried by scientific name at runtime, which is wrong in both
//       directions — the app's name for the western red bat is older than
//       GBIF's (0 records near San Francisco under Lasiurus blossevillii, 90
//       under Lasiurus frantzii), and its name for the serotine is newer than
//       GBIF's (Cnephaeus serotinus matches only the GENUS, so the serotine
//       returned 0 records near London and was switched off in the one country
//       it is most familiar in). Taxonomy is now resolved once, at generation
//       time, where a human can read the report.
//
//  Three resolution tiers, matching SpeciesGuideStore:
//
//    1. Bundled — ships in the app. This file decides which species the app is
//       willing to name, so a cold install with no network must not be left
//       with no opinion; a copy travels in the app. (The old occurrence-point
//       range data was download-only, on the reasoning that a missing dot map
//       was merely cosmetic. That was true of it and is not true of this.)
//    2. Cached  — the last successfully downloaded copy, in Application Support.
//    3. Remote  — raw JSON on GitHub, checked once per launch.
//
//  KEYED BY SPECIES CODE, not scientific name — deliberately the opposite of
//  SpeciesGuideLookup's join. That file joins on scientific name to avoid a
//  third mapping table between two independently-maintained vocabularies. Here
//  there is no second vocabulary: the generator reads the classifiers' own
//  code -> scientific name tables, so the code IS the shared key. It also has
//  to be: one code can span several taxa (LABL covers both Lasiurus
//  blossevillii and L. frantzii), which a scientific-name key cannot express.
//

import Foundation
import CoreLocation

@MainActor
@Observable
final class SpeciesPresenceStore {

    /// What the data says about one species at one place. The three cases are
    /// the whole point: `unknown` is not `absent`, and conflating them is the
    /// bug this file exists to fix.
    enum Presence: Equatable {
        /// The species' range covers this location. `months` is a bitmask,
        /// bit 0 = January, of the months it has actually been recorded in
        /// cells around here — 0 when the sample carried no usable dates.
        case present(months: UInt16)
        /// There is range data for this species and it does not cover here.
        case absent
        /// No usable range data for this species — too few records, or a taxon
        /// that couldn't be resolved. The app must fall back to a neutral prior
        /// rather than guessing either way.
        case unknown
    }

    /// Raw content URL tracking `main`, same reasoning as
    /// `SpeciesGuideStore.remoteURL` — new commits picked up on next launch.
    static let remoteURL = URL(string:
        "https://raw.githubusercontent.com/NiallxD/OpenBat-FieldGuide/main/SpeciesPresenceData.json")!

    /// code -> (cell index -> month bitmask). Absent key means no range data.
    ///
    /// This is the MODELLED range — observed cells plus the buffer and bridge
    /// around them — and it is what every "does this bat live here" question
    /// resolves against. `density` below carries the observations it was built
    /// from, for the map to draw; nothing decides plausibility from those.
    private(set) var presence: [String: [Int: UInt16]] = [:]

    /// code -> where the records actually are, for the range map only.
    private(set) var density: [String: SpeciesDensity] = [:]

    /// The observations behind one species' modelled range.
    ///
    /// Kept apart from `presence` because the two answer different questions.
    /// `presence` answers "could this bat be here", where a buffered cell is as
    /// good as a recorded one. This answers "what do we actually know about
    /// here", where the difference between a cell holding 400 records and a
    /// cell nobody has ever recorded in is the whole point — a range drawn one
    /// flat colour asserts a uniform population across ground that ranges from
    /// heavily surveyed to entirely inferred.
    struct SpeciesDensity: Equatable {
        /// Cell index -> records GBIF holds for it. Only cells with at least
        /// one record appear; everything else in the range is inferred.
        var observed: [Int: Int]
        /// Three ascending record counts splitting `observed` into four tiers.
        /// Computed per species by the generator — counts differ by five orders
        /// of magnitude between species, so one shared scale would flatten every
        /// sparse one — and shipped so the phone never sorts cells to draw a map.
        /// Fewer than three when a species' counts are too tied to separate.
        var breaks: [Int]

        /// Which tier a cell falls in, 0-based, or nil if it holds no records.
        func tier(forCell index: Int) -> Int? {
            guard let count = observed[index] else { return nil }
            return breaks.filter { count >= $0 }.count
        }
    }

    /// Codes the generator explicitly recorded as having no usable range, kept
    /// separate from "not in the file at all" only for diagnostics — both
    /// resolve to `.unknown`.
    private(set) var unknownCodes: Set<String> = []
    private(set) var cellDegrees: Double = 1.0
    private(set) var dataVersion = 0
    private(set) var updatedAt: String?
    private(set) var isRefreshing = false
    private(set) var lastRefreshError: String?

    var updatedDate: Date? {
        updatedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    /// True once any tier has loaded. Callers use this to tell "the data says
    /// nothing about this bat" from "the data hasn't loaded yet", which are
    /// different reasons to stay neutral.
    var isLoaded: Bool { !presence.isEmpty }

    // MARK: - Wire format

    private struct PresenceData: Decodable {
        var schemaVersion: Int
        var dataVersion: Int
        var updatedAt: String?
        var cellDegrees: Double
        var unknown: [String]
        var presence: [String: SpeciesPresenceEntry]

        static let supportedSchemaVersion = 1
    }

    private struct SpeciesPresenceEntry: Decodable {
        /// Delta-encoded, ascending: the generator stores gaps rather than
        /// absolute indices because occupied cells cluster, which roughly halves
        /// the file. Re-accumulated on load.
        var cells: [Int]
        var months: [Int]
        /// The subset of `cells` that holds records, delta-encoded the same way,
        /// with `counts` aligned to it. Optional so that data predating the
        /// density tiers still decodes — the map falls back to drawing the range
        /// flat, which is what it did before them.
        var observed: [Int]?
        var counts: [Int]?
        var breaks: [Int]?
    }

    // MARK: - Loading

    nonisolated private static let bundledURL: URL? =
        Bundle.main.url(forResource: "SpeciesPresenceData", withExtension: "json")

    nonisolated private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("SpeciesGuide", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SpeciesPresenceData.json")
    }()

    /// Cheap on purpose — see `SpeciesGuideStore.init()`: this is constructed as
    /// a SwiftUI `@State` default value and re-evaluates whenever that closure
    /// does. The actual decode happens in `loadLocal()`, off the main thread.
    init() {}

    /// Loads the newest of the cached and bundled copies, off the main thread.
    /// Call once, e.g. from a `.task` alongside `refreshFromRemote()`.
    func loadLocal() async {
        let loaded = await Task.detached(priority: .userInitiated) { () -> PresenceData? in
            let cached = Self.decode(from: Self.cacheURL)
            let bundled = Self.bundledURL.flatMap { Self.decode(from: $0) }
            // A cache older than the bundle happens after an app update ships
            // newer data than the device last downloaded.
            switch (cached, bundled) {
            case let (cached?, bundled?): return cached.dataVersion >= bundled.dataVersion ? cached : bundled
            case let (cached?, nil):      return cached
            case let (nil, bundled?):     return bundled
            case (nil, nil):              return nil
            }
        }.value
        guard let loaded else { return }
        adopt(loaded)
    }

    /// Check GitHub for newer presence data; adopt and cache it if `dataVersion`
    /// advanced. Safe to call on every launch — offline or on failure, whatever
    /// is already loaded stays untouched.
    func refreshFromRemote() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        lastRefreshError = nil
        do {
            var request = URLRequest(url: Self.remoteURL)
            // Bypass URLCache: the whole point is to see the latest commit.
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let remote = try JSONDecoder().decode(PresenceData.self, from: data)
            guard remote.schemaVersion <= PresenceData.supportedSchemaVersion else {
                lastRefreshError = "Species range update needs a newer app version."
                return
            }
            guard remote.dataVersion > dataVersion else { return }
            try data.write(to: Self.cacheURL, options: .atomic)
            adopt(remote)
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    private func adopt(_ data: PresenceData) {
        cellDegrees = data.cellDegrees > 0 ? data.cellDegrees : 1.0
        dataVersion = data.dataVersion
        updatedAt = data.updatedAt
        unknownCodes = Set(data.unknown)
        density = data.presence.compactMapValues { entry -> SpeciesDensity? in
            guard let observed = entry.observed, let counts = entry.counts,
                  observed.count == counts.count, !observed.isEmpty else { return nil }
            var cells: [Int: Int] = [:]
            cells.reserveCapacity(observed.count)
            var index = 0
            for (delta, count) in zip(observed, counts) {
                index += delta
                cells[index] = count
            }
            return SpeciesDensity(observed: cells, breaks: entry.breaks ?? [])
        }
        presence = data.presence.compactMapValues { entry in
            // A malformed entry is dropped rather than half-adopted: a species
            // with a truncated cell list would read as absent across most of its
            // real range, which is worse than having no opinion about it.
            guard entry.cells.count == entry.months.count else { return nil }
            var cells: [Int: UInt16] = [:]
            cells.reserveCapacity(entry.cells.count)
            var index = 0
            for (delta, months) in zip(entry.cells, entry.months) {
                index += delta
                cells[index] = UInt16(truncatingIfNeeded: months)
            }
            return cells
        }
    }

    nonisolated private static func decode(from url: URL) -> PresenceData? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(PresenceData.self, from: data),
              decoded.schemaVersion <= PresenceData.supportedSchemaVersion else {
            // Corrupt/truncated/unsupported-schema cache — self-heal rather than
            // failing to decode it again on every future launch. Never delete the
            // bundled copy (it isn't writable, and `removeItem` failing there is
            // harmless, but be explicit about intent).
            if url == cacheURL { try? FileManager.default.removeItem(at: url) }
            return nil
        }
        return decoded
    }

    // MARK: - Asking

    /// Whether `code` belongs at `coordinate`.
    ///
    /// Anything the data doesn't cover is `.unknown`, never `.absent` — a bat
    /// nobody has range data for is not a bat that isn't there.
    func presence(forCode code: String, at coordinate: CLLocationCoordinate2D) -> Presence {
        guard let cells = presence[code] else { return .unknown }
        guard let months = cells[Self.cellIndex(for: coordinate, cellDegrees: cellDegrees)] else {
            return .absent
        }
        return .present(months: months)
    }

    /// As above, but also asks whether the species has been recorded around here
    /// in `month` (1–12). A species present but never recorded locally in this
    /// month is the migration/hibernation case.
    ///
    /// A zero mask means the sample carried no usable dates, which is treated as
    /// "no seasonal information" and passes — the alternative is silently
    /// switching off a resident bat because its records lacked a date field.
    func isPresent(code: String, at coordinate: CLLocationCoordinate2D, inMonth month: Int) -> Bool {
        guard case let .present(months) = presence(forCode: code, at: coordinate) else { return false }
        guard months != 0, (1...12).contains(month) else { return true }
        return months & (1 << UInt16(month - 1)) != 0
    }

    /// Row-major index of the cell containing `coordinate`, matching
    /// `generate_species_presence_data.py`'s `cell_index` exactly — the two must
    /// agree bit for bit or every lookup silently misses by a cell.
    ///
    /// Row 0 is the south pole, column 0 is -180°. Clamped, not wrapped: a
    /// coordinate of exactly 90.0 or 180.0 would otherwise land one past the end.
    nonisolated static func cellIndex(for coordinate: CLLocationCoordinate2D,
                                      cellDegrees: Double) -> Int {
        let rows = Int((180 / cellDegrees).rounded())
        let cols = Int((360 / cellDegrees).rounded())
        let row = min(rows - 1, max(0, Int((coordinate.latitude + 90) / cellDegrees)))
        let col = min(cols - 1, max(0, Int((coordinate.longitude + 180) / cellDegrees)))
        return row * cols + col
    }
}
