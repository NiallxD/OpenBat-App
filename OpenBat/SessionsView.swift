//
//  SessionsView.swift
//  OpenBat
//
//  The Sessions area, split two ways:
//    • SessionsView      — field outings (RecordingSession) grouped by day, plus a
//                          trailing section for recordings that belong to no
//                          session (imports, and pre-sessions leftovers)
//    • SessionDetailView — one outing: species pins on a map + its IDs
//
//  Both share PassRow / PassDetailView so a field ID can still be traced back to
//  the per-pulse spectrogram evidence it was built from.
//
//  This is also where playback lives now. There used to be a separate Playback
//  tab listing every recording grouped by session — the same recordings, in the
//  same buckets, one tab over — so a recording had two destinations depending on
//  which list you found it in: the player, or a static detail page. Tapping a
//  recording anywhere now opens the player (WavPlayerView), and the per-pulse IDs
//  are a sheet over it (RecordingPulsesSheet). The WAV importer came here too,
//  since an imported file lands outside every session.
//

import SwiftUI
import MapKit
import UniformTypeIdentifiers

/// Cached formatters — `DateFormatter()` init is expensive (locale/calendar setup),
/// and these are read once per row per list body evaluation.
private enum SessionDateFormatters {
    static let timeShort: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()
    static let dateMedium: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; return f }()
    static let timeMedium: DateFormatter = { let f = DateFormatter(); f.timeStyle = .medium; return f }()
    static let dateTimeMedium: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium; return f
    }()
    /// "2 Sep 2026". A template rather than a literal format so the field order
    /// follows the user's locale — the ask is dd MMM yyyy, and that is what a
    /// UK or US locale both resolve this to.
    static let dayMonthYear: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return f
    }()
}

// MARK: - Sessions list

struct SessionsView: View {
    @Bindable var store: ClassificationStore
    let settings: AutoIDSettings
    let consent: ConsentStore
    /// Only used to hand the player its calibration curve — this screen shows no
    /// spectrogram of its own.
    let micCalSettings: MicCalibrationSettings
    /// Likewise passed straight through to the player, which shows the guide's
    /// echolocation figures beside the ones it measures.
    let speciesGuide: SpeciesGuideStore
    @State private var showImporter = false
    @State private var importError: String?
    @State private var isImporting = false

    // MARK: Multi-select
    //
    // One list holds two kinds of row — sessions grouped by day, and the
    // recordings belonging to no session — so a selection has to say WHICH,
    // not just which id. Both are UUID-identified and a raw `Set<UUID>` would
    // work by luck; naming the kind means a delete can never reach for the
    // wrong collection.
    private enum Selected: Hashable {
        case session(UUID)
        case recording(UUID)
    }
    @State private var selection = Set<Selected>()
    /// Selection is the app's own, not the List's. `EditMode` puts a tick in a
    /// column of its own down the leading edge, which shoves every row's content
    /// across — and these rows lead with a picture, so the whole list slid
    /// sideways on entering selection (Niall, 2026-09-02). Ticking in place of
    /// the row's chevron says the same thing and moves nothing.
    @State private var isSelecting = false
    /// What a confirmed bulk delete will remove. Held rather than acted on
    /// immediately because it is irreversible in both directions: a session
    /// takes every ID and thumbnail logged in it, a recording takes its WAV.
    @State private var bulkPendingDelete: BulkDelete?
    private struct BulkDelete {
        var sessions: [RecordingSession]
        var recordings: [Recording]
        var isEmpty: Bool { sessions.isEmpty && recordings.isEmpty }
    }

    /// Recordings belonging to no session, newest first. A computed property
    /// so the toolbar can resolve a selection without the list body having to
    /// hand it down; the body still evaluates it once into a local, which is
    /// what the note in `sessionsContent` is about.
    private var looseRecordingsSorted: [Recording] {
        store.listeningRecordings.sorted { $0.date > $1.date }
    }
    var body: some View {
        sessionsContent
            .pageBackground()
            // Delete takes the leading slot while selecting, and the sun clock
            // lives there the rest of the time — see `hidesSunClock`.
            .hidesSunClock(isSelecting)
        // The count lives in the title while selecting. It was a `.bottomBar`
        // toolbar item, which the floating tab bar sits on top of — the text
        // was there the whole time, behind the bar.
        .navigationTitle(isSelecting ? selectionCountTitle : "Sessions")
        .navigationBarTitleDisplayMode(.inline)
        // No painted header (Niall, 2026-09-02). The app-wide appearance proxy
        // gives every bar an opaque background, which on a page whose content
        // starts right under it reads as a header strip the page doesn't need.
        // Cleared here, with the scroll-edge scrim dropped alongside it — one
        // without the other just swaps a painted bar for a glass one.
        .clearNavigationBarBackground()
        .flatTopScrollEdge()
        .toolbar { toolbarContent }
        // AIFF and the generic `.audio` type are honest options because everything
        // that isn't already the app's own WAV shape is converted on the way in
        // (`RecordingImporter.normalizeIfNeeded`). Before that they were accepted
        // and then read as noise.
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.wav, .aiff, .audio],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importAll(urls)
            case .failure(let error): importError = error.localizedDescription
            }
        }
        .alert("Import failed", isPresented: .init(get: { importError != nil },
                                                  set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        // One alert for every way a delete can start — the toolbar's Delete and
        // a row swipe alike.
        //
        // It is an alert rather than a confirmationDialog for two reasons. The
        // dialog anchors to its source, so with Delete moved to the top-left it
        // came up as a popover hanging off the toolbar; and a swipe-delete's
        // dialog left the swiped row half-open behind it, so cancelling gave
        // back a row still stuck in its delete state.
        .alert(deleteAlertTitle,
               isPresented: Binding(
                   get: { !(bulkPendingDelete?.isEmpty ?? true) },
                   set: { if !$0 { bulkPendingDelete = nil } }
               )) {
            Button("Delete", role: .destructive) {
                guard let pending = bulkPendingDelete else { return }
                pending.sessions.forEach(store.deleteSession)
                // The batch overload, not one call per recording: deleting
                // singly rewrites the store's index each time.
                if !pending.recordings.isEmpty { store.delete(pending.recordings) }
                bulkPendingDelete = nil
                withAnimation {
                    selection.removeAll()
                    isSelecting = false
                }
            }
            Button("Cancel", role: .cancel) { bulkPendingDelete = nil }
        } message: {
            Text(bulkPendingDelete.map(bulkDeleteMessage) ?? "")
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        // Everything that isn't the list itself lives behind one trailing menu:
        // Add Recording (the WAV importer) and Select. Two bare toolbar icons
        // used to sit there instead, which meant the import button had to be
        // hidden mid-selection to stop a new row landing in a list being chosen
        // from; the menu is simply gone in selection mode.
        //
        // Import an external WAV is the only way to audition a known bat call
        // through the listening modes without a live bat, since WavPlayerView
        // drives the real DSP from the file at its native rate. See
        // RecordingImporter. Came here when the Playback tab was folded in.
        if !isSelecting {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Add Recording", systemImage: "plus")
                    }
                    .disabled(isImporting)
                    Button {
                        withAnimation { isSelecting = true }
                    } label: {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                    .disabled(store.sessions.isEmpty && looseRecordingsSorted.isEmpty)
                } label: {
                    if isImporting {
                        ProgressView()
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .accessibilityLabel("Sessions menu")
            }
        } else {
            // Delete sits leading, opposite Done, so the destructive tap is
            // nowhere near the one that leaves selection.
            ToolbarItem(placement: .topBarLeading) {
                // Tinted rather than `role: .destructive`: the role fills the
                // toolbar's glass button solid red, which reads as an alert
                // sitting in the bar. Red lettering on the same glass as every
                // other item says the same thing at the weight it deserves —
                // the confirmation alert is where the real red belongs.
                Button {
                    bulkPendingDelete = resolveSelection()
                } label: {
                    Text("Delete")
                }
                .tint(.red)
                .disabled(selection.isEmpty)
            }
            // Not `EditButton()`: leaving selection has to drop the selection
            // with it, or the next Select starts with rows already ticked from
            // last time and a Delete is one tap from removing them.
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    withAnimation {
                        isSelecting = false
                        selection.removeAll()
                    }
                }
            }
        }
        // No unclassified-recordings filter here (Niall, 2026-08-16). This screen
        // is a list of outings, not of classifications; the filter belongs where
        // the recordings are, which is inside a session — SessionDetailView carries
        // it. Nothing on this screen reads `display.showNoID` at all now.

    }

    // MARK: Selection

    private func toggle(_ item: Selected) {
        if selection.contains(item) { selection.remove(item) } else { selection.insert(item) }
    }

    /// Turns the selection back into the objects to delete. Anything that has
    /// gone since it was selected (a sync, an upload sweep) simply isn't
    /// found, rather than being deleted by index into a list that has moved.
    private func resolveSelection() -> BulkDelete {
        var sessionIDs = Set<UUID>()
        var recordingIDs = Set<UUID>()
        for item in selection {
            switch item {
            case .session(let id): sessionIDs.insert(id)
            case .recording(let id): recordingIDs.insert(id)
            }
        }
        return BulkDelete(sessions: store.sessions.filter { sessionIDs.contains($0.id) },
                          recordings: looseRecordingsSorted.filter { recordingIDs.contains($0.id) })
    }

    /// Spelled out per kind, because the two costs are different and the
    /// difference matters: a session takes every ID and thumbnail logged in
    /// it, a loose recording takes its audio.
    private var selectionCountTitle: String {
        selection.isEmpty ? "Select Items" : "\(selection.count) Selected"
    }

    /// A swipe on one row shouldn't be asked about as "the selected items".
    private var deleteAlertTitle: String {
        guard let pending = bulkPendingDelete else { return "" }
        if pending.sessions.count == 1 && pending.recordings.isEmpty { return "Delete this session?" }
        if pending.recordings.count == 1 && pending.sessions.isEmpty { return "Delete this recording?" }
        return "Delete the selected items?"
    }

    private func bulkDeleteMessage(_ pending: BulkDelete) -> String {
        let s = pending.sessions.count, r = pending.recordings.count
        var parts: [String] = []
        if s > 0 { parts.append("\(s) session\(s == 1 ? "" : "s"), with every ID and recording logged in \(s == 1 ? "it" : "them")") }
        if r > 0 { parts.append("\(r) recording\(r == 1 ? "" : "s")") }
        return "This removes " + parts.joined(separator: ", and ") + ". It can't be undone."
    }

    /// One list: sessions by day, then whatever recordings belong to no session.
    ///
    /// These used to be two tabs behind a segmented picker. Every outing has been
    /// a session for a long time now, so the second tab was showing an empty list
    /// (or a handful of pre-sessions leftovers) to everyone, permanently, in
    /// exchange for a control at the top of the screen. The leftovers still have
    /// to go somewhere — an import deliberately lands outside every session (see
    /// `importAll`) — so they are a section at the bottom rather than a tab.
    @ViewBuilder private var sessionsContent: some View {
        // Filtered and sorted ONCE per evaluation, then read from the local.
        // Reading the computed property from several places re-ran the whole
        // chain each time — a filter over every recording, then a sort — on every
        // redraw, and this screen redraws for each of the dozens of `@Observable`
        // recordings changes an upload sweep or an iCloud sync produces.
        //
        // Deliberately NOT filtered by `showNoID`. There is no filter control on
        // this screen any more, so hiding a row here would leave a recording
        // unreachable with nothing to tap to bring it back — the same
        // strand-the-user rule `SimplifiedView`'s header sets out for hidden
        // controls. The filter lives inside a session, where the button does.
        let looseRecordings = store.listeningRecordings.sorted { $0.date > $1.date }
        if store.sessions.isEmpty && looseRecordings.isEmpty {
            ContentUnavailableView(
                "No sessions yet",
                systemImage: "square.stack.3d.up",
                description: Text("Tap Start to begin detecting. Every outing is logged here automatically.")
            )
        } else {
            List {
                ForEach(groupSessionsByDay(store.sessions), id: \.key) { group in
                    // A heading ROW, not a `Section` header: a plain list pins
                    // its headers, and these have no background of their own to
                    // pin with — see `TileList`.
                    TileSectionHeading(title: group.title)

                    ForEach(group.sessions) { session in
                            SelectableRow(isSelecting: isSelecting,
                                          isSelected: selection.contains(.session(session.id)),
                                          toggle: { toggle(.session(session.id)) }) {
                                SessionDetailView(session: session, store: store, settings: settings,
                                                  consent: consent, micCalSettings: micCalSettings,
                                                  speciesGuide: speciesGuide)
                            } label: {
                                SessionRow(session: session, store: store)
                            }
                            .tileRow()
                            // Red-tinted, NOT `role: .destructive`, and not
                            // `onDelete`. Both of those own the row's removal
                            // animation and play it the moment Delete is
                            // tapped, so the row slid out from under the
                            // confirmation alert and slid back when it was
                            // answered — vanishing before the question was
                            // answered and reappearing after it was. A plain
                            // tinted button looks identical and only runs the
                            // closure, leaving the row to the alert.
                            .swipeActions(edge: .trailing) {
                                Button {
                                    bulkPendingDelete = BulkDelete(sessions: [session], recordings: [])
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                    }
                }

                if !looseRecordings.isEmpty {
                    TileSectionHeading(title: "Not in a session")

                    ForEach(looseRecordings) { recording in
                            SelectableRow(isSelecting: isSelecting,
                                          isSelected: selection.contains(.recording(recording.id)),
                                          toggle: { toggle(.recording(recording.id)) }) {
                                recordingDestination(recording)
                            } label: {
                                RecordingRow(recording: recording, store: store, consent: consent)
                            }
                            .tileRow()
                            // Confirmed like every other delete rather than
                            // acted on straight away: a swipe took the WAV with
                            // no way back. See the note above on swipeActions.
                            .swipeActions(edge: .trailing) {
                                Button {
                                    bulkPendingDelete = BulkDelete(sessions: [], recordings: [recording])
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                    }

                    Text("Imported WAVs, and anything recorded before every outing became a session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .tileRow()
                }
            }
            .pageBackground()
            .pageColumn()
            // Tiles, like the guide's species lists — see `TileList` for why a
            // plain list rather than an inset-grouped one.
            .listStyle(.plain)
            .listRowSpacing(0)
            .contentMargins(.top, TileList.scrollTopMargin, for: .scrollContent)
            // The system draws its chevron in the row's trailing inset, outside
            // the glass; `SelectableRow` draws its own inside.
            .navigationLinkIndicatorVisibility(.hidden)
        }
    }

    /// Lazy: WavPlayerView's `@State` engine is expensive to construct — see
    /// LazyDestination.
    @ViewBuilder private func recordingDestination(_ recording: Recording) -> some View {
        LazyDestination {
            WavPlayerView(recording: recording, store: store, micCalSettings: micCalSettings,
                          speciesGuide: speciesGuide)
        }
    }

    // MARK: Import

    /// Copies each picked file, then renders thumbnails and registers them.
    ///
    /// The copy runs RIGHT HERE, synchronously, still inside the `.fileImporter`
    /// completion handler — the sandbox extension the picker grants doesn't
    /// survive a hop onto another task, and doing the copy there instead made
    /// every import fail with a permissions error. Only the FFT-heavy overview
    /// render is deferred, and by then the file is in our own container.
    private func importAll(_ urls: [URL]) {
        var copied: [RecordingImporter.Copied] = []
        var failures: [String] = []
        for url in urls {
            do {
                copied.append(try RecordingImporter.copyIntoLibrary(source: url))
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // No need to force `display.showNoID` on for an unclassified import any
        // more, which is what used to happen here: an import lands outside every
        // session, and the "Not in a session" section is unfiltered, so the row is
        // visible the moment it is inserted whatever that setting says. Flipping it
        // now would only change the filter inside sessions — somewhere the imported
        // file will never appear.

        guard !copied.isEmpty else {
            reportImport(failures: failures)
            return
        }

        isImporting = true
        Task {
            var lateFailures: [String] = []
            for file in copied {
                // Convert anything that isn't already in the app's own WAV shape
                // before anything reads it — see `normalizeIfNeeded`. Runs here
                // rather than during the copy because it is slow on a long file
                // and, unlike the copy, needs no sandbox extension. A file that
                // can't be converted is dropped rather than left in the library
                // to render as noise.
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try RecordingImporter.normalizeIfNeeded(at: file.url)
                    }.value
                } catch {
                    lateFailures.append("\(file.url.lastPathComponent): \(error.localizedDescription)")
                    try? FileManager.default.removeItem(at: file.url)
                    continue
                }

                let image = await Task.detached(priority: .userInitiated) {
                    RecordingImporter.renderOverview(at: file.url)
                }.value
                // Species/confidence/pulses/coordinate come from the file's own
                // GUANO chunk when it has one, so re-importing an OpenBat export
                // round-trips rather than arriving as a dateless "NoID".
                //
                // `sessionID: nil` regardless: an import always lands outside
                // every session. Filing it into whichever survey session's time
                // window happens to contain its timestamp — which is what
                // RecordingMigration does, correctly, for WAVs this app recorded —
                // would silently alter that session's species list and map pins
                // using a file the user merely opened.
                store.addRecording(date: file.date,
                                   durationSeconds: file.durationSeconds,
                                   species: file.species,
                                   confidence: file.confidence,
                                   pulseCount: file.pulseCount,
                                   sessionID: nil, coordinate: file.coordinate,
                                   relativeWavPath: file.relativeWavPath,
                                   spectrogramImage: image)
            }
            isImporting = false
            reportImport(failures: failures + lateFailures)
        }
    }

    /// Surfaces import failures after a short delay. Presenting an alert while
    /// `.fileImporter` is still dismissing gets silently dropped by SwiftUI, so
    /// a failure reported immediately never reaches the user at all — which is
    /// how the first version of this managed to fail completely silently.
    private func reportImport(failures: [String]) {
        guard !failures.isEmpty else { return }
        let message = failures.joined(separator: "\n\n")
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            importError = message
        }
    }
}

private struct SessionRow: View {
    let session: RecordingSession
    let store: ClassificationStore

    var body: some View {
        // Excludes NOISE/NoID — same filter SessionSpeciesSummary applies — so the
        // count and dominant-species label read as actual species IDs, not
        // inflated by triggers that never resolved to one.
        let passes = store.passes(inSession: session.id).filter { !$0.isNoise && !$0.isNoID }
        HStack(spacing: 12) {
            SessionMapThumbnail(points: passes.compactMap(\.coordinate))
            VStack(alignment: .leading, spacing: 3) {
                // The place, alone. The stored title carries the start timestamp
                // as well, so a row led with the date and then truncated the one
                // thing that says which outing this was — see
                // `RecordingSession.displayName` (Niall, 2026-09-02).
                Text(session.displayName).font(.headline).lineLimit(1)
                Text(dateAndTime).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Label("\(passes.count) ID\(passes.count == 1 ? "" : "s")",
                          systemImage: "waveform.badge.magnifyingglass")
                    if let top = dominantSpecies(passes) { Text("· \(top)") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            // The map sets the row's height; the text only needs enough room of
            // its own not to touch the edges when it wraps to more lines than
            // the square is tall.
            .padding(.vertical, 8)
            Spacer(minLength: 0)
        }
    }

    /// "2 Sep 2026 | 13:30 – 13:47" — the date the row no longer leads with,
    /// then the span. Ends "– now" while the outing is still running.
    private var dateAndTime: String {
        let time = SessionDateFormatters.timeShort
        let start = time.string(from: session.startDate)
        let span = session.endDate.map { "\(start) – \(time.string(from: $0))" } ?? "\(start) – now"
        return "\(SessionDateFormatters.dayMonthYear.string(from: session.startDate)) | \(span)"
    }

    private func dominantSpecies(_ passes: [PassRecord]) -> String? {
        let counts = Dictionary(grouping: passes, by: \.species).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key
    }
}

/// Non-interactive map preview filling the leading square of a session row
/// (Niall, 2026-09-02) — it used to be a 56×40 chip in the same slot as
/// RecordingRow's spectrogram thumbnail, which made the one picture on the row
/// the smallest thing on it. Disabled interaction so a tap still reaches the
/// enclosing NavigationLink instead of panning the mini-map.
///
/// It rounds nothing itself: the row is laid out flush to the leading edge, so
/// the section card does the clipping and the map picks up the card's corners.
///
/// Shows where the IDs happened. It used to draw the session's GPS track as a
/// polyline; tracks were removed (see LocationProvider) because detections
/// already carry coordinates and timestamps — the same information, without a
/// second and much denser recording of the user's movements.
private struct SessionMapThumbnail: View {
    let points: [CLLocationCoordinate2D]
    /// Square, and tall enough to set the row's height on its own — the three
    /// lines of text beside it come to a little less.
    static let side: CGFloat = 76
    /// How much bigger than its slot the map is drawn before being scaled back
    /// down — see the note on the frame below.
    private static let renderScale: CGFloat = 2

    var body: some View {
        Group {
            if points.isEmpty {
                Rectangle()
                    .fill(.quaternary)
                    .overlay { Image(systemName: "location.slash").font(.caption2).foregroundStyle(.secondary) }
            } else {
                Map(initialPosition: .region(fittedRegion(for: points)), interactionModes: []) {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        // A fixed-size dot, not a `MapCircle`: a circle is drawn
                        // in metres, so on a session whose IDs sit close together
                        // the fitted region zooms in and the marker grows into a
                        // blob covering the map. Orange, matching the species
                        // pins on the session's own map.
                        Annotation(coordinate: point) {
                            Circle()
                                .fill(.orange)
                                .frame(width: 6, height: 6)
                        } label: {
                            EmptyView()
                        }
                    }
                }
                .mapControlVisibility(.hidden)
                .allowsHitTesting(false)
                // Rendered at twice the size and scaled back down, which is the
                // only handle there is on the "Legal" attribution: MapKit draws
                // it at a fixed size and it may not be removed — it is Apple's
                // required credit, not a control — so on a 76pt square it was
                // most of the bottom edge. Halving it takes the street labels
                // down with it, which a thumbnail this size is better for.
                .frame(width: Self.side * Self.renderScale,
                       height: Self.side * Self.renderScale)
                .scaleEffect(1 / Self.renderScale)
            }
        }
        .frame(width: Self.side, height: Self.side)
        // The scaled-up map is drawn larger than its slot before the scale is
        // applied; without this it paints over the row's text for one pass.
        .clipped()
    }
}

/// Shared by `SessionMapThumbnail` and `SessionMap` — fits a region around
/// whatever coordinates are passed in, falling back to a fixed Null Island
/// region when there's nothing to show yet.
private func fittedRegion(for coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
    guard let first = coords.first else {
        return MKCoordinateRegion(center: .init(latitude: 0, longitude: 0),
                                  span: .init(latitudeDelta: 1, longitudeDelta: 1))
    }
    var minLat = first.latitude, maxLat = first.latitude
    var minLon = first.longitude, maxLon = first.longitude
    for c in coords {
        minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
        minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
    }
    let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                        longitude: (minLon + maxLon) / 2)
    let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 0.005),
                                longitudeDelta: max((maxLon - minLon) * 1.4, 0.005))
    return MKCoordinateRegion(center: center, span: span)
}

// MARK: - Session detail (map + IDs)

struct SessionDetailView: View {
    let session: RecordingSession
    @Bindable var store: ClassificationStore
    let settings: AutoIDSettings
    let consent: ConsentStore
    let micCalSettings: MicCalibrationSettings
    let speciesGuide: SpeciesGuideStore
    @AppStorage("display.showNoID") private var showNoID = false
    /// Queued by a swipe or by the toolbar's Delete, pending confirmation — a
    /// delete takes the WAV with no way back, so it is asked about here exactly
    /// as it is in the sessions list.
    @State private var pendingDelete: [Recording] = []
    /// Multi-select over the recordings section only; the map and the charts
    /// above it aren't selectable rows.
    @State private var selection = Set<UUID>()
    /// The app's own, not the List's — see the note on the sessions list's
    /// `isSelecting` for what `EditMode` does to a row that leads with a picture.
    @State private var isSelecting = false
    /// Exports don't belong to this screen — see `SessionExportManager`. This
    /// view only starts them and reflects whether one is already running for
    /// this session.
    private let exportManager = SessionExportManager.shared

    var body: some View {
        List {
            if hasGeo {
                // The chart headers are rows now, like every other heading in a
                // tiled list — a plain list pins section headers, and there is no
                // background under them to pin with. See `TileList`.
                sectionHeading { SessionChartHeader(title: "Map & species", kind: .map) }
                // Two cards with a gutter between them, not one panel: a square
                // map, and the species tally in a card of its own (Niall,
                // 2026-09-02). They draw their own surfaces, so the row gives
                // them nothing but the gutter.
                SessionMapSpeciesRow(pins: mappablePasses, passes: sessionPasses)
                    .tileRow()
            }
            if !sessionPasses.isEmpty {
                // Species first, then when they were about. Both used to sit below
                // the recordings list; the summary of an outing is the reason to
                // open it, and the file list is what you go to afterwards. With a
                // map the species live beside it, so the bar chart is redundant.
                if !hasGeo {
                    sectionHeading { SessionChartHeader(title: "Species detected", kind: .species) }
                    SessionSpeciesSummary(passes: sessionPasses)
                        .padding(14)
                        .glassTile()
                        .tileRow()
                }
                sectionHeading { SessionChartHeader(title: "Detections over time", kind: .timeline) }
                SessionActivityChart(passes: sessionPasses,
                                     start: session.startDate,
                                     end: session.endDate ?? Date())
                    .padding(14)
                    .glassTile()
                    .tileRow()
            }
            if !session.notes.isEmpty {
                TileSectionHeading(title: "Notes")
                Text(session.notes)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .glassTile()
                    .tileRow()
            }
            TileSectionHeading(title: "Recordings")
            if sessionRecordings.isEmpty {
                Text(allSessionRecordings.isEmpty
                     ? "No recordings in this session."
                     : "Every recording here is unclassified (NoID) — turn on \"Show unclassified\" in the menu above to see them.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .glassTile()
                    .tileRow()
            } else {
                ForEach(sessionRecordings) { recording in
                    SelectableRow(isSelecting: isSelecting,
                                  isSelected: selection.contains(recording.id),
                                  toggle: { toggle(recording.id) }) {
                        // Lazy: WavPlayerView's `@State` engine is expensive
                        // to construct — see LazyDestination.
                        LazyDestination {
                            WavPlayerView(recording: recording, store: store, micCalSettings: micCalSettings,
                                          speciesGuide: speciesGuide)
                        }
                    } label: {
                        RecordingRow(recording: recording, store: store, consent: consent)
                    }
                    .tileRow()
                    // Red-tinted rather than `role: .destructive` (and not
                    // `onDelete`): both play the row's removal animation as
                    // soon as Delete is tapped, pulling the row out from
                    // under the confirmation and putting it back when the
                    // alert is answered.
                    .swipeActions(edge: .trailing) {
                        Button {
                            pendingDelete = [recording]
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            }
        }
        .pageBackground()
        .pageColumn()
        .listStyle(.plain)
        .listRowSpacing(0)
        .contentMargins(.top, TileList.scrollTopMargin, for: .scrollContent)
        // The system's chevron sits in the row's trailing inset, outside the
        // tile; `SelectableRow` draws its own inside.
        .navigationLinkIndicatorVisibility(.hidden)
        // While selecting the title carries the count — see the note in the
        // sessions list about the floating tab bar covering `.bottomBar`.
        .navigationTitle(isSelecting
                         ? (selection.isEmpty ? "Select Recordings" : "\(selection.count) Selected")
                         : session.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // No painted header (Niall, 2026-09-02). The app-wide appearance proxy
        // gives every bar an opaque background, which on a page whose content
        // starts right under it reads as a header strip the page doesn't need.
        // Cleared here, with the scroll-edge scrim dropped alongside it — one
        // without the other just swaps a painted bar for a glass one.
        .clearNavigationBarBackground()
        .flatTopScrollEdge()
        // The back chevron shares the leading slot with Delete, and a screen
        // you are part-way through selecting on is one you leave with Done.
        .navigationBarBackButtonHidden(isSelecting)
        .alert(pendingDelete.count == 1 ? "Delete this recording?" : "Delete the selected recordings?",
               isPresented: Binding(
                   get: { !pendingDelete.isEmpty },
                   set: { if !$0 { pendingDelete = [] } }
               )) {
            Button("Delete", role: .destructive) {
                // The batch overload, not one call per recording: deleting
                // singly rewrites the store's index each time.
                store.delete(pendingDelete)
                pendingDelete = []
                withAnimation {
                    selection.removeAll()
                    isSelecting = false
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text(pendingDelete.count == 1
                 ? "This removes the recording and any IDs made from it. It can't be undone."
                 : "This removes \(pendingDelete.count) recordings and any IDs made from them. It can't be undone.")
        }
        .toolbar {
            if !isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // A Toggle rather than a Button: inside a Menu it draws
                        // its own checkmark, which is what carries the on/off
                        // state now that the toolbar icon no longer can.
                        Toggle("Show unclassified", isOn: $showNoID)
                        Divider()
                        Button {
                            withAnimation { isSelecting = true }
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        .disabled(sessionRecordings.isEmpty)
                        if isExporting {
                            // Not a disabled "Export Session…" — that reads as
                            // "you can't", when what's true is "it's already
                            // happening, and the banner is showing you where".
                            Label("Exporting…", systemImage: "clock")
                        } else {
                            Button {
                                exportSession()
                            } label: {
                                Label("Export Session…", systemImage: "square.and.arrow.up")
                            }
                            .disabled(allSessionRecordings.isEmpty)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Session options")
                }
            } else {
                // Same shape as the sessions list: Delete leading, Done
                // trailing, the count between them.
                ToolbarItem(placement: .topBarLeading) {
                    // Tinted, not `role: .destructive` — see the sessions list's
                    // Delete for why.
                    Button {
                        pendingDelete = sessionRecordings.filter { selection.contains($0.id) }
                    } label: {
                        Text("Delete")
                    }
                    .tint(.red)
                    .disabled(selection.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        withAnimation {
                            isSelecting = false
                            selection.removeAll()
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// A custom header view — `SessionChartHeader`, with its own info button —
    /// dressed as a `TileSectionHeading`: same type, same colour, same insets.
    /// The heading component itself can't be replaced by one, because it carries
    /// a popover the plain text heading has no room for.
    private func sectionHeading<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color(uiColor: .secondaryLabel))
            .textCase(nil)
            .listRowInsets(EdgeInsets(top: TileList.headerTopPadding, leading: TileList.contentInset,
                                      bottom: TileList.headerBottomPadding, trailing: TileList.contentInset))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private var isExporting: Bool { exportManager.isActive(sessionID: session.id) }

    /// Hands the export to `SessionExportManager` and returns. Everything after
    /// this — progress, cancelling, and the share sheet at the end — belongs to
    /// the manager, so leaving this screen doesn't abandon the work.
    ///
    /// Exports the whole session, NOT what the list is currently showing:
    /// `showNoID` is a filter on this screen, and a bundle that quietly dropped
    /// the unclassified files would be a worse archive than the session it came
    /// from. Every recording is in the CSV either way, with its species column
    /// reading NOID.
    private func exportSession() {
        let input = SessionExport.Input(
            sessionID: session.id,
            title: session.title,
            notes: session.notes,
            startDate: session.startDate,
            endDate: session.endDate,
            rows: allSessionRecordings.map { recording in
                SessionExport.Row(
                    recordingID: recording.id,
                    wavURL: store.wavURL(for: recording),
                    date: recording.date,
                    durationSeconds: recording.durationSeconds,
                    species: recording.species,
                    commonName: recording.commonName,
                    confidence: recording.confidence,
                    pulseCount: recording.pulseCount,
                    latitude: recording.latitude,
                    longitude: recording.longitude,
                    uploadStatus: recording.uploadStatus?.phase.rawValue ?? ""
                )
            },
            detections: sessionPasses.map { pass in
                SessionExport.Detection(
                    passID: pass.id,
                    date: pass.date,
                    species: pass.species,
                    commonName: pass.commonName,
                    confidence: pass.confidence,
                    rawConfidence: pass.rawConfidence,
                    pulseCount: pass.pulseCount,
                    runnerUpSpecies: pass.runnerUpSpecies,
                    runnerUpConfidence: pass.runnerUpConfidence,
                    complexID: pass.complexID,
                    complexAmbiguous: pass.complexAmbiguous,
                    latitude: pass.latitude,
                    longitude: pass.longitude
                )
            },
            // Flattened here rather than in the exporter: this is the only place
            // that knows the snapshots are stored on the session.
            priors: (session.priorSnapshots ?? []).flatMap { snapshot in
                snapshot.priors
                    .sorted { $0.key < $1.key }
                    .map { code, prior in
                        SessionExport.PriorRow(
                            takenAt: snapshot.takenAt,
                            modelID: snapshot.modelID,
                            species: code,
                            prior: prior,
                            enabled: !snapshot.disabled.contains(code))
                    }
            },
            pulseScores: sessionPasses.flatMap { pass in
                pass.pulses.flatMap { pulse -> [SessionExport.PulseScore] in
                    func row(rank: Int?, species: String?, score: Float?) -> SessionExport.PulseScore {
                        SessionExport.PulseScore(
                            passID: pass.id, pulseID: pulse.id, date: pulse.date,
                            pulseSpecies: pulse.species, pulseConfidence: pulse.confidence,
                            peakFreqHz: pulse.peakFreqHz, durationMs: pulse.durationMs,
                            rank: rank, species: species, score: score)
                    }
                    // A pulse that stored no scores still gets a row. In long
                    // format it would otherwise vanish from the file entirely,
                    // and "this pulse has no scores" is itself worth seeing.
                    guard !pulse.topScores.isEmpty else { return [row(rank: nil, species: nil, score: nil)] }
                    return pulse.topScores.enumerated().map { index, entry in
                        row(rank: index + 1, species: entry.species, score: entry.score)
                    }
                }
            }
        )
        exportManager.enqueue(input)
    }

    private var sessionPasses: [PassRecord] { store.passes(inSession: session.id) }
    /// Everything in the session, unfiltered — what the export bundles.
    private var allSessionRecordings: [Recording] { store.recordings(inSession: session.id) }
    private var sessionRecordings: [Recording] {
        allSessionRecordings.filteredByNoID(showNoID: showNoID)
    }
    private var mappablePasses: [PassRecord] { sessionPasses.filter(settings.isMappable) }
    private var hasGeo: Bool { !mappablePasses.isEmpty }
}

/// The session's map and its species tally as two separate cards side by side,
/// with a gutter between them: a square map on the left two-thirds, the codes
/// and counts in a card of its own in the rest.
///
/// The row carries no insets of its own, so the pair spans exactly the width the
/// list's other section cards do and the outer edges line up down the screen.
///
/// Both cards use `SessionCardShape`, which on iOS 26 derives its corners from
/// the list's own card rather than guessing at them — the previous fixed 12pt
/// radius is what read as the wrong shape beside a system section card.
///
/// The width is measured rather than derived from an aspect ratio on the row:
/// the map is square and the species card matches its height, so the row's
/// height follows from the width and no ratio on the row expresses that.
private struct SessionMapSpeciesRow: View {
    let pins: [PassRecord]
    let passes: [PassRecord]

    /// Seeded from the screen so the first layout pass is already right — a zero
    /// default collapses the map for one frame.
    @State private var width: CGFloat = UIScreen.main.bounds.width - 32

    private static let gutter: CGFloat = 12

    var body: some View {
        let side = max(0, (width - Self.gutter) * 2 / 3)
        HStack(alignment: .top, spacing: Self.gutter) {
            // Both on the app's card material, in the concentric shape this row
            // has always used (Niall, 2026-09-02). The species tally was a
            // `secondarySystemGroupedBackground` fill, which is white on a white
            // light-mode page — the card simply wasn't there any more. The map
            // was only clipped, with no card under it at all; it missed the pass
            // that moved everything else onto glass.
            SessionMap(pins: pins)
                .frame(width: side, height: side)
                .glassTile(in: SessionCardShape.shape)
            SessionSpeciesColumn(passes: passes)
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(height: side)
                .glassTile(in: SessionCardShape.shape)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { geo in
                Color.clear.onChange(of: geo.size.width, initial: true) { _, w in
                    width = w
                }
            }
        )
    }
}

/// The corner shape for a card drawn inside a list row — the map and the species
/// tally beside it.
///
/// A card inside a rounded card has to answer to the one around it, and the
/// list's own radius is not a number the app is told. On iOS 26 the system will
/// derive it: a concentric rectangle takes its corners from its container, which
/// is the section card these sit in, and stays right if the OS changes them
/// again. Before that there is nothing to ask, so it falls back to the 10pt
/// radius UIKit's inset-grouped sections have used all along — which is also the
/// minimum the concentric shape is given, for the case where a container shape
/// isn't resolvable.
private enum SessionCardShape {
    static let fallbackRadius: CGFloat = 10

    static var shape: AnyShape {
        if #available(iOS 26.0, *) {
            AnyShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(fallbackRadius)),
                                         isUniform: true))
        } else {
            AnyShape(RoundedRectangle(cornerRadius: fallbackRadius, style: .continuous))
        }
    }
}

/// Just the codes and their detection counts — no bars. The map carries the
/// visual weight; this is the legend beside it.
///
/// Draws no background: the card is painted by whatever places it, so the fill
/// and the corner shape are decided in one place rather than two.
private struct SessionSpeciesColumn: View {
    let passes: [PassRecord]

    var body: some View {
        let rows = SessionSpeciesSummary.counts(for: passes)
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                if rows.isEmpty {
                    Text("No species IDs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows, id: \.species) { row in
                        HStack(spacing: 6) {
                            Text(row.species)
                                .font(.system(size: 12, weight: .medium).monospaced())
                            Spacer(minLength: 4)
                            Text("\(row.count)")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// A species pin per high-quality ID, framed to fit them all.
private struct SessionMap: View {
    let pins: [PassRecord]

    var body: some View {
        Map(initialPosition: .region(region)) {
            ForEach(pins) { pass in
                if let c = pass.coordinate {
                    Marker(pass.species, systemImage: "waveform", coordinate: c)
                        .tint(.orange)
                }
            }
        }
    }

    private var region: MKCoordinateRegion {
        fittedRegion(for: pins.compactMap(\.coordinate))
    }
}


// MARK: - Selectable row (shared)

/// A list row that navigates normally, and while a selection is running becomes
/// a tick instead — in the chevron's place, not in a column of its own.
///
/// The alternative is `List(selection:)` with `EditMode`, which is what this
/// screen used to do. It inserts its circles down the leading edge and slides
/// every row's content across to make room; on rows that lead with a picture
/// (a session's map, a recording's spectrogram) the whole list lurches
/// sideways as selection starts, and the thing being ticked ends up furthest
/// from the tick. Swapping the row's trailing chevron for the tick keeps every
/// row exactly where it was and puts the state where the eye already is.
///
/// The row is a `Button` rather than a `NavigationLink` while selecting, which
/// is also what removes the chevron — a link would still draw one and still be
/// pushable underneath the tap that was meant to tick it.
private struct SelectableRow<Destination: View, Label: View>: View {
    let isSelecting: Bool
    let isSelected: Bool
    let toggle: () -> Void
    @ViewBuilder var destination: () -> Destination
    @ViewBuilder var label: () -> Label

    var body: some View {
        if isSelecting {
            Button(action: toggle) {
                tile {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.batAccent : Color.secondary)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            NavigationLink { destination() } label: { tile { RowChevron() } }
        }
    }

    /// The row as a glass tile, with whichever trailing accessory the mode calls
    /// for inside it.
    ///
    /// Both the tick and the chevron are drawn here rather than left to the
    /// list: the system's disclosure indicator sits in the row's trailing inset,
    /// which is OUTSIDE the tile, so it floated in the gutter beside the row —
    /// the same thing that happened to the guide's species rows (Niall,
    /// 2026-09-02). Turn the system's off with
    /// `.navigationLinkIndicatorVisibility(.hidden)` on the list.
    private func tile<Accessory: View>(@ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 10) {
            label()
            Spacer(minLength: 6)
            accessory()
        }
        .padding(.trailing, 12)
        .contentShape(Rectangle())
        .glassTile()
    }
}

// MARK: - Day grouping (shared)

private struct SessionDayGroup { let key: Date; let title: String; let sessions: [RecordingSession] }
private func groupSessionsByDay(_ sessions: [RecordingSession]) -> [SessionDayGroup] {
    let cal = Calendar.current
    let dict = Dictionary(grouping: sessions) { cal.startOfDay(for: $0.startDate) }
    return dict.keys.sorted(by: >).map { day in
        SessionDayGroup(key: day, title: dayTitle(day),
                        sessions: dict[day]!.sorted { $0.startDate > $1.startDate })
    }
}

private func dayTitle(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) { return "Today" }
    if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
    return SessionDateFormatters.dateMedium.string(from: date)
}

// MARK: - Pass row

struct PassRow: View {
    let pass: PassRecord
    let store: ClassificationStore
    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pass.species).font(.headline)
                    Text("·").foregroundStyle(.secondary)
                    Text(pass.commonName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if pass.isNoise {
                    Text("NOISE means it wasn't a bat")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if pass.isNoID {
                    Text("Triggered, but couldn't be classified")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text("\(pass.pulseCount) pulse\(pass.pulseCount == 1 ? "" : "s") · \(Self.time(pass.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !pass.isNoID {
                VStack(alignment: .trailing, spacing: 4) {
                    ConfidenceBadge(confidence: pass.confidence)
                    ComplexIndicator(pass: pass)
                }
            }
        }
        .padding(.vertical, 2)
        .task(id: representativePulse?.id) {
            guard let pulse = representativePulse else { return }
            image = await store.loadImage(for: pulse)
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 56, height: 40)
                .overlay { Image(systemName: "waveform").font(.caption2).foregroundStyle(.secondary) }
        }
    }

    /// Optional, and the `?? pulses.first` matters: `max(by:)` returns nil
    /// EXACTLY when the array is empty, so the old `?? pass.pulses[0]` fallback
    /// could only ever run in the one case where index 0 is out of bounds — a
    /// guaranteed crash dressed as a default. Live construction always guards
    /// against an empty `pulses` (PulseDetector.finalizePass, and again in
    /// ClassificationStore.addPass), but a PassRecord decoded from a corrupt or
    /// future-schema recordings.json has no such guarantee. The thumbnail view
    /// already renders a placeholder for a nil image.
    private var representativePulse: PulseRecord? {
        pass.pulses.max(by: { $0.confidence < $1.confidence }) ?? pass.pulses.first
    }

    private static func time(_ d: Date) -> String {
        SessionDateFormatters.timeMedium.string(from: d)
    }
}

// MARK: - Pass detail

// Not private: also presented as a sheet from the live species-ID feed
// (SpeciesFeedView) — same record, same detail screen.
struct PassDetailView: View {
    let pass: PassRecord
    let store: ClassificationStore

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(pass.species).font(.title2.bold())
                        Spacer()
                        if !pass.isNoID {
                            ConfidenceBadge(confidence: pass.confidence)
                        }
                    }
                    Text(pass.commonName).foregroundStyle(.secondary)
                    if pass.isNoise {
                        Text("NOISE means it wasn't a bat")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if pass.isNoID {
                        Text("Triggered, but couldn't be classified")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text("\(pass.pulseCount) classified pulse\(pass.pulseCount == 1 ? "" : "s") · \(Self.timestamp(pass.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let runnerUp = pass.runnerUpSpecies {
                        Text("Runner-up: \(SpeciesInfo.commonName[runnerUp] ?? runnerUp)"
                             + (pass.runnerUpConfidence.map { String(format: " (%.0f%%)", $0 * 100) } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                // Plain-language caveat: the % is a posterior renormalized over the
                // species enabled in AutoID settings, not an absolute certainty —
                // without this, "85%" over-promises whenever species are disabled.
                Text("Confidence is how the classifier splits its belief between the species enabled in AutoID settings — not an absolute certainty. Disabling species hands their share to the rest, so the number can read high even for an unclear call.")
            }

            if pass.complex != nil {
                Section {
                    ComplexCallout(pass: pass)
                }
            }

            Section("Pulses") {
                ForEach(pass.pulses) { pulse in
                    PulseDetailRow(pulse: pulse, store: store)
                }
            }
        }
        .pageBackground()
        .pageColumn()
        .navigationTitle(pass.species)
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func timestamp(_ d: Date) -> String {
        SessionDateFormatters.dateTimeMedium.string(from: d)
    }
}

// MARK: - Pulse detail row

private struct PulseDetailRow: View {
    let pulse: PulseRecord
    let store: ClassificationStore
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image {
                PulseImagePlot(image: image,
                               freqMinHz: pulse.imageFreqMinHz,
                               freqMaxHz: pulse.imageFreqMaxHz,
                               spanMs: pulse.imageSpanMs)
            }

            HStack {
                Text(pulse.species).font(.headline)
                Spacer()
                ConfidenceBadge(confidence: pulse.confidence)
            }

            HStack(spacing: 14) {
                stat("Fpeak", String(format: "%.0f kHz", pulse.peakFreqHz / 1000))
                stat("Dur", String(format: "%.0f ms", pulse.durationMs))
            }

            // Top alternative scores as labelled bars.
            VStack(spacing: 3) {
                ForEach(pulse.topScores.prefix(4)) { entry in
                    ScoreBar(species: entry.species, score: entry.score)
                }
            }
        }
        .padding(.vertical, 4)
        .task(id: pulse.id) {
            image = await store.loadImage(for: pulse)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit())
        }
    }
}

// MARK: - Pulse image plot

/// Stored pulse thumbnail with labelled frequency (y) and time (x) axes, when
/// the record carries its crop bounds. Older records without bounds fall back
/// to the bare image. The spectrogram is stretched to the plot frame (not
/// aspect-preserved) so the axis endpoints line up exactly with the image edges.
struct PulseImagePlot: View {
    let image: UIImage
    let freqMinHz: Double?
    let freqMaxHz: Double?
    let spanMs: Double?

    private let axisWidth: CGFloat = 30
    private let plotHeight: CGFloat = 130

    var body: some View {
        if let fMin = freqMinHz, let fMax = freqMaxHz, let span = spanMs,
           fMax > fMin, span > 0 {
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    VStack(alignment: .trailing, spacing: 0) {
                        axisLabel(String(format: "%.0f", fMax / 1000))
                        Spacer()
                        axisLabel(String(format: "%.0f", (fMin + fMax) / 2000))
                        Spacer()
                        axisLabel(String(format: "%.0f", fMin / 1000))
                    }
                    .frame(width: axisWidth, height: plotHeight, alignment: .trailing)
                    plotImage
                }
                HStack(spacing: 4) {
                    axisLabel("kHz")
                        .frame(width: axisWidth, alignment: .trailing)
                    HStack(spacing: 0) {
                        axisLabel("0")
                        Spacer()
                        axisLabel(String(format: "%.1f", span / 2))
                        Spacer()
                        axisLabel(String(format: "%.1f ms", span))
                    }
                }
            }
        } else {
            plotImage
        }
    }

    private var plotImage: some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .frame(maxWidth: .infinity)
            .frame(height: plotHeight)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(uiColor: .systemBackground)))
    }

    private func axisLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

// MARK: - Small components

struct ConfidenceBadge: View {
    let confidence: Float
    var body: some View {
        Text(String(format: "%.0f%%", confidence * 100))
            .font(.caption.monospacedDigit().weight(.semibold))
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
    }

    private var ink: Color { color.darkenedInLightMode() }

    private var color: Color {
        switch confidence {
        case 0.6...:  return .green
        case 0.3..<0.6: return .yellow
        default:      return .orange
        }
    }
}

/// Small amber pill shown alongside a `ConfidenceBadge` when the winning species is
/// one the model can't cleanly separate. Non-interactive — the full explanation lives
/// in `ComplexCallout` on the detail screen. When the ID is an *active* ambiguity it
/// names the close alternative ("or MYYU"); otherwise it flags the group ("sounds
/// alike").
///
/// The wording is deliberately not the field's own vocabulary. This used to read
/// "complex" and "cf. MYYU" — both standard in bat acoustics and both opaque to
/// everyone else: "complex" is a term of art that a newcomer reads as the ordinary
/// adjective, and "cf." is an abbreviation of Latin *confer*. Neither appears in
/// GUANO metadata or the upload path, so they were only ever teaching a vocabulary,
/// not carrying data — see the onboarding cards, which explain both jobs.
struct ComplexIndicator: View {
    let pass: PassRecord

    var body: some View {
        if pass.complex != nil {
            Label(text, systemImage: "questionmark.circle")
                .font(.system(size: 10, weight: .semibold))
                .fixedSize()
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                // Darker orange in light mode — see `darkenedInLightMode`. On
                // white this pill was an orange glyph on an almost-white wash.
                .background(Color.orange.opacity(0.18), in: Capsule())
                .foregroundStyle(Color.orange.darkenedInLightMode())
                .accessibilityLabel(accessibility)
        }
    }

    private var text: String {
        if pass.isComplexAmbiguous, let runnerUp = pass.runnerUpSpecies {
            return "or \(runnerUp)"
        }
        return "sounds alike"
    }

    private var accessibility: String {
        if pass.isComplexAmbiguous, let runnerUp = pass.runnerUpSpecies {
            return "Confusable with \(SpeciesInfo.commonName[runnerUp] ?? runnerUp)"
        }
        return "Sounds like other species the model cannot reliably separate"
    }
}

/// The honest, expanded caveat shown on the pass detail screen: what the complex is,
/// why it's hard, and — for an active ambiguity — the close alternative with the
/// per-species scores from this pass so the user can judge for themselves.
struct ComplexCallout: View {
    let pass: PassRecord

    var body: some View {
        if let complex = pass.complex {
            VStack(alignment: .leading, spacing: 8) {
                Label(complex.name, systemImage: "questionmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)

                if pass.isComplexAmbiguous, let runnerUp = pass.runnerUpSpecies {
                    Text("Could also be \(SpeciesInfo.commonName[runnerUp] ?? runnerUp) (\(runnerUp))"
                         + (pass.runnerUpConfidence.map { String(format: ", %.0f%%", $0 * 100) } ?? "")
                         + " — these ran close and are hard to tell apart.")
                        .font(.footnote)
                }

                Text(complex.note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }
}

private struct ScoreBar: View {
    let species: String
    let score: Float
    var body: some View {
        HStack(spacing: 6) {
            Text(species)
                .font(.system(size: 10, weight: .medium).monospaced())
                .frame(width: 42, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint)
                        .frame(width: max(2, geo.size.width * CGFloat(min(max(score, 0), 1))))
                }
            }
            .frame(height: 6)
            Text(String(format: "%.0f%%", score * 100))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }
}
