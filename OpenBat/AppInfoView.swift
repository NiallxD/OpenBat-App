//
//  AppInfoView.swift
//  OpenBat
//
//  "Info" sheet (what the app does) launched from the leading toolbar menu, plus
//  the guided spotlight tour it can kick off. The tour dims the whole screen and
//  cuts a hole over one real control at a time, with a caption explaining it.
//
//  The tour highlights live controls by their on-screen bounds: each control is
//  tagged with `.tourTarget(_:)`, ContentView collects the anchors via
//  `.overlayPreferenceValue`, and `TourOverlay` resolves them to rects. A step
//  whose target isn't on screen in the current orientation just shows a centred
//  card (no cutout) instead — so the tour degrades gracefully rather than
//  pointing at nothing.
//

import SwiftUI
import UIKit

// MARK: - Tour target plumbing

/// Stable IDs for the controls the tour can spotlight. Each is attached to both
/// the portrait and landscape variant of its control (only one is ever in the
/// view tree, so only one anchor is recorded).
enum TourID: Hashable {
    // The three panes, top to bottom.
    case stats, pulseView, spectrogram
    // Individual buttons. Tagged on the shared button properties, so the portrait
    // and landscape placements both resolve to whichever one is in the tree.
    case micStatus, resetStats                 // stats header (micStatus: portrait only)
    case pulseSpeciesToggle, pulseSettings     // pulse-view header
    case spectrogramSpeciesToggle, compressTimeline, batRange, palette, bandSettings
    case start, record, listen                 // transport bar
}

struct TourTargetKey: PreferenceKey {
    static let defaultValue: [TourID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourID: Anchor<CGRect>],
                       nextValue: () -> [TourID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension View {
    /// Tag a control so the guided tour can spotlight it. Cheap and inert when no
    /// tour is running (it only publishes a bounds anchor).
    ///
    /// Must be `transformAnchorPreference`, not `anchorPreference`: targets nest
    /// (buttons tagged inside a pane that is itself tagged), and a plain
    /// `anchorPreference` on the outer view REPLACES the dictionary its descendants
    /// accumulated — the key's `reduce` only merges siblings, not parent/child —
    /// silently dropping every button anchor inside a tagged pane.
    func tourTarget(_ id: TourID) -> some View {
        transformAnchorPreference(key: TourTargetKey.self, value: .bounds) { dict, anchor in
            dict[id] = anchor
        }
    }
}

// MARK: - Tour script

struct TourStep: Identifiable {
    let id = UUID()
    /// The control to spotlight, or nil for a centred, no-cutout card.
    let target: TourID?
    let symbol: String
    /// Rotation applied to the card's symbol, matching icons the UI itself renders
    /// rotated (the bat-range button draws its bracket at -90°).
    var symbolRotation: Angle = .zero
    let title: String
    let detail: String
}

enum TourScript {
    // Walks the screen top-to-bottom: each pane first, then each button inside it
    // individually, then the transport bar buttons, then the menus.
    static let steps: [TourStep] = [
        TourStep(target: nil, symbol: "hand.wave",
                 title: "Welcome to OpenBat",
                 detail: "A real-time bat detector for the ultrasonic mic. Here's a quick tour of the screen — tap Next to step through, or End tour any time."),

        TourStep(target: .stats, symbol: "chart.bar",
                 title: "Live stats",
                 detail: "Peak frequency, bandwidth, duration, pulse rate and count for the most recent pulse, plus the current species ID and input level. They clear when activity goes stale."),
        TourStep(target: .micStatus, symbol: "cable.connector",
                 title: "Mic status",
                 detail: "Shows whether the ultrasonic mic is attached and the sample rate it's running at."),
        TourStep(target: .resetStats, symbol: "arrow.counterclockwise",
                 title: "Reset stats",
                 detail: "Clears the pulse count, pulse rate and the level meter's peak-hold."),

        TourStep(target: .pulseView, symbol: "waveform.path.ecg",
                 title: "Pulse view & Species ID",
                 detail: "A zoomed, onset-aligned render of the latest call. Pinch and drag to inspect it. It can also show the live Species ID feed instead."),
        TourStep(target: .pulseSpeciesToggle, symbol: "sparkle.magnifyingglass",
                 title: "Species ID feed",
                 detail: "The bat glyph swaps this pane between the pulse close-up and the live Species ID feed. In the feed, tap any ID for the pulses and scores behind it."),
        TourStep(target: .pulseSettings, symbol: "slider.horizontal.3",
                 title: "Pulse view settings",
                 detail: "Display settings for the pulse close-up — zoom window span and noise floor."),

        TourStep(target: .spectrogram, symbol: "waveform.badge.magnifyingglass",
                 title: "Spectrogram",
                 detail: "The scrolling frequency-vs-time view. Drag to scroll back through history."),
        TourStep(target: .spectrogramSpeciesToggle, symbol: "sparkle.magnifyingglass",
                 title: "Species ID here too",
                 detail: "Swaps this pane to the Species ID feed, same as in the pulse view — handy in landscape when the spectrogram is full screen."),
        TourStep(target: .compressTimeline, symbol: "lines.measurement.horizontal.aligned.bottom",
                 title: "Compress timeline",
                 detail: "Drops the silent gaps so the display shows just the detected pulses, back-to-back."),
        TourStep(target: .batRange, symbol: "minus.plus.lines.measurement.horizontal.aligned.bottom",
                 symbolRotation: .degrees(-90),
                 title: "Bat frequency band",
                 detail: "One-tap preset snapping the frequency axis to 15–90 kHz, where most bat calls live. Tap again to restore the full range."),
        TourStep(target: .palette, symbol: "paintpalette",
                 title: "Colour palette",
                 detail: "Picks the colormap for the spectrogram and pulse view — Inferno, Viridis, Jet and friends."),
        TourStep(target: .bandSettings, symbol: "slider.horizontal.3",
                 title: "Display range",
                 detail: "Fine control over the displayed frequency range, time window and noise floor."),

        TourStep(target: .start, symbol: "ear",
                 title: "Start & stop",
                 detail: "Starts and stops detecting. A Session logs IDs with a GPS track on a map; Just Listening logs to the Listening bucket."),
        TourStep(target: .record, symbol: "record.circle",
                 title: "Record",
                 detail: "Arms WAV recording — each detected pass is saved as its own file, with the species ID in its metadata."),
        TourStep(target: .listen, symbol: "headphones",
                 title: "Listen",
                 detail: "Cycles the listen mode — heterodyne or time-expansion — so you can hear the bats live. Tap again for off."),

        TourStep(target: nil, symbol: "line.3.horizontal.decrease.circle",
                 title: "Menus",
                 detail: "Top-left switches between Detector and Sessions and reopens this Info screen. Top-right (on Detector) holds Settings and Diagnostics. That's the tour — happy detecting!"),
    ]
}

// MARK: - Info sheet

struct AppInfoView: View {
    /// Requests the guided tour. Called before the sheet dismisses itself; the
    /// host launches the tour from the sheet's onDismiss, once it's actually gone.
    var startTour: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    section("What it does",
                            "OpenBat turns iOS compatible ultrasonic USB microphones into live bat detectors. It captures audio at up to 384 kHz, shows a real-time spectrogram, detects individual echolocation pulses, and identifies the species with an on-device classifier if classifiers (sometimes called models) are openly available for a region.")
                    
                    section("The Origin of OpenBat",
                            "OpenBat exists to make bat observing accessible to everyone. Most tools for identifying bat calls are expensive, proprietary, and hard to get hold of, which puts the experience out of reach for a lot of people who'd genuinely enjoy it. Free apps that work with ultrasonic microphones already exist, but as far as I know, none of them use the open-source machine learning models that have been trained on bat echolocation calls. By building that identification directly into the app, we can help people put a name to the call they just heard. That small moment of recognition does a lot to build a real connection with bats, and with it, a bit more respect for them too.")

                    featureList

                    section("Getting started",
                            "Connect the mic, press Start, and point it at the sky. Detected passes are logged with their species, confidence, and a spectrogram of the pulses. Start a Session to also record a GPS track and map where each pass was heard.")

                    Button {
                        // Flag the tour, then dismiss; the host starts it from the
                        // sheet's onDismiss so the spotlight lands on the real,
                        // unobscured UI — no timing race with the dismiss animation.
                        startTour()
                        dismiss()
                    } label: {
                        Label("Take the guided tour", systemImage: "sparkles")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.batAccent)
                    .padding(.top, 4)

                    attributionSection
                }
                .padding(20)
            }
            .navigationTitle("About OpenBat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            appIcon
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenBat").font(.title2.bold())
                Text("Ultrasonic bat detector").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    /// The real app icon, with the rounded-rect (squircle-ish) mask iOS gives icons.
    /// Falls back to the bat glyph if the icon image can't be loaded.
    @ViewBuilder private var appIcon: some View {
        Group {
            if let icon = Self.appIconImage {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image("batIcon")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    /// The primary app icon from the bundle. The asset-catalog app icon isn't
    /// reliably reachable by a fixed name, so resolve the actual filename from the
    /// Info.plist icon-files list and load that.
    private static let appIconImage: UIImage? = {
        guard
            let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
            let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
            let files = primary["CFBundleIconFiles"] as? [String],
            let name = files.last
        else { return nil }
        return UIImage(named: name)
    }()

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Features").font(.headline)
            feature("waveform.badge.magnifyingglass", "Real-time spectrogram",
                    "High-resolution frequency-vs-time display with drag-to-scroll history.")
            feature("waveform.path.ecg", "Pulse detection & zoom",
                    "Isolates each call and renders an onset-aligned close-up.")
            feature("sparkle.magnifyingglass", "Species ID",
                    "On-device classifier names the species, with runner-up and confidence.")
            feature("headphones", "Heterodyne & time-expansion",
                    "Hear the ultrasound live, tuned down or slowed 10×.")
            feature("square.stack.3d.up", "Sessions & map",
                    "Log passes with a GPS track and see where each was heard.")
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(body).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    // MARK: Attribution

    private var attributionSection: some View {
        DataModelSourcesView()
    }
}

/// One entry per data source OpenBat actually depends on. Classifier models are
/// pulled straight from `ModelRegistry.all` (its `citation`/`sourceURL` are also
/// shown in the model detail screen) so a newly registered model is attributed
/// automatically — no separate list to keep in sync. BatDetect2's CC BY-NC
/// non-commercial licence surfaces here through that same `citation`. GBIF
/// (distribution maps) and Wikipedia (species photos/summaries) are fixed
/// entries since they're general data sources, not classifiers.
///
/// Shared (not private to AppInfoView) so the field guide credits the same
/// sources from its own sheet — see `SpeciesExplorerView`.
struct DataModelSourcesView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Data & Model Sources").font(.headline)

            ForEach(ModelRegistry.all) { model in
                attributionRow(name: model.displayName, detail: model.citation, url: model.sourceURL)
            }
            attributionRow(name: "GBIF",
                           detail: "Species distribution maps use occurrence data from the Global Biodiversity Information Facility (GBIF), licensed CC BY 4.0.",
                           url: URL(string: "https://www.gbif.org"))
            attributionRow(name: "Wikipedia",
                           detail: "Species photos and summary text in the field guide come from Wikipedia, licensed CC BY-SA 4.0. Individual photo authorship isn't tracked per-image.",
                           url: URL(string: "https://www.wikipedia.org"))
        }
    }

    private func attributionRow(name: String, detail: String, url: URL?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let url {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text(name).font(.subheadline.weight(.semibold))
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption2)
                    }
                }
            } else {
                Text(name).font(.subheadline.weight(.semibold))
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Guided tour overlay

/// Full-screen dimming overlay with a spotlight cutout over the current step's
/// control and a caption card. Presented via `.overlayPreferenceValue` so it can
/// resolve the tagged controls' bounds. Binding-driven so ContentView owns the
/// step index and dismissal.
struct TourOverlay: View, Equatable {
    let targets: [TourID: CGRect]
    @Binding var index: Int
    let steps: [TourStep]
    /// Ends the tour (Skip / Done / finishing the last step).
    let finish: () -> Void

    /// The detector UI relayouts many times a second while running (stats text,
    /// meters, button tints), and every pass republishes the anchor preferences,
    /// re-invoking the host's overlayPreferenceValue closure. Comparing the
    /// resolved rects + step index lets SwiftUI skip re-diffing this whole
    /// overlay (dim shape, material card, shadow) when nothing visible changed —
    /// paired with .equatable() at the call site.
    static func == (lhs: TourOverlay, rhs: TourOverlay) -> Bool {
        lhs.targets == rhs.targets && lhs.index == rhs.index
    }

    private var step: TourStep { steps[min(index, steps.count - 1)] }
    private var hole: CGRect {
        guard let id = step.target, let r = targets[id] else { return .null }
        return r.insetBy(dx: -6, dy: -6)
    }

    var body: some View {
        GeometryReader { geo in
            let hasHole = !hole.isNull && !hole.isEmpty
            // Steps with no target collapse the cutout to a zero-size rect at screen
            // centre rather than .null — SpotlightShape is animatable, and .null's
            // infinite coordinates interpolate to NaN geometry (flashing dim layer).
            // A degenerate rect instead animates the hole growing/shrinking smoothly.
            let shapeHole = hasHole
                ? hole
                : CGRect(x: geo.size.width / 2, y: geo.size.height / 2, width: 0, height: 0)
            ZStack {
                // Dim everything except the spotlight. No .ignoresSafeArea() here:
                // the host applies it to the whole overlay, so this view, the hole
                // rects, the ring and the caption all share one coordinate space.
                SpotlightShape(hole: shapeHole)
                    .fill(Color.black.opacity(0.82), style: FillStyle(eoFill: true))
                    .contentShape(Rectangle())
                    .onTapGesture { advance() }

                // Ring around the spotlighted control.
                if hasHole {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.9), lineWidth: 2)
                        .frame(width: hole.width, height: hole.height)
                        .position(x: hole.midX, y: hole.midY)
                        .allowsHitTesting(false)
                }

                captionLayer(in: geo.size, hasHole: hasHole)
            }
            .animation(.easeInOut(duration: 0.35), value: index)
        }
        .transition(.opacity)
    }

    /// Places the caption card below the hole when it's in the top half of the
    /// screen, above it otherwise, and centred when there's no cutout.
    @ViewBuilder private func captionLayer(in size: CGSize, hasHole: Bool) -> some View {
        if hasHole {
            let below = hole.midY < size.height / 2
            // Clamp the spacer at 0: on a short landscape height (size.height < 200) the
            // `size.height - 200` cap goes negative, which snapped the card to the top/
            // bottom edge. max(0, …) keeps it a valid spacer height.
            VStack(spacing: 0) {
                if below {
                    Color.clear.frame(height: max(0, min(hole.maxY + 16, size.height - 200)))
                    card
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    card
                    Color.clear.frame(height: max(0, min(size.height - hole.minY + 16, size.height - 200)))
                }
            }
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: step.symbol)
                    .font(.title2)
                    .rotationEffect(step.symbolRotation)
                    .foregroundStyle(Color.batAccent)
                Text(step.title).font(.headline)
                Spacer()
                Text("\(index + 1)/\(steps.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(step.detail)
                .font(.subheadline)
                .foregroundStyle(.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("End tour") { finish() }
                    .foregroundStyle(.secondary)
                Spacer()
                if index > 0 {
                    Button { withAnimation { index -= 1 } } label: {
                        Image(systemName: "chevron.left")
                            .fontWeight(.semibold)
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                }
                Button { advance() } label: {
                    // Checkmark on the last step (the old "Done").
                    Image(systemName: index == steps.count - 1 ? "checkmark" : "chevron.right")
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.batAccent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(index == steps.count - 1 ? "Done" : "Next")
            }
            .font(.callout)
        }
        .padding(16)
        .frame(maxWidth: 360)
        // Opaque fill, not a material: a material backdrop-blurs the live
        // spectrogram beneath it every frame, a per-frame GPU cost for the whole
        // tour. Over the 82% black dim an opaque dark grey looks the same.
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
        .shadow(radius: 20, y: 8)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }

    private func advance() {
        if index >= steps.count - 1 { finish() }
        else { withAnimation { index += 1 } }
    }
}

/// A full-rect path with an optional rounded-rect hole punched out; fill it with
/// `eoFill: true` to dim everything except the hole.
private struct SpotlightShape: Shape {
    var hole: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(hole.minX, hole.minY), .init(hole.width, hole.height)) }
        set { hole = CGRect(x: newValue.first.first, y: newValue.first.second,
                            width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        if !hole.isNull && !hole.isEmpty {
            p.addRoundedRect(in: hole, cornerSize: CGSize(width: 14, height: 14))
        }
        return p
    }
}
