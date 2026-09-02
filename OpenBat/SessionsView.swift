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
}

// MARK: - Sessions list

struct SessionsView: View {
    @Bindable var store: ClassificationStore
    let settings: AutoIDSettings
    let consent: ConsentStore
    /// Only used to hand the player its calibration curve — this screen shows no
    /// spectrogram of its own.
    let micCalSettings: MicCalibrationSettings
    @State private var showImporter = false
    @State private var importError: String?
    @State private var isImporting = false
    /// Sessions queued by a swipe-delete, pending user confirmation (deleting a
    /// session irreversibly removes all its IDs and thumbnails).
    @State private var sessionsPendingDelete: [RecordingSession] = []

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
    @State private var editMode: EditMode = .inactive
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
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        // Flat black bar, matching every other section. This colour only fills the
        // bar's background — the glass material that used to composite over it
        // (reading as a grey header) is removed app-wide in
        // `OpenBatApp.configureNavigationBarAppearance`, and `flatTopScrollEdge`
        // drops the scroll-edge scrim this section's list would otherwise add.
        .toolbarBackground(Color.black, for: .navigationBar)
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
        .confirmationDialog("Delete this session and all its IDs?",
                            isPresented: Binding(
                                get: { !sessionsPendingDelete.isEmpty },
                                set: { if !$0 { sessionsPendingDelete = [] } }
                            ),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                sessionsPendingDelete.forEach(store.deleteSession)
                sessionsPendingDelete = []
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Every ID and recording logged in this session will be removed. This can't be undone.")
        }
        .confirmationDialog("Delete the selected items?",
                            isPresented: Binding(
                                get: { !(bulkPendingDelete?.isEmpty ?? true) },
                                set: { if !$0 { bulkPendingDelete = nil } }
                            ),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let pending = bulkPendingDelete else { return }
                pending.sessions.forEach(store.deleteSession)
                // The batch overload, not one call per recording: deleting
                // singly rewrites the store's index each time.
                if !pending.recordings.isEmpty { store.delete(pending.recordings) }
                bulkPendingDelete = nil
                withAnimation {
                    selection.removeAll()
                    editMode = .inactive
                }
            }
            Button("Cancel", role: .cancel) { bulkPendingDelete = nil }
        } message: {
            Text(bulkPendingDelete.map(bulkDeleteMessage) ?? "")
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        // Import an external WAV — the only way to audition a known bat call
        // through the listening modes without a live bat, since WavPlayerView
        // drives the real DSP from the file at its native rate. See
        // RecordingImporter. Came here when the Playback tab was folded in.
        //
        // Hidden while selecting: importing during a multi-select would land a
        // new row in a list the user is part-way through choosing from.
        if editMode == .inactive {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showImporter = true
                } label: {
                    if isImporting {
                        ProgressView()
                    } else {
                        Image(systemName: "plus")
                    }
                }
                .disabled(isImporting)
                .accessibilityLabel("Import a recording")
            }
        }
        // Not `EditButton()`: leaving selection has to drop the selection with
        // it, or the next Select starts with rows already ticked from last
        // time and a Delete is one tap from removing them.
        ToolbarItem(placement: .topBarTrailing) {
            Button(editMode == .inactive ? "Select" : "Done") {
                withAnimation {
                    if editMode == .inactive {
                        editMode = .active
                    } else {
                        editMode = .inactive
                        selection.removeAll()
                    }
                }
            }
            .disabled(store.sessions.isEmpty && looseRecordingsSorted.isEmpty)
        }
        if editMode == .active {
            ToolbarItemGroup(placement: .bottomBar) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected { selection.removeAll() } else { selectAll() }
                }
                Spacer()
                Text(selection.isEmpty
                     ? "Nothing selected"
                     : "\(selection.count) selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    bulkPendingDelete = resolveSelection()
                } label: {
                    Text("Delete")
                }
                .disabled(selection.isEmpty)
            }
        }
        // No unclassified-recordings filter here (Niall, 2026-08-16). This screen
        // is a list of outings, not of classifications; the filter belongs where
        // the recordings are, which is inside a session — SessionDetailView carries
        // it. Nothing on this screen reads `display.showNoID` at all now.

    }

    // MARK: Selection

    private var allSelectableCount: Int {
        store.sessions.count + looseRecordingsSorted.count
    }

    private var allSelected: Bool {
        !selection.isEmpty && selection.count == allSelectableCount
    }

    private func selectAll() {
        selection = Set(store.sessions.map { Selected.session($0.id) })
            .union(looseRecordingsSorted.map { Selected.recording($0.id) })
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
            List(selection: $selection) {
                ForEach(groupSessionsByDay(store.sessions), id: \.key) { group in
                    Section(group.title) {
                        ForEach(group.sessions) { session in
                            NavigationLink {
                                SessionDetailView(session: session, store: store, settings: settings,
                                                  consent: consent, micCalSettings: micCalSettings)
                            } label: {
                                SessionRow(session: session, store: store)
                            }
                            .tag(Selected.session(session.id))
                        }
                        .onDelete { offsets in
                            sessionsPendingDelete = offsets.map { group.sessions[$0] }
                        }
                    }
                }

                if !looseRecordings.isEmpty {
                    Section {
                        ForEach(looseRecordings) { recording in
                            NavigationLink {
                                recordingDestination(recording)
                            } label: {
                                RecordingRow(recording: recording, store: store, consent: consent)
                            }
                            .tag(Selected.recording(recording.id))
                        }
                        .onDelete { offsets in offsets.map { looseRecordings[$0] }.forEach(store.delete) }
                    } header: {
                        Text("Not in a session")
                    } footer: {
                        Text("Imported WAVs, and anything recorded before every outing became a session.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, $editMode)
        }
    }

    /// Lazy: WavPlayerView's `@State` engine is expensive to construct — see
    /// LazyDestination.
    @ViewBuilder private func recordingDestination(_ recording: Recording) -> some View {
        LazyDestination {
            WavPlayerView(recording: recording, store: store, micCalSettings: micCalSettings)
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
                Text(session.title).font(.headline).lineLimit(1)
                Text(timeRange).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Label("\(passes.count) ID\(passes.count == 1 ? "" : "s")",
                          systemImage: "waveform.badge.magnifyingglass")
                    if let top = dominantSpecies(passes) { Text("· \(top)") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var timeRange: String {
        let f = SessionDateFormatters.timeShort
        let start = f.string(from: session.startDate)
        guard let end = session.endDate else { return "\(start) – now" }
        return "\(start) – \(f.string(from: end))"
    }

    private func dominantSpecies(_ passes: [PassRecord]) -> String? {
        let counts = Dictionary(grouping: passes, by: \.species).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key
    }
}

/// Small non-interactive map preview for a session row — same slot/size as
/// RecordingRow's spectrogram thumbnail. Disabled interaction so a tap still
/// reaches the enclosing NavigationLink instead of panning the mini-map.
///
/// Shows where the IDs happened. It used to draw the session's GPS track as a
/// polyline; tracks were removed (see LocationProvider) because detections
/// already carry coordinates and timestamps — the same information, without a
/// second and much denser recording of the user's movements.
private struct SessionMapThumbnail: View {
    let points: [CLLocationCoordinate2D]
    static let size = CGSize(width: 56, height: 40)

    var body: some View {
        Group {
            if points.isEmpty {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .overlay { Image(systemName: "location.slash").font(.caption2).foregroundStyle(.secondary) }
            } else {
                Map(initialPosition: .region(fittedRegion(for: points)), interactionModes: []) {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        MapCircle(center: point, radius: 120)
                            .foregroundStyle(.blue.opacity(0.7))
                    }
                }
                .mapControlVisibility(.hidden)
                .allowsHitTesting(false)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
    @AppStorage("display.showNoID") private var showNoID = false
    /// Exports don't belong to this screen — see `SessionExportManager`. This
    /// view only starts them and reflects whether one is already running for
    /// this session.
    private let exportManager = SessionExportManager.shared

    var body: some View {
        List {
            if hasGeo {
                Section {
                    SessionMap(pins: mappablePasses)
                        .frame(height: 240)
                        .listRowInsets(EdgeInsets())
                }
                // The "N pinned of M IDs (≥ 60% · ≥ 3 pulses)" caption that used to
                // sit under the map is gone (Niall, 2026-08-16). It was explaining
                // the map's own filtering thresholds in the map's smallest type —
                // a discrepancy nobody had asked about, stated in the language of
                // the settings that cause it. The thresholds are still in AutoID
                // settings, where they can be changed.
            }
            if !sessionPasses.isEmpty {
                // Species first, then when they were about. Both used to sit below
                // the recordings list; the summary of an outing is the reason to
                // open it, and the file list is what you go to afterwards.
                Section {
                    SessionSpeciesSummary(passes: sessionPasses)
                } header: {
                    SessionChartHeader(title: "Species detected", kind: .species)
                }
                Section {
                    SessionActivityChart(passes: sessionPasses,
                                         start: session.startDate,
                                         end: session.endDate ?? Date())
                } header: {
                    SessionChartHeader(title: "Detections over time", kind: .timeline)
                }
            }
            if !session.notes.isEmpty {
                Section("Notes") { Text(session.notes) }
            }
            Section("Recordings") {
                if sessionRecordings.isEmpty {
                    Text(allSessionRecordings.isEmpty
                         ? "No recordings in this session."
                         : "Every recording here is unclassified (NoID) — turn on \"Show unclassified\" in the menu above to see them.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessionRecordings) { recording in
                        NavigationLink {
                            // Lazy: WavPlayerView's `@State` engine is expensive
                            // to construct — see LazyDestination.
                            LazyDestination {
                                WavPlayerView(recording: recording, store: store, micCalSettings: micCalSettings)
                            }
                        } label: {
                            RecordingRow(recording: recording, store: store, consent: consent)
                        }
                    }
                    .onDelete { offsets in offsets.map { sessionRecordings[$0] }.forEach(store.delete) }
                }
            }
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // A Toggle rather than a Button: inside a Menu it draws
                    // its own checkmark, which is what carries the on/off
                    // state now that the toolbar icon no longer can.
                    Toggle("Show unclassified", isOn: $showNoID)
                    Divider()
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
        }
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
            .background(RoundedRectangle(cornerRadius: 6).fill(.black))
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
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }
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
                .background(Color.orange.opacity(0.18), in: Capsule())
                .foregroundStyle(.orange)
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
