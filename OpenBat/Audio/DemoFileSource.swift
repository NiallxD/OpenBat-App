//
//  DemoFileSource.swift
//  OpenBat
//
//  Feeds a WAV file into the capture pipeline in place of the microphone tap,
//  for demo mode (see AudioEngineController's "Demo mode" section). Delivers
//  `AVAudioPCMBuffer`s paced to wall clock at the file's own sample rate, so
//  everything downstream of the tap — SpectrogramProcessor, PulseDetector, the
//  heterodyne and adaptive time-expansion processors — behaves exactly as it
//  does live. Nothing below the tap can tell the difference: every consumer
//  already reads `buffer.format.sampleRate` off the buffer rather than assuming
//  384 kHz.
//
//  Real-time pacing is not a nicety. VariableTimeDistortionProcessor's
//  drain-deafness and its `missedCount` are wall-clock behaviours (see the
//  invariants in that file); feeding the pipeline faster than real time would
//  make the mode look better than it is, and feeding it slower would hide the
//  misses entirely.
//

import AVFoundation

/// `nonisolated`: the delivery callback runs on this object's own queue, off the
/// main actor, matching the real audio tap's contract. Same reasoning as
/// `AudioRecorder`/`HeterodyneProcessor` — the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` would otherwise make this
/// `@MainActor` and the callback unusable as a tap replacement.
nonisolated final class DemoFileSource: @unchecked Sendable {

    /// Frames per delivered buffer — matches the live tap's `bufferSize: 2048`
    /// so the downstream FFT hop/column cadence is identical to a real capture.
    private static let framesPerBuffer: AVAudioFrameCount = 2048

    /// Ceiling on how many buffers one timer tick may emit while catching up
    /// after a scheduling hiccup. Without it, a long main-thread stall (a sheet
    /// dismissal, a Metal hitch) would be followed by a burst of hundreds of
    /// buffers delivered back-to-back — which is exactly the faster-than-real-
    /// time feed the pacing exists to prevent.
    private static let maxBuffersPerTick = 4

    let url: URL
    let sampleRate: Double
    let channelCount: Int
    /// Total frames in the file, for a duration readout.
    let totalFrames: AVAudioFramePosition

    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let queue = DispatchQueue(label: "bat.DemoFileSource", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Frames emitted since `start()`, against which the wall-clock target is
    /// compared. Queue-local.
    private var emittedFrames: AVAudioFramePosition = 0
    private var startTime: DispatchTime = .now()

    /// Opens `url` for paced playback. Throws if the file can't be read as
    /// audio — the caller surfaces that rather than starting a silent demo.
    init(url: URL) throws {
        // A user-chosen recording may be an iCloud placeholder; the bundled demo
        // file never is, but this is cheap and covers both.
        CloudStorage.ensureDownloaded(url)
        self.url = url
        // AVAudioFile rather than WavPCMReader: that reader assumes the 44-byte
        // fixed header AudioRecorder writes (see its doc comment), which holds
        // for recordings made by this app but not for an arbitrary bundled or
        // imported WAV. AVAudioFile also hands back float buffers directly, in
        // the same layout the live tap delivers.
        let file = try AVAudioFile(forReading: url)
        self.file = file
        self.format = file.processingFormat
        self.sampleRate = file.processingFormat.sampleRate
        self.channelCount = Int(file.processingFormat.channelCount)
        self.totalFrames = file.length
        guard sampleRate > 0, file.length > 0 else {
            throw DemoFileSourceError.emptyFile
        }
    }

    var durationSeconds: Double { Double(totalFrames) / sampleRate }

    /// Begins paced delivery. `sink` is called off the main thread, once per
    /// buffer, and must obey the same rules as the live tap closure: cheap,
    /// non-blocking work only.
    func start(sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        queue.async { [self] in
            handler = sink
            emittedFrames = 0
            file.framePosition = 0
            startTime = .now()

            let interval = Double(Self.framesPerBuffer) / sampleRate
            let t = DispatchSource.makeTimerSource(queue: queue)
            // Leeway of a fraction of the interval lets the system coalesce
            // wakeups without the average rate drifting — the catch-up loop in
            // `tick()` is what actually holds the long-run rate to real time.
            t.schedule(deadline: .now() + interval,
                       repeating: interval,
                       leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            handler = nil
        }
    }

    // MARK: Queue work

    /// Emits however many buffers wall clock says are now due, capped at
    /// `maxBuffersPerTick`. Deriving the target from elapsed time rather than
    /// counting ticks means timer jitter can't accumulate into drift: a late
    /// tick catches up, an early one emits nothing.
    private func tick() {
        guard let handler else { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- startTime.uptimeNanoseconds) / 1_000_000_000
        let targetFrames = AVAudioFramePosition(elapsed * sampleRate)
        var emitted = 0
        while emittedFrames < targetFrames, emitted < Self.maxBuffersPerTick {
            guard let buffer = nextBuffer() else { return }
            handler(buffer)
            emittedFrames += AVAudioFramePosition(buffer.frameLength)
            emitted += 1
        }
    }

    /// Reads the next chunk, looping back to the start at EOF. A fresh buffer
    /// per call rather than a reused one: at 384 kHz this is ~187 allocations a
    /// second of 8 KB each, which is nothing, and it removes any question about
    /// a downstream consumer holding onto the buffer past the callback.
    ///
    /// The rewind is checked BEFORE reading rather than inferred from the read's
    /// result. Reading past the end of an `AVAudioFile` is not dependably a
    /// zero-frame success — it can throw — and treating a throw as fatal made
    /// the demo play through exactly once and then sit silent forever, since a
    /// nil here just ends the tick with no way back.
    private func nextBuffer() -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.framesPerBuffer) else { return nil }
        if file.framePosition >= totalFrames { rewind() }
        do {
            try file.read(into: buffer, frameCount: Self.framesPerBuffer)
        } catch {
            // Any read failure is treated as an unexpected EOF and retried once
            // from the top; only a file that also fails from frame 0 is really
            // unreadable, and that ends the feed.
            rewind()
            guard (try? file.read(into: buffer, frameCount: Self.framesPerBuffer)) != nil else { return nil }
        }
        // A short read at the tail is normal and delivered as-is; a zero-length
        // one means we hit the end exactly on a buffer boundary, so loop now
        // rather than emitting an empty buffer downstream.
        if buffer.frameLength == 0 {
            rewind()
            guard (try? file.read(into: buffer, frameCount: Self.framesPerBuffer)) != nil else { return nil }
        }
        return buffer.frameLength > 0 ? buffer : nil
    }

    /// Restart the clip. Only the file position — the pacing counters stay
    /// monotonic across laps on purpose. `tick()` reads `targetFrames` once
    /// before its loop, so zeroing `emittedFrames` from inside `nextBuffer()`
    /// would leave the loop comparing 0 against a large target and fire a burst
    /// of buffers at every loop point. Both counters simply grow at the same
    /// rate for as long as the demo runs; `Int64` frames at 384 kHz has no
    /// practical ceiling.
    private func rewind() {
        file.framePosition = 0
    }
}

enum DemoFileSourceError: LocalizedError {
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .emptyFile: return "The file contains no audio."
        }
    }
}
