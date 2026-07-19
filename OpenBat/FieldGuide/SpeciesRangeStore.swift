//
//  SpeciesRangeStore.swift
//  OpenBat
//
//  Loads SpeciesRangeData.json — a snapshot of each field-guide species' GBIF
//  occurrence points, generated offline by generate_species_range_data.py and
//  committed to the repo alongside SpeciesGuideData.json — with a two-tier
//  resolution:
//
//    1. Cached  — the last successfully downloaded copy, in Application Support.
//    2. Remote  — raw JSON on GitHub, checked once per launch.
//
//  Unlike SpeciesGuideStore this ships nothing in the app bundle: range data is
//  large-ish (hundreds of KB, growing with the guide) and non-essential for
//  first launch, so there's no bundled fallback tier. On a cold install with no
//  cache and no network yet, `ranges` is simply empty and
//  `GBIFDistributionCard` falls back to its existing live GBIFService fetch for
//  any species not (yet) covered.
//
//  `refreshFromRemote()` adopts the downloaded copy only if its `dataVersion`
//  is strictly newer than what's cached, matching SpeciesGuideStore exactly —
//  regenerate the JSON, commit, bump `DATA_VERSION` in the generator script.
//

import Foundation

@MainActor
@Observable
final class SpeciesRangeStore {
    /// Raw content URL tracking `main`, same reasoning as
    /// `SpeciesGuideStore.remoteURL` — new commits picked up on next launch.
    static let remoteURL = URL(string:
        "https://raw.githubusercontent.com/NiallxD/OpenBat/main/SpeciesRangeData.json")!

    private(set) var ranges: [String: [GBIFService.GBIFOccurrencePoint]] = [:]
    private(set) var dataVersion = 0
    /// ISO 8601 string set by generate_species_range_data.py alongside each
    /// `dataVersion` bump — same reasoning as `SpeciesGuide.updatedAt`, shown
    /// next to the GBIF attribution so users can see how stale the bundled
    /// range snapshot is.
    private(set) var updatedAt: String?
    private(set) var isRefreshing = false
    private(set) var lastRefreshError: String?

    var updatedDate: Date? {
        updatedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    /// Decodes a `[lat, lon]` pair — generate_species_range_data.py writes
    /// points this way rather than `{"lat":...,"lon":...}` to skip the
    /// repeated key names, which dominate a rounded-coordinate point's byte
    /// count once pretty-printing and full float precision are already gone.
    private struct CompactPoint: Decodable {
        let lat: Double
        let lon: Double

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            lat = try container.decode(Double.self)
            lon = try container.decode(Double.self)
        }
    }

    private struct RangeData: Decodable {
        var schemaVersion: Int
        var dataVersion: Int
        var updatedAt: String?
        var ranges: [String: [CompactPoint]]

        static let supportedSchemaVersion = 1
    }

    private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("SpeciesGuide", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SpeciesRangeData.json")
    }()

    init() {
        guard let cached = Self.decode(from: Self.cacheURL) else { return }
        ranges = Self.convert(cached.ranges)
        dataVersion = cached.dataVersion
        updatedAt = cached.updatedAt
    }

    /// Check GitHub for newer range data; adopt and cache it if `dataVersion`
    /// advanced. Safe to call on every launch — offline or on failure whatever
    /// is already loaded (cached copy, or nothing) stays untouched.
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
            let remote = try JSONDecoder().decode(RangeData.self, from: data)
            guard remote.schemaVersion <= RangeData.supportedSchemaVersion else {
                lastRefreshError = "Range data update needs a newer app version."
                return
            }
            guard remote.dataVersion > dataVersion else { return }
            try data.write(to: Self.cacheURL, options: .atomic)
            ranges = Self.convert(remote.ranges)
            dataVersion = remote.dataVersion
            updatedAt = remote.updatedAt
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    private static func decode(from url: URL) -> RangeData? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(RangeData.self, from: data),
              decoded.schemaVersion <= RangeData.supportedSchemaVersion else { return nil }
        return decoded
    }

    private static func convert(_ raw: [String: [CompactPoint]]) -> [String: [GBIFService.GBIFOccurrencePoint]] {
        raw.mapValues { points in
            points.map { GBIFService.GBIFOccurrencePoint(lat: $0.lat, lon: $0.lon) }
        }
    }
}
