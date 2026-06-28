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
        // Patch RIFF chunk size (offset 4) and data chunk size (offset 40).
        try? h.seek(toOffset: 4);  h.write(Self.le32(UInt32(36 + dataBytes)))
        try? h.seek(toOffset: 40); h.write(Self.le32(UInt32(dataBytes)))
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

    private func write(_ samples: [Float]) {
        guard let handle else { return }
        // Float32 [-1,1] → little-endian 16-bit PCM.
        var bytes = [UInt8]()
        bytes.reserveCapacity(samples.count * 2)
        for s in samples {
            let clamped = max(-1, min(1, s))
            let u = UInt16(bitPattern: Int16(clamped * 32767))
            bytes.append(UInt8(u & 0xFF))
            bytes.append(UInt8(u >> 8))
        }
        handle.write(Data(bytes))
        dataBytes += bytes.count
    }

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
        let day = Self.dayFormatter.string(from: Date())
        let stamp = Self.stampFormatter.string(from: Date())
        let dir = docs.appendingPathComponent("Recordings/\(day)", isDirectory: true)
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
