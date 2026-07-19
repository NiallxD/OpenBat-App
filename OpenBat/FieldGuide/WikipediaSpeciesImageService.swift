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
//  Licensing: Wikipedia images are near-universally CC BY-SA or public domain,
//  but per-image attribution (photographer/exact license) isn't fetched here
//  — callers show a blanket "Photo: Wikipedia (CC BY-SA 4.0)" caption, same
//  as the companion app. If a specific image needs stricter per-photo credit,
//  add `extmetadata` to the `iiprop` request below.
//

import Foundation

enum WikipediaSpeciesImageService {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.httpAdditionalHeaders = [
            "User-Agent": "OpenBat/1.0 (https://github.com/search?q=OpenBat+bat+detector; open-source, non-commercial iOS app)"
        ]
        return URLSession(configuration: cfg)
    }()

    /// sciName -> resolved image URL, or `.some(nil)` for "checked, no usable
    /// photo found" (distinct from "not yet checked", which has no entry at
    /// all) so a species with no Wikipedia photo isn't re-queried every time
    /// its row scrolls back on screen. Backed by disk (see `cacheURL`) so this
    /// survives app relaunches — same on-disk convention as `SpeciesGuideStore`
    /// and `GBIFService`'s caches, rather than a session-only lookup.
    private static var cache: [String: URL?] = loadCache()

    private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WikipediaImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.json")
    }()

    private static func loadCache() -> [String: URL?] {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: String?].self, from: data)
        else { return [:] }
        return decoded.mapValues { $0.flatMap(URL.init(string:)) }
    }

    private static func saveCache() {
        let encoded = cache.mapValues { $0?.absoluteString }
        guard let data = try? JSONEncoder().encode(encoded) else { return }
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
    }

    private struct Candidate { let url: URL; let width: Int; let height: Int }

    /// Words that show up in Wikipedia taxobox furniture (range maps, flags,
    /// logos) rather than an actual photo of the animal — filtered out before
    /// even asking for their image info.
    private static let bannedTitleWords = ["logo", "icon", "flag", "map", "range", "distribution"]

    /// Resolves a scientific name to a photo URL (an 800px-wide thumbnail when
    /// Wikipedia generated one, else the original), or nil if the species has
    /// no Wikipedia article, no acceptable image, or the request failed. Cached
    /// to disk — callers don't need to debounce, and a repeat visit across app
    /// launches makes no network request at all.
    static func fetchImageURL(for scientificName: String) async -> URL? {
        if let cached = cache[scientificName] { return cached }
        let result = await reallyFetch(scientificName)
        cache[scientificName] = result
        saveCache()
        return result
    }

    private static func reallyFetch(_ scientificName: String) async -> URL? {
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
                URLQueryItem(name: "iiprop", value: "url|size"),
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
                    return Candidate(url: url, width: detail.width, height: detail.height)
                }

            // Prefer a landscape photo (reads better in a wide hero/thumbnail
            // slot); fall back to the widest available if none are landscape.
            return (candidates.first { $0.width > $0.height } ?? candidates.max { $0.width < $1.width })?.url
        } catch {
            return nil
        }
    }
}
