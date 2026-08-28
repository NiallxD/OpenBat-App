//
//  INatObservation.swift
//  OpenBat
//
//  Prepares everything needed to log one recording as an iNaturalist
//  observation, WITHOUT posting it. OpenBat builds the files and the text; the
//  user completes the observation in iNaturalist's own app.
//
//  WHY NOT POST IT DIRECTLY
//  ------------------------
//  Creating observations through iNaturalist's API needs a registered OAuth
//  application, and registering one is gated on the developer's own iNat
//  account activity. Handing the pieces to the share sheet needs nothing, works
//  today, and has a genuine advantage besides: a human completes every
//  observation in iNat's own UI, so OpenBat's automated ID is a suggestion a
//  person has looked at rather than an unreviewed record posted at scale. That
//  is the failure mode the bat2inat project's README warns about, and this
//  route avoids it by construction.
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
//    • The spectrogram PNG, which is the evidence a reviewer actually reads.
//    • The original WAV, for anyone who wants to re-analyse it.
//

import Foundation
import UIKit
import CoreLocation
import Photos

nonisolated struct INatObservation: Identifiable {
    let id = UUID()
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

    /// How far the audible copy slows the recording down. 10× is the convention
    /// bat detectors have used for decades — a 45 kHz pipistrelle lands at
    /// 4.5 kHz, comfortably inside what a phone speaker and a browser can play,
    /// and anyone used to time-expansion hears it at the speed they expect.
    static let expansionFactor = 10

    // MARK: Building the draft

    /// The text half of the hand-off — cheap, and safe on the main actor.
    /// `ModelRegistry` is main-actor isolated, which is the reason this is too;
    /// the file work is `prepareFiles`, which deliberately isn't.
    @MainActor
    static func draft(recording: Recording, passes: [PassRecord]) -> INatObservation {
        // Resolved from the species code rather than from the user's currently
        // active model: the recording was classified by whichever model knew
        // this code, and that may not be the one selected now.
        let descriptor = ModelRegistry.all.first { $0.scientificNames[recording.species] != nil }
        let taxon = taxon(for: recording, passes: passes, descriptor: descriptor)
        return INatObservation(
            taxonName: taxon.name,
            taxonNote: taxon.note,
            observedOn: Self.dateTime.string(from: recording.date),
            latitude: recording.latitude,
            longitude: recording.longitude,
            notes: notes(recording: recording, passes: passes, descriptor: descriptor),
            fields: fields(recording: recording, passes: passes))
    }

    /// The files to attach, built off the main actor: an audible copy of the
    /// call, the spectrogram, and the original. Slow enough to matter — a long
    /// recording at 384 kHz is tens of megabytes — so this never runs inline.
    static func prepareFiles(wavURL: URL, overviewPNG: Data?) -> [URL] {
        let baseName = wavURL.deletingPathExtension().lastPathComponent
        var files: [URL] = []
        if let audible = audibleCopy(of: wavURL, baseName: baseName) { files.append(audible) }
        if let overviewPNG {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(baseName)-spectrogram.png")
            try? overviewPNG.write(to: url)
            files.append(url)
        }
        files.append(wavURL)
        return files
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
                              descriptor: ModelDescriptor?) -> String {
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
        lines.append("Audio attached is a \(expansionFactor)× time-expanded copy so it's audible; the original ultrasonic WAV is attached too.")
        return lines.joined(separator: "\n")
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
