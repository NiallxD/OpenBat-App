//
//  BD2EvalHarnessTests.swift
//  OpenBatTests
//
//  The app's arm of the BatDetect2 accuracy comparison (`tools/bd2_eval/`).
//
//  WHY THIS LIVES IN THE TEST TARGET
//  ---------------------------------
//  The thing being measured is the app's real detection path, and half of it
//  cannot be compiled for macOS: `PulseDetector` imports UIKit, and the
//  classifier is a Core ML model loaded from the app bundle. A command-line
//  tool would therefore have to be a re-implementation — which is exactly what
//  an accuracy comparison must not be, because then the number describes the
//  copy. Running inside the test host on the simulator gets the shipping
//  objects: the same `SpectrogramProcessor` columns, the same `PulseDetector`
//  trigger, the same `BatDetect2Classifier`, the same `PassAggregation` rule.
//
//  WHAT IT IS NOT
//  --------------
//  Not a test. It asserts nothing about correctness; it writes a JSON-lines
//  file for `compare.py` to score. It is skipped unless `OPENBAT_EVAL_INPUT` is
//  set, so a normal test run never sees it.
//
//  DIFFERENCES FROM THE LIVE PATH, STATED UP FRONT
//  -----------------------------------------------
//  - Every detected pulse is classified. Live, the render+classify path is
//    rate-limited against wall-clock (`PulseDetector.capturesSkipped`), so a
//    busy pass loses some. Offline there is no deadline, and a throughput limit
//    measured on a machine feeding audio faster than real time would be
//    meaningless.
//  - No location priors: `prior` returns 1 for every class, so what is compared
//    is the model against the model, not OpenBat's range knowledge against
//    BatDetect2's lack of it.
//  - Passes are cut by the same silence timeout the app uses, but a 5 s clip
//    usually holds one, so the file-level verdict is normally one pass's.
//
//  Environment:
//    OPENBAT_EVAL_INPUT    directory searched recursively for .wav (required)
//    OPENBAT_EVAL_OUTPUT   directory for app_arm.jsonl and tensors/ (required)
//    OPENBAT_EVAL_LIMIT    stop after N files (default: all)
//    OPENBAT_EVAL_TENSORS  "1" to dump the 128×256 input tensor per pulse, for
//                          the PyTorch arm (run_pytorch_arm.py consumes them)
//    OPENBAT_EVAL_BAND_LOW / _BAND_HIGH  peak-search band as a fraction of
//                          Nyquist; defaults match the app's own 0.02–0.45
//    OPENBAT_EVAL_AMPLITUDE   trigger threshold override (default: the app's
//                          own 0.5). These recordings come off the Griff's own
//                          card rather than through the app's input gain, and
//                          at 0.5 the trigger fires on almost none of them, so
//                          the comparison is worth running at more than one
//                          value — the setting used is written into every
//                          record.
//    OPENBAT_EVAL_MIN_FREQ_KHZ  pitch gate override (default: the app's 15 kHz)
//    OPENBAT_EVAL_SKIP_CLASSIFY  "1" to render each pulse's tensor but not run
//                          Core ML on it. On a simulator its answer is zeros
//                          anyway (see tools/bd2_eval/README.md) and the score
//                          comes from the host, so the inference is pure cost.
//

import Testing
import Foundation
import AVFoundation
@testable import OpenBat

@MainActor
struct BD2EvalHarnessTests {

    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    /// `nonisolated` so `.enabled(if:)` can read it: the trait's condition is
    /// evaluated in a Sendable closure, outside the main actor this type is
    /// otherwise pinned to.
    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["OPENBAT_EVAL_INPUT"] != nil
    }

    /// The app's native capture rate. Every file in the library is a Griff
    /// recording at this rate; anything else is skipped rather than resampled,
    /// because `BatDetect2Classifier` hard-codes 384 kHz for its input and a
    /// silently-wrong rate would show up as an accuracy difference.
    private static let captureRate: Double = 384_000

    @Test(.enabled(if: BD2EvalHarnessTests.isEnabled))
    func runLibrary() async throws {
        let env = Self.env
        let inputDir = URL(fileURLWithPath: env["OPENBAT_EVAL_INPUT"]!)
        guard let outPath = env["OPENBAT_EVAL_OUTPUT"] else {
            Issue.record("OPENBAT_EVAL_OUTPUT is required")
            return
        }
        let outputDir = URL(fileURLWithPath: outPath)
        let dumpTensors = env["OPENBAT_EVAL_TENSORS"] == "1"
        let limit = env["OPENBAT_EVAL_LIMIT"].flatMap(Int.init)
        let bandLow = env["OPENBAT_EVAL_BAND_LOW"].flatMap(Double.init) ?? 0.02
        let bandHigh = env["OPENBAT_EVAL_BAND_HIGH"].flatMap(Double.init) ?? 0.45
        let amplitude = env["OPENBAT_EVAL_AMPLITUDE"].flatMap(Float.init)
        let skipClassify = env["OPENBAT_EVAL_SKIP_CLASSIFY"] == "1"
        let minFrequencyHz = env["OPENBAT_EVAL_MIN_FREQ_KHZ"].flatMap(Double.init).map { $0 * 1000 }

        let fm = FileManager.default
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let tensorDir = outputDir.appendingPathComponent("tensors")
        if dumpTensors { try? fm.createDirectory(at: tensorDir, withIntermediateDirectories: true) }

        var files: [URL] = []
        if let walker = fm.enumerator(at: inputDir, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension.lowercased() == "wav" {
                files.append(url)
            }
        }
        files.sort { $0.path < $1.path }
        if let limit { files = Array(files.prefix(limit)) }
        guard !files.isEmpty else {
            Issue.record("no .wav files under \(inputDir.path)")
            return
        }

        // Resume support: a run over a thousand files is long enough that being
        // able to restart it matters more than the code it costs.
        let jsonlURL = outputDir.appendingPathComponent("app_arm.jsonl")
        var done = Set<String>()
        if let existing = try? String(contentsOf: jsonlURL, encoding: .utf8) {
            for line in existing.split(separator: "\n") {
                if let data = line.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let file = obj["file"] as? String {
                    done.insert(file)
                }
            }
        }
        if !fm.fileExists(atPath: jsonlURL.path) { fm.createFile(atPath: jsonlURL.path, contents: nil) }
        let sink = try FileHandle(forWritingTo: jsonlURL)
        try sink.seekToEnd()
        defer { try? sink.close() }

        guard let descriptor = ModelRegistry.descriptor(id: ModelRegistry.batDetect2ID),
              let classifier = descriptor.makeClassifier() else {
            Issue.record("BatDetect2 model unavailable — is BatDetect2.mlpackage in the app bundle?")
            return
        }

        let started = Date()
        var processed = 0
        for file in files {
            let relative = Self.relativePath(of: file, under: inputDir)
            if done.contains(relative) { continue }
            guard let record = try Self.process(file: file,
                                                relative: relative,
                                                classifier: classifier,
                                                descriptor: descriptor,
                                                bandLow: bandLow,
                                                bandHigh: bandHigh,
                                                amplitude: amplitude,
                                                minFrequencyHz: minFrequencyHz,
                                                skipClassify: skipClassify,
                                                tensorDir: dumpTensors ? tensorDir : nil)
            else { continue }
            let line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            sink.write(line)
            sink.write(Data("\n".utf8))
            processed += 1
            if processed % 25 == 0 {
                let rate = Double(processed) / Date().timeIntervalSince(started)
                print("[bd2_eval] \(processed)/\(files.count - done.count) files, \(String(format: "%.1f", rate)) files/s")
            }
        }
        print("[bd2_eval] wrote \(processed) records to \(jsonlURL.path)")
    }

    // MARK: One recording

    /// Runs detection and classification over one WAV and returns its record.
    /// Returns nil for a file the harness will not speak for — wrong sample
    /// rate, or unreadable — rather than filing an empty result that would score
    /// as "OpenBat found nothing".
    private static func process(file: URL,
                                relative: String,
                                classifier: SpeciesClassifier,
                                descriptor: ModelDescriptor,
                                bandLow: Double,
                                bandHigh: Double,
                                amplitude: Float?,
                                minFrequencyHz: Double?,
                                skipClassify: Bool,
                                tensorDir: URL?) throws -> [String: Any]? {

        guard let audioFile = try? AVAudioFile(forReading: file) else { return nil }
        let sampleRate = audioFile.fileFormat.sampleRate
        let totalSamples = Int(audioFile.length)
        guard abs(sampleRate - captureRate) < 1, totalSamples > 0 else {
            print("[bd2_eval] skipping \(relative): \(Int(sampleRate)) Hz, expected \(Int(captureRate))")
            return nil
        }
        guard let pcm = WavPCMReader.readSamples(wavURL: file, startSample: 0, count: totalSamples) else {
            return nil
        }

        // --- Detection: the live loop, minus the display -------------------
        //
        // Mirrors `BackgroundDetectionPump.pump()`, which is itself the drain
        // half of `SpectrogramRenderer.draw(in:)`. Feeding in buffer-sized
        // chunks rather than one giant buffer keeps the column cadence and the
        // pending-column backpressure identical to the live path.
        let processor = SpectrogramProcessor()
        processor.sampleRate = sampleRate
        processor.peakMinFraction = max(bandLow, 0.01)
        processor.peakMaxFraction = bandHigh

        let detector = PulseDetector(defaults: Self.scratchDefaults())
        if let amplitude { detector.amplitudeThreshold = amplitude }
        if let minFrequencyHz { detector.minFrequencyHz = minFrequencyHz }
        var onsets: [Int] = []
        detector.onPulseWindow = { onset, _ in onsets.append(onset) }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        let chunk = 4096
        let columnsPerSecond = sampleRate / Double(processor.hopSize)
        var offset = 0
        while offset < pcm.count {
            let n = min(chunk, pcm.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            buffer.frameLength = AVAudioFrameCount(n)
            pcm.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress! + offset, count: n)
            }
            processor.process(buffer)
            for column in processor.drain() {
                detector.feed(peakLevel: column.peakLevel,
                              peakFrequency: processor.frequency(forBin: column.peakBin),
                              columnEndSample: column.endSample,
                              columnsPerSecond: columnsPerSecond,
                              sampleRate: sampleRate)
            }
            offset += n
        }

        // --- Classification: the same window the live path hands the model --
        //
        // Cut exactly as `ClassifierAnalysis.run` cuts it, which in turn copies
        // `PulseDetector.scheduleCapture`. A window framed differently would be
        // answering a different question.
        let spec = descriptor.input
        let clsCount = max(PulseImageRenderer.fftLen, Int(spec.windowSeconds * sampleRate))
        var tensorBlob = Data()
        var pulses: [[String: Any]] = []
        var aggPulses: [PassAggregation.Pulse] = []
        var skipped = 0

        for onset in onsets {
            let start = onset - Int(Double(clsCount) * spec.onsetFraction)
            guard start >= 0, start + clsCount <= pcm.count else { skipped += 1; continue }
            let window = Array(pcm[start..<(start + clsCount)])
            var result: ClassificationResult?
            if !skipClassify {
                result = classifier.classify(pcm: window, gate: .disabled, prior: { _ in 1 })
                if result == nil { skipped += 1; continue }
            }
            if tensorDir != nil {
                let resampled = PolyphaseResampler.resample(window, from: sampleRate,
                                                            to: BatDetect2SpectrogramRenderer.targetSampleRate)
                if let rendered = BatDetect2SpectrogramRenderer.render(pcm: resampled) {
                    rendered.image.withUnsafeBufferPointer { tensorBlob.append(Data(buffer: $0)) }
                } else {
                    // Keep blob index ↔ pulse index aligned; a short write would
                    // silently misattribute every score after it.
                    tensorBlob.append(Data(count: BatDetect2SpectrogramRenderer.outH
                                           * BatDetect2SpectrogramRenderer.outW * 4))
                }
            }
            if let result {
                aggPulses.append(.init(rawScores: result.rawScores, adjustedScores: result.allScores))
            }
            pulses.append([
                "onset_seconds": Double(onset) / sampleRate,
                "species": result?.species ?? "",
                "confidence": Double(result?.confidence ?? 0),
                "raw": (result?.rawScores ?? [:]).mapValues { Double($0) },
            ])
        }

        if let tensorDir, !tensorBlob.isEmpty {
            let name = relative.replacingOccurrences(of: "/", with: "_") + ".f32"
            try tensorBlob.write(to: tensorDir.appendingPathComponent(name))
        }

        // --- Passes and the file's verdict ---------------------------------
        let timeout = AutoIDSettings.defaultPassTimeoutSeconds
        var passes: [[String: Any]] = []
        var group: [Int] = []
        func closeGroup() {
            guard !group.isEmpty else { return }
            // With classification skipped there is nothing to aggregate: the
            // pass boundaries are still the app's, and compare.py re-derives
            // the verdict from the host's scores by the same rule.
            guard !aggPulses.isEmpty else {
                passes.append([
                    "pulse_count": group.count,
                    "start_seconds": pulses[group.first!]["onset_seconds"] as Any,
                    "end_seconds": pulses[group.last!]["onset_seconds"] as Any,
                    "recorded": group.count >= PulseDetector.minRecordedPassPulseCount,
                    "species": "UNSCORED",
                ])
                group = []
                return
            }
            let members = group.map { aggPulses[$0] }
            let verdict = PassAggregation.aggregate(
                members,
                minAdjustedConfidence: 0.05,
                minPulseCount: 1,
                rawConfidenceThreshold: descriptor.noidRawConfidenceThreshold,
                noiseClassName: descriptor.noiseClassName,
                minWinningMargin: 0)
            var entry: [String: Any] = [
                "pulse_count": members.count,
                "start_seconds": pulses[group.first!]["onset_seconds"] as Any,
                "end_seconds": pulses[group.last!]["onset_seconds"] as Any,
                // The pass gate the app applies before a pass is even filed —
                // a lone trigger is not a pass (PulseDetector.finalizePass).
                "recorded": members.count >= PulseDetector.minRecordedPassPulseCount,
            ]
            if let outcome = verdict.outcome {
                entry["species"] = outcome.species
                entry["confidence"] = Double(outcome.confidence)
                entry["mean_raw_confidence"] = Double(outcome.meanRawConfidence)
            } else {
                entry["species"] = "NOID"
                entry["noid_reason"] = verdict.noIDReason?.rawValue ?? "unknown"
            }
            passes.append(entry)
            group = []
        }
        for (i, pulse) in pulses.enumerated() {
            let t = pulse["onset_seconds"] as! Double
            if let last = group.last, t - (pulses[last]["onset_seconds"] as! Double) > timeout { closeGroup() }
            group.append(i)
        }
        closeGroup()

        return [
            "file": relative,
            // The trigger the numbers were produced with. Two runs at
            // different thresholds are two different experiments, and the
            // report has to be able to tell them apart after the fact.
            "settings": [
                "amplitude_threshold": Double(detector.amplitudeThreshold),
                "min_frequency_hz": detector.minFrequencyHz,
                "trigger_mode": detector.triggerMode.rawValue,
                "hold_off_seconds": detector.holdOffSeconds,
                "max_gap_ms": detector.maxGapMs,
                "min_consecutive_columns": detector.minConsecutiveColumns,
                "band_low": bandLow,
                "band_high": bandHigh,
            ],
            "duration_seconds": Double(totalSamples) / sampleRate,
            "pulses_detected": onsets.count,
            "pulses_classified": pulses.count,
            "pulses_skipped": skipped,
            "pulses": pulses,
            "passes": passes,
        ]
    }

    // MARK: Helpers

    /// A defaults suite the harness owns, wiped each run, so the numbers come
    /// from the app's compiled/remote defaults rather than from whatever the
    /// simulator's last interactive session left behind.
    private static func scratchDefaults() -> UserDefaults {
        let name = "bd2eval.scratch"
        UserDefaults.standard.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name) ?? .standard
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let full = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard full.hasPrefix(base) else { return url.lastPathComponent }
        return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
