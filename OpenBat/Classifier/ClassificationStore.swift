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
import ImageIO
import Observation
import CoreLocation

// MARK: - Persisted records

/// A field outing: a dated, located container owning the passes and recordings
/// made during it (linked by `sessionID`).
///
/// Every run of the detector is one of these as of 2026-08-16. There used to be
/// a choice on the way in — "New Session" or "Just Listening" — where listening
/// produced passes with a nil `sessionID` that no screen ever showed. The choice
/// really decided whether a GPS track was recorded, which is a question about
/// privacy and battery wearing the costume of a question about filing, and it
/// had to be answered before the user had heard a single bat. Tracks are gone
/// (see LocationProvider), so the question went with them.
struct RecordingSession: Codable, Identifiable {
    let id: UUID
    var title: String            // "29 Jun 2026 · Mendip Hills" — place filled in async
    var notes: String
    let startDate: Date
    var endDate: Date?

    /// Sessions saved before tracks were removed carry one; it is decoded and
    /// discarded rather than rejected, so an existing library still opens.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decode(String.self, forKey: .notes)
        startDate = try c.decode(Date.self, forKey: .startDate)
        endDate = try c.decodeIfPresent(Date.self, forKey: .endDate)
    }

    init(id: UUID, title: String, notes: String, startDate: Date, endDate: Date?) {
        self.id = id
        self.title = title
        self.notes = notes
        self.startDate = startDate
        self.endDate = endDate
    }
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
    var sessionID: UUID?         // owning session; nil only for pre-2026-08-16 records, adopted on load
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
/// Context.md §10): everything from the pre-roll before the
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
    var species: String             // never "NOISE" — those are rejected before saving; mutable for a manual correction (see `ClassificationStore.setManualSpecies`)
    var commonName: String
    let confidence: Float?          // nil for a NoID recording
    let pulseCount: Int
    var sessionID: UUID?            // nil = recorded outside a session (legacy, or demo)
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
    /// Throttle full sessions.json rewrites.
    private var lastSessionPersist: Date = .distantPast
    /// Guards `load()` against running more than once — see its doc comment.
    private var hasLoaded = false

    // Small in-memory cache so scrolling the list doesn't re-decode JPEGs.
    // Cost-limited (bytes of decoded bitmap, see `cacheCost`): a Recording's
    // whole-file overview is stored at the render's native 4096 × 1024, i.e.
    // ~16 MB decoded EACH, so an uncapped cache of those alone could carry the
    // library's worth of them until the app was jettisoned. Row thumbnails are
    // cached under a size-qualified key (see `cacheKey`) so the 56 × 40 list
    // entry never pulls the full-size bitmap in.
    private var imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    init() {
        let docs = CloudStorage.baseDirectory
        dir         = docs.appendingPathComponent("Classifications", isDirectory: true)
        imagesDir   = dir.appendingPathComponent("images", isDirectory: true)
        jsonURL     = dir.appendingPathComponent("passes.json")
        sessionsURL = dir.appendingPathComponent("sessions.json")
        recordingsURL = dir.appendingPathComponent("recordings.json")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        // NOT load() — see `load()`'s doc comment. Path setup only here.
        //
        // `CloudStorage.baseDirectory` is a lazy `static let`, so its (possibly
        // blocking) ubiquity-container resolution is paid once per process by
        // whichever store is built first, not on every construction.
    }

    // MARK: Sessions

    /// How long a just-ended session stays resumable. Stopping and restarting
    /// inside this window continues the same outing instead of starting another.
    ///
    /// Every run became a session on 2026-08-16, which removed a decision the
    /// user shouldn't have had to make — but it also meant a stop and a start
    /// now cost a whole extra row. Someone pausing to move to a better spot, or
    /// to check a setting, would otherwise litter one evening with a dozen
    /// near-empty sessions. A session should be an outing, not a tap.
    private static let sessionResumeWindow: TimeInterval = 15 * 60

    /// Begin an outing and mark it active, resuming the previous one if it ended
    /// only moments ago. New passes attach to it until `endSession`.
    @discardableResult
    func startSession(startDate: Date = Date()) -> UUID {
        if let last = sessions.first, let ended = last.endDate,
           startDate.timeIntervalSince(ended) <= Self.sessionResumeWindow,
           startDate >= ended {
            // Reopening: clear the end stamp so the row reads as one continuous
            // outing rather than showing when the user happened to pause.
            if let i = sessions.firstIndex(where: { $0.id == last.id }) {
                sessions[i].endDate = nil
            }
            activeSessionID = last.id
            persistSessions()
            return last.id
        }
        let session = RecordingSession(id: UUID(), title: Self.defaultTitle(startDate),
                                       notes: "", startDate: startDate, endDate: nil)
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

    /// Called only after a successful `ConsentStore.eraseConsentRecord()`. The
    /// device identifier has been rotated, so these badges describe contributions
    /// made under an identity this device no longer holds — and the recordings
    /// themselves are anonymous and stay in the dataset, so a per-recording
    /// "Uploaded" claim is no longer something the app can stand behind. Resets
    /// every recording back to untouched (nil = not contributing).
    ///
    /// Note this deletes nothing server-side and is not cleanup after something
    /// that did — see `ConsentStore.eraseConsentRecord` for what erasure covers.
    func clearAllUploadStatus() {
        for index in recordings.indices { recordings[index].uploadStatus = nil }
        persistRecordings()
    }

    // MARK: Manual species correction

    /// Applies a user correction from the WAV player's species-edit sheet —
    /// updates the persisted `species`/`commonName` that every list, feed and
    /// map pin reads, so the correction shows up everywhere, not just in the
    /// WAV's own GUANO tag. `code == nil` resets to "NOID" (matches a fresh
    /// no-ID recording); the GUANO `Species Manual ID` chunk itself is
    /// rewritten separately by the caller (`GuanoMetadata.updateManualID`) —
    /// this only touches the in-app record.
    func setManualSpecies(recordingID: UUID, code: String?) {
        guard let index = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        let resolved = code ?? "NOID"
        recordings[index].species = resolved
        recordings[index].commonName = SpeciesInfo.commonName[resolved] ?? resolved
        persistRecordings()
    }

    // MARK: Delete

    func delete(_ pass: PassRecord) {
        delete([pass])
    }

    /// Bulk delete — the only one that actually touches state, with the
    /// single-pass form above delegating to it. Mirrors `delete(_
    /// toDelete: [Recording])`'s fix for the same O(n²) bug class: deleting
    /// one at a time in a loop did its own `removeAll` scan, `io.async` hop,
    /// and full `persist()` re-encode of the entire passes array per call.
    func delete(_ toDelete: [PassRecord]) {
        guard !toDelete.isEmpty else { return }
        let doomed = Set(toDelete.map(\.id))
        passes.removeAll { doomed.contains($0.id) }

        let imageFiles = toDelete.flatMap { $0.pulses.compactMap(\.imageFile) }
        io.async { [weak self] in
            guard let self else { return }
            for file in imageFiles {
                try? FileManager.default.removeItem(at: self.imagesDir.appendingPathComponent(file))
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
    /// single-recording form above delegating to it. Deliberately bulk rather than a
    /// loop of single deletes: each one does its own O(n) `removeAll` scan plus a full
    /// JSON re-encode of the whole array via `persistRecordings`, so "Delete All" over
    /// thousands of recordings would otherwise mean thousands of full encodes and,
    /// with `recordings.json` in the iCloud container, thousands of sync-triggering
    /// writes.
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

    /// Clear only the Listening bucket (passes and recordings not owned by a session).
    func clearListening() {
        delete(listeningPasses)
        delete(listeningRecordings)   // removes WAVs too
    }

    /// Settings ▸ Storage's "Delete NoID Recordings" — triggered, but never
    /// classified confidently enough to call a species (usually just noise).
    /// Leaves the pass log alone; only the disk-heavy WAVs go.
    func deleteNoIDRecordings() {
        delete(recordings.filter(\.isNoID))
    }

    /// Settings ▸ Storage's "Delete All Sessions" — every session and
    /// everything it owns: its passes, its recordings, and their WAVs and
    /// thumbnails.
    ///
    /// The "Not in a session" bucket is deliberately untouched — imported WAVs
    /// and anything recorded before every outing became a session were never in
    /// one, and a bulk delete named for sessions must not quietly take them.
    /// Those rows are swipe-deletable in Sessions.
    ///
    /// Routed through `deleteSession` per session rather than clearing the
    /// arrays wholesale: that is the method that also removes the pulse images
    /// and the WAVs off disk, and duplicating it here is how those get orphaned.
    /// `sessions` is a value type, so mutating it inside the loop is safe.
    func deleteAllSessions() {
        for session in sessions { deleteSession(session) }
    }

    // MARK: Image loading

    /// What an off-main image load actually found. `awaitingDownload` is NOT a
    /// failure: the file exists in the library but its bytes are still in iCloud,
    /// so the caller should keep its placeholder and ask again later (see
    /// `RecordingThumbnailLoader` in RecordingViews.swift) rather than treating
    /// the recording as having no spectrogram.
    enum ImageLoad {
        case loaded(UIImage)
        case awaitingDownload
        case unavailable
    }

    func image(for record: PulseRecord) -> UIImage? {
        guard let file = record.imageFile else { return nil }
        if let cached = imageCache.object(forKey: file as NSString) { return cached }
        guard let img = UIImage(contentsOfFile: imagesDir.appendingPathComponent(file).path)
        else { return nil }
        imageCache.setObject(img, forKey: file as NSString, cost: Self.cacheCost(img))
        return img
    }

    /// Off-main-thread counterpart to `image(for:)` — a cache hit still returns
    /// immediately (no `Task.detached` hop), but a miss decodes on a background
    /// thread instead of blocking whichever row's body called it. Use from a
    /// `.task(id:)` in a row view, not from `body` directly.
    ///
    /// Checks `CloudStorage.isDownloaded` before touching the file: right after
    /// a delete/reinstall the thumbnail JPEGs are still iCloud placeholders (the
    /// library synced back via `recordings.json`/`passes.json`, which are tiny
    /// and land almost immediately, well before the images do), and a screen
    /// full of rows all calling `UIImage(contentsOfFile:)` on files that aren't
    /// there yet is what read as the app hanging while it "generated" every
    /// thumbnail. Skipping the read and just requesting the download instead
    /// means the row shows its placeholder immediately rather than stalling;
    /// there's no active retry here (see `CloudStorage.ensureDownloaded`'s own
    /// doc comment — this file gets read again on the next appearance/scroll,
    /// which is the same best-effort contract every other reader in this app
    /// already relies on for WAVs).
    func loadImage(for record: PulseRecord) async -> UIImage? {
        guard let file = record.imageFile else { return nil }
        // Pulse thumbnails are already written small (`thumbMaxWidth`), so
        // there's nothing to gain from decode-time downsampling here.
        guard case .loaded(let img) = await load(file: file, maxPixelSize: nil,
                                                priority: .userInitiated)
        else { return nil }
        return img
    }

    /// Loads a Recording's whole-file spectrogram overview off the main thread.
    ///
    /// `maxPixelSize` caps the LONGER decoded edge, and matters far more than it
    /// looks: these JPEGs are saved at the render's native 4096 × 1024, so a plain
    /// `UIImage(contentsOfFile:)` inflates ~16 MB of bitmap per row for a 56 × 40
    /// thumbnail, then hands the render server a 4096-wide image to downscale on
    /// every frame. Passing a display-sized cap routes the decode through ImageIO's
    /// scaled thumbnail path (which subsamples during JPEG decode rather than
    /// decoding full-size first), which is what keeps a screenful of rows from
    /// stalling the list. Pass nil only when the full resolution is genuinely
    /// wanted.
    ///
    /// Rows should prefer `.utility` priority: a tapped-into WavPlayerView is doing
    /// a `.userInitiated` whole-file FFT, and thumbnail decodes must not compete
    /// with it for the same cores.
    func loadSpectrogramImage(for recording: Recording,
                              maxPixelSize: CGFloat?,
                              priority: TaskPriority = .utility) async -> ImageLoad {
        guard let file = recording.spectrogramImageFile else { return .unavailable }
        return await load(file: file, maxPixelSize: maxPixelSize, priority: priority)
    }

    /// Shared body of the two loaders above: cache hit → decode off-thread → cache.
    ///
    /// Checks `CloudStorage.isDownloaded` before touching the file: right after
    /// a delete/reinstall the thumbnail JPEGs are still iCloud placeholders (the
    /// library synced back via `recordings.json`/`passes.json`, which are tiny
    /// and land almost immediately, well before the images do), and a screen
    /// full of rows all calling `UIImage(contentsOfFile:)` on files that aren't
    /// there yet is what read as the app hanging while it "generated" every
    /// thumbnail. Skipping the read and reporting `awaitingDownload` instead
    /// means the row shows its placeholder immediately rather than stalling, and
    /// the caller retries on its own clock once the bytes have landed.
    private func load(file: String, maxPixelSize: CGFloat?, priority: TaskPriority) async -> ImageLoad {
        let key = Self.cacheKey(file: file, maxPixelSize: maxPixelSize)
        if let cached = imageCache.object(forKey: key) { return .loaded(cached) }
        let url = imagesDir.appendingPathComponent(file)
        let result = await Task.detached(priority: priority, operation: { () -> ImageLoad in
            guard CloudStorage.isDownloaded(url) else {
                CloudStorage.ensureDownloaded(url)
                return .awaitingDownload
            }
            guard let img = Self.decode(at: url, maxPixelSize: maxPixelSize) else {
                // A failed decode is NOT proof the thumbnail is gone. On a
                // cloud-backed library right after a reinstall the file often
                // doesn't exist yet at all — iCloud brings back
                // recordings.json/passes.json well before it enumerates the
                // images directory — and a missing path reads as "downloaded"
                // to `isDownloaded` (nothing to wait on), so this used to
                // return `.unavailable` and the row gave up for good. Ask
                // CloudStorage whether the bytes can still show up, and let
                // the caller keep retrying if they can.
                return CloudStorage.mayArriveLater(url) ? .awaitingDownload : .unavailable
            }
            return .loaded(img)
        }).value
        if case .loaded(let img) = result {
            imageCache.setObject(img, forKey: key, cost: Self.cacheCost(img))
        }
        return result
    }

    /// Size-qualified so a row's small decode and the detail page's large one
    /// can't be served to each other.
    private static func cacheKey(file: String, maxPixelSize: CGFloat?) -> NSString {
        guard let maxPixelSize else { return file as NSString }
        return "\(file)@\(Int(maxPixelSize))" as NSString
    }

    /// Approximate decoded-bitmap bytes, for `imageCache`'s cost limit.
    private static func cacheCost(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        return cg.bytesPerRow * cg.height
    }

    private nonisolated static func decode(at url: URL, maxPixelSize: CGFloat?) -> UIImage? {
        guard let maxPixelSize else { return UIImage(contentsOfFile: url.path) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize.rounded()),
            // Decode eagerly, here on this background thread — otherwise the
            // first draw pays for it on the main/render thread, which is the
            // cost this whole path exists to move off the list.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
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
                try? data.write(to: self.jsonURL, options: .atomic)
            }
        }
    }

    private func persistRecordings() {
        let snapshot = recordings
        io.async { [weak self] in
            guard let self else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: self.recordingsURL, options: .atomic)
            }
        }
    }

    /// Persist sessions, throttled so a burst of changes doesn't rewrite on every
    /// breadcrumb. `force` bypasses the throttle (session start/end, edits, deletes).
    private func persistSessions(force: Bool = false) {
        if !force, Date().timeIntervalSince(lastSessionPersist) < 5 { return }
        lastSessionPersist = Date()
        let snapshot = sessions
        io.async { [weak self] in
            guard let self else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: self.sessionsURL, options: .atomic)
            }
        }
    }

    /// Reads the three stores off the main thread. Call once, from the owning
    /// view's `.task` — never from `init()`, whose expression SwiftUI may
    /// re-evaluate any number of times per `@State` default, discarding all but
    /// the first result (see Context.md §13's SwiftUI-init pattern).
    func load() async {
        guard !hasLoaded else { return }
        let decoded = await Task.detached(priority: .userInitiated) {
            [jsonURL, sessionsURL, recordingsURL] in
            (passes: Self.decode([PassRecord].self, from: jsonURL),
             sessions: Self.decode([RecordingSession].self, from: sessionsURL),
             recordings: Self.decode([Recording].self, from: recordingsURL))
        }.value

        // Re-checked after the await: `hasLoaded` gates against a second caller,
        // and anything already recorded in the meantime (a session started
        // before the decode landed) must not be clobbered by the disk copy.
        guard !hasLoaded else { return }
        hasLoaded = true
        if let p = decoded.passes,     passes.isEmpty     { passes = p }
        if let s = decoded.sessions,   sessions.isEmpty   { sessions = s }
        if let r = decoded.recordings, recordings.isEmpty { recordings = r }
        adoptOrphanedListeningPasses()
    }

    /// Gathers pre-2026-08-16 "Just Listening" detections into sessions, one per
    /// night, so they stop being invisible.
    ///
    /// Those passes were saved with a nil `sessionID` and no screen ever showed
    /// them — the review that started this work ran the detector for twenty
    /// minutes, logged 1,450 pulses, and then found "No sessions yet". The data
    /// was there the whole time with nowhere to appear. Now that every run is a
    /// session, the old ones need somewhere to live too, or upgrading would
    /// silently discard a user's history.
    ///
    /// Grouped by night rather than by day: a session that starts at 21:00 and
    /// runs past midnight is one outing, and splitting it at midnight would be
    /// wrong for exactly the users who did the most listening.
    private func adoptOrphanedListeningPasses() {
        let orphans = passes.filter { $0.sessionID == nil }
        guard !orphans.isEmpty else { return }

        var calendar = Calendar.current
        calendar.timeZone = .current
        let grouped = Dictionary(grouping: orphans) { pass -> Date in
            // Anything before midday belongs to the previous evening's outing.
            let shifted = calendar.date(byAdding: .hour, value: -12, to: pass.date) ?? pass.date
            return calendar.startOfDay(for: shifted)
        }

        for (night, group) in grouped {
            let start = group.map(\.date).min() ?? night
            let end = group.map(\.date).max()
            let session = RecordingSession(id: UUID(),
                                           title: Self.defaultTitle(start),
                                           notes: "",
                                           startDate: start,
                                           endDate: end)
            sessions.append(session)
            for index in passes.indices where passes[index].sessionID == nil
                && group.contains(where: { $0.id == passes[index].id }) {
                passes[index].sessionID = session.id
            }
        }
        sessions.sort { $0.startDate > $1.startDate }
        persistSessions(force: true)
        persist()
    }

    nonisolated private static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Species names (shared)

enum SpeciesInfo {

    /// Common names, with the field guide winning wherever it has an entry.
    ///
    /// The app used to hold two independent name lists and they disagreed in
    /// public: the classifier called TABR the "Brazilian Free-tailed Bat" while
    /// the field guide called the same animal the "Mexican Free-tailed Bat",
    /// which reads to a new user as two species. The guide is the right
    /// authority — it is community-edited, correctable without shipping an app
    /// update, and it is where anyone goes to read about the bat — so it now
    /// overrides the table below rather than sitting beside it.
    ///
    /// Kept as a subscript so all ~13 call sites (several outside SwiftUI, in
    /// the store and the Live Activity controller) read exactly as before,
    /// rather than each having to be handed a guide reference.
    struct NameTable {
        subscript(code: String) -> String? {
            SpeciesInfo.guideNames[code] ?? SpeciesInfo.bundledNames[code]
        }
    }

    static let commonName = NameTable()

    /// Populated by `SpeciesGuideStore` whenever it loads or refreshes.
    private(set) static var guideNames: [String: String] = [:]

    /// Adopt the guide's names for every code a model can produce.
    ///
    /// Joined on scientific name, the same way `SpeciesGuide.species(forCode:)`
    /// does — the guide deliberately knows nothing about classifier codes.
    static func adoptNames(from guide: SpeciesGuide) {
        var names: [String: String] = [:]
        for entry in guide.species {
            guard let code = SpeciesGuide.code(forScientificName: entry.scientificName) else { continue }
            names[code] = entry.commonName
        }
        guideNames = names
    }

    /// Fallback for codes the guide has no page for — which is most of them:
    /// the models name 47 species and the guide describes far fewer.
    static let bundledNames: [String: String] = [
        // BatDetect2 (UK/Europe), 6-letter codes — see
        // BatDetect2Classifier.classNames/scientificNames.
        "MYOMYS": "Whiskered Bat",
        "MYOALC": "Alcathoe Bat",
        "CNESER": "Serotine",
        "PIPNAT": "Nathusius' Pipistrelle",
        "BARBAR": "Barbastelle",
        "MYONAT": "Natterer's Bat",
        "MYODAU": "Daubenton's Bat",
        "MYOBRA": "Brandt's Bat",
        "PIPPIP": "Common Pipistrelle",
        "MYOBEC": "Bechstein's Bat",
        "PIPPYG": "Soprano Pipistrelle",
        "RHIHIP": "Lesser Horseshoe Bat",
        "NYCLEI": "Leisler's Bat",
        "RHIFER": "Greater Horseshoe Bat",
        "PLEAUR": "Brown Long-eared Bat",
        "NYCNOC": "Common Noctule",
        "PLEAUS": "Grey Long-eared Bat",
        // NABat (US), 4-letter codes.
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
