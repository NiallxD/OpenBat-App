//
//  ClassificationLoggerTests.swift
//  OpenBatTests
//
//  Regression tests for the CSV log's column layout — the exact thing that broke
//  before: score columns were hardwired to NABat's class list, so every score
//  logged for any other model (BatDetect2) landed under names that didn't exist in
//  its output and came out as 0.0000. The fix made the columns the UNION of every
//  registered model's class codes plus a `model` column. These assert that shape
//  directly off `expectedHeader` / `makeRow` (exposed `internal` for this) so the
//  check is deterministic — no filesystem, no background queue, no real-log pollution.
//

import Testing
import Foundation
@testable import OpenBat

@MainActor
struct ClassificationLoggerTests {

    /// The union of every registered model's class codes, deduped and sorted — the
    /// score-column set the logger is supposed to use. Recomputed here independently
    /// so the test fails if the logger's own derivation drifts.
    private var expectedClassColumns: [String] {
        var seen = Set<String>()
        for model in ModelRegistry.all { for code in model.classNames { seen.insert(code) } }
        return seen.sorted()
    }

    /// Pins the exact header shape: fixed metadata columns, then the sorted
    /// union of every registered model's class codes.
    @Test func headerIsMetadataColumnsThenClassCodeUnion() {
        let expected = "timestamp,type,model,species,confidence_pct,pulse_count,"
            + expectedClassColumns.joined(separator: ",") + "\n"
        #expect(ClassificationLogger.shared.expectedHeader == expected)
    }

    /// Every registered model's codes must be present in the header — the
    /// essence of the fix this file guards against regressing.
    @Test func headerCoversBothModelsClassCodes() {
        let columns = Set(expectedClassColumns)
        for model in ModelRegistry.all {
            for code in model.classNames {
                #expect(columns.contains(code), "Header is missing class code \(code) from \(model.displayName)")
            }
        }
    }

    /// A row's scores land under the right class-code columns regardless of
    /// which model produced them, and every other model's columns read 0 —
    /// the actual bug this file exists to catch.
    @Test func rowPopulatesModelColumnAndAlignsScores() throws {
        let columns = expectedClassColumns
        try #require(columns.count >= 2)
        let codeA = columns[0]
        let codeB = columns[1]

        let result = ClassificationResult(
            species: codeA,
            confidence: 0.9,
            allScores: [codeA: 0.9, codeB: 0.1])
        let row = ClassificationLogger.shared.makeRow(
            type: "pass", date: Date(), result: result, pulseCount: 3, modelID: "test-model")

        let fields = row.trimmingCharacters(in: .newlines).components(separatedBy: ",")
        // Fixed metadata columns: timestamp,type,model,species,confidence_pct,pulse_count
        #expect(fields[1] == "pass")
        #expect(fields[2] == "test-model")       // the `model` column — was the bug's blind spot
        #expect(fields[3] == codeA)              // species
        #expect(fields[5] == "3")                // pulse_count
        #expect(fields.count == 6 + columns.count)

        // Score columns line up with the header order: codeA/codeB carry their
        // values, every other class column is a bare "0" — the compact form the
        // logger writes for structurally-absent classes (the ones belonging to
        // the model that didn't produce this row), which is about half the
        // file's bytes on a wide union header.
        for (i, code) in columns.enumerated() {
            let field = fields[6 + i]
            switch code {
            case codeA: #expect(field == "0.9000")
            case codeB: #expect(field == "0.1000")
            default:    #expect(field == "0")
            }
        }
    }
}
