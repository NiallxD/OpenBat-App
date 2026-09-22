//
//  BlogFeed.swift
//  OpenBat
//
//  The blog posts the website chooses to show in the app. Shape and field
//  meanings are specified in `BlogFeedSpec.md` at the repo root, which is the
//  contract the website build writes to — change one without the other and the
//  app quietly shows nothing.
//
//  Posts are NOT bundled. The species guide ships a copy inside the app because
//  a guide with no species is a broken screen; a blog with no posts is simply a
//  blog with no posts yet, and shipping a frozen copy of week-old writing in
//  every release buys nothing. So this is cache-or-empty, not bundle-or-cache.
//

import CoreLocation
import Foundation

/// Where a post's story happened. Optional on purpose — see `BlogPost.location`.
struct BlogLocation: Codable, Hashable {
    let latitude: Double
    let longitude: Double
    let name: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// One position on the globe's dial, as the website declares it.
///
/// The list is data rather than an enum for one reason: Niall expects to add
/// categories, and an enum would mean an App Store release per addition while
/// the website could already serve the posts. See `BlogFeedSpec.md`.
struct BlogCategory: Codable, Hashable, Identifiable {
    let id: String
    let label: String
}

/// One post as the feed carries it.
///
/// `Hashable` because it rides in `SpeciesGuideDestination`, which is a
/// navigation value. Equality is by `id` alone — the website may re-render a
/// post's HTML on any rebuild, and a value that changed identity every time the
/// body was re-rendered would push a duplicate screen.
struct BlogPost: Codable, Identifiable, Hashable {
    /// The website slug. Stable across edits — it is the cache key and the
    /// target of `openbat://post/…` links from inside other posts.
    let id: String
    let title: String
    let excerpt: String
    let date: String
    let updated: String?
    let author: String?
    let tags: [String]
    let coverImage: URL?
    /// The canonical page, for "open in Safari" and for sharing.
    let url: URL
    /// Title, excerpt and body as plain text — what the guide's search box
    /// actually matches against. Supplied by the build rather than stripped
    /// here: the app would have to parse HTML to do it, and the build already
    /// has the source.
    let searchText: String
    let readingMinutes: Int?
    /// The category this post sits in, matching a `BlogCategory.id`. A post whose
    /// type matches no declared category is still readable and searchable — it
    /// simply appears on no dial position.
    let type: String?
    /// Where the story happened, if it happened anywhere.
    ///
    /// **Absent is the normal case for an explainer**, and not a gap: a post about
    /// how a classifier works does not occur at a place, and pinning it somewhere
    /// would put a false claim on a map. Unpinned posts are reached from the blog
    /// list instead.
    let location: BlogLocation?
    /// Rendered body fragment. Never a whole document, never carrying script or
    /// style — see `BlogPostView`, which supplies the app's own stylesheet and
    /// refuses anything else.
    let html: String

    static func == (a: BlogPost, b: BlogPost) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Publication date for display. The feed carries `YYYY-MM-DD`; anything
    /// else renders as the raw string rather than as a wrong date.
    var displayDate: String {
        guard let d = Self.parser.date(from: date) else { return date }
        return Self.formatter.string(from: d)
    }

    /// Sort key. A post with an unparseable date sorts oldest rather than
    /// crashing or jumping to the top.
    var sortDate: Date { Self.parser.date(from: date) ?? .distantPast }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    /// How well this post matches a search query, or nil for no match.
    ///
    /// Deliberately the same scale as `GuideSpecies.searchScore` — the two sets
    /// of results are sorted together in one list, so a species and a post that
    /// match equally well have to produce comparable numbers. A title match
    /// scores like a species name match; a body match scores below every title.
    func searchScore(for query: String) -> Int? {
        let q = query.folded
        guard !q.isEmpty else { return nil }
        if let titleScore = Self.score(query: q, in: title.folded) { return titleScore }
        if tags.contains(where: { $0.folded.hasPrefix(q) }) { return 150 - title.count }
        // Body matches are a real hit but a weak one: a post that merely mentions
        // a word must never outrank the species that word names.
        if searchText.folded.contains(q) { return -100 - title.count }
        return nil
    }

    /// Prefix / word-prefix / substring, matching the species scorer's tiers.
    /// Subsequence matching is deliberately NOT offered here: it exists so
    /// "pippip" finds *Pipistrellus pipistrellus*, and over a few thousand words
    /// of prose it matches essentially everything.
    private static func score(query q: String, in t: String) -> Int? {
        let lengthPenalty = t.count
        if t.hasPrefix(q) { return 300 - lengthPenalty }
        if t.split(separator: " ").contains(where: { $0.hasPrefix(q) }) {
            return 200 - lengthPenalty
        }
        if t.contains(q) { return 100 - lengthPenalty }
        return nil
    }
}

/// The feed file itself. Envelope fields mirror `SpeciesGuideData.json` so the
/// two stores can behave identically about what counts as newer.
struct BlogFeed: Codable {
    let schemaVersion: Int
    let dataVersion: Int
    let updatedAt: String?
    let posts: [BlogPost]
    /// Dial positions, in the order the website wants them. See `categoryList`.
    let categories: [BlogCategory]?

    static let empty = BlogFeed(schemaVersion: 0, dataVersion: 0, updatedAt: nil,
                                posts: [], categories: nil)

    /// The categories to build dial positions from.
    ///
    /// A declared list is used exactly as written — including an empty category,
    /// which keeps its position rather than vanishing. **A dial whose detents come
    /// and go with the content is a dial nobody can learn**, and "the category I
    /// used yesterday has gone" is a worse failure than an empty one.
    ///
    /// With no declared list, the distinct types found across the posts are used,
    /// sorted so the order is at least stable between launches. That is a fallback
    /// for an older feed, not a design.
    var categoryList: [BlogCategory] {
        if let categories, !categories.isEmpty { return categories }
        let found = Set(posts.compactMap(\.type)).sorted()
        return found.map { BlogCategory(id: $0, label: $0.capitalized) }
    }

    /// Posts in a category that can actually be drawn on the globe.
    func pinnedPosts(in categoryID: String) -> [BlogPost] {
        posts.filter { $0.type == categoryID && $0.location != nil }
    }

    func posts(in categoryID: String) -> [BlogPost] {
        posts.filter { $0.type == categoryID }
    }

    /// The posts in the order the website chose — `appPriority` first, then
    /// newest, as the build decides.
    ///
    /// Deliberately not re-sorted here. The build knows which posts are pinned
    /// and the app does not (`appPriority` is not carried per-post, by design),
    /// so sorting by date app-side would silently discard an ordering that was
    /// chosen on purpose. `sortDate` exists for display and for the one case
    /// that needs it — picking the newest post — not for reordering the feed.
    var orderedPosts: [BlogPost] { posts }

    var newest: BlogPost? { posts.max { $0.sortDate < $1.sortDate } }
}
