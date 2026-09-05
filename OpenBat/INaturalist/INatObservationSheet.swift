//
//  INatObservationSheet.swift
//  OpenBat
//
//  The hand-off screen: everything iNaturalist will ask for, laid out in the
//  order it asks for it, each row copyable, with the files ready to share.
//
//  Deliberately NOT a form that posts. OpenBat prepares; the user decides. See
//  `INatObservation` for why the app doesn't create the observation itself, and
//  for the rule about which taxon it suggests.
//
//  The order of the sections is the order of iNaturalist's own new-observation
//  screen — media, then what, then when, then where, then notes — so this can be
//  worked down the page with the two apps side by side.
//

import SwiftUI

struct INatObservationSheet: View {
    let observation: INatObservation
    let wavURL: URL
    /// Already encoded, so the sheet never touches a `UIImage` off the main
    /// actor. nil when the overview hasn't rendered yet.
    let overviewPNG: Data?
    @Environment(\.dismiss) private var dismiss
    @State private var shareFiles: ShareFiles?
    @State private var copied: String?
    @State private var photoState = PhotoState.idle

    private enum PhotoState { case idle, saving, saved, denied }

    /// Built in `.task` — see `INatExport.prepareFiles`, which copies and
    /// rewrites tens of megabytes and must not run on the main actor.
    @State private var files: [URL] = []

    private struct ShareFiles: Identifiable { let id = UUID(); let urls: [URL] }

    /// iNaturalist's web uploader. Opened in the browser rather than deep-linked
    /// into the app on purpose: the app is the route that cannot take the sound.
    static let uploaderURL = URL(string: "https://www.inaturalist.org/observations/upload")!

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Link(destination: INatObservationSheet.uploaderURL) {
                        Label("Open the iNaturalist Uploader", systemImage: "safari")
                    }
                    ControlNote("The website takes the sound and the spectrogram together, which the iPhone app can't — it records sound but won't import a file. Save the files below first, then pick them in the uploader.")
                } header: {
                    CardHeader("1 · Where to add it", "The web uploader, not the app.")
                }

                Section {
                    Button {
                        shareFiles = ShareFiles(urls: files)
                    } label: {
                        if files.isEmpty {
                            HStack(spacing: 8) { ProgressView(); Text("Preparing files…") }
                        } else {
                            Label("Save or Share \(files.count) Files", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(files.isEmpty)
                    ControlNote("A \(INatExport.expansionFactor)× slowed-down copy you can actually hear, the spectrogram, and the original ultrasonic recording. Save them to Files, then choose them in the uploader.")

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
                    .disabled(overviewPNG == nil || photoState == .saving || photoState == .saved)
                    if photoState == .denied {
                        ControlNote("Turn on Photos access for OpenBat in Settings — or skip it, since the uploader can take the spectrogram straight from Files.")
                    } else {
                        ControlNote("Only needed if you'd rather build the observation in the iNaturalist app. It can take a photo from your library, but you'd be posting the call without its sound.")
                    }
                } header: {
                    CardHeader("2 · The files", "")
                }

                Section {
                    copyRow("Species", observation.taxonName)
                    Text(observation.taxonNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    CardHeader("3 · What it was", "Paste into iNaturalist's species box.")
                } footer: {
                    // The single most important sentence on this screen. An
                    // observation posted from here carries the user's name, not
                    // OpenBat's, and iNat records are permanent and public.
                    Text("You're making this claim, not OpenBat. If you're not sure, log it as Chiroptera and let iNaturalist's community narrow it down — that's what the site is for.")
                }

                Section {
                    copyRow("Date and time", observation.observedOn)
                    if let coordinates = observation.coordinateText {
                        copyRow("Coordinates", coordinates)
                    } else {
                        Text("No location was recorded with this file. You'll need to place it on iNaturalist's map yourself.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    CardHeader("4 · When and where", "")
                } footer: {
                    // Roosts are the reason this is here and not left to the
                    // default. iNat obscures some taxa automatically; that is not
                    // something to rely on for a species list this app doesn't
                    // control.
                    Text("Set the observation's geoprivacy to Obscured before you post, unless you're certain the exact spot is safe to publish. A precise bat record can identify a roost, and roost locations are not something to put on a public map.")
                }

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
                    CardHeader("5 · Notes", "Paste into the description field.")
                }

                if !observation.fields.isEmpty {
                    Section {
                        ForEach(observation.fields) { field in
                            copyRow(field.label, field.value, note: field.note)
                        }
                    } header: {
                        CardHeader("6 · Observation fields", "Optional, and worth it.")
                    } footer: {
                        Text("iNaturalist lets you add named fields to an observation. Filling these in puts your record alongside the bat recordings uploaded by other tools, where a search can find them all together.")
                    }
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
            .sheet(item: $shareFiles) { share in
                ShareSheet(items: share.urls)
            }
            .task {
                let url = wavURL
                let png = overviewPNG
                files = await Task.detached(priority: .userInitiated) {
                    INatExport.prepareFiles(wavURL: url, overviewPNG: png)
                }.value
            }
        }
    }

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
        guard let overviewPNG else { return }
        photoState = .saving
        Task {
            let ok = await INatExport.saveSpectrogramToPhotos(overviewPNG)
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
