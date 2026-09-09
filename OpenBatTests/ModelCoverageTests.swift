//
//  ModelCoverageTests.swift
//  OpenBatTests
//
//  The rule that replaced the "Suggested Model" card on 2026-09-08: where the
//  phone is decides which classifier runs, and being outside every model's
//  coverage means none of them does.
//
//  Tested here rather than through the UI because each case is a border
//  crossing — a pair of coordinates thousands of kilometres apart — and there is
//  no way to tap your way from one to the next.
//
//  The coordinates are picked to sit well inside (or well outside) the coverage
//  boxes in `ModelRegistry`, never near an edge: this asserts the switching
//  behaviour, not where exactly the authors drew the boundary, so nudging a box
//  by a degree must not turn these red.
//

import Testing
import Foundation
import CoreLocation
@testable import OpenBat

struct ModelCoverageTests {

    private let squamish  = CLLocationCoordinate2D(latitude: 49.70, longitude: -123.16)
    private let london    = CLLocationCoordinate2D(latitude: 51.51, longitude: -0.13)
    /// Outside both boxes — NABat stops at 50°W, BatDetect2 at 2°E.
    private let melbourne = CLLocationCoordinate2D(latitude: -37.81, longitude: 144.96)

    @Test func aFreshInstallIdentifiesNothingUntilAFixArrives() {
        let settings = AutoIDSettings()
        #expect(settings.activeModelID == nil)
    }

    @Test func theFirstFixTurnsOnTheModelThatCoversIt() {
        let settings = AutoIDSettings()
        let change = settings.applyCoverage(at: squamish)

        #expect(settings.activeModelID == ModelRegistry.nabatID)
        guard case .switchedTo(let model)? = change else {
            Issue.record("expected a switch, got \(String(describing: change))")
            return
        }
        #expect(model.id == ModelRegistry.nabatID)
    }

    @Test func crossingIntoAnotherModelsRangeSwitchesToIt() {
        let settings = AutoIDSettings()
        settings.applyCoverage(at: squamish)

        let change = settings.applyCoverage(at: london)
        #expect(settings.activeModelID == ModelRegistry.batDetect2ID)
        guard case .switchedTo(let model)? = change else {
            Issue.record("expected a switch, got \(String(describing: change))")
            return
        }
        #expect(model.id == ModelRegistry.batDetect2ID)
    }

    /// The half that matters most: a North American classifier left running in
    /// Australia would not fail, it would confidently name Australian bats after
    /// American ones.
    @Test func leavingEveryModelsRangeTurnsIdentificationOff() {
        let settings = AutoIDSettings()
        settings.applyCoverage(at: squamish)

        let change = settings.applyCoverage(at: melbourne)
        #expect(settings.activeModelID == nil)
        guard case .turnedOff(let previous)? = change else {
            Issue.record("expected a turn-off, got \(String(describing: change))")
            return
        }
        #expect(previous.id == ModelRegistry.nabatID)
    }

    /// Nothing to report is reported as nothing — otherwise every fix inside the
    /// same coverage would raise the "New Area" sheet.
    @Test func movingWithinTheSameCoverageChangesNothing() {
        let settings = AutoIDSettings()
        settings.applyCoverage(at: squamish)

        let vancouver = CLLocationCoordinate2D(latitude: 49.28, longitude: -123.12)
        #expect(settings.applyCoverage(at: vancouver) == nil)
        #expect(settings.activeModelID == ModelRegistry.nabatID)
    }

    /// A fix arriving somewhere uncovered, with nothing active, is not an event —
    /// it is the state a fresh install is already in.
    @Test func anUncoveredFirstFixReportsNothing() {
        let settings = AutoIDSettings()
        #expect(settings.applyCoverage(at: melbourne) == nil)
        #expect(settings.activeModelID == nil)
    }
}
