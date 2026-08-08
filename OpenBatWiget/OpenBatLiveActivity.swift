//
//  OpenBatLiveActivity.swift
//  OpenBatWigetExtension
//
//  The lock-screen card and Dynamic Island presentations.
//
//  ⚠️ This file belongs to the WIDGET target only. It depends on
//  BatDetectorAttributes.swift and BatActivityPalette.swift, which must be members of
//  BOTH targets — see the note at the top of BatDetectorAttributes.swift.
//
//  Layout note: everything here is a static snapshot re-rendered on update. There is no
//  animation loop and no Metal — WidgetKit disables repeating animations, so the two
//  liveness cues are (1) `Text(timerInterval:)`, which ticks in-process for free, and
//  (2) transitions keyed off `updateTick`, which fire when an update actually lands.
//  Don't reach for `.repeatForever` here; it silently does nothing.
//

import SwiftUI
import WidgetKit
import ActivityKit

struct OpenBatLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BatDetectorAttributes.self) { context in

            // MARK: Lock screen / banner
            LockScreenCard(context: context)
                // The gradient is painted inside the card (see `cardBackground`); the tint
                // is the flat fallback for anything the content doesn't cover.
                .activityBackgroundTint(BatActivityPalette.navy)
                .activitySystemActionForegroundColor(BatActivityPalette.orange)

        } dynamicIsland: { context in

            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IDBlock(state: context.state, compact: true)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StatStrip(state: context.state)
                }
            } compactLeading: {
                LiveDot(state: context.state)
            } compactTrailing: {
                Text(context.state.speciesCode ?? "—")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(BatActivityPalette.orange)
            } minimal: {
                LiveDot(state: context.state)
            }
            .keylineTint(BatActivityPalette.orange)
        }
    }
}

// MARK: - Lock screen

/// Species ID over a full-width stat strip. The pulse spectrogram that used to sit
/// on the left was dropped — at lock-screen size it added little a glance can use, and
/// it was the only reason this needed an App Group.
///
/// Sized to sit inside the lock screen's ~160 pt ceiling with room to spare — a card
/// that overflows gets clipped by the system, not scrolled.
private struct LockScreenCard: View {
    let context: ActivityViewContext<BatDetectorAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            IDBlock(state: context.state, compact: false)
            StatStrip(state: context.state)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        // Width fills, height stays content-driven. An earlier `maxHeight: .infinity`
        // here let the card grow to the lock screen's full allowance, and combined with a
        // `.fill` image that wanted to be enormous it pushed every text row out of view —
        // the card rendered as nothing but a gradient and a grey slab. Let the content
        // size it; `activityBackgroundTint` is set to the gradient's bottom colour so any
        // strip the system adds below still matches.
        .frame(maxWidth: .infinity)
        .background(BatActivityPalette.cardBackground)
    }

    private var header: some View {
        HStack(spacing: 6) {
            LiveDot(state: context.state)

            Text(context.attributes.isDemo ? "DEMO" : context.attributes.sessionTitle)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(context.attributes.isDemo
                                 ? BatActivityPalette.orange
                                 : BatActivityPalette.inkMuted)
                .lineLimit(1)

            Spacer(minLength: 4)

            // Free-running: the widget process advances this itself, so the card keeps
            // visibly ticking between updates without costing any update budget. This is
            // the primary "it's still running" signal — the dot only moves when
            // something is actually detected.
            Text(timerInterval: context.attributes.sessionStart...Date.distantFuture,
                 countsDown: false)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(BatActivityPalette.inkMuted)
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
    }
}

// MARK: - Identification

private struct IDBlock: View {
    let state: BatDetectorAttributes.ContentState
    let compact: Bool

    /// Straight from the state — the app decides this. Computing it here from `Date()`
    /// would never fire, because the update that would trigger the re-render is the one
    /// the no-op guard drops. See `ContentState.isIDStale`.
    private var isStale: Bool { state.isIDStale }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            switch state.speciesCode {
            case .none:
                Text("Listening…")
                    .font(.system(size: compact ? 15 : 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(BatActivityPalette.inkFaint)

            case "NOISE":
                Text("Noise")
                    .font(.system(size: compact ? 15 : 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(BatActivityPalette.inkFaint)

            case "NOID":
                // Defensive, and currently UNREACHABLE: `finalizePass` records a NoID pass
                // to the store but never assigns it to `lastPassResult`, which only ever
                // holds a species or "NOISE". So after a NoID pass the card keeps showing
                // the previous ID — exactly what the app's own species cell does, since it
                // reads the same property. Left in so this doesn't silently render a raw
                // "NOID" code if that ever changes; don't read its presence as a promise
                // that NoID passes are surfaced here.
                Text("Unidentified")
                    .font(.system(size: compact ? 15 : 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(BatActivityPalette.inkMuted)
                Text("\(state.passPulseCount) pulse\(state.passPulseCount == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(BatActivityPalette.inkFaint)

            case .some(let code):
                Text(state.commonName ?? code)
                    .font(.system(size: compact ? 15 : 17, weight: .bold, design: .rounded))
                    .foregroundStyle(isStale
                                     ? BatActivityPalette.inkFaint
                                     : BatActivityPalette.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                HStack(spacing: 5) {
                    Text(code)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    Text("·")
                    Text("\(Int((state.confidence * 100).rounded()))%")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                    Text("·")
                    Text("\(state.passPulseCount)p")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                }
                .foregroundStyle(BatActivityPalette.inkMuted)
            }
        }
        // Animates when a new pass replaces the old ID. Keyed on `updateTick` rather
        // than the code itself so two consecutive passes of the *same* species still
        // register as a change.
        .animation(.snappy(duration: 0.28), value: state.updateTick)
    }
}

// MARK: - Stats

private struct StatStrip: View {
    let state: BatDetectorAttributes.ContentState

    /// The last-pulse stats age out with the ID, matching `PulseStatValues` in the app:
    /// Fpeak/Dur/Rate all describe the most recent pulse, so freezing them at values
    /// from a long-gone pass would misreport what's flying now. `Pulses` is cumulative
    /// and exempt — same exemption the app makes.
    ///
    /// Note this is the *pulse* clock, not the ID clock — see `ContentState.isPulseStale`
    /// for why the two are separate. App-computed, for the reason given on `isIDStale`.
    private var isStale: Bool { state.isPulseStale }

    var body: some View {
        HStack(spacing: 0) {
            StatChip(label: "FPEAK", value: value(state.fpeakKHz, "%.0f"), unit: "kHz")
            StatChip(label: "DUR",   value: value(state.durationMs, "%.0f"), unit: "ms")
            StatChip(label: "RATE",  value: value(state.pulseRateHz, "%.1f"), unit: "/s")
            StatChip(label: "PULSES", value: "\(state.pulseCount)", unit: "")
        }
    }

    private func value(_ v: Double, _ format: String) -> String {
        guard !isStale, v > 0 else { return "–" }
        return String(format: format, v)
    }
}

private struct StatChip: View {
    let label: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(BatActivityPalette.inkFaint)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(BatActivityPalette.ink)
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(BatActivityPalette.inkMuted)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Live indicator

/// The "it's running" dot.
///
/// Two states, not an animation: orange and haloed when a pulse landed within
/// `activeDotSeconds`, dim otherwise. It grows briefly whenever `updateTick` changes,
/// which is the closest thing to a pulse WidgetKit permits — repeating animations are
/// disabled in widgets, so a genuinely throbbing dot is not available at any price. The
/// steadily ticking elapsed timer in the header carries the liveness signal between
/// detections; this carries "something was just heard".
private struct LiveDot: View {
    let state: BatDetectorAttributes.ContentState

    /// App-computed, for the reason given on `ContentState.isIDStale`. Its granularity is
    /// `LiveActivityController.heartbeatInterval`, so the dot goes out within ~5 s of the
    /// last pulse aging past `activeDotSeconds` rather than exactly on it.
    private var isActive: Bool { state.isDetectionRecent }

    var body: some View {
        ZStack {
            Circle()
                .fill(BatActivityPalette.orange.opacity(isActive ? 0.28 : 0))
                .frame(width: 16, height: 16)
            Circle()
                .fill(isActive ? BatActivityPalette.orange : BatActivityPalette.orangeDeep.opacity(0.4))
                .frame(width: 7, height: 7)
        }
        .scaleEffect(isActive ? 1.0 : 0.85)
        .animation(.spring(duration: 0.35, bounce: 0.5), value: state.updateTick)
    }
}
