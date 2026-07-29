//
//  GBIFService.swift
//  OpenBat
//
//  Minimal GBIF (Global Biodiversity Information Facility) client for the
//  species detail page's distribution map. Resolves a scientific name to a
//  GBIF taxon key once via `/v1/species/match`, then fetches a sample of the
//  species' own occurrence records as raw coordinates (see
//  `fetchOccurrencePoints`) — un-binned, so `GBIFRangeMapView` can bin them
//  into H3 hexagons (github.com/uber/h3, via the SwiftyH3 package) at
//  whatever resolution the current map zoom calls for, entirely on-device
//  and without re-fetching. This used to bin into a fixed lat/lon degree
//  grid itself, but that distorts cell area badly away from the equator and
//  can't adapt to zoom the way a hierarchical hex grid can.
//
//  This replaces an earlier `MKTileOverlay`-based approach
//  (`/v2/map/occurrence/density`) that went through three failed fixes in a
//  row, each one a different symptom of the same root problem — GBIF's
//  server-rendered point tiles draw markers at a fixed PIXEL size that never
//  scales with zoom, so nothing about how the client requests tiles can fix
//  it: (1) markers were legible zoomed out (many overlapping) but shrank to
//  near-invisible specks zoomed in (real dot size, just spread apart); (2)
//  clamping the requested zoom via `MKTileOverlay.maximumZ` to keep the last
//  legible tile past that point did nothing — that property is documented to
//  auto-upscale but is unreliable for custom (non-Apple) tile templates, so
//  tiles just stopped rendering past the cap; (3) clamping the tile path
//  ourselves (a custom `MKTileOverlay` subclass) "fixed" that by reusing the
//  coarse tile's URL for every finer sub-tile position — but that stretches
//  the ENTIRE coarse image into each small sub-tile rect instead of cropping
//  the relevant slice of it, which repeats the same picture across the
//  screen instead of showing one coherently scaled view. Aggregating real
//  occurrence coordinates ourselves and drawing geographic-radius shapes
//  sidesteps the whole class of bug: a shape with a real metre radius scales
//  correctly at every zoom level by construction, the same way any other
//  MapKit overlay does.
//
//  Unlike numbird (thousands of bird species, key never cached), OpenBat's
//  species list is small and fixed, so resolved taxon keys are persisted to
//  UserDefaults — avoids re-resolving the same name on every page visit.
//

import Foundation
import MapKit

enum GBIFService {
    private static let matchBase = "https://api.gbif.org/v1/species/match"
    private static let occurrenceSearchBase = "https://api.gbif.org/v1/occurrence/search"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 45
        // GBIF asks API callers to identify themselves; an unidentified client
        // is more likely to get throttled under load.
        cfg.httpAdditionalHeaders = ["User-Agent": "OpenBat-iOS (contact: privacy@openbat.app)"]
        return URLSession(configuration: cfg)
    }()

    private static let cacheDefaultsKey = "gbif.taxonKeyCache"
    /// Guards `taxonKeyCache`'s read-modify-write in `fetchTaxonKey` — several
    /// species cards can resolve concurrently (each a separate SwiftUI `.task`),
    /// and an unguarded read-then-write there is a lost-update race: two
    /// concurrent resolutions both read the same base dict, and whichever writes
    /// back second silently drops the other's newly-resolved key (self-healing
    /// on the next lookup, but still a needless re-fetch).
    private static let taxonKeyCacheLock = NSLock()

    private static var taxonKeyCache: [String: Int] {
        get {
            UserDefaults.standard.dictionary(forKey: cacheDefaultsKey) as? [String: Int] ?? [:]
        }
        set {
            UserDefaults.standard.set(newValue, forKey: cacheDefaultsKey)
        }
    }

    private struct MatchResponse: Decodable {
        let usageKey: Int?
        let matchType: String?
    }

    /// Resolves a scientific name to a GBIF taxon key, checking the on-device
    /// cache first. Returns nil on no match, decode failure, or network error
    /// — callers should show an "unavailable" state rather than retry.
    static func fetchTaxonKey(for scientificName: String) async -> Int? {
        if let cached = taxonKeyCache[scientificName] { return cached }
        guard var components = URLComponents(string: matchBase) else { return nil }
        components.queryItems = [URLQueryItem(name: "name", value: scientificName)]
        guard let url = components.url else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            let match = try JSONDecoder().decode(MatchResponse.self, from: data)
            guard match.matchType != "NONE", let key = match.usageKey else { return nil }
            taxonKeyCacheLock.lock()
            var cache = taxonKeyCache
            cache[scientificName] = key
            taxonKeyCache = cache
            taxonKeyCacheLock.unlock()
            return key
        } catch {
            return nil
        }
    }

    private struct OccurrenceSearchResponse: Decodable {
        let results: [OccurrenceRecord]
        let endOfRecords: Bool
    }

    private struct OccurrenceRecord: Decodable {
        let decimalLatitude: Double?
        let decimalLongitude: Double?
    }

    /// One occurrence record's raw coordinate. Cached un-binned (unlike the
    /// old fixed lat/lon grid this replaced) so the distribution map can bin
    /// these into whatever H3 hexagon resolution the current zoom level
    /// calls for — see `GBIFRangeMapView`'s zoom-adaptive H3 binning — without
    /// re-fetching from GBIF every time the resolution needs to change.
    struct GBIFOccurrencePoint: Codable {
        let lat: Double
        let lon: Double
    }

    private static let pointsCacheDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GBIFPoints", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func pointsCacheURL(taxonKey: Int) -> URL {
        pointsCacheDir.appendingPathComponent("\(taxonKey).json")
    }

    /// Distinguishes "queried successfully but this species genuinely has no
    /// (coordinate-bearing) occurrence records" from "couldn't reach GBIF at all" —
    /// callers show different copy for each rather than one generic error state.
    enum PointFetchResult {
        case success([GBIFOccurrencePoint])
        case noData
        case networkError
    }

    /// Fetches a sample of the taxon's occurrence records (paginated, up to
    /// `maxRecords`) as raw coordinates. Cached to disk indefinitely (species
    /// ranges don't meaningfully shift within an app's lifetime) — a repeat
    /// visit to the same species is instant and makes no network requests at all.
    static func fetchOccurrencePoints(taxonKey: Int, maxRecords: Int = 3000) async -> PointFetchResult {
        let cacheURL = pointsCacheURL(taxonKey: taxonKey)
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([GBIFOccurrencePoint].self, from: data) {
            return .success(cached)
        }

        var points: [GBIFOccurrencePoint] = []
        var anyPageSucceeded = false
        var pageDropped = false
        let pageSize = 300
        var offset = 0
        while offset < maxRecords {
            guard var components = URLComponents(string: occurrenceSearchBase) else { break }
            components.queryItems = [
                URLQueryItem(name: "taxonKey", value: String(taxonKey)),
                URLQueryItem(name: "hasCoordinate", value: "true"),
                URLQueryItem(name: "limit", value: "\(pageSize)"),
                URLQueryItem(name: "offset", value: "\(offset)"),
            ]
            guard let url = components.url else { break }
            let page: OccurrenceSearchResponse
            do {
                let (data, _) = try await session.data(from: url)
                page = try JSONDecoder().decode(OccurrenceSearchResponse.self, from: data)
                anyPageSucceeded = true
            } catch {
                // Keep whatever pages already succeeded rather than discarding
                // them, but remember the drop so a mid-pagination network error
                // doesn't get persisted to disk as if it were the complete range.
                pageDropped = true
                break
            }
            for record in page.results {
                guard let lat = record.decimalLatitude, let lon = record.decimalLongitude else { continue }
                points.append(GBIFOccurrencePoint(lat: lat, lon: lon))
            }
            offset += pageSize
            if page.endOfRecords || page.results.isEmpty { break }
        }

        guard !points.isEmpty else { return anyPageSucceeded ? .noData : .networkError }
        if !pageDropped, let data = try? JSONEncoder().encode(points) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return .success(points)
    }

    /// Coordinate region bounding a species' occurrence points, padded so the
    /// range isn't flush against the map edges — used to open the distribution
    /// map centred on the species' actual range instead of a fixed whole-world view.
    static func region(for points: [GBIFOccurrencePoint]) -> MKCoordinateRegion? {
        guard !points.isEmpty else { return nil }
        let lats = points.map(\.lat), lons = points.map(\.lon)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        // Floor the span so a handful of nearby points don't zoom in absurdly tight.
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 6),
                                    longitudeDelta: max((maxLon - minLon) * 1.4, 6))
        return MKCoordinateRegion(center: center, span: span)
    }

    // MARK: Location-based species priors

    /// Suggested prior for one species code, derived from nearby GBIF occurrence
    /// counts (see `suggestPriors`).
    struct PriorSuggestion {
        var enabled: Bool
        var prior: Float
    }

    private struct CountResponse: Decodable { let count: Int }

    /// Total GBIF occurrence records for `scientificName` within `radiusKm` of
    /// `coordinate`. Uses `geoDistance` + `limit=0` so GBIF returns just the
    /// count, not the records themselves — cheap enough to call once per
    /// species. Returns nil on any network/decode failure, distinct from a
    /// genuine 0 — `suggestPriors` skips (rather than disables) a species whose
    /// query failed, so a GBIF outage can't be mistaken for "no species here"
    /// and silently disable everything.
    private static func occurrenceCount(scientificName: String,
                                        near coordinate: CLLocationCoordinate2D,
                                        radiusKm: Int) async -> Int? {
        guard var components = URLComponents(string: occurrenceSearchBase) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "scientificName", value: scientificName),
            URLQueryItem(name: "geoDistance",
                        value: "\(coordinate.latitude),\(coordinate.longitude),\(radiusKm)km"),
            URLQueryItem(name: "limit", value: "0"),
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            return try JSONDecoder().decode(CountResponse.self, from: data).count
        } catch {
            return nil
        }
    }

    /// Suggests a prior for every code in `scientificNames`, based on GBIF
    /// occurrence records within `radiusKm` of `coordinate` — one species with
    /// zero nearby records is disabled (prior 0.01, matching the app's
    /// existing "disabled species" floor); any species with at least one
    /// nearby record is enabled, with its prior scaled by record count
    /// relative to the locally most-recorded species in the group (so a
    /// species with a handful of nearby records doesn't get treated as
    /// confidently as one with thousands, but still clears the "possible
    /// here" bar). Square-root compression keeps a single hyper-recorded
    /// species (disproportionate recording effort, not necessarily
    /// abundance) from crushing every other present species toward the floor.
    ///
    /// Runs all species lookups concurrently — the species lists here are
    /// small (≤31 codes today), and each request is a cheap `limit=0` count
    /// query, not a full occurrence fetch.
    static func suggestPriors(scientificNames: [String: String],
                              near coordinate: CLLocationCoordinate2D,
                              radiusKm: Int = 100) async -> [String: PriorSuggestion] {
        var counts: [String: Int] = [:]
        await withTaskGroup(of: (String, Int?).self) { group in
            for (code, sciName) in scientificNames {
                group.addTask {
                    (code, await occurrenceCount(scientificName: sciName, near: coordinate, radiusKm: radiusKm))
                }
            }
            // A failed query is skipped rather than treated as a real 0 — leaves that
            // species' existing prior untouched instead of disabling it on an outage.
            for await (code, count) in group {
                if let count { counts[code] = count }
            }
        }

        let maxCount = max(1, counts.values.max() ?? 1)
        var suggestions: [String: PriorSuggestion] = [:]
        for (code, count) in counts {
            if count == 0 {
                suggestions[code] = PriorSuggestion(enabled: false, prior: 0.01)
            } else {
                let scaled = 0.15 + 0.85 * Float(sqrt(Double(count) / Double(maxCount)))
                suggestions[code] = PriorSuggestion(enabled: true, prior: clampToPriorStep(scaled))
            }
        }
        return suggestions
    }

    /// Snaps a continuous prior estimate to the app's discrete prior scale
    /// (0.01/0.25/0.5/0.75/1.0), so GBIF-derived priors line up with the
    /// steps exposed on the manual per-species slider in ModelDetailView.
    private static let priorSteps: [Float] = [0.01, 0.25, 0.5, 0.75, 1.0]

    private static func clampToPriorStep(_ value: Float) -> Float {
        priorSteps.min(by: { abs($0 - value) < abs($1 - value) }) ?? 1.0
    }
}
