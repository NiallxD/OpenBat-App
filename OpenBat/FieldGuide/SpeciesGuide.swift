//
//  SpeciesGuide.swift
//  OpenBat
//
//  Data model for the Species field guide. The guide is a single JSON document
//  (see SpeciesGuideData.json) designed to be community-editable on GitHub:
//  add a species / region, bump `dataVersion`, open a PR. The app ships a
//  prebaked copy in the bundle and overlays newer versions downloaded at
//  launch (SpeciesGuideStore).
//

import Foundation
import CoreLocation

/// Top-level guide document. `dataVersion` is a monotonically increasing
/// integer bumped on every content change — it's how the app decides whether
/// a downloaded (or newly bundled) copy supersedes the cached one. Keeping it
/// an explicit field (rather than relying on HTTP ETags) makes updates
/// host-agnostic and diff-reviewable in PRs.
struct SpeciesGuide: Codable {
    /// Bump when the JSON *schema* changes incompatibly; the app refuses
    /// documents with a schema it doesn't understand rather than mis-decoding.
    var schemaVersion: Int
    /// Bump on every content edit (new species, corrected text, …).
    var dataVersion: Int
    /// ISO 8601 date string set alongside each `dataVersion` bump — optional so
    /// older cached/bundled copies (and hand-edited PRs that forget it) still
    /// decode. Shown in the explorer footer so users can see how stale the
    /// guide content is, distinct from the on-device download date.
    var updatedAt: String?
    var regions: [GuideRegion]
    var species: [GuideSpecies]

    static let supportedSchemaVersion = 1

    static let empty = SpeciesGuide(schemaVersion: supportedSchemaVersion,
                                    dataVersion: 0, updatedAt: nil, regions: [], species: [])

    /// `ISO8601DateFormatter()`'s default format options require a full
    /// date-time (`withInternetDateTime`) — a date-only string like
    /// "2026-07-21" (the natural thing to hand-type in a PR editing
    /// `contributors`/`updatedAt`) silently fails to parse against it. Falls
    /// back to a date-only parse before giving up.
    private static let fullDateTimeFormatter = ISO8601DateFormatter()
    private static let dateOnlyFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    static func parseISO8601(_ string: String) -> Date? {
        fullDateTimeFormatter.date(from: string) ?? dateOnlyFormatter.date(from: string)
    }

    /// Parsed `updatedAt`, if present and well-formed.
    var updatedDate: Date? {
        updatedAt.flatMap(Self.parseISO8601)
    }

    func species(in region: GuideRegion) -> [GuideSpecies] {
        species.filter { $0.regions.contains(region.id) }
            .sorted { $0.commonName < $1.commonName }
    }
}

/// A geographic region on the explorer globe. `latitude`/`longitude` place the
/// label/fallback pin; species reference regions by `id`.
///
/// `boundary`, when present, draws the region as a filled/stroked outline
/// instead of a pin — a GeoJSON-style MultiPolygon: an array of polygons
/// (for regions split across landmasses, e.g. islands), each polygon an
/// array of `[longitude, latitude]` pairs for its exterior ring (GeoJSON's
/// coordinate order — no interior-ring/hole support, which coarse regional
/// outlines don't need). Regions without a `boundary` fall back to the pin
/// so the guide JSON can be migrated one region at a time.
struct GuideRegion: Codable, Identifiable, Hashable {
    var id: String             // stable slug, e.g. "uk-ireland"
    var name: String           // display name, e.g. "UK & Ireland"
    var latitude: Double
    var longitude: Double
    var boundary: [[[Double]]]?

    var coordinate: CLLocationCoordinate2D {
        .init(latitude: latitude, longitude: longitude)
    }

    /// `boundary` decoded into map-ready coordinate rings; empty if absent
    /// or malformed (rings need at least 3 points).
    var polygons: [[CLLocationCoordinate2D]] {
        guard let boundary else { return [] }
        return boundary
            .map { ring in ring.compactMap { pair -> CLLocationCoordinate2D? in
                guard pair.count == 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
            } }
            .filter { $0.count >= 3 }
    }
}

/// Common names for the bat families the guide groups species under.
///
/// The collection pages group by `GuideSpecies.family`, and a heading that says
/// "Vespertilionidae" tells a beginner nothing — the name they can actually use
/// is "Vesper bats", with the Latin kept beside it for anyone who wants it
/// (Niall, 2026-09-02). Held here rather than in the guide JSON because it is a
/// property of the family, not of any one species: a per-species field would let
/// two members of the same family disagree about what their family is called.
///
/// Every extant chiropteran family, so a new contributor entry lands with a
/// heading already written. Anything unrecognised — a family added by a future
/// taxonomy, or the app's "Other" bucket — falls back to the name as given
/// rather than to a wrong guess.
enum GuideFamily {

    static func commonName(for family: String) -> String? { names[family] }

    /// Niall's list (2026-09-02), one name each: where he gave two ("Vesper bats
    /// / evening bats") the first is the heading and the second is here, because
    /// a heading is not the place to teach synonyms.
    ///
    /// Cistugidae and Rhinonycteridae are not on that list — both were split out
    /// of older families recently enough that plenty of sources still fold them
    /// in — but a species filed under either would otherwise show bare Latin, so
    /// they carry the names those splits are usually published under.
    private static let names: [String: String] = [
        "Pteropodidae":     "Flying foxes",           // also Old World fruit bats
        "Rhinolophidae":    "Horseshoe bats",
        "Hipposideridae":   "Old World leaf-nosed bats", // also roundleaf bats
        "Rhinopomatidae":   "Mouse-tailed bats",
        "Megadermatidae":   "False vampire bats",
        "Craseonycteridae": "Bumblebee bat",          // also Kitti's hog-nosed bat
        "Vespertilionidae": "Vesper bats",            // also evening bats
        "Molossidae":       "Free-tailed bats",       // also mastiff bats
        "Phyllostomidae":   "New World leaf-nosed bats",
        "Emballonuridae":   "Sheath-tailed bats",     // also sac-winged bats
        "Nycteridae":       "Slit-faced bats",
        "Mormoopidae":      "Mustached bats",         // also ghost-faced bats
        "Noctilionidae":    "Bulldog bats",           // also fishing bats
        "Miniopteridae":    "Bent-winged bats",       // also long-fingered bats
        "Natalidae":        "Funnel-eared bats",
        "Furipteridae":     "Smoky bats",             // also thumbless bats
        "Thyropteridae":    "Disk-winged bats",
        "Myzopodidae":      "Sucker-footed bats",
        "Mystacinidae":     "New Zealand short-tailed bats",
        "Rhinonycteridae":  "Trident bats",
        "Cistugidae":       "Wing-gland bats",
    ]
}

/// One species entry. Only identity + placement fields are load-bearing today;
/// the page-content fields are optional so the JSON can grow without breaking
/// older app builds (unknown keys are ignored by Codable anyway).
struct GuideSpecies: Codable, Identifiable, Hashable {
    var id: String            // stable slug, e.g. "pipistrellus-pipistrellus"
    var commonName: String
    var scientificName: String
    /// Common name of the broader group the species belongs to, shown
    /// verbatim above `commonName` on the species page — write the full
    /// display text a contributor wants shown, e.g. `"Vesper Bat"`,
    /// `"Horseshoe Bat"`, `"Flying Fox"`, `"Leaf-nosed Bat"`. Not derived or
    /// suffixed by the app, since not every group name takes "Bat" the same
    /// way ("Flying Fox" already reads as one without it).
    var group: String?
    /// Taxonomic order, e.g. "Chiroptera" — always the same for bats, but
    /// included for the breadcrumb. A stopgap until the full taxonomic-tree
    /// JSON (see Context.md §16) replaces this and
    /// `family`/`genus` with a proper lookup.
    var order: String?
    var family: String?
    var regions: [String]     // GuideRegion ids where present
    var summary: String?      // short intro blurb
    /// Direct URL to a photo of the species, set by a contributor. Preferred
    /// over the live Wikipedia lookup (`WikipediaSpeciesImageService`) that
    /// otherwise fills the hero photo — that lookup is unpredictable (wrong
    /// species, taxobox furniture instead of a real photo, no photo at all)
    /// and gives contributors nothing to point at when it picks a bad one, so
    /// this is a plain URL a contributor can choose and pin down themselves.
    /// Wikipedia fetch remains the fallback for any entry that hasn't set one.
    ///
    /// MUST link a Creative Commons–licensed (or public domain) image — see
    /// the field guide README's photo section before adding one.
    var imageURL: String?
    /// Attribution text shown over the photo, e.g.
    /// "Jane Doe, Wikimedia Commons, CC BY-SA 4.0" — required whenever
    /// `imageURL` is set; a CC license is a licence to use the image, not a
    /// waiver of the attribution it requires. Ignored (falls back to
    /// Wikipedia's own per-image credit) when `imageURL` is nil.
    var imageCredit: String?
    var measurements: SpeciesMeasurements?
    var morphology: SpeciesMorphology?
    var echolocation: SpeciesEcholocation?
    var conservation: SpeciesConservation?
    var habits: SpeciesHabits?
    var references: [String]?     // citations, rendered verbatim in small type at the foot of the page
    /// Edit history — first entry is the page's creator, the rest are
    /// editors, each with the date of their contribution. Shown via a sheet
    /// from the References section.
    var contributors: [SpeciesContributor]?

    /// Parsed from `scientificName` rather than stored — avoids redundant
    /// data entry until the real taxonomy JSON arrives.
    var genus: String {
        scientificName.split(separator: " ").first.map(String.init) ?? scientificName
    }

    var creator: SpeciesContributor? { contributors?.first }
    var editors: [SpeciesContributor] { contributors.map { Array($0.dropFirst()) } ?? [] }
}

/// One entry in a species page's edit history.
struct SpeciesContributor: Codable, Hashable {
    var name: String
    var date: String    // ISO 8601
    var note: String?   // e.g. "Added echolocation measurements"

    var parsedDate: Date? {
        SpeciesGuide.parseISO8601(date)
    }
}

/// A min/max pair — used for every physical/acoustic range field below.
/// Plain `ClosedRange<Double>` isn't `Codable`, so this stands in for it.
struct MeasurementRange: Codable, Hashable {
    var min: Double
    var max: Double
}

struct SpeciesMeasurements: Codable, Hashable {
    var forearmMmRange: MeasurementRange?
    var wingspanCmRange: MeasurementRange?
    var weightGRange: MeasurementRange?
    /// Free-text overall appearance description — shown ahead of the
    /// measurements table on the species page. Renamed from "color" (the
    /// original field name undersold it — entries describe general
    /// morphology, not just pelage); `init(from:)` below still accepts the
    /// old "color" key so already-cached/remote SpeciesGuideData.json keeps
    /// decoding until the GitHub-hosted copy is migrated to the new key.
    var morphologyDescription: String?

    private enum CodingKeys: String, CodingKey {
        case forearmMmRange, wingspanCmRange, weightGRange, morphologyDescription
        case legacyColor = "color"
    }

    init(forearmMmRange: MeasurementRange? = nil,
         wingspanCmRange: MeasurementRange? = nil,
         weightGRange: MeasurementRange? = nil,
         morphologyDescription: String? = nil) {
        self.forearmMmRange = forearmMmRange
        self.wingspanCmRange = wingspanCmRange
        self.weightGRange = weightGRange
        self.morphologyDescription = morphologyDescription
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        forearmMmRange = try c.decodeIfPresent(MeasurementRange.self, forKey: .forearmMmRange)
        wingspanCmRange = try c.decodeIfPresent(MeasurementRange.self, forKey: .wingspanCmRange)
        weightGRange = try c.decodeIfPresent(MeasurementRange.self, forKey: .weightGRange)
        morphologyDescription = try c.decodeIfPresent(String.self, forKey: .morphologyDescription)
            ?? c.decodeIfPresent(String.self, forKey: .legacyColor)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(forearmMmRange, forKey: .forearmMmRange)
        try c.encodeIfPresent(wingspanCmRange, forKey: .wingspanCmRange)
        try c.encodeIfPresent(weightGRange, forKey: .weightGRange)
        try c.encodeIfPresent(morphologyDescription, forKey: .morphologyDescription)
    }
}

/// Text descriptors for key identifying features. Illustrations/icons for
/// these are future work (see Context.md §16) — plain text for now.
struct SpeciesMorphology: Codable, Hashable {
    var earType: String?
    var tailType: String?
    var noseType: String?
    var otherFeatures: [String]?
}

struct SpeciesEcholocation: Codable, Hashable {
    var callType: String?    // e.g. "FM", "CF-FM", "FM-CF-FM"
    var peakFreqHzRange: MeasurementRange?           // "Pf"
    var characteristicFreqHzRange: MeasurementRange? // "Cf" / knee frequency
    var freqHighHzRange: MeasurementRange?           // "Fhigh"
    var freqLowHzRange: MeasurementRange?             // "Flow"
    var durationMsRange: MeasurementRange?
    var notes: String?
    var exemplarImageName: String?    // bundled asset name, e.g. an annotated spectrogram
}

struct SpeciesConservation: Codable, Hashable {
    var iucnStatus: String?    // e.g. "Least Concern", "Near Threatened"
    var localStatus: String?   // free text — varies per region/authority
}

struct SpeciesHabits: Codable, Hashable {
    var roosting: String?
    var migration: String?
    var feeding: String?
    var reproduction: String?
    var other: String?
}

// MARK: - Fuzzy search

extension GuideSpecies {
    /// Match score for the explorer search bar, higher is better; nil = no match.
    /// Tiers: exact prefix (300) > word prefix (200) > substring (100) >
    /// in-order subsequence (0), each minus a small length penalty so tighter
    /// matches rank first. Checked against both common and scientific names,
    /// diacritic- and case-insensitively.
    func searchScore(for query: String) -> Int? {
        [commonName, scientificName]
            .compactMap { Self.score(query: query, in: $0) }
            .max()
    }

    private static func score(query: String, in target: String) -> Int? {
        let q = query.folded, t = target.folded
        guard !q.isEmpty else { return nil }
        let lengthPenalty = t.count
        if t.hasPrefix(q) { return 300 - lengthPenalty }
        if t.split(separator: " ").contains(where: { $0.hasPrefix(q) }) {
            return 200 - lengthPenalty
        }
        if t.contains(q) { return 100 - lengthPenalty }
        // Subsequence: every query char appears in order ("pippip" hits
        // "Pipistrellus pipistrellus" despite the gap).
        var it = t.makeIterator()
        outer: for ch in q {
            while let c = it.next() { if c == ch { continue outer } }
            return nil
        }
        return 0 - lengthPenalty
    }
}

private extension String {
    /// Case/diacritic-insensitive normal form for matching.
    var folded: String { folding(options: [.caseInsensitive, .diacriticInsensitive],
                                 locale: .current) }
}
