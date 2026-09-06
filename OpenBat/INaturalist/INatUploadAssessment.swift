//
//  INatUploadAssessment.swift
//  OpenBat
//
//  Whether a recording is worth posting to iNaturalist, and how strongly.
//
//  WHY THIS EXISTS
//  ---------------
//  iNaturalist runs on volunteers who look at other people's records. A tool
//  that makes posting one-tap easy makes posting a hundred mediocre records
//  one-tap easy too, and the cost of that lands on identifiers, not on us. The
//  bat2inat project's guidance is explicit about what is worth uploading — a
//  clear call, one species, not noisy, not a duplicate, complete metadata, not
//  a roost — and this file is that guidance turned into arithmetic the app can
//  apply before the user taps anything.
//
//  THE SCORE IS ADVICE. THE BLOCKERS ARE NOT.
//  ------------------------------------------
//  `score` colours a button and sorts a list; a user is free to post a 40. A
//  `blocker` stops the post outright, and there are only five of them — each
//  one a case where posting would produce a record that is either useless or
//  actively unwelcome.
//
//  THE CAP: TWO PER SPECIES, PER NIGHT, PER PLACE
//  ----------------------------------------------
//  Not per calendar day. A day boundary falls at midnight, in the middle of a
//  survey night, so a "2 per day" cap is really 4 for anyone recording either
//  side of it — the same bats, twice over. A night here runs NOON TO NOON,
//  which needs no solar calculation and no coordinate, and cannot split a
//  night in half wherever the user is standing.
//
//  And per place, because bat2inat's wording is "one or two per species from an
//  AREA". Somebody walking a transect is producing genuinely different presence
//  records at each stop, which is the most useful surveying there is; a flat
//  two-a-night would punish it. `cell` rounds to ~1 km.
//
//  The cap is hard — there is no "post anyway". It can afford to be, because
//  the manual route at the bottom of `INatObservationSheet` needs no account
//  and is not capped: what the cap removes is effortless bulk posting, not the
//  ability to post. Somebody with a real reason to add a third record can still
//  do it, deliberately, by hand.
//

import Foundation
import CoreLocation

nonisolated struct INatUploadAssessment {

    /// 0–100. Only meaningful when `blockers` is empty; a blocked recording
    /// reports 0 so it sorts to the bottom of any list of candidates.
    let score: Int

    /// Why this cannot be posted. Empty means it can.
    let blockers: [String]

    /// Set when the only thing stopping this is that it has been posted
    /// already — which is a completed job, not a fault with the recording.
    var alreadyPosted = false

    /// True when the debug override is on and `blockers` is being ignored.
    /// Only ever set from the Debug menu — see `INatUploadAssessment.overrideLimits`.
    var overridden = false

    /// Why the score is not higher. Ordered worst-first.
    let notes: [String]

    var canPost: Bool { blockers.isEmpty || overridden }

    enum Rating: String {
        /// Its own rating rather than a kind of `blocked`: "Not suitable" is a
        /// judgement about the recording, and saying it about one the user has
        /// already successfully posted is both wrong and insulting.
        case alreadyPosted = "Already uploaded"
        case blocked = "Not suitable"
        case poor = "Poor"
        case fair = "Fair"
        case good = "Good"
        case excellent = "Excellent"
    }

    var rating: Rating {
        if alreadyPosted { return .alreadyPosted }
        // An overridden recording still shows its real rating, blockers and
        // all: the override is there to let a post through, not to pretend the
        // recording is better than it is.
        guard blockers.isEmpty else { return .blocked }
        switch score {
        case 80...: return .excellent
        case 60..<80: return .good
        case 40..<60: return .fair
        default: return .poor
        }
    }

    /// One line for the confirmation screen.
    var summary: String {
        switch rating {
        case .alreadyPosted: return "This is already on iNaturalist."
        case .blocked: return "This one shouldn't go to iNaturalist."
        case .poor: return "Weak evidence. Consider keeping this one for yourself."
        case .fair: return "Usable, but an identifier will have to work for it."
        case .good: return "A solid record."
        case .excellent: return "A strong record — clear, and clearly one species."
        }
    }

    /// Debug-only: post regardless of the blockers.
    ///
    /// Exists for testing against the live API, where the same known recording
    /// gets posted and deleted over and over and the "you've already posted
    /// this" blocker makes the second attempt impossible. Set from the hidden
    /// Debug menu (fifteen taps on the version footer) and nowhere else, so it
    /// cannot be reached by an ordinary user — the rules it lifts are the ones
    /// protecting iNaturalist's identifiers, and there is deliberately no
    /// user-facing "post anyway".
    @MainActor
    static var overrideLimits: Bool {
        UserDefaults.standard.bool(forKey: "openbat.inat.debugIgnoreLimits")
    }

    // MARK: Assessing

    /// `uploadBytes` is the size of what would actually be attached — the pass
    /// SEGMENT, not the file on disk. Cutting the pass out of a recording can
    /// be the difference between 30 MB and 2 MB, so assessing the whole file
    /// would reject records that are perfectly fine.
    /// `echo` is `EchoAnalysis`'s verdict on the pass segment, or nil where
    /// nothing measured it — which is every row of the recordings list, since
    /// the measurement is an FFT per call and a list is sixty rows deep. A nil
    /// deducts nothing rather than assuming the worst, so a badge can be a
    /// grade more generous than the sheet on a reverberant recording. That is
    /// the same direction the size estimate already errs in, and the sheet is
    /// where the decision is actually made.
    static func assess(recording: Recording,
                       passes: [PassRecord],
                       uploadBytes: Int,
                       echo: EchoAnalysis.Result? = nil) -> INatUploadAssessment {
        var blockers: [String] = []
        var notes: [String] = []

        // ---- Blockers ----

        if uploadBytes > INatCredentials.maxSoundBytes {
            // Sound is the entire point of an acoustic record. An observation
            // with a spectrogram and no audio cannot be verified by anyone, so
            // this is a refusal rather than a deduction.
            blockers.append(String(format: "Even trimmed, the audio is %.0f MB — over iNaturalist's %d MB limit, so the call itself couldn't be attached.",
                                   Double(uploadBytes) / 1_048_576,
                                   INatCredentials.maxSoundBytes / 1_048_576))
        }

        if recording.latitude == nil || recording.longitude == nil {
            // "Complete metadata, including GPS location" — a presence record
            // with no place records no presence.
            blockers.append("There's no location on this recording, and a bat record without one can't tell anyone where the species was.")
        }

        let pulses = passes.flatMap(\.pulses)
        if recording.pulseCount == 0 || pulses.isEmpty {
            blockers.append("No calls were detected in this recording.")
        }

        var alreadyPosted = false
        if INatPostLedger.hasPosted(recordingID: recording.id) {
            alreadyPosted = true
            blockers.append("You've already posted this recording.")
        } else if let coordinate = recording.coordinate {
            let already = INatPostLedger.count(species: recording.species,
                                               night: Night(containing: recording.date),
                                               cell: Cell(coordinate))
            if already >= INatPostLedger.perSpeciesPerNight {
                blockers.append("You've already posted \(already) \(recording.commonName) records from around here tonight. iNaturalist is verified by volunteers, and more of the same species from the same place doesn't add anything.")
            }
        }

        // The override does not clear the blockers, it just stops them being
        // fatal — they stay on the screen, and the score below is still worked
        // out honestly, so a test post looks exactly like the real thing.
        let overridden = !blockers.isEmpty && MainActor.assumeIsolated { overrideLimits }
        if !blockers.isEmpty && !overridden {
            return INatUploadAssessment(score: 0, blockers: blockers,
                                        alreadyPosted: alreadyPosted, notes: notes)
        }

        // ---- Score ----

        var score = 0.0

        // Confidence (35). The RAW figure, not the location-weighted one: the
        // weighted score has the observer's own settings baked into it, and
        // what is being judged here is how good the evidence is, not how
        // plausible the species is where they happen to be standing.
        let raws = passes.compactMap(\.rawConfidence)
        let confidence = raws.isEmpty
            ? (recording.confidence ?? 0)
            : raws.reduce(0, +) / Float(raws.count)
        score += 35 * ramp(Double(confidence), from: 0.4, to: 0.95)
        if confidence < 0.6 {
            // A note about the EVIDENCE, not about the rank: everything is
            // posted at genus regardless (see `INatExport.taxon`), so this says
            // how much weight to put on the suggestion in the notes rather than
            // predicting what will be claimed.
            notes.append(String(format: "The model is only %.0f%% sure of the species, so the suggestion in the notes is a weak one.",
                                confidence * 100))
        }

        // One species (25). bat2inat's "works best if one species is present",
        // measured two ways: how many pulses agree with the verdict, and how
        // far clear the winner is of whatever ran second.
        let agreement = pulses.isEmpty ? 0
            : Double(pulses.filter { $0.species == recording.species }.count) / Double(pulses.count)
        score += 15 * ramp(agreement, from: 0.5, to: 0.95)
        if agreement < 0.8 {
            notes.append(String(format: "Only %.0f%% of the calls matched the reported species — there may be more than one bat here.", agreement * 100))
        }

        let best = passes.max { $0.confidence < $1.confidence }
        let margin: Double
        if let best, let runnerUp = best.runnerUpConfidence, best.confidence > 0 {
            margin = Double(max(0, best.confidence - runnerUp) / best.confidence)
        } else {
            margin = 1  // Nothing ran second at all, which is as clean as it gets.
        }
        score += 10 * ramp(margin, from: 0.05, to: 0.5)
        if let best, best.isComplexAmbiguous {
            notes.append("Another species in the same group scored close behind, and the two can't be told apart acoustically.")
        }

        // How much there is to look at (20). One call is a guess; a sequence is
        // evidence, and an identifier can only judge what was recorded.
        score += 20 * ramp(Double(recording.pulseCount), from: 1, to: 8)
        if recording.pulseCount < 4 {
            notes.append("Only \(recording.pulseCount) call\(recording.pulseCount == 1 ? "" : "s") — a longer sequence is much easier to verify.")
        }

        // Consistency (10). Calls from one bat on one pass cluster tightly in
        // peak frequency. A wide spread means noise, or more than one animal —
        // it is the cheapest "is this clean?" signal available without going
        // back to the audio.
        if pulses.count >= 3 {
            let peaks = pulses.map(\.peakFreqHz)
            let mean = peaks.reduce(0, +) / Double(peaks.count)
            if mean > 0 {
                let variance = peaks.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(peaks.count)
                let spread = variance.squareRoot() / mean
                score += 10 * (1 - ramp(spread, from: 0.05, to: 0.25))
                if spread > 0.15 {
                    notes.append("The calls vary a lot in frequency, which usually means noise or more than one species.")
                }
            }
        } else {
            // Too few to measure. Not penalised twice — the call count already
            // took the hit — so this awards the middle.
            score += 5
        }

        // Room under the size limit (10). Not a quality signal exactly, but a
        // file scraping the ceiling is one long recording of mostly nothing,
        // and it makes the observation slow to load for everyone who opens it.
        let fill = Double(uploadBytes) / Double(INatCredentials.maxSoundBytes)
        score += 10 * (1 - ramp(fill, from: 0.4, to: 1.0))

        // Echoes (−10). A deduction rather than a component, so a recording
        // with no echo measurement scores exactly what it always did and only
        // a measurably reverberant one loses anything.
        //
        // **Ten points, down from twenty** (Niall, 2026-09-06): "a high quality
        // recording with echo is still good". Reflections blur the sweep shape
        // an identifier reads, so they belong in the score — but they are one
        // property of a recording among several, and at twenty they could
        // outweigh the confidence term and most of the call count together. A
        // clean, confident, twelve-call pass that happens to have been recorded
        // beside a wall is still a better record than a quiet two-call one in
        // the open, and the score has to keep saying so.
        //
        // It is never a blocker — a reverberant recording is still a true
        // presence record, and where the bat was is the half that doesn't blur.
        if let echo {
            let penalty = 10 * ramp(echo.index,
                                    from: EchoAnalysis.cleanIndex,
                                    to: EchoAnalysis.reverberantIndex)
            score -= penalty
            if penalty >= 3 {
                notes.append("The calls trail off into their own echoes, which blurs the shape an identifier reads. Somewhere more open, or pointing the microphone away from hard surfaces, records the same bat much more clearly.")
            }
        }

        return INatUploadAssessment(score: Int(max(0, score).rounded()),
                                    blockers: blockers,
                                    alreadyPosted: alreadyPosted,
                                    overridden: overridden,
                                    notes: notes)
    }

    /// What the upload will weigh, WITHOUT cutting the segment out.
    ///
    /// `assess` needs the size of what actually gets attached, and producing it
    /// means copying tens of megabytes — fine for one recording on a
    /// confirmation screen, impossible for every row of a scrolling list. The
    /// segment is a plain span of the recording, though, so the size of its
    /// result is arithmetic: the span the calls occupy plus its margins, over
    /// the whole duration, times the bytes on disk.
    ///
    /// **It cannot see the silence map, and the real cut does** (2026-09-06).
    /// `INatExport.passSegment` widens the span to cover everything the app
    /// heard, including calls the classifier didn't keep, so the real segment
    /// is sometimes bigger than this says. The direction is the same one this
    /// estimate has always erred in and the consequence is bounded: the real
    /// cut also SHRINKS its own margins to fit under the size limit, so the
    /// only recording that can be over the limit in the sheet and under it here
    /// is one whose calls alone span more than 27 seconds — and that one gets
    /// its blocker on the sheet, before anything is posted.
    static func estimatedUploadBytes(recording: Recording,
                                     passes: [PassRecord],
                                     fileBytes: Int) -> Int {
        let pulses = passes.flatMap(\.pulses)
        guard !pulses.isEmpty, recording.durationSeconds > 0, fileBytes > 0 else { return fileBytes }

        let offsets = pulses.map { $0.date.timeIntervalSince(recording.date) }
        let longestPulse = (pulses.map(\.durationMs).max() ?? 0) / 1000
        let core = max(0, (offsets.max() ?? 0) + longestPulse - (offsets.min() ?? 0))

        // The margin the real cut asks for, and gives back where the size limit
        // takes it — mirrored here so a badge and the sheet cannot disagree
        // about whether something fits. See `INatExport.passSegment`.
        let budgetSeconds = Double(INatCredentials.maxSoundBytes)
            / Double(fileBytes) * recording.durationSeconds
        let affordable = max(0, (budgetSeconds - core) / 2)
        let padding = min(INatExport.preferredPaddingSeconds,
                          max(INatExport.minimumPaddingSeconds, affordable))

        let span = min(recording.durationSeconds, core + 2 * padding)
        let fraction = span / recording.durationSeconds
        guard fraction < 0.95 else { return fileBytes }
        return Int(Double(fileBytes) * fraction)
    }

    /// 0 at or below `from`, 1 at or above `to`, linear between. Every
    /// component above is one of these, so the weights are the only place the
    /// balance lives.
    private static func ramp(_ value: Double, from: Double, to: Double) -> Double {
        guard to > from else { return value >= to ? 1 : 0 }
        return min(1, max(0, (value - from) / (to - from)))
    }
}

// MARK: - Night and place

/// One survey night, running NOON TO NOON local time.
///
/// Midnight is the wrong boundary for anything nocturnal: it falls in the
/// middle of the activity, so a per-day rule counts one night as two. Noon is
/// the quietest possible moment to cut, and needs no sunrise calculation — see
/// the header of this file.
nonisolated struct Night: Hashable, Codable {
    /// The date the night *began* on, i.e. the calendar day of its first noon.
    let startOfNight: Date

    init(containing moment: Date, calendar: Calendar = .current) {
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: moment) ?? moment
        // Before noon is still last night's session.
        startOfNight = moment < noon ? calendar.date(byAdding: .day, value: -1, to: noon) ?? noon : noon
    }
}

/// A location rounded to roughly a kilometre, which is the resolution the
/// duplicate rule cares about: two records of the same species from the same
/// field on the same night are a duplicate; from two ends of a transect they
/// are two presence records.
///
/// 0.01° of latitude is about 1.1 km everywhere. The same step in longitude is
/// narrower the further from the equator, which makes the cells smaller — the
/// direction that lets MORE records through, and the safe one to be wrong in.
nonisolated struct Cell: Hashable, Codable {
    let latitude: Int
    let longitude: Int

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = Int((coordinate.latitude * 100).rounded())
        longitude = Int((coordinate.longitude * 100).rounded())
    }
}

// MARK: - What has already been posted

/// The record of what this phone has put on iNaturalist, which is what makes
/// the cap and the "already posted" check possible.
///
/// Local, in UserDefaults, and deliberately not synced: it holds a species, a
/// time and a rounded location per post, which is exactly the kind of thing
/// that should not be shipped anywhere. Erased with the app.
///
/// It is also NOT the authority on whether an observation exists — iNaturalist
/// is, and `INatClient.post` asks it. This is the local shortcut that stops the
/// user reaching that point.
/// Tells the recording list that the ledger changed.
///
/// The rows work out their iNaturalist badge once, when they appear, off a
/// snapshot of the ledger. Posting happens two screens away, so without this a
/// row would keep saying "worth posting" about something already posted until
/// the app was relaunched. Observing a counter is enough — the rows re-read the
/// ledger themselves.
@Observable
final class INatPostSignal {
    static let shared = INatPostSignal()
    private(set) var changes = 0
    private init() {}
    func bump() { changes += 1 }
}

nonisolated enum INatPostLedger {

    static let perSpeciesPerNight = 2

    struct Entry: Codable {
        let recordingID: UUID
        let species: String
        let night: Night
        let cell: Cell?
        let postedAt: Date
    }

    private static let key = "openbat.inat.posted"

    /// Decoded once and held, because the recording list asks every row whether
    /// it has been posted — re-decoding a year of JSON per row, per scroll, is
    /// the kind of thing that makes a list stutter for no reason. Only `record`
    /// writes, and it refreshes this itself.
    nonisolated(unsafe) private static var cached: [Entry]?

    static var entries: [Entry] {
        if let cached { return cached }
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            cached = []
            return []
        }
        cached = decoded
        return decoded
    }

    static func hasPosted(recordingID: UUID) -> Bool {
        entries.contains { $0.recordingID == recordingID }
    }

    static func count(species: String, night: Night, cell: Cell) -> Int {
        entries.filter { $0.species == species && $0.night == night && $0.cell == cell }.count
    }

    static func record(recording: Recording) {
        var all = entries
        guard !all.contains(where: { $0.recordingID == recording.id }) else { return }
        all.append(Entry(recordingID: recording.id,
                         species: recording.species,
                         night: Night(containing: recording.date),
                         cell: recording.coordinate.map(Cell.init),
                         postedAt: .now))
        // Trimmed to the last year: the cap only ever asks about tonight, and
        // "already posted" only matters for recordings still on the phone.
        // Unbounded growth in UserDefaults is the failure this avoids.
        let cutoff = Date.now.addingTimeInterval(-365 * 24 * 60 * 60)
        all = all.filter { $0.postedAt > cutoff }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
            cached = all
            Task { @MainActor in INatPostSignal.shared.bump() }
        }
    }

    /// Debug-only: forget every post this phone has made.
    ///
    /// The companion to `INatUploadAssessment.overrideLimits`, and the tidier
    /// half of it — testing against the live API means posting the same
    /// recording repeatedly, and this puts the phone back to never having
    /// posted anything rather than leaving the override switched on.
    static func forgetEverythingPosted() {
        UserDefaults.standard.removeObject(forKey: key)
        cached = []
        Task { @MainActor in INatPostSignal.shared.bump() }
    }

    // Note this is NOT called on sign-out, and signing out does NOT reset the
    // ledger. It would be tidier — the counts belong to an account, and a
    // second person signing in on the same phone inherits the first one's cap
    // for the night. But a reset on sign-out is a one-tap way around the cap,
    // and a cap with a one-tap bypass is decoration. The shared-phone case is
    // rare, lasts until noon, and has the manual uploader as its way out.
}
