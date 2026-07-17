//
//  ClassificationStore.swift
//  OpenBat
//
//  Persistent record of AutoID "passes" (a run of pulses between silence gaps),
//  surfaced in the Sessions tab. Each pass keeps its contributing pulses with
//  their per-pulse species, confidence and a spectrogram thumbnail, so a tap can
//  reveal exactly what the aggregated ID was built from.
//
//  Records (metadata) persist as JSON; thumbnails as JPEGs under
//  Documents/Classifications/. The list is capped at `maxPasses`; pruned passes
//  have their thumbnails deleted too.
//

import UIKit
import Observation
import CoreLocation

// MARK: - Persisted records

/// One breadcrumb on a session's GPS course.
struct TrackPoint: Codable {
    let lat: Double
    let lon: Double
    let t: Date
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

/// A field outing: a dated, located container that owns its passes (linked by
/// `sessionID`) and a recorded GPS course. "Just Listening" passes have a nil
/// `sessionID` and live in the Listening bucket instead of a session.
struct RecordingSession: Codable, Identifiable {
    let id: UUID
    var title: String            // "29 Jun 2026 · Mendip Hills" — place filled in async
    var notes: String
    let startDate: Date
    var endDate: Date?
    var track: [TrackPoint]
}

struct ScoreEntry: Codable, Identifiable {
    let species: String
    let score: Float
    var id: String { species }
}

struct PulseRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let species: String
    let confidence: Float        // renormalized posterior of the winning species
    let peakFreqHz: Double
    let durationMs: Double
    let topScores: [ScoreEntry]  // strongest species, descending
    var imageFile: String?       // thumbnail filename under the images dir
    // Bounds of the stored thumbnail's crop (call band + a few ms either side),
    // used to draw labelled axes on it. Optional: records saved before the
    // renderer produced clean crops decode as nil and show the bare image.
    var imageFreqMinHz: Double?
    var imageFreqMaxHz: Double?
    var imageSpanMs: Double?
}

struct PassRecord: Codable, Identifiable {
    let id: UUID
    let date: Date               // when the pass closed
    let species: String
    let commonName: String
    let confidence: Float        // mean posterior of the winner across pulses
    let pulseCount: Int          // pulses that contributed to the ID
    let pulses: [PulseRecord]
    var sessionID: UUID?         // owning session; nil = Listening bucket
    var latitude: Double?        // where the pass was heard (session passes only)
    var longitude: Double?
    /// Second-place species (by mean posterior) across the pass's pulses, and its
    /// confidence — nil for old records decoded before this field existed, or a
    /// pass with only one candidate species. Optional `Codable` properties decode
    /// as nil for pre-existing persisted JSON, so no migration is needed.
    var runnerUpSpecies: String?
    var runnerUpConfidence: Float?
    /// The acoustic complex the winning species belongs to, if the classifying model
    /// admits one (see `SpeciesComplex`). Persisted as the complex's stable id and
    /// resolved back to its name/note/members via `ModelRegistry.complex(id:)` at
    /// display time. nil for a clean, non-confusable ID (or an old record). Optional
    /// `Codable`, so pre-existing JSON decodes as nil — no migration.
    var complexID: String?
    /// True when this ID is an *active* ambiguity: the runner-up is a complex-mate of
    /// the winner and its confidence is within `SpeciesComplex.ambiguityMargin`. A
    /// pass can be in a complex (`complexID != nil`) without being ambiguous — the
    /// species is confusable in general, but nothing close ran second this time.
    var complexAmbiguous: Bool?
    /// The resolved complex, or nil for a clean ID.
    var complex: SpeciesComplex? { ModelRegistry.complex(id: complexID) }
    /// Whether to phrase the caveat as an active "could also be…" vs an ambient note.
    var isComplexAmbiguous: Bool { complexAmbiguous ?? false }
    /// Representative thumbnail (the highest-confidence pulse's image).
    var thumbnailFile: String? { pulses.max(by: { $0.confidence < $1.confidence })?.imageFile }
    /// Map coordinate, when one was captured.
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return .init(latitude: latitude, longitude: longitude)
    }
    /// True when this pass's winning class is the model's noise class rather than an
    /// actual bat call — see `PassAggregation`. Still worth surfacing in the species
    /// list (so the user can see "we heard something, it wasn't a bat"), but excluded
    /// from the session map (see `AutoIDSettings.isMappable`).
    var isNoise: Bool { species == "NOISE" }
}

// MARK: - Transient capture (handed to the store before persistence)

/// One classified pulse, still holding its in-memory image. The store writes the
/// thumbnail and converts this into a `PulseRecord`.
struct CapturedPulse {
    let date: Date
    let species: String
    let confidence: Float
    let peakFreqHz: Double
    let durationMs: Double
    let topScores: [ScoreEntry]
    let image: UIImage?
    // Crop bounds of `image` (see PulseRecord.imageFreqMinHz &c.).
    var imageFreqMinHz: Double? = nil
    var imageFreqMaxHz: Double? = nil
    var imageSpanMs: Double? = nil
}

// MARK: - Store

@Observable
final class ClassificationStore {

    private(set) var passes: [PassRecord] = []      // newest first
    private(set) var sessions: [RecordingSession] = []   // newest first
    /// The in-progress session (set while a "New Session" run is detecting).
    private(set) var activeSessionID: UUID?

    private let maxPasses = 500
    private let thumbMaxWidth: CGFloat = 360

    private let dir: URL
    private let imagesDir: URL
    private let jsonURL: URL
    private let sessionsURL: URL
    private let io = DispatchQueue(label: "bat.ClassificationStore.io", qos: .utility)
    /// Throttle full sessions.json rewrites while a track streams in points.
    private var lastSessionPersist: Date = .distantPast

    // Small in-memory cache so scrolling the list doesn't re-decode JPEGs.
    private var imageCache = NSCache<NSString, UIImage>()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir         = docs.appendingPathComponent("Classifications", isDirectory: true)
        imagesDir   = dir.appendingPathComponent("images", isDirectory: true)
        jsonURL     = dir.appendingPathComponent("passes.json")
        sessionsURL = dir.appendingPathComponent("sessions.json")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: Sessions

    /// Begin a new outing and mark it active. New passes attach to it until `endSession`.
    @discardableResult
    func startSession(startDate: Date = Date()) -> UUID {
        let session = RecordingSession(id: UUID(), title: Self.defaultTitle(startDate),
                                       notes: "", startDate: startDate, endDate: nil, track: [])
        sessions.insert(session, at: 0)
        activeSessionID = session.id
        persistSessions()
        return session.id
    }

    /// Close the active outing (stamps its end time).
    func endSession() {
        if let id = activeSessionID, let i = sessions.firstIndex(where: { $0.id == id }) {
            sessions[i].endDate = Date()
        }
        activeSessionID = nil
        persistSessions(force: true)
    }

    func setTitle(_ title: String, for id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].title = title
        persistSessions(force: true)
    }

    func setNotes(_ notes: String, for id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].notes = notes
        persistSessions(force: true)
    }

    /// Fold a reverse-geocoded place name into the title, keeping the start timestamp.
    func setPlaceName(_ name: String, for id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].title = "\(Self.defaultTitle(sessions[i].startDate)) · \(name)"
        persistSessions(force: true)
    }

    /// Append a GPS breadcrumb to the active session (called by LocationProvider).
    func appendTrackPoint(_ point: TrackPoint) {
        guard let id = activeSessionID, let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].track.append(point)
        persistSessions()
    }

    func passes(inSession id: UUID) -> [PassRecord] { passes.filter { $0.sessionID == id } }
    var listeningPasses: [PassRecord] { passes.filter { $0.sessionID == nil } }

    /// Merlin-style "recently detected" stack: one row per species, most-recently-
    /// heard pass on top. `passes` is already newest-first (inserted at index 0),
    /// so keeping the first occurrence of each species per source scope is enough —
    /// no separate ordering state to maintain, and a re-detection naturally bumps
    /// its species back to the top the next time this is read.
    ///
    /// `since` scopes the feed to the current run: a "New Session" already gets a
    /// fresh `sessionID` per run, but "Just Listening" passes all share a nil
    /// `sessionID` across every run ever recorded, so without a `since` floor the
    /// feed would resurrect species from long-past outings. `since == nil` means
    /// no run is active — the feed reads blank until one starts.
    func speciesFeed(sessionID: UUID?, since: Date?) -> [PassRecord] {
        guard let since else { return [] }
        let source = (sessionID.map(passes(inSession:)) ?? listeningPasses)
            .filter { $0.date >= since }
        var seen = Set<String>()
        return source.filter { seen.insert($0.species).inserted }
    }

    func deleteSession(_ session: RecordingSession) {
        if activeSessionID == session.id { activeSessionID = nil }
        sessions.removeAll { $0.id == session.id }
        for pass in passes(inSession: session.id) { delete(pass) }   // removes images too
        persistSessions(force: true)
    }

    private static func defaultTitle(_ date: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: Add

    /// Build a `PassRecord` from a finished pass and persist it. Safe to call from
    /// the main thread; thumbnail encoding + disk writes happen off-thread.
    func addPass(species: String,
                 confidence: Float,
                 pulses: [CapturedPulse],
                 sessionID: UUID? = nil,
                 coordinate: CLLocationCoordinate2D? = nil,
                 date: Date = Date(),
                 runnerUpSpecies: String? = nil,
                 runnerUpConfidence: Float? = nil,
                 complexID: String? = nil,
                 complexAmbiguous: Bool? = nil) {
        guard !pulses.isEmpty else { return }
        let passID = UUID()

        io.async { [weak self] in
            guard let self else { return }
            var records: [PulseRecord] = []
            records.reserveCapacity(pulses.count)
            for p in pulses {
                var file: String?
                if let img = p.image, let data = self.thumbnailJPEG(img) {
                    let name = "\(passID.uuidString)_\(records.count).jpg"
                    try? data.write(to: self.imagesDir.appendingPathComponent(name))
                    file = name
                }
                records.append(PulseRecord(id: UUID(), date: p.date, species: p.species,
                                           confidence: p.confidence, peakFreqHz: p.peakFreqHz,
                                           durationMs: p.durationMs, topScores: p.topScores,
                                           imageFile: file,
                                           imageFreqMinHz: p.imageFreqMinHz,
                                           imageFreqMaxHz: p.imageFreqMaxHz,
                                           imageSpanMs: p.imageSpanMs))
            }
            let pass = PassRecord(id: passID, date: date, species: species,
                                  commonName: SpeciesInfo.commonName[species] ?? species,
                                  confidence: confidence, pulseCount: pulses.count,
                                  pulses: records, sessionID: sessionID,
                                  latitude: coordinate?.latitude, longitude: coordinate?.longitude,
                                  runnerUpSpecies: runnerUpSpecies, runnerUpConfidence: runnerUpConfidence,
                                  complexID: complexID, complexAmbiguous: complexAmbiguous)

            DispatchQueue.main.async {
                self.passes.insert(pass, at: 0)
                self.prune()
                self.persist()
            }
        }
    }

    // MARK: Delete

    func delete(_ pass: PassRecord) {
        passes.removeAll { $0.id == pass.id }
        io.async { [weak self] in
            guard let self else { return }
            for p in pass.pulses where p.imageFile != nil {
                try? FileManager.default.removeItem(at: self.imagesDir.appendingPathComponent(p.imageFile!))
            }
        }
        persist()
    }

    func clearAll() {
        passes.removeAll()
        imageCache.removeAllObjects()
        io.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.imagesDir)
            try? FileManager.default.createDirectory(at: self.imagesDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: self.jsonURL)
        }
    }

    /// Clear only the Listening bucket (passes not owned by a session).
    func clearListening() {
        for pass in listeningPasses { delete(pass) }
    }

    // MARK: Image loading

    func image(for record: PulseRecord) -> UIImage? {
        guard let file = record.imageFile else { return nil }
        if let cached = imageCache.object(forKey: file as NSString) { return cached }
        guard let img = UIImage(contentsOfFile: imagesDir.appendingPathComponent(file).path)
        else { return nil }
        imageCache.setObject(img, forKey: file as NSString)
        return img
    }

    // MARK: Private

    private func prune() {
        guard passes.count > maxPasses else { return }
        let removed = passes[maxPasses...]
        for pass in removed {
            for p in pass.pulses where p.imageFile != nil {
                let name = p.imageFile!
                io.async { [weak self] in
                    guard let self else { return }
                    try? FileManager.default.removeItem(at: self.imagesDir.appendingPathComponent(name))
                }
            }
        }
        passes.removeLast(passes.count - maxPasses)
    }

    private func thumbnailJPEG(_ image: UIImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, thumbMaxWidth / size.width)
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return scaled.jpegData(compressionQuality: 0.7)
    }

    private func persist() {
        let snapshot = passes
        io.async { [weak self] in
            guard let self else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: self.jsonURL)
            }
        }
    }

    /// Persist sessions, throttled so a streaming GPS track doesn't rewrite on every
    /// breadcrumb. `force` bypasses the throttle (session start/end, edits, deletes).
    private func persistSessions(force: Bool = false) {
        if !force, Date().timeIntervalSince(lastSessionPersist) < 5 { return }
        lastSessionPersist = Date()
        let snapshot = sessions
        io.async { [weak self] in
            guard let self else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: self.sessionsURL)
            }
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: jsonURL),
           let decoded = try? JSONDecoder().decode([PassRecord].self, from: data) {
            passes = decoded
        }
        if let data = try? Data(contentsOf: sessionsURL),
           let decoded = try? JSONDecoder().decode([RecordingSession].self, from: data) {
            sessions = decoded
        }
    }
}

// MARK: - Species names (shared)

enum SpeciesInfo {
    static let commonName: [String: String] = [
        "ANPA": "Pallid Bat",
        "COTO": "Townsend's Big-eared Bat",
        "EPFU": "Big Brown Bat",
        "EUMA": "Spotted Bat",
        "EUPE": "Western Mastiff Bat",
        "IDPH": "Allen's Big-eared Bat",
        "LABL": "Western Red Bat",
        "LABO": "Eastern Red Bat",
        "LACI": "Hoary Bat",
        "LAIN": "Northern Yellow Bat",
        "LANO": "Silver-haired Bat",
        "LASE": "Seminole Bat",
        "MYAU": "Southeastern Myotis",
        "MYCA": "California Myotis",
        "MYCI": "W. Small-footed Myotis",
        "MYEV": "Long-eared Myotis",
        "MYGR": "Gray Myotis",
        "MYLE": "E. Small-footed Myotis",
        "MYLU": "Little Brown Bat",
        "MYSE": "N. Long-eared Myotis",
        "MYSO": "Indiana Bat",
        "MYTH": "Fringed Myotis",
        "MYVE": "Cave Myotis",
        "MYVO": "Long-legged Myotis",
        "MYYU": "Yuma Myotis",
        "NOISE": "Non-bat noise",
        "NYHU": "Evening Bat",
        "NYMA": "Big Free-tailed Bat",
        "PAHE": "Canyon Bat",
        "PESU": "Tri-colored Bat",
        "TABR": "Brazilian Free-tailed Bat",
    ]
}
