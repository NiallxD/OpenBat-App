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

    func makeCoordinator() -> SpectrogramRenderer? {
        SpectrogramRenderer(processor: processor)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator?.device ?? MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        guard let coordinator = context.coordinator else { return }
        if columnsPerSecond > 0 {
            coordinator.columnsPerSecond = columnsPerSecond
        }
        coordinator.bandLow = Float(bandLow)
        coordinator.bandHigh = Float(bandHigh)
        coordinator.timeWindowSeconds = timeWindowSeconds
        coordinator.isScrolling = isScrolling
        coordinator.scrollColumnOffset = scrollColumnOffset
        coordinator.pulseDetector = pulseDetector
    }
}

struct SpectrogramView: View {
    let processor: SpectrogramProcessor
    /// Nyquist (half the sample rate); top of the frequency axis.
    var maxFrequency: Double
    /// Visible frequency band, as fractions of Nyquist.
    var bandLow: Double = 0
    var bandHigh: Double = 1
    /// Width of the x-axis time window, in seconds (e.g. 0.5 = 500 ms).
    var timeWindowSeconds: Double = 0.5
    var pulseDetector: PulseDetector? = nil

    @State private var isScrolling = false
    @State private var scrollColumnOffset: Double = 0
    @State private var lastDragTranslation: CGFloat = 0

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
                                     pulseDetector: pulseDetector)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                frequencyAxis
                    .padding(6)

                if isScrolling {
                    returnToLiveButton
                }
            }
            .background(.black, in: RoundedRectangle(cornerRadius: 12))
            .gesture(dragGesture(viewWidth: geo.size.width))
        }
    }

    // MARK: Drag gesture

    private func dragGesture(viewWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
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
            .onEnded { _ in
                lastDragTranslation = 0
            }
    }

    // MARK: Return to live

    private var returnToLiveButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
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

    // MARK: Frequency axis

    private var frequencyAxis: some View {
        VStack {
            axisLabel(bandHigh * maxFrequency)
            Spacer()
            axisLabel((bandLow + bandHigh) / 2 * maxFrequency)
            Spacer()
            axisLabel(bandLow * maxFrequency)
        }
    }

    private func axisLabel(_ hz: Double) -> some View {
        Text(format(hz))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
            .shadow(radius: 1)
    }

    private func format(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.0f kHz", hz / 1000) : String(format: "%.0f Hz", hz)
    }
}
