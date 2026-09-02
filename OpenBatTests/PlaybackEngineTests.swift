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

    /// Sanity check on the fixture itself: the header this test file writes
    /// parses back to the values it was given.
    // MARK: The timeline playback actually walks

    /// Playing the whole file is the one-region case, so the pacing thread has
    /// a single code path either way.
    @Test func wholeFilePlanIsOneRegion() {
        let plan = PlayPlan(regions: [0..<1000], totalSamples: 1000)
        #expect(plan.virtualTotal == 1000)
        #expect(plan.regionIndex(forVirtual: 500) == 0)
        #expect(plan.realSample(forVirtual: 500, regionIndex: 0) == 500)
    }

    /// The mapping that makes silence removal audible: a position in the
    /// packed timeline has to resolve to the right byte offset in the file,
    /// including exactly at a seam.
    @Test func packedPositionsResolveToTheRightFileOffsets() {
        // Two kept regions with 3000 samples of silence cut between them.
        let plan = PlayPlan(regions: [1000..<2000, 5000..<6000], totalSamples: 7000)
        #expect(plan.virtualTotal == 2000)
        #expect(plan.realSample(forVirtual: 0, regionIndex: plan.regionIndex(forVirtual: 0)) == 1000)
        #expect(plan.realSample(forVirtual: 999, regionIndex: plan.regionIndex(forVirtual: 999)) == 1999)
        // The seam: the first sample of the second region, not of the gap.
        #expect(plan.regionIndex(forVirtual: 1000) == 1)
        #expect(plan.realSample(forVirtual: 1000, regionIndex: 1) == 5000)
        #expect(plan.realSample(forVirtual: 1999, regionIndex: 1) == 5999)
    }

    /// An out-of-range or empty input must land somewhere valid rather than
    /// off the end of the region array — the pacing thread indexes with this.
    @Test func planClampsRatherThanRunningOffTheEnd() {
        let plan = PlayPlan(regions: [1000..<2000, 5000..<6000], totalSamples: 7000)
        #expect(plan.regionIndex(forVirtual: -50) == 0)
        #expect(plan.regionIndex(forVirtual: 999_999) == 1)
        // Empty or degenerate region lists fall back to the whole file — a
        // timeline with no audio in it is something nothing downstream expects.
        #expect(PlayPlan(regions: [], totalSamples: 500).regions == [0..<500])
        #expect(PlayPlan(regions: [10..<10], totalSamples: 500).regions == [0..<500])
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

    /// `load()` must read the header and populate duration, not fail silently.
    @Test func engineLoadSetsDuration() {
        let url = makeTestWav(seconds: 2.0)
        let engine = PlaybackEngine()
        engine.load(url: url)
        #expect(engine.loadedURL != nil, "loadedURL is nil after load() — header read must have failed")
        #expect(engine.durationSeconds > 1.9 && engine.durationSeconds < 2.1,
                "durationSeconds = \(engine.durationSeconds), expected ~2.0")
        try? FileManager.default.removeItem(at: url)
    }

    /// A missing file must surface `loadError`, not fail invisibly.
    @Test func loadMissingFileSetsLoadError() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope_\(UUID().uuidString).wav")
        let engine = PlaybackEngine()
        engine.load(url: missing)
        #expect(engine.loadedURL == nil)
        #expect(engine.loadError != nil, "load() of a missing file should set loadError instead of failing silently")
    }

    /// `play()` must actually drive audio through the pipeline — checked via
    /// the spectrogram processor's own peak reading rather than by draining
    /// columns (see the note below on why that approach was flaky).
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

        // Asserted through the heterodyne oscillator the auto-tuner drives,
        // which is the end of the chain that actually matters: it can only be
        // parked here if the pacing thread read the file, handed a full window
        // to `TuningPeakDetector`, and that detector resolved the tone. The LO
        // sits `audibleOffsetHz` (1500 Hz) below the detected frequency.
        //
        // This used to read the playback `SpectrogramProcessor`'s own
        // `peakFrequency`. That processor is gone from the playback path —
        // it ran the whole live column pipeline on the pacing thread to
        // produce this one number, and nothing drew the columns (see
        // TuningPeakDetector). The measurement itself is covered directly and
        // deterministically in `TuningPeakDetectorTests`.
        let lo = engine.heterodyne.loFrequency
        #expect(lo > 36_500 && lo < 40_500,
                "heterodyne LO = \(lo) Hz after 400ms of playing a 40 kHz tone — auto-tune never saw the audio, so the file isn't reaching the listening path")

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

    // MARK: Seam envelope (hide-silence splices)

    /// The defect this replaced: both edges of every kept region were ramped
    /// to true zero, so the recording's background hiss dropped out completely
    /// twice per gap — at 8x expansion a ~32 ms hole shortly before every
    /// call. Crossfading into the next region's own run-up instead must leave
    /// no sample of the seam quieter than the material either side of it.
    @Test func seamCrossfadeNeverDropsToSilence() {
        let fade = 64
        let region = 0..<1_000
        var buf = [Float](repeating: 1, count: region.count)
        let incoming = [Float](repeating: 1, count: fade)
        incoming.withUnsafeBufferPointer { inc in
            buf.withUnsafeMutableBufferPointer { b in
                PlaybackDriver.applySeamEnvelope(b.baseAddress!, count: b.count, at: region.lowerBound,
                                                 in: region, fade: fade,
                                                 fadeInFromSilence: false, incoming: inc.baseAddress)
            }
        }
        // Equal-power weights over two same-level sources: level is held or
        // slightly raised through the splice, never dipped.
        #expect(buf.allSatisfy { $0 >= 1 && $0.isFinite },
                "seam dipped below the surrounding level: min \(buf.min() ?? 0)")
        // A region start that follows another region's crossfade is arrived
        // at, not faded into — its first sample is untouched.
        #expect(buf[0] == 1)
    }

    /// With nothing to cross into — the last region of a run — the old fade to
    /// silence is still the right ending, and the run's first region still
    /// fades up from it.
    @Test func firstAndLastEdgesStillFadeFromAndToSilence() {
        let fade = 64
        let region = 0..<1_000
        var buf = [Float](repeating: 1, count: region.count)
        buf.withUnsafeMutableBufferPointer { b in
            PlaybackDriver.applySeamEnvelope(b.baseAddress!, count: b.count, at: region.lowerBound,
                                             in: region, fade: fade,
                                             fadeInFromSilence: true, incoming: nil)
        }
        #expect(buf[0] == 0)
        #expect(buf[fade] == 1, "the ramp must not reach past `fade` samples into the call margin")
        #expect(buf[region.count - 1] < 0.05)
        #expect(buf[region.count - 1 - fade] == 1)
    }
}
