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

enum PrivacyLinks {
    static let policyURL = URL(string: "https://openbat.app/privacy")!
    static let helpURL = URL(string: "https://openbat.app/help")!
}
