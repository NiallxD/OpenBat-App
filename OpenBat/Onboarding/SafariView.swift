//
//  SafariView.swift
//  OpenBat
//
//  In-app browser sheet (Safari View Controller), so privacy-notice links open
//  without leaving the app — used from both OnboardingView and ConsentView.
//

import SwiftUI
import SafariServices

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

/// Canonical locations of the published privacy pages. Source copy for both
/// lives outside this repo, in `../Privacy/website/` — change it there, publish,
/// then change these if a path moves.
enum PrivacyLinks {
    /// The formal notice. Also the URL given to App Store Connect as the app's
    /// privacy policy, so these two must stay the same page.
    ///
    /// Previously pointed at `/privacy`, which is the short plain-language
    /// summary — so the consent screen's "Read the full privacy notice" button
    /// opened something that explicitly isn't the full notice.
    static let policyURL = URL(string: "https://openbat.app/privacy-policy")!

    /// Plain-language explainer — how contributions are anonymised, and what
    /// that does and doesn't protect. Shorter and far more readable than the
    /// policy; the page most people actually want.
    static let explainerURL = URL(string: "https://openbat.app/privacy")!

    static let helpURL = URL(string: "https://openbat.app/help")!
}
