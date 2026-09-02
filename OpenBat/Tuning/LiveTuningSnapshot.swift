//
//  LiveTuningSnapshot.swift
//  OpenBat
//
//  Everything the live tuning overlay can change, captured as one value so
//  Revert can put it all back. One flat struct rather than per-tab snapshots
//  is deliberate — a knob added to a tab and not added here fails silently
//  under Revert, so there is exactly one place to remember it. See
//  Context.md §13.
//
//  ⚠️ That design did NOT hold on its own. An audit on 2026-08-15 found EIGHT
//  knobs the overlay exposes and this struct never captured: all five Slow
//  Replay sliders, the output routing picker, the trigger-mode picker and the
//  palette picker. Revert silently left every one of them where the user had
//  dragged it, and because the replay sliders also commit to UserDefaults, a
//  Revert the user believed had worked had in fact changed persisted settings
//  for good. "One place to remember it" is only a convention; nothing enforces
//  it. The check is mechanical, so do it rather than trusting the comment:
//
//      grep -c 'onLive:' Tuning/LiveTuningTabs.swift   # every slider
//      grep -n  'Picker(' Tuning/LiveTuningTabs.swift  # every picker
//
//  and confirm each one has a field here, in `capture`, and in `restore`.
//  Pickers are what slipped through last time — a sweep that only looks for
//  sliders will miss them again. Plain value type, not `@Observable`; no threading contract
//  of its own, since `capture`/`restore` both run on the main actor via the
//  main-actor-isolated objects they read and write.
//

import Foundation

/// A point-in-time copy of every tunable the live overlay exposes, taken on
/// open and put back by Revert.
struct LiveTuningSnapshot {

    // Heterodyne
    var heterodyneGain: Float
    var audibleOffsetHz: Double

    // Pulse haptics. Like the heterodyne knobs these live on the object itself
    // rather than behind a separate settings type, so Revert writes them back
    // there directly.
    var hapticStrength: Double
    var hapticLevelFloor: Float
    var hapticLevelCeiling: Float
    var hapticMinIntensity: Float
    var hapticFreqFloorHz: Double
    var hapticFreqCeilingHz: Double
    var hapticBuzzEnterHz: Double
    var hapticBuzzExitHz: Double
    var hapticRateWindow: TimeInterval
    var hapticBuzzHangover: TimeInterval
    var hapticMinTapInterval: TimeInterval

    // Pulse detector
    var amplitudeThreshold: Float
    var minFrequencyHz: Double
    var minConsecutiveColumns: Int
    var maxGapMs: Double
    var holdOffSeconds: Double
    var displayWindowMs: Double
    var pulseNoiseFloor: Float
    var spectrogramNoiseFloor: Float

    // Slow replay (D240x snippet expansion). Unlike every other group here these
    // have a PERSISTED counterpart as well as a live one: the tab's sliders write
    // the processor on drag and `SnippetExpansionSettings` (→ UserDefaults) on
    // release. So Revert has to put both back, or a revert the user believes
    // worked leaves the persisted value permanently changed. These were missing
    // from this struct entirely until 2026-08-15 — see the type doc.
    var snippetExpansion: Double
    var snippetMemorySeconds: Double
    var snippetDenoiseMode: SnippetDenoiseMode
    var snippetRearmSeconds: Double
    var snippetFadeMS: Double
    var snippetTrimDB: Double
    var snippetRouting: SnippetOutputRouting

    // Pulse detector, continued: which trigger the detector is using. A picker,
    // not a slider, which is how it escaped the original sweep.
    var triggerMode: PulseDetector.TriggerMode

    // Display
    var bandLow: Double
    var bandHigh: Double
    var timeWindowSeconds: Double
    var displayPalette: Palette

    /// Reads the current value of every tunable from its live source of truth.
    static func capture(audio: AudioEngineController,
                        pulse: PulseDetector,
                        haptics: PulseHaptics,
                        snippet: SnippetExpansionSettings,
                        bandLow: Double,
                        bandHigh: Double,
                        timeWindowSeconds: Double) -> LiveTuningSnapshot {
        LiveTuningSnapshot(
            heterodyneGain: audio.heterodyne.gain,
            audibleOffsetHz: audio.audibleOffsetHz,
            hapticStrength: haptics.strength,
            hapticLevelFloor: haptics.levelFloor,
            hapticLevelCeiling: haptics.levelCeiling,
            hapticMinIntensity: haptics.minIntensity,
            hapticFreqFloorHz: haptics.freqFloorHz,
            hapticFreqCeilingHz: haptics.freqCeilingHz,
            hapticBuzzEnterHz: haptics.buzzEnterHz,
            hapticBuzzExitHz: haptics.buzzExitHz,
            hapticRateWindow: haptics.rateWindow,
            hapticBuzzHangover: haptics.buzzHangover,
            hapticMinTapInterval: haptics.minTapInterval,
            amplitudeThreshold: pulse.amplitudeThreshold,
            minFrequencyHz: pulse.minFrequencyHz,
            minConsecutiveColumns: pulse.minConsecutiveColumns,
            maxGapMs: pulse.maxGapMs,
            holdOffSeconds: pulse.holdOffSeconds,
            displayWindowMs: pulse.displayWindowMs,
            pulseNoiseFloor: pulse.pulseNoiseFloor,
            spectrogramNoiseFloor: pulse.spectrogramNoiseFloor,
            // Read from the SETTINGS object, not the processor: settings is what
            // survives a restart, and the two agree except mid-drag.
            snippetExpansion: snippet.expansion,
            snippetMemorySeconds: snippet.memorySeconds,
            snippetDenoiseMode: snippet.denoiseMode,
            snippetRearmSeconds: snippet.rearmSeconds,
            snippetFadeMS: snippet.fadeMS,
            snippetTrimDB: snippet.trimDB,
            snippetRouting: snippet.routing,
            triggerMode: pulse.triggerMode,
            bandLow: bandLow,
            bandHigh: bandHigh,
            timeWindowSeconds: timeWindowSeconds,
            displayPalette: pulse.displayPalette
        )
    }

    /// Put everything back. Every value here lives on a processor or the pulse
    /// detector rather than behind a settings object, so each is written
    /// directly to its source of truth.
    func restore(audio: AudioEngineController,
                 pulse: PulseDetector,
                 haptics: PulseHaptics,
                 snippet: SnippetExpansionSettings,
                 bandLow: inout Double,
                 bandHigh: inout Double,
                 timeWindowSeconds: inout Double) {
        audio.heterodyne.gain = heterodyneGain
        audio.audibleOffsetHz = audibleOffsetHz

        haptics.strength = hapticStrength
        haptics.levelFloor = hapticLevelFloor
        haptics.levelCeiling = hapticLevelCeiling
        haptics.minIntensity = hapticMinIntensity
        haptics.freqFloorHz = hapticFreqFloorHz
        haptics.freqCeilingHz = hapticFreqCeilingHz
        // Enter before exit: enter's didSet drags a too-high exit down with it.
        haptics.buzzEnterHz = hapticBuzzEnterHz
        haptics.buzzExitHz = hapticBuzzExitHz
        haptics.rateWindow = hapticRateWindow
        haptics.buzzHangover = hapticBuzzHangover
        haptics.minTapInterval = hapticMinTapInterval

        pulse.amplitudeThreshold = amplitudeThreshold
        pulse.minFrequencyHz = minFrequencyHz
        pulse.minConsecutiveColumns = minConsecutiveColumns
        pulse.maxGapMs = maxGapMs
        pulse.holdOffSeconds = holdOffSeconds
        pulse.displayWindowMs = displayWindowMs
        pulse.pulseNoiseFloor = pulseNoiseFloor
        pulse.spectrogramNoiseFloor = spectrogramNoiseFloor
        pulse.triggerMode = triggerMode
        pulse.displayPalette = displayPalette

        // Both halves, in this order: the settings object persists the value, and
        // `apply(to:)` pushes the whole set into the live processor so the change
        // is audible on the next replay rather than after a restart.
        snippet.expansion = snippetExpansion
        snippet.memorySeconds = snippetMemorySeconds
        snippet.denoiseMode = snippetDenoiseMode
        snippet.rearmSeconds = snippetRearmSeconds
        snippet.fadeMS = snippetFadeMS
        snippet.trimDB = snippetTrimDB
        snippet.apply(to: audio.snippetExpansion)
        // Routing lives in an atomic on the controller, not on the processor, so
        // `apply(to:)` doesn't carry it — it needs its own write.
        snippet.routing = snippetRouting
        audio.setSnippetRouting(snippetRouting)

        bandLow = self.bandLow
        bandHigh = self.bandHigh
        timeWindowSeconds = self.timeWindowSeconds
    }
}
