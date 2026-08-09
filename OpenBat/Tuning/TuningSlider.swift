//
//  TuningSlider.swift
//  OpenBat
//
//  The control the live tuning overlay is built from. One compact row: label,
//  slider, live value readout — sized to fit a floating card over the running
//  detector rather than a Form. Not `Slider(value:in:step:)` bound straight to
//  settings: onLive fires every drag frame and writes the DSP object's
//  lock-guarded scalar (heard next buffer); onCommit fires once on release and
//  writes the persisted settings object. Binding straight to settings would do
//  a `UserDefaults.set` plus an `@Observable` invalidation per drag frame, on
//  the main thread, behind the live render loop. See Context.md §13.
//
//  A knob with no settings-object counterpart passes the same closure to both,
//  or omits `onCommit`.
//

import SwiftUI

/// A tappable parameter name that explains itself in a popover.
///
/// The tradeoffs behind these knobs are the entire reason the overlay is worth
/// having, and they were previously only in the source. A popover rather than
/// inline text so opening one doesn't reflow the card — which, being floating
/// and hand-positioned, would shift under the finger that just tapped it.
struct TuningInfoLabel: View {
    let text: String
    let explanation: String?
    var emphasis: Color = .secondary

    @State private var showExplainer = false

    var body: some View {
        if let explanation {
            Button { showExplainer = true } label: {
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(emphasis)
                    // Dotted underline is the "there's a definition here"
                    // affordance. Subtle enough not to make a column of rows
                    // look like a link farm, visible enough to be found.
                    .underline(true, pattern: .dot)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Explains this setting")
            .popover(isPresented: $showExplainer) {
                TuningExplainer(title: text, detail: explanation)
                    .presentationCompactAdaptation(.popover)
            }
        } else {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(emphasis)
        }
    }
}

private struct TuningExplainer: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                // Same fix as MicStatusExplainer: a compact popover otherwise
                // sizes to the text's intrinsic single-line width and overflows.
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
    }
}

/// One row of the live tuning overlay: label, slider, live value readout.
/// See the file header for the onLive/onCommit split this exists to support.
struct TuningSlider: View {
    let label: String
    /// Shown when the label is tapped. Nil leaves the label plain and inert.
    var explanation: String?
    let range: ClosedRange<Double>
    /// Slider step. Pass 0 for continuous.
    var step: Double = 0
    /// Formats the value for the readout — units belong here, not in `label`.
    let format: (Double) -> String
    /// Fired continuously while dragging. Wire to the live DSP property.
    let onLive: (Double) -> Void
    /// Fired once when the gesture ends. Wire to the persisted settings property.
    var onCommit: ((Double) -> Void)?
    /// Shown greyed with the slider disabled — for a knob that only applies in a
    /// mode that isn't currently active.
    var disabledReason: String?

    /// The slider's own value. Seeded from `initial` and thereafter owned by the
    /// gesture — deliberately NOT a binding back to the settings object, so a
    /// mid-drag `@Observable` update from anywhere else can't yank the thumb.
    @State private var value: Double
    private let initial: Double

    init(label: String,
         explanation: String? = nil,
         initial: Double,
         range: ClosedRange<Double>,
         step: Double = 0,
         format: @escaping (Double) -> String,
         onLive: @escaping (Double) -> Void,
         onCommit: ((Double) -> Void)? = nil,
         disabledReason: String? = nil) {
        self.label = label
        self.explanation = explanation
        self.initial = initial
        self.range = range
        self.step = step
        self.format = format
        self.onLive = onLive
        self.onCommit = onCommit
        self.disabledReason = disabledReason
        _value = State(initialValue: initial.clamped(to: range))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                TuningInfoLabel(
                    text: label,
                    explanation: explanation,
                    emphasis: disabledReason == nil ? .secondary : Color.secondary.opacity(0.5))
                Spacer(minLength: 4)
                Text(format(value))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(disabledReason == nil ? .primary : Color.secondary)
            }
            slider
        }
        .help(disabledReason ?? "")
        // Re-seed if the value changed underneath us (Revert, Reset to defaults,
        // or the other end of a clamped pair moving). Guarded so the assignment
        // during our own drag doesn't fight the gesture.
        .onChange(of: initial) { _, new in
            if !isDragging { value = new.clamped(to: range) }
        }
    }

    @State private var isDragging = false

    @ViewBuilder
    private var slider: some View {
        let binding = Binding(
            get: { value },
            set: { newValue in
                value = newValue
                onLive(newValue)
            }
        )
        Group {
            if step > 0 {
                Slider(value: binding, in: range, step: step) { editing in
                    isDragging = editing
                    if !editing { onCommit?(value) }
                }
            } else {
                Slider(value: binding, in: range) { editing in
                    isDragging = editing
                    if !editing { onCommit?(value) }
                }
            }
        }
        .controlSize(.mini)
        .disabled(disabledReason != nil)
    }
}

/// Compact labelled readout for values the overlay shows but doesn't edit —
/// the adaptive-TE telemetry, mainly. Same row metrics as `TuningSlider` so a
/// column of the two lines up.
struct TuningReadout: View {
    let label: String
    var explanation: String?
    let value: String
    var emphasis: Color = .primary

    var body: some View {
        HStack(spacing: 6) {
            TuningInfoLabel(text: label, explanation: explanation)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(emphasis)
        }
    }
}

/// Clamps any `Comparable` value into a range. Used throughout the tuning
/// overlay to keep a slider's seeded value and drag position inside bounds.
extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
