//
//  EraseDataConfirmationView.swift
//  OpenBat
//
//  Type-to-confirm gate in front of ConsentStore.eraseAllData() — a GDPR-style
//  full erasure (deletes every past R2 recording for this device, not just
//  future ones) is destructive and irreversible, so it doesn't hang off a
//  plain confirmation alert the way a normal delete would.
//

import SwiftUI

struct EraseDataConfirmationView: View {
    let consent: ConsentStore
    let classStore: ClassificationStore
    let onFinished: () -> Void

    private static let confirmationPhrase = "DELETE"

    @State private var typedText = ""
    @State private var isErasing = false
    @State private var resultMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // "recorded" rather than "notified the moment you submit":
                    // the request is now durably logged server-side before
                    // anything is deleted, and the privacy team's notification
                    // retries until it lands (see the Worker's erasure_requests
                    // table). Promising instant notification would be describing
                    // a single email send that can fail.
                    Text("This permanently deletes every recording you've contributed from our servers, along with your consent record, immediately. This cannot be undone, and is separate from just turning off contribution — that only stops future uploads. Your request is recorded the moment you submit it, and any recordings ever moved to long-term archive storage are removed by our privacy team as a follow-up — that part can take up to 7 business days.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Erase all my data")
                }

                Section {
                    TextField("Type \(Self.confirmationPhrase) to confirm", text: $typedText)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                        .disabled(isErasing)
                }

                if let resultMessage {
                    Section {
                        Text(resultMessage)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        erase()
                    } label: {
                        if isErasing {
                            ProgressView()
                        } else {
                            Text("Erase Everything")
                        }
                    }
                    .disabled(typedText != Self.confirmationPhrase || isErasing)
                }
            }
            .navigationTitle("Erase My Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isErasing)
                }
            }
        }
        .interactiveDismissDisabled(isErasing)
    }

    private func erase() {
        isErasing = true
        Task {
            let deletedCount = await consent.eraseAllData()
            isErasing = false
            if let deletedCount {
                // Server-side data is gone — clear local upload status too, so the
                // Uploads queue doesn't keep showing recordings as "Uploaded" that no
                // longer exist anywhere.
                classStore.clearAllUploadStatus()
                resultMessage = "Done — \(deletedCount) recording\(deletedCount == 1 ? "" : "s") deleted from our servers immediately, and your request has been logged. If any were ever archived, that copy will be removed within 7 business days."
                // Give the user a moment to read the confirmation rather than
                // yanking the sheet away the instant the request completes —
                // longer than before since this message is now two sentences.
                try? await Task.sleep(for: .seconds(3))
                onFinished()
                dismiss()
            } else {
                resultMessage = "Couldn't reach the server — nothing was deleted. Check your connection and try again."
            }
        }
    }
}
