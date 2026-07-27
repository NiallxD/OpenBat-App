//
//  ConsentVersionTests.swift
//  OpenBatTests
//
//  `ConsentStore.isGranted` gates every upload path, and it fails CLOSED — a
//  record it doesn't accept stops contributions with no error and no user
//  action. That makes both directions worth pinning: accepting a stale record
//  would mean uploading under terms the user never saw, and rejecting a valid
//  one would silently break contribution for everybody.
//
//  Tests the decision logic against `ConsentRecord` values directly rather than
//  through `ConsentStore`, which is a Keychain-backed singleton and can't be
//  instantiated per-test.
//

import Testing
import Foundation
@testable import OpenBat

struct ConsentVersionTests {

    private let current = ConsentStore.currentConsentVersion

    private func record(_ status: ConsentStatus, version: String) -> ConsentRecord {
        ConsentRecord(consentVersion: version, status: status,
                      grantedAt: status == .granted ? Date() : nil,
                      revokedAt: status == .revoked ? Date() : nil,
                      syncedAt: Date())
    }

    /// Mirrors `ConsentStore.isGranted`. If that changes, this must change with
    /// it — which is the point: the rule is short enough to state twice, and
    /// stating it twice makes a silent change to it fail here.
    private func isGranted(_ record: ConsentRecord?) -> Bool {
        guard let record, record.status == .granted else { return false }
        return record.consentVersion == ConsentStore.currentConsentVersion
    }

    private func needsReconsent(_ record: ConsentRecord?) -> Bool {
        guard let record, record.status == .granted else { return false }
        return record.consentVersion != ConsentStore.currentConsentVersion
    }

    // MARK: Granting

    @Test func currentVersionGrantIsAccepted() {
        #expect(isGranted(record(.granted, version: current)))
        #expect(!needsReconsent(record(.granted, version: current)))
    }

    /// The case this whole mechanism exists for: agreement to wording the app no
    /// longer shows must not count as agreement to the wording it does show.
    @Test func supersededVersionGrantIsNotLiveConsent() {
        let stale = record(.granted, version: "1.0")
        #expect(!isGranted(stale))
        #expect(needsReconsent(stale))
    }

    /// A downgraded app finding a newer stored version is in the same position:
    /// it cannot present, and so cannot claim agreement to, terms it doesn't
    /// have. Exact match rather than "at least this version" covers it.
    @Test func newerStoredVersionAlsoRequiresReconsent() {
        let ahead = record(.granted, version: "99.0")
        #expect(!isGranted(ahead))
        #expect(needsReconsent(ahead))
    }

    // MARK: Not granting

    @Test func revokedIsNeverGrantedAtAnyVersion() {
        #expect(!isGranted(record(.revoked, version: current)))
        #expect(!isGranted(record(.revoked, version: "1.0")))
    }

    /// Someone who declined, or whose consent predates nothing because they
    /// never gave any, must not be shown a "your terms changed" prompt — that
    /// would be nagging a person who already said no.
    @Test func revokedOrAbsentDoesNotAskForReconsent() {
        #expect(!needsReconsent(record(.revoked, version: "1.0")))
        #expect(!needsReconsent(record(.revoked, version: current)))
        #expect(!needsReconsent(nil))
    }

    @Test func absentRecordIsNotGranted() {
        #expect(!isGranted(nil))
    }

    // MARK: Invariants

    /// The two are mutually exclusive by construction — a record cannot both be
    /// live consent and be awaiting re-consent. A UI showing the review banner
    /// alongside an enabled contribution toggle would be incoherent.
    @Test func grantedAndNeedsReconsentAreMutuallyExclusive() {
        for status in [ConsentStatus.granted, .revoked] {
            for version in [current, "1.0", "0.9", "99.0"] {
                let r = record(status, version: version)
                #expect(!(isGranted(r) && needsReconsent(r)),
                        "status \(status) version \(version)")
            }
        }
    }

    /// Re-consenting has to actually resolve the state, or the prompt is a loop.
    @Test func regrantingAtCurrentVersionClearsReconsent() {
        let stale = record(.granted, version: "1.0")
        #expect(needsReconsent(stale))

        // What ConsentStore.grant() writes.
        let regranted = ConsentRecord(consentVersion: ConsentStore.currentConsentVersion,
                                      status: .granted, grantedAt: Date(),
                                      revokedAt: stale.revokedAt, syncedAt: nil)
        #expect(isGranted(regranted))
        #expect(!needsReconsent(regranted))
    }

    /// The app's constant and the Worker's `CURRENT_CONSENT_VERSION` have to be
    /// bumped together — they gate the same decision on opposite sides of the
    /// wire. This can't read the Worker's source, so it pins the app side and
    /// leaves a marker to grep for.
    @Test func currentVersionIsTheExpectedValue() {
        #expect(ConsentStore.currentConsentVersion == "2.0",
                "Bumped the app's consent version? Bump CURRENT_CONSENT_VERSION in backend/consent-worker/src/index.ts in the same deploy.")
    }
}
