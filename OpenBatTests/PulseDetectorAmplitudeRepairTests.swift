//
//  PulseDetectorAmplitudeRepairTests.swift
//  OpenBatTests
//
//  Covers the one-time amplitude-threshold repair (2026-09-01).
//
//  Why this is worth pinning down: the setting it repairs was wrong on every
//  install for two weeks and nobody could see it, because the slider displayed
//  a value it was not applying. The repair is five lines that run once per
//  install and then never again, so a mistake in it is silent in exactly the
//  same way — the wrong threshold everywhere, with the UI agreeing.
//
//  The three cases below are the whole contract:
//
//    * a stale sub-0.5 value, written while the hidden frequency gate made it
//      unreachable, is raised — that is the regression fix;
//    * a value the user chose AFTER the repair survives every later launch —
//      that is what makes it a stamp and not a clamp, and it is the half that
//      is easy to lose by "simplifying" the stamp away;
//    * a fresh install is left alone and simply starts at the default.
//

import Foundation
import Testing
@testable import OpenBat

@MainActor
struct PulseDetectorAmplitudeRepairTests {

    /// A private defaults domain per test. `UserDefaults.standard` would make
    /// these tests order-dependent and single-use: the repair stamps itself,
    /// so a second run against the real domain would exercise nothing.
    private func makeSuite(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    private let key = "pulse.amplitudeThreshold"
    private let stamp = "pulse.amplitudeGateRepaired"

    @Test("A threshold saved while the hidden gate was in force is raised to 0.5")
    func repairsStaleValue() {
        let suite = makeSuite()
        // What the 2026-08-17 field tuning session left on every device.
        suite.set(Float(0.3), forKey: key)

        let detector = PulseDetector(defaults: suite)

        #expect(detector.amplitudeThreshold == 0.5)
        // Persisted, not just held in memory — otherwise the next launch reads
        // 0.3 back out and the repair undoes itself.
        #expect(suite.float(forKey: key) == 0.5)
        #expect(suite.bool(forKey: stamp))
    }

    @Test("A low threshold chosen after the repair survives relaunch")
    func preservesDeliberateChoice() {
        let suite = makeSuite()
        suite.set(Float(0.3), forKey: key)

        // First launch: repaired to 0.5.
        _ = PulseDetector(defaults: suite)
        #expect(suite.float(forKey: key) == 0.5)

        // The user now turns it down on purpose, knowing the slider works.
        suite.set(Float(0.3), forKey: key)

        // Every later launch must leave that alone. This is the assertion that
        // fails if the repair is ever rewritten as an unconditional clamp.
        _ = PulseDetector(defaults: suite)
        #expect(suite.float(forKey: key) == 0.3)

        let relaunched = PulseDetector(defaults: suite)
        #expect(relaunched.amplitudeThreshold == 0.3)
    }

    @Test("A fresh install starts at the default and is not treated as stale")
    func leavesFreshInstallAtDefault() {
        let suite = makeSuite()

        let detector = PulseDetector(defaults: suite)

        #expect(detector.amplitudeThreshold == 0.5)
        #expect(suite.bool(forKey: stamp))
    }

    @Test("A threshold already at or above 0.5 is untouched")
    func leavesHigherValueAlone() {
        let suite = makeSuite()
        suite.set(Float(0.7), forKey: key)

        let detector = PulseDetector(defaults: suite)

        #expect(detector.amplitudeThreshold == 0.7)
        #expect(suite.float(forKey: key) == 0.7)
    }
}
