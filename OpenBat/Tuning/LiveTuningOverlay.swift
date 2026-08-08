//
//  LiveTuningOverlay.swift
//  OpenBat
//
//  A floating, draggable card of live tuning controls that sits OVER the running
//  detector screen. The point is to change a threshold and hear/see the result
//  without the pipeline stopping.
//
//  Why this isn't a sheet: every existing settings surface is presented as one,
//  and sheets feed `ContentView.menuIsOpen`, which pauses the Metal render loop
//  and sets `processor.suspended`. Tuning against a frozen spectrogram is
//  useless, so this is a plain overlay in the detector's ZStack and
//  `showTuningOverlay` is deliberately NOT part of `menuIsOpen` — the same
//  deliberate exclusion `showBand`/`showPulseView` already have.
//
//  Paired with demo mode this is the actual workflow: loop a known clip, drag a
//  knob, listen. The clip is identical every lap, so the only variable is the
//  knob.
//

import SwiftUI

struct LiveTuningOverlay: View {
    let audio: AudioEngineController
    let adaptiveTESettings: AdaptiveTimeExpansionSettings
    let pulseDetector: PulseDetector
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
    @AppStorage("tuning.overlayTab") private var tabRaw = LiveTuningTab.adaptiveTE.rawValue

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
        get { LiveTuningTab(rawValue: tabRaw) ?? .adaptiveTE }
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
                audio: audio, ate: adaptiveTESettings, pulse: pulseDetector,
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
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
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
                                    .fill(.white.opacity(0.12))
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
            case .adaptiveTE:
                AdaptiveTETuningTab(audio: audio, settings: adaptiveTESettings)
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
            // Adaptive-TE only, and labelled inside that tab's scope rather than
            // as a global reset: there is no equivalent "factory default" for
            // the pulse detector or the display band, and a button that reset
            // some tabs but not others would be worse than one that is honest
            // about what it touches.
            Button("ATE Defaults") {
                adaptiveTESettings.reset()
                adaptiveTESettings.apply(to: audio.adaptiveTimeExpansion)
                revertToken += 1
            }
        }
        .font(.system(size: 11, weight: .medium))
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func revert() {
        guard let snapshot = opening else { return }
        snapshot.restore(audio: audio, ate: adaptiveTESettings, pulse: pulseDetector,
                         bandLow: &bandLow, bandHigh: &bandHigh,
                         timeWindowSeconds: &timeWindowSeconds)
        // The adaptive-TE group reaches the processor via ContentView's
        // `.onChange(of: adaptiveTESettings.snapshot)`, but that fires on the
        // next update pass — push it now so a revert is heard immediately
        // rather than on whatever redraw happens next.
        adaptiveTESettings.apply(to: audio.adaptiveTimeExpansion)
        onBandChange()
        revertToken += 1
    }

    // MARK: Dragging

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

    private func clampedPosition(in size: CGSize) -> CGPoint {
        CGPoint(x: posX.clamped(to: 0.08...0.92) * size.width + dragOffset.width,
                y: posY.clamped(to: 0.06...0.94) * size.height + dragOffset.height)
    }
}
