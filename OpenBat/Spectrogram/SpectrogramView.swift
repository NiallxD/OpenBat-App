//
//  SpectrogramView.swift
//  OpenBat
//
//  SwiftUI wrapper hosting the Metal-backed spectrogram, plus frequency-axis
//  labels and drag-to-scroll. Dragging pauses the live feed and lets the user
//  scrub back through history; a "Return to live" button snaps back.
//

import SwiftUI
import MetalKit

private struct MetalSpectrogramView: UIViewRepresentable {
    let processor: SpectrogramProcessor
    let columnsPerSecond: Double
    let bandLow: Double
    let bandHigh: Double
    let timeWindowSeconds: Double
    let isScrolling: Bool
    let scrollColumnOffset: Double
    let pulseDetector: PulseDetector?
    let isPaused: Bool
    let logFrequency: Bool
    let palette: Palette?
    /// Render rate. 60 while anything is actually moving; dropped right down when
    /// capture is stopped and the user isn't scrolling — see `SpectrogramView.isIdle`.
    let preferredFPS: Int

    func makeCoordinator() -> SpectrogramRenderer? {
        SpectrogramRenderer(processor: processor)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator?.device ?? MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = preferredFPS
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = isPaused
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        guard let coordinator = context.coordinator else { return }
        if columnsPerSecond > 0 {
            coordinator.columnsPerSecond = columnsPerSecond
        }
        coordinator.bandLow = Float(bandLow)
        coordinator.bandHigh = Float(bandHigh)
        coordinator.logFrequency = logFrequency
        coordinator.timeWindowSeconds = timeWindowSeconds
        coordinator.isScrolling = isScrolling
        coordinator.scrollColumnOffset = scrollColumnOffset
        coordinator.pulseDetector = pulseDetector
        coordinator.palette = palette
        // Stopping the 60 Hz Metal render loop (which drains FFT columns and
        // feeds the pulse detector inline, all on the main thread) is what
        // frees the main run loop up for gesture recognition while a sheet/
        // popover is on screen — see SpectrogramView.isPaused.
        if uiView.isPaused != isPaused { uiView.isPaused = isPaused }
        if uiView.preferredFramesPerSecond != preferredFPS {
            uiView.preferredFramesPerSecond = preferredFPS
        }
    }
}

struct SpectrogramView: View {
    let processor: SpectrogramProcessor
    /// Nyquist (half the sample rate); top of the frequency axis.
    var maxFrequency: Double
    /// Visible frequency band, as fractions of Nyquist.
    var bandLow: Double = 0
    var bandHigh: Double = 1
    /// Width of the x-axis time window, in seconds (e.g. 0.75 = 750 ms).
    var timeWindowSeconds: Double = 0.75
    var pulseDetector: PulseDetector? = nil
    /// When true, stops the Metal render loop (and with it, FFT-column
    /// draining and pulse-detector feeding) entirely — for use while a sheet
    /// or popover is covering the spectrogram and doesn't need it live.
    var isPaused: Bool = false
    /// True when capture isn't running, so there is no new audio to draw. The view
    /// is NOT paused in that case — `enableSetNeedsDisplay` is false, so a paused
    /// view stops responding to scroll-back too, and scrolling into history after a
    /// stop is exactly when someone wants it. Instead the render rate drops, which
    /// keeps the gesture live while ending a full-screen fragment pass 60 times a
    /// second over a static image. Scrolling restores full rate on its own.
    var isIdle: Bool = false
    /// Display the frequency axis log-scaled within [bandLow, bandHigh] instead of
    /// linear — a Settings toggle independent of the pulse view's own.
    var logFrequency: Bool = false
    /// Explicit palette override — see `SpectrogramRenderer.palette`. nil (the
    /// default) falls back to `pulseDetector?.displayPalette`.
    var palette: Palette? = nil
    /// Drag-to-scroll into the history buffer. Off in simplified view (Niall,
    /// 2026-08-16): scrolling back is a review gesture, and there it is only ever
    /// reached by accident — a finger resting on the spectrogram silently freezes
    /// the live feed, and the way back is a "Return to live" button that only
    /// exists *because* you are already lost. The whole feature is one the user
    /// has to know about to want.
    ///
    /// This is a hard override rather than a hidden control: there is nothing to
    /// hide (it is a gesture), and no state to strand the user in — see
    /// `SimplifiedView`'s header for which of the two mechanisms applies when.
    var scrollEnabled: Bool = true

    @State private var isScrolling = false
    @State private var scrollColumnOffset: Double = 0
    @State private var lastDragTranslation: CGFloat = 0
    @State private var momentum = ScrollMomentum()

    /// Columns produced per second = sampleRate / hop = (2 * Nyquist) / hopSize.
    private var columnsPerSecond: Double {
        maxFrequency > 0 ? (maxFrequency * 2) / Double(processor.hopSize) : 0
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                MetalSpectrogramView(processor: processor,
                                     columnsPerSecond: columnsPerSecond,
                                     bandLow: bandLow,
                                     bandHigh: bandHigh,
                                     timeWindowSeconds: timeWindowSeconds,
                                     isScrolling: isScrolling,
                                     scrollColumnOffset: scrollColumnOffset,
                                     pulseDetector: pulseDetector,
                                     isPaused: isPaused,
                                     logFrequency: logFrequency,
                                     palette: palette,
                                     preferredFPS: (isIdle && !isScrolling) ? 10 : 60)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                gridOverlay

                frequencyAxis
                    .padding(6)

                if isScrolling {
                    returnToLiveButton
                }
            }
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 12))
            // `nil` rather than a `.disabled` gesture: an attached-but-disabled
            // DragGesture still claims the touch sequence, which would swallow
            // taps meant for the pills overlaid on top of the spectrogram.
            .gesture(scrollEnabled ? dragGesture(viewWidth: geo.size.width) : nil)
        }
    }

    // MARK: Drag gesture

    private func dragGesture(viewWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                momentum.cancel()
                if !isScrolling {
                    isScrolling = true
                    lastDragTranslation = 0
                }
                let dx = value.translation.width - lastDragTranslation
                lastDragTranslation = value.translation.width
                // Drag right = scrolling into the past (positive offset = older data).
                let columnsPerPoint = columnsPerSecond * timeWindowSeconds / Double(max(viewWidth, 1))
                scrollColumnOffset = max(0, scrollColumnOffset + dx * columnsPerPoint)
            }
            .onEnded { value in
                lastDragTranslation = 0
                // Let the release coast the rest of the way UIKit's own
                // deceleration model predicts, instead of stopping dead.
                let columnsPerPoint = columnsPerSecond * timeWindowSeconds / Double(max(viewWidth, 1))
                let residualColumns = (value.predictedEndTranslation.width - value.translation.width) * columnsPerPoint
                let base = scrollColumnOffset
                momentum.start(residual: residualColumns) { delta in
                    scrollColumnOffset = max(0, base + delta)
                }
            }
    }

    // MARK: Return to live

    private var returnToLiveButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    momentum.cancel()
                    scrollColumnOffset = 0
                    isScrolling = false
                } label: {
                    Label("Return to live", systemImage: "arrow.forward.to.line")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding(.bottom, 10)
                Spacer()
            }
        }
    }

    // MARK: Grid

    /// Faint analysis grid, same style as the pulse view's (`ContentView.pulseGrid`):
    /// vertical quarter lines mark time, horizontal ones frequency, with the middle
    /// line aligned to the mid axis label.
    private var gridOverlay: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Path { p in
                for f in [0.25, 0.5, 0.75] as [CGFloat] {
                    p.move(to: CGPoint(x: w * f, y: 0)); p.addLine(to: CGPoint(x: w * f, y: h))
                    p.move(to: CGPoint(x: 0, y: h * f)); p.addLine(to: CGPoint(x: w, y: h * f))
                }
            }
            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    // MARK: Frequency axis

    /// Evenly spaced (in screen position) tick Hz values, top to bottom — must match
    /// whatever the shader actually draws at each row: log-interpolated in log mode
    /// (matching Spectrogram.metal's log interpolation), linear otherwise. More ticks
    /// in log mode since the compressed top of the band otherwise reads as empty.
    private func tickHzValues(count: Int) -> [Double] {
        guard count > 1 else { return [(bandLow + bandHigh) / 2 * maxFrequency] }
        if logFrequency {
            let lo = max(bandLow, 0.01)
            let hi = max(bandHigh, lo * 1.001)
            return (0..<count).map { i in
                let v = Double(i) / Double(count - 1)              // 0 = top, 1 = bottom
                return lo * exp((1 - v) * log(hi / lo)) * maxFrequency
            }
        }
        return (0..<count).map { i in
            let v = Double(i) / Double(count - 1)
            return (bandHigh - v * (bandHigh - bandLow)) * maxFrequency
        }
    }

    private var frequencyAxis: some View {
        let ticks = tickHzValues(count: logFrequency ? 8 : 5)
        return VStack {
            ForEach(ticks.indices, id: \.self) { i in
                axisLabel(ticks[i])
                if i < ticks.count - 1 { Spacer() }
            }
        }
    }

    private func axisLabel(_ hz: Double) -> some View {
        Text(format(hz))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(Color.primary.opacity(0.7))
            .shadow(radius: 1)
    }

    private func format(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.0f kHz", hz / 1000) : String(format: "%.0f Hz", hz)
    }
}
