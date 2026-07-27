//
//  SessionsView.swift
//  OpenBat
//
//  The Sessions area, split three ways:
//    • SessionsView      — list of field outings (RecordingSession), grouped by day
//    • SessionDetailView — one outing: GPS course on a map + species pins + its IDs
//    • ListeningView     — the flat "Just Listening" log of passes (no session/map)
//
//  All three share PassRow / PassDetailView so a field ID can still be traced back to
//  the per-pulse spectrogram evidence it was built from.
//

import SwiftUI
import MapKit

// MARK: - Sessions list

struct SessionsView: View {
    @Bindable var store: ClassificationStore
    let settings: AutoIDSettings
    let consent: ConsentStore
    @State private var selectedTab: SessionTab = .sessions
    /// Sessions queued by a swipe-delete, pending user confirmation (deleting a
    /// session irreversibly removes all its IDs and thumbnails).
    @State private var sessionsPendingDelete: [RecordingSession] = []
    /// Hides NoID recordings (triggered, but never classified confidently enough to
    /// call a species OR the model's own noise class) — shared with PlaybackListView
    /// and RecordingDetailView via the same UserDefaults key, off by default since a
    /// single-pulse-or-ambiguous trigger is mostly clutter to browse past.
    @AppStorage("display.showNoID") private var showNoID = false

    private enum SessionTab { case sessions, listening }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Sessions").tag(SessionTab.sessions)
                Text("Recordings").tag(SessionTab.listening)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            switch selectedTab {
            case .sessions:  sessionsContent
            case .listening: listeningContent
            }
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        // Flat black bar, matching every other section. This colour only fills the
        // bar's background — the glass material that used to composite over it
        // (reading as a grey header) is removed app-wide in
        // `OpenBatApp.configureNavigationBarAppearance`, and `flatTopScrollEdge`
        // drops the scroll-edge scrim this section's list would otherwise add.
        .toolbarBackground(Color.black, for: .navigationBar)
        .flatTopScrollEdge()
        .toolbar {
            // Only filters `filteredListeningRecordings` (the Recordings tab) —
            // sessionsContent doesn't read `showNoID` at all, so the toggle has
            // no effect on the Sessions tab and stays hidden there.
            if selectedTab == .listening {
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: $showNoID) {
                        Image(systemName: showNoID ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .toggleStyle(.button)
                    .accessibilityLabel(showNoID ? "Hide unclassified recordings" : "Show unclassified recordings")
                }
            }
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
            Text("The GPS track and every ID logged in this session will be removed. This can't be undone.")
        }
    }

    @ViewBuilder private var sessionsContent: some View {
        if store.sessions.isEmpty {
            ContentUnavailableView(
                "No sessions yet",
                systemImage: "square.stack.3d.up",
                description: Text("Tap Start ▸ New Session to log IDs and a GPS track on a map.")
            )
        } else {
            List {
                ForEach(groupSessionsByDay(store.sessions), id: \.key) { group in
                    Section(group.title) {
                        ForEach(group.sessions) { session in
                            NavigationLink {
                                SessionDetailView(session: session, store: store, settings: settings, consent: consent)
                            } label: {
                                SessionRow(session: session, store: store)
                            }
                        }
                        .onDelete { offsets in
                            sessionsPendingDelete = offsets.map { group.sessions[$0] }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var filteredListeningRecordings: [Recording] {
        store.listeningRecordings.filteredByNoID(showNoID: showNoID)
    }

    @ViewBuilder private var listeningContent: some View {
        if store.listeningRecordings.isEmpty {
            ContentUnavailableView(
                "No recordings yet",
                systemImage: "waveform.badge.magnifyingglass",
                description: Text("Recordings made while Just Listening (with recording turned on) appear here.")
            )
        } else if filteredListeningRecordings.isEmpty {
            ContentUnavailableView(
                "No classified recordings",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Every recording here is unclassified (NoID) — tap the filter icon to show them.")
            )
        } else {
            List {
                ForEach(groupRecordingsByDay(filteredListeningRecordings), id: \.key) { group in
                    Section(group.title) {
                        ForEach(group.recordings) { recording in
                            NavigationLink {
                                RecordingDetailView(recording: recording, store: store)
                            } label: {
                                RecordingRow(recording: recording, store: store, consent: consent)
                            }
                        }
                        .onDelete { offsets in offsets.map { group.recordings[$0] }.forEach(store.delete) }
                    }
                }
            }
            .listStyle(.insetGrouped)
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
            SessionMapThumbnail(track: session.track.map(\.coordinate))
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).font(.headline).lineLimit(1)
                Text(timeRange).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Label("\(passes.count) ID\(passes.count == 1 ? "" : "s")",
                          systemImage: "waveform.badge.magnifyingglass")
                    if let top = dominantSpecies(passes) { Text("· \(top)") }
                    if !session.track.isEmpty {
                        Label("GPS", systemImage: "location.fill")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var timeRange: String {
        let f = DateFormatter(); f.timeStyle = .short
        let start = f.string(from: session.startDate)
        guard let end = session.endDate else { return "\(start) – now" }
        return "\(start) – \(f.string(from: end))"
    }

    private func dominantSpecies(_ passes: [PassRecord]) -> String? {
        let counts = Dictionary(grouping: passes, by: \.species).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key
    }
}

/// Small non-interactive GPS-track preview for a session row — same slot/size as
/// RecordingRow's spectrogram thumbnail. Disabled interaction so a tap still
/// reaches the enclosing NavigationLink instead of panning the mini-map.
private struct SessionMapThumbnail: View {
    let track: [CLLocationCoordinate2D]
    static let size = CGSize(width: 56, height: 40)

    var body: some View {
        Group {
            if track.isEmpty {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .overlay { Image(systemName: "location.slash").font(.caption2).foregroundStyle(.secondary) }
            } else {
                Map(initialPosition: .region(fittedRegion(for: track)), interactionModes: []) {
                    MapPolyline(coordinates: track).stroke(.blue, lineWidth: 2)
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
    @AppStorage("display.showNoID") private var showNoID = false

    var body: some View {
        List {
            if hasGeo {
                Section {
                    SessionMap(track: trackCoords, pins: mappablePasses)
                        .frame(height: 240)
                        .listRowInsets(EdgeInsets())
                }
                if !mappablePasses.isEmpty {
                    Text("\(mappablePasses.count) pinned of \(sessionPasses.count) ID\(sessionPasses.count == 1 ? "" : "s") (≥ \(Int(settings.mapPinMinConfidence * 100))% · ≥ \(settings.mapPinMinPulseCount) pulses)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            if !session.notes.isEmpty {
                Section("Notes") { Text(session.notes) }
            }
            if !sessionPasses.isEmpty {
                Section("Species") {
                    SessionSpeciesSummary(passes: sessionPasses)
                }
            }
            Section("Recordings") {
                if sessionRecordings.isEmpty {
                    Text(store.recordings(inSession: session.id).isEmpty
                         ? "No recordings in this session."
                         : "Every recording here is unclassified (NoID) — tap the filter icon to show them.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessionRecordings) { recording in
                        NavigationLink {
                            RecordingDetailView(recording: recording, store: store)
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
                Toggle(isOn: $showNoID) {
                    Image(systemName: showNoID ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .toggleStyle(.button)
                .accessibilityLabel(showNoID ? "Hide unclassified recordings" : "Show unclassified recordings")
            }
        }
    }

    private var sessionPasses: [PassRecord] { store.passes(inSession: session.id) }
    private var sessionRecordings: [Recording] {
        store.recordings(inSession: session.id).filteredByNoID(showNoID: showNoID)
    }
    private var mappablePasses: [PassRecord] { sessionPasses.filter(settings.isMappable) }
    private var trackCoords: [CLLocationCoordinate2D] { session.track.map(\.coordinate) }
    private var hasGeo: Bool { !trackCoords.isEmpty || !mappablePasses.isEmpty }
}

/// The course polyline plus a species pin per high-quality ID, framed to fit them all.
private struct SessionMap: View {
    let track: [CLLocationCoordinate2D]
    let pins: [PassRecord]

    var body: some View {
        Map(initialPosition: .region(region)) {
            if track.count > 1 {
                MapPolyline(coordinates: track).stroke(.blue, lineWidth: 3)
            }
            ForEach(pins) { pass in
                if let c = pass.coordinate {
                    Marker(pass.species, systemImage: "waveform", coordinate: c)
                        .tint(.orange)
                }
            }
        }
    }

    private var region: MKCoordinateRegion {
        fittedRegion(for: track + pins.compactMap(\.coordinate))
    }
}


// MARK: - Day grouping (shared)

private struct PassDayGroup { let key: Date; let title: String; let passes: [PassRecord] }
private func groupPassesByDay(_ passes: [PassRecord]) -> [PassDayGroup] {
    let cal = Calendar.current
    let dict = Dictionary(grouping: passes) { cal.startOfDay(for: $0.date) }
    return dict.keys.sorted(by: >).map { day in
        PassDayGroup(key: day, title: dayTitle(day),
                     passes: dict[day]!.sorted { $0.date > $1.date })
    }
}

private struct RecordingDayGroup { let key: Date; let title: String; let recordings: [Recording] }
private func groupRecordingsByDay(_ recordings: [Recording]) -> [RecordingDayGroup] {
    let cal = Calendar.current
    let dict = Dictionary(grouping: recordings) { cal.startOfDay(for: $0.date) }
    return dict.keys.sorted(by: >).map { day in
        RecordingDayGroup(key: day, title: dayTitle(day),
                          recordings: dict[day]!.sorted { $0.date > $1.date })
    }
}

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
    let f = DateFormatter(); f.dateStyle = .medium
    return f.string(from: date)
}

// MARK: - Pass row

struct PassRow: View {
    let pass: PassRecord
    let store: ClassificationStore

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
    }

    @ViewBuilder private var thumbnail: some View {
        if let img = store.image(for: representativePulse) {
            Image(uiImage: img)
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

    private var representativePulse: PulseRecord {
        pass.pulses.max(by: { $0.confidence < $1.confidence }) ?? pass.pulses[0]
    }

    private static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .medium; return f.string(from: d)
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
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium
        return f.string(from: d)
    }
}

// MARK: - Pulse detail row

private struct PulseDetailRow: View {
    let pulse: PulseRecord
    let store: ClassificationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let img = store.image(for: pulse) {
                PulseImagePlot(image: img,
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
/// names the close alternative ("cf. MYYU"); otherwise it just flags the complex.
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
            return "cf. \(runnerUp)"
        }
        return "complex"
    }

    private var accessibility: String {
        if pass.isComplexAmbiguous, let runnerUp = pass.runnerUpSpecies {
            return "Confusable with \(SpeciesInfo.commonName[runnerUp] ?? runnerUp)"
        }
        return "Part of a species complex that is hard to separate acoustically"
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
