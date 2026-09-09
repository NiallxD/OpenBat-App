//
//  HeterodyneSettings.swift
//  OpenBat
//
//  Persisted settings for the LIVE heterodyne channel, in the same shape as
//  `SnippetExpansionSettings` and for the same reason: threaded down from
//  ContentView, written by both the Settings sheet and the live tuning overlay,
//  applied to the processor whenever capture starts.
//
//  It exists because the two knobs it holds already existed and did not
//  survive a launch (Niall, 2026-09-09). `HeterodyneProcessor.gain` and
//  `.denoiseMode` were live-only, reachable only from the tuning overlay inside
//  the passcode-locked config menu, and reset to their defaults every time the
//  app started. That is the right contract for a knob you turn while a bat is
//  overhead and judge by ear; it is the wrong one for a setting, because a
//  setting that forgets is worse than no setting at all.
//
//  Volume is a dB TRIM, not a gain. The same distinction `SnippetExpansionSettings`
//  draws: the level itself is decided in the processor
//  (`HeterodyneProcessor.defaultGain`, which is a correction for a fixed output
//  attenuation and not a matter of taste), and this shifts it. Stored as dB so
//  the number in the card means something to a reader, and so 0 is honestly
//  "leave it alone".
//

import Foundation

@MainActor
@Observable
final class HeterodyneSettings: Reseedable {

    /// Shift on the heterodyne channel's own level, in dB. ±18 matches the
    /// replay path's trim, which is the other half of the same decision — a
    /// listener balancing the two channels under `.both` routing is setting
    /// these against each other.
    var trimDB: Double {
        didSet { persist(trimDB, Self.keyTrim) }
    }

    /// How much background the live channel keeps — the same three choices and
    /// the same machinery as the replay path (`SnippetDenoiseMode`), kept as a
    /// separate setting rather than one app-wide one because the two channels
    /// are listened to for different things. The replay is where you study a
    /// call; this is where you notice a bat exists, and silence means something
    /// different in each.
    ///
    /// Clamped to `SnippetDenoiseMode.liveChoices`: High is not offered on this
    /// channel, and the clamp is here rather than only in the picker so a value
    /// arriving from anywhere else — the tuning overlay, a restored snapshot, a
    /// stored value from an earlier build — can't reintroduce it.
    var denoiseMode: SnippetDenoiseMode {
        didSet {
            if !SnippetDenoiseMode.liveChoices.contains(denoiseMode) {
                denoiseMode = .reduce
                return          // the re-entrant set writes it
            }
            persist(denoiseMode.rawValue, Self.keyDenoise)
        }
    }

    static var defaultTrimDB: Double { Tunable.heterodyneTrimDB.value(0.0) }
    /// Off, where the replay path defaults to High — and High isn't reachable
    /// here at all; see `SnippetDenoiseMode.liveChoices` for why.
    static let defaultDenoiseMode: SnippetDenoiseMode = .off

    private static let keyTrim = "Heterodyne.trimDB"
    private static let keyDenoise = "Heterodyne.denoiseMode"

    init() {
        let d = UserDefaults.standard
        trimDB = d.object(forKey: Self.keyTrim) != nil
            ? d.double(forKey: Self.keyTrim) : Self.defaultTrimDB
        let stored = d.object(forKey: Self.keyDenoise) != nil
            ? (SnippetDenoiseMode(rawValue: d.integer(forKey: Self.keyDenoise))
               ?? Self.defaultDenoiseMode)
            : Self.defaultDenoiseMode
        // Property observers don't run during init, so the clamp above can't
        // catch a stored High here — do it explicitly.
        denoiseMode = SnippetDenoiseMode.liveChoices.contains(stored) ? stored : .reduce
    }

    /// Suppresses the persisting `didSet`s while a re-seed assigns — see
    /// `RemoteDefaultsReseed.swift`.
    var isSeeding = false

    private func persist(_ value: Any, _ key: String) {
        guard !isSeeding else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    /// See `RemoteDefaultsReseed.swift`. Only the trim: the background mode has
    /// no remote default, so there is nothing here for it to pick up.
    func reseedRemoteDefaults() {
        seeding {
            if UserDefaults.standard.object(forKey: Self.keyTrim) == nil {
                trimDB = Self.defaultTrimDB
            }
        }
    }

    func apply(to processor: HeterodyneProcessor) {
        processor.gain = HeterodyneProcessor.defaultGain * Float(pow(10, trimDB / 20))
        processor.denoiseMode = denoiseMode
    }

    func reset() {
        trimDB = Self.defaultTrimDB
        denoiseMode = Self.defaultDenoiseMode
    }
}
