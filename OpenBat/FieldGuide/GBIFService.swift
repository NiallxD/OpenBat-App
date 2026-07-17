//
//  GBIFService.swift
//  OpenBat
//
//  Minimal GBIF (Global Biodiversity Information Facility) client for the
//  species detail page's distribution map. Ported down from the same
//  pattern used in the numbird app (Birding_Data/Core/Supporting/GBIFService.swift):
//  resolve a scientific name to a GBIF taxon key once via `/v1/species/match`,
//  then hand MapKit a `/v2/map/occurrence/density` tile overlay — no manual
//  tile fetching or parsing needed.
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
    private static let tileBase = "https://api.gbif.org/v2/map/occurrence/density"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 45
        return URLSession(configuration: cfg)
    }()

    private static let cacheDefaultsKey = "gbif.taxonKeyCache"

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
            var cache = taxonKeyCache
            cache[scientificName] = key
            taxonKeyCache = cache
            return key
        } catch {
            return nil
        }
    }

    private struct OccurrenceSearchResponse: Decodable {
        let results: [OccurrenceRecord]
    }

    private struct OccurrenceRecord: Decodable {
        let decimalLatitude: Double?
        let decimalLongitude: Double?
    }

    /// Fetches a sample of occurrence records for the taxon and returns the
    /// coordinate region bounding them, so the map can open centered on the
    /// species' actual range instead of a fixed whole-world view. Returns nil
    /// on no data/network error — callers should fall back to a default
    /// region rather than leave the map unset.
    static func fetchOccurrenceExtent(taxonKey: Int) async -> MKCoordinateRegion? {
        guard var components = URLComponents(string: occurrenceSearchBase) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "taxonKey", value: String(taxonKey)),
            URLQueryItem(name: "hasCoordinate", value: "true"),
            URLQueryItem(name: "limit", value: "300")
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(OccurrenceSearchResponse.self, from: data)
            let coords = response.results.compactMap { record -> (lat: Double, lon: Double)? in
                guard let lat = record.decimalLatitude, let lon = record.decimalLongitude else { return nil }
                return (lat, lon)
            }
            guard !coords.isEmpty else { return nil }
            let lats = coords.map(\.lat), lons = coords.map(\.lon)
            let minLat = lats.min()!, maxLat = lats.max()!
            let minLon = lons.min()!, maxLon = lons.max()!
            let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                                 longitude: (minLon + maxLon) / 2)
            // Pad so occurrence points aren't flush against the map edges;
            // floor the span so a handful of nearby records don't zoom in
            // absurdly tight.
            let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 6),
                                         longitudeDelta: max((maxLon - minLon) * 1.4, 6))
            return MKCoordinateRegion(center: center, span: span)
        } catch {
            return nil
        }
    }

    /// A slippy-map tile overlay of GBIF occurrence density for the given
    /// taxon — MapKit streams tiles lazily as the user pans/zooms.
    ///
    /// `style=classic.poly` (and the other `.poly`/hex-bin styles) render as
    /// fully transparent tiles for bat occurrence data — verified against
    /// GBIF directly, not a bug in this app's request. `purpleHeat.point`
    /// plots raw occurrence points instead and actually has visible data.
    static func rangeTileOverlay(taxonKey: Int) -> MKTileOverlay {
        let template = "\(tileBase)/{z}/{x}/{y}@1x.png?taxonKey=\(taxonKey)&style=purpleHeat.point"
        let overlay = MKTileOverlay(urlTemplate: template)
        overlay.canReplaceMapContent = false
        return overlay
    }
}
