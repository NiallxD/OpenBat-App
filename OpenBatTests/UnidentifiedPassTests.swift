//
//  UnidentifiedPassTests.swift
//  OpenBatTests
//
//  A recording made with species identification switched off — or simply with
//  no model chosen, which is how a fresh install starts — has to stay a usable
//  record. Before 2026-09-06 it was not: the detector found the calls, drew
//  them and counted them, and then threw the measurements away because nothing
//  had classified them, so the recording reported zero pulses and the
//  iNaturalist sheet refused it outright.
//

import Testing
import Foundation
@testable import OpenBat

struct UnidentifiedPassTests {

    // MARK: What it is, and what it is not

    /// The distinction the whole change rests on. NoID is a model's inconclusive
    /// answer and marks a recording as junk — "Delete NoID Recordings" exists to
    /// sweep those up. A recording nothing was asked about is not junk, and must
    /// never be one tap from deletion.
    @Test func unidentifiedIsNotNoID() {
        let unidentified = PassRecord(id: UUID(), date: Date(), species: "UNID",
                                      commonName: "Not identified", confidence: 0,
                                      pulseCount: 4, pulses: [])
        #expect(unidentified.isUnidentified)
        #expect(!unidentified.isNoID)
        #expect(!unidentified.isNoise)

        let noID = PassRecord(id: UUID(), date: Date(), species: "NOID",
                              commonName: "Unidentified", confidence: 0,
                              pulseCount: 4, pulses: [])
        #expect(noID.isNoID)
        #expect(!noID.isUnidentified)
    }

    @Test func theCodeHasAReadableName() {
        #expect(SpeciesInfo.commonName["UNID"] == "Not identified")
    }

    // MARK: Keeping the recording

    /// A segment whose calls were never classified is saved, not discarded —
    /// the audio is the whole point and nothing about it is worse for the
    /// absence of a name.
    @Test func anUnidentifiedSegmentIsKept() {
        #expect(!AudioRecorder.rejectsSegment(.unidentified(pulseCount: 4)))
        #expect(!AudioRecorder.rejectsSegment(.unidentified(pulseCount: 2)))
    }

    /// The lone-trigger rule still applies. One pulse with silence either side
    /// is a knock or a footfall whether or not a model was there to have an
    /// opinion about it.
    @Test func aLoneUnidentifiedTriggerIsStillDiscarded() {
        #expect(AudioRecorder.rejectsSegment(.unidentified(pulseCount: 1)))
    }

    /// The old case is untouched: nothing detected at all still reads as NoID
    /// with a count of zero, and is still kept.
    @Test func nothingDetectedIsStillNoID() {
        #expect(!AudioRecorder.rejectsSegment(.noID(pulseCount: 0)))
        #expect(AudioRecorder.rejectsSegment(.noID(pulseCount: 1)))
    }
}
