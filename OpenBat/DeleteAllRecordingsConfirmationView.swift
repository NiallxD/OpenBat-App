//
//  DeleteAllRecordingsConfirmationView.swift
//  OpenBat
//
//  Type-to-confirm gate in front of ClassificationStore.deleteAllRecordings() —
//  local-only and irreversible (every WAV on this device, gone), so it gets the
//  same stronger friction EraseDataConfirmationView uses for the server-side
//  erasure, rather than a plain confirmation alert. Distinct from that other
//  flow: this never touches anything already uploaded — see SettingsView's
//  Privacy tab for erasing server-side data.
//

import SwiftUI

struct DeleteAllRecordingsConfirmationView: View {
    let classStore: ClassificationStore
    let onFinished: () -> Void

    private static let confirmationPhrase = "DELETE"

    @State private var typedText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This permanently deletes every recording (and its WAV file) on this device. Session and pulse-ID history is unaffected — only the saved recordings themselves go. This cannot be undone, and doesn't touch anything already uploaded to the community science project.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Delete all recordings")
                }

                Section {
                    TextField("Type \(Self.confirmationPhrase) to confirm", text: $typedText)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                }

                Section {
                    Button("Delete Everything", role: .destructive) {
                        classStore.deleteAllRecordings()
                        onFinished()
                        dismiss()
                    }
                    .disabled(typedText != Self.confirmationPhrase)
                }
            }
            .navigationTitle("Delete All Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
