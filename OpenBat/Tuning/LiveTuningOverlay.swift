//
//  LiveTuningOverlay.swift
//  OpenBat
//
//  Floating, draggable card of live tuning controls over the running detector
//  screen — changes a threshold and hears/sees the result without the
//  pipeline stopping. Not a sheet: sheets feed `ContentView.menuIsOpen`, which
//  pauses the render loop and suspends the processor, defeating the point.
//  `showTuningOverlay` must stay out of `menuIsOpen`, same exclusion as
//  `showBand`/`showPulseView`. See Context.md §13.
//
//  Paired with demo mode: loop a known clip, drag a knob, listen — same clip
//  every lap, so the knob is the only variable.
//

import SwiftUI

/// The floating tuning card itself: header, tab bar, the active tab's
/// controls, and a Revert/Defaults footer. Owns its own position and
/// collapsed state in `@AppStorage`; everything it edits lives on the
/// objects passed in, not here.
struct LiveTuningOverlay: View {
    let audio: AudioEngineController
    let pulseDetector: PulseDetector
    let haptics: PulseHaptics
    let snippetSettings: SnippetExpansionSettings
    @Binding var bandLow: Double
    @Binding var bandHigh: Double
    @Binding var timeWindowSeconds: Double
    let maxFrequency: Double
    let onBandChange: () -> Void
    let onClose: () -> Void

    /// Card position, persisted so it stays where it was parked. Stored as a
    /// fraction of the container so it survives rotation and iPhone→iPad
    /// without needing to be re-clamped from a stale point.
    @AppStorage("tuning.overlayX") private var posX: Double = 0.5
    @AppStorage("tuning.overlayY") private var posY: Double = 0.62
    @AppStorage("tuning.overlayCollapsed") private var collapsed = false
    @AppStorage("tuning.overlayTab") private var tabRaw = LiveTuningTab.heterodyne.rawValue

    @GestureState private var dragOffset: CGSize = .zero
    /// Captured when the overlay appears; restored by Revert.
    @State private var opening: LiveTuningSnapshot?
    /// Bumped by Revert/Defaults to force the tab subtree to rebuild with fresh
    /// `@State` in every `TuningSlider`.
    ///
    /// Needed because not every knob is `@Observable`-backed: `heterodyne.gain`
    /// is a plain lock-guarded property on a non-Observable processor, so
    /// restoring it changes nothing SwiftUI is watching and its slider would go
    /// on showing the pre-revert value. Re-identifying the subtree re-seeds
    /// every slider from its source of truth, whatever that source is.
    @State private var revertToken = 0

    private var tab: LiveTuningTab {
        get { LiveTuningTab(rawValue: tabRaw) ?? .heterodyne }
        nonmutating set { tabRaw = newValue.rawValue }
    }

    private static let cardWidth: CGFloat = 268

    var body: some View {
        GeometryReader { geo in
            card
                .frame(width: Self.cardWidth)
                .position(clampedPosition(in: geo.size))
                .gesture(dragGesture(in: geo.size))
        }
        .ignoresSafeArea(.keyboard)
        .onAppear {
            guard opening == nil else { return }
            opening = LiveTuningSnapshot.capture(
                audio: audio, pulse: pulseDetector, haptics: haptics,
                snippet: snippetSettings,
                bandLow: bandLow, bandHigh: bandHigh, timeWindowSeconds: timeWindowSeconds)
        }
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 0) {
            header
            if !collapsed {
                Divider().opacity(0.4)
                tabBar
                content
                Divider().opacity(0.4)
                footer
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.glassEdge, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    /// The whole header is the drag surface — a small dedicated grab dot would
    /// be a fiddly target over a live view, and the header has no other gesture
    /// competing for it (the two buttons take their own taps first).
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(collapsed ? "Tuning" : tab.title)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button {
                collapsed.toggle()
            } label: {
                Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(collapsed ? "Expand tuning panel" : "Collapse tuning panel")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close tuning panel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(LiveTuningTab.allCases) { t in
                Button {
                    tab = t
                } label: {
                    Text(t.rawValue)
                        .font(.system(size: 11, weight: tab == t ? .semibold : .regular))
                        .foregroundStyle(tab == t ? Color.primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if tab == t {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.chromeFill(0.12))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch tab {
            case .heterodyne:
                HeterodyneTuningTab(audio: audio)
            case .replay:
                SnippetExpansionTuningTab(audio: audio, settings: snippetSettings)
            case .haptics:
                HapticsTuningTab(haptics: haptics)
            case .pulse:
                PulseTuningTab(detector: pulseDetector)
            case .display:
                DisplayTuningTab(detector: pulseDetector,
                                 bandLow: $bandLow, bandHigh: $bandHigh,
                                 timeWindowSeconds: $timeWindowSeconds,
                                 maxFrequency: maxFrequency,
                                 onBandChange: onBandChange)
            }
        }
        .id(revertToken)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Revert") { revert() }
                .disabled(opening == nil)
            Spacer()
            // Scoped to the visible tab rather than offered as a global reset:
            // there is no equivalent "factory default" for the pulse detector or
            // the display band, and a button that reset some tabs but not others
            // would be worse than one that is honest about what it touches.
            if tab == .haptics {
                Button("Haptic Defaults") {
                    haptics.resetToDefaults()
                    revertToken += 1
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Restores everything captured when the overlay opened.
    private func revert() {
        guard let snapshot = opening else { return }
        snapshot.restore(audio: audio, pulse: pulseDetector, haptics: haptics,
                         snippet: snippetSettings,
                         bandLow: &bandLow, bandHigh: &bandHigh,
                         timeWindowSeconds: &timeWindowSeconds)
        // The adaptive-TE group reaches the processor via ContentView's
        onBandChange()
        revertToken += 1
    }

    // MARK: Dragging

    /// Drives the card's position while dragging; commits to `@AppStorage`
    /// only on release, clamped so the card can't be parked unreachably
    /// off-screen.
    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragOffset) { value, state, _ in state = value.translation }
            .onEnded { value in
                // Commit as fractions of the container, clamped so the card can
                // never be parked more than half off-screen in any direction —
                // dragged fully off, it would be unreachable with no way back
                // short of deleting the app's defaults.
                let current = clampedPosition(in: size)
                let end = CGPoint(x: current.x + value.translation.width - dragOffset.width,
                                  y: current.y + value.translation.height - dragOffset.height)
                guard size.width > 0, size.height > 0 else { return }
                posX = (end.x / size.width).clamped(to: 0.08...0.92)
                posY = (end.y / size.height).clamped(to: 0.06...0.94)
            }
    }

    /// The stored fractional position resolved to a point in `size`, with any
    /// in-flight drag offset applied.
    private func clampedPosition(in size: CGSize) -> CGPoint {
        CGPoint(x: posX.clamped(to: 0.08...0.92) * size.width + dragOffset.width,
                y: posY.clamped(to: 0.06...0.94) * size.height + dragOffset.height)
    }
}
