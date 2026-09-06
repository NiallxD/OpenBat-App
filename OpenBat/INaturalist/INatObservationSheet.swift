//
//  INatObservationSheet.swift
//  OpenBat
//
//  The confirmation screen: what OpenBat is about to claim, where, and with
//  what evidence — then one button that posts it.
//
//  NOTHING IS EVER POSTED WITHOUT A TAP HERE
//  -----------------------------------------
//  There is no background posting, no "upload the night", no queue that drains
//  on its own. An observation exists because somebody read this screen and
//  pressed the button, which is the only honest way to put a machine
//  identification into a public record other people's research draws on.
//
//  THE MANUAL ROUTE IS STILL AT THE BOTTOM
//  ---------------------------------------
//  Signed out, offline, or simply preferring to do it themselves, the user can
//  still take the files and paste the text into iNaturalist's web uploader —
//  the route that worked before there was an API key, kept because it needs no
//  account and nothing can break it. The website, not the iPhone app: iNat's
//  app can record a sound but cannot import one, so it is structurally unable
//  to carry an acoustic record.
//
//  The order of the sections is the order of iNaturalist's own new-observation
//  screen — what, then when, then where, then notes — so the manual route can
//  still be worked down the page with the two apps side by side.
//

import SwiftUI
import AuthenticationServices

struct INatObservationSheet: View {
    let observation: INatObservation
    /// Needed alongside the built observation because trimming and scoring both
    /// work off the classifier's own output — where the calls are, how many
    /// there were, and how well they agreed. See `INatUploadAssessment`.
    let recording: Recording
    let passes: [PassRecord]
    let wavURL: URL
    /// What the pictures are built from — gathered by the player, rendered
    /// here. See `INatImages`.
    let imageSources: INatImageSources
    /// The player's own full-range overview, kept only as the fallback for when
    /// the cropped render fails.
    let overviewPNG: Data?
    @Environment(\.dismiss) private var dismiss
    /// SwiftUI's own wrapper around ASWebAuthenticationSession — see the note
    /// in `INatAuth` about why the view presents the browser and not the model.
    @Environment(\.webAuthenticationSession) private var webAuthentication

    @State private var auth = INatAuth.shared
    @State private var uploads = INatUploadManager.shared
    @State private var shareFiles: ShareFiles?
    @State private var copied: String?
    @State private var geoprivacy = INatGeoprivacy.obscured
    @State private var signingIn = false
    @State private var authError: String?
    @State private var showPostBriefing = false
    /// Remembered between recordings: somebody who prefers doing it by hand
    /// prefers it every time, and being put back on the automatic route on
    /// every sheet would be a small insult each time.
    @AppStorage("openbat.inat.sheetMode") private var mode = Mode.auto

    private enum Mode: String { case auto, manual }

    /// Built in `.task` — see `INatExport.prepareFiles`, which copies and
    /// rewrites tens of megabytes and must not run on the main actor.
    @State private var files: INatExport.Files?
    /// nil until `files` is ready — the score can't be known before the trim
    /// is, because the size of the trimmed file is one of its inputs.
    @State private var assessment: INatUploadAssessment?
    @State private var photos: [INatImages.Photo] = []
    /// Decoded once for the preview. `UIImage(data:)` on every body pass would
    /// re-decode a dozen PNGs each time the list scrolled.
    ///
    /// Index-aligned with `photos`, which is why it holds optionals rather than
    /// being compacted: a single picture that failed to decode would otherwise
    /// shift every index after it, and each thumbnail would be captioned and
    /// removed as if it were the next one along.
    @State private var previews: [UIImage?] = []
    /// Pictures the user has taken out of the upload, by filename.
    ///
    /// Kept out rather than deleted, so the decision is reversible: a tile
    /// removed by mistake would otherwise mean closing the sheet and waiting
    /// for every picture to be rendered again.
    @State private var excluded: Set<String> = []

    private struct ShareFiles: Identifiable { let id = UUID(); let urls: [URL] }

    var body: some View {
        NavigationStack {
            List {
                modeSection
                if mode == .auto {
                    assessmentSection.tileRow()
                    previewSection.tileRow()
                } else {
                    manualSection.tileRow()
                }
                taxonSection.tileRow()
                whenAndWhereSection.tileRow()
                notesSection.tileRow()
                fieldsSection.tileRow()
            }
            // The app's own list material rather than a grouped list's: see
            // `TileCard`. A grouped list would draw a second container around
            // every card and, on `pageBackground()`, draw it in a colour that
            // disappears in light mode.
            .listStyle(.plain)
            .contentMargins(.top, TileList.scrollTopMargin, for: .scrollContent)
            .pageBackground()
            .navigationTitle("Add to iNaturalist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { postBar }
            .sheet(item: $shareFiles) { share in
                ShareSheet(items: share.urls)
            }
            .alert("Before you post", isPresented: $showPostBriefing) {
                Button("Back", role: .cancel) { }
                Button("Post") { post(briefed: true) }
            } message: {
                Text(Self.briefing)
            }
            .task {
                let url = wavURL
                let png = overviewPNG
                let start = recording.date
                let pulses = passes.flatMap(\.pulses)
                let baseName = url.deletingPathExtension().lastPathComponent
                // One answer to "where are the calls", shared by where the
                // segment is cut, where the audible copy is spliced and where
                // the whole-pass picture's gaps are — see
                // `INatImages.silenceMap`.
                let silence = await INatImages.silenceMap(sources: imageSources)

                // The bat pass, cut out of the recording in its own real time.
                // Everything below is made from THIS, not from the file on
                // disk, so no picture can be of audio nobody was sent.
                let segment = await Task.detached(priority: .userInitiated) {
                    INatExport.passSegment(wavURL: url,
                                           recordingStart: start,
                                           pulses: pulses,
                                           silence: silence,
                                           byteBudget: INatCredentials.maxSoundBytes,
                                           baseName: baseName)
                }.value

                var prepared: INatExport.Files
                let sources: INatImageSources
                if let segment {
                    sources = await imageSources.rebased(on: segment)
                    prepared = await Task.detached(priority: .userInitiated) {
                        INatExport.prepareFiles(segment: segment, baseName: baseName)
                    }.value
                } else {
                    // Unreadable, or not the canonical layout every reader here
                    // assumes. The recording still goes up whole; the size
                    // blocker catches it if it is too big.
                    sources = imageSources
                    prepared = INatExport.Files(audible: nil, photos: [], original: url, upload: url)
                }

                // The pictures, and copies of them on disk so the manual
                // uploader route offers exactly what the API route would send.
                photos = await INatImages.render(sources: sources,
                                                 pulses: pulses,
                                                 fallbackPNG: png,
                                                 silence: segment?.silence ?? silence)
                previews = photos.map { UIImage(data: $0.data) }
                // Named after the recording, exactly as the two sounds are
                // (Niall, 2026-09-06). These used to carry the recording's UUID
                // instead, so a saved folder held six files under two unrelated
                // names, sorted apart, one of them a hex string that means
                // nothing to anybody. Those filenames are what somebody reads
                // while attaching the files on iNaturalist's website, and since
                // saving them is now the whole of the manual route, they are
                // most of that screen's output.
                //
                // The UUID was there to stop two recordings colliding in the
                // temporary directory. `baseName` is the WAV's own filename —
                // a timestamp to the millisecond plus the species — so it is
                // unique for the same reason the recording file itself is.
                prepared.photos = photos.compactMap { photo in
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(baseName)-\(photo.name)")
                    guard (try? photo.data.write(to: url)) != nil else { return nil }
                    return url
                }
                files = prepared

                // Reverberation, measured on the segment — the audio that
                // actually goes up — and after the pictures, so the sheet fills
                // in rather than waiting on an FFT per call.
                let echoURL = sources.wavURL
                let echoStart = sources.recordingStart
                let rate = sources.sampleRate
                let curve = sources.calibrationCurve
                let echo = await Task.detached(priority: .userInitiated) {
                    EchoAnalysis.measure(wavURL: echoURL, sampleRate: rate,
                                         segmentStart: echoStart, pulses: pulses,
                                         calibrationCurve: curve)
                }.value

                assessment = INatUploadAssessment.assess(recording: recording,
                                                         passes: passes,
                                                         uploadBytes: prepared.uploadBytes,
                                                         echo: echo)
            }
        }
    }

    // MARK: Posting

    /// Pinned rather than placed in the list, so the thing that actually
    /// creates a public record can't be scrolled past and pressed by accident
    /// on the way somewhere else.
    @ViewBuilder
    private var postBar: some View {
        if mode == .manual {
            // The manual route posts nothing; its actions are its own section.
            EmptyView()
        } else {
            VStack(spacing: 8) {
                if let authError {
                    Text(authError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let assessment, assessment.overridden {
                    // Loud on purpose: this state only exists behind the Debug
                    // menu, and posting from it puts a record iNaturalist's
                    // rules would have stopped onto a real account.
                    Label("Posting limits overridden in Debug", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity)
                }

                if let assessment, !assessment.canPost {
                    // No "post anyway". Every blocker is a case where the
                    // record would be useless or unwelcome, and the manual
                    // uploader below is the deliberate way past it.
                    Label(assessment.rating.rawValue,
                          systemImage: assessment.alreadyPosted ? "checkmark.seal.fill" : "hand.raised.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(assessment.alreadyPosted ? Color.green : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                } else if auth.isSignedIn {
                    Button {
                        post()
                    } label: {
                        Label("Post to iNaturalist", systemImage: "arrow.up.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    // Orange, which is the colour the recording list already
                    // uses to mean "this one is worth sending" — so the mark on
                    // the row and the button that acts on it are the same idea
                    // in the same colour. Not the accent, which is every other
                    // button in the app, and not red, which would read as a
                    // warning about an action the user has chosen.
                    .tint(.orange)
                    .disabled(files == nil)
                    Text("Posts to your own iNaturalist account, as \(observation.taxonName), \(geoprivacy.label.lowercased()) location.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        signIn()
                    } label: {
                        Group {
                            if signingIn {
                                HStack(spacing: 8) { ProgressView(); Text("Signing in…") }
                            } else {
                                Label("Sign in to iNaturalist", systemImage: "person.crop.circle")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(signingIn)
                    Text("On iNaturalist's own page. OpenBat never sees your password.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            // Centred once here rather than per line: the bar is a single
            // column of statements about one action, and a mix of centred and
            // leading text in a stack that narrow reads as a mistake.
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    private func signIn() {
        signingIn = true
        authError = nil
        Task {
            defer { signingIn = false }
            let request = auth.beginSignIn()
            do {
                let callback = try await webAuthentication.authenticate(
                    using: request.url,
                    callbackURLScheme: INatCredentials.callbackScheme)
                try await auth.finishSignIn(callback: callback, request: request)
            } catch is ASWebAuthenticationSessionError {
                // Dismissing the browser is a decision, not a failure: saying
                // "sign-in failed" to somebody who just changed their mind is
                // noise.
                return
            } catch {
                authError = error.localizedDescription
            }
        }
    }

    /// The etiquette briefing, shown before EVERY post (Niall, 2026-09-04).
    ///
    /// It was written to appear once, on the reasoning that repeated advice
    /// gets tapped through — overruled, and the reason is sound: every post is
    /// a permanent public record that somebody else will have to check, so the
    /// pause belongs in front of all of them, not just the first. A user who
    /// knows the text by heart is a user who has read it.
    ///
    /// None of the rules depend on it being read. The cap and the blockers are
    /// enforced in `INatUploadAssessment` either way; this is the courtesy of
    /// saying why before somebody runs into one.
    static let briefing = """
        Every record on iNaturalist is checked by the community. Upload quality \
        over quantity.

        Location is obscured to protect species locations.

        OpenBat uploads to genus level only — the community can help improve that.
        """

    /// `briefed` is set only by the alert's own Post button, which is the one
    /// path that has already shown the briefing. Everything else routes through
    /// the alert first.
    private func post(briefed: Bool = false) {
        guard let files else { return }
        guard briefed else {
            showPostBriefing = true
            return
        }
        // Handed to `INatUploadManager` and forgotten. The work outlives this
        // sheet on purpose — a post is tens of megabytes over a field's signal,
        // and it used to die the moment somebody dismissed the screen they had
        // already finished with.
        uploads.post(INatUploadManager.Input(recording: recording,
                                             observation: observation,
                                             geoprivacy: geoprivacy,
                                             photos: includedPhotos,
                                             sounds: files.sounds))
        dismiss()
    }

    // MARK: Sections

    /// The first thing on the screen, before the taxon or the map, because the
    /// question it answers — should this be posted at all? — comes before every
    /// other question on the page.
    @ViewBuilder
    private var assessmentSection: some View {
        TileCard("Worth posting?", "Volunteers check every record.") {
            if let assessment {
                HStack(alignment: .firstTextBaseline) {
                    Text(assessment.rating.rawValue)
                        .font(.headline)
                        .foregroundStyle(colour(for: assessment.rating))
                    Spacer()
                    if assessment.canPost {
                        Text("\(assessment.score)/100")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(assessment.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(assessment.blockers, id: \.self) { blocker in
                    Label(blocker, systemImage: "xmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(.primary)
                }
                ForEach(assessment.notes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) { ProgressView(); Text("Checking the recording…") }
            }
        }
    }

    private func colour(for rating: INatUploadAssessment.Rating) -> Color {
        switch rating {
        case .alreadyPosted: return .green
        case .blocked: return .red
        case .poor: return .orange
        case .fair: return .yellow
        case .good, .excellent: return .green
        }
    }

    /// The two routes, named for what they do rather than for how they work.
    ///
    /// "By hand" is not a fallback here, it is a choice — it needs no account,
    /// nothing about it can break, and some people would simply rather build
    /// the observation themselves in iNaturalist's own uploader. The automatic
    /// route is the default because it is the one that gets records posted at
    /// the moment somebody is standing in a field looking at the call.
    private var modeSection: some View {
        Picker("How", selection: $mode) {
            Text("Post from OpenBat").tag(Mode.auto)
            Text("Do it by hand").tag(Mode.manual)
        }
        .pickerStyle(.segmented)
        // Not a card, and not drawn as one: it chooses which cards follow, so
        // it takes the tile gutter for alignment and none of the tile's air.
        .listRowInsets(EdgeInsets(top: 0, leading: TileList.contentInset,
                                  bottom: 2, trailing: TileList.contentInset))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// Exactly what is about to be uploaded, in the order it will appear.
    ///
    /// **Because an observation is permanent and public.** Every other
    /// confirmation on this screen is text — a species, a time, a place — and
    /// the pictures are the part a reader will actually judge, so they are the
    /// part most worth checking before it goes. It also catches the failures
    /// that text cannot describe: a close-up centred on the wrong call, a tile
    /// of empty noise, a spectrogram cropped to the wrong band.
    @ViewBuilder
    private var previewSection: some View {
        TileCard("What gets posted", previews.isEmpty
                 ? "Checking."
                 : "\(includedPhotos.count) pictures, then the sound, in this order.") {
            if previews.isEmpty {
                HStack(spacing: 8) { ProgressView(); Text("Preparing the pictures…") }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(previews.enumerated()), id: \.offset) { index, image in
                            if let image {
                                previewThumbnail(image, name: photos[index].name)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityLabel("\(includedPhotos.count) pictures will be posted")
            }

            if let files {
                // The two sounds by what they are, and nothing about bytes:
                // trimming and file sizes are how the feature works, not
                // something a person deciding whether to post needs to weigh.
                ForEach(Array(files.sounds.enumerated()), id: \.offset) { index, _ in
                    Label(index == 0
                          ? "Cleaned up and slowed \(INatExport.expansionFactor)× so you can hear it"
                          : "The pass as recorded, full speed and bandwidth",
                          systemImage: "waveform")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The numbered headers exist so the manual route can be worked down the
    /// page with iNaturalist's uploader open beside it. On the automatic route
    /// there is nothing to work through in order — the numbers would read as a
    /// checklist of things the user has to do, when the whole point is that
    /// they don't.
    private func step(_ number: Int, _ title: String) -> String {
        mode == .manual ? "\(number) · \(title)" : title
    }

    /// One picture in the strip, with the control that takes it out.
    ///
    /// **Excluded rather than deleted, and still on screen.** A tile that
    /// vanished on a mistaken tap would leave no way back except closing the
    /// sheet and waiting for everything to render again — so it stays, faded,
    /// with the same button now offering to put it back. The number under it
    /// disappears while it is out, because the numbers are upload positions and
    /// an excluded picture does not have one.
    private func previewThumbnail(_ image: UIImage, name: String) -> some View {
        let isOut = excluded.contains(name)
        return VStack(spacing: 4) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(isOut ? 0.3 : 1)
                .overlay(alignment: .topLeading) {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            if isOut { excluded.remove(name) } else { excluded.insert(name) }
                        }
                    } label: {
                        Image(systemName: isOut ? "plus.circle.fill" : "xmark.circle.fill")
                            .font(.body)
                            .symbolRenderingMode(.palette)
                            // White glyph on a dark disc: these sit on
                            // spectrograms, which are black in some corners and
                            // bright yellow in others, and a single-colour
                            // symbol disappears into one or the other.
                            .foregroundStyle(.white, .black.opacity(0.6))
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isOut ? "Add \(name) back to the upload"
                                              : "Leave \(name) out of the upload")
                }
            Text(isOut ? "—" : "\(uploadPosition(of: name))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// What goes up, in order, renumbered so the filenames have no gaps in them
    /// where an excluded picture used to be.
    private var includedPhotos: [INatImages.Photo] {
        photos.filter { !excluded.contains($0.name) }
            .enumerated()
            .map { index, photo in
                let base = photo.name.drop { $0.isNumber }.drop { $0 == "-" }
                return INatImages.Photo(name: String(format: "%02d-%@", index + 1, String(base)),
                                        data: photo.data)
            }
    }

    private func uploadPosition(of name: String) -> Int {
        (photos.filter { !excluded.contains($0.name) }.firstIndex { $0.name == name } ?? 0) + 1
    }

    private var taxonSection: some View {
        TileCard(step(1, "What it was"), "What OpenBat will claim.") {
            ControlNote("Genus only — the species goes in the notes.")
            copyRow("Species", observation.taxonName)
            Text(observation.taxonNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var whenAndWhereSection: some View {
        TileCard(step(2, "When and where"), "Obscured unless you change it.") {
            copyRow("Date and time", observation.observedOn)
            if let coordinates = observation.coordinateText {
                copyRow("Coordinates", coordinates)
                Picker("Location precision", selection: $geoprivacy) {
                    ForEach(INatGeoprivacy.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                ControlNote(geoprivacy.note)
            } else {
                Text("No location on this recording — place it on the map yourself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notesSection: some View {
        TileCard(step(3, "Notes"), mode == .manual ? "Paste into the description field." : "Posted as the description.") {
            if mode == .manual {
                Button {
                    UIPasteboard.general.string = observation.pasteboardText
                    flash("notes")
                } label: {
                    Label(copied == "notes" ? "Copied" : "Copy Notes",
                          systemImage: copied == "notes" ? "checkmark" : "doc.on.doc")
                }
            }
            // Kept on both routes: on the automatic one this is not something
            // to copy, it is a preview of the description that will be posted,
            // and it is the longest piece of text going onto a public record.
            Text(observation.notes)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var fieldsSection: some View {
        // Automatic: only the three that are actually posted. The others exist
        // to be copied by hand, and listing them on a route that copies nothing
        // would be listing work nobody has to do.
        let shown = mode == .auto ? observation.postableFields : observation.fields
        if !shown.isEmpty {
            TileCard(step(4, "Observation fields"),
                           mode == .auto ? "Found with other bat records." : "Optional, and worth it.") {
                ForEach(shown) { field in
                    copyRow(field.label, field.value, note: field.note)
                }
            }
        }
    }

    /// The manual route: take the files, and go wherever you were going.
    ///
    /// **It no longer opens iNaturalist for you** (Niall, 2026-09-06). A link
    /// straight to the uploader assumed both the destination and the moment —
    /// somebody standing in a field with no signal, or headed for a local
    /// records centre rather than iNaturalist at all, got sent to a web page
    /// they had not asked for and had to come back from. Saving to Files is
    /// also the step that has to happen FIRST whichever way they are going,
    /// since the uploader needs files that already exist on the device. So this
    /// hands over the files and stops, and the destination stays the user's.
    ///
    /// What it hands over is byte-for-byte what the automatic route would post
    /// — see `INatExport.Files.all`.
    private var manualSection: some View {
        TileCard("Or do it by hand", "No account needed.") {
            ControlNote("Save these, then add them to iNaturalist's website — its own iPhone app can't take sound.")
            Button {
                shareFiles = ShareFiles(urls: files?.all ?? [])
            } label: {
                if let files {
                    Label("Save or Share \(files.all.count) Files", systemImage: "square.and.arrow.up")
                } else {
                    HStack(spacing: 8) { ProgressView(); Text("Preparing files…") }
                }
            }
            .disabled(files == nil)
        }
    }

    // MARK: Rows

    /// A row that can be copied, or just read.
    ///
    /// The copy buttons exist for the manual route, where every one of these is
    /// something to paste into a field on iNaturalist's uploader. On the
    /// automatic route there is nothing to paste anywhere — a copy button on
    /// each line implies work the user is supposed to do, which is exactly what
    /// that route removes.
    @ViewBuilder
    private func copyRow(_ label: String, _ value: String, note: String? = nil) -> some View {
        if mode == .auto {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body)
                    .textSelection(.enabled)
                if let note {
                    Text(note).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        } else {
            copyableRow(label, value, note: note)
        }
    }

    private func copyableRow(_ label: String, _ value: String, note: String? = nil) -> some View {
        Button {
            UIPasteboard.general.string = value
            flash(label)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    if let note {
                        Text(note).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: copied == label ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied == label ? Color.green : Color.accentColor)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy \(label): \(value)")
    }

    /// Ticks the row for a moment so a tap that only changes the pasteboard —
    /// which is otherwise completely invisible — is visibly acknowledged.
    private func flash(_ key: String) {
        copied = key
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if copied == key { copied = nil }
        }
    }
}
