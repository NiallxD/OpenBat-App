//
//  SessionButtonLocator.swift
//  OpenBat
//
//  Finds out where the system tab bar actually put the session button, so the
//  things that hang off it — the recording glow behind it, the tap catcher in
//  front of it — can be placed against the real thing rather than against a
//  guess. It locates the ordinary tabs the same way, for the guided tour's
//  spotlight; everything below about *why* applies equally to those.
//
//  Why this exists. On iOS 26 the session button is a `Tab(role: .search)`,
//  drawn by the bar, and the bar tells us nothing about where it drew it. The
//  first version worked from hand-measured constants, which were wrong twice on
//  iPhone before they were right, and on iPad were not merely wrong but
//  dangerous: the bar there is a *centred pill at the top* with the button
//  inside it, so the iPhone geometry put an invisible tap catcher squarely on
//  the Settings gear, where it would have silently eaten every tap.
//
//  A constant cannot describe a layout that depends on the idiom, the
//  orientation, the pill's width and therefore the language of the tab titles.
//  Asking the view hierarchy where the button is does, on every device, in every
//  orientation, for free.
//
//  How it identifies the button, and why by accessibility. The button is found
//  by its accessibility identifier, falling back to the accessibility labels the
//  Tab's own label sets. Both are public API and both are *ours* — set in
//  `ContentView.sessionTabLabel` — so this doesn't depend on private view class
//  names or on the bar's internal view arrangement, which is what would
//  otherwise break on the next OS release.
//

import SwiftUI
import UIKit

/// Where the session button is, in window coordinates. `nil` until it has been
/// found — every caller must handle that, and handle it by drawing nothing
/// rather than by falling back to a guess. A glow in the wrong place is untidy;
/// an invisible tap catcher in the wrong place eats a control the user needs.
@Observable
final class SessionButtonLocator {
    private(set) var frameInWindow: CGRect?

    /// Where the bar put each ordinary tab, in window coordinates. Empty until
    /// found, and missing entries are normal — same contract as `frameInWindow`:
    /// draw nothing rather than guess.
    ///
    /// Only the guided tour needs these, and only so it can spotlight a real tab
    /// rather than gesture at the bottom of the screen. They come from the same
    /// search as the session button for the same reason: on iOS 26 a `Tab`'s
    /// label is rendered by the bar, outside the normal view tree, so a
    /// `.tourTarget` anchor placed on one never reaches the preference the
    /// overlay reads.
    private(set) var tabFramesInWindow: [AppSection: CGRect] = [:]

    /// Identifier set on the Tab's label and matched here. Also the reason this
    /// is a shared constant rather than two string literals that can drift.
    static let accessibilityIdentifier = "openbat.session-button"

    /// The labels `ContentView.sessionTabLabel` gives the button across its
    /// three states, used when the identifier doesn't survive the trip into the
    /// bar's own view tree.
    static let accessibilityLabels: Set<String> = [
        "Start session", "Session controls", "Close session controls"
    ]

    /// Per-tab identifier, set in `ContentView.systemTabs`. Same
    /// identifier-then-label pairing as the session button above.
    static func tabIdentifier(_ section: AppSection) -> String {
        "openbat.tab.\(section.rawValue)"
    }

    func update(_ frame: CGRect?) {
        guard frame != frameInWindow else { return }
        frameInWindow = frame
    }

    func updateTabs(_ frames: [AppSection: CGRect]) {
        guard frames != tabFramesInWindow else { return }
        tabFramesInWindow = frames
    }
}

/// A zero-sized view whose only job is to be in the hierarchy, so it can reach
/// the window and search it.
struct SessionButtonProbe: UIViewRepresentable {
    let locator: SessionButtonLocator

    func makeUIView(context: Context) -> ProbeView {
        ProbeView(locator: locator)
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.locator = locator
        uiView.scheduleLocate()
    }

    final class ProbeView: UIView {
        var locator: SessionButtonLocator

        init(locator: SessionButtonLocator) {
            self.locator = locator
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleLocate()
        }

        /// Fires whenever this view's parent re-lays-out, which covers rotation
        /// and size-class changes — the two things that actually move the
        /// button once the app is up.
        override func layoutSubviews() {
            super.layoutSubviews()
            locate()
        }

        /// The bar is not necessarily laid out at the moment SwiftUI first
        /// hands us a window, so the first look often finds nothing. Retrying
        /// on a few short delays costs nothing and saves the alternative, which
        /// is polling forever.
        func scheduleLocate() {
            locate()
            for delay in [0.05, 0.2, 0.5, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.locate()
                }
            }
        }

        func locate() {
            guard let window else { return }
            let found = Self.findSessionButton(in: window)
            locator.update(found.map { window.convert($0.bounds, from: $0) })

            // Scoped to the tab bar's own subtree where one can be found. The
            // section titles are ordinary words — "Sessions" and "Species" both
            // appear elsewhere on the Detector — so searching the whole window
            // for them by label would happily match a pill in the stats header.
            // Inside the bar there is nothing else they could be.
            let searchRoot = Self.findTabBar(in: window) ?? window
            var tabs: [AppSection: CGRect] = [:]
            for section in AppSection.allCases {
                if let view = Self.findTab(section, in: searchRoot) {
                    tabs[section] = window.convert(view.bounds, from: view)
                }
            }
            locator.updateTabs(tabs)
        }

        /// The system bar, when there is one. `UITabBar` is public API and this
        /// only narrows the search — a miss falls back to the whole window rather
        /// than failing, so the pre-iOS 26 hand-built bar (which is not a
        /// `UITabBar` at all, and whose tabs the tour reaches by `.tourTarget`
        /// anyway) costs nothing here.
        static func findTabBar(in root: UIView) -> UIView? {
            var stack = [root]
            while let view = stack.popLast() {
                if view is UITabBar { return view }
                stack.append(contentsOf: view.subviews)
            }
            return nil
        }

        /// One tab: the whole item, icon and title together.
        ///
        /// Identifier matches are preferred outright, and label matches exclude
        /// `UILabel` and `UIImageView`. Both rules exist for the same reason —
        /// **a `UILabel` derives its accessibility label from its own text**, so
        /// the title inside the Sessions tab answers to "Sessions" exactly as the
        /// tab itself does. Taking the smallest match without excluding it (which
        /// is what the session button's search can safely do — nothing inside it
        /// is a label reading "Start session") drew the spotlight ring around the
        /// word and left the icon above it out in the dark.
        static func findTab(_ section: AppSection, in root: UIView) -> UIView? {
            let identifier = SessionButtonLocator.tabIdentifier(section)
            var byIdentifier: [UIView] = []
            var byLabel: [UIView] = []
            var stack = [root]
            while let view = stack.popLast() {
                if view.accessibilityIdentifier == identifier {
                    byIdentifier.append(view)
                } else if view.accessibilityLabel == section.rawValue,
                          !(view is UILabel), !(view is UIImageView) {
                    byLabel.append(view)
                }
                stack.append(contentsOf: view.subviews)
            }
            let matches = byIdentifier.isEmpty ? byLabel : byIdentifier
            return matches
                .filter { $0.bounds.width > 1 && $0.bounds.height > 1 }
                .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        }

        /// Depth-first search for the button. Identifier first — it is exact —
        /// then the labels, which are what survive when the bar rebuilds the
        /// item as its own view and carries only the accessibility text across.
        ///
        /// Returns the *smallest* match rather than the first: an ancestor
        /// container can inherit the label of the item inside it, and taking the
        /// ancestor would hand back a frame spanning the whole bar.
        static func findSessionButton(in root: UIView) -> UIView? {
            var matches: [UIView] = []
            var stack = [root]
            while let view = stack.popLast() {
                if view.accessibilityIdentifier == SessionButtonLocator.accessibilityIdentifier {
                    matches.append(view)
                } else if let label = view.accessibilityLabel,
                          SessionButtonLocator.accessibilityLabels.contains(label) {
                    matches.append(view)
                }
                stack.append(contentsOf: view.subviews)
            }
            // A zero-size match is a label with no drawing of its own; it tells
            // us nothing about where the button is.
            return matches
                .filter { $0.bounds.width > 1 && $0.bounds.height > 1 }
                .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        }
    }
}

/// Places its content exactly on the session button, wherever the bar put it.
///
/// The frame arrives in window coordinates, so this converts through the host's
/// own global frame rather than assuming the two spaces share an origin —
/// which they don't, once a screen is inset by a bar or a safe area. That
/// conversion is why this is a `GeometryReader` and not a plain `.offset`.
///
/// Draws nothing until the button has been found. Every caller must be able to
/// live with that: the alternative is drawing in a guessed position, which on
/// iPad put an invisible tap catcher on the Settings gear.
struct SessionButtonAnchored<Content: View>: View {
    let locator: SessionButtonLocator
    @ViewBuilder let content: (CGSize) -> Content

    var body: some View {
        GeometryReader { proxy in
            if let button = locator.frameInWindow {
                let host = proxy.frame(in: .global)
                content(button.size)
                    .position(x: button.midX - host.minX,
                              y: button.midY - host.minY)
            }
        }
        // So this never takes part in its parent's layout, only its drawing.
        .allowsHitTesting(locator.frameInWindow != nil)
    }
}

/// Hangs its content off the session button — directly above it or directly
/// below it, centred on it, wherever the bar put it.
///
/// This is what makes the transport menu grow out of the button on every
/// device. It used to be pinned to the window's trailing edge with the bar's
/// own metrics, which is roughly right on iPhone and simply wrong on iPad,
/// where the button is in the middle of a pill at the top and the menu sat over
/// at the screen's edge with nothing above it.
struct SessionButtonAttached<Content: View>: View {
    let locator: SessionButtonLocator
    /// Which side of the button to grow from — away from the bar, so the menu
    /// opens onto the screen rather than off the edge of it.
    let placement: TransportMenuPlacement
    let gap: CGFloat
    /// Handed the button's measured width, so content can size itself to match.
    @ViewBuilder let content: (CGFloat) -> Content

    /// The content's own size, needed because placing something *beside*
    /// another thing means knowing how big it is; `position` centres.
    @State private var contentSize: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            if let button = locator.frameInWindow {
                let host = proxy.frame(in: .global)
                content(button.width)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
                    .position(x: button.midX - host.minX,
                              y: centreY(button: button, hostMinY: host.minY))
                    // The first layout pass has no size yet, so the content
                    // would flash at the wrong place before settling. One frame
                    // of nothing is better than one frame of somewhere else.
                    .opacity(contentSize == .zero ? 0 : 1)
            }
        }
    }

    private func centreY(button: CGRect, hostMinY: CGFloat) -> CGFloat {
        switch placement {
        case .above: button.minY - hostMinY - gap - contentSize.height / 2
        case .below: button.maxY - hostMinY + gap + contentSize.height / 2
        }
    }
}

extension View {
    /// Attaches the probe without affecting layout.
    func locatesSessionButton(_ locator: SessionButtonLocator) -> some View {
        background {
            SessionButtonProbe(locator: locator)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }
}
