//
//  WikipediaSpeciesImageService.swift
//  OpenBat
//
//  Fetches a representative photo for a species from Wikipedia's public REST
//  API — the same three-call pattern (page summary is skipped here, OpenBat
//  only needs the photo) used by the numbird/Birding_Data companion app for
//  its bird species detail pages: media-list → imageinfo, picking the first
//  landscape-oriented candidate (or the widest, if none are landscape).
//
//  Unlike that app's version, every request here sets a descriptive
//  User-Agent — required by Wikimedia's API etiquette policy for non-WMF
//  clients (https://meta.wikimedia.org/wiki/User-Agent_policy); omitting it
//  risks throttling/blocking.
//
//  Licensing: Wikipedia images are near-universally CC BY-SA or public domain.
//  Per-image attribution (photographer + license) is pulled from the
//  `extmetadata` `iiprop` below and shown by callers as a real credit rather
//  than a blanket "Wikipedia" caption; `Photo.creditText` falls back to that
//  blanket form only when a photo has no Artist/LicenseShortName metadata.
//

import Foundation

enum WikipediaSpeciesImageService {
    struct Photo: Codable, Equatable {
        let url: URL
        /// Stripped-HTML Artist field, e.g. "Jane Doe" — nil if Wikipedia has
        /// no Artist metadata for this file.
        let artist: String?
        /// e.g. "CC BY-SA 4.0" — nil if Wikipedia has no LicenseShortName.
        let license: String?

        var creditText: String {
            switch (artist, license) {
            case let (artist?, license?): return "\(artist) · \(license)"
            case let (artist?, nil): return "\(artist) · Wikipedia"
            case let (nil, license?): return "Wikipedia · \(license)"
            case (nil, nil): return "Wikipedia"
            }
        }
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.httpAdditionalHeaders = [
            "User-Agent": "OpenBat/1.0 (https://github.com/search?q=OpenBat+bat+detector; open-source, non-commercial iOS app)"
        ]
        return URLSession(configuration: cfg)
    }()

    /// sciName -> resolved photo, or `.some(nil)` for "checked, no usable
    /// photo found" (distinct from "not yet checked", which has no entry at
    /// all) so a species with no Wikipedia photo isn't re-queried every time
    /// its row scrolls back on screen. Backed by disk (see `cacheURL`) so this
    /// survives app relaunches — same on-disk convention as `SpeciesGuideStore`,
    /// rather than a session-only lookup.
    private static var cache: [String: Photo?] = loadCache()

    /// Guards `cache`'s read-modify-write in `fetchImageURL` — several species
    /// cards can resolve concurrently (each a separate SwiftUI `.task`), and an
    /// unguarded mutation of the same dictionary from multiple threads is
    /// undefined behavior, not just a lost update.
    private static let cacheLock = NSLock()

    private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WikipediaImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.json")
    }()

    private static func loadCache() -> [String: Photo?] {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: Photo?].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func saveCache() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private struct WikiMediaList: Decodable { let items: [WikiMediaItem] }
    private struct WikiMediaItem: Decodable { let title: String; let type: String }

    private struct WikiImageInfo: Decodable { let query: WikiImageQuery? }
    private struct WikiImageQuery: Decodable { let pages: [String: WikiImagePage] }
    private struct WikiImagePage: Decodable { let imageinfo: [WikiImageDetail]? }
    private struct WikiImageDetail: Decodable {
        let url: String
        let width: Int
        let height: Int
        let thumburl: String?
        let extmetadata: WikiExtMetadata?
    }
    private struct WikiExtMetadata: Decodable {
        let Artist: WikiMetaValue?
        let LicenseShortName: WikiMetaValue?
    }
    private struct WikiMetaValue: Decodable { let value: String }

    private struct Candidate { let url: URL; let width: Int; let height: Int; let artist: String?; let license: String? }

    /// Wikipedia's Artist field is free-form HTML (often a linked username) —
    /// strip tags and decode the handful of entities MediaWiki actually emits
    /// here rather than pulling in a full HTML parser for one field.
    private static func plainText(fromHTML html: String) -> String? {
        let noTags = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let decoded = noTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    /// Words that show up in Wikipedia taxobox furniture (range maps, flags,
    /// logos) rather than an actual photo of the animal — filtered out before
    /// even asking for their image info.
    private static let bannedTitleWords = ["logo", "icon", "flag", "map", "range", "distribution"]

    /// Every photo URL resolved on a previous run, for `SpeciesGuideStore`'s
    /// cache warming. Reading these costs no network call, which is the whole
    /// point: a preload that had to resolve names first would fire a burst of
    /// Wikipedia API requests at launch for species nobody has opened.
    static var cachedPhotoURLs: [URL] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache.values.compactMap { $0?.url }
    }

    /// Resolves a scientific name to a photo URL only (an 800px-wide thumbnail
    /// when Wikipedia generated one, else the original) — for thumbnail-only
    /// call sites (`GuideSpeciesThumbnail`) that don't display a credit.
    static func fetchImageURL(for scientificName: String) async -> URL? {
        await fetchPhoto(for: scientificName)?.url
    }

    /// Resolves a scientific name to a photo + its per-image attribution, or
    /// nil if the species has no Wikipedia article, no acceptable image, or
    /// the request failed. Cached to disk — callers don't need to debounce,
    /// and a repeat visit across app launches makes no network request at all.
    static func fetchPhoto(for scientificName: String) async -> Photo? {
        cacheLock.lock()
        let cached = cache[scientificName]
        cacheLock.unlock()
        if let cached { return cached }

        let result = await reallyFetch(scientificName)

        cacheLock.lock()
        cache[scientificName] = result
        saveCache()
        cacheLock.unlock()
        return result
    }

    private static func reallyFetch(_ scientificName: String) async -> Photo? {
        let title = scientificName
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
        guard let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let mediaListURL = URL(string: "https://en.wikipedia.org/api/rest_v1/page/media-list/\(encodedTitle)")
        else { return nil }

        do {
            let (data, response) = try await session.data(from: mediaListURL)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
            let mediaList = try JSONDecoder().decode(WikiMediaList.self, from: data)

            let imageTitles = mediaList.items
                .filter { $0.type == "image" }
                .map(\.title)
                .filter { candidateTitle in
                    let lower = candidateTitle.lowercased()
                    guard lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png")
                    else { return false }
                    return !bannedTitleWords.contains { lower.contains($0) }
                }
                .prefix(6)
            guard !imageTitles.isEmpty else { return nil }

            var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
            components.queryItems = [
                URLQueryItem(name: "action", value: "query"),
                URLQueryItem(name: "titles", value: imageTitles.joined(separator: "|")),
                URLQueryItem(name: "prop", value: "imageinfo"),
                URLQueryItem(name: "iiprop", value: "url|size|extmetadata"),
                URLQueryItem(name: "iiurlwidth", value: "800"),
                URLQueryItem(name: "format", value: "json"),
            ]
            guard let infoURL = components.url else { return nil }

            let (infoData, _) = try await session.data(from: infoURL)
            let info = try JSONDecoder().decode(WikiImageInfo.self, from: infoData)
            let candidates: [Candidate] = (info.query?.pages.values ?? Dictionary<String, WikiImagePage>().values)
                .compactMap { page in
                    guard let detail = page.imageinfo?.first,
                          let url = URL(string: detail.thumburl ?? detail.url)
                    else { return nil }
                    return Candidate(
                        url: url, width: detail.width, height: detail.height,
                        artist: detail.extmetadata?.Artist.flatMap { plainText(fromHTML: $0.value) },
                        license: detail.extmetadata?.LicenseShortName?.value
                    )
                }

            // Prefer a landscape photo (reads better in a wide hero/thumbnail
            // slot); fall back to the widest available if none are landscape.
            guard let chosen = candidates.first(where: { $0.width > $0.height }) ?? candidates.max(by: { $0.width < $1.width })
            else { return nil }
            return Photo(url: chosen.url, artist: chosen.artist, license: chosen.license)
        } catch {
            return nil
        }
    }
}
