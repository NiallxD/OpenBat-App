//
//  ConsentView.swift
//  OpenBat
//
//  Shown once during onboarding (and reachable again from Settings' Community
//  tab) to decide whether this device's recordings can be uploaded to the
//  community science project. Recording and on-device species ID work
//  regardless of the choice made here — this only gates uploads. Consent is
//  permission to collect, not a promise that anything uploads automatically:
//  the normal flow is a manual per-recording tap in Playback (RecordingRow's
//  upload badge); "Upload automatically" below is off by default and opts
//  into the old auto-upload-on-save behavior instead.
//
//  Wording is a first draft, not final copy (see openbat-onboarding-consent-
//  upload-spec.md, "Final wording" open item).
//

import SwiftUI

struct ConsentView: View {
    let consent: ConsentStore
    /// Called after the user picks either option, so the caller (onboarding
    /// flow) can advance regardless of which button was tapped.
    let onDecided: () -> Void

    @State private var showPrivacyDetail = false
    @AppStorage("community.autoUploadEnabled") private var autoUploadEnabled = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    OnboardingStepView(
                        systemImage: "globe.americas.fill",
                        title: "Community Science",
                        message: "Join the project to help build a shared reference call library and support bat conservation research. Recording and on-device species ID work the same either way — saying yes here just gives OpenBat permission to collect recordings you choose to send. Nothing uploads on its own: you pick which recordings to contribute, one at a time, from the Playback screen.")

                    VStack(alignment: .leading, spacing: 16) {
                        bullet("Recordings are only uploaded when you tap to send one — from Playback, tap the cloud icon on a recording that's eligible (a confident species ID, above the confidence bar).")
                        bullet("Your recording, location (approximate or precise — your choice), a device identifier, and an optional display name are collected for whatever you send.")
                        bullet("Before a recording you contribute reaches us, an irreversible filter removes the low frequencies human speech occupies — bat calls sit far above that range, so the calls themselves are untouched.")
                        bullet("Recordings you don't contribute never reach us at all. They're stored for you, on this device and in your own iCloud unless you turn that off in settings.")
                        bullet("Stored privately — never published to a public map or fed live into any public-facing feature.")
                        bullet("Used to build a reference call library, train classification models, inform conservation research, and may be licensed to commercial or research users to help fund the project.")
                        bullet("Never sold or shared for purposes unrelated to bat research and conservation.")
                        bullet("Uploading a recording uses mobile or Wi-Fi data.")
                        bullet("You can withdraw at any time from Settings — this stops future uploads.")

                        Toggle("Upload automatically", isOn: $autoUploadEnabled)
                            .padding(.top, 4)
                        Text("Off by default, and not the normal way to contribute — recordings are meant to be sent one at a time from Playback. Turning this on instead uploads every eligible recording as soon as it's saved, with no per-file review.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)

                    Button("Read the full privacy notice") { showPrivacyDetail = true }
                        .font(.footnote)
                }
                .padding(.vertical, 8)
            }

            VStack(spacing: 12) {
                Button("Contribute My Recordings") {
                    consent.grant()
                    onDecided()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)

                Button("Not Now") {
                    consent.revoke()
                    onDecided()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 16)
        }
        .sheet(isPresented: $showPrivacyDetail) { SafariView(url: PrivacyLinks.policyURL) }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
            Text(text)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}
