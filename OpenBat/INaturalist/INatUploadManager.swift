//
//  INatUploadManager.swift
//  OpenBat
//
//  Posting an observation, off the screen that asked for it.
//
//  WHY IT LEFT THE SHEET
//  ---------------------
//  A post is a handful of HTTP requests carrying two audio files and a dozen
//  pictures — tens of megabytes, over whatever signal a field has at midnight.
//  Owned by the sheet, that work died the moment the sheet was dismissed, so
//  the user had to sit and watch a spinner to the end of something they had
//  already decided about. It is the same shape as exporting a session, and it
//  gets the same treatment: an app-lifetime object doing the work, and a pill
//  over the tab bar saying how it is going.
//
//  Modelled on `SessionExportManager` deliberately, down to the inline-host
//  count, so the two pills behave identically and neither has to know about the
//  other.
//
//  WHAT IT DOES NOT DO
//  -------------------
//  There is still no queue that drains on its own, and nothing here starts
//  without a tap. `enqueue` is called by the confirmation sheet's Post button
//  and by nothing else — backgrounding the WORK is not the same as posting in
//  the background, and the rule that an observation exists only because
//  somebody pressed a button is unchanged.
//
//  NETWORK WORK, NOT FILE WORK
//  ---------------------------
//  Unlike the exporter this has no long synchronous block to keep off the main
//  thread — `INatClient` is `async` all the way down and `URLSession` does its
//  own IO — so there is no dispatch queue here and no cancellation flag. The
//  task's own cancellation reaches `URLSession` on its own.
//

import SwiftUI
import UIKit

@Observable
final class INatUploadManager {

    static let shared = INatUploadManager()

    /// What the pill draws. A value type replaced whole on each update, so
    /// `@Observable` has one property to track.
    struct Job: Identifiable, Equatable {
        /// The recording's id, so a repeat tap while it is in flight is a no-op.
        let id: UUID
        let title: String
        var fraction: Double
    }

    /// A finished post, waiting to be acknowledged. Held here rather than
    /// handed to a view, so it survives whatever the user is looking at when it
    /// lands.
    struct Finished: Identifiable {
        let id = UUID()
        let title: String
        let result: INatClient.PostResult
    }

    private(set) var job: Job?
    var finished: Finished?
    var failure: String?

    /// Screens drawing the pill in their own layout register here and the root
    /// chrome stands down, so it is never drawn twice. A count, not a flag:
    /// pushes and tab changes overlap, and a bool is left stuck by whichever
    /// registration ended last.
    private(set) var inlineHosts = 0
    var showsRootPill: Bool { job != nil && inlineHosts == 0 }
    func addInlineHost() { inlineHosts += 1 }
    func removeInlineHost() { inlineHosts = max(0, inlineHosts - 1) }

    private var task: Task<Void, Never>?

    private init() {}

    /// Everything the post needs, captured at the moment of the tap so nothing
    /// afterwards can change what gets sent.
    struct Input {
        let recording: Recording
        let observation: INatObservation
        let geoprivacy: INatGeoprivacy
        let photos: [INatImages.Photo]
        let sounds: [URL]
        var title: String { recording.commonName }
    }

    func isActive(recordingID: UUID) -> Bool { job?.id == recordingID }

    /// Starts the post and returns. One at a time: two observations at once
    /// would compete for the same field signal and finish later than they would
    /// in sequence, and the cap means there is never a queue worth having.
    func post(_ input: Input) {
        guard job == nil else { return }
        job = Job(id: input.recording.id, title: input.title, fraction: 0)

        // No `[weak self]`: a `static let shared` that lives as long as the app,
        // and a weak capture would make `self` a var the progress closure then
        // captures across an isolation boundary.
        task = Task(priority: .userInitiated) {
            // Without this the process is suspended when the screen locks or
            // the user switches away, and a post half way through a 15 MB sound
            // file never finishes.
            let background = UIApplication.shared.beginBackgroundTask(withName: "INatUpload")
            defer { UIApplication.shared.endBackgroundTask(background) }

            do {
                // The taxon lookup is here rather than in the sheet so the tap
                // returns instantly even on a cold cache.
                let taxonID = await INatClient.taxonID(for: input.observation.taxonName)
                let result = try await INatClient.post(input.observation,
                                                       geoprivacy: input.geoprivacy,
                                                       taxonID: taxonID,
                                                       photos: input.photos,
                                                       sounds: input.sounds) { fraction in
                    Task { @MainActor in self.advance(fraction) }
                }
                self.complete(input: input, result: result)
            } catch is CancellationError {
                self.job = nil
            } catch {
                self.job = nil
                self.failure = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        job = nil
    }

    private func advance(_ fraction: Double) {
        guard var job else { return }
        job.fraction = fraction
        self.job = job
    }

    private func complete(input: Input, result: INatClient.PostResult) {
        // Only on a real success, and only for a record this phone created —
        // that is what the nightly cap counts.
        if !result.alreadyExisted {
            INatPostLedger.record(recording: input.recording)
        }
        job = nil
        task = nil
        finished = Finished(title: input.title, result: result)
    }
}

/// The pill: how far along, and a way to stop.
///
/// Deliberately the same shape and the same words-per-line budget as
/// `SessionExportBanner` — two different-looking progress pills for two
/// background jobs in one app is one pill too many designs.
struct INatUploadBanner: View {
    @Bindable var manager: INatUploadManager

    var body: some View {
        if let job = manager.job {
            HStack(spacing: 8) {
                ProgressView(value: job.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 54)
                Text("Posting \(job.title)")
                    .lineLimit(1)
                Button {
                    manager.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel the upload")
            }
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .liquidGlass(in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Posting \(job.title) to iNaturalist, \(Int(job.fraction * 100)) percent")
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}

/// The two alerts a finished post can raise, as one modifier.
///
/// Its own type rather than two `.alert`s on the root view: `ContentView`'s
/// body is already at the edge of what the type-checker will do in reasonable
/// time, and adding them inline pushed it over ("unable to type-check this
/// expression in reasonable time"). Anything with its own strings and its own
/// bindings can live out here.
private struct INatUploadAlerts: ViewModifier {
    @Bindable var manager: INatUploadManager
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(
                get: { manager.finished != nil },
                set: { if !$0 { manager.finished = nil } }
            )) {
                if let finished = manager.finished {
                    Button("Open") { openURL(finished.result.webURL) }
                }
                Button("OK", role: .cancel) { }
            } message: {
                Text(message)
            }
            .alert("Couldn't post to iNaturalist", isPresented: Binding(
                get: { manager.failure != nil },
                set: { if !$0 { manager.failure = nil } }
            )) {
                Button("OK") { }
            } message: {
                Text(manager.failure ?? "")
            }
    }

    private var title: String {
        guard let finished = manager.finished else { return "" }
        return finished.result.alreadyExisted ? "Already on iNaturalist" : "Posted to iNaturalist"
    }

    /// Says what actually happened, including a partial success: an observation
    /// whose sound was too large is still a real observation, and reporting it
    /// as a clean win would leave the user believing the call went up with it.
    private var message: String {
        guard let finished = manager.finished else { return "" }
        let result = finished.result
        if result.alreadyExisted {
            return "\(finished.title) had already been posted, so nothing new was created."
        }
        var lines = ["\(finished.title): \(result.attachedPhotos) pictures and \(result.attachedSounds) sound files."]
        lines.append(contentsOf: result.skipped)
        return lines.joined(separator: "\n\n")
    }
}

extension View {
    func inatUploadAlerts(manager: INatUploadManager) -> some View {
        modifier(INatUploadAlerts(manager: manager))
    }
}
