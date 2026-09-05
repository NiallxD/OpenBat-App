//
//  CallAnalysisPanel.swift
//  OpenBat
//
//  Displays a CallAnalysis.Result for the current manual drag-selection.
//  Reuses `StatCell` (PulseStatsViews.swift) for the same title/value/unit
//  look the live Detector screen's pulse stats already use, and the shared
//  `filledPanelCard`/`PanelTitle` (PanelCard.swift) for the same "STATS"
//  card look the Detector screen's own stats strip uses.
//
//  The card is ALWAYS the same height, whether or not `result` is nil.
//  Previously the whole panel collapsed to a single short placeholder line
//  when `result` was nil and expanded to the full grid once a selection was
//  measured — since this panel sits in the same VStack as the spectrogram
//  (`frame(maxHeight: .infinity)`), that height change visibly resized the
//  spectrogram every time a selection was made or cleared. So the grid is
//  always laid out; with no result it is merely invisible, and a prompt sits
//  over the space it holds.
//
//  That prompt replaced a grid of eleven "–" placeholders (Niall,
//  2026-09-01), which reserved the height correctly but read as a broken
//  readout: it said there was no data without saying why, or that the user
//  has to select a region before there can be any.
//
//  The one exception to the fixed height is deliberate and user-driven: the
//  species button in the last cell of the grid expands a single reference row
//  of the field guide's published Pf / Cf / Duration for the species this
//  recording is filed under, so a measured call can be read against the
//  book's figures without leaving the player. That row DOES squash the
//  spectrogram while it is open — which is the point of it being a toggle
//  rather than something always on screen (Niall, 2026-09-02).
//

import SwiftUI

struct CallAnalysisPanel: View {
    let result: CallAnalysis.Result?
    /// The classifier code this recording is filed under ("LACI"), or nil for
    /// a NoID recording. Names the reference row's species on its button.
    let speciesCode: String?
    /// The field guide's echolocation figures for that code, when the guide
    /// has an entry for it — nil hides the button entirely rather than
    /// offering an expansion with nothing in it.
    let guideEcholocation: SpeciesEcholocation?

    @State private var showGuideRow = false

    var body: some View {
        VStack(spacing: 0) {
            PanelTitle("Call Analysis")
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)

            statGrid
                // Kept in the layout, not removed, when there is nothing to
                // show — see the note at the top of this file: this panel
                // shares a VStack with the spectrogram, so any height change
                // here resizes the spectrogram. Hiding it and laying the
                // prompt over the space it reserves keeps the card the exact
                // same size in both states.
                .opacity(result == nil ? 0 : 1)
                .overlay { if result == nil { emptyPrompt } }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .filledPanelCard()
    }

    /// Eleven dashes said "there is no data" without saying why or what to do
    /// about it — and the selection tool that produces the data is a toolbar
    /// glyph a user has no particular reason to have tried. The icon is the
    /// one on that button (`WavPlayerView`'s Select Region toggle), so the
    /// sentence points at something findable rather than naming it.
    private var emptyPrompt: some View {
        Text("Use the \(Image(systemName: "rectangle.dashed")) tool to reveal call data")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
    }

    private var statGrid: some View {
            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    InfoStatCell(title: "Peak", value: values.peak, unit: "",
                                 info: "The frequency with the most energy anywhere in the call — usually near the loudest point of the sweep.")
                    InfoStatCell(title: "Char. Freq", value: values.charFreq, unit: "",
                                 info: "Fc — the frequency of the flattest part of the call body, excluding any terminal toe. Often the most species-diagnostic figure.")
                    InfoStatCell(title: "Bandwidth", value: values.bandwidth, unit: "",
                                 info: "The full frequency span of the call, from its highest point to its lowest.")
                    InfoStatCell(title: "Duration", value: values.duration, unit: "ms",
                                 info: "How long the call lasts, start to end.")
                }
                HStack(spacing: 0) {
                    InfoStatCell(title: "Start", value: values.start, unit: "",
                                 info: "The highest frequency in the call — where the sweep begins (Fmax).")
                    InfoStatCell(title: "End", value: values.end, unit: "",
                                 info: "The lowest frequency in the call — where the sweep ends (Fmin).")
                    InfoStatCell(title: "Sweep", value: values.sweep, unit: "Hz/ms",
                                 info: "The whole-call average slope, start to end — steep for a typical downward FM sweep. Distinct from Body Sc, which measures only the flatter body.")
                    InfoStatCell(title: "Quality", value: values.quality, unit: "%",
                                 info: "How cleanly the selection was measured — how much the loudest point stands out above the rest of the selected region. Higher is a more trustworthy reading.")
                }
                HStack(spacing: 0) {
                    InfoStatCell(title: "Knee (Fk)", value: values.knee, unit: "",
                                 info: "The frequency where the steep initial FM sweep bends into the flatter call body — the elbow of the curve.")
                    InfoStatCell(title: "Body Sc", value: values.bodySlope, unit: "Hz/ms",
                                 info: "The slope of the call body only, from the knee to the start of any terminal toe — a more diagnostic slope than the whole-call Sweep figure.")
                    InfoStatCell(title: "Toe", value: values.toe, unit: "",
                                 info: "Whether the call curves at its very end: up, down, or stays flat (none) with no distinct terminal hook.")
                    // The cell this button fills was empty — eleven metrics in
                    // a four-column grid leave one gap, and it sat blank.
                    speciesCell
                }
                if showGuideRow, result != nil, let guideEcholocation {
                    Divider()
                    guideRow(guideEcholocation)
                }
            }
    }

    // MARK: Field-guide reference row

    /// The grid's twelfth cell: a toggle naming the species, or nothing at all
    /// when there is no guide entry to expand (a NoID recording, a code no
    /// model resolves to a guide page, or an entry with no echolocation
    /// figures filled in). Kept as an empty `StatCell` in that case so the
    /// grid's four columns stay evenly divided.
    @ViewBuilder private var speciesCell: some View {
        // `result != nil` as well: the whole grid is faded to zero opacity
        // until a selection has been measured (an opacity-0 button is still
        // tappable, and the empty prompt sits over it), and there is nothing
        // to read the guide's figures against until then anyway.
        if result != nil, let speciesCode, let guideEcholocation,
           guideEcholocation.hasDisplayableFigures {
            Button {
                withAnimation(.snappy(duration: 0.25)) { showGuideRow.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Text(speciesCode)
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showGuideRow ? 180 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
                .frame(maxWidth: .infinity)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showGuideRow
                                ? "Hide field guide figures for \(speciesCode)"
                                : "Show field guide figures for \(speciesCode)")
        } else {
            StatCell(title: "", value: "", unit: "")
        }
    }

    /// One row of the guide's published ranges, column-aligned with the
    /// measured grid above it: Pf under Peak, Cf under Char. Freq, Duration
    /// under Duration. The third column has no guide counterpart (the guide
    /// publishes Fhigh/Flow, not a bandwidth), so the species' notes hang
    /// there as a popover instead of leaving a hole.
    private func guideRow(_ echo: SpeciesEcholocation) -> some View {
        HStack(spacing: 0) {
            GuideStatCell(title: "Pf", value: Self.kHzValue(echo.peakFreqHzRange), unit: "kHz")
            GuideStatCell(title: "Cf", value: Self.kHzValue(echo.characteristicFreqHzRange), unit: "kHz")
            GuideNotesCell(notes: echo.notes, callType: echo.callType)
            GuideStatCell(title: "Dur", value: Self.value(echo.durationMsRange), unit: "ms")
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// Range → "38–42", or "40" when the guide gives a single figure. Values
    /// only: the unit goes in `StatCell`'s own unit slot, as it does for every
    /// measured cell above.
    private static func value(_ range: MeasurementRange?) -> String {
        guard let range else { return "–" }
        // Defensive about min/max order — the guide is hand-edited JSON.
        let lo = Swift.min(range.min, range.max), hi = Swift.max(range.min, range.max)
        return lo == hi ? trimmed(lo) : "\(trimmed(lo))–\(trimmed(hi))"
    }

    private static func kHzValue(_ range: MeasurementRange?) -> String {
        guard let range else { return "–" }
        return value(MeasurementRange(min: range.min / 1000, max: range.max / 1000))
    }

    private static func trimmed(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    private var values: Values { Values(result) }

    /// "–" for every field when there's no result yet, same convention
    /// `PulseStatValues` already uses for a stale/no-data pulse — keeps
    /// `StatCell`'s title/unit layout identical either way.
    private struct Values {
        let peak, charFreq, bandwidth, duration, start, end, sweep, quality: String
        let knee, bodySlope, toe: String

        init(_ result: CallAnalysis.Result?) {
            guard let result else {
                peak = "–"; charFreq = "–"; bandwidth = "–"; duration = "–"
                start = "–"; end = "–"; sweep = "–"; quality = "–"
                knee = "–"; bodySlope = "–"; toe = "–"
                return
            }
            peak = Self.freqString(result.peakFreqHz)
            charFreq = result.characteristicFreqHz.map(Self.freqString) ?? "–"
            bandwidth = Self.freqString(result.bandwidthHz)
            duration = String(format: "%.1f", result.durationMs)
            start = Self.freqString(result.startFreqHz)
            end = Self.freqString(result.endFreqHz)
            sweep = String(format: "%.1f", result.sweepRateHzPerMs)
            quality = String(format: "%.0f", result.quality * 100)
            knee = result.kneeFreqHz.map(Self.freqString) ?? "–"
            bodySlope = result.bodySlopeHzPerMs.map { String(format: "%.1f", $0) } ?? "–"
            switch result.toeDirection {
            case .none: toe = "None"
            case .up:   toe = "Up"
            case .down: toe = "Down"
            }
        }

        private static func freqString(_ hz: Double) -> String {
            hz >= 1000 ? String(format: "%.1f kHz", hz / 1000) : String(format: "%.0f Hz", hz)
        }
    }
}

/// `StatCell` wrapped in a tap target that pops over a short plain-language
/// explanation of the metric — `StatCell` itself stays untouched since it's
/// shared with the live Detector screen's pulse stats, which don't need this.
/// Each instance owns its own `showInfo` so tapping one cell's popover
/// doesn't affect the others.
private struct InfoStatCell: View {
    let title: String
    let value: String
    let unit: String
    let info: String
    @State private var showInfo = false

    var body: some View {
        Button { showInfo = true } label: {
            StatCell(title: title, value: value, unit: unit)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showInfo) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(info)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 260)
            .presentationCompactAdaptation(.popover)
        }
    }
}



/// A guide figure under its measured counterpart. Deliberately quieter and
/// shorter than `StatCell`: this row is the reference the measurement is being
/// read against, not another measurement, and a full-size row of it would
/// double the visual weight of the card while adding no new reading.
private struct GuideStatCell: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
            Text(value)
                .font(.footnote.monospacedDigit().weight(.semibold))
            if !unit.isEmpty {
                Text(unit).font(.system(size: 9))
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .minimumScaleFactor(0.6)
        .lineLimit(1)
    }
}

/// The guide's free-text echolocation notes, behind an info glyph — the same
/// gesture every metric in the grid above already answers to, so the row needs
/// no separate affordance explaining itself. Shows the call type ("FM",
/// "CF-FM") inline when the guide gives one, since that is the single most
/// useful thing to have on screen beside the numbers.
private struct GuideNotesCell: View {
    let notes: String?
    let callType: String?
    @State private var showNotes = false

    var body: some View {
        if notes == nil && callType == nil {
            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
        } else {
            Button { if notes != nil { showNotes = true } } label: {
                HStack(spacing: 3) {
                    if let callType {
                        Text(callType)
                            .font(.footnote.weight(.semibold))
                    }
                    if notes != nil {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                    }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .disabled(notes == nil)
            .accessibilityLabel("Field guide notes")
            .popover(isPresented: $showNotes) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("FIELD GUIDE NOTES")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(notes ?? "")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                }
                .frame(width: 280)
                .presentationCompactAdaptation(.popover)
            }
        }
    }
}

extension SpeciesEcholocation {
    /// Whether there is anything for the reference row to show. A guide entry
    /// can carry an echolocation block with only, say, `exemplarImageName`
    /// set; expanding a row of four dashes for it would be worse than not
    /// offering the button.
    var hasDisplayableFigures: Bool {
        peakFreqHzRange != nil || characteristicFreqHzRange != nil
            || durationMsRange != nil || callType != nil || notes != nil
    }
}
