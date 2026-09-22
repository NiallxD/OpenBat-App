//
//  BlogFeedTests.swift
//  OpenBatTests
//
//  The feed is a contract with a separate repository (`BlogFeedSpec.md`), and
//  the app is the half that cannot be fixed by a redeploy. These pin the parts
//  the website could change without noticing: the field names, the optional
//  ones, and how a post ranks against a species in the one search box they
//  share.
//

import Testing
import Foundation
@testable import OpenBat

struct BlogFeedTests {

    /// Exactly the shape `BlogFeedSpec.md` documents, optional fields included.
    private static let fullFeed = """
    {
      "schemaVersion": 1,
      "dataVersion": 7,
      "updatedAt": "2026-09-21T16:40:00Z",
      "posts": [
        {
          "id": "the-models-openbat-uses",
          "title": "The Models OpenBat Uses",
          "excerpt": "Two published classifiers rather than one of its own.",
          "date": "2026-09-05",
          "updated": "2026-09-20",
          "author": "Niall Bell",
          "tags": ["auto-id", "classifier"],
          "coverImage": "https://openbat.app/static/images/orange-sunset.webp",
          "url": "https://openbat.app/blog/the-models-openbat-uses/",
          "searchText": "The Models OpenBat Uses. OpenBat does not have an AI. It includes two published models, one of which knows the noctule well.",
          "readingMinutes": 6,
          "html": "<p>OpenBat does not have an AI.</p>"
        }
      ]
    }
    """

    /// Everything optional left out — the website is allowed to omit these and
    /// the app must not require them to decode the post at all.
    private static let minimalFeed = """
    {
      "schemaVersion": 1,
      "dataVersion": 1,
      "posts": [
        {
          "id": "why-openbat-has-a-blog",
          "title": "Why OpenBat Has a Blog",
          "excerpt": "Short one.",
          "date": "2026-08-27",
          "tags": [],
          "url": "https://openbat.app/blog/why-openbat-has-a-blog/",
          "searchText": "Why OpenBat Has a Blog. Short one.",
          "html": "<p>Short one.</p>"
        }
      ]
    }
    """

    private func decode(_ json: String) throws -> BlogFeed {
        try JSONDecoder().decode(BlogFeed.self, from: Data(json.utf8))
    }

    @Test func aFullPostDecodes() throws {
        let feed = try decode(Self.fullFeed)
        let post = try #require(feed.posts.first)
        #expect(feed.dataVersion == 7)
        #expect(post.id == "the-models-openbat-uses")
        #expect(post.readingMinutes == 6)
        #expect(post.coverImage?.host == "openbat.app")
        #expect(post.tags == ["auto-id", "classifier"])
    }

    /// The fields the spec marks optional have to be genuinely optional, or the
    /// first post Niall writes without a cover image disappears from the app
    /// with no error anywhere.
    @Test func aPostWithNoOptionalFieldsStillDecodes() throws {
        let feed = try decode(Self.minimalFeed)
        let post = try #require(feed.posts.first)
        #expect(post.coverImage == nil)
        #expect(post.readingMinutes == nil)
        #expect(post.author == nil)
        #expect(post.updated == nil)
    }

    /// A date the app cannot parse must render as itself rather than as a wrong
    /// date or a crash — it is a string from another repository.
    @Test func anUnparseableDateDegradesToItsOwnText() throws {
        let feed = try decode(Self.minimalFeed.replacingOccurrences(
            of: "2026-08-27", with: "last Tuesday"))
        let post = try #require(feed.posts.first)
        #expect(post.displayDate == "last Tuesday")
        #expect(post.sortDate == .distantPast)
    }

    // MARK: Search

    private func post(title: String, tags: [String] = [], body: String = "") -> BlogPost {
        BlogPost(id: title.lowercased(), title: title, excerpt: "", date: "2026-01-01",
                 updated: nil, author: nil, tags: tags, coverImage: nil,
                 url: URL(string: "https://openbat.app/")!,
                 searchText: "\(title). \(body)", readingMinutes: nil,
                 type: nil, location: nil, html: "")
    }

    @Test func aTitleMatchOutranksABodyMention() {
        let titled = post(title: "Choosing a Bat Microphone")
        let mentions = post(title: "The Gaps in Bat Data", body: "a microphone is mentioned here")
        let a = try? #require(titled.searchScore(for: "microphone"))
        let b = try? #require(mentions.searchScore(for: "microphone"))
        #expect((a ?? 0) > (b ?? 0))
    }

    /// The scores share a scale with `GuideSpecies`, and this is the case that
    /// matters: someone typing a bat's name wants the bat, even though several
    /// posts discuss it at length.
    @Test func aSpeciesOutranksAPostThatMerelyDiscussesIt() throws {
        // Decoded rather than constructed: `GuideSpecies` is a wide Codable type
        // and a test that spelled out every field would break on the next one
        // added, for no reason connected to what it is checking.
        let noctule = try #require(try? JSONDecoder().decode(GuideSpecies.self, from: Data("""
        {"id":"nyctalus-noctula","commonName":"Noctule",
         "scientificName":"Nyctalus noctula","regions":[]}
        """.utf8)))
        let speciesScore = try #require(noctule.searchScore(for: "noctule"))
        let article = try #require(
            post(title: "The Models OpenBat Uses", body: "knows the noctule well")
                .searchScore(for: "noctule"))
        #expect(speciesScore > article, "species \(speciesScore) vs post \(article)")
    }

    @Test func aTagMatchesButScoresBelowATitle() throws {
        let tagged = post(title: "How OpenBat Draws a Range Map", tags: ["classifier"])
        let titled = post(title: "Classifier Notes")
        let tag = try #require(tagged.searchScore(for: "classifier"))
        let title = try #require(titled.searchScore(for: "classifier"))
        #expect(title > tag)
    }

    @Test func nothingMatchesAnUnrelatedQuery() {
        #expect(post(title: "A Garden Bats Will Use").searchScore(for: "oscilloscope") == nil)
    }

    /// Accents and case are folded the same way the species search folds them,
    /// which is why `String.folded` is shared rather than duplicated.
    @Test func searchIgnoresCaseAndAccents() {
        #expect(post(title: "Réserve Notes").searchScore(for: "reserve") != nil)
        #expect(post(title: "Réserve Notes").searchScore(for: "RESERVE") != nil)
    }

    // MARK: Dial categories

    private func feed(categories: String?, posts: String) throws -> BlogFeed {
        let cats = categories.map { "\"categories\": \($0)," } ?? ""
        return try decode("""
        { "schemaVersion": 1, "dataVersion": 1, \(cats) "posts": \(posts) }
        """)
    }

    private static let twoPosts = """
    [{"id":"a","title":"A","excerpt":"","date":"2026-01-01","tags":[],
      "url":"https://openbat.app/a/","searchText":"A","html":"","type":"stories",
      "location":{"latitude":42.6,"longitude":-73.7,"name":"Albany"}},
     {"id":"b","title":"B","excerpt":"","date":"2026-01-02","tags":[],
      "url":"https://openbat.app/b/","searchText":"B","html":"","type":"research"}]
    """

    /// The declared order is the dial's order — not alphabetical, not the order
    /// posts happen to appear in. Getting this wrong would silently reshuffle a
    /// control the user is learning by position.
    @Test func declaredCategoriesKeepTheirOrder() throws {
        let f = try feed(categories: """
        [{"id":"locations","label":"Locations"},
         {"id":"stories","label":"Stories"},
         {"id":"research","label":"Research"}]
        """, posts: Self.twoPosts)
        #expect(f.categoryList.map(\.id) == ["locations", "stories", "research"])
    }

    /// A declared category with no posts keeps its detent. A dial whose positions
    /// appear and disappear with content cannot be learned.
    @Test func anEmptyDeclaredCategoryKeepsItsPosition() throws {
        let f = try feed(categories: """
        [{"id":"locations","label":"Locations"},{"id":"history","label":"History"}]
        """, posts: Self.twoPosts)
        #expect(f.categoryList.count == 2)
        #expect(f.posts(in: "history").isEmpty)
    }

    @Test func withNoDeclaredListTheTypesFoundAreUsed() throws {
        let f = try feed(categories: nil, posts: Self.twoPosts)
        #expect(f.categoryList.map(\.id) == ["research", "stories"])
    }

    /// Only posts that have somewhere to be go on the map. The other one is still
    /// in the category — it is readable from the blog list — but unpinned.
    @Test func onlyLocatedPostsArePinned() throws {
        let f = try feed(categories: nil, posts: Self.twoPosts)
        #expect(f.pinnedPosts(in: "stories").map(\.id) == ["a"])
        #expect(f.pinnedPosts(in: "research").isEmpty)
        #expect(f.posts(in: "research").count == 1)
    }

    @Test func aLocationDecodesToItsCoordinate() throws {
        let f = try feed(categories: nil, posts: Self.twoPosts)
        let located = try #require(f.pinnedPosts(in: "stories").first?.location)
        #expect(located.name == "Albany")
        #expect(abs(located.coordinate.latitude - 42.6) < 0.001)
    }

    /// A post with no `type` is not lost — it stays readable and searchable, it
    /// simply belongs to no dial position.
    @Test func aTypelessPostBelongsToNoCategory() throws {
        let f = try feed(categories: nil, posts: """
        [{"id":"c","title":"C","excerpt":"","date":"2026-01-01","tags":[],
          "url":"https://openbat.app/c/","searchText":"C","html":""}]
        """)
        #expect(f.categoryList.isEmpty)
        #expect(f.posts.count == 1)
        #expect(f.posts[0].searchScore(for: "C") != nil)
    }

    // MARK: The rendered document

    /// The reader runs no JavaScript, so a chart's canvas would be a blank box
    /// where a figure should be. Whichever way the website settles the charts
    /// question, the stylesheet has to hide the canvas and show the table.
    @Test func theDocumentHidesChartCanvasesAndShowsTheirTables() {
        let doc = BlogPostView.documentForTesting(fragment: "<p>hi</p>", dark: false)
        #expect(doc.contains("figure.chart canvas { display: none; }"))
        #expect(doc.contains("<p>hi</p>"))
    }

    @Test func theDocumentCarriesTheSchemeItWasAskedFor() {
        #expect(BlogPostView.documentForTesting(fragment: "", dark: true).contains("color-scheme: dark"))
        #expect(BlogPostView.documentForTesting(fragment: "", dark: false).contains("color-scheme: light"))
    }

    // MARK: The dial's rotation

    /// Six categories, so 60° apart. Species is 0 and Stories is 5.
    private static let step: Double = 60

    /// The bug Niall saw: turning a little anticlockwise from Species reaches
    /// Stories, the last of six. Its canonical angle is −300°, so snapping there
    /// from about +60° wound the ring a full turn forwards to arrive where it
    /// already was.
    @Test func snappingBackwardsToTheLastCategoryDoesNotWindForwards() {
        let settled = GlobeDial.nearestAngle(for: 5, to: 60, degreesPerStep: Self.step)
        #expect(settled == 60, "snapped to \(settled)°, having started at 60°")
        #expect(abs(settled - 60) < 180, "moved more than half a turn to settle")
    }

    /// And the ordinary case still lands on the plain angle.
    @Test func snappingForwardsLandsOnTheCategorysOwnAngle() {
        #expect(GlobeDial.nearestAngle(for: 1, to: -50, degreesPerStep: Self.step) == -60)
        #expect(GlobeDial.nearestAngle(for: 0, to: -10, degreesPerStep: Self.step) == 0)
    }

    /// Whatever the starting angle, settling never moves more than half a step —
    /// which is what "snap to the nearest detent" has to mean.
    @Test func snappingNeverMovesMoreThanHalfAStep() {
        for index in 0..<6 {
            for start in stride(from: -720.0, through: 720.0, by: 17) {
                let settled = GlobeDial.nearestAngle(for: index, to: start,
                                                     degreesPerStep: Self.step)
                // The nearest angle for a GIVEN index can be up to half a turn
                // away; what must hold is that it is the closest of its family.
                let base = -Self.step * Double(index)
                let offBy = (settled - base).truncatingRemainder(dividingBy: 360)
                #expect(abs(offBy) < 0.001, "index \(index) from \(start) settled off-detent")
                #expect(abs(settled - start) <= 180.001,
                        "index \(index) from \(start) wound \(settled - start)°")
            }
        }
    }
}
