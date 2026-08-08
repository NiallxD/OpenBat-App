//
//  MicCalibrationTests.swift
//  OpenBatTests
//
//  MicCalibrationCurve's two application modes (direct index vs. frequency-
//  interpolated), and MicCalibrator's quality gates — each fed a synthetic
//  buffer engineered to trigger exactly one failure mode, so a regression in
//  any single gate shows up as a specific, named test failure rather than
//  "something about calibration broke."
//

import Testing
import AVFoundation
@testable import OpenBat

struct MicCalibrationCurveTests {

    @Test func applyMultipliesEachBinByItsOwnGain() {
        let curve = MicCalibrationCurve(binCount: 4, sampleRate: 384_000, fftSize: 8,
                                        gains: [1, 2, 0.5, 4], micName: "Test Mic", capturedAt: Date())
        var mags: [Float] = [10, 10, 10, 10]
        curve.apply(to: &mags)
        #expect(mags == [10, 20, 5, 40])
    }

    @Test func applyIsNoOpWhenBinCountMismatches() {
        let curve = MicCalibrationCurve(binCount: 4, sampleRate: 384_000, fftSize: 8,
                                        gains: [1, 2, 0.5, 4], micName: "Test Mic", capturedAt: Date())
        var mags: [Float] = [10, 10, 10] // wrong count — e.g. a differently-configured caller
        curve.apply(to: &mags)
        #expect(mags == [10, 10, 10])
    }

    @Test func gainAtFrequencyInterpolatesBetweenTheTwoNearestBins() {
        // sampleRate=8, fftSize=8 -> hzPerBin = 1, so bin index == Hz here.
        let curve = MicCalibrationCurve(binCount: 4, sampleRate: 8, fftSize: 8,
                                        gains: [1, 1, 2, 4], micName: "Test Mic", capturedAt: Date())
        let midway = curve.gain(atFrequencyHz: 2.5) // halfway between bin 2 (gain 2) and bin 3 (gain 4)
        #expect(abs(midway - 3.0) < 0.001)
    }

    @Test func gainAtFrequencyHandlesOutOfRangeEdges() {
        let curve = MicCalibrationCurve(binCount: 4, sampleRate: 8, fftSize: 8,
                                        gains: [1, 2, 3, 4], micName: "Test Mic", capturedAt: Date())
        #expect(curve.gain(atFrequencyHz: 0) == 1) // non-positive Hz -> neutral gain
        #expect(curve.gain(atFrequencyHz: 100) == 4) // far past Nyquist clamps to the last bin
    }
}

struct MicCalibratorTests {

    private let sampleRate = 384_000.0
    private let hopSize = 256.0
    private let windowLen = 512.0

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let ch = buffer.floatChannelData![0]
        for i in 0..<samples.count { ch[i] = samples[i] }
        return buffer
    }

    /// Enough samples to produce comfortably more columns than
    /// `MicCalibrator`'s 90%-of-target minimum for `seconds` of capture, at
    /// this file's window/hop grid (matches `MicCalibrator`'s own constants).
    private func sampleCount(forSeconds seconds: Double) -> Int {
        let columns = Int(sampleRate / hopSize * seconds) + 5
        return Int(windowLen) + columns * Int(hopSize)
    }

    @Test func steadyQuietNoiseProducesACurve() {
        let seconds = 0.1
        let samples = (0..<sampleCount(forSeconds: seconds)).map { _ in Float.random(in: -0.001...0.001) }
        let calibrator = MicCalibrator(sampleRate: sampleRate, captureSeconds: seconds)
        calibrator.feed(makeBuffer(samples))
        guard case .success(let curve) = calibrator.finish(micName: "Test Mic") else {
            Issue.record("Expected steady quiet noise to produce a curve")
            return
        }
        #expect(curve.micName == "Test Mic")
        #expect(curve.gains.count == 1024)
    }

    @Test func loudTransientDuringCaptureFails() {
        let seconds = 0.1
        var samples = (0..<sampleCount(forSeconds: seconds)).map { _ in Float.random(in: -0.001...0.001) }
        // A short, much louder BROADBAND burst partway through — a real sound
        // (a call, a knock, talking) happening during the supposedly-quiet
        // period. Broadband (not a single tone) so it unambiguously raises
        // the mean-across-bins level the detector actually watches, across
        // enough consecutive analysis windows to count as sustained.
        let burstStart = samples.count / 2
        for i in burstStart..<min(burstStart + 4000, samples.count) {
            samples[i] = Float.random(in: -0.3...0.3)
        }
        let calibrator = MicCalibrator(sampleRate: sampleRate, captureSeconds: seconds)
        calibrator.feed(makeBuffer(samples))
        guard case .failure(let reason) = calibrator.finish(micName: "Test Mic") else {
            Issue.record("Expected a loud transient to fail calibration")
            return
        }
        #expect(reason.contains("sound during"))
    }

    @Test func clippedSamplesFail() {
        let seconds = 0.1
        var samples = (0..<sampleCount(forSeconds: seconds)).map { _ in Float.random(in: -0.001...0.001) }
        samples[100] = 0.999 // input overload / handling noise
        let calibrator = MicCalibrator(sampleRate: sampleRate, captureSeconds: seconds)
        calibrator.feed(makeBuffer(samples))
        guard case .failure(let reason) = calibrator.finish(micName: "Test Mic") else {
            Issue.record("Expected clipping to fail calibration")
            return
        }
        #expect(reason.contains("overloaded"))
    }

    @Test func deadInputFails() {
        let seconds = 0.1
        let samples = [Float](repeating: 0, count: sampleCount(forSeconds: seconds))
        let calibrator = MicCalibrator(sampleRate: sampleRate, captureSeconds: seconds)
        calibrator.feed(makeBuffer(samples))
        guard case .failure(let reason) = calibrator.finish(micName: "Test Mic") else {
            Issue.record("Expected a dead/silent input to fail calibration")
            return
        }
        #expect(reason.contains("clear reading"))
    }

    @Test func interruptedCaptureFails() {
        let targetSeconds = 1.0
        // Only a tenth of the samples the target duration needs.
        let samples = (0..<sampleCount(forSeconds: targetSeconds / 10)).map { _ in Float.random(in: -0.001...0.001) }
        let calibrator = MicCalibrator(sampleRate: sampleRate, captureSeconds: targetSeconds)
        calibrator.feed(makeBuffer(samples))
        guard case .failure(let reason) = calibrator.finish(micName: "Test Mic") else {
            Issue.record("Expected a short capture to fail calibration")
            return
        }
        #expect(reason.contains("interrupted"))
    }
}
