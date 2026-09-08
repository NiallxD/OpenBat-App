//
//  DemoLoggerTests.swift
//  OpenBatTests
//
//  The demo log exists to answer one question — "do these two phones do the
//  same thing with the same audio" — and it can only answer it if it is off
//  when it should be off, self-contained when it is on, and honest about the
//  pulses nothing was asked to name.
//

import Testing
import Foundation
@testable import OpenBat

struct DemoLoggerTests {

    private func makeDefaults(enabled: Bool) -> UserDefaults {
        let domain = "openbat.tests.demolog.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        defaults.set(enabled, forKey: DemoLogger.enabledKey)
        return defaults
    }

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("demolog-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func result(_ species: String, _ confidence: Float) -> ClassificationResult {
        ClassificationResult(species: species, confidence: confidence,
                             allScores: [species: confidence], rawScores: [species: confidence])
    }

    /// The switch is the whole contract: off, a demo leaves nothing behind at
    /// all. Somebody who never turns this on must never find a file.
    @Test func nothingIsWrittenWhileTheSwitchIsOff() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        DemoLogger.shared.begin(clip: "clip", context: [], defaults: makeDefaults(enabled: false),
                                directory: dir)
        DemoLogger.shared.logPass(result("MYLU", 0.8), pulseCount: 3, modelID: "nabat")
        DemoLogger.shared.flush()

        #expect(DemoLogger.shared.currentLogURL == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    /// The header is half the point of the file — a run is only comparable if
    /// you know what it ran as. Everything the caller passes has to survive into
    /// it, in order, alongside the device this was recorded on.
    @Test func theHeaderCarriesTheContextAndTheDevice() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        DemoLogger.shared.begin(clip: "Demo Bat Calls",
                                context: [("model", "nabat"), ("amplitude_threshold", "0.500")],
                                defaults: makeDefaults(enabled: true), directory: dir)
        let url = try #require(DemoLogger.shared.currentLogURL)
        DemoLogger.shared.end()

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("# device: "))
        #expect(text.contains("# os: "))
        #expect(text.contains("# model: nabat"))
        #expect(text.contains("# amplitude_threshold: 0.500"))
        // The clip's spaces cannot reach the filename.
        #expect(!url.lastPathComponent.contains(" "))
        #expect(url.lastPathComponent.hasPrefix("demo_Demo-Bat-Calls_"))
    }

    /// A classified pulse, an unclassified one and the pass they belong to all
    /// land, and the unclassified row keeps its reason. That row is the one the
    /// field log cannot write and the one that distinguishes "heard less" from
    /// "named less".
    @Test func everyKindOfRowIsWritten() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        DemoLogger.shared.begin(clip: "clip", context: [],
                                defaults: makeDefaults(enabled: true), directory: dir)
        let url = try #require(DemoLogger.shared.currentLogURL)

        DemoLogger.shared.logClassifiedPulse(result("MYLU", 0.91), peakFreqHz: 45_000,
                                             durationMs: 3.2, modelID: "nabat")
        DemoLogger.shared.logUnclassifiedPulse(peakFreqHz: 38_000, durationMs: 2.1,
                                               note: "no active model")
        DemoLogger.shared.logPass(result("MYLU", 0.88), pulseCount: 4, modelID: "nabat")
        DemoLogger.shared.logUnclassifiedPass(pulseCount: 2, species: "UNID")
        DemoLogger.shared.end()
        DemoLogger.shared.flush()

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let rows = lines.filter { !$0.hasPrefix("#") && !$0.hasPrefix("time,") }

        try #require(rows.count == 4)
        #expect(rows[0].contains(",pulse,MYLU,0.9100,1,nabat,45.00,3.20,"))
        #expect(rows[1].contains(",pulse-unclassified,UNID,,1,,38.00,2.10,no active model"))
        #expect(rows[2].contains(",pass,MYLU,0.8800,4,nabat,,,"))
        #expect(rows[3].contains(",pass-unclassified,UNID,,2,,,,"))
    }

    /// A run that has ended stops accepting rows, so a live session started
    /// straight after a demo cannot append itself to the demo's file.
    @Test func nothingIsWrittenAfterTheRunEnds() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        DemoLogger.shared.begin(clip: "clip", context: [],
                                defaults: makeDefaults(enabled: true), directory: dir)
        let url = try #require(DemoLogger.shared.currentLogURL)
        DemoLogger.shared.end()
        DemoLogger.shared.logPass(result("MYLU", 0.8), pulseCount: 3, modelID: "nabat")
        DemoLogger.shared.flush()
        #expect(!DemoLogger.shared.isLogging)

        let rows = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.hasPrefix("time,") }
        #expect(rows.isEmpty)
    }

    /// A finished run says so. Without a footer, a run somebody stopped early and
    /// a run where the device stopped detecting look identical — the rows just
    /// stop — and that is a guess nobody should have to make about a file
    /// somebody else recorded.
    @Test func aFinishedRunRecordsHowItEnded() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        DemoLogger.shared.begin(clip: "clip", context: [],
                                defaults: makeDefaults(enabled: true), directory: dir)
        DemoLogger.shared.flush()
        let url = try #require(DemoLogger.shared.currentLogURL)
        DemoLogger.shared.logPass(result("MYLU", 0.8), pulseCount: 3, modelID: "nabat")
        DemoLogger.shared.end()
        DemoLogger.shared.flush()

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("# ended: "))
        #expect(text.contains("# elapsed_s: "))
        #expect(text.contains("# thermal_state_at_end: "))
        // The header's own thermal reading is taken before any work happens, so
        // the end-of-run one is the only one that can differ from "nominal".
        #expect(text.contains("# low_power_mode_at_end: "))
    }

    /// Conditions that change what the numbers mean, recorded so a reader does
    /// not have to assume them. Low Power Mode throttles the CPU, so a run made
    /// in it is indistinguishable from a run on slower hardware without this.
    @Test func theHeaderRecordsWhatWouldSkewThePerformance() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        DemoLogger.shared.begin(clip: "clip", context: [],
                                defaults: makeDefaults(enabled: true), directory: dir)
        let url = try #require(DemoLogger.shared.currentLogURL)
        DemoLogger.shared.end()
        DemoLogger.shared.flush()

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("# low_power_mode: "))
        #expect(text.contains("# memory_gb: "))
        #expect(text.contains("# processors: "))
    }

    /// One column per class per score kind, so the table is rectangular and a
    /// diff of two files lines up column for column.
    @Test func theColumnsAreTheUnionOfEveryModelsClasses() {
        let header = DemoLogger.shared.columnHeader.split(separator: ",").map(String.init)
        var codes = Set<String>()
        for model in ModelRegistry.all { for code in model.classNames { codes.insert(code) } }

        #expect(header.starts(with: ["time", "elapsed_s", "kind", "species", "confidence",
                                     "pulse_count", "model", "peak_khz", "duration_ms", "note",
                                     "skipped_capture", "skipped_classify", "skipped_picture"]))
        #expect(header.filter { $0.hasPrefix("adj_") }.count == codes.count)
        #expect(header.filter { $0.hasPrefix("raw_") }.count == codes.count)
    }

    /// A row carries the detector's running loss totals, so a file says whether
    /// the device kept up. Without these the only evidence that a phone dropped
    /// calls is a second phone disagreeing with it.
    @Test func aRowCarriesTheSkipCounters() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        DemoLogger.shared.begin(clip: "clip", context: [],
                                defaults: makeDefaults(enabled: true), directory: dir)
        DemoLogger.shared.flush()
        DemoLogger.shared.logPass(result("MYLU", 0.8), pulseCount: 3, modelID: "nabat",
                                  skippedCapture: 12, skippedClassify: 5)
        DemoLogger.shared.flush()
        let url = try #require(DemoLogger.shared.currentLogURL)
        DemoLogger.shared.end()

        let header = DemoLogger.shared.columnHeader.split(separator: ",").map(String.init)
        let row = try #require(String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .first { !$0.hasPrefix("#") && !$0.hasPrefix("time,") })
            .split(separator: ",", omittingEmptySubsequences: false).map(String.init)

        #expect(row[try #require(header.firstIndex(of: "skipped_capture"))] == "12")
        #expect(row[try #require(header.firstIndex(of: "skipped_classify"))] == "5")
    }
}
