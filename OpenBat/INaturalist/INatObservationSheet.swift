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
    @Environment(\.openURL) private var openURL
    /// SwiftUI's own wrapper around ASWebAuthenticationSession — see the note
    /// in `INatAuth` about why the view presents the browser and not the model.
    @Environment(\.webAuthenticationSession) private var webAuthentication

    @State private var auth = INatAuth.shared
    @State private var shareFiles: ShareFiles?
    @State private var copied: String?
    @State private var geoprivacy = INatGeoprivacy.obscured
    @State private var postState = PostState.idle
    @State private var signingIn = false
    @State private var authError: String?
    @State private var showPostBriefing = false
    /// Remembered between recordings: somebody who prefers doing it by hand
    /// prefers it every time, and being put back on the automatic route on
    /// every sheet would be a small insult each time.
    @AppStorage("openbat.inat.sheetMode") private var mode = Mode.auto

    private enum Mode: String { case auto, manual }

    private enum PostState {
        case idle
        case posting
        case posted(INatClient.PostResult)
        case failed(String)
    }

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

    /// iNaturalist's web uploader. Opened in the browser rather than deep-linked
    /// into the app on purpose: the app is the route that cannot take the sound.
    static let uploaderURL = URL(string: "https://www.inaturalist.org/observations/upload")!

    var body: some View {
        NavigationStack {
            List {
                if case .posted(let result) = postState {
                    postedSection(result)
                } else {
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
                var prepared = await Task.detached(priority: .userInitiated) {
                    INatExport.prepareFiles(wavURL: url,
                                            recordingStart: start,
                                            pulses: pulses)
                }.value

                // The pictures, and copies of them on disk so the manual
                // uploader route offers exactly what the API route would send.
                photos = await INatImages.render(sources: imageSources,
                                                 pulses: pulses,
                                                 fallbackPNG: png)
                previews = photos.map { UIImage(data: $0.data) }
                prepared.photos = photos.compactMap { photo in
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(recording.id.uuidString)-\(photo.name)")
                    guard (try? photo.data.write(to: url)) != nil else { return nil }
                    return url
                }
                files = prepared
                assessment = INatUploadAssessment.assess(recording: recording,
                                                         passes: passes,
                                                         uploadBytes: prepared.uploadBytes)
            }
        }
    }

    // MARK: Posting

    /// Pinned rather than placed in the list, so the thing that actually
    /// creates a public record can't be scrolled past and pressed by accident
    /// on the way somewhere else.
    @ViewBuilder
    private var postBar: some View {
        if case .posted = postState {
            EmptyView()
        } else if mode == .manual {
            // The manual route posts nothing; its actions are its own section.
            EmptyView()
        } else {
            VStack(spacing: 8) {
                if let authError {
                    Text(authError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if case .failed(let message) = postState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                    // A status code on its own is not a diagnosis — the first
                    // live failure was a 404 whose actual cause was a malformed
                    // URL, invisible from here. This puts the request and the
                    // reply where they can be pasted into a bug report.
                    Button {
                        UIPasteboard.general.string = INatLog.shared.text
                        flash("log")
                    } label: {
                        Label(copied == "log" ? "Copied" : "Copy the request log",
                              systemImage: copied == "log" ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
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
                        Group {
                            if case .posting = postState {
                                HStack(spacing: 8) { ProgressView(); Text("Posting…") }
                            } else {
                                Label("Post to iNaturalist", systemImage: "arrow.up.circle.fill")
                            }
                        }
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
                    .disabled(isPosting || files == nil)
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

    private var isPosting: Bool {
        if case .posting = postState { return true }
        return false
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
        postState = .posting
        Task {
            // Resolved here rather than in the draft: it is a network call, and
            // it must not happen until the user has actually asked to post.
            let taxonID = await INatClient.taxonID(for: observation.taxonName)
            do {
                let result = try await INatClient.post(observation,
                                                       geoprivacy: geoprivacy,
                                                       taxonID: taxonID,
                                                       photos: includedPhotos,
                                                       sounds: files.sounds)
                // Recorded only on a real success, and only for a record this
                // phone actually created — that is what the nightly cap counts.
                INatPostLedger.record(recording: recording)
                postState = .posted(result)
            } catch {
                postState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func postedSection(_ result: INatClient.PostResult) -> some View {
        TileCard("Done", "It's on your iNaturalist account.") {
            Label(result.alreadyExisted ? "Already on iNaturalist" : "Posted to iNaturalist",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if result.alreadyExisted {
                ControlNote("Already posted — nothing new was created.")
            } else {
                ControlNote("\(result.attachedPhotos) pictures, \(result.attachedSounds) sounds, \(result.attachedFields) fields. Location \(geoprivacy.label.lowercased()).")
            }
            Button {
                openURL(result.webURL)
            } label: {
                Label("Open the observation", systemImage: "safari")
            }
        }
        .tileRow()

        if !result.skipped.isEmpty {
            TileCard("Some didn't attach", "Add them on iNaturalist yourself.") {
                ForEach(result.skipped, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                }
                Button {
                    shareFiles = ShareFiles(urls: files?.all ?? [])
                } label: {
                    Label("Save the files", systemImage: "square.and.arrow.up")
                }
                .disabled(files == nil)
            }
            .tileRow()
        }
    }

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
                          ? "Slowed \(INatExport.expansionFactor)× so you can hear it"
                          : "The original, at full speed",
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

    private var manualSection: some View {
        TileCard("Or do it by hand", "No account needed.") {
            ControlNote("The website takes sound; the iPhone app can't.")
            Link(destination: INatObservationSheet.uploaderURL) {
                Label("Open the iNaturalist Uploader", systemImage: "safari")
            }
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
