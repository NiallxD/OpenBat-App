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
//  How it identifies the button, and why not by accessibility alone.
//
//  It used to match only on the accessibility identifier we set in
//  `ContentView.sessionTabLabel`, falling back to the labels there. That is
//  public API and it is ours, so it looked like the option that didn't depend on
//  the bar's private internals — and it worked in every simulator.
//
//  **It has never worked on a real device.** A hierarchy dump from an iPad on
//  26.6 (2026-08-17) contains 465 views and not one accessibility identifier or
//  label anywhere, on any view, including the ones we set them on. UIKit does
//  not materialise accessibility attributes until an assistive technology asks
//  for them; a simulator has accessibility switched on for UI automation, so
//  there they are always populated. The consequence was that the glow, the
//  transport menu and the tap catcher were all invisible on hardware and all
//  present in the simulator, which is exactly as confusing as it sounds.
//
//  So the accessibility match is kept — it is exact, and it is what runs when
//  VoiceOver is on or under UI tests — and a structural search backs it up. The
//  structural one reads private class *names*, which is a real cost and worth
//  naming: it is introspection only, no private API is called, but it can stop
//  matching on any OS release. The failure mode when it does is the documented
//  one — nothing is found, so nothing is drawn — and Diagnostics carries a
//  "Session Button" card that says so and can share the tree again.
//
//  **There are two bar shapes, not one, and the structural search has to know
//  both.** iPad on 26 gets a `_UIFloatingTabBar` — a centred pill at the top,
//  with the session button as a *pinned item* beside the collection holding the
//  tabs. iPhone on 26 gets a plain `UITabBar`, which looks like the floating one
//  and shares none of its class names: the session button is a `_UITabButton`
//  inside a `_UITabBarAuxiliaryView`, beside the platter holding the tabs. Only
//  the iPad shape was implemented, so on every real iPhone the search found
//  nothing and the glow, the transport menu and the tour's tab spotlights were
//  all silently absent. `-locator.structuralOnly` exists so that class of bug
//  can be seen in a simulator at all; see `structuralOnly` below.
//

import SwiftUI
import UIKit

/// Where the session button is, in window coordinates. `nil` until it has been
/// found — every caller must handle that, and handle it by drawing nothing
/// rather than by falling back to a guess. A glow in the wrong place is untidy;
/// an invisible tap catcher in the wrong place eats a control the user needs.
@Observable
final class SessionButtonLocator {
    /// Where the session button is, whoever put it there.
    ///
    /// A frame the app set itself always wins: on the pre-26 bar the button is
    /// an ordinary SwiftUI view we draw, so its own geometry is exact and there
    /// is nothing to search for. See `updateSelfDrawn`.
    var frameInWindow: CGRect? { selfDrawnFrameInWindow ?? searchedFrameInWindow }

    /// The frame the view-tree search found, on the systems where the bar is
    /// the system's and draws the button for us.
    private(set) var searchedFrameInWindow: CGRect?

    /// The frame the pre-26 bar reported for the button it drew itself.
    ///
    /// **Without this, nothing that hangs off the button was drawn at all on
    /// iOS 18–25** — not the recording glow, and not the transport menu, which
    /// is the only way to arm recording, change listening mode or end a session.
    /// The search cannot find that button: SwiftUI draws ordinary views into the
    /// hosting view's layer rather than as `UIView`s, so there is no view in the
    /// tree carrying our identifier or label, and there is no `UITabBar` either
    /// — the pre-26 bar is hand-built. Every caller therefore drew nothing,
    /// exactly as documented, and the button turned into a cross that opened
    /// nothing. Caught 2026-08-30 on an iPhone 16 Pro Max simulator on 18.
    private(set) var selfDrawnFrameInWindow: CGRect?

    /// Reported by the pre-26 bar as it lays the button out. `nil` when that bar
    /// is not on screen, which hands the question back to the search.
    func updateSelfDrawn(_ frame: CGRect?) {
        guard frame != selfDrawnFrameInWindow else { return }
        selfDrawnFrameInWindow = frame
    }

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

    /// Makes the search behave the way it does on real hardware: no
    /// accessibility identifiers, no accessibility labels, structural matches
    /// only. Set with the `-locator.structuralOnly YES` launch argument.
    ///
    /// **This exists because the simulator lies.** UIKit only materialises
    /// accessibility attributes once an assistive technology asks for them, and
    /// a simulator has accessibility switched on for UI automation — so the
    /// identifier set on the `Tab` label is always found there and never found
    /// on a device. Every bug in the structural fallback is therefore invisible
    /// in a simulator by construction, which is how one shipped. With this on,
    /// a simulator exercises exactly the path hardware takes.
    static let structuralOnly = UserDefaults.standard.bool(forKey: "locator.structuralOnly")

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
        guard frame != searchedFrameInWindow else { return }
        searchedFrameInWindow = frame
    }

    /// The last view-tree dump taken while the button could not be found, or
    /// `nil` if it has always been found. Read by Diagnostics.
    ///
    /// Captured rather than printed because the failure only happens on real
    /// hardware, where there is no console to read — see `SessionButtonProbe`.
    private(set) var failureDump: String?

    func recordFailureDump(_ dump: String?) {
        failureDump = dump
    }

    /// What the search is looking for, spelled out at the top of a dump so the
    /// dump can be read without the source next to it.
    static var searchCriteria: String {
        "Looking for a view with identifier \"\(accessibilityIdentifier)\", "
            + "or with an accessibility label in \(accessibilityLabels.sorted())."
    }

    /// The live view hierarchy as text, taken on demand rather than only after
    /// the retries give up.
    ///
    /// Two failures look identical from the outside — the button never being
    /// found, and the button being found in a place nothing draws at — and the
    /// after-the-fact dump only covers the first. This covers both, because it
    /// can be taken while everything is up and working normally.
    ///
    /// Every window in every foreground scene, not just the key one: on iPad a
    /// presented sheet can be in a window of its own, and the bar we are looking
    /// for would then be in the one behind it.
    static func hierarchyDump() -> String {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard !windows.isEmpty else { return "No windows." }
        return windows.enumerated().map { index, window in
            "── Window \(index + 1) of \(windows.count) "
                + "[\(Int(window.frame.width))×\(Int(window.frame.height))]"
                + (window.isKeyWindow ? " key" : "")
                + "\n" + SessionButtonProbe.ProbeView.describe(window)
        }.joined(separator: "\n\n")
    }

    /// Which half of the window the bar put the session button in, or `nil`
    /// while the button has not been found.
    ///
    /// **Where the bar is has to be measured, not assumed from the idiom.** The
    /// things that hang off the button — the transport menu, the export banner,
    /// the not-recording nudge — each have to grow away from the bar or they
    /// open off the edge of the screen, and the code that placed them asked
    /// `UIDevice.current.userInterfaceIdiom == .pad`. That is right for an iPad
    /// filling the screen, where the bar is a centred pill at the top, and wrong
    /// for the same iPad in Split View, Slide Over or a small window, where the
    /// width is compact and the bar drops to the bottom like an iPhone's. The
    /// idiom does not change when the window does; this does.
    var buttonIsInTopHalf: Bool? {
        guard let frameInWindow, let windowHeight, windowHeight > 0 else { return nil }
        return frameInWindow.midY < windowHeight / 2
    }

    /// Height of the window the button was found in, kept only so
    /// `buttonIsInTopHalf` has something to compare against.
    private(set) var windowHeight: CGFloat?

    func updateWindowHeight(_ height: CGFloat) {
        guard height != windowHeight else { return }
        windowHeight = height
    }

    /// The tour overlay's own frame, in SwiftUI's global space.
    ///
    /// Recorded only so Diagnostics can show it. Everything the locator
    /// publishes is in *window* coordinates and has to be rebased into an
    /// overlay's space before it can be drawn, and that rebasing assumes
    /// SwiftUI's global space and the window share an origin. When a spotlight
    /// lands in the wrong place, this is the number that says whether that
    /// assumption held.
    private(set) var tourHostFrameInGlobal: CGRect?

    func recordTourHostFrame(_ frame: CGRect) {
        guard frame != tourHostFrameInGlobal else { return }
        tourHostFrameInGlobal = frame
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

        /// Rotation, size-class changes, split view — anything that resizes the
        /// screen resizes this view too, which is the whole reason it is sized
        /// to fill rather than left at zero. See `locatesSessionButton`.
        override func layoutSubviews() {
            super.layoutSubviews()
            scheduleLocate()
        }

        /// Re-checks for a while after anything that could have moved the
        /// button, and keeps checking indefinitely while it has never been found
        /// at all.
        ///
        /// **Why a burst rather than a single look.** Being told *our* geometry
        /// changed does not mean the bar has been laid out in its new position
        /// yet, so the look we take right now can return the old frame — or, at
        /// launch, nothing. Both have happened on hardware:
        /// - At launch the search used to run four times over the first second
        ///   and then stop. A Mac-hosted simulator always won that race; an iPad
        ///   starting Metal, the audio engine and the field-guide decode did not,
        ///   and losing it was permanent.
        /// - **On rotation it kept a stale frame.** The bar is centred, so
        ///   turning an iPad moves the button by half the change in width — 180
        ///   points on an 11-inch — and the glow, the transport menu and the
        ///   tour's spotlight all drew that far from the button. Diagnostics
        ///   caught it holding 535 while the live hierarchy said 715.
        ///
        /// So the burst is topped up on *every* layout pass, whether or not
        /// something was already found; a found-but-stale frame is exactly as
        /// wrong as no frame. It still stops, so the steady state is no timer.
        func scheduleLocate() {
            locate()
            // Long while nothing has ever been found, short after a layout
            // change that may have moved something already known.
            attemptsRemaining = max(attemptsRemaining,
                                    locator.frameInWindow == nil ? 120 : 8)
            guard retryTimer == nil else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return }
                    self.locate()
                    self.attemptsRemaining -= 1
                    if self.attemptsRemaining <= 0 {
                        timer.invalidate()
                        self.retryTimer = nil
                        // Only interesting if we gave up. A dump taken after a
                        // success would describe a hierarchy that worked.
                        if self.locator.frameInWindow == nil {
                            // Debug-flag only: under `-locator.structuralOnly` the
                            // whole point is to see this failure, which is
                            // otherwise invisible (nothing is drawn).
                            if SessionButtonLocator.structuralOnly, !Self.hasDumped {
                                Self.hasDumped = true
                                let dump = SessionButtonLocator.hierarchyDump()
                                let url = FileManager.default.temporaryDirectory
                                    .appending(path: "locator-dump.txt")
                                try? dump.write(to: url, atomically: true, encoding: .utf8)
                                NSLog("OPENBAT-LOCATOR-DUMP written to %@", url.path)
                            }
                            self.locator.recordFailureDump(
                                "Session button not found after 30 s of retries.\n"
                                + SessionButtonLocator.searchCriteria + "\n\n"
                                + SessionButtonLocator.hierarchyDump())
                        }
                    }
                }
            }
            retryTimer = timer
        }

        nonisolated(unsafe) static var hasDumped = false
        private var retryTimer: Timer?
        private var attemptsRemaining = 0

        func locate() {
            guard let window else { return }
            locator.updateWindowHeight(window.bounds.height)
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

        /// The system bar, when there is one. A miss falls back to the whole
        /// window rather than failing, so the pre-iOS 26 hand-built bar (which is
        /// no kind of system bar at all, and whose tabs the tour reaches by
        /// `.tourTarget` anyway) costs nothing here.
        ///
        /// **`UITabBar` alone is not enough.** On iOS 26 the bar is a
        /// `_UIFloatingTabBar` — on iPad a pill at the top, on iPhone a floating
        /// bar at the bottom — and it is not a `UITabBar` subclass, so the class
        /// check missed it on every device. Matched by name as well as by type,
        /// with the type check kept first because it is the one that cannot
        /// break.
        static func findTabBar(in root: UIView) -> UIView? {
            var stack = [root]
            while let view = stack.popLast() {
                if view is UITabBar { return view }
                if className(view).contains("FloatingTabBar") { return view }
                stack.append(contentsOf: view.subviews)
            }
            return nil
        }

        /// A view's class name, for the structural matches below. Reading a name
        /// is introspection; nothing here calls anything private.
        static func className(_ view: UIView) -> String {
            String(describing: type(of: view))
        }

        /// Every descendant whose class name contains `fragment`, outermost
        /// first.
        static func descendants(of root: UIView, named fragment: String) -> [UIView] {
            var found: [UIView] = []
            var queue = [root]
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if className(view).contains(fragment) { found.append(view) }
                queue.append(contentsOf: view.subviews)
            }
            return found
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
                if !SessionButtonLocator.structuralOnly {
                    if view.accessibilityIdentifier == identifier {
                        byIdentifier.append(view)
                    } else if view.accessibilityLabel == section.rawValue,
                              !(view is UILabel), !(view is UIImageView) {
                        byLabel.append(view)
                    }
                }
                stack.append(contentsOf: view.subviews)
            }
            let matches = byIdentifier.isEmpty ? byLabel : byIdentifier
            if let match = matches
                .filter(isDrawn)
                .min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
                return match
            }
            return structuralTab(section, in: root)
        }

        /// The tabs by position, for the usual case where no accessibility text
        /// exists to match on.
        ///
        /// The bar lays its ordinary tabs out as item cells in a collection, in
        /// the order they were declared — which is `AppSection.allCases`, since
        /// that is what `ContentView.systemTabs` iterates. So the nth cell from
        /// the left is the nth section. Sorted by position rather than trusting
        /// subview order, which is the bar's business and not documented.
        ///
        /// The session button is deliberately not among these: it is a pinned
        /// item, outside the collection. See `structuralSessionButton`.
        static func structuralTab(_ section: AppSection, in root: UIView) -> UIView? {
            guard let index = AppSection.allCases.firstIndex(of: section) else { return nil }
            var cells = descendants(of: root, named: "FloatingTabBarItemCell").filter(isDrawn)
            if cells.isEmpty {
                // The plain-`UITabBar` shape — see `structuralSessionButton`.
                // The tabs are `_UITabButton`s; the session button is one too,
                // so the auxiliary view's own is excluded. The bar also keeps a
                // second, identically framed copy of the whole row behind the
                // selection lens, which is what the de-dup by frame is for:
                // without it there are six "tabs" and the count check below
                // rejects the lot.
                let auxiliary = descendants(of: root, named: "TabBarAuxiliaryView")
                let buttons = descendants(of: root, named: "TabButton").filter { button in
                    isDrawn(button) && !auxiliary.contains { button.isDescendant(of: $0) }
                }
                var seen: [CGRect] = []
                for button in buttons {
                    let frame = button.convert(button.bounds, to: nil)
                    if seen.contains(frame) { continue }
                    seen.append(frame)
                    cells.append(button)
                }
            }
            cells.sort { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
            // A count mismatch means the bar is laid out in a way this doesn't
            // understand — paginated, collapsed, mid-transition. Guessing which
            // cell is which at that point is how the tour ends up spotlighting
            // the wrong tab, so it declines instead.
            guard cells.count == AppSection.allCases.count else { return nil }
            return cells[index]
        }

        /// A view big enough to be the thing itself rather than a zero-sized
        /// label or a collapsed container.
        static func isDrawn(_ view: UIView) -> Bool {
            view.bounds.width > 1 && view.bounds.height > 1
        }

        /// The window's view tree as text: class, frame, and the two
        /// accessibility values the search matches on.
        ///
        /// This exists because the search has now failed on a real iPad while
        /// succeeding on every simulator, and the two candidate causes — the bar
        /// not being laid out yet, versus the bar not carrying our accessibility
        /// text into its own views on device — are indistinguishable from the
        /// outside. The tree says which. Only taken after the retries give up,
        /// so it costs nothing in the normal case.
        static func describe(_ window: UIWindow) -> String {
            var lines: [String] = []
            // Marked so a dump can be read against what the search concluded,
            // rather than only against what it was looking for. Resolved once,
            // not per line.
            let bar = findTabBar(in: window)
            let button = structuralSessionButton(in: window)
            func walk(_ view: UIView, depth: Int) {
                // A cap rather than no cap, but a generous one: the bar is
                // typically last in the window's subviews, so truncating early
                // would drop the one part of the tree this is being taken for.
                guard depth < 40 else { return }
                guard lines.count < 6000 else {
                    if lines.last != "… truncated" { lines.append("… truncated") }
                    return
                }
                let frame = window.convert(view.bounds, from: view)
                var line = String(repeating: "  ", count: depth) + String(describing: type(of: view))
                line += String(format: " [%.0f,%.0f %.0f×%.0f]",
                               frame.minX, frame.minY, frame.width, frame.height)
                if view === bar { line += " ←bar" }
                if view === button { line += " ←session button" }
                if let id = view.accessibilityIdentifier { line += " id=\"\(id)\"" }
                if let label = view.accessibilityLabel { line += " label=\"\(label)\"" }
                if view.isHidden { line += " hidden" }
                lines.append(line)
                for subview in view.subviews { walk(subview, depth: depth + 1) }
            }
            walk(window, depth: 0)
            return lines.joined(separator: "\n")
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
                if !SessionButtonLocator.structuralOnly {
                    if view.accessibilityIdentifier == SessionButtonLocator.accessibilityIdentifier {
                        matches.append(view)
                    } else if let label = view.accessibilityLabel,
                              SessionButtonLocator.accessibilityLabels.contains(label) {
                        matches.append(view)
                    }
                }
                stack.append(contentsOf: view.subviews)
            }
            // A zero-size match is a label with no drawing of its own; it tells
            // us nothing about where the button is.
            if let match = matches
                .filter(isDrawn)
                .min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
                return match
            }
            return structuralSessionButton(in: root)
        }

        /// The session button by its position in the bar, for the usual case
        /// where no accessibility text exists to match on.
        ///
        /// `Tab(role: .search)` is not laid out with the ordinary tabs. The bar
        /// puts it in a *pinned items* view of its own, beside the collection
        /// holding the rest — which is what makes it identifiable without any
        /// text: it is the one item that is not one of the tabs.
        ///
        /// The item inside that container is preferred over the container
        /// itself, because the container carries the bar's full height while the
        /// item is the button as drawn — and the glow, the menu's width and the
        /// tap catcher's circle are all sized from what comes back. Measured on
        /// an iPad on 26.6: container 46×44, item 46×36.
        static func structuralSessionButton(in root: UIView) -> UIView? {
            guard let bar = findTabBar(in: root) else { return nil }

            // The floating bar — an iPad on 26, and anywhere else the system
            // chooses it. Measured on an iPad on 26.6: container 46×44, item
            // 46×36.
            if let pinned = descendants(of: bar, named: "PinnedItems").first(where: isDrawn) {
                return descendants(of: pinned, named: "TabBarItemView")
                    .first(where: isDrawn) ?? pinned
            }

            // **A plain `UITabBar`, which is what iPhone has on 26.** The bar
            // looks like the floating one and is not one: it is a real
            // `UITabBar`, and none of the floating bar's class names appear
            // anywhere inside it. So this search found nothing on every iPhone —
            // and, because a simulator always answers the accessibility match
            // that runs first, nothing about that was visible until the
            // `-locator.structuralOnly` flag was added to force the device path.
            // The symptom on hardware was the session button turning into a
            // cross that opened no menu, with no glow behind it while listening.
            //
            // The shape is the same idea as the floating bar's: the detached
            // circle is the one item that is not one of the tabs, held in an
            // *auxiliary* view beside the platter that holds them. Measured on
            // an iPhone 17 Pro, iOS 26.5: auxiliary 62×62, the button inside it
            // the same.
            if let auxiliary = descendants(of: bar, named: "TabBarAuxiliaryView").first(where: isDrawn) {
                return descendants(of: auxiliary, named: "TabButton").first(where: isDrawn) ?? auxiliary
            }
            return nil
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
    ///
    /// **Sized to fill, deliberately.** It was `.frame(width: 0, height: 0)`,
    /// which is the obvious way to say "this draws nothing" — and it meant the
    /// probe's bounds never changed, so UIKit never called `layoutSubviews` on
    /// it, so rotating the iPad never triggered a fresh look and the button's
    /// frame stayed where it was in the previous orientation. A background does
    /// not affect its parent's layout at any size, and the view is hidden and
    /// takes no touches, so filling costs nothing and buys the one notification
    /// this needs.
    func locatesSessionButton(_ locator: SessionButtonLocator) -> some View {
        background {
            SessionButtonProbe(locator: locator)
                .allowsHitTesting(false)
        }
    }
}
