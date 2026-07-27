//
//  PlaybackEngineTests.swift
//  OpenBatTests
//
//  Builds a WAV byte-for-byte like AudioRecorder's own header writer, then
//  drives PlaybackEngine exactly the way PlaybackPlayerView does (load → play →
//  wait) — regression coverage for the class of bug where load()/play() fail
//  silently and playback just looks inert (no error, no progress, no spectrogram).
//

import Testing
import Foundation
import AVFoundation
@testable import OpenBat

@MainActor
struct PlaybackEngineTests {

    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    /// Mirrors AudioRecorder.wavHeader + the closeAndKeep size patch exactly.
    private func makeTestWav(sampleRate: UInt32 = 384_000, seconds: Double = 1.0,
                              toneFrequency: Double = 40_000) -> URL {
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bits / 8)
        let blockAlign = channels * (bits / 8)
        let sampleCount = Int(Double(sampleRate) * seconds)
        let dataBytes = UInt32(sampleCount * 2)

        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(Self.le32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(Self.le32(16))
        d.append(Self.le16(1))
        d.append(Self.le16(channels))
        d.append(Self.le32(sampleRate))
        d.append(Self.le32(byteRate))
        d.append(Self.le16(blockAlign))
        d.append(Self.le16(bits))
        d.append(contentsOf: Array("data".utf8))
        d.append(Self.le32(dataBytes))

        // Tone scaled to 16-bit so there's real signal in the file.
        var pcm = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let t = Double(i) / Double(sampleRate)
            pcm[i] = Int16(sin(2 * .pi * toneFrequency * t) * 20000)
        }
        pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diag_\(UUID().uuidString).wav")
        try? d.write(to: url)
        return url
    }

    @Test func wavHeaderParsesTestFile() {
        let url = makeTestWav()
        let header = WavHeader.read(url: url)
        #expect(header != nil, "WavHeader.read returned nil for a well-formed test WAV")
        if let header {
            #expect(header.sampleRate == 384_000)
            #expect(header.dataBytes == 384_000 * 2)
        }
        try? FileManager.default.removeItem(at: url)
    }

    @Test func engineLoadSetsDuration() {
        let url = makeTestWav(seconds: 2.0)
        let engine = PlaybackEngine()
        engine.load(url: url)
        #expect(engine.loadedURL != nil, "loadedURL is nil after load() — header read must have failed")
        #expect(engine.durationSeconds > 1.9 && engine.durationSeconds < 2.1,
                "durationSeconds = \(engine.durationSeconds), expected ~2.0")
        try? FileManager.default.removeItem(at: url)
    }

    @Test func loadMissingFileSetsLoadError() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope_\(UUID().uuidString).wav")
        let engine = PlaybackEngine()
        engine.load(url: missing)
        #expect(engine.loadedURL == nil)
        #expect(engine.loadError != nil, "load() of a missing file should set loadError instead of failing silently")
    }

    @Test func playActuallyStartsAndProgresses() async {
        let url = makeTestWav(seconds: 2.0)
        let engine = PlaybackEngine()
        engine.load(url: url)
        #expect(engine.loadedURL != nil)
        #expect(engine.durationSeconds > 0)

        engine.listenMode = .off   // avoid any HeterodyneProcessor gate/state quirks for this check
        engine.play()
        #expect(engine.isPlaying == true, "isPlaying didn't flip true after play() — the guard in play() bailed")

        // Give the pacing thread real wall-clock time to advance.
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(engine.currentTimeSeconds > 0,
                "currentTimeSeconds still 0 after 400ms of playback — PlaybackDriver never fed a buffer")

        // Asserted via `peakFrequency` rather than by draining columns.
        //
        // This used to check `spectrogramProcessor.drain()` was non-empty, which
        // can no longer work: `PlaybackDriver` drains the processor itself on
        // every buffer and discards the result (see the comment beside
        // `_ = spec.drain()` in PlaybackEngine) because WavPlayerView renders a
        // static whole-file spectrogram and `pending` would otherwise grow ~6
        // MB/sec for the length of playback. A test draining from another thread
        // is racing the driver for columns the driver is throwing away, so it
        // failed nearly always and passed occasionally — the worst kind of test.
        //
        // `peakBin`/`peakLevel` are written directly inside `process()`, not
        // sourced from `pending`, so they survive the driver's drain and are the
        // honest signal that audio is reaching the processor and being analysed.
        // The driver itself depends on exactly this for heterodyne auto-tune.
        //
        // Checking the VALUE rather than just non-zero also makes this cover more
        // than the original did: the fixture is a 40 kHz tone, so a correct
        // reading confirms the samples arrived intact and the bin→Hz conversion
        // is right, not merely that something was fed.
        let peak = engine.spectrogramProcessor.peakFrequency
        #expect(peak > 38_000 && peak < 42_000,
                "peakFrequency = \(peak) Hz after 400ms of playing a 40 kHz tone — audio isn't reaching spectrogramProcessor, which is why the spectrogram and heterodyne auto-tune show nothing")

        engine.stop()
        try? FileManager.default.removeItem(at: url)
    }

    /// Regression coverage for "can't hear anything / volume slider greyed
    /// out": AudioEngineController leaves the SHARED AVAudioSession in
    /// `.record` category (no output route at all) whenever the live
    /// Detector screen isn't actively listening — a previous fix here only
    /// switched session MODE, never CATEGORY, so playback's own
    /// AVAudioSourceNode had no audible route whenever the session was still
    /// `.record`. `play()` must claim an output-capable category itself.
    @Test func playClaimsAnOutputCapableSessionCategory() {
        // Simulates AudioEngineController's own non-listening configuration —
        // exactly what the shared session looks like before any live capture
        // has ever engaged listen mode.
        try? AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: [])

        let url = makeTestWav(seconds: 0.5)
        let engine = PlaybackEngine()
        engine.load(url: url)
        engine.play()

        #expect(AVAudioSession.sharedInstance().category == .playback,
                "session category is \(AVAudioSession.sharedInstance().category) after play() — still can't route audio to the speaker")

        engine.stop()
        try? FileManager.default.removeItem(at: url)
    }

    /// Regression coverage for the "heterodyne playback stopped working" bug:
    /// PlaybackEngine's HeterodyneProcessor was never retuned away from its class
    /// default (a fixed 40 kHz LO) — only a recorded call within the ~4 kHz IF
    /// passband around 40 kHz was ever audible; everything else played back
    /// silent. `PlaybackDriver.start()` now auto-tunes the LO from the pacing
    /// thread's own SpectrogramProcessor, same as the live Detector screen does
    /// from PulseDetector triggers. This drives playback through a call well away
    /// from 40 kHz (25 kHz, a typical Noctule-range call) and checks the LO
    /// actually moved — a race-free check (`loFrequency`'s getter is lock-guarded,
    /// no ring-buffer consumption involved), unlike reading `render()` directly
    /// while the real output engine's audio thread is also consuming it.
    @Test func heterodyneAutoTuneRetunesAwayFromDefaultDuringPlayback() async {
        let url = makeTestWav(seconds: 1.0, toneFrequency: 25_000)
        let engine = PlaybackEngine()
        engine.load(url: url)
        engine.listenMode = .heterodyne
        engine.play()
        #expect(engine.isPlaying == true)

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(engine.currentTimeSeconds > 0, "currentTimeSeconds didn't advance in heterodyne mode")

        let lo = engine.heterodyne.loFrequency
        #expect(abs(lo - 40_000) > 5_000,
                "LO is still at/near its 40 kHz class default (\(lo)) — auto-tune never engaged for a 25 kHz call")
        #expect(lo < 25_000, "expected the LO parked below the detected 25 kHz call, got \(lo)")

        engine.stop()
        try? FileManager.default.removeItem(at: url)
    }

    /// Builds a mono float buffer of a single tone — used by the isolated
    /// HeterodyneProcessor tests below, which drive the DSP directly (no engine,
    /// no threads) to avoid the SPSC ring's single-consumer contract: calling
    /// `render()` concurrently with a running `AVAudioEngine`'s own render thread
    /// (as `play()` sets up) is a genuine second-consumer race, not something to
    /// paper over in a test.
    private func makeToneBuffer(frequency: Double, sampleRate: Double, seconds: Double = 0.05) -> AVAudioPCMBuffer {
        let frameCount = Int(sampleRate * seconds)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let ch = buffer.floatChannelData![0]
        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            ch[i] = Float(sin(2 * .pi * frequency * t)) * 0.5
        }
        return buffer
    }

    /// Documents the DSP's correct-use case: with the LO parked `audibleOffsetHz`
    /// below the call (as auto-tune now does), heterodyne produces a real,
    /// audible difference tone.
    @Test func heterodyneProducesAudioWhenLOIsProperlyTuned() {
        let het = HeterodyneProcessor()
        het.reset(inputSampleRate: 384_000)
        het.setGate(true)
        het.loFrequency = 40_000 - 1_500
        het.process(makeToneBuffer(frequency: 40_000, sampleRate: 384_000))

        var out = [Float](repeating: 0, count: 2048)
        out.withUnsafeMutableBufferPointer { het.render($0.baseAddress!, frames: $0.count) }
        let peak = out.map { abs($0) }.max() ?? 0
        #expect(peak > 0.1, "expected a strong difference tone when LO is parked audibleOffsetHz below the call, got peak=\(peak)")
    }

    /// Documents the actual pre-fix failure mode: with the LO stuck at its class
    /// default (40 kHz — what PlaybackEngine's HeterodyneProcessor sat at for
    /// every file before auto-tune was added), a call 15 kHz away mixes down to a
    /// difference frequency the ~4 kHz low-pass filter throws away entirely.
    @Test func heterodyneDefaultLOIsNearSilentForAnOffCenterCall() {
        let het = HeterodyneProcessor()
        het.reset(inputSampleRate: 384_000)
        het.setGate(true)
        // loFrequency left at its class default — no explicit tuning at all.
        het.process(makeToneBuffer(frequency: 25_000, sampleRate: 384_000))

        var out = [Float](repeating: 0, count: 2048)
        out.withUnsafeMutableBufferPointer { het.render($0.baseAddress!, frames: $0.count) }
        let peak = out.map { abs($0) }.max() ?? 0
        #expect(peak < 0.01, "a call 15 kHz from a fixed 40 kHz LO should fall outside the ~4 kHz IF passband, got peak=\(peak)")
    }
}
