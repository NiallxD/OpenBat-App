//
//  IDScoreViews.swift
//  OpenBat
//
//  The two numbers an identification carries, and the shared components that
//  show them.
//
//  PRECISION is the model's published track record for the species it just
//  named: of all the times its authors' test set was labelled this species, how
//  often that was right. The same figure for every detection of that species,
//  because it describes the model rather than the call (see ModelReliability).
//
//  CONFIDENCE is the per-call softmax percentage. It says how clearly this call
//  beat the other species — a share-out of 100% that must be given away
//  entirely, so a high figure can just mean the runners-up looked worse.
//
//  Precision leads in both the badge and the detail lines (Niall, 2026-09-09):
//  it is the closer of the two to the question everyone is actually asking, and
//  the confidence percentage on its own had been quietly answering a different
//  one for as long as it has been on screen.
//

import SwiftUI

/// Which of the two numbers a badge or line is showing.
enum IDScoreKind {
    case precision
    case confidence

    var label: String {
        switch self {
        case .precision:  return "Precision"
        case .confidence: return "Confidence"
        }
    }

    /// The colour bands differ because the two numbers live on different scales.
    /// A confidence of 0.65 is a middling call; a *precision* of 0.65 is a species
    /// the model gets wrong a third of the time it names it, which is much worse
    /// news and should not be wearing the same green.
    func color(for value: Float) -> Color {
        switch self {
        case .precision:
            switch value {
            case 0.90...:     return .green
            case 0.75..<0.90: return .yellow
            default:          return .orange
            }
        case .confidence:
            switch value {
            case 0.6...:    return .green
            case 0.3..<0.6: return .yellow
            default:        return .orange
            }
        }
    }

    /// The row-level version: the headline claim and nothing else. A popover
    /// hanging off a pill in a live feed is read standing up, mid-session — the
    /// full pair of paragraphs lives on the detail screen behind the same glyph.
    @ViewBuilder func briefExplainer(_ reliability: SpeciesReliability?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch self {
            case .precision:
                Text("Precision").font(.subheadline.weight(.semibold))
                Text("How often this model turns out to be correct when it names this species, measured against recordings of bats that had already been identified. The same figure every time you record it — it describes the model, not this call.")
                    .font(.caption)
                if let reliability {
                    Text(String(format: "That is across a whole recording. Judging one call on its own, it drops to %.0f%%.", reliability.pulsePrecision * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .confidence:
                Text("Confidence").font(.subheadline.weight(.semibold))
                Text("How clearly this call beat the other species on the list, not the chance the identification is right. The model shares out 100% and must give all of it away, so a high figure can just mean the runners-up looked worse.")
                    .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 280)
        // Without this the popover hands the text a compressed height and the
        // last paragraph truncates — a popover sizes to its content, and the
        // content has to be willing to state a full height for it to read.
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder func explainer(_ reliability: SpeciesReliability?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch self {
            case .precision:
                Text("Precision").font(.subheadline.weight(.semibold))
                Text("How often this model turns out to be correct when it names this species, measured by the people who built it against recordings of bats they had already identified.")
                    .font(.caption)
                if let reliability {
                    Text(String(format: "That figure is for a whole recording, where the model hears the bat many times over. Judging a single call on its own it gets this species right %.0f%% of the time — the difference between the two is what hearing a bat repeatedly is worth.", reliability.pulsePrecision * 100))
                        .font(.caption)
                }
                Text("It is the same figure every time you record this species — it describes the model's track record, not this particular call. Species tested on only a handful of recordings show no figure at all. Both figures were measured on dedicated bat detectors rather than a phone, so treat them as a best case.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .confidence:
                Text("Confidence").font(.subheadline.weight(.semibold))
                Text("How clearly this call beat the other species on the list. The model has 100% to share out and must give all of it away, so a high number can simply mean the runners-up looked worse.")
                    .font(.caption)
                Text("It is not the chance the identification is right. Turning species off in AutoID settings hands their share to the rest, which pushes the figure up without any new evidence arriving.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The trailing pill on an identification row: **this species' precision, and
/// never anything else** (Niall, 2026-09-10).
///
/// It used to fall back to the call's own confidence wherever the model published
/// no precision — BatDetect2 publishes none at all, and NABat's sparsest classes
/// are suppressed — on the reasoning that a pill which vanished would take away a
/// number the row had always had. What it actually did was print two unrelated
/// quantities, on different scales with different colour bands, as an identical
/// bare "94%": in a list, a species with a track record and one without sat a row
/// apart wearing the same badge, and only VoiceOver could tell them apart.
///
/// So where there is no figure the pill is replaced by an `ⓘ`, which says which of
/// the reasons applies. An absence that explains itself is worth more than a
/// number that means something else.
///
/// The `ⓘ` is drawn only where the row can spare the tap (`interactive: true`,
/// the species feed, whose row is a tap gesture). A Sessions row is a
/// NavigationLink, which swallows taps meant for a button inside it, so there it
/// isn't drawn at all rather than drawn dead: the pill shows the bare figure, an
/// absence shows nothing, and the detail screen the row pushes explains both.
struct IDBadge: View {
    /// The species whose track record to show. nil where the row is not about a
    /// whole recording at all — precision is measured per recording, and quoting
    /// it against one pulse would put a file-level figure on a unit it was never
    /// measured for.
    let species: String?
    /// Whether the pill opens its own explanation. False inside a NavigationLink.
    var interactive: Bool = false

    @State private var showInfo = false

    private var reliability: SpeciesReliability? {
        species.flatMap { ModelReliability.reliability(for: $0) }
    }

    private var precision: Float? { reliability?.precision }

    var body: some View {
        if interactive {
            Button { showInfo = true } label: { badge }
                .buttonStyle(.plain)
                .popover(isPresented: $showInfo) {
                    explainer.presentationCompactAdaptation(.popover)
                }
        } else {
            badge
        }
    }

    @ViewBuilder private var badge: some View {
        if precision != nil { pill } else { absenceGlyph }
    }

    private var pill: some View {
        HStack(spacing: 2) {
            Text(String(format: "%.0f%%", (precision ?? 0) * 100))
                .font(.caption.monospacedDigit().weight(.semibold))
            // Only where the tap lands somewhere. An inert `ⓘ` inside a
            // NavigationLink is an affordance that pushes the detail screen
            // instead of explaining itself.
            if interactive {
                Image(systemName: "info.circle")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.7)
            }
        }
        // Never wrap ("51" over "%") when a narrow container squeezes the row.
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        // The wash stays as bright as it ever was; the ink and the edge are
        // what darken in light mode, where full-strength orange or yellow on
        // a pale wash is barely there. The border is the other half of the
        // fix: on white the wash alone doesn't describe a shape.
        .background(color.opacity(0.2), in: Capsule())
        .overlay { Capsule().strokeBorder(ink.opacity(0.45), lineWidth: 1) }
        .foregroundStyle(ink)
        .accessibilityElement()
        .accessibilityLabel("Precision \(Int((precision ?? 0) * 100)) percent")
    }

    /// Deliberately not a pill: an absence should not occupy the same shape as a
    /// figure, or it reads as one from across the room. It is *only* an
    /// affordance, so where the tap can't land it isn't drawn at all — the row
    /// simply carries no figure, and the detail screen says why.
    @ViewBuilder private var absenceGlyph: some View {
        if interactive {
            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityElement()
                .accessibilityLabel("No precision figure. \(absenceHeadline)")
        }
    }

    private var absenceHeadline: String {
        guard let species else {
            return "Precision is measured for a whole recording, not for one call."
        }
        switch ModelReliability.precisionAbsence(for: species) {
        case .tooFewTestRecordings:
            return "This species was tested on too few recordings to quote a figure."
        case .notPublished, .none:
            return "The model that named this species publishes no track record."
        }
    }

    @ViewBuilder private var explainer: some View {
        if precision != nil {
            IDScoreKind.precision.briefExplainer(reliability)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("No precision figure").font(.subheadline.weight(.semibold))
                Text(absenceHeadline).font(.caption)
                if case .tooFewTestRecordings(let n) = species.flatMap({ ModelReliability.precisionAbsence(for: $0) }) {
                    Text("Its authors' test set held \(n) recordings of it, against the \(SpeciesReliability.minimumSampleSize) this app asks for before quoting a track record. A figure from a handful of recordings would be the app's most authoritative-looking number on its least supported claim.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Precision comes from the model authors' own evaluation, and not every model publishes one. The identification is unaffected — there is simply no measured track record to quote alongside it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(width: 280)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ink: Color { color.darkenedInLightMode() }
    private var color: Color { IDScoreKind.precision.color(for: precision ?? 0) }
}

/// One pulse's own score, on a row that is about a single call rather than a
/// recording.
///
/// Labelled, and shaped nothing like `IDBadge`. This slot used to hold an
/// `IDBadge` handed a nil species, which printed the pulse's confidence in the
/// precision pill's clothing — the same "94%" a species' track record wears one
/// screen away.
struct PulseScoreChip: View {
    let confidence: Float

    var body: some View {
        HStack(spacing: 4) {
            Text("Call score")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(String(format: "%.0f%%", confidence * 100))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(IDScoreKind.confidence.color(for: confidence).darkenedInLightMode())
        }
        .fixedSize()
        .accessibilityElement()
        .accessibilityLabel("Call score \(Int(confidence * 100)) percent")
    }
}

/// "ⓘ Precision: 95%" — one labelled figure with its explanation behind the
/// info button. Used on the detail screens, where a tap has somewhere to land.
struct IDScoreLine: View {
    let kind: IDScoreKind
    let value: Float
    /// The species whose full record the explanation should quote. nil for a
    /// confidence line, which has nothing species-level to say.
    var species: String? = nil

    @State private var showInfo = false

    var body: some View {
        HStack(spacing: 5) {
            Button { showInfo = true } label: {
                Image(systemName: "info.circle").font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("About \(kind.label.lowercased())")
            .popover(isPresented: $showInfo) {
                kind.explainer(species.flatMap { ModelReliability.reliability(for: $0) })
                    .presentationCompactAdaptation(.popover)
            }
            Text("\(kind.label):")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "%.0f%%", value * 100))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(kind.color(for: value).darkenedInLightMode())
            Spacer(minLength: 0)
        }
    }
}

/// The winner and the runner-up as ONE chip — "MYYU 66% | LANO 10%" — washed
/// with a gradient running from the winner's colour to the runner-up's.
///
/// The comparison is the finding (Niall, 2026-09-10). "MYYU 80%, LANO 10%" and
/// "MYYU 45%, LANO 40%" are completely different results, and a colour scale
/// keyed to the winner's own number cannot tell them apart — 45% and 80% are
/// both just "some amount of green". Keyed to the gap, the second case turns the
/// whole chip amber and says the real thing: these two were not separated.
///
/// One chip rather than two stacked ones because they are a single statement.
/// Two chips read as two independent scores that happen to be adjacent, which is
/// exactly the misreading the pair exists to prevent.
///
/// The threshold is `SpeciesComplex.ambiguityMargin`, the same 0.20 the complex
/// machinery already uses to decide whether a runner-up counts as an active
/// ambiguity, so the chip and the complex pill can't disagree about "close".
struct ScoreComparison: View {
    let species: String
    let confidence: Float
    let runnerUpSpecies: String?
    let runnerUpConfidence: Float?

    @State private var showInfo = false

    /// True when the two are close enough that naming a winner is a coin toss.
    private var isClose: Bool {
        guard let runnerUpConfidence else { return false }
        return confidence - runnerUpConfidence < SpeciesComplex.ambiguityMargin
    }

    private var winnerColor: Color { isClose ? .orange : .green }
    /// The far end of the wash. With no runner-up there is no loser to colour,
    /// and running the gradient to red would wash the winner-alone chip the same
    /// as a decisive loss — see `isClose`, which is false in both cases.
    private var loserColor: Color {
        guard runnerUpConfidence != nil else { return winnerColor }
        return isClose ? .orange : .red
    }

    var body: some View {
        Button { showInfo = true } label: {
            VStack(alignment: .leading, spacing: 2) {
                // **Says what the two numbers are** (Niall, 2026-09-10). Without
                // it the chip is two species and two percentages with no stated
                // relationship, and the reading it invites — two independent
                // scores that happen to be adjacent — is the exact misreading the
                // single chip exists to prevent.
                //
                // Hidden from VoiceOver: the chip's own label already says
                // "against", so reading the caption too would say it twice.
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                chip
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showInfo) {
            explainer.presentationCompactAdaptation(.popover)
        }
    }

    /// No runner-up means there is nothing to be "versus" — see the explainer,
    /// which says the same thing at length.
    private var caption: String {
        runnerUpSpecies == nil ? "Winner" : "Winner vs runner-up"
    }

    private var chip: some View {
        HStack(spacing: 5) {
            score(species, confidence, winnerColor)
            if let runnerUpSpecies, let runnerUpConfidence {
                Text("|")
                    .font(.caption2.weight(.light))
                    .foregroundStyle(.secondary)
                score(runnerUpSpecies, runnerUpConfidence, loserColor)
            }
        }
        .fixedSize()
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background {
            Capsule().fill(LinearGradient(colors: [winnerColor.opacity(0.22),
                                                   loserColor.opacity(0.22)],
                                          startPoint: .leading, endPoint: .trailing))
        }
        .overlay {
            Capsule().strokeBorder(LinearGradient(
                colors: [winnerColor.darkenedInLightMode().opacity(0.45),
                         loserColor.darkenedInLightMode().opacity(0.45)],
                startPoint: .leading, endPoint: .trailing), lineWidth: 1)
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private func score(_ code: String, _ value: Float, _ color: Color) -> some View {
        Text(String(format: "%@ %.0f%%", code, value * 100))
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(color.darkenedInLightMode())
    }

    private var accessibilityText: String {
        guard let runnerUpSpecies, let runnerUpConfidence else {
            return "\(species) \(Int(confidence * 100)) percent, no close second"
        }
        return "\(species) \(Int(confidence * 100)) percent, "
            + "against \(runnerUpSpecies) \(Int(runnerUpConfidence * 100)) percent. "
            + (isClose ? "Too close to separate." : "A clear winner.")
    }

    @ViewBuilder private var explainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The two front-runners").font(.subheadline.weight(.semibold))
            Text("The species this call scored highest for, and the one that came closest to it. What matters is the gap between them, not either figure on its own.")
                .font(.caption)
            if runnerUpSpecies == nil {
                // Not "nothing else came close": a NOISE outcome skips the
                // runner-up entirely (its scores are raw, so second place there
                // means nothing), and a pass recorded before the field existed
                // has none either. The chip cannot tell those apart from a pool
                // with only one candidate, so it doesn't claim to.
                Text("There is no second species to compare this against.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isClose {
                Text("These two finished close together, so the chip is amber end to end: the model did not really separate them, and the name on this row is close to a coin toss between the two.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("These two finished well apart — green to red — so the winner beat its nearest rival clearly. That says nothing about whether either species is right, only that the model was not torn between them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
    }
}
