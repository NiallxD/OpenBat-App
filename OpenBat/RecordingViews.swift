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
    /// The second-place species line, once it has been worked out — see
    /// `runnerUpLine(in:)`. `nil` until then, and drawn as a blank line rather
    /// than as a claim, so the row's height never changes under the reader.
    @State private var runnerUp: String?
    /// How well this recording would serve as an iNaturalist observation, or
    /// nil while it is still being worked out. See `iNatBadge`.
    @State private var iNatRating: INatUploadAssessment.Rating?
    @State private var iNatPosted = false
    @Environment(FeatureFlagStore.self) private var flags
    @State private var postSignal = INatPostSignal.shared

    /// Wide enough that the picture reads as the square end of the row — the
    /// same width `GuideSpeciesRow` uses, because these rows sit in the same app
    /// and now look like the same object.
    private static let thumbnailWidth: CGFloat = 72

    var body: some View {
        // Full-bleed leading picture with the text laid over the space beside it,
        // the way the guide's species rows are built: the photo is drawn as a
        // `.background`, so it is handed the text block's own height and fills
        // the row whatever the caption does to it.
        text
            .padding(.vertical, 10)
            .padding(.trailing, 4)
            .padding(.leading, Self.thumbnailWidth + 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) { leadingImage }
            .task(id: recording.id) {
                // Off the render path: `passes(forRecording:)` scans every pass
                // in the library, and this row is one of a scrolling listful.
                // One fetch, two readers: `passes(forRecording:)` scans the
                // whole library, so asking twice per row would double the cost
                // of every scroll.
                let passes = store.passes(forRecording: recording)
                if !recording.isNoID && !recording.isUnidentified {
                    runnerUp = runnerUpLine(in: passes)
                }
                assessForINaturalist(passes)
                image = await RecordingThumbnailLoader.load(
                    recording, store: store,
                    maxPixelSize: RecordingThumbnailLoader.rowMaxPixelSize)
            }
            // Re-scored when something is posted from elsewhere in the app, so
            // a row stops advertising a recording that has just gone up. Guarded
            // on a non-zero count: this task also fires on first appearance,
            // where the one above has already done the work.
            .task(id: postSignal.changes) {
                guard postSignal.changes > 0 else { return }
                assessForINaturalist(store.passes(forRecording: recording))
            }
    }

    private var text: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                // **No species lines on a recording that was never
                // classified** (Niall, 2026-09-06), rather than sixty rows each
                // reading "Not identified" — the same dead phrase repeated down
                // a list says less than its absence does, and the launch notice
                // has already explained why. What is left is what the app still
                // knows for certain: how long it was, how many pulses, and when.
                //
                // It is the RECORDING that decides this, not the switch's
                // current position. A recording made while identification was
                // running carries a name that was genuinely computed from its
                // calls, and hiding it because the feature was later turned off
                // deletes a night's results from the user's view for a reason
                // that has nothing to do with that night (Niall, 2026-09-06,
                // reversing the blanket hide). Recordings made while the switch
                // is down are marked `UNID` when they are saved — see
                // `PassRecord.isUnidentified` — so they, and only they, get the
                // shorter row.
                if recording.isUnidentified {
                    Text(Self.time(recording.date)).font(.headline)
                    Text("\(Self.durationString(recording.durationSeconds)) · \(recording.pulseCount) pulse\(recording.pulseCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                HStack(spacing: 6) {
                    Text(recording.species).font(.headline)
                    Text("·").foregroundStyle(.secondary)
                    // Common name and confidence as one phrase, in the same
                    // plain type as the runner-up line below: the confidence
                    // belongs TO the name, and a coloured pill said it a second
                    // time in a way that competed with the iNaturalist leaf for
                    // the same corner of the row (Niall, 2026-09-04).
                    Text(confidenceLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Always a third line, whatever the row is. NoID rows carried
                // one and identified rows did not, so half the list was two
                // lines tall and half was three — and the taller ones had the
                // bigger picture (Niall, 2026-09-02). The runner-up is the
                // honest thing to put there: an ID is a choice between species,
                // and which one it nearly was is the most useful thing about it.
                Text(recording.isNoID ? "Triggered, but couldn't be classified" : (runnerUp ?? " "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Text("\(Self.durationString(recording.durationSeconds)) · \(recording.pulseCount) pulse\(recording.pulseCount == 1 ? "" : "s") · \(Self.time(recording.date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            uploadBadge
            // The iNaturalist mark, and NOT the confidence percentage beside it
            // (Niall, 2026-09-04, having tried both and then an outline). Two
            // trailing marks that both look like a verdict on the same
            // recording read as one confused thing, whichever two they are. The
            // percentage lost: it answers "how sure is the model", which the
            // row already implies and the detail screen states properly, while
            // this answers "should I do anything with this one", which is the
            // question a list of sixty recordings exists to answer.
            iNatBadge
        }
    }

    /// A leaf on the rows worth posting to iNaturalist, and nothing on the rest.
    ///
    /// **Only the good news is drawn.** The question this answers is "which of
    /// tonight's recordings should I do something with", and a list where every
    /// row carries a grade answers it much worse than one where four rows out of
    /// sixty have a leaf on them. Poor and blocked recordings say nothing at all
    /// rather than wearing a red mark — the full reasoning is one tap away on
    /// the observation sheet, which is where somebody has actually asked.
    ///
    /// **Three tiers, not two** (Niall, 2026-09-06). Excellent used to share the
    /// green filled leaf with Good, so the best recording of a night looked
    /// exactly like a merely solid one and the list could not answer "which is
    /// the BEST of these" — which is the question somebody with a nightly cap of
    /// two posts per species is actually asking. Gold, green, orange outline,
    /// and nothing below that.
    @ViewBuilder private var iNatBadge: some View {
        if iNatPosted {
            Image(systemName: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityLabel("Posted to iNaturalist")
        } else if let iNatRating {
            switch iNatRating {
            case .excellent:
                Image(systemName: "leaf.fill")
                    .font(.caption)
                    .foregroundStyle(Color.goldLeaf)
                    .accessibilityLabel("Worth posting to iNaturalist: excellent")
            case .good:
                Image(systemName: "leaf.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Worth posting to iNaturalist: good")
            case .fair:
                Image(systemName: "leaf")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Could be posted to iNaturalist: fair")
            case .poor, .blocked, .alreadyPosted:
                // `alreadyPosted` is drawn by the branch above, off the ledger.
                EmptyView()
            }
        }
    }

    /// Scores the recording for the badge above.
    ///
    /// Uses `estimatedUploadBytes` rather than actually trimming the file: the
    /// trim copies tens of megabytes, which is fine on a confirmation screen and
    /// impossible for a scrolling list. The estimate is the same arithmetic the
    /// trim performs, so the list and the sheet agree.
    private func assessForINaturalist(_ passes: [PassRecord]) {
        // Nothing to advertise while posting is switched off, and no reason to
        // pay for the scan — see `Feature.iNaturalistUpload`. Cleared rather
        // than left standing, so a switch thrown mid-session takes the badges
        // with it instead of leaving a leaf on a row that can no longer be
        // posted.
        guard flags.isEnabled(.iNaturalistUpload) else {
            iNatRating = nil
            iNatPosted = false
            return
        }
        // Cheapest question first: a posted recording draws the seal and needs
        // no score, so it never touches the filesystem.
        iNatPosted = INatPostLedger.hasPosted(recordingID: recording.id)
        guard !iNatPosted else { return }
        let fileBytes = (try? FileManager.default
            .attributesOfItem(atPath: store.wavURL(for: recording).path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        let bytes = INatUploadAssessment.estimatedUploadBytes(recording: recording,
                                                              passes: passes,
                                                              fileBytes: fileBytes)
        iNatRating = INatUploadAssessment.assess(recording: recording,
                                                 passes: passes,
                                                 uploadBytes: bytes).rating
    }

    /// "Common Pipistrelle 87%", or just the name where there is no figure to
    /// give — a NoID recording has no confidence, and a bare "0%" would read as
    /// a measurement rather than an absence.
    private var confidenceLine: String {
        guard let confidence = recording.confidence, !recording.isNoID else {
            return recording.commonName
        }
        return String(format: "%@ %.0f%%", recording.commonName, confidence * 100)
    }

    /// "Runner-up: Soprano Pipistrelle 22%", from the passes inside this
    /// recording, or a plain statement when there was no second candidate.
    ///
    /// Taken from the pass that agrees with the recording's own species where
    /// there is one — a recording can contain a pass that went the other way,
    /// and the runner-up worth showing is the runner-up to the ID on the row.
    /// Falls back to the strongest runner-up in the recording otherwise.
    private func runnerUpLine(in passes: [PassRecord]) -> String {
        let candidates = passes.filter { $0.runnerUpSpecies != nil }
        let best = candidates.first { $0.species == recording.species } ??
            candidates.max { ($0.runnerUpConfidence ?? 0) < ($1.runnerUpConfidence ?? 0) }
        guard let best, let code = best.runnerUpSpecies else { return "No close second species" }
        let name = SpeciesInfo.commonName[code] ?? code
        guard let confidence = best.runnerUpConfidence else { return "Runner-up: \(name)" }
        return String(format: "Runner-up: %@ %.0f%%", name, confidence * 100)
    }

    /// The species' photo where the guide has one for this code, the recording's
    /// own spectrogram where it does not.
    ///
    /// **The photo first, and the spectrogram as the fallback** (Niall,
    /// 2026-09-02): a row is a species sighting before it is a signal, and the
    /// picture is what makes a list of them scannable — the same reason the guide
    /// rows lead with one. NoID and NOISE have no guide page by construction, so
    /// they keep the spectrogram, which is the only thing there is to show for a
    /// recording that never resolved to a bat.
    @ViewBuilder private var leadingImage: some View {
        if let page = SpeciesInfo.guidePage(forCode: recording.species) {
            GuideSpeciesThumbnail(species: page, size: Self.thumbnailWidth, fillsHeight: true)
        } else {
            spectrogramThumbnail
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

    /// The spectrogram, filling the same leading tile the species photo would.
    @ViewBuilder private var spectrogramThumbnail: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay { Image(systemName: "waveform").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .frame(width: Self.thumbnailWidth)
        .frame(maxHeight: .infinity)
        .clipped()
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
            .pageBackground()
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

    /// Detections per species, commonest first. Shared with the session detail
    /// screen's map-side column, which shows the same tally without the bars.
    static func counts(for passes: [PassRecord]) -> [(species: String, commonName: String, count: Int)] {
        var byspecies: [String: (commonName: String, count: Int)] = [:]
        for pass in passes where !pass.isNoise && !pass.isNoID {
            byspecies[pass.species, default: (pass.commonName, 0)].count += 1
        }
        return byspecies
            .map { (species: $0.key, commonName: $0.value.commonName, count: $0.value.count) }
            .sorted { $0.count == $1.count ? $0.species < $1.species : $0.count > $1.count }
    }

    private var counts: [(species: String, commonName: String, count: Int)] {
        Self.counts(for: passes)
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
