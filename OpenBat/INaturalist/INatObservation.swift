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
//  spectrogram go in together. Saving the spectrogram to Photos is kept as a
//  secondary path for anyone who would rather work in the app — it can pick a
//  photo out of the library — but that posts the call without its sound, which
//  is why it is not the one offered first.
//
//  Video is not an escape hatch: iNaturalist accepts images and audio only, so
//  a spectrogram video would save to Photos and then be refused on upload.
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
import Photos

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
    }

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

nonisolated enum INatExport {

    /// How far the audible copy slows the recording down.
    ///
    /// 16×, matching the slowest speed OpenBat's own player offers, so a call
    /// sounds the same on iNaturalist as it did in the app. It also divides
    /// 384 kHz exactly, to 24 kHz — a rate every browser plays without
    /// resampling. A 45 kHz pipistrelle lands at 2.8 kHz, low enough to hear
    /// the structure of the call rather than a chirp.
    static let expansionFactor = 16

    // MARK: Building the draft

    /// The text half of the hand-off — cheap, and safe on the main actor.
    /// `ModelRegistry` is main-actor isolated, which is the reason this is too;
    /// the file work is `prepareFiles`, which deliberately isn't.
    @MainActor
    static func draft(recording: Recording,
                      passes: [PassRecord],
                      priors: PriorSnapshot? = nil) -> INatObservation {
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
            fields: fields(recording: recording, passes: passes))
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
        /// The recording exactly as it sits on disk. Offered to the share
        /// sheet, where somebody may want the whole thing, and never uploaded.
        var original: URL
        /// The calls with the silence cut off either side, which is what
        /// actually goes to iNaturalist. Falls back to `original` when there
        /// was nothing to trim or the trim failed.
        var upload: URL

        /// Everything there is, in the order the hand-off sheet offers them.
        var all: [URL] { [audible].compactMap { $0 } + photos + [original] }

        /// What goes to `/observation_sounds`. The audible copy leads because
        /// it is the one a reviewer can actually play in a browser.
        var sounds: [URL] { [audible, upload].compactMap { $0 } }

        /// What the size limit and the upload score are judged against — both
        /// attachments are the same length, so one figure covers them.
        var uploadBytes: Int {
            (try? FileManager.default.attributesOfItem(atPath: upload.path)[.size] as? Int)
                .flatMap { $0 } ?? 0
        }
    }

    /// Built off the main actor: the calls trimmed out of the recording, an
    /// audible copy of them, and the spectrogram. Slow enough to matter — a
    /// long recording at 384 kHz is tens of megabytes — so this never runs
    /// inline.
    static func prepareFiles(wavURL: URL,
                             recordingStart: Date,
                             pulses: [PulseRecord]) -> Files {
        let baseName = wavURL.deletingPathExtension().lastPathComponent
        var files = Files(original: wavURL, upload: wavURL)
        if let trimmed = trimmedToCalls(source: wavURL,
                                        recordingStart: recordingStart,
                                        pulses: pulses,
                                        baseName: baseName) {
            files.upload = trimmed
        }
        // Derived from the trimmed file, not the original: otherwise the small
        // upload would be paired with a full-length audible copy, and the
        // 20 MB limit would still bite on the file people actually play.
        files.audible = audibleCopy(of: files.upload, baseName: baseName)
        return files
    }

    // MARK: Trimming

    /// How much recording to keep either side of the outermost call.
    ///
    /// Not zero: a call clipped hard at the first sample looks truncated on a
    /// spectrogram and sounds wrong, and an identifier needs to see that
    /// nothing was cut off mid-pulse. A third of a second is enough context to
    /// show the call is complete without carrying the bout's dead air.
    static let trimPaddingSeconds = 0.33

    /// Cuts the recording down to the span the calls actually occupy.
    ///
    /// A bout is mostly silence — the detector keeps a pre-roll and runs on
    /// past the last call — and at 384 kHz, silence costs the same 768 kB a
    /// second as a bat does. Trimming is what keeps a real recording under
    /// iNaturalist's 20 MB sound limit, and it makes the observation quicker
    /// to load for everyone who opens it.
    ///
    /// This trims by the PULSE TIMESTAMPS the classifier already produced, not
    /// by hunting for energy in the samples: the app has already decided where
    /// the calls are, and a second, differently-tuned opinion about that in the
    /// export path is a bug waiting to happen. It also means a recording whose
    /// calls span the whole file is correctly left alone.
    ///
    /// Returns nil when there is nothing to gain — no pulses, an unreadable or
    /// non-canonical file, or a trim that would save almost nothing — and the
    /// caller falls back to the original.
    static func trimmedToCalls(source: URL,
                               recordingStart: Date,
                               pulses: [PulseRecord],
                               baseName: String) -> URL? {
        guard !pulses.isEmpty,
              let format = WavHeader.describe(url: source), format.isCanonical else { return nil }

        let bytesPerSample = 2  // canonical: 16-bit mono
        let totalSeconds = Double(format.dataBytes) / Double(format.sampleRate) / Double(bytesPerSample)

        let offsets = pulses.map { $0.date.timeIntervalSince(recordingStart) }
        let firstCall = offsets.min() ?? 0
        // Each pulse's timestamp is its start, so the last call ends a pulse
        // length later. Taking the longest is cheaper than pairing them up and
        // errs towards keeping more.
        let longestPulse = (pulses.map(\.durationMs).max() ?? 0) / 1000
        let lastCall = (offsets.max() ?? totalSeconds) + longestPulse

        let start = max(0, firstCall - trimPaddingSeconds)
        let end = min(totalSeconds, lastCall + trimPaddingSeconds)
        guard end > start else { return nil }

        // Pulse timestamps come from a different clock to the file's own
        // length, and a bad one could ask for a span longer than the file.
        // Nothing to cut means nothing to do.
        guard (end - start) < totalSeconds * 0.95 else { return nil }

        let startByte = UInt64(start * Double(format.sampleRate)) * UInt64(bytesPerSample)
        let endByte = UInt64(end * Double(format.sampleRate)) * UInt64(bytesPerSample)
        let keep = Int(min(endByte, UInt64(format.dataBytes)) - min(startByte, endByte))
        guard keep > 0 else { return nil }

        guard let input = try? FileHandle(forReadingFrom: source),
              (try? input.seek(toOffset: format.dataOffset + startByte)) != nil
        else { return nil }
        defer { try? input.close() }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(baseName)-calls.wav")
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

    /// What to claim, and it is often not the species.
    ///
    /// OpenBat's ID is a model's opinion weighted by where the phone is, and iNat
    /// is a permanent public record that other people's research draws on. So the
    /// rule is to claim the most specific rank the evidence actually supports:
    /// an ambiguous complex goes up to the complex, a weak or absent ID goes all
    /// the way up to Chiroptera. Someone who knows better can always refine it in
    /// iNat — which is what iNat is for — but an over-claimed ID that nobody
    /// revisits quietly becomes data.
    @MainActor
    private static func taxon(for recording: Recording,
                              passes: [PassRecord],
                              descriptor: ModelDescriptor?) -> (name: String, note: String) {
        let order = "Chiroptera"
        guard !recording.isNoID, recording.species != "NOISE" else {
            return (order, "OpenBat couldn't identify this one, so it's logged only as a bat.")
        }
        let best = passes.max { ($0.confidence) < ($1.confidence) }
        if let best, best.isComplexAmbiguous, let complex = best.complex {
            return (complex.name,
                    "Two species in this group scored close together, so this is logged at group level rather than picking one.")
        }
        guard let scientific = descriptor?.scientificNames[recording.species] else {
            return (order, "No scientific name for \(recording.species) in this model, so it's logged as a bat.")
        }
        if let confidence = recording.confidence, confidence < 0.6 {
            return (order,
                    String(format: "OpenBat suggests %@ but only at %.0f%%, which is too weak to claim. Change this if you're confident.",
                           scientific, confidence * 100))
        }
        return (scientific, "OpenBat's identification. Check it before you post — you're the one making the claim.")
    }

    /// The notes body. Mirrors the quantities bat2inat writes into its
    /// descriptions (peak/min/max frequency in kHz, call duration in ms, call
    /// count) so the two tools' records are read the same way, and adds the one
    /// thing it has no equivalent of: the RAW confidence.
    @MainActor
    private static func notes(recording: Recording,
                              passes: [PassRecord],
                              descriptor: ModelDescriptor?,
                              priors: PriorSnapshot?) -> String {
        var lines: [String] = []
        lines.append("Recorded with OpenBat on iOS.")

        if let model = descriptor {
            lines.append("Classifier: \(model.displayName)")
        }
        lines.append("Automated ID: \(recording.commonName) (\(recording.species))")
        if let confidence = recording.confidence {
            lines.append(String(format: "Confidence: %.0f%% (location-weighted)", confidence * 100))
        }
        // The number a reviewer can actually use. The adjusted figure has the
        // observer's own location settings baked into it and isn't comparable
        // between people; the raw score is the model's own, unweighted.
        let raws = passes.compactMap(\.rawConfidence)
        if !raws.isEmpty {
            let mean = raws.reduce(0, +) / Float(raws.count)
            lines.append(String(format: "Raw model confidence (before location weighting): %.0f%%", mean * 100))
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
        lines.append("Audio attached is slowed \(expansionFactor)× so it is audible — a \(expansionFactor)× time-expanded copy, with the silence either side of the calls removed. The same trimmed audio is attached at its original ultrasonic sample rate for re-analysis.")
        lines.append("")
        lines.append("These measurements are produced automatically by OpenBat from the recording. Nothing here has been checked by a person, and the identification is a model's opinion — please treat all of it as a starting point rather than a result.")
        return lines.joined(separator: "\n")
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
            return ["Location weighting: not recorded for this session."]
        }
        var lines: [String] = []
        let own = snapshot.priors[recording.species]
        if let own {
            lines.append(String(format: "Location weighting: %@ was weighted %.2f (1.00 = fully expected here, 0.01 = effectively ruled out).",
                                recording.species, own))
        } else {
            lines.append("Location weighting: no weight recorded for \(recording.species).")
        }
        let downWeighted = snapshot.priors.values.filter { $0 < 0.2 }.count
        lines.append("\(downWeighted) of \(snapshot.priors.count) species in this model were weighted below 0.20 for this location\(snapshot.disabled.isEmpty ? "" : ", and \(snapshot.disabled.count) switched off by the observer").")
        return lines
    }

    /// The individually-copyable rows. Labels match iNaturalist's own field
    /// names where it has one, so there is no translation step for the user.
    @MainActor
    private static func fields(recording: Recording, passes: [PassRecord]) -> [INatObservation.Field] {
        var fields: [INatObservation.Field] = []
        let pulses = passes.flatMap(\.pulses)
        if !pulses.isEmpty {
            let peaks = pulses.map(\.peakFreqHz).sorted()
            fields.append(.init(label: "Frequency (kHz)",
                                value: String(format: "%.0f", median(peaks) / 1000),
                                note: "Median peak frequency across \(pulses.count) calls."))
        }
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

    // MARK: Photos

    /// Puts the spectrogram in the photo library, which is the only door the
    /// iNaturalist iOS app opens to another app's files (see the note at the top
    /// of this file).
    ///
    /// Add-only authorisation: OpenBat never reads the library, and asking for
    /// read access to write one image would be asking for far more than the
    /// feature needs.
    static func saveSpectrogramToPhotos(_ png: Data) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: png, options: nil)
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

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
