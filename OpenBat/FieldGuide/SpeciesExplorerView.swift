//
//  SpeciesExplorerView.swift
//  OpenBat
//
//  The Species section — a field-guide explorer. A prominent fuzzy-search bar
//  sits at the top (common + scientific names); below it, an interactive globe
//  (MapKit satellite imagery with realistic elevation renders as a true 3D
//  globe when zoomed out) shows one pin per species region. Tapping a pin
//  pushes the region's species list; each species pushes a (placeholder)
//  detail page.
//

import SwiftUI
import MapKit

/// Both region pins and species rows push through this single enum so the
/// explorer only ever registers one `.navigationDestination(for:)` — mixing
/// that with a separate `.navigationDestination(item:)` for regions caused
/// NavigationStack to desync (pushed view showed the previous destination's
/// content until a back-then-forward "caught it up").
enum SpeciesGuideDestination: Hashable {
    case region(GuideRegion)
    case species(GuideSpecies)
    /// Species whose range covers the user's location — see
    /// `SpeciesExplorerView.nearbySpecies` and the globe pill. Carries no
    /// payload: the destination handler resolves the list itself from
    /// `presenceStore` + `userCoordinate` at push time, same as the pill
    /// that offers it.
    case nearby
}

struct SpeciesExplorerView: View {
    let store: SpeciesGuideStore
    let presenceStore: SpeciesPresenceStore
    /// Where to pre-pan the globe — the user's current location, if known.
    /// Falls back to a fixed mid-Atlantic center when nil (no fix yet / denied).
    let userCoordinate: CLLocationCoordinate2D?

    @State private var query = ""
    /// Measured height of the search results, so the dropdown can be as tall as
    /// its rows rather than as tall as the space offered — see `searchResults`.
    @State private var contentHeight: CGFloat = 0
    @State private var showSources = false
    @State private var showGuideInfo = false
    @FocusState private var searchFieldFocused: Bool
    /// Start far enough out that the realistic-elevation imagery style renders
    /// the whole planet as a spinnable globe — just pre-panned toward the user
    /// rather than a fixed point, so the globe opens already facing home.
    @State private var camera: MapCameraPosition
    /// Guards the one-time opening pan/fade in `globe`'s `.onAppear` — without
    /// this it re-fires every time the globe reappears (e.g. popping back
    /// from a region/species page), snapping the camera back to Null Island
    /// instead of staying wherever the user last panned it to.
    @State private var hasNudgedCameraOnce = false
    /// Globe starts invisible and fades in once imagery has had a moment to
    /// load, instead of popping in already fully opaque.
    @State private var globeOpacity: Double = 0
    /// The opening swoop's repeating Timer — retained so `.onDisappear` can
    /// invalidate it if the user navigates away mid-swoop. Otherwise it keeps
    /// firing and mutating `camera` on an off-screen view for the rest of its
    /// ~`swoopDuration` regardless of navigation.
    @State private var swoopTimer: Timer?

    /// Ceiling on the results dropdown. Roughly four rows — enough that the list
    /// visibly shrinks as the query narrows, while leaving the globe readable
    /// behind it and staying clear of the keyboard.
    private static let maxResultsHeight: CGFloat = 360

    private static let fallbackCenter = CLLocationCoordinate2D(latitude: 30, longitude: -10)
    /// Opening camera position — Null Island (0, 0), out in the Atlantic —
    /// the globe swoops from here to `userCoordinate` on first appearance.
    private static let openingCenter = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    /// Total wall-clock time for the opening swoop. Previously requested via
    /// `withAnimation(duration: 4.0)`, which MapKit silently shortened to
    /// ~1.5s in practice — this is the real, honored duration for the
    /// hand-stepped animation in `animateSwoop`.
    private static let swoopDuration = 2.0
    private static let swoopStepInterval = 1.0 / 60.0

    init(store: SpeciesGuideStore, presenceStore: SpeciesPresenceStore, userCoordinate: CLLocationCoordinate2D? = nil) {
        self.store = store
        self.presenceStore = presenceStore
        self.userCoordinate = userCoordinate
        _camera = State(initialValue: .camera(
            MapCamera(centerCoordinate: Self.openingCenter, distance: 60_000_000)
        ))
    }

    /// Species whose range covers `userCoordinate` — what the globe pill
    /// offers ("Tap here to see bats near you") and what `.nearby` pushes.
    /// Empty with no location fix yet (`userCoordinate` is nil until then;
    /// see that property's doc comment) or if nothing in the guide has a
    /// resolvable presence-grid code for this spot — either way the pill
    /// falls back to its generic wording rather than offering a dead tap.
    ///
    /// Joined the same way `GBIFDistributionCard` does, via
    /// `GuideSpecies.presenceCode` — whichever classifier names the species,
    /// falling back to the entry's own slug — since the grid is keyed by code
    /// and the guide only knows scientific names (see that property's own doc
    /// comment).
    private var nearbySpecies: [GuideSpecies] {
        guard let coordinate = userCoordinate else { return [] }
        return store.guide.species.filter { species in
            if case .present = presenceStore.presence(forCode: species.presenceCode,
                                                     at: coordinate) { return true }
            return false
        }
    }

    private var results: [GuideSpecies] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return store.guide.species
            .compactMap { s in s.searchScore(for: trimmed).map { (s, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var body: some View {
        // The globe fills the screen and the search field floats ON it as a glass
        // capsule. It used to be a row in a VStack above the globe, which gave it
        // a black strip of its own — a bare text field on black, pushing the globe
        // down the screen for no gain (Niall, 2026-08-16).
        //
        // **One hierarchy, always — the search results hang UNDER the pill rather
        // than replacing the screen.** This was a `Group` with an `if` on the
        // query: empty showed the globe with the pill floating on it, non-empty
        // showed a completely different stacked layout with a full-screen List.
        // That swap rebuilt the `TextField` inside a different branch, so it lost
        // focus and **the keyboard closed the instant the first character was
        // typed** — and the whole screen was replaced by a long list before the
        // user had typed enough to narrow anything. Keeping the globe and the
        // pill in the same place in the tree, and putting the matches in a
        // dropdown attached below the pill, means the field is never rebuilt: the
        // keyboard stays up and the list narrows as you type (Niall, 2026-08-17).
        globe
            // Tapping the globe dismisses the keyboard. It no longer competes with
            // taps on result rows: those are in an overlay ABOVE this, so they are
            // hit-tested first and never reach the globe. (The old comment here
            // warned that the same gesture ate NavigationLink taps when the
            // results were a List in the same branch — that arrangement is gone.)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { searchFieldFocused = false })
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    searchPill
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        searchResults
                            // Grows downward out of the pill rather than fading in
                            // place, so it reads as attached to the field.
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .animation(.snappy(duration: 0.22), value: results.count)
            }
        .navigationDestination(for: SpeciesGuideDestination.self) { destination in
            switch destination {
            case .region(let region):
                SpeciesCollectionView(
                    title: region.name,
                    species: store.guide.species(in: region),
                    countSuffix: "in region",
                    emptyStateDescription: markdownText("This region has no entries in the guide yet! As a community-sourced guide, contributions are always welcome — [get started here](\(fieldGuideRepoURL)).")
                )
            case .species(let species):
                SpeciesDetailView(species: species, store: store, presenceStore: presenceStore)
            case .nearby:
                SpeciesCollectionView(
                    title: "Bats Near You",
                    species: nearbySpecies,
                    countSuffix: "near you",
                    emptyStateDescription: markdownText("We don't have range data covering your exact location yet — try exploring a region on the globe instead, or [contribute range data here](\(fieldGuideRepoURL)).")
                )
            }
        }
        // The one screen that does NOT get the app's flat black bar: the globe
        // is bright, full-bleed imagery, and cutting it off with a solid strip
        // wastes the top of the screen. The imagery runs up under the bar
        // instead (`ignoresSafeArea` on `globe`).
        //
        // The old comment here claimed `.toolbarBackground(Color.black, for:)`
        // was what pinned this bar black. It wasn't: that call is deprecated
        // and inert on iOS 26, and the flat black comes from the UIKit
        // appearance proxy in `OpenBatApp.configureNavigationBarAppearance`.
        // See `clearNavigationBarBackground()`.
        .clearNavigationBarBackground()
        .flatTopScrollEdge()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showGuideInfo = true } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("About this guide")
                .popover(isPresented: $showGuideInfo) {
                    guideInfoPopover
                        .presentationCompactAdaptation(.popover)
                }
            }
        }
        // At the root, not inside `globeFooter` where it used to live: the footer
        // only exists on the globe branch, so a sheet attached to it disappeared
        // along with its presenter the moment a search filtered the globe away.
        // The button that opens it is now in the toolbar, which is always there.
        .sheet(isPresented: $showSources) { sourcesSheet }
    }

    /// Which guide data is loaded, where it came from, and the credits.
    ///
    /// This was a footer card floating at the bottom of the globe, and it was
    /// colliding with the bottom tab bar — `ignoresSafeArea(edges: .bottom)` on the
    /// globe put its 24pt bottom padding below the bar rather than above it, so the
    /// version line sat under the chrome. It is reference material read once, which
    /// makes a toolbar button the right home for it rather than a permanent card
    /// over the map (Niall, 2026-08-16).
    private var guideInfoPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Field guide data")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Version").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text("v\(store.guide.dataVersion)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                    if store.isRefreshing { ProgressView().controlSize(.mini) }
                }
                HStack(spacing: 6) {
                    Text("Source").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(store.source.rawValue).font(.caption.weight(.semibold))
                }
                if let updated = store.guide.updatedDate {
                    HStack(spacing: 6) {
                        Text("Updated").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(Self.updatedAtFormatter.string(from: updated))
                            .font(.caption.weight(.semibold))
                    }
                }
            }

            Text("The guide is community-maintained and updates itself in the background — species, photos and range maps arrive without an app update.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Credits the field guide's data (GBIF/Wikipedia) and the classifier
            // models — including BatDetect2's CC BY-NC non-commercial licence —
            // from within the guide itself, so it's reachable without going to the
            // app-info sheet.
            Button("Sources & licences") {
                showGuideInfo = false
                // Deferred, and it does not work without this: presenting a sheet
                // while the popover it was tapped in is still dismissing gets
                // silently DROPPED by SwiftUI — the button appeared completely
                // dead. Same failure and the same fix as `PlaybackListView`'s
                // import-error alert (now `SessionsView.reportImport`), which was
                // being swallowed by the file importer's own dismissal.
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    showSources = true
                }
            }
            .font(.caption.weight(.semibold))
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    // MARK: Search

    /// A Liquid Glass capsule, so it reads as a control floating over the globe
    /// rather than a field sunk into a black band. `interactive: true` for the
    /// press response and — the part that is not cosmetic — so the whole capsule
    /// is the tap target rather than just the glyph and the text baseline; see
    /// `liquidGlass`'s own note.
    private var searchPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search species or scientific name", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searchFieldFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .liquidGlass(interactive: true, in: Capsule())
        // The glass shape is the tap target, but a TextField only takes focus from
        // a tap that lands on the field itself — so the padding around it would be
        // dead. This hands the whole capsule to the field.
        .onTapGesture { searchFieldFocused = true }
    }

    /// The matches, in a card hanging below the search pill.
    ///
    /// A `ScrollView`/`LazyVStack` rather than a `List`, for two reasons that
    /// both matter here: a `List` insists on filling the space offered to it, so
    /// as a dropdown it would draw a full-height slab with three rows at the top
    /// and a lot of empty below; and it brings its own background, which is what
    /// made the old full-screen version need a solid black strip behind the pill
    /// in the first place. Sized to its content and capped, this shrinks as the
    /// query narrows, which is the whole feedback the user is after.
    @ViewBuilder private var searchResults: some View {
        VStack(spacing: 0) {
            if results.isEmpty {
                // A row, not a `ContentUnavailableView`: that type is built to
                // own a screen, and in a dropdown it renders as a large centred
                // island of empty space.
                Text("No species match \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, species in
                            if index > 0 {
                                Divider().padding(.leading, 14)
                            }
                            NavigationLink(value: SpeciesGuideDestination.species(species)) {
                                GuideSpeciesRow(species: species)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    // So the whole row width is tappable, not
                                    // just the text inside it.
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // Measured, and the height below is driven from it. A
                    // `ScrollView` takes all the height it is offered rather than
                    // sizing to its content, so without this the card would be a
                    // full-height slab with three rows at the top of it. The
                    // `.fixedSize` trick sometimes coaxes an ideal height out of
                    // it and sometimes does not; measuring is not a guess.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        contentHeight = $0
                    }
                }
                // Sized to the rows, capped so the card never reaches up-rising
                // keyboard — it hangs from the top of the screen. `max(1,)` keeps
                // the frame valid on the first pass, before anything is measured.
                .frame(height: min(max(contentHeight, 1), Self.maxResultsHeight))
                // Keyboard stays up while scrolling the matches: the point of
                // this list is to narrow it further, and dismissing the keyboard
                // on the first scroll makes correcting a typo a two-tap job.
                .scrollDismissesKeyboard(.never)
                // No rubber-banding when the matches already fit.
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    // MARK: Globe

    /// Stable per-region tint, cycled by index rather than hashed from `id` so
    /// colors stay visually distinct between neighbors regardless of slug text.
    private static let regionPalette: [Color] = [.orange, .teal, .purple, .mint, .pink, .indigo, .yellow, .cyan]

    private func regionColor(_ region: GuideRegion) -> Color {
        let index = store.guide.regions.firstIndex(of: region) ?? 0
        return Self.regionPalette[index % Self.regionPalette.count]
    }

    private var globe: some View {
        Map(position: $camera) {
            ForEach(store.guide.regions) { region in
                if region.polygons.isEmpty {
                    // No boundary data yet for this region — fall back to a pin.
                    Annotation(region.name, coordinate: region.coordinate) {
                        NavigationLink(value: SpeciesGuideDestination.region(region)) {
                            RegionPin(count: store.guide.species(in: region).count)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    ForEach(Array(region.polygons.enumerated()), id: \.offset) { _, ring in
                        MapPolygon(coordinates: ring)
                            .foregroundStyle(regionColor(region).opacity(0.45))
                            .stroke(regionColor(region), lineWidth: 2)
                    }
                    Annotation(region.name, coordinate: region.coordinate) {
                        NavigationLink(value: SpeciesGuideDestination.region(region)) {
                            RegionLabel(name: region.name, color: regionColor(region),
                                        count: store.guide.species(in: region).count)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let userCoordinate {
                Annotation("Your Location", coordinate: userCoordinate) {
                    UserLocationDot()
                }
            }
        }
        .mapStyle(.imagery(elevation: .realistic))
        // ORDER MATTERS: the imagery bleeds into the bottom safe area, and the
        // footer must not. Overlaying first and ignoring the safe area afterwards
        // (which is what this used to do) expands the overlay along with the map
        // and drops the footer under the tab bar — the bug that sent the version
        // line under the chrome.
        // Top as well as bottom. The top half pairs with
        // `clearNavigationBarBackground()` below: clearing the bar's
        // background only stops the bar painting, so without this the globe
        // would still stop at the safe area and leave a black gap where the
        // bar used to be. The bottom is unchanged — see the ORDER MATTERS
        // note above.
        .ignoresSafeArea(edges: [.top, .bottom])
        .overlay(alignment: .bottom) { globeFooter }
        .opacity(globeOpacity)
        .onAppear {
            guard !hasNudgedCameraOnce else { return }
            hasNudgedCameraOnce = true
            withAnimation(.easeIn(duration: 0.5)) { globeOpacity = 1 }
            // MapKit's realistic-elevation globe doesn't lay out `Annotation`
            // pins on first render — they stay invisible until the camera
            // moves at least once. The opening swoop (Null Island → the
            // user's location) doubles as that first layout-triggering move,
            // so pins show up without the user needing to pan themselves.
            // Guarded to fire only once (not on every return from a pushed
            // region/species page) so the camera otherwise just keeps
            // whatever position the user last panned/tapped it to.
            //
            // Driven by hand rather than a single `withAnimation(duration:)`
            // around one big camera jump — SwiftUI's `Map` doesn't reliably
            // honor a requested duration for large `MapCamera` position
            // changes; it substitutes MapKit's own short internal camera
            // transition instead, so a "4 second" swoop actually completed
            // in ~1.5s. Stepping the camera through many small, close-spaced
            // updates forces MapKit to animate each hop at its own (short)
            // pace back-to-back, which reads as one smooth, slow pan overall.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                animateSwoop(to: userCoordinate ?? Self.fallbackCenter)
            }
        }
        .onDisappear {
            swoopTimer?.invalidate()
            swoopTimer = nil
        }
    }

    /// Steps `camera` from its current position to `destination` over
    /// `Self.swoopDuration`, in small increments so MapKit's per-update
    /// internal animation can't shortcut the overall pace (see `.onAppear`
    /// above).
    private func animateSwoop(to destination: CLLocationCoordinate2D) {
        let steps = Int(Self.swoopDuration / Self.swoopStepInterval)
        let startCenter = Self.openingCenter
        let startDistance = 60_000_000.0
        let endDistance = 40_000_000.0
        var step = 0
        swoopTimer = Timer.scheduledTimer(withTimeInterval: Self.swoopStepInterval, repeats: true) { timer in
            step += 1
            let t = min(Double(step) / Double(steps), 1.0)
            // easeInOut
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let lat = startCenter.latitude + (destination.latitude - startCenter.latitude) * eased
            let lon = startCenter.longitude + (destination.longitude - startCenter.longitude) * eased
            let distance = startDistance + (endDistance - startDistance) * eased
            Task { @MainActor in
                camera = .camera(MapCamera(centerCoordinate: .init(latitude: lat, longitude: lon),
                                            distance: distance))
            }
            if t >= 1.0 { timer.invalidate() }
        }
    }

    private static let updatedAtFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    /// Just the one instruction now — everything else that used to be down here
    /// (version, source, updated date, credits) moved to the toolbar's info
    /// popover, which is also what stopped it colliding with the tab bar. This
    /// stays on the globe because it is not reference material: it tells a
    /// first-time user the map is tappable, which nothing else does.
    ///
    /// Positioned against the safe area rather than the ignored bottom edge, so it
    /// sits above the tab bar instead of under it.
    ///
    /// Tappable and dynamic since 2026-08-17: when `nearbySpecies` has
    /// anything in it, this offers that list directly ("Tap here to see bats
    /// near you") instead of the generic instruction, since a resolved
    /// answer is more useful than a hint to go find one on the globe. Falls
    /// back to the original wording — plain text, not a link — whenever
    /// there's no fix yet or nothing resolves nearby, so nothing here is ever
    /// a tap that goes nowhere.
    @ViewBuilder
    private var globeFooter: some View {
        if !nearbySpecies.isEmpty {
            NavigationLink(value: SpeciesGuideDestination.nearby) {
                Text("Tap here to see bats near you")
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .liquidGlass(in: Capsule())
            }
            .padding(.bottom, 12)
        } else {
            Text("Tap a region to explore its species")
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .liquidGlass(in: Capsule())
                .padding(.bottom, 12)
        }
    }

    private var sourcesSheet: some View {
        NavigationStack {
            ScrollView {
                DataModelSourcesView()
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Sources & Licences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showSources = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Marks `userCoordinate` on the globe — the same small blue dot with a white
/// outline Maps uses for the current-location marker, just static (no live
/// heading/accuracy ring) since this is a one-shot fix, not a tracked position.
private struct UserLocationDot: View {
    var body: some View {
        Circle()
            .fill(Color.blue)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .shadow(radius: 2)
    }
}

/// Bat pin used for regions on the globe — species count badged alongside.
private struct RegionPin: View {
    let count: Int

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(.orange.gradient)
                    .frame(width: 36, height: 36)
                    .shadow(radius: 3)
                Image("batIcon")
                    .resizable().scaledToFit()
                    .foregroundStyle(.white)
                    .padding(7)
                    .frame(width: 36, height: 36)
                Text("\(count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.blue, in: Circle())
                    .offset(x: 6, y: -6)
            }
        }
    }
}

/// Centroid label used on regions drawn as a colored boundary outline (see
/// `SpeciesExplorerView.globe`) — a compact name chip instead of `RegionPin`'s
/// bat-icon pin, since the colored shape already marks the region.
private struct RegionLabel: View {
    let name: String
    let color: Color
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.caption.bold())
            Text("\(count)")
                .font(.caption2.bold())
                .padding(3)
                .background(.white.opacity(0.3), in: Circle())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.gradient, in: Capsule())
        .shadow(radius: 2)
    }
}

/// IUCN Red List category → (short badge text, color). Free text in the data
/// (`SpeciesConservation.iucnStatus`), matched case-insensitively; anything
/// unrecognized (or absent) falls back to a neutral gray "?" rather than
/// hiding the badge, since a wrong-but-visible status is easier to notice and
/// fix in the guide JSON than a silently-missing one.
/// Shared by the species list's row badge and the detail page's header badge —
/// one mapping, so the two can't disagree about what a status means.
enum IUCNStatusStyle {
    /// The badge for a status string, or nil when there isn't one to show.
    ///
    /// Matched by prefix rather than equality, and nil rather than "?", because
    /// the guide is community-edited free text and an exact-match switch was
    /// quietly losing to it. Real values in the shipped guide today include
    /// "Least Concern (global)" and one that continues "…; note that two
    /// isolated US subspecies, Ozark and Virginia big-eared bat, are federally
    /// Endangered in the US" — all correct, none of them equal to "least
    /// concern", so five of nineteen species rendered an unexplained grey "?"
    /// where their status should be.
    ///
    /// An unrecognised or absent status now shows no badge at all. A "?" that
    /// means "this app couldn't parse a sentence" is worse than silence: the
    /// full text is on the Conservation card regardless, so nothing is lost.
    ///
    /// Order matters — the longer names have to be tested before the shorter
    /// ones they contain, or "critically endangered" reads as "endangered" and
    /// "extinct in the wild" as "extinct".
    static func forStatus(_ status: String?) -> (text: String, color: Color)? {
        guard let status else { return nil }
        let s = status.lowercased()
        switch true {
        case s.hasPrefix("critically endangered"): return ("CR", .purple)
        case s.hasPrefix("near threatened"):       return ("NT", .yellow)
        case s.hasPrefix("least concern"):         return ("LC", .green)
        case s.hasPrefix("vulnerable"):            return ("VU", .orange)
        case s.hasPrefix("endangered"):            return ("EN", .red)
        case s.hasPrefix("extinct in the wild"):   return ("EW", .black)
        case s.hasPrefix("extinct"):               return ("EX", .black)
        case s.hasPrefix("data deficient"):        return ("DD", .gray)
        case s.hasPrefix("not evaluated"):         return ("NE", .gray)
        default:                                   return nil
        }
    }
}

/// Species row thumbnail — the guide entry's own `imageURL` when a
/// contributor has set one, else a live fallback lookup against Wikipedia's
/// open media (same fetch pattern the Birding_Data companion app uses for its
/// species detail pages, see WikipediaSpeciesImageService). Falls back to a
/// themed silhouette icon (tinted per-family) while loading, on a species
/// with neither, or if the Wikipedia request fails.
private struct GuideSpeciesThumbnail: View {
    let species: GuideSpecies
    static let size: CGFloat = 50

    @State private var imageURL: URL?

    private var tint: Color {
        // Deterministic (not random) so the same family always gets the same
        // color across launches and across rows.
        let hash = abs((species.family ?? species.order ?? "Chiroptera").hashValue)
        let palette: [Color] = [.orange, .teal, .indigo, .pink, .brown, .mint]
        return palette[hash % palette.count]
    }

    var body: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: species.scientificName) {
            // Contributor-set URL first — see its doc comment on `GuideSpecies`
            // for why that's preferred over the live Wikipedia lookup below,
            // which stays only as a fallback for entries that haven't set one.
            if let urlString = species.imageURL, let url = URL(string: urlString) {
                imageURL = url
            } else {
                imageURL = await WikipediaSpeciesImageService.fetchImageURL(for: species.scientificName)
            }
        }
    }

    private var placeholder: some View {
        Image("batIcon")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .padding(10)
            .frame(width: Self.size, height: Self.size)
            .background(tint.gradient)
    }
}

/// Shared species row (search results + region lists) — mirrors the
/// thumbnail + headline/subtitle/caption + trailing-badge layout used by the
/// life-list/checklist rows in the Birding_Data companion app, adapted to
/// what the field guide actually has on hand (no per-species photos, but
/// echolocation stats and an IUCN conservation status).
struct GuideSpeciesRow: View {
    let species: GuideSpecies

    private var peakFreqCaption: String? {
        guard let range = species.echolocation?.peakFreqHzRange else { return nil }
        let lo = range.min / 1000, hi = range.max / 1000
        return "Peak freq: \(String(format: "%.0f", lo))–\(String(format: "%.0f", hi)) kHz"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            GuideSpeciesThumbnail(species: species)

            VStack(alignment: .leading, spacing: 4) {
                Text(species.commonName)
                    .font(.headline)
                Text(species.scientificName)
                    .font(.subheadline.italic())
                    .foregroundStyle(.secondary)
                if let peakFreqCaption {
                    Text(peakFreqCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let iucn = species.conservation?.iucnStatus,
               let badge = IUCNStatusStyle.forStatus(iucn) {
                Text(badge.text)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(badge.color.gradient, in: Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Region / nearby page

/// Repo the community-editable guide JSON (SpeciesGuideData.json) lives in —
/// same repo `SpeciesGuideStore.remoteURL` fetches from. File-scope rather
/// than nested in `RegionSpeciesView` since both its `.region` and `.nearby`
/// empty-state messages, built at the call sites below, point contributors
/// there.
private let fieldGuideRepoURL = "https://github.com/NiallxD/OpenBat-FieldGuide"

/// Builds a `Text` from markdown, for the contribution links below.
///
/// **`Text("[label](\(url))")` does not produce a tappable link**, which is how
/// both empty states shipped. A string literal passed to `Text` is a
/// `LocalizedStringKey`, and its interpolations become substitution
/// placeholders in a format string that markdown is parsed from *before* the
/// values are put back — so the parser sees a link destination that is a
/// placeholder rather than a URL, fails to form a link, and the whole
/// `[label](…)` renders as literal characters. Nothing is tappable and the raw
/// brackets are visible.
///
/// Parsing an `AttributedString` sidesteps the format string entirely: the URL
/// is already in the string by the time markdown is applied. Falls back to the
/// unparsed text rather than trapping — a broken link in an empty state is not
/// worth a crash, and these strings are literals a compile would catch anyway.
private func markdownText(_ markdown: String) -> Text {
    Text((try? AttributedString(markdown: markdown)) ?? AttributedString(markdown))
}

// Species detail page lives in SpeciesDetailView.swift.
