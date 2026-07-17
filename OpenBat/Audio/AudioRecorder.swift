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

@Observable
final class AudioRecorder: @unchecked Sendable {

    // MARK: UI state (main thread)

    private(set) var isArmed = false
    private(set) var isWriting = false
    private(set) var segmentCount = 0
    private(set) var lastSavedFilename: String?
    /// Sample rate actually written into the most recent recording file.
    private(set) var lastWrittenSampleRate: Double = 0

    // MARK: Config

    var preRollSeconds = 0.3
    var postRollSeconds = 0.5
    var maxSegmentSeconds = 30.0   // safety cap so a noisy environment can't make one huge file

    // MARK: Queue-local state (recorder queue only)

    private let queue = DispatchQueue(label: "bat.AudioRecorder", qos: .userInitiated)
    private var sampleRate: Double = 384_000
    private var armedQ = false
    private var activeQ = false
    private var sessionDirQ: String?     // queue-local: active session's subfolder (nil = Listening)
    // Queue-local metadata for the GUANO chunk written at segment close.
    private var segmentStartDate: Date?
    private var sessionLabelQ = "Listening only"
    private var inputNameQ = "—"
    private var lastCoordinateQ: (lat: Double, lon: Double)?
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

    /// Route recordings into the active session's folder (nil = Listening bucket) and
    /// record the human label embedded as `OpenBat|Session` in each file's GUANO chunk.
    func setActiveSession(id: UUID?, label: String) {
        queue.async { [weak self] in
            self?.sessionDirQ = id?.uuidString
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

    func setArmed(_ on: Bool) {
        isArmed = on
        queue.async { [weak self] in
            guard let self else { return }
            armedQ = on
            if !on { closeSegment(); preRoll.removeAll(keepingCapacity: true) }
        }
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
        segmentStartDate = Date()
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
            write(preRoll)
            writtenSamples += preRoll.count
            preRoll.removeAll(keepingCapacity: true)
        }
        DispatchQueue.main.async { [weak self] in self?.isWriting = true }
    }

    private func closeSegment() {
        guard let h = handle else { return }
        // Append the GUANO metadata chunk after the data chunk, then patch the sizes.
        let guano = makeGuanoChunk(filename: currentURL?.lastPathComponent ?? "")
        try? h.seek(toOffset: UInt64(44 + dataBytes)); try? h.write(contentsOf: guano)   // append after the data chunk
        // RIFF size (offset 4) now spans the data + guano chunks; data size (offset 40)
        // is unchanged.
        try? h.seek(toOffset: 4);  try? h.write(contentsOf: Self.le32(UInt32(36 + dataBytes + guano.count)))
        try? h.seek(toOffset: 40); try? h.write(contentsOf: Self.le32(UInt32(dataBytes)))
        try? h.close()
        handle = nil
        let name = currentURL?.lastPathComponent
        currentURL = nil
        writtenSamples = 0
        dataBytes = 0
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isWriting = false
            if let name { lastSavedFilename = name; segmentCount += 1 }
        }
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
    private func makeGuanoChunk(filename: String) -> Data {
        let sr = sampleRate
        let durationS = sr > 0 ? Double(dataBytes / 2) / sr : 0
        var fields: [GuanoMetadata.Field] = [
            .init("GUANO|Version", "1.0"),
            .init("Make", "OpenBat"),
            .init("Model", inputNameQ),
            .init("Timestamp", Self.iso8601.string(from: segmentStartDate ?? Date())),
            .init("Length", String(format: "%.3f", durationS)),
            .init("Samplerate", String(Int(sr.rounded()))),
            .init("Original Filename", filename),
        ]
        if let c = lastCoordinateQ {
            fields.append(.init("Loc Position",
                                String(format: "%.6f %.6f", c.lat, c.lon), tightColon: true))
        }
        let (species, confidence, pulseCount) = speciesAutoID(segmentStart: segmentStartDate ?? Date())
        fields.append(.init("Species Auto ID", species))
        fields.append(.init("Species Manual ID", ""))
        if let confidence {
            fields.append(.init("OpenBat|Species Confidence", String(format: "%.3f", confidence)))
            fields.append(.init("OpenBat|Species Pulse Count", String(pulseCount)))
        }
        fields.append(.init("OpenBat|Session", sessionLabelQ))
        fields.append(.init("OpenBat|App Version", Self.appVersion))
        fields.append(.init("OpenBat|Host", Self.deviceModel))
        return GuanoMetadata.chunk(fields: fields)
    }

    /// Winning species (GUANO/Wildlife-Acoustics-style code, "NOISE", or "No ID")
    /// across the pulses classified during this segment's time span, plus its mean
    /// confidence and contributing pulse count. Uses the same `PassAggregation` rule
    /// as `PulseDetector.finalizePass` (mean per-pulse raw confidence below 0.57 →
    /// "No ID"; NOISE allowed to win on raw evidence) so a WAV's GUANO tag can't
    /// disagree with what the app itself would report — scoped to just this file's
    /// pulses rather than the whole multi-segment pass. The extra
    /// `minPassConfidence`/`minPassPulseCount` strictness PulseDetector applies on
    /// top (AutoIDSettings, user-tunable) isn't applied here — this is only the
    /// reference pipeline's own NoID/NOISE gate, since AudioRecorder doesn't have
    /// access to the active model's settings.
    private func speciesAutoID(segmentStart: Date) -> (species: String, confidence: Float?, pulseCount: Int) {
        let inSegment = recentClassificationsQ.filter { $0.date >= segmentStart }
        guard !inSegment.isEmpty else { return ("No ID", nil, 0) }

        let pulses = inSegment.map { PassAggregation.Pulse(rawScores: $0.raw, adjustedScores: $0.adjusted) }
        guard let outcome = PassAggregation.aggregate(pulses, minAdjustedConfidence: 0, minPulseCount: 1) else {
            return ("No ID", nil, 0)
        }
        return (outcome.species, outcome.confidence, inSegment.count)
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

    private func makeURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = Self.stampFormatter.string(from: Date())
        // Session passes group under the session id; Listening keeps the dated folders.
        let dir: URL
        if let sid = sessionDirQ {
            dir = docs.appendingPathComponent("Recordings/Sessions/\(sid)", isDirectory: true)
        } else {
            let day = Self.dayFormatter.string(from: Date())
            dir = docs.appendingPathComponent("Recordings/Listening/\(day)", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pass-\(stamp).wav")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH-mm-ss-SSS"; return f
    }()
}
