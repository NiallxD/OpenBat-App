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
        "https://raw.githubusercontent.com/NiallxD/OpenBat-FieldGuide/main/SpeciesGuideData.json")!

    private(set) var guide: SpeciesGuide = .empty
    /// Where the current guide came from — surfaced in the explorer footer.
    private(set) var source: Source = .bundled
    private(set) var isRefreshing = false
    private(set) var lastRefreshError: String?

    enum Source: String {
        case bundled = "bundled"
        case cached = "downloaded"
    }

    nonisolated private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("SpeciesGuide", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("SpeciesGuideData.json")
    }()

    /// Cheap on purpose — this runs inline as `ContentView`'s `@State` default
    /// value, which is constructed inside `OpenBatApp`'s `WindowGroup` content
    /// closure and therefore re-evaluates every time that closure does, not just
    /// once. Doing the bundled+cached decode here (as this used to) put a
    /// synchronous ~328 KB `JSONDecoder` pass — twice — on the main thread as
    /// part of `ContentView.init()`, gating the very first frame the app could
    /// draw on it. See `loadLocal()`, called once from `ContentView`'s `.task`.
    init() {}

    /// Loads bundled + cached JSON off the main thread and adopts whichever has
    /// the higher `dataVersion`, then hands the result back to the main actor.
    /// Call once, e.g. from a `.task` alongside `refreshFromRemote()`.
    func loadLocal() async {
        guard let result = await Task.detached(priority: .userInitiated, operation: {
            Self.loadFromDisk()
        }).value else { return }
        guide = result.guide
        SpeciesInfo.adoptNames(from: guide)
        source = result.source
    }

    private struct LoadResult {
        let guide: SpeciesGuide
        let source: Source
    }

    /// Pure disk I/O + decode, `nonisolated` so it can run on `loadLocal()`'s
    /// detached task instead of blocking the main actor. Mirrors the merge
    /// logic `init()` used to run inline.
    nonisolated private static func loadFromDisk() -> LoadResult? {
        let bundledData = Self.bundledData()
        let bundled = bundledData.flatMap(Self.decode(data:))
        let cachedData = try? Data(contentsOf: Self.cacheURL)
        let cached = cachedData.flatMap(Self.decode(data:))
        // A cached file that fails to decode (corrupt, truncated, or an
        // unsupported future schema written by a since-reverted app version)
        // used to sit there forever, silently retried and re-failed on every
        // launch — self-heal by dropping it so a clean re-download can land.
        if cachedData != nil, cached == nil {
            try? FileManager.default.removeItem(at: Self.cacheURL)
        }

        if let cached, let bundled, cached.dataVersion == bundled.dataVersion {
            // Equal declared version — normally means "identical data", but a
            // bundled-JSON edit that forgot to bump dataVersion would tie here too
            // and then silently keep shadowing the new bundled content forever
            // (this exact bug happened once: boundary polygons were added to the
            // bundle without a version bump, and a stale same-version cache
            // shadowed them). A raw byte comparison catches that: only trust the
            // cache if it's actually byte-identical to what's bundled now.
            if cachedData == bundledData {
                return LoadResult(guide: cached, source: .cached)
            } else {
                try? FileManager.default.removeItem(at: Self.cacheURL)
                return LoadResult(guide: bundled, source: .bundled)
            }
        } else if let cached, cached.dataVersion > (bundled?.dataVersion ?? 0) {
            return LoadResult(guide: cached, source: .cached)
        } else if let bundled {
            // The bundle overtook the cache (app update) — the stale cache would
            // just lose the version comparison forever, so drop it.
            try? FileManager.default.removeItem(at: Self.cacheURL)
            return LoadResult(guide: bundled, source: .bundled)
        }
        return nil
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
            SpeciesInfo.adoptNames(from: guide)
            source = .cached
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    // MARK: Decoding helpers

    nonisolated private static func bundledData() -> Data? {
        guard let url = Bundle.main.url(forResource: "SpeciesGuideData",
                                        withExtension: "json") else {
            assertionFailure("SpeciesGuideData.json missing from bundle")
            return nil
        }
        return try? Data(contentsOf: url)
    }

    nonisolated private static func decode(data: Data) -> SpeciesGuide? {
        guard let guide = try? JSONDecoder().decode(SpeciesGuide.self, from: data),
              guide.schemaVersion <= SpeciesGuide.supportedSchemaVersion else { return nil }
        return guide
    }
}
