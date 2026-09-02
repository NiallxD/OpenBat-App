//
//  LoneTriggerRejectionTests.swift
//  OpenBatTests
//
//  A pass of one pulse is a knock, not a bat — bats call in trains. Measured
//  against the Squamish session of 2026-09-01: twenty of its thirty-nine NoID
//  passes were single-pulse, while every pass the classifier could name carried
//  two or more (2, 4, 4, 4, 8, 10, 30).
//
//  The rule is applied in two places that aggregate independently — the detector
//  over its pass, the recorder over its own segment span — because dropping the
//  pass from the history without dropping the segment would leave the WAV on
//  disk, which is the half the user actually sees. These tests pin the recorder
//  half, where the subtlety lives.
//
//  The case worth protecting is `pulseCount == 0`. It does NOT mean "nothing
//  happened" — it means nothing was CLASSIFIED during the segment, which happens
//  when no AutoID model is active or when classification simply can't keep up.
//  A feeding buzz does exactly that. Rejecting those would silently delete real
//  recordings on the busiest passes of the night, which is the worst possible
//  place to lose data and the least likely place to notice.
//

import Foundation
import Testing
@testable import OpenBat

struct LoneTriggerRejectionTests {

    typealias Outcome = AudioRecorder.AutoIDOutcome

    @Test("A single-pulse NoID segment is thrown away")
    func rejectsLoneTrigger() {
        #expect(AudioRecorder.rejectsSegment(.noID(pulseCount: 1)))
    }

    @Test("A NoID segment with nothing classified is KEPT, not treated as a lone trigger")
    func keepsUnclassifiedSegment() {
        // Zero means "we don't know", not "one knock". This is the assertion that
        // fails if the guard is ever simplified to `pulseCount < min`.
        #expect(!AudioRecorder.rejectsSegment(.noID(pulseCount: 0)))
    }

    @Test("A NoID segment that met the pulse minimum is kept")
    func keepsMultiPulseNoID() {
        #expect(!AudioRecorder.rejectsSegment(.noID(pulseCount: 2)))
        #expect(!AudioRecorder.rejectsSegment(.noID(pulseCount: 13)))
    }

    @Test("A named species is kept however few pulses carried it")
    func keepsSpeciesRegardless() {
        // The detector's own gate decides whether a pass this thin can be named;
        // once it HAS been named, the recording is evidence and stays.
        #expect(!AudioRecorder.rejectsSegment(.species(code: "LACI", confidence: 0.4, pulseCount: 1)))
        #expect(!AudioRecorder.rejectsSegment(.species(code: "MYVO", confidence: 0.8, pulseCount: 30)))
    }

    @Test("NOISE is still rejected outright")
    func rejectsNoise() {
        #expect(AudioRecorder.rejectsSegment(.noise))
    }

    @Test("The threshold the recorder uses is the detector's, not a copy")
    func sharesThresholdWithDetector() {
        // Two independent constants would drift, and the symptom would be WAVs
        // surviving passes that the history had already dropped.
        let min = PulseDetector.minRecordedPassPulseCount
        #expect(AudioRecorder.rejectsSegment(.noID(pulseCount: min - 1)))
        #expect(!AudioRecorder.rejectsSegment(.noID(pulseCount: min)))
    }
}
