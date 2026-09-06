//
//  ConfigPasscodeTests.swift
//  OpenBatTests
//
//  The passcode is the only thing between an ordinary user and controls that
//  can break the app, so the one property that matters is that it tracks the
//  date — a code shared with a tester, or posted somewhere, has to stop working
//  tomorrow.
//

import Testing
import Foundation
@testable import OpenBat

struct ConfigPasscodeTests {

    private func date(_ day: Int, _ month: Int, _ year: Int) -> Date {
        var components = DateComponents()
        components.day = day; components.month = month; components.year = year
        components.hour = 12
        return Calendar.current.date(from: components)!
    }

    @Test func theCodeIsBatsPlusTheDate() {
        #expect(ConfigPasscode.today(date(6, 9, 2026)) == "Bats06092026")
        #expect(ConfigPasscode.today(date(31, 12, 2026)) == "Bats31122026")
        // Zero-padded both ways round, so a single-digit day and month can't
        // collide with a two-digit one.
        #expect(ConfigPasscode.today(date(1, 1, 2027)) == "Bats01012027")
    }

    @Test func yesterdaysCodeStopsWorking() {
        let today = date(6, 9, 2026)
        #expect(ConfigPasscode.accepts("Bats06092026", on: today))
        #expect(!ConfigPasscode.accepts("Bats05092026", on: today))
        #expect(!ConfigPasscode.accepts("Bats07092026", on: today))
    }

    /// Typed on a phone keyboard, which capitalises a field's first letter
    /// whether or not you want it to. Rejecting that would be a puzzle with no
    /// purpose.
    @Test func caseAndSurroundingSpaceDoNotMatter() {
        let today = date(6, 9, 2026)
        #expect(ConfigPasscode.accepts("bats06092026", on: today))
        #expect(ConfigPasscode.accepts("BATS06092026", on: today))
        #expect(ConfigPasscode.accepts("  Bats06092026 ", on: today))
    }

    @Test func nearMissesAreRejected() {
        let today = date(6, 9, 2026)
        #expect(!ConfigPasscode.accepts("", on: today))
        #expect(!ConfigPasscode.accepts("Bats", on: today))
        #expect(!ConfigPasscode.accepts("Bats6092026", on: today))
        #expect(!ConfigPasscode.accepts("Bats06092026x", on: today))
    }
}
