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
    // Panes, each paired with the cluster of buttons that live inside it, plus the
    // bottom call-to-action bar (start / record / listen).
    case stats, statsButtons
    case pulseView, pulseButtons
    case spectrogram, spectrogramButtons
    case controls
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
    func tourTarget(_ id: TourID) -> some View {
        anchorPreference(key: TourTargetKey.self, value: .bounds) { [id: $0] }
    }
}

// MARK: - Tour script

struct TourStep: Identifiable {
    let id = UUID()
    /// The control to spotlight, or nil for a centred, no-cutout card.
    let target: TourID?
    let symbol: String
    let title: String
    let detail: String
}

enum TourScript {
    // Walks the screen top-to-bottom: each pane first, then the buttons inside it,
    // then the bottom transport bar, then the menus.
    static let steps: [TourStep] = [
        TourStep(target: nil, symbol: "hand.wave",
                 title: "Welcome to OpenBat",
                 detail: "A real-time bat detector for the ultrasonic mic. Here's a quick tour of the screen — tap Next to step through, or End tour any time."),

        TourStep(target: .stats, symbol: "chart.bar",
                 title: "Live stats",
                 detail: "Peak frequency, bandwidth, duration, pulse rate and count for the most recent pulse, plus the current species ID and input level. They clear when activity goes stale."),
        TourStep(target: .statsButtons, symbol: "cable.connector",
                 title: "Stats controls",
                 detail: "The circular arrow resets the pulse count, rate and peak-hold. In portrait, the connector icon beside it shows whether the ultrasonic mic is attached and its sample rate."),

        TourStep(target: .pulseView, symbol: "waveform.path.ecg",
                 title: "Pulse view & Species ID",
                 detail: "A zoomed, onset-aligned render of the latest call. Pinch and drag to inspect it. It can also show the live Species ID feed instead — tap any ID there for the pulses and scores behind it."),
        TourStep(target: .pulseButtons, symbol: "slider.horizontal.3",
                 title: "Pulse view controls",
                 detail: "The bat glyph swaps this pane between the pulse close-up and the Species ID feed. The sliders open display settings — zoom window span and noise floor."),

        TourStep(target: .spectrogram, symbol: "waveform.badge.magnifyingglass",
                 title: "Spectrogram",
                 detail: "The scrolling frequency-vs-time view. Drag to scroll back through history."),
        TourStep(target: .spectrogramButtons, symbol: "slider.horizontal.below.rectangle",
                 title: "Spectrogram controls",
                 detail: "Toggle the Species ID overlay, compress the timeline to back-to-back pulses, snap to the bat frequency band, or open the palette and frequency-range settings."),

        TourStep(target: .controls, symbol: "ear",
                 title: "Start, record & listen",
                 detail: "Left starts and stops detecting (Session with a GPS track, or just Listening). Middle arms WAV recording of each pass. Right cycles the listen mode — heterodyne or time-expansion — so you can hear the bats."),

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
                    .padding(.top, 4)
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
}

// MARK: - Guided tour overlay

/// Full-screen dimming overlay with a spotlight cutout over the current step's
/// control and a caption card. Presented via `.overlayPreferenceValue` so it can
/// resolve the tagged controls' bounds. Binding-driven so ContentView owns the
/// step index and dismissal.
struct TourOverlay: View {
    let targets: [TourID: CGRect]
    @Binding var index: Int
    let steps: [TourStep]
    /// Ends the tour (Skip / Done / finishing the last step).
    let finish: () -> Void

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
            VStack(spacing: 0) {
                if below {
                    Color.clear.frame(height: min(hole.maxY + 16, size.height - 200))
                    card
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    card
                    Color.clear.frame(height: min(size.height - hole.minY + 16, size.height - 200))
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
                    .foregroundStyle(.tint)
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

            HStack {
                Button("End tour") { finish() }
                    .foregroundStyle(.secondary)
                Spacer()
                if index > 0 {
                    Button("Back") { withAnimation { index -= 1 } }
                }
                Button(index == steps.count - 1 ? "Done" : "Next") { advance() }
                    .fontWeight(.semibold)
            }
            .font(.callout)
        }
        .padding(16)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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
