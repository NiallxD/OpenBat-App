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
import Synchronization   // Atomic, for the capture hand-off ring
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
    /// Message from the most recent failed PCM write, or nil. Surfaced so a
    /// segment discarded for a write failure (a full disk, most likely) says so
    /// somewhere instead of a recording simply never appearing — the same
    /// reasoning as `PulseHaptics.unavailableReason`: a silent stop reads
    /// exactly like "the bats stopped". Shown in Diagnostics.
    private(set) var lastWriteError: String? {
        didSet {
            guard lastWriteError != nil else { return }
            let message = lastWriteError
            DispatchQueue.main.async { [weak self] in self?.writeErrorForDisplay = message }
        }
    }
    /// Main-actor mirror of `lastWriteError` for the UI to read — `lastWriteError`
    /// itself is written on the recorder queue.
    private(set) var writeErrorForDisplay: String?

    /// Fired (on the main thread) each time a segment closes and is kept (i.e. not
    /// rejected as NOISE) — set from ContentView to persist it as a `Recording`.
    var onRecordingSaved: ((RecordingReport) -> Void)?

    // MARK: Config

    // These three are bound straight into Settings sliders, i.e. written on the
    // main thread, and every consumer of them runs on the recorder queue. They
    // are therefore mirrored into queue-local copies (`…Q`) on write rather than
    // read across threads — the same discipline `setPassGates`/`setCoordinate`
    // already follow, and the one the DSP processors get from `ctrlLock`. Reading
    // an `@Observable` stored property from another thread synchronises nothing:
    // the registrar is thread-safe, the stored value is not.
    //
    // Read `preRollSecondsQ` / `postRollSecondsQ` / `maxSegmentSecondsQ` on the
    // queue; never these.

    /// Longest pre-roll the Settings slider offers — the ring is sized for this
    /// so the setting can move without reallocating. Keep in step with
    /// `SettingsView`'s slider range.
    static let maxPreRollSeconds = 5.0

    /// Pre-trigger buffer kept rolling while idle, so a segment can start with audio
    /// from BEFORE the triggering pulse instead of clipping its onset.
    var preRollSeconds = 3.0 {
        didSet { let v = preRollSeconds; queue.async { [weak self] in self?.preRollSecondsQ = v } }
    }
    /// How long to keep a segment open after the last detected pulse before closing
    /// it off — i.e. the silence gap that ends one activity "bout". Reset on every
    /// new pulse while the segment is open, so a bat giving several passes with
    /// gaps shorter than this all land in ONE file instead of fragmenting into many.
    /// User-configurable in Settings (the Detecting tab, "Length of a recording").
    var postRollSeconds = 3.0 {
        didSet { let v = postRollSeconds; queue.async { [weak self] in self?.postRollSecondsQ = v } }
    }
    /// Safety cap so a very long continuous bout can't make one unbounded file.
    var maxSegmentSeconds = 600.0 {
        didSet { let v = maxSegmentSeconds; queue.async { [weak self] in self?.maxSegmentSecondsQ = v } }
    }

    // MARK: Queue-local state (recorder queue only)

    private let queue = DispatchQueue(label: "bat.AudioRecorder", qos: .userInitiated)
    /// Where a closed segment's whole-file spectrogram render happens. Separate
    /// from `queue` on purpose — see `closeAndKeep`: `queue` drains the capture
    /// ring, and a multi-second render there drops live audio. Serial, so a burst
    /// of short segments renders one at a time rather than spawning a thread each.
    private let reportQueue = DispatchQueue(label: "bat.AudioRecorder.report", qos: .utility)
    private var sampleRate: Double = 384_000
    /// Queue-local mirrors of the three Settings-bound timings above. Defaults
    /// must match theirs — nothing writes them until the user first moves a slider.
    private var preRollSecondsQ = 3.0
    private var postRollSecondsQ = 3.0
    private var maxSegmentSecondsQ = 600.0
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
    /// Set by `write` when a PCM write fails; condemns the current segment. Reset
    /// per segment in `openSegment`, not globally — one bad segment must not
    /// poison the next, and the disk may well have been freed in between.
    private var segmentWriteFailed = false
    private var currentURL: URL?
    private var postRollRemaining = 0     // samples left to write after the pulse ends
    private var writtenSamples = 0        // current segment length, for the safety cap

    // MARK: Pre-roll ring (recorder queue only)
    //
    // The rolling pre-trigger buffer is a fixed ring, not an array trimmed from
    // the front. It used to be `preRoll.append(contentsOf:)` followed by
    // `preRoll.removeFirst(overflow)` — and removing from the front of an Array
    // shifts everything behind it. At 384 kHz a 3 s pre-roll is 4.6 MB, shifted
    // once per capture callback (~188/s), i.e. of the order of 800 MB/s of pure
    // memmove on a `.userInitiated` queue, running continuously whenever capture
    // was up — armed or not, since only demo mode gates this path. A ring makes
    // it two memcpys of the incoming buffer instead, independent of pre-roll
    // length.
    //
    // Kept running while disarmed, deliberately: with the ring the cost is
    // negligible, and skipping it would mean arming just as a bat passes yields
    // a recording with a truncated pre-roll — the exact case the pre-roll exists
    // for.
    private var preRollRing: UnsafeMutableBufferPointer<Float>?
    /// Ring length in samples. Grow-only within a capture, so nudging the
    /// pre-roll slider doesn't reallocate or throw the buffer away on every
    /// step — shortening the pre-roll just reads fewer of the samples held (see
    /// `preRollWindow`).
    private var preRollCapacity = 0
    private var preRollHead = 0           // next write index
    private var preRollFilled = 0         // valid samples held (≤ capacity)
    /// The capture rate the held samples were taken at. A rate change rebuilds
    /// the ring outright: the old contents are samples at a different rate, and
    /// splicing them into a segment written at the new rate would put audio of
    /// the wrong duration — and pitch — at the head of the file. The Array
    /// version carried them across, and did exactly that.
    private var preRollRate: Double = 0

    /// How many of the held samples the current `preRollSeconds` actually asks
    /// for. Read at trigger time rather than enforced on write, so shortening
    /// the setting takes effect immediately without discarding history that a
    /// subsequent lengthening would want back.
    private var preRollWindow: Int {
        guard preRollRate > 0 else { return 0 }
        return min(preRollFilled, max(0, Int(preRollSecondsQ * preRollRate)))
    }

    // MARK: Audio thread

    /// Lock-free SPSC hand-off from the realtime capture thread to the recorder
    /// queue — the producer only advances `captureWriteA`, the consumer only
    /// `captureReadA`, same shape as the listening processors' output rings.
    ///
    /// This exists because `append` used to do `Array(UnsafeBufferPointer(...))`
    /// per callback: a heap allocation of the whole buffer, on the realtime
    /// thread, ~187 times a second at 384 kHz — the exact thing the project bans
    /// there, and which every sibling DSP type already avoids. A malloc that
    /// takes the slow path under memory pressure costs a dropped capture buffer,
    /// which is a lost call.
    ///
    /// ~1.4 s of headroom at 384 kHz. Manually managed rather than a Swift Array
    /// because both threads touch it concurrently, which Array's exclusivity
    /// rules don't allow.
    private static let captureRingCapacity = 1 << 19
    private let captureRing: UnsafeMutableBufferPointer<Float> = {
        let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: AudioRecorder.captureRingCapacity)
        b.initialize(repeating: 0)
        return b
    }()
    private let captureWriteA = Atomic<Int>(0)
    private let captureReadA = Atomic<Int>(0)
    /// Capture rate, published as a bit pattern so the cross-thread read is a
    /// genuine atomic rather than an assumed-atomic `Double` load.
    private let captureRateA = Atomic<UInt64>(0)
    /// Consumer-side scratch, reused across drains — queue-local, never touched
    /// by the audio thread.
    private var drainScratch: [Float] = []

    deinit {
        captureRing.deallocate()
        preRollRing?.deallocate()
    }

    /// Copy samples off the realtime thread and hand them to the recorder queue.
    ///
    /// Allocation-free: the samples go into the preallocated ring, and the only
    /// thing handed to `queue.async` is the fixed-size closure context (which
    /// libdispatch pools) rather than a fresh buffer of the capture's length.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        captureRateA.store(buffer.format.sampleRate.bitPattern, ordering: .releasing)

        let cap = Self.captureRingCapacity
        var w = captureWriteA.load(ordering: .relaxed)
        let r = captureReadA.load(ordering: .acquiring)
        // Writable slots, keeping one empty so "full" and "empty" stay
        // distinguishable (w == r means empty). Copying only this many drops the
        // remainder when the recorder queue is behind — same policy as the
        // per-sample loop this replaces, which broke out of the copy on full.
        // At 1.4 s of headroom, being full means the queue has stalled for longer
        // than any recording could survive anyway.
        //
        // Derived from what's USED, not from `(r - w + cap) % cap - 1`. That form
        // is right for every state except the one that matters most: with the ring
        // empty (w == r) it evaluates to (cap % cap) - 1 == -1, so nothing was
        // copied. And empty is the steady state — `drainCapture` always takes
        // everything available — so the ring accepted nothing, ever. Recording
        // produced 44-byte header-only WAVs. Caught by
        // `AudioRecorderPreRollTests`, which is why they exist.
        let used = (w - r + cap) % cap
        let writable = cap - 1 - used
        let toCopy = min(n, max(0, writable))
        // Block copies rather than a sample-at-a-time loop with a modulo per
        // sample: this runs on the realtime thread at 384 kHz, i.e. 384 000
        // iterations a second to move data that memcpy moves in two calls. Same
        // shape as `drainCapture`'s read side and `SpectrogramProcessor`'s PCM
        // ring, which already do it this way.
        var copied = 0
        while copied < toCopy {
            let chunk = min(toCopy - copied, cap - w)
            (captureRing.baseAddress! + w).update(from: ch + copied, count: chunk)
            w = (w + chunk) % cap
            copied += chunk
        }
        captureWriteA.store(w, ordering: .releasing)
        queue.async { [weak self] in self?.drainCapture() }
    }

    /// Recorder-queue side of the hand-off: pull everything currently readable
    /// and run the existing segment logic over it in one pass.
    private func drainCapture() {
        let cap = Self.captureRingCapacity
        let w = captureWriteA.load(ordering: .acquiring)
        var r = captureReadA.load(ordering: .relaxed)
        let available = (w - r + cap) % cap
        guard available > 0 else { return }
        let sr = Double(bitPattern: captureRateA.load(ordering: .acquiring))
        guard sr > 0 else { return }

        if drainScratch.count < available {
            drainScratch = [Float](repeating: 0, count: available)
        }
        drainScratch.withUnsafeMutableBufferPointer { dst in
            // Up to two chunks: the readable region can wrap the end of the ring.
            let firstChunk = min(available, cap - r)
            dst.baseAddress!.update(from: captureRing.baseAddress! + r, count: firstChunk)
            if available > firstChunk {
                (dst.baseAddress! + firstChunk).update(from: captureRing.baseAddress!,
                                                      count: available - firstChunk)
            }
        }
        r = (r + available) % cap
        captureReadA.store(r, ordering: .releasing)

        drainScratch.withUnsafeBufferPointer { src in
            handle(UnsafeBufferPointer(start: src.baseAddress!, count: available), sampleRate: sr)
        }
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
            let cutoff = Date().addingTimeInterval(-(maxSegmentSecondsQ + 5))
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
            if !on { closeSegment(); clearPreRoll() }
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
                postRollRemaining = Int(postRollSecondsQ * sampleRate)
            } else if handle != nil {
                postRollRemaining = Int(postRollSecondsQ * sampleRate)
            }
        }
    }

    /// Audio stopped — close any open segment so the file is finalised.
    func audioStopped() {
        queue.async { [weak self] in self?.closeSegment() }
    }

    // MARK: Queue work

    private func handle(_ samples: UnsafeBufferPointer<Float>, sampleRate sr: Double) {
        sampleRate = sr

        // Demo mode: drop the audio entirely rather than just refusing to open a
        // segment — otherwise the pre-roll below would sit there accumulating
        // seconds of demo audio, ready to be written into the first real
        // recording made after the demo ends.
        guard !blockedQ else { return }

        guard handle != nil else {
            // Idle: keep a rolling pre-roll so a segment can start mid-buffer.
            appendPreRoll(samples, sampleRate: sr)
            return
        }

        write(samples)
        writtenSamples += samples.count

        if !activeQ {
            postRollRemaining -= samples.count
            if postRollRemaining <= 0 { closeSegment(); return }
        }
        // Safety cap: rotate to a fresh file if a segment runs very long.
        if writtenSamples >= Int(maxSegmentSecondsQ * sampleRate) {
            closeSegment()
            if armedQ && activeQ { startSegment() }
        }
    }

    // MARK: Pre-roll (recorder queue)

    /// Fold one capture buffer into the rolling pre-trigger ring. O(buffer),
    /// independent of the pre-roll length — see `preRollRing`.
    private func appendPreRoll(_ samples: UnsafeBufferPointer<Float>, sampleRate sr: Double) {
        guard sr > 0 else { return }
        // Allocated for the LONGEST pre-roll the setting can ask for, not the
        // current one, so moving the slider never reallocates and never empties
        // the buffer — `preRollWindow` narrows the read instead. Without this,
        // lengthening the pre-roll would leave the next few seconds' triggers
        // with a truncated one, which is the opposite of what the user just asked
        // for. `max` with the current value so a future wider slider still fits.
        let wanted = max(1, Int(max(preRollSecondsQ, Self.maxPreRollSeconds) * sr))
        if preRollRing == nil || preRollRate != sr || preRollCapacity < wanted {
            preRollRing?.deallocate()
            let ring = UnsafeMutableBufferPointer<Float>.allocate(capacity: wanted)
            ring.initialize(repeating: 0)
            preRollRing = ring
            preRollCapacity = wanted
            preRollRate = sr
            preRollHead = 0
            preRollFilled = 0
        }
        guard let ring = preRollRing, let src = samples.baseAddress else { return }

        // A buffer longer than the whole ring can only leave its own tail behind,
        // so skip straight to the part that survives instead of wrapping over
        // ourselves. (Can't happen at any real IO buffer size, but the arithmetic
        // below would be wrong rather than merely wasteful if it did.)
        let n = samples.count
        let srcStart = n > preRollCapacity ? n - preRollCapacity : 0
        let copyCount = n - srcStart
        guard copyCount > 0 else { return }

        var copied = 0
        while copied < copyCount {
            let chunk = min(copyCount - copied, preRollCapacity - preRollHead)
            (ring.baseAddress! + preRollHead).update(from: src + srcStart + copied, count: chunk)
            preRollHead = (preRollHead + chunk) % preRollCapacity
            copied += chunk
        }
        preRollFilled = min(preRollFilled + copyCount, preRollCapacity)
    }

    /// Write everything the pre-roll holds into the open segment, oldest sample
    /// first, and empty it. Returns how many samples were written.
    @discardableResult
    private func writePreRoll() -> Int {
        guard let ring = preRollRing, preRollCapacity > 0 else { return 0 }
        let count = preRollWindow
        guard count > 0 else { clearPreRoll(); return 0 }
        let start = (preRollHead - count + preRollCapacity) % preRollCapacity
        let firstChunk = min(count, preRollCapacity - start)
        write(UnsafeBufferPointer(start: ring.baseAddress! + start, count: firstChunk))
        if count > firstChunk {
            write(UnsafeBufferPointer(start: ring.baseAddress!, count: count - firstChunk))
        }
        clearPreRoll()
        return count
    }

    /// Drop the pre-roll's contents without freeing the ring.
    private func clearPreRoll() {
        preRollHead = 0
        preRollFilled = 0
    }

    private func startSegment() {
        let triggerDate = Date()
        let url = makeURL()
        let sr = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        // Write a 44-byte WAV header with placeholder sizes; patched on close.
        // Rounded, not truncated: the GUANO chunk written at close states the rate
        // as `Int(sr.rounded())`, and a non-integral delivered rate made the file's
        // two statements of its own sample rate differ by 1 Hz — harmless to this
        // app, which reads the header, but other tools parse both.
        try? h.write(contentsOf: Self.wavHeader(sampleRate: UInt32(sr.rounded()), dataBytes: 0))
        handle = h
        dataBytes = 0
        segmentWriteFailed = false
        currentURL = url
        DispatchQueue.main.async { [weak self] in self?.lastWrittenSampleRate = sr }
        writtenSamples = 0
        postRollRemaining = Int(postRollSecondsQ * sr)

        // segmentStartDate must be the timestamp of the file's actual FIRST
        // sample, not the trigger moment — the pre-roll pushes real audio
        // earlier than the trigger, and using the trigger time here would
        // shift the reported start (and ClassificationStore's pulse-matching
        // window) later than the file's true content.
        let preRollSamples = preRollWindow
        segmentStartDate = preRollSamples > 0 && sr > 0
            ? triggerDate.addingTimeInterval(-Double(preRollSamples) / sr)
            : triggerDate
        writtenSamples += writePreRoll()
        DispatchQueue.main.async { [weak self] in self?.isWriting = true }
    }

    private func closeSegment() {
        guard let h = handle, let url = currentURL else { return }

        // A segment can close with zero PCM bytes written (e.g. armed/stopped again
        // before any samples made it through, or a trigger whose post-roll write
        // never actually ran) — discard rather than hand back an unreadable,
        // headers-only WAV that Files/other apps can't play.
        guard dataBytes > 0 else { discardSegment(handle: h, url: url); return }

        // A segment with a failed write in it has a hole in its PCM stream and no
        // honest length to declare, so it is discarded rather than saved — better
        // a missing recording (reported via `lastWriteError`) than one whose
        // header lies about what it contains. See `write`.
        guard !segmentWriteFailed else { discardSegment(handle: h, url: url); return }

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

        // The spectrogram render is a full FFT pass over the whole file, and it
        // must NOT run on the recorder queue: that queue is also what drains the
        // capture ring, which holds ~1.4 s. A render of a long segment
        // (`maxSegmentSeconds` is 600, so up to 230 M samples at 384 kHz) blocks
        // the drain for longer than the ring can cover, so capture buffers are
        // dropped — and the segment-rotation path below starts the NEXT file
        // immediately afterwards, so that file loses its own opening. Both
        // losses were silent.
        //
        // Everything the report needs is queue-local state, so it is read here,
        // on the recorder queue, and only value types cross to `reportQueue`.
        let docs = CloudStorage.baseDirectory
        let relativePath = String(finalURL.path.dropFirst(docs.path.count + 1))
        let (species, confidence, pulseCount): (String, Float?, Int)
        switch outcome {
        case .species(let code, let conf, let count): (species, confidence, pulseCount) = (code, conf, count)
        case .noID(let count): (species, confidence, pulseCount) = ("NOID", nil, count)
        case .noise: (species, confidence, pulseCount) = ("NOISE", nil, 0)   // unreachable — rejected before this is called
        }
        let reportDate = segmentStartDate ?? Date()
        let duration = sr > 0 ? Double(closedDataBytes / 2) / sr : 0
        let sessionID = sessionIDQ
        let coordinate = lastCoordinateQ

        reportQueue.async {
            // maxWidth 4096 matches what WavSpectrogramEngine.renderOverview
            // requests for its fallback (non-cached) render path — keeping this
            // cached render at the same resolution means the WAV player's reuse
            // of this cache (see WavSpectrogramEngine.renderOverview) doesn't
            // trade away overview sharpness to save the render time.
            let image = RecordingSpectrogramRenderer.render(wavURL: finalURL, maxWidth: 4096)
            let report = RecordingReport(
                date: reportDate,
                durationSeconds: duration,
                species: species, confidence: confidence, pulseCount: pulseCount,
                sessionID: sessionID, coordinate: coordinate,
                relativeWavPath: relativePath, spectrogramImage: image)
            DispatchQueue.main.async { [weak self] in self?.onRecordingSaved?(report) }
        }
    }

    // Reused scratch for the vectorised float→Int16 conversion in write().
    private var floatScratch: [Float] = []
    private var pcm16Scratch: [Int16] = []

    private func write(_ samples: UnsafeBufferPointer<Float>) {
        guard let handle else { return }
        // The segment is already condemned (see below) and will be discarded at
        // close, so there is nothing to gain by converting and re-attempting
        // every subsequent buffer. Without this, a full disk means ~188 failed
        // writes a second, each assigning `lastWriteError` — whose didSet hops to
        // the main thread — for the rest of the post-roll, precisely when the
        // device is already in trouble.
        guard !segmentWriteFailed else { return }
        // Float32 [-1,1] → 16-bit PCM via vDSP (clip, scale, truncate). iOS is
        // little-endian, so the Int16 buffer's raw bytes are already WAV byte order.
        let n = samples.count
        if floatScratch.count < n { floatScratch = [Float](repeating: 0, count: n) }
        if pcm16Scratch.count < n { pcm16Scratch = [Int16](repeating: 0, count: n) }
        var lo: Float = -1, hi: Float = 1, scale: Float = 32767
        vDSP_vclip(samples.baseAddress!, 1, &lo, &hi, &floatScratch, 1, vDSP_Length(n))
        vDSP_vsmul(floatScratch, 1, &scale, &floatScratch, 1, vDSP_Length(n))
        let data = pcm16Scratch.withUnsafeMutableBufferPointer { dst -> Data in
            vDSP_vfix16(floatScratch, 1, dst.baseAddress!, 1, vDSP_Length(n))
            return Data(bytes: dst.baseAddress!, count: n * 2)
        }
        // `dataBytes` advances ONLY on a write that actually landed. It is the
        // number the WAV header's RIFF/data sizes and the GUANO chunk's offset
        // are all computed from at close (see `closeAndKeep`), so counting a
        // failed write produced a header claiming more PCM than exists on disk:
        // the GUANO seek then lands past real EOF and zero-fills the gap, and
        // the file is handed to ClassificationStore as a normal saved recording.
        // A disk that fills mid-bout is the realistic way in — every subsequent
        // write fails, and the old code recorded a full-length file of nothing.
        // This is review item 5.5 (Context.md §15), which was logged as fixed
        // and was not.
        do {
            try handle.write(contentsOf: data)
            dataBytes += n * 2
        } catch {
            // One failure condemns the segment: the PCM stream now has a hole in
            // it, and there is no honest length to report for a file missing a
            // chunk out of its middle. `closeSegment` discards it instead of
            // saving something unreadable.
            segmentWriteFailed = true
            lastWriteError = error.localizedDescription
        }
    }

    // MARK: GUANO metadata

    /// Build the GUANO chunk for the segment being closed, from queue-local context.
    private func makeGuanoChunk(filename: String, outcome: AutoIDOutcome) -> Data {
        let sr = sampleRate
        let durationS = sr > 0 ? Double(dataBytes / 2) / sr : 0
        // GUANO Make/Model describe the recording HARDWARE, not the app: `Make`
        // is the ultrasonic input device (the Griff's detected port name, or
        // the host model if none was named), `Model` is the host iPhone. The
        // app goes in `Firmware Version` (GUANO's conventional slot for
        // recording software) so downstream tools read "OpenBat …" as the app,
        // not the device.
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

    /// The canonical 44-byte header every reader in this app assumes (16-bit mono
    /// PCM, `data` immediately after a 16-byte `fmt `). Shared with
    /// `RecordingImporter`, which rewrites imported files into exactly this shape
    /// — the layout is asserted in four separate readers, so it must be written
    /// in one place only.
    static func wavHeader(sampleRate: UInt32, dataBytes: UInt32) -> Data {
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
