//
//  PlaybackEngine.swift
//  OpenBat
//
//  Plays back a saved Recording WAV through the SAME listening DSPs the live
//  detector uses (HeterodyneProcessor / TimeExpansionProcessor) — a raw ultrasonic
//  WAV played straight through the speaker is inaudible (and gets lowpassed by the
//  hardware's DAC anyway), same reason live listening needs downconversion. Also
//  feeds a SpectrogramProcessor so PlaybackView can show the SAME live-style
//  scrolling Metal spectrogram the Detector screen uses, just fed from file
//  playback instead of the mic tap.
//
//  Split into two pieces, mirroring AudioEngineController's own split between a
//  @MainActor wrapper and the nonisolated, audio-thread-safe processors it owns:
//    • PlaybackEngine — @MainActor, @Observable UI-facing state (play/pause,
//      position, listen mode).
//    • PlaybackDriver — nonisolated, owns the file-reading thread that paces PCM
//      to real time and the AVAudioEngine output graph.
//

import AVFoundation
import Accelerate
import Observation

/// Nonisolated: owns the background pacing thread and the output AVAudioEngine, so
/// it can be driven independent of the main actor. `mode` is `nonisolated(unsafe)` —
/// a plain enum read/written from two threads with no sync, same benign-race
/// pattern SpectrogramProcessor's `suspended`/`peakBin` already use elsewhere.
nonisolated final class PlaybackDriver: @unchecked Sendable {
    private let heterodyne: HeterodyneProcessor
    private let timeExpansion: TimeExpansionProcessor
    private let spectrogramProcessor: SpectrogramProcessor

    nonisolated(unsafe) var mode: ListenMode = .heterodyne

    /// Called off the main thread as playback advances; the caller hops to main.
    var onProgress: ((Double) -> Void)?
    /// Called off the main thread once the file's last sample has been fed.
    var onFinished: (() -> Void)?
    /// Called off the main thread if the pacing thread can't open `url` at all —
    /// distinct from `onFinished` so the caller can tell "played to the end" apart
    /// from "never actually started" and surface the latter as an error instead of
    /// silently sitting at isPlaying == true with no progress.
    var onOpenFailed: (() -> Void)?

    private final class StopBox { var stopped = false }
    private var stopBox = StopBox()
    private var thread: Thread?
    /// Signaled by the pacing thread right before it returns. `stop()` waits on
    /// this (briefly, bounded) before returning, so a `stop()` immediately
    /// followed by `start()` (e.g. dragging the scrub slider, which calls
    /// `seek` → `stop()` then `start()` on every drop) can't leave the OLD
    /// thread's last buffer still calling `process()` on the shared Heterodyne/
    /// TimeExpansion/SpectrogramProcessor instances concurrently with the NEW
    /// thread doing the same — those are single-producer processors, and two
    /// concurrent producers racing on the same ring buffer/filter state is a
    /// real (if narrow, ~1-2ms) data race without this.
    private var stopSemaphore: DispatchSemaphore?
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    init(heterodyne: HeterodyneProcessor, timeExpansion: TimeExpansionProcessor,
        spectrogramProcessor: SpectrogramProcessor) {
        self.heterodyne = heterodyne
        self.timeExpansion = timeExpansion
        self.spectrogramProcessor = spectrogramProcessor
    }

    // MARK: Output engine

    /// Attaches a source node pulling the active listen-mode's rendered audio to
    /// the speaker — same shape as `AudioEngineController.attachListenOutput`, just
    /// a dedicated engine instead of sharing the live capture engine's graph (the
    /// two can coexist: live detection may still be running in another tab, and
    /// the shared AVAudioSession already runs `.playAndRecord` for exactly that
    /// reason). Idempotent — a second call while already running is a no-op.
    func startEngineIfNeeded() {
        guard engine == nil else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: heterodyne.outputSampleRate, channels: 1)
        else { return }
        let hetero = heterodyne
        let timeExp = timeExpansion
        let node = AVAudioSourceNode(format: outFormat) { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = buffers[0].mData else { return noErr }
            let out = data.assumingMemoryBound(to: Float.self)
            switch self.mode {
            case .heterodyne:    hetero.render(out, frames: Int(frameCount))
            case .timeExpansion: timeExp.render(out, frames: Int(frameCount))
            case .off:            for i in 0..<Int(frameCount) { out[i] = 0 }
            }
            return noErr
        }
        let e = AVAudioEngine()
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: outFormat)
        e.prepare()
        try? e.start()
        engine = e
        sourceNode = node
    }

    func stopEngine() {
        engine?.stop()
        engine = nil
        sourceNode = nil
    }

    // MARK: Pacing thread

    /// Reads `url`'s PCM starting at `fromSample`, pacing reads to real elapsed
    /// wall-clock time (catch-up/slow-down each tick rather than a fixed
    /// per-timer-tick sample count, which drifts) so the processors — and the
    /// listener — get audio at the file's own sample rate in real time. Feeds
    /// every buffer to `spectrogramProcessor` (display) and whichever of
    /// heterodyne/timeExpansion `mode` currently selects (audible output); `.off`
    /// still advances the spectrogram, just renders silence.
    func start(url: URL, sampleRate: Double, totalSamples: Int, fromSample: Int) {
        stop()
        let box = StopBox()
        stopBox = box
        let semaphore = DispatchSemaphore(value: 0)
        stopSemaphore = semaphore
        let hetero = heterodyne
        let timeExp = timeExpansion
        let spec = spectrogramProcessor
        let onProgress = onProgress
        let onFinished = onFinished
        let onOpenFailed = onOpenFailed

        let t = Thread {
            defer { semaphore.signal() }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                if !box.stopped { onOpenFailed?() }
                return
            }
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(44 + fromSample * 2))
            guard let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            else {
                if !box.stopped { onOpenFailed?() }
                return
            }

            var samplesFed = fromSample
            let startWall = Date()
            let maxChunk = 1 << 14   // ~16k samples (~43 ms @ 384 kHz) per read
            var int16Buf = [Int16](repeating: 0, count: maxChunk)

            while !box.stopped, samplesFed < totalSamples {
                let elapsed = Date().timeIntervalSince(startWall)
                let shouldHaveFed = fromSample + Int(elapsed * sampleRate)
                guard shouldHaveFed > samplesFed else { usleep(2_000); continue }
                let want = min(shouldHaveFed - samplesFed, min(maxChunk, totalSamples - samplesFed))
                guard want > 0 else { continue }
                guard let data = try? handle.read(upToCount: want * 2), !data.isEmpty else { break }
                let n = data.count / 2
                guard n > 0 else { continue }
                data.withUnsafeBytes { raw in
                    let src = raw.bindMemory(to: Int16.self)
                    int16Buf.withUnsafeMutableBufferPointer { dst in
                        for i in 0..<n { dst[i] = src[i] }
                    }
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(n)),
                      let floatCh = buffer.floatChannelData?[0]
                else { break }
                buffer.frameLength = AVAudioFrameCount(n)
                int16Buf.withUnsafeBufferPointer { srcBuf in
                    vDSP_vflt16(srcBuf.baseAddress!, 1, floatCh, 1, vDSP_Length(n))
                    var scale: Float = 1.0 / 32767.0
                    vDSP_vsmul(floatCh, 1, &scale, floatCh, 1, vDSP_Length(n))
                }

                spec.process(buffer)
                hetero.process(buffer)       // both kept warm regardless of `mode`, so
                timeExp.process(buffer)      // switching mid-playback doesn't cold-start

                samplesFed += n
                if !box.stopped { onProgress?(Double(samplesFed) / sampleRate) }
            }
            if !box.stopped { onFinished?() }
        }
        t.qualityOfService = .userInitiated
        t.name = "bat.PlaybackDriver"
        t.start()
        thread = t
    }

    func stop() {
        stopBox.stopped = true
        // Bounded wait (not indefinite — never risk hanging the caller, which is
        // typically the main actor via PlaybackEngine): the thread checks
        // `box.stopped` at least every 2ms (see the pacing loop's usleep), so a
        // 200ms timeout is generous headroom, not a real limit in practice.
        _ = stopSemaphore?.wait(timeout: .now() + 0.2)
        stopSemaphore = nil
        thread = nil
    }
}

@MainActor
@Observable
final class PlaybackEngine {

    private(set) var isPlaying = false
    private(set) var currentTimeSeconds: Double = 0
    private(set) var durationSeconds: Double = 0
    /// Which Recording is loaded — nil when nothing's been picked yet.
    private(set) var loadedURL: URL?
    /// Set whenever `load()` or the pacing thread itself can't actually get audio
    /// out of the file — surfaced by PlaybackView instead of leaving play() a
    /// silent no-op (see the WavHeader/FileHandle guards below).
    private(set) var loadError: String?

    var listenMode: ListenMode = .heterodyne {
        didSet {
            guard oldValue != listenMode else { return }
            driver.mode = listenMode
            // Heterodyne's squelch gate only opens from live pulse triggers
            // normally (see AudioEngineController.notifyPulseDetected) — there's
            // no live PulseDetector here, so just hold it open for the whole file
            // whenever heterodyne is the active mode.
            heterodyne.setGate(listenMode == .heterodyne)
        }
    }

    let heterodyne = HeterodyneProcessor()
    let timeExpansion = TimeExpansionProcessor()
    let spectrogramProcessor = SpectrogramProcessor()

    // Not part of the @Observable-tracked UI state — an internal implementation
    // detail SwiftUI never reads directly, so it's excluded from observation.
    @ObservationIgnored private var driver: PlaybackDriver!
    /// The loaded file's sample rate — read by PlaybackView to size the
    /// spectrogram's frequency axis (`maxFrequency = sampleRate / 2`).
    private(set) var sampleRate: Double = 384_000
    private var totalSamples: Int = 0

    init() {
        driver = PlaybackDriver(heterodyne: heterodyne, timeExpansion: timeExpansion,
                                spectrogramProcessor: spectrogramProcessor)
        driver.mode = listenMode
        driver.onProgress = { [weak self] t in
            DispatchQueue.main.async { self?.currentTimeSeconds = t }
        }
        driver.onFinished = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPlaying = false
                self.currentTimeSeconds = self.durationSeconds
            }
        }
        driver.onOpenFailed = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPlaying = false
                self.loadError = "Couldn't open the recording for playback."
            }
        }
    }

    /// Loads a Recording's WAV — resets playback to the start. Call `play()`
    /// afterward to start listening.
    func load(url: URL) {
        stop()
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadError = "Recording file is missing on disk: \(url.lastPathComponent)"
            return
        }
        guard let (sr, total) = Self.readHeader(url: url) else {
            loadError = "Recording's WAV header couldn't be read: \(url.lastPathComponent)"
            return
        }
        loadError = nil
        loadedURL = url
        sampleRate = sr
        totalSamples = total
        durationSeconds = sr > 0 ? Double(total) / sr : 0
        currentTimeSeconds = 0
        spectrogramProcessor.sampleRate = sr
        heterodyne.reset(inputSampleRate: sr)
        timeExpansion.reset(inputSampleRate: sr)
    }

    func togglePlaying() { isPlaying ? pause() : play() }

    func play() {
        guard let url = loadedURL, !isPlaying, currentTimeSeconds < durationSeconds else { return }
        isPlaying = true
        driver.startEngineIfNeeded()
        heterodyne.setGate(listenMode == .heterodyne)
        driver.start(url: url, sampleRate: sampleRate, totalSamples: totalSamples,
                    fromSample: Int(currentTimeSeconds * sampleRate))
    }

    func pause() {
        isPlaying = false
        driver.stop()
    }

    /// Scrubs to `t` seconds, restarting the pacing thread from there (resumes
    /// playing if it was already playing).
    func seek(toSeconds t: Double) {
        let wasPlaying = isPlaying
        driver.stop()
        isPlaying = false
        currentTimeSeconds = min(max(0, t), durationSeconds)
        if wasPlaying { play() }
    }

    func stop() {
        pause()
        driver.stopEngine()
        loadedURL = nil
        currentTimeSeconds = 0
        durationSeconds = 0
    }

    private static func readHeader(url: URL) -> (sampleRate: Double, totalSamples: Int)? {
        guard let header = WavHeader.read(url: url) else { return nil }
        return (Double(header.sampleRate), Int(header.dataBytes) / 2)
    }
}
