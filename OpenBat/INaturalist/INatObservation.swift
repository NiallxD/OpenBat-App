//
//  INatObservation.swift
//  OpenBat
//
//  Prepares everything needed to log one recording as an iNaturalist
//  observation: the taxon to claim, the notes, and the files to attach.
//
//  Building the observation and POSTING it are deliberately separate. This file
//  only builds. `INatClient` posts, and only ever in response to a tap on
//  `INatObservationSheet` — nothing here reaches the network.
//
//  ONE OBSERVATION PER RECORDING, FOREVER
//  --------------------------------------
//  `observationUUID` is the recording's own id, and iNaturalist v2 lets the
//  client choose an observation's UUID. So a recording maps to exactly one
//  observation for good: a retry after a dropped connection re-sends the same
//  UUID and cannot create a second record. See `INatClient.post`.
//
//  THE HAND-OFF ROUTE IS STILL HERE
//  --------------------------------
//  Posting through the API needs a signed-in user; the copy-and-paste route
//  through iNaturalist's web uploader needs nothing, and remains the fallback
//  for anyone signed out or offline. Both routes claim the same taxon under the
//  same rules — see `taxon(for:)`, which is the part that matters.
//
//  Shaped to line up with bat2inat (github.com/AugustT/bat2inat, MIT): the same
//  quantities in the notes, in the same units, so OpenBat records read like the
//  ones already on iNat from Wildlife Acoustics kit.
//
//  THE WEB UPLOADER, NOT THE APP
//  -----------------------------
//  iNaturalist's iOS app can RECORD a sound but cannot import one. Its Android
//  app can, and its web uploader takes wav/mp3/m4a — so on an iPhone the app is
//  the one route that structurally cannot carry an acoustic record. The first
//  version of this screen handed the files to the Files app and left the user
//  stuck there.
//
//  So the sheet points at inaturalist.org's uploader, where the sound and the
//  spectrogram go in together, and the files go to the Files app.
//
//  **Not to Photos** (Niall, 2026-09-04). There was a "Save spectrogram to
//  Photos" button, for anyone who would rather build the observation in
//  iNaturalist's own app, which can pick a photo out of the library. It cost a
//  photo-library permission prompt — on a screen whose whole subject is a file
//  the user already has — to enable a route that posts the call WITHOUT its
//  sound, which is the thing this feature exists to fix. The Files app needs no
//  permission and carries everything.
//
//  WHAT GOES IN THE BUNDLE
//  -----------------------
//    • An AUDIBLE copy of the call — see `audibleCopy`. The original is 384 kHz
//      and no browser will play it, which makes the sound attachment on a lot of
//      existing bat observations effectively decorative.
//    • Two spectrograms, built by `INatImages`: the pass cropped to the call
//      band, and one call in detail with kHz/ms axes on it. The full-range
//      overview the player draws is deliberately NOT what gets sent — see that
//      file's header.
//    • The original WAV, for anyone who wants to re-analyse it.
//

import Foundation
import UIKit
import CoreLocation
import Accelerate

/// How precisely the observation's location is published.
///
/// A bat record at full precision can disclose a roost, and roosts are exactly
/// the thing not to put on a public map — so OpenBat defaults to `obscured`
/// (iNaturalist blurs the point to a ~0.2° cell and shows only that) and makes
/// publishing the exact spot a choice the user has to make on purpose.
nonisolated enum INatGeoprivacy: String, CaseIterable, Identifiable {
    case obscured
    case open
    /// The location is kept private entirely: iNaturalist stores it but shows
    /// nobody, which also means the record can't contribute to range data.
    case `private`

    var id: String { rawValue }

    var label: String {
        switch self {
        case .obscured: return "Obscured"
        case .open: return "Exact"
        case .private: return "Hidden"
        }
    }

    var note: String {
        switch self {
        case .obscured: return "The map shows a rough area, not the spot. The safe default for bats."
        case .open: return "The exact coordinates are public. Only if you're sure there's no roost here."
        case .private: return "Nobody sees the location, including researchers using the record."
        }
    }
}

nonisolated struct INatObservation: Identifiable {
    let id = UUID()
    /// The UUID this observation will have on iNaturalist — the recording's own
    /// id, which is what makes posting idempotent. See this file's header.
    let observationUUID: UUID
    /// What to put in iNat's species box. Deliberately not always the species —
    /// see `taxon(for:)`.
    let taxonName: String
    /// One line saying why the taxon is what it is, shown under the field so the
    /// user can disagree before they post rather than after.
    let taxonNote: String
    /// `YYYY-MM-DD HH:MM:SS`, local — the format iNat's date field accepts.
    let observedOn: String
    let latitude: Double?
    let longitude: Double?
    /// The notes body: what the recorder heard, in the units bat2inat uses.
    let notes: String
    /// Rows for the sheet, each individually copyable.
    let fields: [Field]

    struct Field: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        /// Shown in smaller type under the value.
        var note: String?
        /// The iNaturalist observation field this row is posted as, where one
        /// exists. nil rows are shown on the sheet for the manual route but
        /// have nowhere to go through the API — see `INatObservationFields`.
        var iNatFieldID: Int?
    }

    /// The rows that can actually be posted as observation fields.
    var postableFields: [Field] { fields.filter { $0.iNatFieldID != nil } }

    var coordinateText: String? {
        guard let latitude, let longitude else { return nil }
        return String(format: "%.6f, %.6f", latitude, longitude)
    }

    /// Everything, as one block to paste into iNat's Notes field.
    var pasteboardText: String {
        var lines = ["Date/time: \(observedOn)"]
        if let coordinateText { lines.append("Coordinates: \(coordinateText)") }
        lines.append("")
        lines.append(notes)
        return lines.joined(separator: "\n")
    }
}

/// The iNaturalist observation fields OpenBat fills in.
///
/// **These are existing community fields, not new ones.** Observation fields on
/// iNaturalist are global and anyone can create one, which means the useful
/// thing is to use whatever the bat-recording community already searches on
/// rather than to invent a tidier set. Looked up on iNaturalist directly rather
/// than taken from the API application draft, which named none of them:
///
///   567  Bat detector model          19,385 uses — far and away the
///                                    established one for acoustic bat records
///   578  Recording method            478 uses, and it has a FIXED value list:
///                                    time expansion | heterodyne |
///                                    frequency division | direct recording
///   308  Echolocation call frequency  1,252 uses. Free text, "dominant
///                                    frequency of call (kHz)"
///
/// Filling these is what puts an OpenBat record alongside the ones already
/// there from Wildlife Acoustics and Pettersson kit, and makes it turn up in
/// the searches people use to find acoustic records.
nonisolated enum INatObservationFields {
    /// iNaturalist's "Alive or Dead" annotation, and its "Alive" value.
    ///
    /// Safe to set without asking, which almost no annotation is: the
    /// observation is a recording of an echolocation call, and a bat that is
    /// echolocating is alive. It is not an inference about the animal, it is a
    /// restatement of what the evidence is.
    ///
    /// Only this one. "Life Stage" and "Sex" are unknowable from a call, and
    /// "Evidence of Presence" is for records that show something OTHER than the
    /// organism — a track, scat, a feather — so annotating a call with
    /// "Organism" adds nothing a reader couldn't see.
    ///
    /// Looked up from `/v1/controlled_terms` rather than remembered.
    static let aliveOrDeadAttribute = 17
    static let aliveValue = 18

    static let detectorModel = 567
    static let recordingMethod = 578
    static let callFrequency = 308

    /// One of `578`'s four permitted values, and the one that is true.
    ///
    /// OpenBat records full-spectrum at 384 kHz — every sample, unmodified —
    /// which is "direct recording". It is tempting to answer "time expansion"
    /// because the audio ATTACHED to the observation is time-expanded, and that
    /// would be wrong: this field describes how the call was captured, not what
    /// was uploaded, and a time-expansion detector is a different instrument
    /// that records in bursts and goes deaf between them.
    static let method = "direct recording"

    /// What goes in `567`: the microphone this RECORDING was made with, and
    /// the app.
    ///
    /// Both, because the field is read by people comparing kit and the answer
    /// is genuinely two things — the mic decides what was captured, the app
    /// decides what was made of it.
    ///
    /// **From the recording's own GUANO metadata, not from the setting** (Niall,
    /// 2026-09-04). Plenty of people own more than one detector, and the setting
    /// says which one is in use *now*; reading it at post time would stamp
    /// tonight's microphone onto a recording made last month with the other one.
    /// The GUANO `Make` field was written when the file was recorded and is the
    /// only per-recording answer there is.
    ///
    /// Only a name OpenBat itself offers is used. A file recorded before the
    /// setting existed has the USB port name in `Make` — `bat_detector_usb` and
    /// the like — and publishing that would be worse than publishing nothing:
    /// it looks like a model name and isn't one.
    static func detector(recordedWith make: String?) -> String {
        guard let make, DetectorModel.known.contains(make) else { return "OpenBat for iOS" }
        return "\(make) + OpenBat for iOS"
    }
}

nonisolated enum INatExport {

    /// How far the audible copy slows the recording down.
    ///
    /// 16×, matching the slowest speed OpenBat's own player offers. It also
    /// divides 384 kHz exactly, to 24 kHz — a rate every browser plays without
    /// resampling. A 45 kHz pipistrelle lands at 2.8 kHz, low enough to hear
    /// the structure of the call rather than a chirp.
    ///
    /// This used to claim the copy sounded "the same as it did in the app",
    /// which was untrue in both directions and is not the goal anyway: the
    /// player's gaps are still there and its background control defaults to
    /// Off, while this file is packed and scrubbed. What it matches is the
    /// player at its slowest SPEED — see `scrubbed` for the rest.
    static let expansionFactor = 16

    // MARK: Building the draft

    /// The text half of the hand-off — cheap, and safe on the main actor.
    /// `ModelRegistry` is main-actor isolated, which is the reason this is too;
    /// the file work is `prepareFiles`, which deliberately isn't.
    @MainActor
    static func draft(recording: Recording,
                      passes: [PassRecord],
                      priors: PriorSnapshot? = nil,
                      detectorMake: String? = nil) -> INatObservation {
        // Resolved from the species code rather than from the user's currently
        // active model: the recording was classified by whichever model knew
        // this code, and that may not be the one selected now.
        let descriptor = ModelRegistry.all.first { $0.scientificNames[recording.species] != nil }
        let taxon = taxon(for: recording, passes: passes, descriptor: descriptor)
        return INatObservation(
            observationUUID: recording.id,
            taxonName: taxon.name,
            taxonNote: taxon.note,
            observedOn: Self.dateTime.string(from: recording.date),
            latitude: recording.latitude,
            longitude: recording.longitude,
            notes: notes(recording: recording, passes: passes, descriptor: descriptor, priors: priors),
            fields: fields(recording: recording, passes: passes, detectorMake: detectorMake))
    }

    /// The attachments, kept apart rather than lumped into one array: the share
    /// sheet wants all of them together, but the API needs to know which is a
    /// photo and which is a sound, and telling them apart by file extension
    /// afterwards is the kind of thing that quietly breaks.
    struct Files {
        var audible: URL?
        /// The rendered spectrograms — the cropped context view and the
        /// axis-labelled call detail. Written by the sheet once `INatImages`
        /// has produced them, because rendering one of them needs the main
        /// actor and this type is built off it.
        var photos: [URL] = []
        /// The recording exactly as it sits on disk. Kept so the segment can
        /// say where it came from; never attached to an observation, and no
        /// longer offered to the share sheet either — see `all`.
        var original: URL
        /// The bat pass in its own real time — `INatExport.passSegment` — which
        /// is what actually goes to iNaturalist, and what every exported
        /// picture is drawn from. Equal to `original` when the pass fills the
        /// recording or the cut failed.
        var upload: URL

        /// What the manual route hands over — and it is exactly what the
        /// automatic route posts: the two sounds in upload order, then the
        /// pictures in theirs.
        ///
        /// **The untrimmed recording is deliberately not in here** (Niall,
        /// 2026-09-06). It used to be, and it was the last place the mismatch
        /// an identifier reported still survived: every picture describes the
        /// segment, so somebody building the observation by hand attached
        /// audio that was seconds longer than the pictures and started
        /// somewhere else entirely. Offering two files that both look like
        /// "the recording" is also a choice nobody should have to make while
        /// standing in iNaturalist's uploader. Anyone who wants the whole
        /// recording has Share Recording on the player, which is where that
        /// belongs.
        var all: [URL] { sounds + photos }

        /// What goes to `/observation_sounds`, in upload order: the audible
        /// time-expanded copy first, then the recording at its own rate.
        ///
        /// That order is the point. iNaturalist plays the first sound on an
        /// observation, and a 384 kHz file plays in no browser at all — leading
        /// with it would give every visitor silence and leave them assuming the
        /// record has no audio, which is what has happened to a lot of the
        /// acoustic observations already on the site.
        var sounds: [URL] { [audible, upload].compactMap { $0 } }

        /// What the size limit and the upload score are judged against. The
        /// audible copy is packed and so never larger, and the two are the same
        /// length whenever it isn't — either way this is the binding figure.
        var uploadBytes: Int {
            (try? FileManager.default.attributesOfItem(atPath: upload.path)[.size] as? Int)
                .flatMap { $0 } ?? 0
        }
    }

    /// Built off the main actor: the pass segment's audible copy, and the
    /// bookkeeping that says which file goes where. Slow enough to matter — a
    /// long recording at 384 kHz is tens of megabytes — so this never runs
    /// inline.
    ///
    /// **Everything downstream comes from the segment, not from the file on
    /// disk** (Niall, 2026-09-06). The segment IS the bat pass in real time;
    /// the audible copy is that segment with its gaps spliced out, and the
    /// pictures are drawn from the same segment by `INatImages`. Before this,
    /// the sounds were cut out of the recording and the pictures were drawn
    /// from the whole file — so an observation's first spectrogram tile showed
    /// the recorder's pre-roll, seconds of dead air that appeared in no
    /// attachment anybody could download, and no picture shared a zero with
    /// any sound. An identifier noticed, which is exactly the person who
    /// should never have to wonder whether the picture is of the audio.
    static func prepareFiles(segment: PassSegment, baseName: String) -> Files {
        var files = Files(original: segment.sourceURL, upload: segment.url)
        // The listening copy is the segment put through three steps, in this
        // order: the gaps cut out, the background scrubbed, then slowed 16×.
        //
        // Packed first, and scrubbed second, because the scrub measures the
        // noise it removes from the audio it is handed — and packing removes
        // gaps, not background. A packed pass is still around 90% background by
        // duration (thirty calls of five milliseconds inside 1.7 seconds), so
        // the median the estimator takes still lands in the noise, and there is
        // four times less audio to run the FFT over.
        //
        // Slowed LAST, though it makes no difference to the samples: expansion
        // is a header rewrite, so the denoiser would see exactly the same
        // buffer either way. Doing it last keeps the rule "nothing after the
        // expansion touches the audio" true.
        //
        // Never from the original, or the small upload would be paired with a
        // full-length listening copy and the 20 MB limit would still bite on
        // the file people actually play.
        let packed = packedToCalls(source: segment.url, map: segment.silence, baseName: baseName)
        let listenable = packed ?? segment.url
        let scrubbed = scrubbed(listenable, baseName: baseName) ?? listenable
        files.audible = audibleCopy(of: scrubbed, baseName: baseName)
        return files
    }

    // MARK: Scrubbing

    /// The listening copy with its background taken out.
    ///
    /// **Only this file, and never the full-spectrum one** (Niall, 2026-09-06).
    /// The two attachments answer different questions. The full-spectrum file is
    /// the evidence somebody re-analyses, and spectral subtraction would quietly
    /// alter every measurement made from it — so it goes up exactly as recorded.
    /// This one exists to be listened to, and hiss at 16× is what stops people
    /// listening.
    ///
    /// **Scrub, fixed, not the player's own setting.** The player defaults its
    /// background control to Off because a recording being reviewed is
    /// evidence, which is right for the screen and wrong here: following it
    /// would mean almost every observation carried an untreated file, and the
    /// person who benefits is a stranger on iNaturalist who has no way to turn
    /// it on. Scrub keeps only what is plainly a call and silences the rest —
    /// the audio equivalent of the noise floor the exported pictures are
    /// already drawn at.
    ///
    /// Returns nil if anything is not as expected, and the caller falls back to
    /// the unscrubbed audio: a hissy attachment is much better than none.
    static func scrubbed(_ source: URL, baseName: String) -> URL? {
        guard let format = WavHeader.describe(url: source), format.isCanonical else { return nil }
        let bytesPerSample = 2
        let count = Int(format.dataBytes) / bytesPerSample
        // Below one FFT there is nothing to measure; the ceiling is a guard on
        // a buffer this reads whole, and no packed pass comes near it.
        guard count >= SpectralDenoiser.fftSize, count <= maxScrubSamples else { return nil }

        guard let input = try? FileHandle(forReadingFrom: source),
              (try? input.seek(toOffset: format.dataOffset)) != nil,
              let data = try? input.read(upToCount: count * bytesPerSample),
              data.count == count * bytesPerSample
        else { return nil }
        try? input.close()

        // To float in ±1 and back. The denoiser's gains are ratios, so the
        // scale does not change what it does — but it is the scale every other
        // caller hands it, and a rule that holds everywhere is worth more than
        // one that happens to work here.
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            vDSP_vflt16(ints.baseAddress!, 1, &samples, 1, vDSP_Length(count))
        }
        var scale = Float(1) / 32_768
        vDSP_vsmul(samples, 1, &scale, &samples, 1, vDSP_Length(count))

        let denoiser = SpectralDenoiser(maxOfflineSamples: count)
        samples.withUnsafeMutableBufferPointer { buffer in
            denoiser.denoiseOffline(buffer.baseAddress!, count: count, strength: .scrub)
        }

        // Clipped before the conversion: `vDSP_vfix16` truncates towards zero
        // and wraps on overflow, so a sample the scrub pushed past full scale
        // would come back as loud noise of the opposite sign.
        var back = Float(32_767)
        vDSP_vsmul(samples, 1, &back, &samples, 1, vDSP_Length(count))
        var low = Float(-32_767), high = Float(32_767)
        vDSP_vclip(samples, 1, &low, &high, &samples, 1, vDSP_Length(count))
        var out = [Int16](repeating: 0, count: count)
        vDSP_vfix16(samples, 1, &out, 1, vDSP_Length(count))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(baseName)-calls-scrubbed.wav")
        try? FileManager.default.removeItem(at: url)
        var file = header(sampleRate: format.sampleRate, dataBytes: count * bytesPerSample)
        out.withUnsafeBufferPointer { file.append(Data(buffer: $0)) }
        guard (try? file.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    /// The most audio the scrub will read into memory at once.
    ///
    /// It holds the samples as floats and an overlap-add buffer beside them, so
    /// this is roughly eight bytes a sample plus the scrub's own mask. 30
    /// seconds at 384 kHz is about 90 MB and already far beyond anything the
    /// 20 MB upload limit can produce — the ceiling exists for an imported file
    /// with strange geometry, not for a bat pass.
    static let maxScrubSamples = 30 * 384_000

    // MARK: Packing

    /// The calls spliced together with the gaps between them cut out — the same
    /// audio the whole-pass picture shows, and cut at the same seams.
    ///
    /// **Why the audible copy needs this and the full-spectrum one must not**
    /// (Niall, 2026-09-05). Trimming to the outermost call leaves every gap
    /// inside the bout, and the audible copy is played 16×
    /// slower — so a 24-second recording of 30 calls became six and a half
    /// minutes of mostly nothing, with the calls scattered through it. Nobody
    /// listens to that, and it is the one attachment that exists to be listened
    /// to. The full-spectrum file is the opposite case: pulse INTERVAL is a
    /// real identification parameter, and splicing would silently rewrite it,
    /// so that file keeps the recording's own timing.
    ///
    /// The map comes from the player, so the seams are the ones the user was
    /// looking at and the ones the exported picture cuts — three things that
    /// would otherwise each have their own opinion about where the calls are.
    /// Returns nil when there is nothing worth cutting, and the caller falls
    /// back to the segment itself.
    static func packedToCalls(source: URL, map: SilenceMap, baseName: String) -> URL? {
        // `isFallback` means detection found nothing and the map is one
        // whole-file segment; packing it would be a copy.
        guard !map.isFallback, map.keptFraction < 0.9,
              let format = WavHeader.describe(url: source), format.isCanonical
        else { return nil }

        let bytesPerSample = 2  // canonical: 16-bit mono
        let totalSamples = Int(format.dataBytes) / bytesPerSample
        let regions = map.realRegions
            .map { $0.clamped(to: 0..<max(totalSamples, 0)) }
            .filter { !$0.isEmpty }
        let kept = regions.reduce(0) { $0 + $1.count }
        guard kept > 0 else { return nil }

        guard let input = try? FileHandle(forReadingFrom: source) else { return nil }
        defer { try? input.close() }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(baseName)-calls-packed.wav")
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let output = try? FileHandle(forWritingTo: url)
        else { return nil }

        var succeeded = false
        defer {
            try? output.close()
            if !succeeded { try? FileManager.default.removeItem(at: url) }
        }
        guard (try? output.write(contentsOf: header(sampleRate: format.sampleRate,
                                                    dataBytes: kept * bytesPerSample))) != nil
        else { return nil }

        let fade = max(1, Int(joinFadeSeconds * Double(format.sampleRate)))
        var written = 0
        for region in regions {
            let offset = format.dataOffset + UInt64(region.lowerBound * bytesPerSample)
            guard (try? input.seek(toOffset: offset)) != nil,
                  let data = try? input.read(upToCount: region.count * bytesPerSample),
                  !data.isEmpty
            else { break }
            var samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            faded(&samples, over: fade)
            let out = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            guard (try? output.write(contentsOf: out)) != nil else { return nil }
            written += samples.count
        }
        guard written > 0 else { return nil }
        // A short read leaves the header overstating the data.
        if written != kept {
            guard (try? output.seek(toOffset: 0)) != nil,
                  (try? output.write(contentsOf: header(sampleRate: format.sampleRate,
                                                        dataBytes: written * bytesPerSample))) != nil
            else { return nil }
        }
        succeeded = true
        return url
    }

    /// How long the taper at each seam is.
    ///
    /// Splicing two unrelated samples together is a step discontinuity, and a
    /// step is a click — which the audible copy then slows by
    /// 16×, turning it into an audible thump between every
    /// pair of calls. Two milliseconds is shorter than any bat call here (a
    /// call is 5–15 ms) so it cannot eat the onset it is protecting, and long
    /// enough at 384 kHz to be a gradual ramp rather than a second step.
    private static let joinFadeSeconds = 0.002

    /// Ramps a segment in and out in place, linearly.
    private static func faded(_ samples: inout [Int16], over fade: Int) {
        let n = samples.count
        let ramp = min(fade, n / 2)
        guard ramp > 0 else { return }
        for i in 0..<ramp {
            let gain = Float(i) / Float(ramp)
            samples[i] = Int16((Float(samples[i]) * gain).rounded())
            samples[n - 1 - i] = Int16((Float(samples[n - 1 - i]) * gain).rounded())
        }
    }

    // MARK: The pass segment

    /// How much quiet to keep either side of the pass when there is room for
    /// it.
    ///
    /// **A second, up from a third of a second** (Niall, 2026-09-06). The old
    /// figure was chosen to prove a call was not clipped, and it does that; it
    /// is not enough to HEAR a pass, and the file is the thing people play. A
    /// second either side reads as a recording of a bat going past rather than
    /// as a fragment, and it is a rounding error against the size limit —
    /// two seconds of 384 kHz audio is 1.5 MB out of 20.
    ///
    /// Asked for, not guaranteed: `passSegment` gives back only as much of it
    /// as fits under the size budget, so a long pass loses its margins before
    /// it loses a call.
    static let preferredPaddingSeconds = 1.0

    /// The least margin worth keeping when the budget is tight.
    ///
    /// Below this a call at the very edge of the span looks truncated on a
    /// spectrogram whether it was or not, which is the one thing the padding
    /// exists to rule out. A segment that cannot afford even this is over the
    /// size limit anyway and `INatUploadAssessment` blocks it.
    static let minimumPaddingSeconds = 0.15

    /// One bat pass, cut out of a recording as a plain span of real time.
    ///
    /// **This is the single thing every attachment is made from.** The
    /// full-spectrum sound IS this file; the audible copy is this file with
    /// its gaps spliced out; every spectrogram is drawn from this file, with
    /// its first sample as time zero. Nothing in the export path reads the
    /// recording on disk any more, which is what makes it impossible for a
    /// picture and a sound to disagree about where the pass starts.
    nonisolated struct PassSegment {
        /// The segment's audio — a canonical 16-bit mono WAV. Equal to
        /// `sourceURL` when the pass fills the recording and there was nothing
        /// worth cutting.
        let url: URL
        /// The recording it was cut from, which the share sheet still offers
        /// whole.
        let sourceURL: URL
        /// Where the segment sits in that recording, in samples.
        let range: Range<Int>
        let sampleRate: Double
        /// Where the calls are INSIDE the segment: the map the player computed
        /// over the whole recording, narrowed to this span rather than
        /// recomputed, so the packed sound and the packed picture cut the same
        /// seams the user was looking at.
        let silence: SilenceMap

        var startSeconds: Double { sampleRate > 0 ? Double(range.lowerBound) / sampleRate : 0 }
        var seconds: Double { sampleRate > 0 ? Double(range.count) / sampleRate : 0 }
        /// True when nothing was cut and `url` is the recording itself.
        var isWholeRecording: Bool { url == sourceURL }

        /// The instant the segment's first sample was recorded — what turns a
        /// pulse's timestamp into an offset into THIS file.
        func start(from recordingStart: Date) -> Date {
            recordingStart.addingTimeInterval(startSeconds)
        }
    }

    /// Cuts the bat pass out of a recording.
    ///
    /// A recording is mostly not a bat: the detector keeps a pre-roll of up to
    /// five seconds and runs on past the last call, and at 384 kHz silence
    /// costs the same 768 kB a second a bat does. What is left after this is
    /// the pass, in its own real time, with a margin either side.
    ///
    /// **The span comes from the silence map, not from the pulse list**
    /// (Niall, 2026-09-06). The old trim ran from the first classified pulse to
    /// the last, and a pulse list holds only the calls a model kept — so a pass
    /// opening with two calls the classifier skipped had those two cut off the
    /// front of the upload, audio the app itself had already decided was sound
    /// and had drawn on screen. The map is the app's own answer to "where is
    /// there sound in this file", it is the answer the player shows, and it is
    /// the one used here. The pulses still widen the span where they fall
    /// outside it, so a call the map missed is never cut either — the span is
    /// the union, and both opinions can only ever add to it.
    ///
    /// **The padding is what the budget can afford.** iNaturalist rejects a
    /// sound file over 20 MB, which at 384 kHz is 27 seconds, so the margin is
    /// asked for at `preferredPaddingSeconds` and shrunk — never below
    /// `minimumPaddingSeconds` — until the segment fits. Padding is the first
    /// thing to go and the calls are the last, which is the opposite of what a
    /// fixed margin does when a pass is long.
    ///
    /// Returns nil for a file this app cannot read at all; the caller then
    /// posts the recording as it is and the size blocker does its job.
    static func passSegment(wavURL: URL,
                            recordingStart: Date,
                            pulses: [PulseRecord],
                            silence: SilenceMap?,
                            byteBudget: Int,
                            baseName: String) -> PassSegment? {
        guard let format = WavHeader.describe(url: wavURL), format.isCanonical else { return nil }
        let bytesPerSample = 2  // canonical: 16-bit mono
        let rate = Double(format.sampleRate)
        let totalSamples = Int(format.dataBytes) / bytesPerSample
        guard totalSamples > 0, rate > 0 else { return nil }

        let whole = 0..<totalSamples
        func segment(over range: Range<Int>, url: URL) -> PassSegment {
            PassSegment(url: url, sourceURL: wavURL, range: range, sampleRate: rate,
                        silence: (silence ?? .wholeFile(totalSamples: totalSamples))
                            .rebased(to: range))
        }

        // Where there is sound, by the app's own two opinions. A fallback map
        // found nothing and describes the whole file, so it contributes
        // nothing here and the pulses decide alone.
        var lower = Int.max, upper = Int.min
        if let map = silence, !map.isFallback, let span = map.soundSpan {
            lower = min(lower, span.lowerBound)
            upper = max(upper, span.upperBound)
        }
        if !pulses.isEmpty {
            let offsets = pulses.map { $0.date.timeIntervalSince(recordingStart) }
            // Each pulse's timestamp is its start, so the last call ends a
            // pulse length later. Taking the longest is cheaper than pairing
            // them up and errs towards keeping more.
            let longestPulse = (pulses.map(\.durationMs).max() ?? 0) / 1000
            lower = min(lower, Int((offsets.min() ?? 0) * rate))
            upper = max(upper, Int(((offsets.max() ?? 0) + longestPulse) * rate))
        }
        // Nothing to go on — no map and no calls. Post what is there.
        guard lower < upper else { return segment(over: whole, url: wavURL) }

        // Pulse timestamps come from a different clock to the file's own
        // length, and a bad one could ask for a span that starts past the end
        // of the file — which is an inverted range, and forming one traps.
        let low = min(max(0, lower), totalSamples)
        let high = min(max(low, upper), totalSamples)
        let core = low..<high
        guard !core.isEmpty else { return segment(over: whole, url: wavURL) }

        // As much margin as the size limit leaves, preferred figure first.
        let budgetSamples = max(0, (byteBudget - 44) / bytesPerSample)
        let affordable = max(0, (budgetSamples - core.count) / 2)
        let padding = min(Int(preferredPaddingSeconds * rate),
                          max(Int(minimumPaddingSeconds * rate), affordable))
        let span = max(0, core.lowerBound - padding)..<min(totalSamples, core.upperBound + padding)

        // A pass that fills its recording has nothing to gain from a copy of
        // it, and copying tens of megabytes to save five per cent is work for
        // nothing.
        guard span.count < Int(Double(totalSamples) * 0.95) else {
            return segment(over: whole, url: wavURL)
        }
        guard let url = writeSegment(source: wavURL, format: format, range: span, baseName: baseName)
        else { return segment(over: whole, url: wavURL) }
        return segment(over: span, url: url)
    }

    /// Copies `range` of a canonical WAV into a new canonical WAV.
    ///
    /// Streamed in blocks rather than read whole: an imported recording can be
    /// minutes long, which at 384 kHz is hundreds of megabytes, and this runs
    /// while the user is looking at a sheet.
    private static func writeSegment(source: URL, format: WavFormat,
                                     range: Range<Int>, baseName: String) -> URL? {
        let bytesPerSample = 2
        let startByte = UInt64(range.lowerBound * bytesPerSample)
        let keep = range.count * bytesPerSample
        guard keep > 0, startByte + UInt64(keep) <= UInt64(format.dataBytes) else { return nil }

        guard let input = try? FileHandle(forReadingFrom: source),
              (try? input.seek(toOffset: format.dataOffset + startByte)) != nil
        else { return nil }
        defer { try? input.close() }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(baseName)-pass.wav")
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let output = try? FileHandle(forWritingTo: url)
        else { return nil }

        var written = 0
        var succeeded = false
        defer {
            try? output.close()
            // Same reasoning as `audibleCopy`: a half-written WAV would be
            // attached to an observation and play as a truncated call.
            if !succeeded { try? FileManager.default.removeItem(at: url) }
        }

        guard (try? output.write(contentsOf: header(sampleRate: format.sampleRate,
                                                    dataBytes: keep))) != nil
        else { return nil }

        while written < keep {
            let want = min(keep - written, 1 << 20)
            guard let block = try? input.read(upToCount: want), !block.isEmpty else { break }
            guard (try? output.write(contentsOf: block)) != nil else { return nil }
            written += block.count
        }
        // A short read would leave the header overstating the data.
        if written != keep {
            guard written > 0,
                  (try? output.seek(toOffset: 0)) != nil,
                  (try? output.write(contentsOf: header(sampleRate: format.sampleRate,
                                                        dataBytes: written))) != nil
            else { return nil }
        }

        succeeded = true
        return url
    }

    /// What to claim, and it is never the species.
    ///
    /// **OpenBat posts at genus, and offers the species in the description.**
    /// (Niall, 2026-09-04, replacing a rule that claimed the species above 85%
    /// raw confidence.) The reasoning is two things:
    ///
    /// A model's confidence is a softmax output, not a probability of being
    /// right. Both bundled models were trained on recordings from dedicated
    /// detectors, and a phone with a plug-in mic has a different noise profile
    /// — which inflates confidence rather than deflating it. So there is no
    /// honest threshold to draw: 85% did not mean what a threshold needs it to
    /// mean, and any other number would have been equally invented.
    ///
    /// And the costs are asymmetric. iNaturalist moves an observation's
    /// community taxon by agreement, so a wrong species ID needs two people to
    /// disagree with it before it shifts, while a correct genus ID needs one
    /// person to refine it. Under-claiming costs a refinement somebody was
    /// going to make anyway; over-claiming leaves bad species records that
    /// nobody revisits, and those quietly become data.
    ///
    /// Nothing is lost by it: the species, its confidence, the runner-up and
    /// every measurement behind them are in the description, which is where a
    /// suggestion belongs. A human reading it can add the species ID — and then
    /// a person has made the species claim, which is the whole point.
    ///
    /// The ladder, first match wins:
    ///
    ///   1. No ID, or noise                       → Chiroptera
    ///   2. No scientific name to use             → Chiroptera
    ///   3. Ambiguous across more than one genus  → Chiroptera
    ///   4. Anything else                         → GENUS
    ///
    /// **No exceptions per taxon, ever** (Niall, 2026-09-04). There are genera
    /// where the acoustics genuinely do separate the species and a rule that
    /// knew about them could claim more — and that is exactly the change not to
    /// make. This has to hold for every recording every user makes, so it has
    /// to be one rule they can state; a list of special cases is unexplainable
    /// at any scale, impossible to keep right as models and regions are added,
    /// and each entry is an argument nobody can settle. Anything the flat rule
    /// gives up is recoverable by a human from the notes and the pictures.
    ///
    /// **Genus comes from the scientific name, not from a table.** The first
    /// word of a binomial is the genus, and unlike a complex's name it is
    /// always a real iNaturalist taxon that `INatClient.taxonID` can resolve.
    /// The complexes are named for humans — "Myotis species", "Low-frequency
    /// bats" — and posting one of those resolved to nothing at all, leaving the
    /// observation as Unknown.
    private static func taxon(for recording: Recording,
                              passes: [PassRecord],
                              descriptor: ModelDescriptor?) -> (name: String, note: String) {
        let order = "Chiroptera"
        guard !recording.isNoID, recording.species != "NOISE" else {
            return (order, "OpenBat couldn't identify this one, so it's logged only as a bat.")
        }
        guard let scientific = descriptor?.scientificNames[recording.species] else {
            return (order, "No scientific name for \(recording.species) in this model, so it's logged as a bat.")
        }
        let genus = Self.genus(of: scientific)

        // Most complexes are genus-level ambiguity and land on the same answer
        // anyway — Myotis, Pipistrellus, Nyctalus, Plecotus are each one genus,
        // so "we can't separate these" and "genus" agree. Only a complex whose
        // members span genera has to go higher.
        let best = passes.max { $0.confidence < $1.confidence }
        if let best, best.isComplexAmbiguous, let complex = best.complex,
           spansMultipleGenera(complex, descriptor: descriptor) {
            return (order,
                    "The species this most resembles can't be separated acoustically from others in a different genus, so it's logged only as a bat. The suggestion is in the notes.")
        }

        return (genus,
                "\(scientific) is what OpenBat's model suggests, but an acoustic identification isn't strong enough to claim a species on a public record — so this is logged as \(genus), with the suggestion and the measurements in the notes. Narrow it yourself if you're confident.")
    }

    /// The first word of a binomial. A name with no space is already at genus
    /// rank or above and stands as it is.
    private static func genus(of scientificName: String) -> String {
        scientificName.split(separator: " ").first.map(String.init) ?? scientificName
    }

    /// Whether a complex's members sit in more than one genus.
    ///
    /// Worked out from the members' own scientific names rather than recorded
    /// on the complex, so adding a species to a complex cannot leave a stale
    /// answer here. Unknown names are ignored: a complex we can only half
    /// resolve is treated as spanning genera, which is the cautious direction.
    private static func spansMultipleGenera(_ complex: SpeciesComplex,
                                            descriptor: ModelDescriptor?) -> Bool {
        guard let descriptor else { return true }
        let genera = Set(complex.codes.compactMap { descriptor.scientificNames[$0] }.map(genus))
        return genera.count != 1
    }

    /// The notes body. Mirrors the quantities bat2inat writes into its
    /// descriptions (peak/min/max frequency in kHz, call duration in ms, call
    /// count) so the two tools' records are read the same way, and adds the one
    /// thing it has no equivalent of: the RAW confidence.
    ///
    /// **Markdown, because iNaturalist renders it** (Niall, 2026-09-05). The
    /// description used to be a flat wall of lines, which on the observation
    /// page is exactly what it looks like. Three headings and two links cost
    /// nothing and turn it into something that can be skimmed: what the machine
    /// thought, what it measured, and what the reader should be careful of.
    ///
    /// The line breaks matter and are easy to lose. Markdown treats a single
    /// newline as a space, so a run of one-fact-per-line rows would render as
    /// one paragraph — every line inside a block therefore ends with the two
    /// spaces that force a hard break. `markdown(_:)` does that, rather than
    /// each call site remembering to.
    @MainActor
    private static func notes(recording: Recording,
                              passes: [PassRecord],
                              descriptor: ModelDescriptor?,
                              priors: PriorSnapshot?) -> String {
        var lines: [String] = []
        lines.append("**Recorded with OpenBat on iOS.**")
        lines.append("")

        // The model's name links to the post explaining what the two models
        // are and why one recording is only ever seen by one of them. An
        // identifier who has never heard of NABat ML has no way to weigh
        // "NABat ML says Myotis lucifugus" without it, and the alternative is
        // explaining it again in every observation.
        if let model = descriptor {
            lines.append("AutoID Classifier: [\(model.displayName)](\(modelsPostURL))")
        }
        // Spelled out as a SUGGESTION, and with the binomial, because the
        // observation itself is posted at genus — this line is the species
        // claim, and it needs to be findable and unambiguous for whoever
        // decides whether to refine the ID.
        if let scientific = descriptor?.scientificNames[recording.species] {
            lines.append("Suggested species: \(scientific) (\(recording.commonName))")
        } else {
            lines.append("Suggested species: \(recording.commonName) (\(recording.species))")
        }
        if let confidence = recording.confidence {
            lines.append(String(format: "Confidence: %.0f%% (location-weighted)", confidence * 100))
        }
        // The number a reviewer can actually use. The weighted figure has the
        // observer's own location settings baked into it and isn't comparable
        // between people; this is the model's own score for the same species,
        // over the same calls, before any of that.
        //
        // It must be THIS number and not the pass's `rawConfidence`, which is
        // the top score of whatever each call was individually taken for.
        // Printed beside a weighted figure, that one made a record whose
        // weighting had pushed the species UP read as having been pushed down
        // (Niall, 2026-09-05). nil on anything recorded before the field
        // existed, and the line is simply absent — a wrong number is worse than
        // a missing one.
        if let raw = recording.rawSpeciesConfidence {
            lines.append(String(format: "Raw model confidence (before location weighting): %.0f%%", raw * 100))
        }
        if let best = passes.max(by: { $0.confidence < $1.confidence }),
           let runnerUp = best.runnerUpSpecies, let runnerUpConfidence = best.runnerUpConfidence {
            lines.append(String(format: "Next best: %@ (%.0f%%)",
                                SpeciesInfo.commonName[runnerUp] ?? runnerUp, runnerUpConfidence * 100))
        }
        if let complex = passes.compactMap(\.complex).first {
            lines.append("Note: \(complex.name) — species in this group are hard to separate acoustically.")
        }
        lines.append(contentsOf: priorLines(recording: recording, snapshot: priors))

        let pulses = passes.flatMap(\.pulses)
        lines.append("")
        lines.append("**Call Parameters:**")
        lines.append("Calls analysed: \(recording.pulseCount)")
        if !pulses.isEmpty {
            let peaks = pulses.map(\.peakFreqHz).sorted()
            let durations = pulses.map(\.durationMs).sorted()
            lines.append(String(format: "Peak frequency (kHz): %.0f (range %.0f–%.0f)",
                                median(peaks) / 1000, (peaks.first ?? 0) / 1000, (peaks.last ?? 0) / 1000))
            lines.append(String(format: "Call duration (ms): %.1f", median(durations)))
        }
        lines.append(String(format: "Recording length (s): %.1f", recording.durationSeconds))

        lines.append("")
        lines.append("**Notes:**")
        lines.append("Both sounds and every picture here come from the same clip: the bat pass cut out of a longer recording, with a second of air either side. The full spectrum file is that clip exactly as recorded — original 384 kHz, real timing, nothing removed — and the numbered spectrograms are consecutive slices of it, so a time on a picture is the same time in that file. Use that one for any measurement. The other sound is for listening: the same clip with the gaps between calls cut out, the background removed, and played \(expansionFactor)× slower to bring it into hearing range. It is processed audio and is not evidence of anything; the whole-pass picture shows which gaps were cut. Call parameters are produced automatically by OpenBat from the recording. Nothing here has been checked by a person, and the identification suggestion is a best guess by an ML model, please treat all of it as a starting point rather than a result.")
        // The one thing the observation itself cannot say. It is posted at
        // genus deliberately, and without this a reader sees a species in the
        // notes and a genus on the record and reads it as a mistake rather
        // than as an invitation.
        lines.append("")
        lines.append("This observation is deliberately logged at a coarser rank than the suggestion above — an acoustic identification isn't strong enough to claim a species. If you can confirm it, please add the identification.")
        lines.append("")
        lines.append("Thank you for taking time to look at this observation!")
        return markdown(lines)
    }

    /// Where the description's two links go. Both posts exist so the notes can
    /// stay short: the alternative to a link is explaining the same thing on
    /// every observation, or not explaining it at all.
    private static let modelsPostURL = "https://openbat.app/blog/the-two-models-openbat-uses/"
    private static let priorsPostURL = "https://openbat.app/blog/openbat-species-priors-for-location-weighting/"

    /// Joins the description's lines so each one survives as its own line.
    ///
    /// Markdown folds a single newline into a space, so the two-space hard
    /// break goes on every line that has another line directly under it — and
    /// nowhere else, because a trailing hard break before a blank line is a
    /// stray `<br>` above the next heading.
    private static func markdown(_ lines: [String]) -> String {
        lines.enumerated().map { index, line in
            let next = index + 1 < lines.count ? lines[index + 1] : ""
            return line.isEmpty || next.isEmpty ? line : line + "  "
        }.joined(separator: "\n")
    }

    /// What the location weighting actually did, in the description.
    ///
    /// The headline confidence on every OpenBat record is weighted by which
    /// species are plausible where the phone was standing, which makes it
    /// **not comparable between observers** — two people can report the same
    /// call at different confidences. The raw figure above is the comparable
    /// one; these lines are what turns the difference between them from a
    /// mystery into something an identifier can reason about.
    ///
    /// Deliberately not a dump of every species' weight. That would be forty
    /// lines nobody reads; what matters is the weight on the species being
    /// claimed, and how aggressively everything else was pushed down.
    private static func priorLines(recording: Recording, snapshot: PriorSnapshot?) -> [String] {
        guard let snapshot, !snapshot.priors.isEmpty else {
            // Silence would read as "no weighting was applied", which is a
            // different and much stronger claim than "we didn't record it".
            return ["[Location weighting](\(priorsPostURL)): not recorded for this session."]
        }
        var lines: [String] = []
        let own = snapshot.priors[recording.species]
        if let own {
            lines.append(String(format: "[Location weighting](%@): %@ was weighted %.2f (1.00 = fully expected here, 0.01 = effectively ruled out).",
                                priorsPostURL, recording.species, own))
        } else {
            lines.append("[Location weighting](\(priorsPostURL)): no weight recorded for \(recording.species).")
        }
        let downWeighted = snapshot.priors.values.filter { $0 < 0.2 }.count
        lines.append("\(downWeighted) of \(snapshot.priors.count) species in this model were weighted below 0.20 for this location\(snapshot.disabled.isEmpty ? "" : ", and \(snapshot.disabled.count) switched off by the observer").")
        return lines
    }

    /// The individually-copyable rows. Labels match iNaturalist's own field
    /// names where it has one, so there is no translation step for the user.
    @MainActor
    private static func fields(recording: Recording, passes: [PassRecord],
                               detectorMake: String?) -> [INatObservation.Field] {
        var fields: [INatObservation.Field] = []
        let pulses = passes.flatMap(\.pulses)
        if !pulses.isEmpty {
            let peaks = pulses.map(\.peakFreqHz).sorted()
            fields.append(.init(label: "Echolocation call frequency",
                                value: String(format: "%.0f", median(peaks) / 1000),
                                note: "kHz. Median peak frequency across \(pulses.count) calls.",
                                iNatFieldID: INatObservationFields.callFrequency))
        }
        fields.append(.init(label: "Recording method",
                            value: INatObservationFields.method,
                            note: "Full spectrum at 384 kHz — see the note in INatObservationFields.",
                            iNatFieldID: INatObservationFields.recordingMethod))
        fields.append(.init(label: "Bat detector model",
                            value: INatObservationFields.detector(recordedWith: detectorMake),
                            iNatFieldID: INatObservationFields.detectorModel))
        // No established community field for either of these, so they are on
        // the sheet to be copied and nothing more.
        fields.append(.init(label: "Number of calls", value: String(recording.pulseCount)))
        fields.append(.init(label: "Source file", value: recording.relativeWavPath.components(separatedBy: "/").last ?? ""))
        return fields
    }

    private static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    // MARK: The audible copy

    /// Time-expansion by rewriting the sample rate, not by resampling.
    ///
    /// The PCM is copied through untouched and only the header's rate is divided
    /// by `expansionFactor`. That IS time expansion — the same thing a detector's
    /// TE mode does — and it is exact, lossless and instant: no filter, no
    /// interpolation, nothing to get wrong. A 384 kHz recording becomes a
    /// 38.4 kHz one that plays ten times longer, ten octaves-ish lower, in any
    /// browser.
    ///
    /// Returns nil rather than throwing for a file that isn't the canonical
    /// 16-bit mono layout — the original is always attached as well, so a failure
    /// here costs the convenience, not the evidence.
    static func audibleCopy(of source: URL, baseName: String) -> URL? {
        guard let format = WavHeader.describe(url: source), format.isCanonical else { return nil }
        let expanded = UInt32(max(1, Int(format.sampleRate) / expansionFactor))

        guard let input = try? FileHandle(forReadingFrom: source),
              (try? input.seek(toOffset: format.dataOffset)) != nil
        else { return nil }
        defer { try? input.close() }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(baseName)-audible-\(expansionFactor)x.wav")
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let output = try? FileHandle(forWritingTo: url)
        else { return nil }

        var succeeded = false
        defer {
            try? output.close()
            // A half-written WAV is worse than none: it would be attached to an
            // observation and play as a truncated call.
            if !succeeded { try? FileManager.default.removeItem(at: url) }
        }

        guard (try? output.write(contentsOf: header(sampleRate: expanded,
                                                    dataBytes: Int(format.dataBytes)))) != nil
        else { return nil }

        // Streamed rather than read whole. A bout is a few megabytes, but an
        // imported file can be minutes long — at 384 kHz that is hundreds of
        // megabytes, and this runs while the user is looking at a sheet.
        var remaining = Int(format.dataBytes)
        while remaining > 0 {
            let want = min(remaining, 1 << 20)
            guard let block = try? input.read(upToCount: want), !block.isEmpty else { break }
            guard (try? output.write(contentsOf: block)) != nil else { return nil }
            remaining -= block.count
        }
        // A source that read short would leave the header overstating the data.
        if remaining > 0 {
            let written = Int(format.dataBytes) - remaining
            guard written > 0,
                  (try? output.seek(toOffset: 0)) != nil,
                  (try? output.write(contentsOf: header(sampleRate: expanded, dataBytes: written))) != nil
            else { return nil }
        }

        succeeded = true
        return url
    }

    /// Canonical 44-byte header, 16-bit mono — the same layout AudioRecorder
    /// writes, kept local here rather than reaching into the upload pipeline's
    /// private writer.
    private static func header(sampleRate: UInt32, dataBytes: Int) -> Data {
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(le32(UInt32(36 + dataBytes)))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(le32(16))
        header.append(le16(1))                    // PCM
        header.append(le16(1))                    // mono
        header.append(le32(sampleRate))
        header.append(le32(sampleRate * 2))       // byte rate
        header.append(le16(2))                    // block align
        header.append(le16(16))                   // bits
        header.append(contentsOf: Array("data".utf8))
        header.append(le32(UInt32(dataBytes)))
        return header
    }
}
