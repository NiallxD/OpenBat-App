//
//  BlogStore.swift
//  OpenBat
//
//  Fetches and caches the app's blog feed. Two tiers rather than the guide's
//  three — there is no bundled copy, see `BlogFeed.swift` for why.
//
//    1. Cached  — the last good download, in Application Support.
//    2. Remote  — the website's build output, checked at most once a day.
//
//  The cached copy is authoritative until a strictly newer `dataVersion`
//  arrives, and every failure path leaves it exactly where it is. An empty feed
//  is a legitimate state, not an error: it is what a user sees before the first
//  fetch, offline on a fresh install, and if the feed is ever withdrawn.
//

import Foundation

@MainActor
@Observable
final class BlogStore {
    /// Built and deployed with the website. A 404 here is not a failure — it is
    /// "no posts yet", which is why the blog button can ship before the feed
    /// does. See `BlogFeedSpec.md`.
    static let remoteURL = URL(string: "https://openbat.app/app/blog.json")!

    private(set) var feed: BlogFeed = .empty
    private(set) var isRefreshing = false
    /// Swallowed rather than surfaced as an alert: there is nothing a reader can
    /// do about it and the cached posts are still there. The blog list shows it
    /// only when it has nothing else to show.
    private(set) var lastRefreshError: String?

    var posts: [BlogPost] { feed.orderedPosts }
    var isEmpty: Bool { feed.posts.isEmpty }

    func post(id: String) -> BlogPost? { feed.posts.first { $0.id == id } }

    nonisolated private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Blog", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("blog.json")
    }()

    /// One fetch per launch, like the guide store — not one per day, which is
    /// what this was.
    ///
    /// **A daily poll can strand a reader on a stale copy for a day**, and it did:
    /// a device that had fetched the old feed kept it, because the clock said it
    /// had checked recently and the check was the only thing that would have
    /// noticed the blog had been rewritten. Pull-to-refresh was the only way out,
    /// and only from the blog list — the globe's dial has no such gesture, so its
    /// categories would have stayed wrong with nothing to do about it.
    ///
    /// Once per launch is what the guide already does, and the cost is one
    /// conditional request against a 60 KB file that answers 304 when unchanged.
    private var hasRefreshedThisLaunch = false

    /// Cheap, for the same reason `SpeciesGuideStore.init` is: this is
    /// constructed inside a view-builder closure that re-evaluates, so any decode
    /// done here would run repeatedly on the main thread during view updates.
    init() {}

    /// Reads the cached feed off the main thread. Call once, from a `.task`.
    func loadCached() async {
        guard feed.posts.isEmpty else { return }
        if let cached = await Task.detached(priority: .utility, operation: {
            Self.decode(Self.readCache())
        }).value {
            feed = cached
        }
    }

    /// Fetches the feed once per launch, or unconditionally when `force`
    /// (pull-to-refresh).
    ///
    /// **Low Data Mode is honoured, but Wi-Fi is not required.** Niall's rule:
    /// no Wi-Fi-only gates — someone reading in a field on cellular is a normal
    /// case — but a user who has explicitly asked the system to economise gets a
    /// conditional request that usually returns `304`, and no fetch at all
    /// unless they asked for one.
    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        if !force, hasRefreshedThisLaunch { return }

        isRefreshing = true
        defer { isRefreshing = false }

        var request = URLRequest(url: Self.remoteURL)
        request.timeoutInterval = 20
        // On a constrained path (the user has Low Data Mode on) an automatic
        // background poll declines and the request fails fast with
        // `networkUnavailableReason == .constrained`; a deliberate pull-to-refresh
        // still goes through. The system owns the answer, so nothing here has to
        // detect the setting itself — which is just as well, since detecting it
        // needs a live path monitor running for something consulted once a launch.
        request.allowsConstrainedNetworkAccess = force
        // **Revalidate every time, never serve URLSession's own cached body.**
        // The feed is sent with `max-age=600`, and under the default policy that
        // means a launch within ten minutes of the last one gets the old bytes
        // without the server being asked at all — so a redeploy appears not to
        // have happened. This still costs almost nothing when nothing changed:
        // the request carries the ETag and the server answers 304 with no body.
        request.cachePolicy = .reloadRevalidatingCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 404 means the feed is not published. That is a valid answer, and
            // treating it as an error would put a red line under a blog that is
            // simply not there yet. Marked as checked so it does not retry on
            // every appearance of every screen that asks.
            if status == 404 {
                hasRefreshedThisLaunch = true
                lastRefreshError = nil
                return
            }
            guard (200...299).contains(status) || status == 304 else {
                lastRefreshError = "The blog feed returned \(status)."
                return
            }
            // 304, or any empty body: what is cached is current.
            guard !data.isEmpty, let incoming = Self.decode(data) else {
                hasRefreshedThisLaunch = true
                lastRefreshError = nil
                return
            }
            // **The server's copy wins, whatever its `dataVersion` says.**
            //
            // This was "strictly newer", copied from the guide store, and it is
            // wrong here. The guide has a bundled copy competing with a cached one
            // and needs a rule for which is fresher. The blog has exactly one
            // source, so there is nothing to arbitrate — and the rule actively bit:
            // republishing the whole blog with `dataVersion` reset from 2 to 1 left
            // every app that had already fetched showing the old four posts and
            // refusing the new fourteen, silently, with no way for a reader to
            // force it. A number going backwards is a normal thing to happen while
            // a site is being built.
            //
            // Comparing bytes rather than versions keeps the one property that rule
            // was actually buying: an unchanged feed does not churn the cache or
            // republish `feed`, so a check that finds nothing new costs nothing
            // downstream.
            if data != Self.readCache() || feed.posts.isEmpty {
                feed = incoming
                Self.writeCache(data)
            }
            hasRefreshedThisLaunch = true
            lastRefreshError = nil
        } catch is CancellationError {
            // A view went away mid-fetch. Not a failure worth reporting, and
            // deliberately not stamped, so the next appearance tries again.
        } catch let error as URLError where error.networkUnavailableReason == .constrained {
            // Low Data Mode declined an automatic poll. Working as intended, and
            // not stamped, so the next launch (or a pull-to-refresh) tries again.
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    // MARK: Plumbing

    nonisolated private static func readCache() -> Data? {
        try? Data(contentsOf: cacheURL)
    }

    nonisolated private static func writeCache(_ data: Data) {
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// A feed whose `schemaVersion` is beyond what this build understands is
    /// refused rather than half-decoded. The app then keeps showing the cached
    /// copy it already had, which is the honest outcome for an old app meeting a
    /// new website.
    nonisolated private static func decode(_ data: Data?) -> BlogFeed? {
        guard let data, let feed = try? JSONDecoder().decode(BlogFeed.self, from: data) else {
            return nil
        }
        guard feed.schemaVersion <= 1 else { return nil }
        return feed
    }
}
