//
//  SpeciesGuideStore.swift
//  OpenBat
//
//  Loads the species field-guide JSON with a three-tier resolution so the
//  guide works offline and stays fresh:
//
//    1. Bundled  — SpeciesGuideData.json shipped inside the app (always present).
//    2. Cached   — the last successfully downloaded copy, in Application Support.
//    3. Remote   — raw JSON on GitHub, checked once per launch.
//
//  On init the store loads whichever of bundled/cached has the higher
//  `dataVersion` (an app update can ship a newer bundle than the cache).
//  `refreshFromRemote()` then fetches the GitHub copy and adopts + caches it
//  only if its dataVersion is strictly newer. Any network / decode failure is
//  swallowed into `lastRefreshError` — the in-memory guide is never degraded.
//

import Foundation

@MainActor
@Observable 
final class SpeciesGuideStore {
    /// Raw content URL (not the `github.com/.../blob/...` viewer page — that
    /// serves an HTML page, not JSON) tracking `main` so new commits are
    /// picked up on the next launch rather than pinning to one frozen SHA.
    static let remoteURL = URL(string:
        "https://raw.githubusercontent.com/NiallxD/OpenBat/main/SpeciesGuideData.json")!

    private(set) var guide: SpeciesGuide = .empty
    /// Where the current guide came from — surfaced in the explorer footer.
    private(set) var source: Source = .bundled
    private(set) var isRefreshing = false
    private(set) var lastRefreshError: String?

    enum Source: String {
        case bundled = "bundled"
        case cached = "downloaded"
    }

    private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("SpeciesGuide", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SpeciesGuideData.json")
    }()

    init() {
        let bundled = Self.loadBundled()
        let cached = Self.decode(from: Self.cacheURL)
        // Prefer whichever copy is newer; ties go to the cache (identical data).
        if let cached, cached.dataVersion >= (bundled?.dataVersion ?? 0) {
            guide = cached
            source = .cached
        } else if let bundled {
            guide = bundled
            source = .bundled
            // The bundle overtook the cache (app update) — the stale cache would
            // just lose the version comparison forever, so drop it.
            try? FileManager.default.removeItem(at: Self.cacheURL)
        }
    }

    /// Check GitHub for a newer guide; adopt and cache it if `dataVersion`
    /// advanced. Safe to call on every launch — offline or on failure the
    /// current guide stays untouched.
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
            let remote = try JSONDecoder().decode(SpeciesGuide.self, from: data)
            guard remote.schemaVersion <= SpeciesGuide.supportedSchemaVersion else {
                // Data repo moved ahead of this app build; keep what we have.
                lastRefreshError = "Guide update needs a newer app version."
                return
            }
            guard remote.dataVersion > guide.dataVersion else { return }
            try data.write(to: Self.cacheURL, options: .atomic)
            guide = remote
            source = .cached
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    // MARK: Decoding helpers

    private static func loadBundled() -> SpeciesGuide? {
        guard let url = Bundle.main.url(forResource: "SpeciesGuideData",
                                        withExtension: "json") else {
            assertionFailure("SpeciesGuideData.json missing from bundle")
            return nil
        }
        return decode(from: url)
    }

    private static func decode(from url: URL) -> SpeciesGuide? {
        guard let data = try? Data(contentsOf: url),
              let guide = try? JSONDecoder().decode(SpeciesGuide.self, from: data),
              guide.schemaVersion <= SpeciesGuide.supportedSchemaVersion else { return nil }
        return guide
    }
}
