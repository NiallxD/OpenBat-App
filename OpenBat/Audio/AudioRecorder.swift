//
//  AudioRecorder.swift
//  OpenBat
//
//  Triggered full-spectrum WAV recorder. While armed, audio is only written when
//  a pulse is active (driven by PulseDetector.isInPulse), plus a short pre-roll
//  before and post-roll after — so each bat pass becomes its own .wav and silence
//  isn't recorded (efficient). Files land in Documents/Recordings/<date>/, visible
//  in the Files app (UIFileSharingEnabled is set).
//
//  Threading: append() runs on the realtime audio thread and only copies samples
//  onto a serial queue; all file IO and state live on that queue. UI-facing state
//  is published on the main thread.
//

import AVFoundation
import Accelerate
import Observation
import CoreGraphics
import UIKit

/// Everything ClassificationStore needs to persist a finished, kept segment as a
/// `Recording` — handed back via `AudioRecorder.onRecordingSaved` rather than
/// AudioRecorder building a `Recording` itself, so the recorder stays decoupled from
/// ClassificationStore's model (same pattern as `onPulseClassified` handing back a
/// plain `ClassificationResult` instead of a `PassRecord`).
struct RecordingReport {
    let date: Date
    let durationSeconds: Double
    let species: String
    let confidence: Float?
    let pulseCount: Int
    let sessionID: UUID?
    let coordinate: (lat: Double, lon: Double)?
    /// Relative to the Documents directory — see `Recording.relativeWavPath`.
    let relativeWavPath: String
    let spectrogramImage: UIImage?
}

/// `nonisolated`, matching `HeterodyneProcessor`'s pattern —
/// this project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` would otherwise make
/// `AudioRecorder` implicitly `@MainActor`, but `append(_:)` is called directly from
/// the real-time audio-tap closure (see `ContentView`'s `bufferSink`), and all of the
/// class's actual work already runs on its own serial `queue`. `@Observable`-tracked
/// properties are still safe to read from SwiftUI: every mutation of one is already
/// manually hopped onto `DispatchQueue.main.async` (see `setArmed`, `closeSegment`,
/// etc.) rather than relying on actor isolation for that.
@Observable
nonisolated final class AudioRecorder: @unchecked Sendable {

    // MARK: UI state (main thread)

    private(set) var isArmed = false
    private(set) var isWriting = false
    /// Set while demo mode is feeding a file into the pipeline. Recording is
    /// blocked outright there: a demo pass is not field data, and saving one
    /// would put a synthetic Recording in Sessions — indistinguishable from a
    /// real detection, eligible for upload, and re-feedable into the demo
    /// itself. Drives the record button's disabled state.
    private(set) var isBlocked = false
    private(set) var segmentCount = 0
    private(set) var lastSavedFilename: String?
    /// Sample rate actually written into the most recent recording file.
    private(set) var lastWrittenSampleRate: Double = 0

    /// Fired (on the main thread) each time a segment closes and is kept (i.e. not
    /// rejected as NOISE) — set from ContentView to persist it as a `Recording`.
    var onRecordingSaved: ((RecordingReport) -> Void)?

    // MARK: Config

    /// Pre-trigger buffer kept rolling while idle, so a segment can start with audio
    /// from BEFORE the triggering pulse instead of clipping its onset.
    var preRollSeconds = 3.0
    /// How long to keep a segment open after the last detected pulse before closing
    /// it off — i.e. the silence gap that ends one activity "bout". Reset on every
    /// new pulse while the segment is open, so a bat giving several passes with
    /// gaps shorter than this all land in ONE file instead of fragmenting into many.
    /// User-configurable in Settings (SettingsView's Recording tab).
    var postRollSeconds = 3.0
    var maxSegmentSeconds = 600.0   // safety cap so a very long continuous bout can't make one unbounded file

    // MARK: Queue-local state (recorder queue only)

    private let queue = DispatchQueue(label: "bat.AudioRecorder", qos: .userInitiated)
    private var sampleRate: Double = 384_000
    private var armedQ = false
    private var activeQ = false
    private var blockedQ = false
    private var sessionDirQ: String?     // queue-local: active session's date-stamped subfolder (nil = Listening)
    private var sessionIDQ: UUID?        // queue-local: active session's id, for RecordingReport.sessionID
    // Queue-local metadata for the GUANO chunk written at segment close.
    private var segmentStartDate: Date?
    private var sessionLabelQ = "Listening only"
    private var inputNameQ = "—"
    private var lastCoordinateQ: (lat: Double, lon: Double)?
    // Which model was active when pulses were classified — set from the main thread
    // via `setActiveModel(id:)` whenever AutoIDSettings.activeModelID changes, so
    // `speciesAutoID`'s NoID/NOISE gate can use the SAME model's calibration
    // PulseDetector itself uses, instead of always assuming NABat.
    private var activeModelIDQ: String?
    // User-tunable pass gates (AutoIDSettings.minPassConfidence/minPassPulseCount for
    // the active model) — set from `setPassGates(minConfidence:minPulseCount:)`,
    // pushed from ContentView alongside activeModelID. Without these, a single
    // confidently-scored pulse could tag a whole recording with a species even when
    // the user has set e.g. "min pulses: 2" — a single pulse in a file isn't reliable
    // enough to call a species on its own, same reasoning the in-app pass log
    // (PulseDetector.finalizePass) already applies.
    private var minPassConfidenceQ: Float = 0.05
    private var minPassPulseCountQ: Int = 1
    // Classified pulses land here (from PulseDetector.onPulseClassified) tagged with
    // their capture date, carrying both raw and prior-adjusted scores so
    // `speciesAutoID` can run the same `PassAggregation` rule PulseDetector uses for
    // in-app passes. At segment close we attribute whichever of these fall inside
    // the segment's time span as that file's `Species Auto ID` — classification is
    // async and per-pulse, so it doesn't line up with the recorder's own segment
    // boundaries. Trimmed on every insert so it never grows unbounded.
    private var recentClassificationsQ: [(date: Date, raw: [String: Float], adjusted: [String: Float])] = []
    // We write the WAV manually (RIFF header + 16-bit PCM) rather than via AVAudioFile:
    // AVAudioFile's WAV writer caps at 192 kHz and silently HALVES a 384 kHz capture on
    // write. Writing the header ourselves guarantees the file rate == the capture rate.
    private var handle: FileHandle?
    private var dataBytes: Int = 0            // PCM bytes written to the current file
    private var currentURL: URL?
    private var preRoll: [Float] = []     // rolling pre-trigger buffer
    private var postRollRemaining = 0     // samples left to write after the pulse ends
    private var writtenSamples = 0        // current segment length, for the safety cap

    // MARK: Audio thread

    /// Copy samples off the realtime thread and hand them to the recorder queue.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let sr = buffer.format.sampleRate
        let samples = Array(UnsafeBufferPointer(start: ch, count: n))
        queue.async { [weak self] in self?.handle(samples, sampleRate: sr) }
    }

    // MARK: Control (main thread)

    func toggleArmed() { setArmed(!isArmed) }

    /// Route recordings into the active session's folder (nil = Listening bucket),
    /// record the human label embedded as `OpenBat|Session` in each file's GUANO
    /// chunk, and tag reported Recordings with the session's id. `startDate` names
    /// the folder — date-stamped (e.g. "2026-07-20_21-15-03") rather than the
    /// session's random UUID, so Files-app browsing is meaningful without opening
    /// each folder. Pass nil id/startDate to return to the Listening bucket.
    func setActiveSession(id: UUID?, startDate: Date?, label: String) {
        queue.async { [weak self] in
            self?.sessionIDQ = id
            self?.sessionDirQ = startDate.map { Self.sessionFolderFormatter.string(from: $0) }
            self?.sessionLabelQ = label
        }
    }

    /// Latest GPS fix to embed as `Loc Position` (nil clears it — Listening files get none).
    func setCoordinate(_ coord: (lat: Double, lon: Double)?) {
        queue.async { [weak self] in self?.lastCoordinateQ = coord }
    }

    /// Audio input port name, embedded as the GUANO `Model`.
    func setInputName(_ name: String) {
        queue.async { [weak self] in self?.inputNameQ = name }
    }

    /// Record a single pulse's classification result (wire to
    /// `PulseDetector.onPulseClassified`). Whichever segment is open when the pulse's
    /// date falls inside its span picks this up as its `Species Auto ID` at close.
    func addClassifiedPulse(result: ClassificationResult, date: Date) {
        queue.async { [weak self] in
            guard let self else { return }
            recentClassificationsQ.append((date, result.rawScores, result.allScores))
            // Nothing older than this can still belong to an open segment (maxSegmentSeconds
            // caps how long one can stay open); keep a little slack past that.
            let cutoff = Date().addingTimeInterval(-(maxSegmentSeconds + 5))
            recentClassificationsQ.removeAll { $0.date < cutoff }
        }
    }

    /// Tell the recorder which model is currently active, so `speciesAutoID` gates a
    /// WAV's GUANO species tag with that model's own NoID threshold/noise-class name
    /// rather than always assuming NABat. Call once at startup and again whenever
    /// `AutoIDSettings.activeModelID` changes (see ContentView).
    func setActiveModel(id: String?) {
        queue.async { [weak self] in self?.activeModelIDQ = id }
    }

    /// Push the active model's `AutoIDSettings` pass gates — call once at startup
    /// and again whenever they might have changed (active model switch, or the
    /// Settings sheet closing, since minPassConfidence/minPassPulseCount are
    /// per-model and user-editable there).
    func setPassGates(minConfidence: Float, minPulseCount: Int) {
        queue.async { [weak self] in
            self?.minPassConfidenceQ = minConfidence
            self?.minPassPulseCountQ = minPulseCount
        }
    }

    func setArmed(_ on: Bool) {
        isArmed = on
        queue.async { [weak self] in
            guard let self else { return }
            armedQ = on
            if !on { closeSegment(); preRoll.removeAll(keepingCapacity: true) }
        }
    }

    /// Block or unblock recording wholesale (main thread) — see `isBlocked`.
    /// Blocking disarms and closes any open segment, so switching into demo mode
    /// mid-recording finalises the real file rather than appending demo audio to
    /// it. The queue-local flag in `handle` is the actual backstop; disarming
    /// alone would leave `setPulseActive` able to re-open a segment.
    func setBlocked(_ on: Bool) {
        isBlocked = on
        if on { setArmed(false) }
        queue.async { [weak self] in self?.blockedQ = on }
    }

    /// Drive the trigger from PulseDetector.isInPulse (main thread).
    func setPulseActive(_ active: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            activeQ = active
            if active {
                if armedQ && handle == nil { startSegment() }
                postRollRemaining = Int(postRollSeconds * sampleRate)
            } else if handle != nil {
                postRollRemaining = Int(postRollSeconds * sampleRate)
            }
        }
    }

    /// Audio stopped — close any open segment so the file is finalised.
    func audioStopped() {
        queue.async { [weak self] in self?.closeSegment() }
    }

    // MARK: Queue work

    private func handle(_ samples: [Float], sampleRate sr: Double) {
        sampleRate = sr

        // Demo mode: drop the audio entirely rather than just refusing to open a
        // segment — otherwise the pre-roll below would sit there accumulating
        // seconds of demo audio, ready to be written into the first real
        // recording made after the demo ends.
        guard !blockedQ else { return }

        guard handle != nil else {
            // Idle: keep a rolling pre-roll so a segment can start mid-buffer.
            let cap = Int(preRollSeconds * sr)
            preRoll.append(contentsOf: samples)
            if preRoll.count > cap { preRoll.removeFirst(preRoll.count - cap) }
            return
        }

        write(samples)
        writtenSamples += samples.count

        if !activeQ {
            postRollRemaining -= samples.count
            if postRollRemaining <= 0 { closeSegment(); return }
        }
        // Safety cap: rotate to a fresh file if a segment runs very long.
        if writtenSamples >= Int(maxSegmentSeconds * sampleRate) {
            closeSegment()
            if armedQ && activeQ { startSegment() }
        }
    }

    private func startSegment() {
        let triggerDate = Date()
        let url = makeURL()
        let sr = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        // Write a 44-byte WAV header with placeholder sizes; patched on close.
        try? h.write(contentsOf: Self.wavHeader(sampleRate: UInt32(sr), dataBytes: 0))
        handle = h
        dataBytes = 0
        currentURL = url
        DispatchQueue.main.async { [weak self] in self?.lastWrittenSampleRate = sr }
        writtenSamples = 0
        postRollRemaining = Int(postRollSeconds * sr)

        if !preRoll.isEmpty {
            // segmentStartDate must be the timestamp of the file's actual FIRST
            // sample, not the trigger moment — the pre-roll pushes real audio
            // earlier than the trigger. Getting this wrong shifted every
            // Recording's reported start (and its `passes(forRecording:)` time
            // window in ClassificationStore) later than the file's true content by
            // ~preRollSeconds, which could both exclude pulses that are audibly IN
            // the file and bleed into the next recording's window.
            segmentStartDate = triggerDate.addingTimeInterval(-Double(preRoll.count) / sr)
            write(preRoll)
            writtenSamples += preRoll.count
            preRoll.removeAll(keepingCapacity: true)
        } else {
            segmentStartDate = triggerDate
        }
        DispatchQueue.main.async { [weak self] in self?.isWriting = true }
    }

    private func closeSegment() {
        guard let h = handle, let url = currentURL else { return }

        // A segment can close with zero PCM bytes written (e.g. armed/stopped again
        // before any samples made it through, or a trigger whose post-roll write
        // never actually ran) — discard rather than hand back an unreadable,
        // headers-only WAV that Files/other apps can't play.
        guard dataBytes > 0 else { discardSegment(handle: h, url: url); return }

        let outcome = speciesAutoID(segmentStart: segmentStartDate ?? Date(), segmentEnd: Date())

        // NOISE is the model's own confident "not a bat" call — reject it outright
        // rather than saving a WAV nobody will want. Every other outcome (a real
        // species OR "couldn't be classified") is kept: only NOISE is discarded.
        guard case .noise = outcome else {
            try? closeAndKeep(handle: h, url: url, outcome: outcome)
            return
        }
        discardSegment(handle: h, url: url)
    }

    private func discardSegment(handle h: FileHandle, url: URL) {
        try? h.close()
        try? FileManager.default.removeItem(at: url)
        handle = nil
        currentURL = nil
        writtenSamples = 0
        dataBytes = 0
        DispatchQueue.main.async { [weak self] in self?.isWriting = false }
    }

    /// Appends the GUANO chunk, patches the RIFF/data sizes, closes the file handle,
    /// renames the file to its final `<stamp>_<SPECIES>.wav` form now that the
    /// segment's classification outcome is known, then renders its spectrogram and
    /// reports the finished `Recording` back via `onRecordingSaved`.
    private func closeAndKeep(handle h: FileHandle, url: URL, outcome: AutoIDOutcome) throws {
        let finalURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_\(Self.filenameSuffix(for: outcome)).wav")
        let guano = makeGuanoChunk(filename: finalURL.lastPathComponent, outcome: outcome)
        try? h.seek(toOffset: UInt64(44 + dataBytes)); try? h.write(contentsOf: guano)   // append after the data chunk
        // RIFF size (offset 4) now spans the data + guano chunks; data size (offset 40)
        // is unchanged.
        try? h.seek(toOffset: 4);  try? h.write(contentsOf: Self.le32(UInt32(36 + dataBytes + guano.count)))
        try? h.seek(toOffset: 40); try? h.write(contentsOf: Self.le32(UInt32(dataBytes)))
        try? h.close()
        try? FileManager.default.moveItem(at: url, to: finalURL)
        handle = nil
        currentURL = nil
        let closedDataBytes = dataBytes
        let sr = sampleRate
        writtenSamples = 0
        dataBytes = 0
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isWriting = false
            lastSavedFilename = finalURL.lastPathComponent
            segmentCount += 1
        }

        // Spectrogram render + report run on THIS (recorder) queue too — real file
        // IO and FFT work, kept off the audio-thread-adjacent main-thread hop above.
        let docs = CloudStorage.baseDirectory
        let relativePath = String(finalURL.path.dropFirst(docs.path.count + 1))
        // maxWidth 4096 matches what WavSpectrogramEngine.renderOverview
        // requests for its fallback (non-cached) render path — keeping this
        // cached render at the same resolution means the WAV player's reuse
        // of this cache (see WavSpectrogramEngine.renderOverview) doesn't
        // trade away overview sharpness to save the render time.
        let image = RecordingSpectrogramRenderer.render(wavURL: finalURL, maxWidth: 4096)
        let (species, confidence, pulseCount): (String, Float?, Int)
        switch outcome {
        case .species(let code, let conf, let count): (species, confidence, pulseCount) = (code, conf, count)
        case .noID(let count): (species, confidence, pulseCount) = ("NOID", nil, count)
        case .noise: (species, confidence, pulseCount) = ("NOISE", nil, 0)   // unreachable — rejected before this is called
        }
        let report = RecordingReport(
            date: segmentStartDate ?? Date(),
            durationSeconds: sr > 0 ? Double(closedDataBytes / 2) / sr : 0,
            species: species, confidence: confidence, pulseCount: pulseCount,
            sessionID: sessionIDQ, coordinate: lastCoordinateQ,
            relativeWavPath: relativePath, spectrogramImage: image)
        DispatchQueue.main.async { [weak self] in self?.onRecordingSaved?(report) }
    }

    // Reused scratch for the vectorised float→Int16 conversion in write().
    private var floatScratch: [Float] = []
    private var pcm16Scratch: [Int16] = []

    private func write(_ samples: [Float]) {
        guard let handle else { return }
        // Float32 [-1,1] → 16-bit PCM via vDSP (clip, scale, truncate). iOS is
        // little-endian, so the Int16 buffer's raw bytes are already WAV byte order.
        let n = samples.count
        if floatScratch.count < n { floatScratch = [Float](repeating: 0, count: n) }
        if pcm16Scratch.count < n { pcm16Scratch = [Int16](repeating: 0, count: n) }
        var lo: Float = -1, hi: Float = 1, scale: Float = 32767
        samples.withUnsafeBufferPointer { src in
            vDSP_vclip(src.baseAddress!, 1, &lo, &hi, &floatScratch, 1, vDSP_Length(n))
        }
        vDSP_vsmul(floatScratch, 1, &scale, &floatScratch, 1, vDSP_Length(n))
        let data = pcm16Scratch.withUnsafeMutableBufferPointer { dst -> Data in
            vDSP_vfix16(floatScratch, 1, dst.baseAddress!, 1, vDSP_Length(n))
            return Data(bytes: dst.baseAddress!, count: n * 2)
        }
        try? handle.write(contentsOf: data)
        dataBytes += n * 2
    }

    // MARK: GUANO metadata

    /// Build the GUANO chunk for the segment being closed, from queue-local context.
    private func makeGuanoChunk(filename: String, outcome: AutoIDOutcome) -> Data {
        let sr = sampleRate
        let durationS = sr > 0 ? Double(dataBytes / 2) / sr : 0
        // GUANO Make/Model describe the recording HARDWARE, not the app:
        // `Make` is the ultrasonic input device (the Griff mic's detected
        // port name — the closest thing to a hardware name we have; falls
        // back to the host model if no external device was named), `Model`
        // is the host iPhone. The APP goes in `Firmware Version` (GUANO's
        // conventional slot for recording software), so downstream tools and
        // the in-app File Info card read "OpenBat …" as the app rather than
        // as the device. (An earlier version set `Make: OpenBat`, conflating
        // the app into the device make.)
        let hardwareName = inputNameQ == "—" ? Self.deviceModel : inputNameQ
        var fields: [GuanoMetadata.Field] = [
            .init("GUANO|Version", "1.0"),
            .init("Make", hardwareName),
            .init("Model", Self.deviceModel),
            .init("Firmware Version", "OpenBat \(Self.appVersion)"),
            .init("Timestamp", Self.iso8601.string(from: segmentStartDate ?? Date())),
            .init("Length", String(format: "%.3f", durationS)),
            .init("Samplerate", String(Int(sr.rounded()))),
            .init("Original Filename", filename),
        ]
        if let c = lastCoordinateQ {
            fields.append(.init("Loc Position",
                                String(format: "%.6f %.6f", c.lat, c.lon), tightColon: true))
        }
        switch outcome {
        case .species(let code, let confidence, let pulseCount):
            fields.append(.init("Species Auto ID", code))
            fields.append(.init("OpenBat|Species Confidence", String(format: "%.3f", confidence)))
            fields.append(.init("OpenBat|Species Pulse Count", String(pulseCount)))
        case .noID(let pulseCount):
            fields.append(.init("Species Auto ID", "No ID"))
            fields.append(.init("OpenBat|Species Pulse Count", String(pulseCount)))
        case .noise:
            fields.append(.init("Species Auto ID", "NOISE"))   // unreachable — rejected before this is called
        }
        fields.append(.init("Species Manual ID", ""))
        fields.append(.init("OpenBat|AutoID Model", ModelRegistry.descriptor(id: activeModelIDQ)?.displayName ?? "None"))
        fields.append(.init("OpenBat|Session", sessionLabelQ))
        fields.append(.init("OpenBat|App Version", Self.appVersion))
        fields.append(.init("OpenBat|Host", Self.deviceModel))
        return GuanoMetadata.chunk(fields: fields)
    }

    /// A segment's classified outcome, aggregated across every pulse whose date falls
    /// inside its time span — same `PassAggregation` rule `PulseDetector.finalizePass`
    /// uses, so a WAV's GUANO species tag/filename can't disagree with what the app
    /// itself would report for the active model. `.noise` is REJECTED (deleted, not
    /// saved) at close — every other outcome, including `.noID`, is kept: a triggered
    /// pulse that couldn't be classified is still evidence something happened, and
    /// only the model's own "definitely not a bat" call is discarded.
    enum AutoIDOutcome {
        case species(code: String, confidence: Float, pulseCount: Int)
        /// `pulseCount` is however many pulses WERE classified during the segment
        /// (0 when none were — e.g. recording armed with no AutoID model active, or
        /// classification just didn't keep up) — never assume it's 0.
        case noID(pulseCount: Int)
        case noise
    }

    /// Winning outcome across the pulses classified during this segment's time span.
    /// Gated with whichever model's `noidRawConfidenceThreshold`/`noiseClassName` was
    /// active when these pulses were classified (see `setActiveModel(id:)`). Falls
    /// back to NABat's calibration if no model is set (matches the prior, model-blind
    /// behavior). The extra `minPassConfidence`/`minPassPulseCount` strictness
    /// PulseDetector applies on top (AutoIDSettings, user-tunable) isn't applied here
    /// either — this is only the reference pipeline's own NoID/NOISE gate.
    ///
    /// `segmentEnd` bounds the window from above (not just `segmentStart` from
    /// below): when pre-roll (up to 5s) exceeds post-roll (down to 1s), the next
    /// segment's retroactive `segmentStartDate` can land BEFORE this segment's own
    /// tail pulses, and an unbounded `>= segmentStart` filter would double-count
    /// them into both segments. Consumed pulses (anything `<= segmentEnd`) are then
    /// dropped from the queue so a later segment can never reclaim them.
    private func speciesAutoID(segmentStart: Date, segmentEnd: Date) -> AutoIDOutcome {
        let inSegment = recentClassificationsQ.filter { $0.date >= segmentStart && $0.date <= segmentEnd }
        recentClassificationsQ.removeAll { $0.date <= segmentEnd }
        guard !inSegment.isEmpty else { return .noID(pulseCount: 0) }

        let descriptor = ModelRegistry.descriptor(id: activeModelIDQ)
        // NOT `descriptor?.noiseClassName ?? "NOISE"` — that would silently overwrite
        // BatDetect2's deliberate `nil` (no noise class) with "NOISE". `.map` preserves
        // the distinction between "no descriptor found" (fall back to "NOISE") and
        // "descriptor found, and it has no noise class".
        let noiseClassName: String? = descriptor.map { $0.noiseClassName } ?? "NOISE"
        let pulses = inSegment.map { PassAggregation.Pulse(rawScores: $0.raw, adjustedScores: $0.adjusted) }
        guard let outcome = PassAggregation.aggregate(
            pulses,
            minAdjustedConfidence: minPassConfidenceQ,
            minPulseCount: minPassPulseCountQ,
            rawConfidenceThreshold: descriptor?.noidRawConfidenceThreshold ?? PassAggregation.noidRawConfidenceThreshold,
            noiseClassName: noiseClassName
        ) else {
            // Real evidence exists (inSegment isn't empty) — either the raw-confidence
            // gate wasn't cleared, or it was but the user's own minPassConfidence/
            // minPassPulseCount gate wasn't (e.g. a single pulse when min pulses = 2).
            // Report the actual count either way, not 0.
            return .noID(pulseCount: inSegment.count)
        }
        if let noiseClassName, outcome.species == noiseClassName { return .noise }
        return .species(code: outcome.species, confidence: outcome.confidence, pulseCount: inSegment.count)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let appVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"

    private static let deviceModel: String = {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }()

    // MARK: WAV header

    private static func wavHeader(sampleRate: UInt32, dataBytes: UInt32) -> Data {
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bits / 8)
        let blockAlign = channels * (bits / 8)
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(le32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(le32(16))            // PCM fmt chunk size
        d.append(le16(1))             // audio format = PCM
        d.append(le16(channels))
        d.append(le32(sampleRate))
        d.append(le32(byteRate))
        d.append(le16(blockAlign))
        d.append(le16(bits))
        d.append(contentsOf: Array("data".utf8))
        d.append(le32(dataBytes))
        return d
    }

    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    /// Working filename while a segment is being written — species isn't known until
    /// classification results for the whole bout are aggregated at close, so this is
    /// renamed to its final `<stamp>_<SPECIES>.wav` form in `closeSegment()`.
    private func makeURL() -> URL {
        let docs = CloudStorage.baseDirectory
        let stamp = Self.stampFormatter.string(from: Date())
        // Session passes group under the session's own date-stamped folder; Listening
        // keeps the dated day folders.
        let dir: URL
        if let sessionDir = sessionDirQ {
            dir = docs.appendingPathComponent("Recordings/Sessions/\(sessionDir)", isDirectory: true)
        } else {
            let day = Self.dayFormatter.string(from: Date())
            dir = docs.appendingPathComponent("Recordings/Listening/\(day)", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(stamp).wav")
    }

    /// Species code suffix for the final filename — filesystem-safe by construction
    /// (species codes are short uppercase letters, "NOISE" is rejected before this is
    /// ever called, and "No ID" has no code to sanitize).
    private static func filenameSuffix(for outcome: AutoIDOutcome) -> String {
        switch outcome {
        case .species(let code, _, _): return code
        case .noID: return "NoID"
        case .noise: return "NOISE"   // unreachable — rejected before renaming
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    /// Filename stamp: date AND time, so a WAV is identifiable on its own once pulled
    /// out of its folder (e.g. shared individually), not just relative to its parent.
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"; return f
    }()
    /// Session folder name — date-stamped instead of the session's UUID (Files-app
    /// browsing should be meaningful without opening each folder).
    static let sessionFolderFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; return f
    }()
}
