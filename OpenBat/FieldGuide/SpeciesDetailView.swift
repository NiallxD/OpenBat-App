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

/// The page's cards, in the order they are drawn. Their only job is to be a
/// scroll target: `SpeciesComparisonView` reads which section the pane you are
/// scrolling has reached and moves the other pane to the section with the same
/// name, which is the whole of linked scrolling.
///
/// A section a species has no data for simply isn't drawn — so asking the other
/// pane to scroll to it does nothing and that pane holds still, which is the
/// right answer for a bat with no echolocation entry.
enum GuideSection: Hashable, CaseIterable {
    /// The very top of the page, above the hero photo. Not a card — an anchor,
    /// and the page needs one: the hero isn't a section, so with `header` (which
    /// sits *below* a 260pt photo) as the highest thing to scroll to, a pane
    /// that followed you down could never be sent back to the top again. No
    /// section qualified as reached up there, so the follower was given no
    /// instruction at all and just stayed where it was.
    case top
    /// The very end of the page, for the mirror of `top`'s problem: the last
    /// card's own top can be a long way above the end of a page, so a leader
    /// scrolled all the way down would leave the follower parked at that card's
    /// heading with a screen of content still below it.
    case bottom
    case header
    case overview
    case quickFacts
    case distribution
    case measurements
    case echolocation
    case conservation
    case habits
    case regions
}

/// The wiring between one species page and the pane beside it. Supplied only
/// when this page is half of a comparison; nil the rest of the time, and then
/// none of the tracking below is installed at all.
struct SectionScrollLink {
    /// Section this pane has been told to scroll to. Changing it scrolls.
    var scrollTo: GuideSection?
    /// The user has their finger on this pane — it leads from now on.
    var onUserScroll: () -> Void
    /// This pane's scroll has reached the top of a new section.
    var onTopSection: (GuideSection) -> Void
}

/// What one pane's scroll position is worth reporting: how far down it is, and
/// whether it has run out of page. Equatable so the observer stays quiet while
/// neither answer changes.
private struct ScrollProbe: Equatable {
    var line: CGFloat
    var atEnd: Bool
}

/// Coordinate space of the page's own content. A card's frame inside it does
/// not change while the page scrolls, which is exactly why the offsets are
/// measured here: they settle once, at layout, instead of churning every frame.
private let guidePageSpace = "guidePageContent"

/// Breathing room left above a card when a pane snaps to it. Landing a heading
/// flush against the top edge looks like the page has been cut off there; a
/// little space above it reads as the section having been scrolled to.
///
/// It is real padding on the card rather than an adjustment at the scroll call,
/// because `scrollTo(anchor:)` speaks in unit points — a fraction of two
/// different heights — and there is no fraction that means "16 points" on both
/// a card and a viewport. Carving the gap out of the stack's spacing instead
/// (see `cardLayoutBody`) leaves every gap on the page exactly as it was.
let guideSectionTopGap: CGFloat = 16

/// Tags a card as a section: an identity to scroll to, and its fixed offset
/// down the page.
private struct GuideSectionMarker: ViewModifier {
    let section: GuideSection
    @Binding var offsets: [GuideSection: CGFloat]
    let isTracking: Bool
    /// Zero for the top anchor — a gap there would push the hero photo down
    /// the page, and there is nothing above it to be separated from anyway.
    var topGap: CGFloat = guideSectionTopGap

    func body(content: Content) -> some View {
        if isTracking {
            content
                // Measured BEFORE the gap is added, so an offset is the card's
                // own top — what "this section has been reached" should mean —
                // while the scroll target below is the gap's top.
                .onGeometryChange(for: CGFloat.self) {
                    $0.frame(in: .named(guidePageSpace)).minY
                } action: { offsets[section] = $0 }
                .padding(.top, topGap)
                .id(section)
        } else {
            content
                .padding(.top, topGap)
                .id(section)
        }
    }
}

/// Pins the page's content to the width it should occupy — measured when one
/// is supplied, container-relative otherwise. See the call site for why the two
/// cases can't be the same call.
private struct PageContentWidth: ViewModifier {
    let explicit: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let explicit {
            content.frame(width: explicit)
        } else {
            // Full viewport width, and NOT the reading column. This is
            // attached to the page's zero-height bottom anchor, where its whole
            // job is to make the scroll content measure exactly one viewport
            // across. Narrowing it to the column here changed the width of a
            // spacer and nothing else — the cards stayed full width while the
            // number was right (Niall, 2026-09-02). The column belongs on the
            // cards themselves; see `ReadingColumn`.
            content.containerRelativeFrame(.horizontal)
        }
    }
}

/// The app's reading column (`PageColumn`), applied to a page's cards.
///
/// Off in a comparison pane. A pane already passes its own `contentWidth` and
/// has given half the window to the page beside it; narrowing each half again
/// would leave two thin ribbons. It would in fact be a no-op — half an iPad is
/// under `PageColumn.minimumContainerWidth` — but saying so at the call site
/// beats relying on that number staying where it is.
private struct ReadingColumn: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled { content.pageColumnFrame() } else { content }
    }
}

struct SpeciesDetailView: View {
    let species: GuideSpecies
    let store: SpeciesGuideStore
    let presenceStore: SpeciesPresenceStore
    /// True when this page is one half of `SpeciesComparisonView` rather than a
    /// screen of its own. Two of these are on screen at once there, and they
    /// cannot both own the navigation bar — the last one drawn would silently
    /// win the title and both would stack a sources button into the same
    /// corner. So the embedded copy claims no bar chrome; the comparison screen
    /// titles itself and labels each pane with its own strip.
    var isEmbedded = false
    /// Lets iOS's own scroll-edge blur sit under the navigation bar instead of
    /// being switched off. Presented modally (`SpeciesProfileSheet`), the page
    /// is short and the hero photo is right under the bar, so with the effect
    /// hidden the title floats over bare picture and is often unreadable. A
    /// pushed page keeps the flat treatment — see `flatTopScrollEdge()` for
    /// what it buys on this app's black screens.
    var blursNavigationBar = false
    /// Width to pin the page's content to. Nil when this page owns a screen —
    /// `containerRelativeFrame` measures that case for itself. Non-nil only
    /// from `SpeciesComparisonView`, which has to measure and pass it: see the
    /// note at the `.containerRelativeFrame` call below.
    var contentWidth: CGFloat?
    /// Set only by `SpeciesComparisonView`, to keep this page in step with the
    /// one beside it. Nil means this page is on its own and none of the scroll
    /// tracking is installed.
    var link: SectionScrollLink?

    /// Where each section sits down the page. Measured once at layout — see
    /// `guidePageSpace`.
    /// Which half of the distribution map is showing. Held here rather than in
    /// the map because the control that changes it is the card's title-row
    /// pill, which is a sibling of the map, not a child. Per detail view, so
    /// the two panes of a comparison can be set differently.
    @State private var rangeMode: GBIFDistributionCard.RangeMode = .modelled
    @State private var sectionOffsets: [GuideSection: CGFloat] = [:]
    /// Last section reported upward, so a scroll that stays inside one section
    /// reports nothing at all.
    @State private var reportedSection: GuideSection?


    @State private var showSources = false
    /// What "compare" should do here, decided by whichever stack this page is
    /// sitting in — see `SpeciesCompareMode`.
    @Environment(\.speciesCompareMode) private var compareMode
    @State private var showComparePicker = false
    /// The species chosen in the picker, held between that sheet closing and
    /// the comparison opening.
    @State private var compareWith: GuideSpecies?
    @State private var showComparison = false
    /// Only for orienting the compare glyph — see `compareButton`.
    @State private var photo: SpeciesPhoto?
    /// A small "i" glyph rather than the credit text itself sitting over the
    /// hero photo — the old always-on capsule covered a large slice of the
    /// image whenever a credit ran long (photographer name + source + licence
    /// adds up). Tapping it opens the full text in a popover instead.
    @State private var showPhotoCredit = false
    @State private var showConservationInfoPopover = false
    /// Measured width of the quick-facts row — see `leftQuickFactsColumnWidth`.
    @State private var quickFactsRowWidth: CGFloat = 0
    /// Whether the navigation bar is currently sitting on the photo rather than
    /// on the page.
    ///
    /// **The bar does work this out for itself, just too late** (Niall,
    /// 2026-09-02). A transparent bar takes its content colour from what it
    /// samples underneath, and the sample doesn't land until the scroll view
    /// first updates — so the page arrived with a black title and black buttons
    /// on a dark photo, and a millimetre of scrolling flipped them to white.
    /// Telling it outright removes the wait; it still tracks the scroll, so once
    /// the photo has gone by the bar goes back to ordinary dark ink on the page.
    ///
    /// Written by the hero photo's `onGeometryChange`, which measures this
    /// question rather than the number behind it — see there.
    @State private var barContentIsOnPhoto = true

    /// Whether the bar says the species' name.
    ///
    /// It should not while the hero photo is still under the bar: the name is
    /// already on screen twice over — in large type in the header card, and
    /// over the photo itself — and a third copy pinned under the tab bar just
    /// sits there looking like chrome nobody asked for (Niall, 2026-09-02).
    /// Once the photo has scrolled away the header goes with it, and then the
    /// bar is the only thing left saying which bat this is.
    ///
    /// **It is drawn either way, and only its ink changes** — see the principal
    /// toolbar item, which is what makes hiding it survivable at all.
    private var showsBarTitle: Bool { photo == nil || !barContentIsOnPhoto }

    var body: some View {
        page
            .task(id: species.scientificName) {
                photo = await SpeciesPhoto.resolve(for: species)
            }
    }

    /// The bar chrome is attached only when this page owns a screen. An
    /// embedded pane must not set `navigationTitle` at all — not even to the
    /// empty string: a descendant's title wins over the ancestor's, so two
    /// panes each setting one would fight each other and then overwrite
    /// `SpeciesComparisonView`'s own title.
    @ViewBuilder private var page: some View {
        if isEmbedded {
            cardLayoutBody
        } else {
            cardLayoutBody
                // **This is the modifier that actually moves the photo up, and
                // it has to be on the scroll view, not on the image.** A
                // `ScrollView` lays its content out inside a container that has
                // already had the safe area applied, so `ignoresSafeArea` on a
                // child *inside* the content (which `cardHeroPhoto` also has)
                // has nothing left to escape — the photo still began at the
                // bottom of the status bar and the page read as a black strip
                // above the image. Ignoring the top edge here starts the content
                // at y = 0, and the photo then runs under the (transparent, see
                // below) bar the way the map on Birding_Data's trip report page
                // does.
                .ignoresSafeArea(edges: .top)
                // Still set, so the system has a name for this page — the
                // parent's back button reads it. What is DRAWN is the principal
                // item below.
                .navigationTitle(species.commonName)
                .navigationBarTitleDisplayMode(.inline)
                // The hero photo runs up under this bar (see `cardHeroPhoto`'s
                // `.ignoresSafeArea(edges: .top)`) rather than stopping at it —
                // same fix as the guide globe, see `clearNavigationBarBackground()`.
                // `flatTopScrollEdge()` matters just as much here: without it,
                // iOS 26's automatic scroll-edge glass paints its own scrim
                // over the top of the scrolling content, which over a bright
                // photo reads as a solid gap between the bar and the image —
                // the bar background being hidden isn't enough on its own.
                .clearNavigationBarBackground()
                .flatTopScrollEdgeUnless(blursNavigationBar)
                .toolbarColorScheme(barContentIsOnPhoto ? .dark : nil, for: .navigationBar)
                .toolbar {
                    // **The title fades; it never appears and disappears.**
                    // Hiding it by not setting `navigationTitle` cost the whole
                    // page its taps (2026-09-02): a bar that gains or loses
                    // content mid-scroll changes shape — on iPadOS 26 the
                    // floating tab bar collapses to make room for it — and that
                    // moves the top safe area, which this page has escaped so
                    // the photo can reach the top of the window. The content
                    // stayed where it was drawn and the touches did not, so
                    // every control on the page answered to a region up to 70pt
                    // above itself. See Context.md.
                    //
                    // An item that is always there and always the same size
                    // leaves the bar's layout alone; only the ink changes.
                    // Appearance-only changes are safe — `toolbarColorScheme`
                    // flips on this same signal and always has been fine.
                    ToolbarItem(placement: .principal) {
                        Text(species.commonName)
                            .font(.headline)
                            .opacity(showsBarTitle ? 1 : 0)
                            .accessibilityHidden(!showsBarTitle)
                    }
                    // Gated outside the item for the same reason as the
                    // sources button below: an item whose content resolves to
                    // nothing is never hosted at all.
                    if compareMode.isAvailable {
                        ToolbarItem(placement: .topBarTrailing) { compareButton }
                    }
                    // The `if` sits outside the item, not inside its content: a
                    // ToolbarItem whose content resolves to nothing is never hosted
                    // at all (see the sun clock pill), so gating within it is a trap.
                    if hasSources {
                        ToolbarItem(placement: .topBarTrailing) { sourcesButton }
                    }
                }
                .sheet(isPresented: $showSources) {
                    SourcesSheet(species: species)
                }
                // The fallback path's picker. Where the host owns the stack's
                // path (the guide) it presents its own — see
                // `SpeciesCompareMode.replacesPage`.
                .sheet(isPresented: $showComparePicker) {
                    SpeciesComparePickerSheet(base: species, store: store,
                                              presenceStore: presenceStore) { chosen in
                        compareWith = chosen
                        showComparePicker = false
                    }
                }
                // **The wait is not a flourish, and `onDismiss` is not a
                // substitute for it.** Presenting anything while the
                // presentation it was chosen in is still dismissing gets
                // silently DROPPED by SwiftUI — the comparison never appears and
                // the button reads as dead. Same failure, and the same fix, as
                // the guide's "Sources & licences" button and
                // `SessionsView.reportImport`.
                //
                // Tried and REVERTED, 2026-09-02: hanging this off the sheet's
                // own `onDismiss` instead, on the reasoning that it fires when
                // the sheet has actually gone rather than guessing at 350 ms.
                // Both branches broke — the comparison came up as a black
                // screen. Whatever `onDismiss` means, the presentation
                // machinery is still busy inside it: the cover comes up with no
                // content behind it, and replacing the page tears out the host
                // the sheet is still dismissing from. The delay stays.
                //
                // What was actually wrong is that the tap had no visible
                // effect for the length of the wait, which read as a hang; the
                // picker now ticks the row you chose the moment you choose it
                // (`SpeciesComparePickerSheet.picked`).
                .onChange(of: showComparePicker) { _, isShowing in
                    guard !isShowing, compareWith != nil else { return }
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        openPickedComparison()
                    }
                }
                // The fallback path only — where the host owns a path, the
                // comparison is pushed in this page's place instead and none of
                // this runs. Full screen rather than a sheet because two species
                // pages want every point there is, and because a comparison
                // reached from a species page should read as having replaced it,
                // which is what `.replacesPage` now does literally.
                .fullScreenCover(isPresented: $showComparison, onDismiss: { compareWith = nil }) {
                    if let compareWith {
                        NavigationStack {
                            SpeciesComparisonView(first: species, second: compareWith,
                                                  store: store, presenceStore: presenceStore)
                                .toolbar {
                                    // Leading, matching Bats Near You: the
                                    // comparison owns its trailing corner for
                                    // the scroll-link toggle.
                                    ToolbarItem(placement: .topBarLeading) {
                                        Button("Done") { showComparison = false }
                                    }
                                }
                        }
                    }
                }
        }
    }

    /// Opens the comparison for the species picked in the sheet. Called only
    /// once the picker's dismissal has had time to finish — see the note on the
    /// sheet. Does nothing if the sheet was cancelled, which is why this is
    /// keyed on `compareWith` rather than on the sheet closing.
    private func openPickedComparison() {
        guard compareWith != nil else { return }
        // Only the fallback reaches here now: where the host owns the stack's
        // path it owns the picker too, and none of this page's picker state is
        // ever written.
        if case .presentsOverPage = compareMode {
            showComparison = true
        } else {
            compareWith = nil
        }
    }

    /// Starts a comparison from the bat you are already reading, rather than
    /// from a list. Same glyph as the collection page's compare toggle, so the
    /// two routes into the same screen look like the same thing.
    private var compareButton: some View {
        Button {
            switch compareMode {
            // The host owns the picker as well as the path — see
            // `SpeciesCompareMode.replacesPage` for why this page must not
            // present a sheet it is about to be removed from underneath.
            case .replacesPage(let startComparison): startComparison(species)
            case .presentsOverPage: showComparePicker = true
            case .unavailable: break
            }
        } label: {
            Image(systemName: "arrow.trianglehead.branch")
        }
        .accessibilityLabel("Compare with another species")
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
    /// This page is pinned by WIDTH rather than by content margin, unlike every
    /// other page that takes the reading column, because it already pins its
    /// width for a second reason — a single over-wide card would otherwise let
    /// the whole page scroll sideways. One pin does both jobs; see
    /// `PageContentWidth`.
    ///
    /// **A comparison pane is never affected.** Those are embedded and pass
    /// `contentWidth` explicitly, which wins: they have already given up half
    /// the window to the pane beside them, and narrowing each half again would
    /// leave two thin ribbons.

    private var cardLayoutBody: some View {
        // The reader is only here to give the follower pane something to scroll
        // with. `scrollPosition(id:)` would be the tidier spelling, but it wants
        // a `scrollTargetLayout` on the scroll view's immediate content, and
        // this page's content is a hero photo beside a stack of cards — the
        // proxy works on the ids wherever they are nested.
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Zero-height, so it changes nothing about the layout — it
                // exists only to be scrolled to. See `GuideSection.top`.
                Color.clear
                    .frame(height: 0)
                    .guideSection(.top, offsets: $sectionOffsets,
                                  tracking: link != nil, topGap: 0)
                if let photo {
                    cardHeroPhoto(photo)
                }
                // Spacing 4, not 20: every card carries `guideSectionTopGap`
                // (16) of its own now, and 4 + 16 is the 20 this page has
                // always had between cards. The gap belongs to the card because
                // that is what makes it part of the card's scroll target.
                VStack(alignment: .leading, spacing: 4) {
                    cardHeaderSection
                        .guideSection(.header, offsets: $sectionOffsets, tracking: link != nil)
                    if let summary = species.summary {
                        GuideCard(title: "Overview") {
                            Text(summary).font(.subheadline)
                        }
                        .guideSection(.overview, offsets: $sectionOffsets, tracking: link != nil)
                    }
                    if hasQuickFactsRow {
                        // A 40% left column, 60% right — unlike an even
                        // 50/50 split, that ratio isn't something an
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
                        .guideSection(.quickFacts, offsets: $sectionOffsets, tracking: link != nil)
                    }
                    GuideCard(title: "Distribution",
                              accessory: AnyView(GBIFDistributionModePill(
                                  species: species, presenceStore: presenceStore,
                                  mode: $rangeMode))) {
                        GBIFDistributionCard(species: species, presenceStore: presenceStore,
                                             mode: $rangeMode, mapHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .guideSection(.distribution, offsets: $sectionOffsets, tracking: link != nil)
                    if species.measurements != nil || species.morphology != nil {
                        GuideCard(title: "Measurements & Morphology") { measurementsContent }
                            .guideSection(.measurements, offsets: $sectionOffsets, tracking: link != nil)
                    }
                    if species.echolocation != nil {
                        GuideCard(title: "Echolocation Calls") { echolocationContent }
                            .guideSection(.echolocation, offsets: $sectionOffsets, tracking: link != nil)
                    }
                    if let c = species.conservation, c.iucnStatus != nil || c.localStatus != nil {
                        GuideCard(title: "Conservation Status", accessory: AnyView(conservationInfoButton)) { conservationContent }
                            .guideSection(.conservation, offsets: $sectionOffsets, tracking: link != nil)
                    }
                    if species.habits != nil {
                        GuideCard(title: "Habits") { habitsContent }
                            .guideSection(.habits, offsets: $sectionOffsets, tracking: link != nil)
                    }
                    GuideCard(title: "Regions") { regionsContent }
                        .guideSection(.regions, offsets: $sectionOffsets, tracking: link != nil)
                }
                // Top inset comes from the first card's own gap instead, or the
                // header would sit 32 below the hero photo rather than 16.
                .padding([.horizontal, .bottom], 16)
                // The cards read as a column on iPad; the hero photo above them
                // does not, and deliberately — it is the one full-bleed thing on
                // the page and it runs under the navigation bar.
                .modifier(ReadingColumn(enabled: contentWidth == nil))

                // The end-of-page anchor. Untracked, deliberately: unlike
                // `top`, its position is never compared against the scroll
                // offset — "am I at the end" is a question the scroll geometry
                // answers directly — so it needs an identity to scroll to and
                // nothing else.
                Color.clear
                    .frame(height: 0)
                    .guideSection(.bottom, offsets: $sectionOffsets,
                                  tracking: false, topGap: 0)
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
                //
                // **`containerRelativeFrame` is wrong in a comparison pane, and
                // `contentWidth` is why the caller measures.** "Container" there
                // resolves past the pane to the navigation container — the whole
                // window — so on an iPad side-by-side both pages laid themselves
                // out full-window-wide and centred, hanging off both edges of
                // their half. A measured width is the pane, whatever the pane
                // turns out to be.
                .modifier(PageContentWidth(explicit: contentWidth))
            }
            .coordinateSpace(.named(guidePageSpace))
        }
        // One observer for the whole page, and it writes no state unless the
        // section actually changed — the per-card measurements above are static,
        // so nothing here churns while a finger is moving.
        .onScrollGeometryChange(for: ScrollProbe.self) { geometry in
            ScrollProbe(
                line: geometry.contentOffset.y + geometry.contentInsets.top,
                // `>=` rather than `==`: rubber-banding takes this past the end
                // and back, and 2pt of slack absorbs the fractional offsets a
                // deceleration settles on.
                atEnd: geometry.visibleRect.maxY >= geometry.contentSize.height - 2
            )
        } action: { _, probe in
            report(probe)
        }
        // Directly on the scroll view, not on an ancestor. A programmatic scroll
        // reports `.animating`, never `.interacting`, so the pane that is merely
        // following can't promote itself to leading and reverse the pair.
        .onScrollPhaseChange { _, phase in
            if phase == .interacting || phase == .decelerating { link?.onUserScroll() }
        }
        .onChange(of: link?.scrollTo) { _, target in
            guard let target = target ?? nil else { return }
            // Slower than the finger that caused it: a snap that keeps pace with
            // scrolling reads as a twitch rather than a page keeping up.
            withAnimation(.easeInOut(duration: 0.35)) {
                // The end anchor is aligned to the BOTTOM of the viewport —
                // scrolling a zero-height view at the end of the content to the
                // top edge would ask for a screenful of nothing below it, which
                // the scroll view can't give and so mostly wouldn't move.
                proxy.scrollTo(target, anchor: target == .bottom ? .bottom : .top)
            }
        }
        .background(Color(.systemGroupedBackground))
        }
    }

    /// How far below the top of the viewport a section counts as reached.
    ///
    /// Not a fudge factor — it is what keeps the two pages feeling like one.
    /// Waiting for a card's top edge to actually cross the top of the screen
    /// meant the other pane only moved once you had already scrolled past the
    /// heading you were reading, so the pair spent most of a scroll visibly out
    /// of step and caught up in a lurch. Counting a section as reached while it
    /// is still ~50pt down means the follower is moving as the heading arrives,
    /// which is what reads as the two pages travelling together (Niall,
    /// 2026-08-26).
    private static let sectionReachedLookahead: CGFloat = 50

    /// Where this pane has got to: the end of the page if it is there,
    /// otherwise the last section whose top has come within
    /// `sectionReachedLookahead` of the top of the viewport. Reported upward
    /// only when it changes.
    ///
    /// The end wins over any section, and has to. The two pages are different
    /// lengths, so the follower running out of content before the leader does
    /// is the normal case — without this, a leader scrolled to the very bottom
    /// reports whatever heading happens to be near its top edge, and the
    /// follower sits at that heading with the rest of its page unread below.
    private func report(_ probe: ScrollProbe) {
        guard let link else { return }
        let reached: GuideSection?
        if probe.atEnd {
            reached = .bottom
        } else {
            reached = sectionOffsets
                .filter { $0.value <= probe.line + Self.sectionReachedLookahead }
                .max { $0.value < $1.value }?
                .key
        }
        guard let reached, reached != reportedSection else { return }
        reportedSection = reached
        link.onTopSection(reached)
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
        Group {
            if isEmbedded {
                heroImage(photo, height: Self.embeddedHeroHeight)
            } else {
                // Bleeds the photo up under the (now-transparent, see `page`)
                // navigation bar instead of stopping short of it — only on the
                // page's own screen: the embedded comparison pane has no bar
                // to bleed under, and sits below its own title strip instead.
                heroImage(photo, height: Self.pageHeroHeight)
                    .ignoresSafeArea(edges: .top)
                    // Whether the bar is on the photo — a BOOL, not the photo's
                    // edge (Niall, 2026-09-02: the page scrolled at about
                    // 30fps). `onGeometryChange` calls its action only when the
                    // mapped value changes, so measuring a `CGFloat` here wrote
                    // new state on every frame of every scroll, and every one of
                    // those re-evaluated this whole page — the hero image, the
                    // glass cards, the quick-facts grid and the distribution
                    // map with it. Mapped to the answer instead, it writes twice
                    // in a scroll: once when the photo leaves the bar, once when
                    // it comes back.
                    //
                    // 100pt is a status bar plus a navigation bar with a little
                    // to spare.
                    .onGeometryChange(for: Bool.self) {
                        $0.frame(in: .global).maxY > 100
                    } action: { barContentIsOnPhoto = $0 }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            creditDisclosureButton(photo)
        }
    }

    /// Deeper than the 260 this used to be, because the photo now starts at the
    /// top of the window rather than below the status bar: the top ~60 of it
    /// sits behind the transparent navigation bar, so the extra depth is what
    /// keeps the *visible* photo the size it was and then some. It crops the
    /// source further — accepted (Niall, 2026-09-01), the aim being something
    /// near square on a phone.
    private static let pageHeroHeight: CGFloat = 380
    /// The comparison pane keeps the original depth. It sits below its own
    /// title strip with nothing to bleed under, so it loses no height to a bar,
    /// and there are two of these side by side.
    private static let embeddedHeroHeight: CGFloat = 260

    private func heroImage(_ photo: SpeciesPhoto, height: CGFloat) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                CachedSpeciesImage(url: photo.url, size: .hero) {
                    Color(.systemGray5)
                }
            }
            .clipped()
    }

    private func creditDisclosureButton(_ photo: SpeciesPhoto) -> some View {
        Button {
            showPhotoCredit = true
        } label: {
            Image(systemName: "info.circle.fill")
                .font(.title)
                .foregroundStyle(.white, Color.black.opacity(0.55))
                .symbolRenderingMode(.palette)
        }
        .padding(10)
        .accessibilityLabel("Photo credit")
        .accessibilityHint(photo.creditText)
        .popover(isPresented: $showPhotoCredit) {
            Text(photo.creditText)
                .font(.footnote)
                .padding(12)
                .presentationCompactAdaptation(.popover)
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
                    if let group = species.group {
                        Text(group)
                            .font(.headline)
                            .foregroundStyle(.orange)
                    }
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

    /// Share of the quick-facts row the stats column takes; the size card gets
    /// the rest.
    ///
    /// **40/60, up from a third/two-thirds** (Niall, 2026-09-02). A third of a
    /// 393pt phone is about 117pt, and inside it these tiles carry a 24pt icon,
    /// 10pt of padding either side and a label like "Call Duration" or "Peak
    /// Freq" — so on anything narrower than a Pro Max the labels and values were
    /// clipping. The size card loses width it can spare: `SizeComparisonCard`
    /// scales its glyphs to whatever space it is given, while a stat tile has a
    /// floor set by its own text.
    private static let quickFactsStatsFraction: CGFloat = 0.4

    /// The stats column's fixed width, minus its share of the inter-column
    /// spacing; the size card keeps its `maxWidth: .infinity` and fills
    /// whatever's left. Nil until `quickFactsRowWidth` has been measured at
    /// least once, so the column uses natural sizing rather than collapsing to
    /// zero width on the first layout pass.
    private var leftQuickFactsColumnWidth: CGFloat? {
        guard quickFactsRowWidth > 0 else { return nil }
        let spacing: CGFloat = 10
        return (quickFactsRowWidth - spacing) * Self.quickFactsStatsFraction
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

    // MARK: Sources

    /// Nothing to open the sheet for when the entry credits nobody and cites
    /// nothing — sparse guide entries just lose the button, in keeping with
    /// every other section on this page.
    private var hasSources: Bool {
        species.creator != nil || (species.references?.isEmpty == false)
    }

    private var sourcesButton: some View {
        Button {
            showSources = true
        } label: {
            Image(systemName: "scroll")
        }
        .accessibilityLabel("Contributors and references")
    }

    // MARK: Regions

    @ViewBuilder private var regionsContent: some View {
        ForEach(store.guide.regions.filter { species.regions.contains($0.id) }) { region in
            Label(region.name, systemImage: "globe.europe.africa")
                .labelStyle(.batAccentIcon)
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
                        // A `Label`'s glyph takes the accent colour, and the
                        // AccentColor asset in this project has no colour set —
                        // so it resolved to the system BLUE, which on a page of
                        // orange read as something bleeding in from the map card
                        // above (Niall, 2026-09-02). Same trap as the About
                        // sheet's feature list. Anywhere a `Label` appears in
                        // this app, say the colour.
                        .labelStyle(.batAccentIcon)
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
        // The app's tile material, not a grouped-list fill — the same glass the
        // species cards, rows and sessions are drawn on (Niall, 2026-09-02).
        .glassTile()
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
        // Tighter radius than a full-width card: these are small tiles nested
        // inside one, and 18 on a 90pt tile reads as a lozenge.
        .glassTile(cornerRadius: 12)
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
        .glassTile(cornerRadius: 14)
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
        .glassTile(cornerRadius: 14)
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

/// Everything behind the page's scroll button: who wrote the entry, then what
/// they cited. Contributors lead because the References card they used to sit
/// under is gone — the page itself now shows only species content, and
/// provenance is one tap away rather than a block at the foot of the scroll.
private struct SourcesSheet: View {
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
                if let references = species.references, !references.isEmpty {
                    Section("References") {
                        ForEach(Array(references.enumerated()), id: \.offset) { _, citation in
                            Text(citation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .pageBackground()
            .navigationTitle("Sources")
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


extension View {
    /// Tags one of the species page's cards — see `GuideSection`.
    func guideSection(_ section: GuideSection,
                      offsets: Binding<[GuideSection: CGFloat]>,
                      tracking: Bool,
                      topGap: CGFloat = guideSectionTopGap) -> some View {
        modifier(GuideSectionMarker(section: section, offsets: offsets,
                                    isTracking: tracking, topGap: topGap))
    }
}
