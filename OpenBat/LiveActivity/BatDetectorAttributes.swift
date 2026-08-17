//
//  BatDetectorAttributes.swift
//  OpenBat
//
//  The contract between the app and the Live Activity widget.
//
//  ⚠️ THIS FILE IS A MEMBER OF BOTH TARGETS (OpenBat + OpenBatWigetExtension).
//  It lives in the app's folder, and the project uses Xcode 16's
//  `fileSystemSynchronizedGroups`, which assigns membership by folder — so the widget
//  target only sees it via an explicit `PBXFileSystemSynchronizedBuildFileExceptionSet`
//  in project.pbxproj ("Exceptions for OpenBat folder in OpenBatWigetExtension target").
//  If you move or rename this file, update that list too, or the widget stops compiling
//  with "cannot find type 'BatDetectorAttributes'".
//

import Foundation
import ActivityKit

/// Everything the lock-screen card shows about a running detection session.
///
/// `ContentState` is serialised and handed to a separate process on every update, and
/// the payload is capped at ~4 KB, so this stays scalars-and-short-strings only — which
/// is also why the card shows no spectrogram: an image can't travel in here, and the
/// App Group detour that made it possible wasn't worth what it added at a glance.
struct BatDetectorAttributes: ActivityAttributes {

    // MARK: Static (set once at start, never updated)

    /// Session label — "Mendip Hills", "Listening only", "Demo".
    let sessionTitle: String
    /// When detection started. The widget renders elapsed time from this with
    /// `Text(timerInterval:)`, which ticks in the widget process without consuming
    /// any of the update budget — see `ContentState` on why that matters.
    let sessionStart: Date
    /// Demo passes aren't field data (see Context.md §6). The card says so
    /// rather than silently presenting a synthetic ID as a real detection.
    let isDemo: Bool

    // MARK: Dynamic

    /// A Live Activity repaints only when the app calls `activity.update(...)`, and
    /// iOS budgets those calls — this is nowhere near a per-frame channel. Updates are
    /// coalesced to `LiveActivityController.minUpdateInterval` and only sent when a
    /// field actually changed, so the card tracks *passes* (a bat flying through),
    /// not columns.
    struct ContentState: Codable, Hashable {

        // MARK: Identification

        /// Four-letter code from the classifier, e.g. "MYLU". `nil` before the first
        /// pass completes. "NOID" and "NOISE" are passed through as-is and rendered
        /// specially — see `OpenBatLiveActivity.idBlock`.
        var speciesCode: String?
        /// Resolved app-side via `SpeciesInfo.commonName` and shipped as a plain string:
        /// the widget process has no access to `SpeciesGuideStore` (bundled → cached →
        /// GitHub resolution), and a few dozen bytes is far cheaper than teaching the
        /// extension that whole path.
        var commonName: String?
        /// Aggregated pass confidence, 0–1.
        var confidence: Double
        /// Pulses that made up the winning pass.
        var passPulseCount: Int
        /// When the pass landed. The widget greys the ID out once this is older than
        /// `staleIDSeconds`, matching `PulseStatsViews.staleIDSeconds` in the app —
        /// the two are deliberately the same 30 s so every surface ages IDs out on
        /// the same clock.
        var lastPassDate: Date?

        // MARK: Last-pulse stats

        var fpeakKHz: Double
        var durationMs: Double
        var pulseRateHz: Double
        /// Cumulative for the session. Deliberately exempt from staleness, matching
        /// `PulseStatValues`.
        var pulseCount: Int
        /// Most recent pulse capture of any kind, ID or not.
        var lastDetectionDate: Date?

        // MARK: Derived staleness
        //
        // Computed by the APP at update time, never by the widget from `Date()` — a
        // widget-computed staleness check would never get the chance to fire, since the
        // no-op guard drops every update once nothing is changing. See Context.md §12.
        // The transition is only as prompt as `heartbeatInterval`.

        /// `lastPassDate` is older than `staleIDSeconds` — greys the species out.
        var isIDStale: Bool
        /// `lastDetectionDate` is older than `staleIDSeconds` — blanks Fpeak/Dur/Rate.
        ///
        /// Deliberately a *separate* clock from `isIDStale`, mirroring the split in the
        /// app: `PulseStatValues` ages the last-pulse stats off `lastDetectionDate` while
        /// the species feed ages each ID off its own pass date. Collapsing them would
        /// blank live stats during a stretch of pulses that never clear the pass
        /// confidence gates — captures are happening, there's just no ID to show.
        var isPulseStale: Bool
        /// A pulse landed within `activeDotSeconds` — lights the dot.
        var isDetectionRecent: Bool

        // MARK: Liveness

        /// Increments on every update the app sends. Nothing displays it: the widget
        /// animates off it (`.animation(_:value:)`), which is the only way to move
        /// anything in a Live Activity — WidgetKit disables repeating animations, so
        /// there is no such thing as a self-animating pulse. The dot flashes when a
        /// detection lands, and the elapsed timer covers the silence between.
        var updateTick: Int

        static let idle = ContentState(
            speciesCode: nil,
            commonName: nil,
            confidence: 0,
            passPulseCount: 0,
            lastPassDate: nil,
            fpeakKHz: 0,
            durationMs: 0,
            pulseRateHz: 0,
            pulseCount: 0,
            lastDetectionDate: nil,
            isIDStale: true,
            isPulseStale: true,
            isDetectionRecent: false,
            updateTick: 0
        )
    }
}

// MARK: - Shared constants

/// Constants both the app and the widget need to agree on for staleness/
/// liveness to read consistently on both sides.
enum BatActivityShared {
    /// An ID older than this greys out. Same 30 s as the app's `staleIDSeconds`, so every
    /// surface ages IDs out on the same clock.
    static let staleIDSeconds: TimeInterval = 30

    /// The live dot counts as "active" for this long after a pulse. Kept comfortably above
    /// `LiveActivityController.heartbeatInterval`, which is the granularity at which the
    /// app can actually notice the window closing.
    static let activeDotSeconds: TimeInterval = 20
}
