//
//  AudioRecorderPreRollTests.swift
//  OpenBatTests
//
//  The pre-roll ring had NO test coverage at all — `OpenBatTests` had nothing for
//  `AudioRecorder` — and it is the part of the recorder where being wrong is
//  silent. A pre-roll that drops, duplicates or reorders samples still produces a
//  playable WAV of the right length; the only symptom is that the first seconds of
//  a recording are subtly wrong, which nobody notices without knowing what was
//  captured. It was rewritten from an Array (trimmed at the front, ~800 MB/s of
//  memmove) to a fixed ring on 2026-08-18, verified by hand-tracing the index
//  arithmetic, and shipped untested.
//
//  So these are round-trip tests: feed a signal whose every sample identifies its
//  own position, trigger, and assert the bytes on disk are exactly the last
//  `preRollSeconds` of what went in, in order. That fails loudly on a wrap bug, an
//  off-by-one, a stale-history bug or a rate-change splice — the four ways the
//  ring can go wrong.
//
//  Everything here drives the real object through its real public API (`append`,
//  `setArmed`, `setPulseActive`) and reads the real file it wrote. Nothing is
//  simulated, because the arithmetic under test is exactly the arithmetic that
//  runs in the field.
//

import AVFoundation
import Foundation
import Testing
@testable import OpenBat

/// `.serialized` is required, not tidiness. Every `AudioRecorder` writes into the
/// same `Recordings/Listening/<day>` folder under a filename stamped only to the
/// second, so two of these running at once produce the same path — and each test
/// deletes the file it found when it finishes. Run in parallel they clobber and
/// delete each other's recordings, and fail on a missing file rather than on
/// anything to do with the pre-roll.
@Suite(.serialized)
@MainActor
struct AudioRecorderPreRollTests {

    // 48 kHz keeps the test quick while exercising identical code — nothing in the
    // pre-roll path is rate-specific except the sample counts derived from it.
    private let sampleRate = 48_000.0
    private let framesPerBuffer = 2_400          // 50 ms

    // MARK: Signal

    /// Value for sample `i`, chosen so every position is distinguishable after the
    /// recorder's Float→Int16 conversion. A plain ramp would be useless: at 1/32767
    /// per step, neighbouring samples quantise to the same Int16 and a reordering
    /// would pass. This is effectively a per-index hash instead.
    private func value(at i: Int) -> Float {
        let scrambled = (i &* 2_654_435_761) % 30_000
        return (Float(scrambled) - 15_000) / 32_767
    }

    /// The recorder's own conversion — clip to [-1, 1], scale by 32767, truncate
    /// toward zero (`vDSP_vfix16`). Applied to expectations so the comparison is
    /// against what the file can actually hold, not against the input floats.
    private func quantised(_ v: Float) -> Int16 {
        Int16(min(max(v, -1), 1) * 32_767)
    }

    private func buffer(startingAt index: Int, frames: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        let ch = buf.floatChannelData![0]
        for j in 0..<frames { ch[j] = value(at: index + j) }
        return buf
    }

    /// Let the recorder queue drain what has been fed so far.
    ///
    /// `append` only enqueues a drain; a drain takes everything currently readable.
    /// Feeding a whole phase without yielding therefore lets ONE drain swallow the
    /// lot, so audio meant to arrive after `setPulseActive(false)` has already been
    /// consumed and the post-roll never counts down. Yielding between phases is
    /// what makes the ordering match the field, where buffers arrive 20 ms apart.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(60))
    }

    // MARK: Harness

    /// Feeds `bufferCount` buffers, triggers, feeds a little more, releases, and
    /// waits for the finished file. Returns the Int16 samples the recorder wrote
    /// and the absolute index of the next sample that would have been fed.
    private func record(preRollSeconds: Double,
                        buffersBeforeTrigger: Int,
                        buffersWhileActive: Int = 2,
                        mutate: ((AudioRecorder) -> Void)? = nil,
                        mutateAfter: Int? = nil) async throws -> (samples: [Int16], fedCount: Int) {
        let recorder = AudioRecorder()
        recorder.preRollSeconds = preRollSeconds
        // Short post-roll so the segment closes after a couple of buffers rather
        // than the 3 s default — nothing under test depends on its length.
        recorder.postRollSeconds = 0.05

        let saved = SavedReport()
        recorder.onRecordingSaved = { report in Task { await saved.set(report) } }
        recorder.setArmed(true)

        var fed = 0
        for b in 0..<buffersBeforeTrigger {
            if let mutateAfter, b == mutateAfter { mutate?(recorder) }
            recorder.append(buffer(startingAt: fed, frames: framesPerBuffer))
            fed += framesPerBuffer
        }

        await settle()

        // Queue ordering is what makes this deterministic: `append` enqueues a
        // drain and `setPulseActive` enqueues its own block on the SAME serial
        // queue, so every buffer above has been folded into the ring before the
        // trigger opens a segment.
        recorder.setPulseActive(true)
        for _ in 0..<buffersWhileActive {
            recorder.append(buffer(startingAt: fed, frames: framesPerBuffer))
            fed += framesPerBuffer
        }
        await settle()

        recorder.setPulseActive(false)
        // Enough buffers to exhaust the post-roll and close the segment.
        for _ in 0..<3 {
            recorder.append(buffer(startingAt: fed, frames: framesPerBuffer))
            fed += framesPerBuffer
            await settle()
        }

        // The recorder must outlive the wait. `closeAndKeep` reports through
        // `DispatchQueue.main.async { [weak self] ... }`, and ARC is free to release
        // a local at its last use — which is the final `append` above, well before
        // the render finishes and the report fires. Without this the callback finds
        // `self` already nil and the test times out having proved nothing. (Not a
        // product concern: ContentView owns the recorder for the app's lifetime.)
        let report = try #require(await saved.wait(), "recorder never reported a saved file")
        withExtendedLifetime(recorder) {}
        let url = CloudStorage.baseDirectory.appendingPathComponent(report.relativeWavPath)
        defer { try? FileManager.default.removeItem(at: url) }

        let format = try #require(WavHeader.describe(url: url))
        let raw = try Data(contentsOf: url)
        let start = Int(format.dataOffset)
        let count = Int(format.dataBytes) / 2
        var out = [Int16](repeating: 0, count: count)
        _ = out.withUnsafeMutableBytes { dst in
            raw.copyBytes(to: dst, from: start..<(start + count * 2))
        }
        return (out, fed)
    }

    // MARK: Tests

    /// The one the audit asked for: the file's opening samples are exactly the last
    /// `preRollSeconds` of audio fed BEFORE the trigger, in order.
    @Test func preRollHoldsTheAudioImmediatelyBeforeTheTrigger() async throws {
        let preRoll = 0.5
        let buffersBefore = 40                       // 2 s — comfortably more than the pre-roll
        let (samples, _) = try await record(preRollSeconds: preRoll,
                                            buffersBeforeTrigger: buffersBefore)

        let expectedPreRoll = Int(preRoll * sampleRate)
        #expect(samples.count > expectedPreRoll)

        // Audio fed before the trigger spans [0, fedBeforeTrigger); the pre-roll is
        // its final `expectedPreRoll` samples.
        let fedBeforeTrigger = buffersBefore * framesPerBuffer
        let firstExpectedIndex = fedBeforeTrigger - expectedPreRoll

        var mismatches = 0
        var firstMismatch = -1
        for k in 0..<expectedPreRoll {
            let want = quantised(value(at: firstExpectedIndex + k))
            if samples[k] != want {
                mismatches += 1
                if firstMismatch < 0 { firstMismatch = k }
            }
        }
        #expect(mismatches == 0,
                "\(mismatches) of \(expectedPreRoll) pre-roll samples wrong, first at \(firstMismatch)")
    }

    /// The pre-roll must be contiguous with the live audio that follows it — a
    /// wrap bug can leave the ring correct in isolation but joined to the post
    /// trigger stream with a gap or an overlap.
    @Test func preRollJoinsLiveAudioWithoutAGapOrRepeat() async throws {
        let preRoll = 0.5
        let buffersBefore = 40
        let (samples, _) = try await record(preRollSeconds: preRoll,
                                            buffersBeforeTrigger: buffersBefore)

        let expectedPreRoll = Int(preRoll * sampleRate)
        let firstExpectedIndex = buffersBefore * framesPerBuffer - expectedPreRoll

        // Check straight across the seam, not just within the pre-roll.
        let seamCheck = min(samples.count, expectedPreRoll + framesPerBuffer)
        for k in 0..<seamCheck {
            #expect(samples[k] == quantised(value(at: firstExpectedIndex + k)),
                    "sample \(k) breaks continuity across the pre-roll/live seam")
        }
    }

    /// The ring is allocated for the LONGEST pre-roll the slider offers, and
    /// `preRollWindow` narrows the read — so lengthening the setting mid-run must
    /// take effect immediately using history already held, not empty the buffer and
    /// hand the next trigger a truncated pre-roll. That regression is invisible
    /// except by listening to the start of a recording.
    @Test func lengtheningPreRollMidRunUsesHistoryAlreadyHeld() async throws {
        let buffersBefore = 60                       // 3 s of history
        let (samples, _) = try await record(preRollSeconds: 0.25,
                                            buffersBeforeTrigger: buffersBefore,
                                            mutate: { $0.preRollSeconds = 1.0 },
                                            mutateAfter: 30)

        // The setting was raised to 1 s well before the trigger; the ring held far
        // more than that, so the trigger must get the full second.
        let expected = Int(1.0 * sampleRate)
        #expect(samples.count > expected)
        let firstExpectedIndex = buffersBefore * framesPerBuffer - expected
        for k in stride(from: 0, to: expected, by: 97) {
            #expect(samples[k] == quantised(value(at: firstExpectedIndex + k)),
                    "pre-roll was truncated or refilled after the setting changed (sample \(k))")
        }
    }

    /// Asking for more pre-roll than has been captured yet must yield everything
    /// held and nothing more — never zeros, never stale samples from before the
    /// recorder started.
    @Test func shortHistoryYieldsOnlyWhatWasCaptured() async throws {
        let buffersBefore = 4                        // 200 ms, far less than the 1 s asked for
        let (samples, _) = try await record(preRollSeconds: 1.0,
                                            buffersBeforeTrigger: buffersBefore)

        let fedBeforeTrigger = buffersBefore * framesPerBuffer
        for k in 0..<fedBeforeTrigger {
            #expect(samples[k] == quantised(value(at: k)),
                    "sample \(k) is not the audio that was actually captured")
        }
    }

    /// A capture-rate change must rebuild the ring rather than carry samples across
    /// it. The Array version spliced audio captured at the old rate into the head of
    /// a file written at the new one — wrong duration and wrong pitch for the first
    /// seconds of the recording after a mic swap.
    @Test func rateChangeDoesNotSpliceOldRateAudioIntoTheNewSegment() async throws {
        let recorder = AudioRecorder()
        recorder.preRollSeconds = 0.5
        recorder.postRollSeconds = 0.05

        let saved = SavedReport()
        recorder.onRecordingSaved = { report in Task { await saved.set(report) } }
        recorder.setArmed(true)

        // Fill the ring at 96 kHz…
        let oldFormat = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 1)!
        for b in 0..<8 {
            let buf = AVAudioPCMBuffer(pcmFormat: oldFormat,
                                       frameCapacity: AVAudioFrameCount(framesPerBuffer))!
            buf.frameLength = AVAudioFrameCount(framesPerBuffer)
            let ch = buf.floatChannelData![0]
            // A constant, obviously-identifiable value that must NOT appear in the file.
            for j in 0..<framesPerBuffer { ch[j] = 0.75 }
            _ = b
            recorder.append(buf)
            await settle()
        }

        // …then switch to 48 kHz and feed a short, distinct run.
        var fed = 0
        for _ in 0..<4 {
            recorder.append(buffer(startingAt: fed, frames: framesPerBuffer))
            fed += framesPerBuffer
            await settle()
        }
        recorder.setPulseActive(true)
        for _ in 0..<2 {
            recorder.append(buffer(startingAt: fed, frames: framesPerBuffer))
            fed += framesPerBuffer
            await settle()
        }
        recorder.setPulseActive(false)
        for _ in 0..<3 {
            recorder.append(buffer(startingAt: fed, frames: framesPerBuffer))
            fed += framesPerBuffer
            await settle()
        }

        // The recorder must outlive the wait. `closeAndKeep` reports through
        // `DispatchQueue.main.async { [weak self] ... }`, and ARC is free to release
        // a local at its last use — which is the final `append` above, well before
        // the render finishes and the report fires. Without this the callback finds
        // `self` already nil and the test times out having proved nothing. (Not a
        // product concern: ContentView owns the recorder for the app's lifetime.)
        let report = try #require(await saved.wait())
        withExtendedLifetime(recorder) {}
        let url = CloudStorage.baseDirectory.appendingPathComponent(report.relativeWavPath)
        defer { try? FileManager.default.removeItem(at: url) }

        let format = try #require(WavHeader.describe(url: url))
        #expect(format.sampleRate == 48_000, "file should declare the rate it was written at")

        let raw = try Data(contentsOf: url)
        let start = Int(format.dataOffset)
        let count = Int(format.dataBytes) / 2
        var samples = [Int16](repeating: 0, count: count)
        _ = samples.withUnsafeMutableBytes { dst in
            raw.copyBytes(to: dst, from: start..<(start + count * 2))
        }

        // The 96 kHz filler was a constant 0.75; not one sample of it may survive.
        let stale = quantised(0.75)
        #expect(!samples.contains(stale),
                "audio captured at the previous rate was spliced into the new segment")
    }
}

/// Bridges the recorder's main-queue `onRecordingSaved` callback into async/await,
/// with a timeout so a failure to report shows up as a test failure rather than a
/// hung suite.
private actor SavedReport {
    private var report: RecordingReport?

    func set(_ r: RecordingReport) { report = r }

    func wait(timeout: Duration = .seconds(10)) async -> RecordingReport? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let report { return report }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return report
    }
}
