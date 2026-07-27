//
//  EraseDataConfirmationView.swift
//  OpenBat
//
//  Type-to-confirm gate in front of ConsentStore.eraseConsentRecord(). Deleting
//  the consent record outright (rather than just revoking it) is irreversible
//  and resets the device identity, so it doesn't hang off a plain confirmation
//  alert the way a normal delete would.
//
//  The copy below has to be exact about scope. This used to promise deletion of
//  every contributed recording, which the backend could honour only because
//  uploads were stored under a device-id prefix. That prefix is gone: uploads
//  carry no identifier at all, so no recording can be traced to a device and
//  none can be deleted on request. Saying so plainly here — and in ConsentView,
//  BEFORE anyone contributes — is the entire basis on which those recordings are
//  not personal data. Do not soften it into "may not be able to".
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
                    // States plainly that it's already done, because it is.
                    // Erasure is now a single synchronous statement server-side
                    // (see the Worker's handleErase) — no queue, no email, no
                    // human step afterwards. Earlier wording promised the
                    // request was "recorded" and would be followed up, which
                    // described machinery that existed to chase archived copies
                    // of recordings; recordings can no longer be attributed to a
                    // device at all, so there is nothing to follow up.
                    Text("This permanently deletes your consent record from our servers and resets this device's identifier. It happens immediately, and it cannot be undone.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Erase my consent record")
                }

                Section {
                    Text("Recordings you've already contributed are not deleted, because there is no way for us to find them. They're stored with no device identifier, a location rounded to about 100 metres, and a time rounded to the nearest 5 minutes — nothing connects them to you or to this device, which is why they don't count as your personal data once sent. That's also why we can't pick yours back out.\n\nRecordings you never contributed were never sent to us at all, and stay on your device.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("What this doesn't cover")
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
                            Text("Erase Consent Record")
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
            let succeeded = await consent.eraseConsentRecord()
            isErasing = false
            guard succeeded else {
                resultMessage = "Couldn't reach the server — nothing was deleted. Check your connection and try again."
                return
            }
            // The device identifier has been rotated, so the local "Uploaded"
            // badges refer to contributions this device can no longer claim any
            // relationship to. Clearing them isn't cleanup after a server-side
            // deletion (nothing was deleted) — it's keeping the local view honest
            // about what this device can still say about itself.
            classStore.clearAllUploadStatus()
            resultMessage = "Done — your consent record has been deleted and this device has a new identifier. Recordings you already contributed stay in the research dataset, unlinked from you."
            // Give the user a moment to read the confirmation rather than
            // yanking the sheet away the instant the request completes.
            try? await Task.sleep(for: .seconds(3))
            onFinished()
            dismiss()
        }
    }
}
