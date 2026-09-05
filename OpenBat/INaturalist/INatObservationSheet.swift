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
    @State private var photoState = PhotoState.idle
    @State private var geoprivacy = INatGeoprivacy.obscured
    @State private var postState = PostState.idle
    @State private var signingIn = false
    @State private var authError: String?
    @State private var showPostBriefing = false

    private enum PhotoState { case idle, saving, saved, denied }

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
                    assessmentSection
                    taxonSection
                    whenAndWhereSection
                    notesSection
                    fieldsSection
                    manualSection
                }
            }
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
        } else {
            VStack(spacing: 8) {
                if let authError {
                    Text(authError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                if case .failed(let message) = postState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
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
                }

                if let assessment, !assessment.canPost {
                    // No "post anyway". Every blocker is a case where the
                    // record would be useless or unwelcome, and the manual
                    // uploader below is the deliberate way past it.
                    Label(assessment.rating.rawValue, systemImage: "hand.raised.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
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
                    .disabled(isPosting || files == nil)
                    Text("Posts to your own iNaturalist account, as \(observation.taxonName), \(geoprivacy.label.lowercased()) location.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
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
                    Text("You'll sign in on iNaturalist's own page. OpenBat never sees your password, and you can post by hand instead — see the bottom of this screen.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
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
        Every record on iNaturalist is checked by volunteers, so a few good \
        recordings are worth much more than a lot of rough recordings. Post the \
        ones where the calls are clear and there's only one bat, and leave the \
        rest on your phone.

        OpenBat won't post more than two of the same species from the same place \
        in one night. Past that you're asking somebody to verify the same bat \
        twice, which costs them time and puts nothing new on the map.

        Your location goes up obscured unless you change it, because a precise \
        bat record can give away a roost.
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
                                                       photos: photos,
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
        Section {
            Label(result.alreadyExisted ? "Already on iNaturalist" : "Posted to iNaturalist",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if result.alreadyExisted {
                ControlNote("This recording had already been posted, so nothing was created. Opening it will show you the existing observation.")
            } else {
                ControlNote("Attached: \(result.attachedSounds) sound file\(result.attachedSounds == 1 ? "" : "s") and \(result.attachedPhotos) spectrogram\(result.attachedPhotos == 1 ? "" : "s"), plus \(result.attachedFields) observation field\(result.attachedFields == 1 ? "" : "s"). Location is \(geoprivacy.label.lowercased()).")
            }
            Button {
                openURL(result.webURL)
            } label: {
                Label("Open the observation", systemImage: "safari")
            }
        } header: {
            CardHeader("Done", "")
        }

        if !result.skipped.isEmpty {
            Section {
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
            } header: {
                CardHeader("Not everything went up", "The observation is posted; these didn't attach.")
            } footer: {
                Text("You can add them to the observation yourself on iNaturalist's website.")
            }
        }
    }

    /// The first thing on the screen, before the taxon or the map, because the
    /// question it answers — should this be posted at all? — comes before every
    /// other question on the page.
    @ViewBuilder
    private var assessmentSection: some View {
        Section {
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
        } header: {
            CardHeader("Worth posting?", "iNaturalist is checked by volunteers.")
        } footer: {
            if let files, files.upload != files.original {
                Text("The silence either side of the calls has been cut off, so what goes up is \(byteCount(files.uploadBytes)) instead of the whole recording.")
            }
        }
    }

    private func colour(for rating: INatUploadAssessment.Rating) -> Color {
        switch rating {
        case .blocked: return .red
        case .poor: return .orange
        case .fair: return .yellow
        case .good, .excellent: return .green
        }
    }

    private func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var taxonSection: some View {
        Section {
            copyRow("Species", observation.taxonName)
            Text(observation.taxonNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            CardHeader("1 · What it was", "What OpenBat will claim.")
        } footer: {
            // The single most important sentence on this screen. An observation
            // posted from here carries the user's name, not OpenBat's, and iNat
            // records are permanent and public.
            Text("OpenBat posts at genus and puts its species suggestion in the notes, because an acoustic identification isn't strong enough to claim a species on a permanent public record. If you're confident of the species, add that identification yourself on iNaturalist — then a person has made the claim, which is the point.")
        }
    }

    private var whenAndWhereSection: some View {
        Section {
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
                Text("No location was recorded with this file. iNaturalist will take the observation without one, but it won't count towards range data — you can place it on the map yourself afterwards.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            CardHeader("2 · When and where", "")
        } footer: {
            // Roosts are the reason the default is Obscured and not iNat's own
            // default. iNat obscures some taxa automatically; that is not
            // something to rely on for a species list this app doesn't control.
            Text("A precise bat record can identify a roost, and roost locations are not something to put on a public map. Obscured is the default for that reason.")
        }
    }

    private var notesSection: some View {
        Section {
            Button {
                UIPasteboard.general.string = observation.pasteboardText
                flash("notes")
            } label: {
                Label(copied == "notes" ? "Copied" : "Copy Notes",
                      systemImage: copied == "notes" ? "checkmark" : "doc.on.doc")
            }
            Text(observation.notes)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } header: {
            CardHeader("3 · Notes", "Posted as the description.")
        }
    }

    @ViewBuilder
    private var fieldsSection: some View {
        if !observation.fields.isEmpty {
            Section {
                ForEach(observation.fields) { field in
                    copyRow(field.label, field.value, note: field.note)
                }
            } header: {
                CardHeader("4 · Observation fields", "Optional, and worth it.")
            } footer: {
                // Not posted by the API path yet: iNaturalist's observation
                // fields are addressed by numeric id, so adding them means
                // resolving each field by name first. The numbers are in the
                // description regardless, so nothing is lost, only harder to
                // search on.
                Text("iNaturalist lets you add named fields to an observation, which is how acoustic records from other tools are found together. The first three are posted for you; the rest are here to copy if you want them.")
            }
        }
    }

    private var manualSection: some View {
        Section {
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

            Button {
                saveSpectrogram()
            } label: {
                switch photoState {
                case .idle:
                    Label("Save Spectrogram to Photos", systemImage: "photo.badge.plus")
                case .saving:
                    HStack(spacing: 8) { ProgressView(); Text("Saving…") }
                case .saved:
                    Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                case .denied:
                    Label("Photos access declined", systemImage: "exclamationmark.triangle")
                }
            }
            .disabled((photos.isEmpty && overviewPNG == nil) || photoState == .saving || photoState == .saved)
            if photoState == .denied {
                ControlNote("Turn on Photos access for OpenBat in Settings — or skip it, since the uploader can take the spectrogram straight from Files.")
            }
        } header: {
            CardHeader("Or do it by hand", "No account needed.")
        } footer: {
            Text("The website takes the sound and the spectrogram together, which the iPhone app can't — it records sound but won't import a file. Save the files, then choose them in the uploader and paste the text above.")
        }
    }

    // MARK: Rows

    private func copyRow(_ label: String, _ value: String, note: String? = nil) -> some View {
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

    private func saveSpectrogram() {
        // The cropped one where it exists: it is the picture worth having, and
        // the whole point of saving to Photos is to attach it somewhere else.
        guard let png = photos.first?.data ?? overviewPNG else { return }
        photoState = .saving
        Task {
            let ok = await INatExport.saveSpectrogramToPhotos(png)
            photoState = ok ? .saved : .denied
        }
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
