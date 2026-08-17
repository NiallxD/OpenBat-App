//
//  RecordingViews.swift
//  OpenBat
//
//  UI for `Recording` — the WAV-backed unit AudioRecorder's bout-based trigger
//  produces (see Context.md §10). Shown two places:
//    • the Recordings tab's list (SessionsView.listeningContent)
//    • a session's recordings list (SessionsView.SessionDetailView)
//  Both open the same destination — WavPlayerView, the player — and the
//  finer-grained per-pulse IDs (PassRecord/PulseRecord, PulseDetector's own
//  "one run of pulses" grouping) that happened during the recording's time span
//  are a sheet over it: RecordingPulsesSheet, below.
//

import SwiftUI

/// Cached formatters — `DateFormatter()` init is expensive (locale/calendar setup),
/// and these are read once per row per list body evaluation.
private enum RecordingDateFormatters {
    static let timeMedium: DateFormatter = { let f = DateFormatter(); f.timeStyle = .medium; return f }()
    static let dateTimeMedium: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium; return f
    }()
}

// MARK: - Thumbnail loading

/// Fills in a Recording's spectrogram image without ever blocking the view it
/// belongs to.
///
/// The awkward part is the reinstall case: the library (recordings.json) syncs
/// back from iCloud almost immediately, but the spectrogram JPEGs arrive
/// gradually afterwards, so a first pass over a screenful of rows legitimately
/// finds nothing to decode. `ClassificationStore.load` reports that as
/// `awaitingDownload` rather than reading the placeholder (which is what used to
/// block), and this retries on a backing-off clock so thumbnails trickle in as
/// their bytes land instead of the list appearing frozen until they all have.
/// Cancellation is SwiftUI's: `.task(id:)` tears this down when the row goes away,
/// so an offscreen row stops polling on its own.
enum RecordingThumbnailLoader {
    /// Longer edge to decode for a list row's 56 × 40 slot. `.fill` of a 4:1
    /// spectrogram scales to the slot's HEIGHT, so ~480 px of width is what
    /// actually gets sampled at @3x — 512 is that, rounded, and ~1/64th the
    /// pixels of the stored 4096-wide original.
    static let rowMaxPixelSize: CGFloat = 512

    @MainActor
    static func load(_ recording: Recording, store: ClassificationStore,
                     maxPixelSize: CGFloat) async -> UIImage? {
        var delay = Duration.seconds(1)
        while !Task.isCancelled {
            switch await store.loadSpectrogramImage(for: recording, maxPixelSize: maxPixelSize) {
            case .loaded(let image):
                return image
            case .unavailable:
                return nil
            case .awaitingDownload:
                do { try await Task.sleep(for: delay) } catch { return nil }
                delay = min(delay * 2, .seconds(20))
            }
        }
        return nil
    }
}

// MARK: - Row

struct RecordingRow: View {
    let recording: Recording
    let store: ClassificationStore
    let consent: ConsentStore
    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(recording.species).font(.headline)
                    Text("·").foregroundStyle(.secondary)
                    Text(recording.commonName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if recording.isNoID {
                    Text("Triggered, but couldn't be classified")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text("\(Self.durationString(recording.durationSeconds)) · \(recording.pulseCount) pulse\(recording.pulseCount == 1 ? "" : "s") · \(Self.time(recording.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            uploadBadge
            if let confidence = recording.confidence {
                ConfidenceBadge(confidence: confidence)
            }
        }
        .padding(.vertical, 2)
        .task(id: recording.id) {
            image = await RecordingThumbnailLoader.load(
                recording, store: store,
                maxPixelSize: RecordingThumbnailLoader.rowMaxPixelSize)
        }
    }

    /// Tapping this IS how a recording gets uploaded now — there's no separate
    /// "Upload Now" sweep. `.borderless` so tapping the badge doesn't also fire
    /// the row's own NavigationLink.
    @ViewBuilder private var uploadBadge: some View {
        if ConsentStore.uploadContributionEnabled {
            uploadBadgeContent
        }
    }

    @ViewBuilder private var uploadBadgeContent: some View {
        switch recording.uploadStatus?.phase {
        case .uploaded:
            Image(systemName: "checkmark.icloud.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityLabel("Uploaded")
        case .converting, .encoding, .uploading:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Uploading")
        case .queued, .failed:
            // Gated on consent like every other branch: without this the button
            // still appeared after contribution was turned off, and tapping it
            // ran the pipeline only to hit the consent guard and silently flip
            // the badge to "not contributing" with no explanation.
            if consent.isGranted { uploadButton }
        case .rejected:
            // Was EmptyView, which made "this can never be uploaded" and "this
            // hasn't been assessed" look identical. The reason is the useful
            // part, so it's carried in the accessibility label and shown in full
            // on the recording's detail page.
            Image(systemName: "xmark.icloud")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Not eligible to upload: \(recording.uploadStatus?.reason ?? "unknown reason")")
        case .notContributing, nil:
            // `nil` covers every recording made before RecordingUploader's
            // eligibility gates existed (or before this device relaunched with
            // them) — it was simply never assessed, not found ineligible. Rather
            // than leave it permanently badge-less, re-check the SAME criteria
            // live: `.notContributing` also covers this correctly for a
            // recording that failed the consent/confidence gate when it was
            // SAVED but would pass now (consent since turned on). Either way,
            // tapping runs it through the real pipeline for the first time.
            if meetsUploadCriteriaNow {
                uploadButton
            }
        }
    }

    private var meetsUploadCriteriaNow: Bool {
        consent.isGranted
            && recording.species != "NOID"
            && (recording.confidence ?? 0) >= RecordingUploader.minUploadConfidence
            && recording.durationSeconds <= RecordingUploader.maxUploadDurationSeconds
    }

    private var uploadButton: some View {
        Button {
            RecordingUploader.shared.uploadNow(recording)
        } label: {
            Image(systemName: "icloud.and.arrow.up")
                .font(.caption)
                .foregroundStyle(.blue)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Upload this recording")
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

    static func time(_ d: Date) -> String {
        RecordingDateFormatters.timeMedium.string(from: d)
    }

    static func durationString(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s < 60 ? "\(s)s" : String(format: "%dm %02ds", s / 60, s % 60)
    }
}

// MARK: - Pulses sheet

/// The per-pulse ID evidence behind one recording, presented as a sheet from the
/// player's "Pulses" button (see WavPlayerView.fileInfoBlock).
///
/// This used to be a pushed page of its own (RecordingDetailView) that a
/// recording row opened INSTEAD of the player — so listening to a recording and
/// seeing what was ID'd in it were two different destinations, and the one you
/// landed on depended on which list you tapped from. A recording row now always
/// opens the player, and this is a sheet over it. The whole-file spectrogram
/// that used to head this page is gone with the push: the player draws the same
/// thing, zoomable, right behind this sheet.
struct RecordingPulsesSheet: View {
    let recording: Recording
    @Bindable var store: ClassificationStore
    /// Shared with SessionsView via the same UserDefaults key.
    @AppStorage("display.showNoID") private var showNoID = false
    @Environment(\.dismiss) private var dismiss

    /// Every pass whose pulses fall inside this recording's time span — the
    /// per-pulse ID detail, same rows/detail screen the rest of the app uses.
    /// Filtered the same way the Recording lists are: a sub-pass within an
    /// otherwise-real recording can itself be NoID (e.g. one clean approach plus
    /// one ambiguous one nearby).
    private var recordingPasses: [PassRecord] {
        store.passes(forRecording: recording).filteredByNoID(showNoID: showNoID)
    }

    var body: some View {
        // Its own stack: a pass row still pushes PassDetailView, and this is
        // presented over a player that is itself inside the Sessions stack.
        NavigationStack {
            List {
                Section {
                    LabeledContent("Species") { Text("\(recording.species) · \(recording.commonName)") }
                    if let confidence = recording.confidence {
                        LabeledContent("Confidence") {
                            Text(String(format: "%.0f%%", confidence * 100))
                        }
                    }
                    LabeledContent("Duration") { Text(RecordingRow.durationString(recording.durationSeconds)) }
                    LabeledContent("Recorded") { Text(Self.fullTimestamp(recording.date)) }
                }

                Section("Pulses & IDs") {
                    if recordingPasses.isEmpty {
                        Text(store.passes(forRecording: recording).isEmpty
                             ? "No classified pulses in this recording."
                             : "Every pulse here is unclassified (NoID) — tap the filter icon to show them.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recordingPasses) { pass in
                            NavigationLink {
                                PassDetailView(pass: pass, store: store)
                            } label: {
                                PassRow(pass: pass, store: store)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pulses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The same filter the recording lists carry, on the same shared
                // key — without it, a recording whose passes are all NoID opens
                // an empty sheet with the only remedy two screens away.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNoID.toggle()
                    } label: {
                        Image(systemName: showNoID ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .foregroundStyle(showNoID ? .blue : .primary)
                    }
                    .accessibilityLabel(showNoID ? "Hide unclassified pulses" : "Show unclassified pulses")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private static func fullTimestamp(_ d: Date) -> String {
        RecordingDateFormatters.dateTimeMedium.string(from: d)
    }
}

// MARK: - Session species summary

/// Bar-chart summary of every species ID'd in a session — same `ScoreBar` visual
/// language as a single pulse's candidate scores, but counting DETECTIONS (passes)
/// across the whole outing instead of one pulse's per-species confidence. NOISE and
/// NOID passes are excluded (they're not species IDs).
struct SessionSpeciesSummary: View {
    let passes: [PassRecord]

    private var counts: [(species: String, commonName: String, count: Int)] {
        var byspecies: [String: (commonName: String, count: Int)] = [:]
        for pass in passes where !pass.isNoise && !pass.isNoID {
            byspecies[pass.species, default: (pass.commonName, 0)].count += 1
        }
        return byspecies
            .map { (species: $0.key, commonName: $0.value.commonName, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    var body: some View {
        let rows = counts
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows, id: \.species) { row in
                    SpeciesCountBar(species: row.species, count: row.count,
                                   maxCount: rows.first?.count ?? 1)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct SpeciesCountBar: View {
    let species: String
    let count: Int
    let maxCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(species)
                .font(.system(size: 11, weight: .medium).monospaced())
                .frame(width: 46, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint)
                        .frame(width: max(3, geo.size.width * CGFloat(count) / CGFloat(max(maxCount, 1))))
                }
            }
            .frame(height: 7)
            Text("\(count)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
    }
}
