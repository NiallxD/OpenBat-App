//
//  SettingsResetTests.swift
//  OpenBatTests
//
//  "Reset all settings" clears preferences and nothing else. The list of what
//  survives is short, and every entry on it is something that would cost the
//  user real work — or somebody else real work — if it went. These tests are
//  that list, written down where it fails loudly.
//

import Testing
import Foundation
@testable import OpenBat

struct SettingsResetTests {

    /// Each test gets its own suite so nothing here can touch the real domain.
    private func makeDefaults(_ name: String) -> (UserDefaults, String) {
        let domain = "openbat.tests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        return (defaults, domain)
    }

    @Test func preferencesAreCleared() {
        let (defaults, domain) = makeDefaults("prefs")
        defaults.set(false, forKey: "ui.simplifiedMode")
        defaults.set(0.9, forKey: "pulse.amplitudeThreshold")
        defaults.set("inferno", forKey: "pulse.displayPalette")
        defaults.set(0.75, forKey: "MapPinMinConfidence")

        let cleared = SettingsReset.eraseUserPreferences(in: defaults, domain: domain)

        #expect(cleared.count == 4)
        #expect(defaults.object(forKey: "ui.simplifiedMode") == nil)
        #expect(defaults.object(forKey: "pulse.amplitudeThreshold") == nil)
        #expect(defaults.object(forKey: "pulse.displayPalette") == nil)
        #expect(defaults.object(forKey: "MapPinMinConfidence") == nil)
    }

    /// The device id ties this install to its uploads and to the consent record
    /// in the Keychain. A new one orphans both.
    @Test func theDeviceIDSurvives() {
        let (defaults, domain) = makeDefaults("identity")
        defaults.set("device-abc", forKey: "openbat.deviceID")

        SettingsReset.eraseUserPreferences(in: defaults, domain: domain)

        #expect(defaults.string(forKey: "openbat.deviceID") == "device-abc")
    }

    /// Clearing the ledger would re-offer recordings already on iNaturalist and
    /// undo the per-night posting cap — which is a cost paid by iNaturalist's
    /// volunteers, not by the person who pressed the button.
    @Test func thePostingLedgerSurvives() {
        let (defaults, domain) = makeDefaults("ledger")
        defaults.set(["recording-1"], forKey: "openbat.inat.posted")

        SettingsReset.eraseUserPreferences(in: defaults, domain: domain)

        #expect(defaults.stringArray(forKey: "openbat.inat.posted") == ["recording-1"])
    }

    /// Resetting this does not move a single file — it points the app at the
    /// other container, and the library reads as empty.
    @Test func theStorageLocationSurvives() {
        let (defaults, domain) = makeDefaults("storage")
        defaults.set(true, forKey: "storage.usesUbiquityContainer")

        SettingsReset.eraseUserPreferences(in: defaults, domain: domain)

        #expect(defaults.bool(forKey: "storage.usesUbiquityContainer"))
    }

    /// Onboarding and What's New record something that happened. Wiping them
    /// re-runs the intro over an app already full of recordings.
    @Test func milestonesSurvive() {
        let (defaults, domain) = makeDefaults("milestones")
        defaults.set(true, forKey: "onboarding.hasCompletedWelcome")
        defaults.set(201, forKey: "release.lastSeenBuild")

        SettingsReset.eraseUserPreferences(in: defaults, domain: domain)

        #expect(defaults.bool(forKey: "onboarding.hasCompletedWelcome"))
        #expect(defaults.integer(forKey: "release.lastSeenBuild") == 201)
    }

    /// A calibration is a measurement of a microphone, not an opinion about it,
    /// and the key is written per microphone — hence a prefix rather than a
    /// name.
    @Test func micCalibrationSurvivesWhateverItIsCalled() {
        let (defaults, domain) = makeDefaults("miccal")
        defaults.set(true, forKey: "MicCal.enabled")
        defaults.set(["Griff"], forKey: "MicCal.offeredMics")
        defaults.set(-3.5, forKey: "MicCal.gain.Griff")

        SettingsReset.eraseUserPreferences(in: defaults, domain: domain)

        #expect(defaults.bool(forKey: "MicCal.enabled"))
        #expect(defaults.stringArray(forKey: "MicCal.offeredMics") == ["Griff"])
        #expect(defaults.double(forKey: "MicCal.gain.Griff") == -3.5)
    }

    /// The remote kill switches' local overrides are preferences, and a reset is
    /// exactly when somebody wants them gone — they are the one thing that can
    /// make two devices behave differently on the same config file.
    @Test func localFeatureOverridesAreCleared() {
        let (defaults, domain) = makeDefaults("flags")
        defaults.set(["automaticID"], forKey: "config.localFeatureOverrides")

        SettingsReset.eraseUserPreferences(in: defaults, domain: domain)

        #expect(defaults.object(forKey: "config.localFeatureOverrides") == nil)
    }

    @Test func anEmptyDomainIsNotAnError() {
        let (defaults, domain) = makeDefaults("empty")
        #expect(SettingsReset.eraseUserPreferences(in: defaults, domain: domain).isEmpty)
    }
}
