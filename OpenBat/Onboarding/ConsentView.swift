//
//  ConsentView.swift
//  OpenBat
//
//  Shown once during onboarding (and reachable again from Settings' Community
//  tab) to decide whether this device's recordings can be uploaded to the
//  community science project. Recording and on-device species ID work
//  regardless of the choice made here — this only gates uploads. Consent is
//  permission to collect, not a promise that anything uploads: every
//  contribution is a per-recording tap in Playback (RecordingRow's upload
//  badge). There is no automatic upload path at all — the setting that provided
//  one was removed, since "we only send what you choose" is a much easier
//  promise to keep when there is no code that could do otherwise.
//
//  Copy here is load-bearing: it is the disclosure the "contributed recordings
//  are not personal data" position rests on, and it must stay accurate to what
//  AnonymizedUploadBuilder actually does.
//
//  This screen was previously eleven bullets of dense text — long enough that
//  nobody would read it, which is a real problem for a screen whose entire job
//  is informing a decision. Detail moved to the linked pages; what's left is the
//  minimum needed to make the choice knowingly, with the irreversibility warning
//  given its own visual weight because it's the one most likely to surprise
//  someone later.
//

import SwiftUI

struct ConsentView: View {
    let consent: ConsentStore
    /// Called after the user picks either option, so the caller (onboarding
    /// flow) can advance regardless of which button was tapped.
    let onDecided: () -> Void

    @State private var showPrivacyDetail = false
    @State private var showExplainer = false

    /// Both default to `false` and must be switched on deliberately.
    ///
    /// NOT `@AppStorage`, and never pre-enabled. Consent has to be a clear
    /// affirmative action: a pre-ticked box is explicitly invalid consent under
    /// GDPR (Recital 32; *Planet49*), fails Quebec Law 25's confidentiality-by-
    /// default rule, and PIPEDA requires express consent for a secondary purpose
    /// like licensing. These also deliberately don't persist across a re-entry
    /// to this screen — someone returning to reconsider should start from "off"
    /// rather than from whatever they last left switched on.
    @State private var agreesToResearchUse = false
    @State private var agreesToFundingUse = false

    private var canContribute: Bool { agreesToResearchUse && agreesToFundingUse }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    OnboardingStepView(
                        systemImage: "globe.americas.fill",
                        title: "Community Science",
                        message: "Help build a shared reference library of bat calls. Recording and species ID work the same either way — this only decides whether you can send recordings to the project.")

                    VStack(alignment: .leading, spacing: 14) {
                        bullet("Nothing uploads on its own. You pick each recording to send, one at a time, from Playback.")
                        bullet("Before one leaves your phone, everything identifying is removed: no device ID, no name, no filename. The location is rounded to about 100 metres, the time to 5 minutes, and human speech is filtered out irreversibly.")
                        bullet("Recordings you don't send never reach us. They stay on your phone.")
                    }
                    .padding(.horizontal, 8)

                    // The single most important disclosure on this screen, and
                    // the one a user is most likely to feel misled about later
                    // if it's buried. It gets its own box, above the toggles,
                    // rather than being the ninth bullet in a list.
                    irreversibilityCallout

                    VStack(spacing: 6) {
                        Button("How we protect your privacy") { showExplainer = true }
                        Button("Read the full privacy notice") { showPrivacyDetail = true }
                    }
                    .font(.footnote)
                }
                .padding(.vertical, 8)
            }

            consentControls
        }
        .sheet(isPresented: $showPrivacyDetail) { SafariView(url: PrivacyLinks.policyURL) }
        .sheet(isPresented: $showExplainer) { SafariView(url: PrivacyLinks.explainerURL) }
    }

    private var irreversibilityCallout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Because nothing links a recording back to you, we can't find it again either. Once you send one, it can't be deleted from the research dataset.")
                .font(.subheadline)
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 8)
    }

    /// Two toggles rather than one, because these are two distinct purposes and
    /// a user deserves to see the commercial one named rather than folded into a
    /// sentence about research. Both are required: the dataset funds itself
    /// through licensing, so it isn't offered on other terms.
    ///
    /// That bundling is defensible specifically because nothing is withheld from
    /// someone who declines — the app is fully functional without contributing,
    /// so "these terms or don't contribute" isn't a service being held hostage.
    /// If a feature is ever gated behind contributing, this reasoning stops
    /// working and the two consents have to become separately refusable.
    private var consentControls: some View {
        VStack(spacing: 14) {
            Divider()

            Toggle(isOn: $agreesToResearchUse) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Contribute my recordings to bat research")
                    Text("Used to build a reference library, train species-ID models, and support conservation research.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $agreesToFundingUse) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let contributions help fund the project")
                    Text("Anonymous recordings may be published in open datasets and licensed to ecological consultants and researchers. Never for anything unrelated to bats.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 12) {
                Button("Start Contributing") {
                    consent.grant()
                    onDecided()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(!canContribute)

                Button("Not Now") {
                    consent.revoke()
                    onDecided()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
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
