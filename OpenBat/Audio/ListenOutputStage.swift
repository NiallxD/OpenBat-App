//
//  ListenOutputStage.swift
//  OpenBat
//
//  The last thing every listening mode passes through, as two numbers that
//  anything deciding a level needs to know about.
//
//  They lived as private constants inside `AudioEngineController` and that
//  cost a real bug (2026-09-01). The snippet replay path had just gained
//  automatic level matching, and it was written to normalise each snippet's
//  peak to 0.5 — "−6 dBFS, leaving headroom". But the output stage then
//  multiplies by four, so every replay arrived at the soft clipper at 2.0 and
//  was crushed against the ceiling: measured off a demo run, 2.4% of all
//  samples sat at full scale and the peaks read +2 dBFS. The normalisation was
//  calibrated against a stage it could not see.
//
//  So the numbers live here, and a caller that needs to land at a particular
//  OUTPUT level divides by `makeupGain` rather than guessing. A plain
//  `nonisolated` enum because the audio threads read it and the project
//  defaults types to `@MainActor`.
//

import Foundation

nonisolated enum ListenOutputStage {
    /// Fixed correction for the output attenuation that `.measurement` mode
    /// imposes — see `AudioEngineController.listenOutputMakeupGain`'s doc
    /// comment for why the session mode itself can't be changed instead.
    /// Applied once to whatever the active mode produced.
    static let makeupGain: Float = 4.0

    /// Where the soft clip starts, at the output. Below this the makeup gain is
    /// exactly linear; above it the signal compresses toward ±1 instead of
    /// buzzing. A level that lands here is as loud as the path goes without
    /// distorting, which makes it the right target for anything normalising.
    static let softClipKnee: Float = 0.7

    /// What a signal should be scaled to BEFORE the makeup gain in order to
    /// arrive at `softClipKnee` after it.
    static var peakBeforeMakeup: Float { softClipKnee / makeupGain }
}
