//
//  DeleteAllSessionsConfirmationView.swift
//  OpenBat
//
//  Type-to-confirm gate in front of ClassificationStore.deleteAllSessions() —
//  local-only and irreversible (every outing, every pass and every WAV those
//  sessions own, gone), so it gets the same stronger friction
//  EraseDataConfirmationView uses for the server-side erasure, rather than a
//  plain confirmation alert. Distinct from that other flow: this never touches
//  anything already uploaded — see SettingsView's General tab's privacy section
//  for erasing server-side data.
//
//  Was DeleteAllRecordingsConfirmationView until 2026-08-17, when the bulk
//  deletes were cut to two. See SettingsView's storage sections.
//

import SwiftUI

struct DeleteAllSessionsConfirmationView: View {
    let classStore: ClassificationStore
    let onFinished: () -> Void

    private static let confirmationPhrase = "DELETE"

    @State private var typedText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This permanently deletes every session on this device, along with the species IDs and recordings each one holds. Anything under \"Not in a session\" is kept. This cannot be undone.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Delete all sessions")
                }

                Section {
                    TextField("Type \(Self.confirmationPhrase) to confirm", text: $typedText)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                }

                Section {
                    Button("Delete Everything", role: .destructive) {
                        classStore.deleteAllSessions()
                        onFinished()
                        dismiss()
                    }
                    .disabled(typedText != Self.confirmationPhrase)
                }
            }
            .navigationTitle("Delete All Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
