//
//  UploadQueueView.swift
//  OpenBat
//
//  Read-only status view — recordings currently uploading, or already uploaded
//  or failed. NOT where uploads are triggered: there's no bulk "Upload Now"
//  sweep — a recording uploads when the user taps its own eligible badge in
//  the Playback list (see RecordingRow.uploadBadge, RecordingUploader.uploadNow).
//  Ineligible recordings (consent off, NoID, below the confidence bar) show no
//  badge there and never appear here either.
//

import SwiftUI

struct UploadQueueView: View {
    let classStore: ClassificationStore
    let consent: ConsentStore
    @Environment(\.dismiss) private var dismiss

    /// Only the recordings that have actually been through an upload attempt —
    /// Queued/Rejected/Not Contributing recordings are eligibility states shown
    /// via the Playback row badge instead, not duplicated here.
    private var grouped: [(title: String, recordings: [Recording])] {
        let all = classStore.recordings
        func matching(_ phases: Set<UploadStatus.Phase>) -> [Recording] {
            all.filter { phases.contains($0.uploadStatus?.phase ?? .notContributing) }
        }
        return [
            ("Uploading", matching([.converting, .encoding, .uploading])),
            ("Uploaded",  matching([.uploaded])),
            ("Failed",    matching([.failed])),
            // Included so the reason is readable somewhere: a rejection is
            // permanent (too long, unreadable, quality gate), and the Playback
            // row can only carry it as an accessibility label.
            ("Not Eligible", matching([.rejected])),
        ].filter { !$0.recordings.isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                if !consent.isGranted {
                    Section {
                        Label("Community Science contribution is disabled. Enable to upload recordings.", systemImage: "icloud.slash")
                            .foregroundStyle(.secondary)
                    }
                }
                if grouped.isEmpty {
                    if consent.isGranted {
                        ContentUnavailableView(
                            "No Uploads Yet",
                            systemImage: "icloud",
                            description: Text("Recordings show up here once Upload Now sends one to the community science project."))
                    }
                } else {
                    ForEach(grouped, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.recordings) { recording in
                                UploadQueueRow(recording: recording)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Upload Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct UploadQueueRow: View {
    let recording: Recording

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.commonName)
                Text(recording.date, style: .date) + Text(" · ") + Text(recording.date, style: .time)
            }
            .font(.subheadline)
            Spacer()
            statusBadge
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch recording.uploadStatus?.phase ?? .notContributing {
        case .converting: inProgress("Converting")
        case .encoding:    inProgress("Encoding")
        case .uploading:   inProgress("Uploading")
        case .uploaded:    Image(systemName: "checkmark.icloud.fill").foregroundStyle(.green)
        case .failed:
            if let reason = recording.uploadStatus?.reason {
                Text(reason).foregroundStyle(.red).multilineTextAlignment(.trailing)
            }
        case .rejected:
            if let reason = recording.uploadStatus?.reason {
                Text(reason).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        case .notContributing, .queued:
            EmptyView()   // filtered out of `grouped` — unreachable in practice
        }
    }

    private func inProgress(_ label: String) -> some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.mini)
            Text(label)
        }
    }
}
