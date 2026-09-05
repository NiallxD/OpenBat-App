//
//  AboutAppTour.swift
//  OpenBat
//
//  The second tour: a paged walk through what bat detecting *is* and what the
//  app does about it, reached from Info & Tour.
//
//  Where these pages came from. They were the middle of onboarding — how
//  echolocation works, the two ways of hearing a call, microphone calibration,
//  and how much of the detector to show. Onboarding was cut to three screens on
//  2026-08-17 (Niall's call): welcome, the permissions ask, and the caveat about
//  identifications. Everything else was explaining the hobby to someone who had
//  not yet been allowed to open the app.
//
//  None of it was wrong, though, and it is the part a curious user actually
//  wants — just *after* they have heard a bat rather than before. So it moved
//  here rather than being deleted, and Info & Tour now offers two tours that do
//  genuinely different jobs:
//
//    • the guided tour  — spotlights the real controls on the real Detector
//      screen ("what is this button")
//    • this one         — the concepts behind them ("why would I want it")
//
//  Deliberately NOT a `TourStep`/`TourOverlay` script: nothing here points at a
//  control, so there is nothing to spotlight. It is the onboarding layout — a
//  progress bar, a header, a stack of cards, a pinned button bar — because that
//  is the shape these pages were written for, and reusing it costs nothing:
//  `OnboardingStepView`, `OnboardingCard` and `OnboardingProgressBar` are all
//  shared with the real flow, so the two cannot drift apart visually.
//

import SwiftUI

struct AboutAppTour: View {
    @Environment(\.dismiss) private var dismiss

    /// The interface mode. A live binding to the real setting, not a copy — the
    /// view-mode page carries the same toggle Settings does, so reading about it
    /// and changing it are the same action. That was true when this page lived in
    /// onboarding and it is the reason the page is worth keeping.
    @AppStorage(SimplifiedView.key) private var simplifiedMode = true

    private enum Page: Int, CaseIterable {
        case echolocation, listening, calibrate, viewMode, findingThings
    }

    @State private var page: Page = .echolocation
    /// Drives the direction of the page transition, so Back slides the opposite
    /// way to Next rather than both looking like "forward".
    @State private var isMovingBackward = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                OnboardingProgressBar(completed: page.rawValue, total: Page.allCases.count)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                // Top-aligned and scrolling, for the reasons `OnboardingView`'s
                // own body documents at length: centring moves the header from
                // page to page, and a ScrollView will happily compress flexible
                // content rather than scroll it unless it is given its ideal
                // height.
                ScrollView {
                    content
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .id(page)
                        .transition(pageTransition)
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        .padding(.bottom, 24)
                }

                footer
                    .id(page)
                    .transition(.opacity)

                controls
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
            }
            .background(Color.appBackground)
            .navigationTitle("About the app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sensoryFeedback(.selection, trigger: page)
        }
    }

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: isMovingBackward ? .leading : .trailing).combined(with: .opacity),
            removal: .move(edge: isMovingBackward ? .trailing : .leading).combined(with: .opacity))
    }

    // MARK: - Pages

    @ViewBuilder
    private var content: some View {
        switch page {
        case .echolocation:
            VStack(spacing: 20) {
                OnboardingStepView(
                    hero: { BounceInGlyph(assetName: "batCall") },
                    title: "Echolocation",
                    message: "To navigate and hunt, a bat shouts dozens of times per second as it flies, then listens for the echo to build a picture of the world around it.")

                VStack(spacing: 10) {
                    OnboardingCard(
                        systemImage: "arrow.up.right.circle.fill",
                        title: "Too high to hear",
                        detail: "Most calls sit between 20 and 120 kHz. Human hearing gives out around 20 kHz, so almost all of it passes by in silence — which is where a bat detector comes in.")
                    OnboardingCard(
                        systemImage: "metronome.fill",
                        title: "The rhythm tells you a lot",
                        detail: "A searching bat calls steadily. As it closes on an insect the calls speed up into a feeding buzz — the moment most bat workers listen for.")
                }
            }

        case .listening:
            VStack(spacing: 20) {
                OnboardingStepView(
                    systemImage: "waveform.and.person.filled",
                    title: "Hearing them",
                    message: "OpenBat brings each call down into your hearing range as it arrives — two ways round, and you can switch between them while you listen.")

                VStack(spacing: 10) {
                    OnboardingCard(
                        systemImage: "headphones",
                        title: "Hear it",
                        detail: "Calls are shifted down into the audible range live, so a pass sounds like the characteristic clicks and warble bat workers listen for.")
                    OnboardingCard(
                        systemImage: "tortoise.fill",
                        title: "Slow it down",
                        detail: "Slow replay grabs a short snippet of a call and plays it back at a fraction of its speed, which brings out detail the shifted-down version glosses over. The detector is deaf while a snippet replays — a trade you choose in Settings.")
                    OnboardingCard(
                        systemImage: "hand.tap.fill",
                        title: "Feel it",
                        detail: "To make bat detecting accessible to all, each call can also be rendered as a vibration — its strength tracks how close the bat is, and its texture changes with the kind of call, so a feeding buzz feels different from a passing bat. Turn it on under Audio in Settings.")
                }
            }

        case .calibrate:
            VStack(spacing: 20) {
                OnboardingStepView(
                    systemImage: "tuningfork",
                    title: "Calibrate your microphone",
                    message: "Optional, takes about 15 seconds, and it lives under Microphone in Settings whenever you want it.")

                VStack(spacing: 10) {
                    OnboardingCard(
                        systemImage: "waveform.path.ecg",
                        title: "Why it helps",
                        detail: "Affordable ultrasonic microphones have an uneven frequency response, which shows up as fixed noise bands across the spectrogram and skews frequency measurements.")
                    OnboardingCard(
                        systemImage: "ear.badge.waveform",
                        title: "What happens",
                        detail: "Find somewhere quiet and OpenBat listens to your microphone's own noise floor for 15 seconds, then corrects for it. It doesn't change or upload any recording.")
                }
            }

        case .viewMode:
            VStack(spacing: 20) {
                OnboardingStepView(
                    systemImage: "slider.horizontal.below.rectangle",
                    title: "How should it look?",
                    message: "Two questions about the app rather than about bats. Both are the first things in Settings, and neither is permanent.")

                // A real toggle rather than two choice cards: this is one
                // setting with two states, it lives in Settings as a toggle,
                // and showing it here in the same form it will take there is
                // what makes "you can change this later" a findable promise
                // rather than a vague one.
                VStack(spacing: 14) {
                    // Same invert as the Settings toggle this mirrors — off is
                    // the default (simplified), on opts into everything. See
                    // that toggle's comment in SettingsView for why the
                    // presentation is flipped from `simplifiedMode` itself.
                    Toggle("Advanced mode", isOn: Binding(
                        get: { !simplifiedMode },
                        set: { simplifiedMode = !$0 }
                    ))
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        // Same tile as the cards under it — this switch is one of the
                        // row of things on this page, not a control of a
                        // different kind.
                        .glassTile()

                    OnboardingCard(
                        systemImage: simplifiedMode ? "eye" : "eye.trianglebadge.exclamationmark",
                        title: simplifiedMode ? "You'll see" : "You'll see everything",
                        detail: simplifiedMode
                            ? "A running list of every species heard, the input level, and the spectrogram. Enough to know which bat flew over."
                            : "Every readout and control: peak frequency, bandwidth, duration and pulse rate, the pulse close-up, and the timeline, palette and frequency-band controls.")
                    // Asked here because it is the other question about how
                    // the app looks, and asking both on one page is what makes
                    // this the page a user remembers going back to (Niall,
                    // 2026-09-02). Same control as Settings shows, for the same
                    // reason the toggle above is a real toggle.
                    AppearancePicker()
                        .padding(.top, 6)
                    OnboardingCard(
                        systemImage: "circle.lefthalf.filled",
                        title: "Light, dark, or the phone's own",
                        detail: "Device follows whatever your phone is set to, including its schedule — that's the default. Pick one outright if you'd rather OpenBat stayed dark in daylight, or light at night.")

                    OnboardingCard(
                        systemImage: "gearshape.fill",
                        title: "Change them any time",
                        detail: "Both are in Settings, under Interface, and nothing is lost by switching either way — anything you've adjusted is kept and comes back.")
                }
                .padding(.top, 4)
            }

        case .findingThings:
            VStack(spacing: 20) {
                OnboardingStepView(
                    systemImage: "square.grid.2x2",
                    title: "Where everything is",
                    message: "Three tabs along the bottom, and the round button beside them starts a session.")

                VStack(spacing: 10) {
                    OnboardingCard(
                        systemImage: "gearshape.fill",
                        title: "Everything is changeable",
                        detail: "Microphone and location access, listening mode, haptics and calibration all live in Settings, and none of these choices are permanent.")
                    OnboardingCard(
                        systemImage: "questionmark.circle.fill",
                        title: "Stuck?",
                        detail: "Help — in the top-right options menu, alongside Settings — covers which microphones work, how to read the spectrogram, and what to do when nothing seems to be coming through.")
                    // The other tour, named from inside this one, because the
                    // two answer different questions and someone reading this
                    // page is exactly the person who wants the other.
                    OnboardingCard(
                        systemImage: "sparkles",
                        title: "Want the buttons named?",
                        detail: "The guided tour, on the Info & Tour screen you came from, points at each control on the detector in turn and says what it does.")
                }
            }
        }
    }

    /// Content pinned below the scrolling column — same slot `OnboardingView`
    /// uses, so a page that had a footer there still has it here.
    @ViewBuilder
    private var footer: some View {
        switch page {
        case .echolocation:
            EcholocationDiagram()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 28)
        default:
            EmptyView()
        }
    }

    // MARK: - Controls

    /// Same fixed-slot bottom bar as onboarding's, minus the Skip case — nothing
    /// here is skippable, because nothing here does anything. See
    /// `OnboardingView.controls` for why the slots are fixed-width.
    private var controls: some View {
        HStack(spacing: 12) {
            Button { goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(height: 22)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(page == .echolocation)
            .opacity(page == .echolocation ? 0 : 1)
            .accessibilityLabel("Back")
            .accessibilityHidden(page == .echolocation)
            .frame(width: Self.sideSlotWidth, alignment: .leading)

            Button { advance() } label: {
                Text(page == .findingThings ? "Done" : "Next")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.batAccent)

            Spacer()
                .frame(width: Self.sideSlotWidth)
        }
        .animation(.snappy(duration: 0.28), value: page)
    }

    private static let sideSlotWidth: CGFloat = 80

    // MARK: - Navigation

    private func advance() {
        guard let next = Page(rawValue: page.rawValue + 1) else { dismiss(); return }
        go(to: next)
    }

    private func goBack() {
        guard let previous = Page(rawValue: page.rawValue - 1) else { return }
        go(to: previous)
    }

    private func go(to next: Page) {
        isMovingBackward = next.rawValue < page.rawValue
        withAnimation(.snappy(duration: 0.28)) { page = next }
    }
}
