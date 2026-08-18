//
//  SpeciesDetailView.swift
//  OpenBat
//
//  The full field-guide species page: header/taxonomy breadcrumb, description,
//  GBIF distribution map, measurements & morphology, echolocation calls,
//  conservation status, and habits. Each section only renders when its
//  backing data is present — sparse guide entries just show fewer sections
//  rather than empty boxes, so the page scales gracefully as the
//  community-editable JSON (SpeciesGuideData.json) grows over time.
//

import SwiftUI
import UIKit

struct SpeciesDetailView: View {
    let species: GuideSpecies
    let store: SpeciesGuideStore
    let presenceStore: SpeciesPresenceStore

    @State private var showContributors = false
    @State private var photo: SpeciesPhoto?
    @State private var showConservationInfoPopover = false
    /// Measured width of the quick-facts row — see `leftQuickFactsColumnWidth`.
    @State private var quickFactsRowWidth: CGFloat = 0

    var body: some View {
        cardLayoutBody
            .navigationTitle(species.commonName)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showContributors) {
                ContributorsSheet(species: species)
            }
            .task(id: species.scientificName) {
                photo = await SpeciesPhoto.resolve(for: species)
            }
    }

    // MARK: Card layout

    /// Photo-forward ScrollView of rounded cards, with a "quick facts" tile
    /// grid up top for the numbers a user glances at first
    /// (forearm/wingspan/weight/peak freq/duration) instead of burying them
    /// in labeled rows further down. Every section here is optional on the
    /// species' data presence — a sparse guide entry just shows fewer cards.
    /// Replaced the original List-of-Sections layout outright (2026-07-28) —
    /// it briefly existed behind a toolbar toggle for comparison; see git
    /// history if that layout's code is ever needed again.
    private var cardLayoutBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let photo {
                    cardHeroPhoto(photo)
                }
                VStack(alignment: .leading, spacing: 20) {
                    cardHeaderSection
                    if let summary = species.summary {
                        GuideCard(title: "Overview") {
                            Text(summary).font(.subheadline)
                        }
                    }
                    if hasQuickFactsRow {
                        // A third-width left column, two-thirds right — unlike
                        // an even 50/50 split, that ratio isn't something an
                        // HStack of `maxWidth: .infinity` children falls into
                        // by construction, so the left column's width is
                        // measured off the row itself (`.onGeometryChange`,
                        // read-only — doesn't affect the row's own sizing) and
                        // applied as an explicit fraction. Nil until the first
                        // measurement lands, so the very first layout pass
                        // uses natural sizing instead of collapsing to zero
                        // width for one frame.
                        //
                        // Both columns are `maxHeight: .infinity`, and the
                        // second row of each (the sub-stat stack on the left,
                        // the size card on the right) stretches to fill
                        // whatever height the taller column establishes. That
                        // is what makes the two columns line up top *and*
                        // bottom, whichever one happens to be taller. The size
                        // card was previously pinned square with a `Spacer`
                        // above it, which necessarily left its top edge
                        // floating below the first sub-stat's; letting it fill
                        // the column instead is what squares the alignment up.
                        // `SizeComparisonCard` sizes its glyphs off whatever
                        // space it's given, so it doesn't care about the shape
                        // it ends up — and the extra height it gains here is
                        // what stops the reference glyph being squeezed small.
                        HStack(alignment: .top, spacing: 10) {
                            VStack(spacing: 8) {
                                if let peakFreqFact {
                                    HeadlineQuickFactTile(fact: peakFreqFact)
                                }
                                ForEach(subQuickFacts) { CompactQuickFactTile(fact: $0) }
                            }
                            .frame(width: leftQuickFactsColumnWidth, alignment: .leading)
                            .frame(maxHeight: .infinity)

                            VStack(spacing: 8) {
                                if let weightFact {
                                    HeadlineQuickFactTile(fact: weightFact) {
                                        if let medianWeightG {
                                            WeightComparisonGlyph(weightGrams: medianWeightG)
                                        }
                                    }
                                }
                                if let medianWingspanCm {
                                    // `minHeight` guards the degenerate case:
                                    // a sparse entry with no sub-stats leaves
                                    // the left column shorter than this one,
                                    // and without a floor the card would
                                    // collapse to near-nothing.
                                    SizeComparisonCard(wingspanCm: medianWingspanCm)
                                        .frame(minHeight: 150, maxHeight: .infinity)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                            quickFactsRowWidth = width
                        }
                    }
                    GuideCard(title: "Distribution") {
                        GBIFDistributionCard(species: species, presenceStore: presenceStore, mapHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if species.measurements != nil || species.morphology != nil {
                        GuideCard(title: "Measurements & Morphology") { measurementsContent }
                    }
                    if species.echolocation != nil {
                        GuideCard(title: "Echolocation Calls") { echolocationContent }
                    }
                    if let c = species.conservation, c.iucnStatus != nil || c.localStatus != nil {
                        GuideCard(title: "Conservation Status", accessory: AnyView(conservationInfoButton)) { conservationContent }
                    }
                    if species.habits != nil {
                        GuideCard(title: "Habits") { habitsContent }
                    }
                    GuideCard(title: "Regions") { regionsContent }
                    if hasReferences {
                        GuideCard(title: "References") { referencesContent }
                    }
                }
                .padding(16)
                // **Pins the content to the viewport width, so the page cannot
                // be dragged sideways.** A vertical `ScrollView` is backed by a
                // `UIScrollView` whose `contentSize` is the measured content in
                // *both* axes — so a single child that measures wider than the
                // screen makes the whole page pan horizontally, even though only
                // `.vertical` was ever asked for. Declaring the axis is not
                // enough; the content has to actually fit.
                //
                // Applied here rather than by hunting the guilty child because
                // this page assembles ~10 optional cards from
                // community-maintained JSON — a long unbroken citation URL or a
                // wide photo is one bad entry away at any time, and `cardHeroPhoto`
                // below documents a previous instance of exactly this. Anything
                // over-wide is now clipped instead of scrollable, which is the
                // behaviour asked for (Niall, 2026-08-17).
                .containerRelativeFrame(.horizontal)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    /// Full-bleed hero photo — real per-image credit (photographer + license)
    /// sits in a pill over the bottom-right corner rather than a caption
    /// underneath, so it reads as an overlay attribution instead of stealing
    /// space of its own.
    ///
    /// `Color.clear` is what defines this view's layout size, with both the
    /// image and the credit pill hung off it as overlays — and that is
    /// load-bearing, not stylistic. The obvious spelling
    /// (`image.scaledToFill().frame(height: 260).frame(maxWidth: .infinity)`,
    /// in a ZStack with the pill) blew the whole page out horizontally on any
    /// species with a wide photo: `.frame(height:)` leaves width unspecified,
    /// so it adopts its child's width, and `scaledToFill` reports
    /// `260 × imageAspect` — ~500pt for a panorama. `.clipped()` doesn't save
    /// you, because it clips *drawing*, not *layout*. The ScrollView's content
    /// then measured wider than the screen and every card on the page got
    /// centre-clipped on both edges. Overlays can't expand their parent, so
    /// this arrangement is immune to that regardless of image aspect (and of
    /// how long a credit string ends up being).
    private func cardHeroPhoto(_ photo: SpeciesPhoto) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 260)
            .overlay {
                AsyncImage(url: photo.url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Color(.systemGray5)
                    }
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                Text(photo.creditText)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.8), in: Capsule())
                    .padding(10)
            }
    }

    /// The hero photo actually shown, resolved from either source — a plain
    /// `URL` + credit string once resolved, regardless of where it came from.
    ///
    /// Prefers `species.imageURL`, the contributor-set field (see its doc
    /// comment in `GuideSpecies` for why that's now preferred over a live
    /// lookup). Falls back to `WikipediaSpeciesImageService` only for guide
    /// entries that haven't set one yet, so older entries aren't left blank.
    fileprivate struct SpeciesPhoto: Equatable {
        let url: URL
        let creditText: String

        static func resolve(for species: GuideSpecies) async -> SpeciesPhoto? {
            if let urlString = species.imageURL, let url = URL(string: urlString) {
                return SpeciesPhoto(url: url, creditText: species.imageCredit ?? "Field guide contributor")
            }
            guard let wiki = await WikipediaSpeciesImageService.fetchPhoto(for: species.scientificName)
            else { return nil }
            return SpeciesPhoto(url: wiki.url, creditText: wiki.creditText)
        }
    }

    /// Name/sci-name/breadcrumb, plus an inline IUCN status badge when
    /// present — surfaced here rather than buried in the "Conservation
    /// Status" card further down, since it's the kind of at-a-glance fact
    /// this layout is meant to lead with.
    private var cardHeaderSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(species.commonName)
                        .font(.title2.bold())
                    Text(species.scientificName)
                        .font(.headline.italic())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let iucn = species.conservation?.iucnStatus {
                    IUCNBadge(status: iucn)
                }
            }
            if !breadcrumb.isEmpty {
                Text(breadcrumb)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Curated set of headline numbers pulled from measurements/echolocation —
    /// deliberately not every field (that's what the fuller cards below are
    /// for), just the handful a field-guide user checks first to confirm an ID.
    fileprivate struct QuickFact: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
        let value: String
    }

    /// Left column's headline tile. Peak Freq is a key acoustic ID trait, so
    /// it leads the column its sub-stats (Forearm/Wingspan/Call Duration) sit
    /// under, same as Weight leads the right column below.
    private var peakFreqFact: QuickFact? {
        guard let r = species.echolocation?.peakFreqHzRange else { return nil }
        return QuickFact(icon: "waveform", label: "Peak Freq", value: r.formattedHz())
    }

    /// Right column's headline tile, sitting above `SizeComparisonCard` —
    /// Weight pairs naturally with a physical-size card the way Peak Freq
    /// pairs with the left column's acoustic sub-stats.
    private var weightFact: QuickFact? {
        guard let r = species.measurements?.weightGRange else { return nil }
        return QuickFact(icon: "scalemass", label: "Weight", value: r.formatted(unit: "g"))
    }

    /// Remaining quick facts, stacked under the Peak Freq headline in the
    /// left column — every `QuickFact` except the two promoted to headlines.
    /// Four rows (Forearm/Wingspan/Call Duration/Char Freq) under the Peak
    /// Freq headline is what makes the left column's natural height reliably
    /// taller than the right column's Weight headline + square size card —
    /// with only three, the square (sized to the column's own width) could
    /// come out taller than the left column's content, making the right
    /// column the tallest child in the row instead and throwing off the
    /// bottom-edge alignment between the two columns.
    private var subQuickFacts: [QuickFact] {
        var facts: [QuickFact] = []
        if let r = species.measurements?.forearmMmRange {
            facts.append(QuickFact(icon: "ruler", label: "Forearm", value: r.formatted(unit: "mm")))
        }
        if let r = species.measurements?.wingspanCmRange {
            facts.append(QuickFact(icon: "arrow.left.and.right", label: "Wingspan", value: r.formatted(unit: "cm")))
        }
        if let r = species.echolocation?.durationMsRange {
            facts.append(QuickFact(icon: "timer", label: "Call Duration", value: r.formatted(unit: "ms")))
        }
        if let r = species.echolocation?.characteristicFreqHzRange {
            facts.append(QuickFact(icon: "tuningfork", label: "Char Freq", value: r.formattedHz()))
        }
        return facts
    }

    private var hasQuickFactsRow: Bool {
        peakFreqFact != nil || weightFact != nil || medianWingspanCm != nil || !subQuickFacts.isEmpty
    }

    /// A third of the quick-facts row, minus its share of the inter-column
    /// spacing — the left column's fixed width; the right column just keeps
    /// its `maxWidth: .infinity` and fills whatever's left, which comes out
    /// to two-thirds automatically. Nil until `quickFactsRowWidth` has been
    /// measured at least once, so the column uses natural sizing rather than
    /// collapsing to zero width on the first layout pass.
    private var leftQuickFactsColumnWidth: CGFloat? {
        guard quickFactsRowWidth > 0 else { return nil }
        let spacing: CGFloat = 10
        return (quickFactsRowWidth - spacing) / 3
    }

    /// Midpoint of the wingspan range — the single number `SizeComparisonCard`
    /// scales its bat glyph against. Nil (no size card shown) when the entry
    /// has no wingspan data at all.
    private var medianWingspanCm: Double? {
        guard let r = species.measurements?.wingspanCmRange else { return nil }
        return (r.min + r.max) / 2
    }

    /// Midpoint of the weight range — what `WeightComparisonGlyph` matches
    /// against the object ladder. Same reasoning as `medianWingspanCm`: a
    /// single representative number reads better than trying to show a range.
    private var medianWeightG: Double? {
        guard let r = species.measurements?.weightGRange else { return nil }
        return (r.min + r.max) / 2
    }

    // MARK: References

    private var hasReferences: Bool {
        species.creator != nil || (species.references?.isEmpty == false)
    }

    @ViewBuilder private var referencesContent: some View {
        if let creator = species.creator {
            Button {
                showContributors = true
            } label: {
                ContributorSummaryRow(creator: creator, editorCount: species.editors.count)
            }
            .buttonStyle(.plain)
        }
        ForEach(Array((species.references ?? []).enumerated()), id: \.offset) { _, citation in
            Text(citation)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Regions

    @ViewBuilder private var regionsContent: some View {
        ForEach(store.guide.regions.filter { species.regions.contains($0.id) }) { region in
            Label(region.name, systemImage: "globe.europe.africa")
        }
    }

    // MARK: Header

    private var breadcrumb: String {
        [species.order, species.family, species.genus]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " › ")
    }

    // MARK: Measurements & morphology

    /// Row data for the Forearm/Wingspan/Weight/Ears/Tail/Nose table — same
    /// "only the fields this entry actually has" rule as `echoStatRows`.
    private var measurementStatRows: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let r = species.measurements?.forearmMmRange { rows.append(("Forearm", r.formatted(unit: "mm"))) }
        if let r = species.measurements?.wingspanCmRange { rows.append(("Wingspan", r.formatted(unit: "cm"))) }
        if let r = species.measurements?.weightGRange { rows.append(("Weight", r.formatted(unit: "g"))) }
        if let ear = species.morphology?.earType { rows.append(("Ears", ear)) }
        if let tail = species.morphology?.tailType { rows.append(("Tail", tail)) }
        if let nose = species.morphology?.noseType { rows.append(("Nose", nose)) }
        return rows
    }

    @ViewBuilder private var measurementsContent: some View {
        if let description = species.measurements?.morphologyDescription {
            HabitRow(title: "Description", text: description)
        }
        if !measurementStatRows.isEmpty {
            StatsTable(rows: measurementStatRows)
        }
        if let features = species.morphology?.otherFeatures, !features.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Characteristic Features")
                    .font(.subheadline.weight(.semibold))
                // TODO: illustrated morphology icons — see Context.md §16.
                ForEach(features, id: \.self) { feature in
                    Label(feature, systemImage: "sparkle")
                        .font(.subheadline)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Echolocation

    /// Row data for the Pf/Cf/Fhigh/Flow/Duration table — only the fields a
    /// given species entry actually has, so a sparse entry just gets a
    /// shorter table rather than blank rows.
    private var echoStatRows: [(label: String, value: String)] {
        guard let echo = species.echolocation else { return [] }
        var rows: [(label: String, value: String)] = []
        if let r = echo.peakFreqHzRange { rows.append(("Peak Freq (Pf)", r.formattedHz())) }
        if let r = echo.characteristicFreqHzRange { rows.append(("Characteristic Freq (Cf)", r.formattedHz())) }
        if let r = echo.freqHighHzRange { rows.append(("Fhigh", r.formattedHz())) }
        if let r = echo.freqLowHzRange { rows.append(("Flow", r.formattedHz())) }
        if let r = echo.durationMsRange { rows.append(("Duration", r.formatted(unit: "ms"))) }
        return rows
    }

    @ViewBuilder private var echolocationContent: some View {
        if let echo = species.echolocation {
            if let type = echo.callType {
                HabitRow(title: "Call Type", text: type)
            }
            if !echoStatRows.isEmpty {
                StatsTable(rows: echoStatRows)
            }
            if let notes = echo.notes {
                HabitRow(title: "Notes", text: notes)
            }
            if let imageName = echo.exemplarImageName, let uiImage = UIImage(named: imageName) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                exemplarPlaceholder
            }
        }
    }

    private var exemplarPlaceholder: some View {
        Label("Exemplar call coming soon", systemImage: "waveform")
            .foregroundStyle(.secondary)
    }

    // MARK: Conservation

    @ViewBuilder private var conservationContent: some View {
        if let c = species.conservation {
            if let local = c.localStatus {
                HabitRow(title: "Local Status", text: local)
            }
            if let iucn = c.iucnStatus {
                VStack(alignment: .leading, spacing: 4) {
                    Text("IUCN")
                        .font(.subheadline.weight(.semibold))
                    IUCNBadge(status: iucn)
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// "?" info button in the Conservation Status card's top-right, next to
    /// the title — explains the Local vs. IUCN distinction, since the two
    /// can (and often do) disagree: a species secure worldwide can still be
    /// declining or protected in the specific region this guide covers.
    private var conservationInfoButton: some View {
        Button {
            showConservationInfoPopover = true
        } label: {
            Image(systemName: "questionmark.circle.fill")
                .font(.subheadline)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About Local vs. IUCN status")
        .popover(isPresented: $showConservationInfoPopover) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Local vs. IUCN Status")
                    .font(.headline)
                Text("IUCN status is this species' global conservation ranking from the International Union for Conservation of Nature, based on population trends worldwide. Local status reflects protections or population concerns specific to the region this guide covers, which can differ from the global picture — a species can be secure globally but declining or protected locally, or vice versa.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            // See GBIFRangeMapView's identical info popover for why a fixed
            // width (not `frame(maxWidth:)`) is what's needed to make the
            // Text actually wrap instead of rendering as one truncated line.
            .frame(width: 280)
            .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: Habits

    @ViewBuilder private var habitsContent: some View {
        if let h = species.habits {
            if let v = h.roosting { HabitRow(title: "Roosting", text: v) }
            if let v = h.migration { HabitRow(title: "Migration", text: v) }
            if let v = h.feeding { HabitRow(title: "Feeding", text: v) }
            if let v = h.reproduction { HabitRow(title: "Reproduction", text: v) }
            if let v = h.other { HabitRow(title: "Other", text: v) }
        }
    }
}

/// Rounded card wrapper used throughout the page — a plain background +
/// title, no List/Section chrome.
private struct GuideCard<Content: View>: View {
    let title: String
    /// Optional trailing control next to the title — e.g. the Conservation
    /// Status card's "about this" info button. Type-erased rather than a
    /// second generic `@ViewBuilder` parameter: every other call site uses
    /// plain trailing-closure syntax for `content`, and a second ViewBuilder
    /// generic would only bind to that trailing closure, not `content`.
    var accessory: AnyView?
    @ViewBuilder var content: () -> Content

    init(title: String, accessory: AnyView? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                accessory
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// One row in the card layout's "quick facts" column — icon, value, label
/// laid out horizontally rather than stacked, so the column reads as a
/// single compact list next to `SizeComparisonCard` instead of the wider
/// 2-column tile grid this replaced.
private struct CompactQuickFactTile: View {
    let fact: SpeciesDetailView.QuickFact

    var body: some View {
        HStack(spacing: 8) {
            // Sized to roughly span the two-line text block beside it (label
            // line + value line), so its top edge reads level with "label"
            // and its bottom edge reads level with the value underneath,
            // rather than a small icon centered awkwardly next to two lines.
            Image(systemName: fact.icon)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(fact.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(fact.value)
                    .font(.subheadline.weight(.semibold))
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // `maxHeight` so a short left column (a sparse entry with only one or
        // two sub-stats) stretches its tiles to meet the size card's bottom
        // edge rather than leaving a ragged gap. When the left column is the
        // taller of the two — the usual case — there's no slack to take up and
        // the tiles just sit at their natural height.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// Headline tile leading each quick-facts column (Peak Freq on the left,
/// Weight on the right, above `SizeComparisonCard`) — bigger value text and
/// an icon+label header row, so these two stats read as the "lead" numbers
/// rather than blending into the sub-stats stacked underneath.
///
/// `trailing` sits directly beside the value text — used only by the Weight
/// tile, for `WeightComparisonGlyph`. Defaults to nothing so Peak Freq's call
/// site doesn't need to change.
private struct HeadlineQuickFactTile<Trailing: View>: View {
    let fact: SpeciesDetailView.QuickFact
    @ViewBuilder var trailing: () -> Trailing

    init(fact: SpeciesDetailView.QuickFact,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.fact = fact
        self.trailing = trailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: fact.icon)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(fact.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(fact.value)
                    .font(.title2.weight(.bold))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Spacer(minLength: 4)
                trailing()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// An everyday object the bat is drawn against, for scale. Tapping the glyph
/// cycles to the next one (see `SizeComparisonCard`).
///
/// `inkWidthCm` is the real-world width the glyph's *visible artwork* spans
/// left-to-right — which is not always the dimension people quote. The
/// banana is drawn on a diagonal, so its familiar "18 cm long" is the
/// tip-to-stem diagonal of its artwork; horizontally that only spans ~12 cm
/// (18 × 696⁄√(696² + 772²), from its ink bounding box). `caption` shows the
/// quoted dimension, `inkWidthCm` drives the geometry.
private enum ScaleReference: CaseIterable {
    case hand, banana

    var next: ScaleReference {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// Real-world width spanned by the glyph's ink. Both are placeholders —
    /// swap in measured values if you want them exact.
    var inkWidthCm: CGFloat {
        switch self {
        case .hand: 11
        case .banana: 12.053
        }
    }

    /// What the caption quotes — the dimension a person would actually cite,
    /// which for the diagonal banana is its length, not its ink width.
    var caption: String {
        switch self {
        case .hand: "Hand ~11 cm"
        case .banana: "Banana ~18 cm"
        }
    }

    /// Fraction of its layout frame width this glyph's ink spans, and the
    /// frame's height ÷ width. Measured off the rendered artwork by scanning
    /// alpha/ink bounds — see `SizeComparisonCard`'s doc comment for why the
    /// frame-vs-ink distinction matters.
    var inkFraction: CGFloat {
        switch self {
        case .hand: 0.658      // SF Symbols pad their boxes
        case .banana: 1.0      // asset viewBox trimmed to the artwork
        }
    }

    var frameAspect: CGFloat {
        switch self {
        case .hand: 1.0
        case .banana: 772.0 / 696
        }
    }

    var accessibilityName: String {
        switch self {
        case .hand: "a hand"
        case .banana: "a banana"
        }
    }

    @ViewBuilder var glyph: some View {
        switch self {
        case .hand:
            Image(systemName: "hand.raised.fill").resizable()
        case .banana:
            Image("bananaIcon").renderingMode(.template).resizable()
        }
    }
}

/// True-to-scale bat-vs-everyday-object size card, next to the quick-facts
/// column. Tapping the reference glyph swaps it (hand ⇄ banana).
///
/// The invariant is the *ratio of visible ink*, never either glyph's
/// absolute size: the drawn bat is always `wingspanCm / reference.inkWidthCm`
/// times as wide as the drawn reference. Both frames come out of
/// `glyphFrames(in:reference:)` together, derived from one shared
/// points-per-cm, so neither can be nudged for looks without the other
/// following — that's what keeps two different species' bat glyphs
/// comparable to each other and not just to the object beside them.
///
/// Two things make that less trivial than it sounds:
///
/// 1. **Ink ≠ frame.** A glyph's visible artwork doesn't fill its layout
///    frame — `hand.raised.fill` inks only ~66% of its frame width, since SF
///    Symbols pad their boxes. Scaling the *frames* in true proportion would
///    therefore draw the hand ~34% too narrow. Each frame is divided by its
///    own ink fraction so it's the ink, not the box, that ends up in true
///    proportion.
/// 2. **Both axes bind.** The card is square and holds two stacked glyphs, so
///    for a big-wingspan species height runs out before width does. A
///    width-only cap overflowed the card and pushed the reference glyph out
///    of view entirely, so the scale is capped against available height too.
///
/// Within those caps the card aims for `preferredReferenceInkWidth`; when a
/// cap binds, the whole pair scales down together — the bat grows to fill
/// the card and the reference simply gets smaller.
///
/// `batIconTop` (Assets.xcassets) is the real illustrated glyph — a
/// template-rendered SVG outline, tinted `.secondary` to match the reference
/// glyph below it rather than standing out as its own color.
private struct SizeComparisonCard: View {
    let wingspanCm: Double

    @State private var reference: ScaleReference = .hand

    /// Visible reference-glyph width aimed for when neither cap binds.
    private static let preferredReferenceInkWidth: CGFloat = 50
    /// From `batIconTop`'s artwork-trimmed 70 × 31 viewBox.
    private static let batInkFraction: CGFloat = 0.996
    private static let batFrameAspect: CGFloat = 31.0 / 70
    /// Gap between the two glyphs, excluded from the height available to them.
    private static let glyphSpacing: CGFloat = 6

    /// Frames for both glyphs, sized by one shared points-per-cm so their
    /// visible ink stays in true wingspan : reference proportion, and capped
    /// so the pair fits `size` on both axes.
    private func glyphFrames(in size: CGSize, reference: ScaleReference) -> (bat: CGSize, reference: CGSize) {
        let wingspan = max(CGFloat(wingspanCm), 1)
        let refCm = reference.inkWidthCm
        // Each glyph's frame width at a scale of one point per cm.
        let batUnit = wingspan / Self.batInkFraction
        let refUnit = refCm / reference.inkFraction

        // `max` of the two: for a small enough bat the reference glyph is the
        // wider of the pair, so capping on the bat alone would let the
        // reference overflow.
        let widthCap = size.width / max(batUnit, refUnit)
        let stackedHeightPerUnit = batUnit * Self.batFrameAspect + refUnit * reference.frameAspect
        let heightCap = max(0, size.height - Self.glyphSpacing) / stackedHeightPerUnit
        let preferred = Self.preferredReferenceInkWidth / refCm

        let pointsPerCm = max(0, min(preferred, widthCap, heightCap))
        let batW = batUnit * pointsPerCm, refW = refUnit * pointsPerCm
        return (CGSize(width: batW, height: batW * Self.batFrameAspect),
                CGSize(width: refW, height: refW * reference.frameAspect))
    }

    var body: some View {
        VStack(spacing: 6) {
            Text("True Size")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            // Bounded on both axes — the card's own size is fixed by the
            // caller's `.aspectRatio(1, contentMode: .fit)`, so this only
            // measures leftover space and can't grow to drive its own
            // parent. No state is written back, so there's no layout
            // feedback loop either.
            GeometryReader { geo in
                let frames = glyphFrames(in: geo.size, reference: reference)
                VStack(spacing: Self.glyphSpacing) {
                    Spacer(minLength: 0)
                    Image("batIconTop")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: frames.bat.width, height: frames.bat.height)
                        .foregroundStyle(.secondary)
                    Button {
                        withAnimation(.snappy) { reference = reference.next }
                    } label: {
                        reference.glyph
                            .scaledToFit()
                            .frame(width: frames.reference.width, height: frames.reference.height)
                            .foregroundStyle(.secondary)
                            // Keeps the tap target usable when the glyph
                            // scales down for a large-wingspan species.
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Compare against \(reference.accessibilityName)")
                    .accessibilityHint("Switches to \(reference.next.accessibilityName)")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(reference.caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .contentTransition(.opacity)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// One rung on the weight-comparison ladder: an everyday object familiar
/// enough that "about as heavy as N of these" means something at a glance,
/// with no number to look up. See `WeightComparisonGlyph`.
///
/// Emoji rather than SF Symbols or hand-drawn artwork (unlike `ScaleReference`
/// above) — there's no SF Symbol for a strawberry or a tin of beans, and an
/// emoji needs no asset-catalog entry to add or re-tune. `half` is the coin's
/// masked-to-its-left-half rendering, not a separate icon — see
/// `WeightComparisonGlyph`.
private struct WeightUnit {
    let name: String
    let grams: Double
    let emoji: String
    var half: Bool = false
}

/// Ordered small to large. Chosen so consecutive rungs are roughly 2-3×
/// apart — close enough together that `bestWeightMatch` always has a rung
/// that lands within a count of 1-3, which is what keeps the result reading
/// as "a handful of a relevant object" rather than "a pile of a small one".
private let weightLadder: [WeightUnit] = [
    WeightUnit(name: "Half a coin", grams: 4, emoji: "🪙", half: true),
    WeightUnit(name: "A coin", grams: 8, emoji: "🪙"),
    WeightUnit(name: "A strawberry", grams: 10, emoji: "🍓"),
    WeightUnit(name: "An AA battery", grams: 23, emoji: "🔋"),
    WeightUnit(name: "A tennis ball", grams: 58, emoji: "🎾"),
    WeightUnit(name: "An apple", grams: 182, emoji: "🍎"),
    WeightUnit(name: "A tin of beans", grams: 400, emoji: "🥫"),
    WeightUnit(name: "A loaf of bread", grams: 800, emoji: "🍞"),
]

/// Largest relative error a match is allowed before it's considered
/// "close enough" — see `bestWeightMatch`.
private let weightMatchTolerance = 0.20

/// The (object, count) pair `WeightComparisonGlyph` shows for `weight`.
///
/// Picking whichever (rung, count) numerically minimises error sounds
/// right and isn't: for 25g it picks "3 coins" over "an AA battery" — 24g is
/// a hair closer to 25g than 23g is, but a single named object beats a small
/// pile of a smaller one even when the pile is marginally more precise. What
/// actually reads as "about right" is the biggest object that gets
/// reasonably close on its own, reached for a *second or third* copy only
/// when one alone isn't enough.
///
/// So: scan rungs biggest to smallest, and within a rung try 1, then 2, then
/// 3 copies, returning the first that lands within `weightMatchTolerance`.
/// `half` rungs are never tried past a single copy — a "half coin" is
/// already a fraction, and "3× half a coin" reads as nonsense rather than a
/// weight. If nothing on the ladder gets close enough (weight sits in a gap
/// between two rungs' reach), fall back to whichever (rung, count) is
/// numerically nearest, preferring fewer copies and then the bigger object
/// on a tie.
private func bestWeightMatch(forGrams weight: Double) -> (unit: WeightUnit, count: Int) {
    for unit in weightLadder.reversed() {
        let maxCount = unit.half ? 1 : 3
        for count in 1...maxCount {
            let error = abs(unit.grams * Double(count) - weight) / weight
            if error <= weightMatchTolerance {
                return (unit, count)
            }
        }
    }
    var best: (unit: WeightUnit, count: Int, error: Double)?
    for unit in weightLadder {
        let maxCount = unit.half ? 1 : 3
        for count in 1...maxCount {
            let error = abs(unit.grams * Double(count) - weight) / weight
            guard let current = best else {
                best = (unit, count, error)
                continue
            }
            if error < current.error
                || (error == current.error && (count, -unit.grams) < (current.count, -current.unit.grams)) {
                best = (unit, count, error)
            }
        }
    }
    return (best!.unit, best!.count)
}

/// The weight-comparison glyph shown beside the gram figure in the Weight
/// headline tile — "×2 🔋" next to "3–8 g", not a card of its own. Weight
/// can't be drawn true-to-scale the way `SizeComparisonCard` draws wingspan,
/// so instead of scaling one fixed reference this picks the best-fitting
/// (object, count) pair off `weightLadder` via `bestWeightMatch` and shows
/// just that — the object's name lives in `WeightUnit.name` for the
/// accessibility label, not on screen, since the tile has no room for it.
private struct WeightComparisonGlyph: View {
    let weightGrams: Double

    var body: some View {
        let match = bestWeightMatch(forGrams: weightGrams)
        HStack(spacing: 2) {
            if match.count > 1 {
                Text("×\(match.count)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            Text(match.unit.emoji)
                .font(.system(size: 22))
                // The coin's "half" rendering: masks the emoji's glyph to its
                // left half rather than needing a second icon. Any rung could
                // use this, but only the half-coin rung does.
                .mask(alignment: .leading) {
                    GeometryReader { geo in
                        Rectangle().frame(width: match.unit.half ? geo.size.width / 2 : geo.size.width)
                    }
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("about as heavy as \(match.count > 1 ? "\(match.count) " : "")\(match.unit.name.lowercased())")
    }
}

/// IUCN Red List status pill — shown in the page header (when present) and
/// again in the Conservation Status card, below the free-text local status.
/// The short IUCN code, colour-coded, or nothing at all.
///
/// Was `Text(status)` in an orange capsule — showing the guide's raw status
/// string. That reads fine for "Least Concern" and badly for the entries that
/// carry a qualifier, one of which runs to a full sentence about federally
/// endangered US subspecies and would have set that whole sentence in a badge.
/// The long form belongs on the Conservation card below, where it already is;
/// the header wants the two-letter code.
private struct IUCNBadge: View {
    let status: String

    var body: some View {
        if let badge = IUCNStatusStyle.forStatus(status) {
            Text(badge.text)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(badge.color.opacity(0.18), in: Capsule())
                .foregroundStyle(badge.color)
        }
    }
}

/// Subheading + paragraph row — used by the habits section; the measurements
/// card's "Description"; the echolocation card's "Call Type" and "Notes";
/// and the conservation card's "Local Status". A one-line stat doesn't suit
/// free text like this, and burying it in a plain unlabeled paragraph reads
/// worse than giving it its own subheading.
private struct HabitRow: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Label/value rows as an actual aligned table (via `Grid`) rather than a
/// stack of `StatRow`s — a Grid keeps every value's leading edge aligned in
/// one column regardless of how long each row's label is, which a stack of
/// independent HStacks can't do. Shared by the measurements/morphology and
/// echolocation cards.
private struct StatsTable: View {
    let rows: [(label: String, value: String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    Text(row.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(row.value)
                        .font(.subheadline.weight(.medium))
                        .gridColumnAlignment(.trailing)
                }
                if index < rows.count - 1 {
                    Divider()
                        .gridCellColumns(2)
                }
            }
        }
    }
}

/// Compact "Created by X · N edits" row shown at the top of the References
/// section; tapping it opens `ContributorsSheet` for the full history.
private struct ContributorSummaryRow: View {
    let creator: SpeciesContributor
    let editorCount: Int

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Created by \(creator.name)")
                    if let date = creator.parsedDate {
                        Text(date, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "person.crop.circle")
            }
            Spacer()
            if editorCount > 0 {
                Text("+\(editorCount) edit\(editorCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
    }
}

/// Full contributor history for a species page — creator plus every editor,
/// each with their date and an optional note on what they changed.
private struct ContributorsSheet: View {
    let species: GuideSpecies
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let creator = species.creator {
                    Section("Created") {
                        ContributorRow(contributor: creator)
                    }
                }
                if !species.editors.isEmpty {
                    Section("Edited") {
                        ForEach(species.editors, id: \.self) { editor in
                            ContributorRow(contributor: editor)
                        }
                    }
                }
            }
            .navigationTitle("Contributors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ContributorRow: View {
    let contributor: SpeciesContributor

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(contributor.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let date = contributor.parsedDate {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let note = contributor.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private extension MeasurementRange {
    func formatted(unit: String) -> String {
        // Defensive: a hand-edited JSON entry could have min/max swapped.
        let lo = Swift.min(min, max), hi = Swift.max(min, max)
        return lo == hi ? "\(lo.formattedTrimmed) \(unit)" : "\(lo.formattedTrimmed)–\(hi.formattedTrimmed) \(unit)"
    }

    /// Hz ranges display in kHz, matching the app's spectrogram/pulse UI conventions.
    func formattedHz() -> String {
        let kHzRange = MeasurementRange(min: min / 1000, max: max / 1000)
        return kHzRange.formatted(unit: "kHz")
    }
}

private extension Double {
    var formattedTrimmed: String {
        truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", self) : String(format: "%.1f", self)
    }
}
