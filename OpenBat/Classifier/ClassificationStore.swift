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

struct PassRecord: Codable, Identifiable, NoIDFilterable {
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
    /// True when a pulse triggered the detector and was classified, but the pass's
    /// mean raw confidence never cleared the model's NoID threshold (or the winning
    /// species didn't clear the user's own confidence/pulse-count gates) — see
    /// `PassAggregation.aggregate`'s nil return, recorded by `PulseDetector.finalizePass()`
    /// instead of being silently dropped. Distinct from `isNoise`: NOISE is a
    /// confident "this wasn't a bat" call from the model, NOID is "not enough
    /// evidence either way".
    var isNoID: Bool { species == "NOID" }
}

/// Conformed by `PassRecord` and `Recording` so both can share the "hide NoID
/// unless the user's toggled it on" filter (`Array.filteredByNoID`) — the same
/// `display.showNoID` `@AppStorage` toggle gates both lists.
protocol NoIDFilterable {
    var isNoID: Bool { get }
}

extension Array where Element: NoIDFilterable {
    func filteredByNoID(showNoID: Bool) -> [Element] {
        showNoID ? self : filter { !$0.isNoID }
    }
}

/// One saved WAV file — the unit `AudioRecorder`'s bout-based trigger produces (see
/// CLAUDE.md's recording-subsystem notes): everything from the pre-roll before the
/// first pulse through the silence gap after the last one, in a single file. Distinct
/// from `PassRecord`, which is PulseDetector's own finer-grained "one run of pulses"
/// grouping — a single Recording can span several PassRecords (e.g. a bat making
/// more than one approach within the same bout). `commonName`/`species`/`confidence`
/// here are the recorder's own whole-file aggregate (same rule as `PassAggregation`,
/// computed independently over every pulse in the file — see AudioRecorder's
/// `speciesAutoID`), matching what's baked into the WAV's filename and GUANO tag.
struct Recording: Codable, Identifiable, NoIDFilterable {
    let id: UUID
    let date: Date                  // segment start (pre-roll included)
    let durationSeconds: Double
    let species: String             // never "NOISE" — those are rejected before saving
    let commonName: String
    let confidence: Float?          // nil for a NoID recording
    let pulseCount: Int
    var sessionID: UUID?            // nil = Listening bucket
    var latitude: Double?
    var longitude: Double?
    /// Path to the WAV, relative to the Documents directory — never store an absolute
    /// URL, since the app's container path can change between launches.
    let relativeWavPath: String
    /// Spectrogram JPEG filename under the store's images dir, nil if rendering failed.
    var spectrogramImageFile: String?
    /// nil means no upload was ever attempted (recorded before this field existed,
    /// or while community-science contribution was off) — see UploadStatus.swift.
    var uploadStatus: UploadStatus? = nil
    var isNoID: Bool { species == "NOID" }
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return .init(latitude: latitude, longitude: longitude)
    }
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
    private(set) var recordings: [Recording] = []   // newest first
    /// The in-progress session (set while a "New Session" run is detecting).
    private(set) var activeSessionID: UUID?

    private let maxPasses = 500
    private let thumbMaxWidth: CGFloat = 360

    private let dir: URL
    private let imagesDir: URL
    private let jsonURL: URL
    private let sessionsURL: URL
    private let recordingsURL: URL
    private let io = DispatchQueue(label: "bat.ClassificationStore.io", qos: .utility)
    /// Throttle full sessions.json rewrites while a track streams in points.
    private var lastSessionPersist: Date = .distantPast

    // Small in-memory cache so scrolling the list doesn't re-decode JPEGs.
    private var imageCache = NSCache<NSString, UIImage>()

    init() {
        let docs = CloudStorage.baseDirectory
        dir         = docs.appendingPathComponent("Classifications", isDirectory: true)
        imagesDir   = dir.appendingPathComponent("images", isDirectory: true)
        jsonURL     = dir.appendingPathComponent("passes.json")
        sessionsURL = dir.appendingPathComponent("sessions.json")
        recordingsURL = dir.appendingPathComponent("recordings.json")
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

    func recordings(inSession id: UUID) -> [Recording] { recordings.filter { $0.sessionID == id } }
    var listeningRecordings: [Recording] { recordings.filter { $0.sessionID == nil } }

    /// Every pass whose date falls inside `recording`'s time span — the per-pulse IDs
    /// display for a Recording's detail page, reusing `PassRecord`/`PulseRecord`
    /// (PulseDetector's own finer-grained grouping) rather than duplicating pulse
    /// data onto `Recording` itself. Scoped to the same session bucket so a Listening
    /// recording can't pick up a session pass that happens to share a timestamp.
    func passes(forRecording recording: Recording) -> [PassRecord] {
        let end = recording.date.addingTimeInterval(recording.durationSeconds)
        return passes.filter {
            $0.sessionID == recording.sessionID && $0.date >= recording.date && $0.date <= end
        }
    }

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
        for recording in recordings(inSession: session.id) { delete(recording) }   // removes WAVs too
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

    /// Record a finished, kept WAV segment (see `AudioRecorder.closeAndKeep`). Safe to
    /// call from any thread; the spectrogram JPEG write happens off-thread, matching
    /// `addPass`'s pattern. `onInserted` fires on the main actor once the Recording is
    /// actually in `recordings` — callers that need to act on this exact entry
    /// (RecordingUploader's `updateUploadStatus`) MUST wait for this rather than
    /// proceeding immediately after calling `addRecording`: this function returns
    /// before the (asynchronous, JPEG-write-gated) insert has happened, so anything
    /// that raced ahead of it would silently no-op against a not-yet-existing id.
    func addRecording(id: UUID = UUID(), date: Date, durationSeconds: Double,
                      species: String, confidence: Float?, pulseCount: Int,
                      sessionID: UUID?, coordinate: CLLocationCoordinate2D?,
                      relativeWavPath: String, spectrogramImage: UIImage?,
                      onInserted: (() -> Void)? = nil) {
        io.async { [weak self] in
            guard let self else { return }
            var file: String?
            if let img = spectrogramImage, let data = img.jpegData(compressionQuality: 0.8) {
                let name = "\(id.uuidString)_spectrogram.jpg"
                try? data.write(to: self.imagesDir.appendingPathComponent(name))
                file = name
            }
            let recording = Recording(id: id, date: date, durationSeconds: durationSeconds,
                                      species: species,
                                      commonName: SpeciesInfo.commonName[species] ?? species,
                                      confidence: confidence, pulseCount: pulseCount,
                                      sessionID: sessionID,
                                      latitude: coordinate?.latitude, longitude: coordinate?.longitude,
                                      relativeWavPath: relativeWavPath, spectrogramImageFile: file)
            DispatchQueue.main.async {
                self.recordings.insert(recording, at: 0)
                self.persistRecordings()
                onInserted?()
            }
        }
    }

    // MARK: Upload status

    /// Called by RecordingUploader at each phase of the convert→FLAC→upload
    /// pipeline, and by its retry sweep — see UploadStatus.swift. A no-op if
    /// the recording was deleted out from under an in-flight upload.
    func updateUploadStatus(recordingID: UUID, status: UploadStatus) {
        guard let index = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        var status = status
        // Carry the consecutive-failure tally here rather than in
        // RecordingUploader: this is the only place that can see the previous
        // value. Any phase that isn't `.failed` means a fresh attempt got
        // further than the last one did, so the count starts over — which is
        // also what re-enables automatic retries after a manual tap.
        status.failureCount = status.phase == .failed
            ? (recordings[index].uploadStatus?.failureCount ?? 0) + 1
            : 0
        recordings[index].uploadStatus = status
        persistRecordings()
    }

    /// Called only after a successful `ConsentStore.eraseAllData()` — every recording
    /// this device ever uploaded no longer exists server-side, so their local
    /// "Uploaded" status would otherwise keep showing stale entries in the upload
    /// queue forever. Resets every recording back to untouched (nil = not contributing).
    func clearAllUploadStatus() {
        for index in recordings.indices { recordings[index].uploadStatus = nil }
        persistRecordings()
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

    /// Removes the Recording's entry, its spectrogram thumbnail, AND the underlying
    /// WAV file itself — unlike a pass (a log entry with no separate asset besides
    /// small thumbnails), a Recording's whole reason for existing is the WAV, so an
    /// orphaned multi-minute file left behind on delete would just waste space.
    func delete(_ recording: Recording) {
        delete([recording])
    }

    /// Bulk delete — the only one that actually touches state, with the
    /// single-recording form above delegating to it.
    ///
    /// Deleting one at a time in a loop was O(n²): every `delete` did its own
    /// `removeAll` scan, its own `io.async` hop, and its own `persistRecordings`,
    /// which snapshots and JSON-encodes the ENTIRE recordings array. "Delete All"
    /// over a few thousand recordings meant a few thousand full encodes of a
    /// shrinking array — a multi-second main-thread stall — and, now that
    /// `recordings.json` lives in the iCloud container, a few thousand
    /// sync-triggering writes with it.
    func delete(_ toDelete: [Recording]) {
        guard !toDelete.isEmpty else { return }
        // Stop any transfer already under way — without this, a recording the
        // user just deleted could still finish uploading to the community
        // project seconds later.
        for recording in toDelete {
            RecordingUploader.shared.cancelUpload(recordingID: recording.id)
        }

        let doomed = Set(toDelete.map(\.id))
        recordings.removeAll { doomed.contains($0.id) }

        let imageFiles = toDelete.compactMap(\.spectrogramImageFile)
        let wavPaths = toDelete.map(\.relativeWavPath)
        io.async { [weak self] in
            guard let self else { return }
            let docs = CloudStorage.baseDirectory
            for file in imageFiles {
                try? FileManager.default.removeItem(at: self.imagesDir.appendingPathComponent(file))
            }
            for path in wavPaths {
                try? FileManager.default.removeItem(at: docs.appendingPathComponent(path))
            }
        }
        persistRecordings()
    }

    /// Wipes both passes AND recordings (WAVs included) — nothing calls this
    /// today, but it previously only cleared `passes` while still wiping the
    /// shared `imagesDir` out from under `recordings`' own thumbnails, orphaning
    /// them (broken thumbnail, WAV and JSON entry left behind). Mirrors
    /// `clearListening()`'s "recordings own their WAVs" scoping instead.
    func clearAll() {
        passes.removeAll()
        recordings.removeAll()
        imageCache.removeAllObjects()
        io.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.imagesDir)
            try? FileManager.default.createDirectory(at: self.imagesDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: self.jsonURL)
            try? FileManager.default.removeItem(at: self.recordingsURL)
            let docs = CloudStorage.baseDirectory
            try? FileManager.default.removeItem(at: docs.appendingPathComponent("Recordings"))
        }
    }

    /// Clear only the Listening bucket (passes and recordings not owned by a session).
    func clearListening() {
        for pass in listeningPasses { delete(pass) }
        delete(listeningRecordings)   // removes WAVs too
    }

    /// Deletes every Recording (and its WAV + thumbnail) — NOT `passes`, the
    /// separate lighter-weight per-pulse ID log entries sessions/species-feed
    /// are built from, which survive. Settings ▸ Recordings' "Delete All"; the
    /// disk-heavy WAVs are the actual storage problem being solved there.
    func deleteAllRecordings() {
        delete(recordings)
    }

    /// Settings ▸ Recordings' "Delete NoID" — triggered, but never classified
    /// confidently enough to call a species (usually just noise).
    func deleteNoIDRecordings() {
        delete(recordings.filter(\.isNoID))
    }

    /// Settings ▸ Recordings' "Delete Low-Confidence" — a real species ID, just
    /// under `threshold`. Excludes NoID (nil confidence): that's its own
    /// separate action above, not folded into "low confidence".
    func deleteRecordings(belowConfidence threshold: Float) {
        delete(recordings.filter { !$0.isNoID && ($0.confidence ?? 0) < threshold })
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

    func spectrogramImage(for recording: Recording) -> UIImage? {
        guard let file = recording.spectrogramImageFile else { return nil }
        if let cached = imageCache.object(forKey: file as NSString) { return cached }
        guard let img = UIImage(contentsOfFile: imagesDir.appendingPathComponent(file).path)
        else { return nil }
        imageCache.setObject(img, forKey: file as NSString)
        return img
    }

    /// Resolves a Recording's WAV to an absolute URL — never persisted as one (see
    /// `Recording.relativeWavPath`), only ever computed at use time.
    func wavURL(for recording: Recording) -> URL {
        let docs = CloudStorage.baseDirectory
        return docs.appendingPathComponent(recording.relativeWavPath)
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

    // Deliberately NO automatic count-based eviction for recordings, unlike
    // `prune()` above for passes. A pass's only asset is a small disposable
    // thumbnail; a Recording's entire reason for existing IS the WAV — silently
    // deleting someone's actual field recordings once they cross an arbitrary
    // count would be real, unprompted data loss. Deletion only ever happens via
    // an explicit `delete(_:)` call (swipe-to-delete, clear-all, etc.).

    private func persist() {
        let snapshot = passes
        io.async { [weak self] in
            guard let self else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: self.jsonURL)
            }
        }
    }

    private func persistRecordings() {
        let snapshot = recordings
        io.async { [weak self] in
            guard let self else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: self.recordingsURL)
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
        if let data = try? Data(contentsOf: recordingsURL),
           let decoded = try? JSONDecoder().decode([Recording].self, from: data) {
            recordings = decoded
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
        "NOID": "Unidentified",
        "NYHU": "Evening Bat",
        "NYMA": "Big Free-tailed Bat",
        "PAHE": "Canyon Bat",
        "PESU": "Tri-colored Bat",
        "TABR": "Brazilian Free-tailed Bat",
    ]
}
