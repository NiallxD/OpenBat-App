//
//  BackgroundDetectionPump.swift
//  OpenBat
//
//  Keeps pulse detection running while the app is backgrounded or the screen is locked.
//

import Foundation

/// Drains `SpectrogramProcessor` and feeds `PulseDetector` while the Metal render loop
/// isn't running (app backgrounded or screen locked).
///
/// **Why this exists.** `PulseDetector.feed()` is normally called from inside
/// `SpectrogramRenderer.draw(in:)`, off the MTKView's CADisplayLink, which the system
/// pauses on background/lock. Without something else draining, columns pile up and get
/// discarded at `maxPendingColumns` — detection silently stops. See Context.md §12.
///
/// **Why it can be this small.** `feed()` reads audio only through `pcmProvider` — it
/// never touches the renderer's `liveHistory` (display/scrollback only) — so this needs
/// no Metal, no textures, no renderer handle: the same drain-and-feed loop `draw(in:)`
/// runs, minus the drawing. The spectrogram has a gap for the backgrounded stretch,
/// which is correct — there was no screen.
///
/// **Ownership.** Exactly one of the render loop and this pump drains at a time, keyed
/// off `scenePhase` in ContentView. `drain()` is lock-guarded and hands out disjoint
/// batches, so the brief overlap on a phase transition can only mean a few columns go to
/// one instead of the other — never a double-feed.
@MainActor
final class BackgroundDetectionPump {

    /// 20 Hz. The backstop is `SpectrogramProcessor.maxPendingColumns` (3000 ≈ 2 s at
    /// 1500 col/s), so this has two orders of magnitude of headroom — it's set by wanting
    /// pulse timing to stay tight, not by the risk of overflow. Going much faster would
    /// just wake the CPU more often for the same work.
    private static let interval: TimeInterval = 0.05

    private(set) var isRunning = false
    private var timer: Timer?
    private weak var processor: SpectrogramProcessor?
    private weak var detector: PulseDetector?

    func start(processor: SpectrogramProcessor, detector: PulseDetector) {
        guard !isRunning else { return }
        self.processor = processor
        self.detector = detector
        isRunning = true

        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pump() }
        }
        // `.common` rather than the default mode: the default mode stops firing during
        // UIKit gesture tracking, which is exactly the kind of stall the processor's own
        // backpressure cap was added to survive. Cheap insurance.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        // Deliberately does NOT drain on the way out. Returning to the foreground hands
        // draining straight back to `draw(in:)`, which will pick up whatever is pending
        // on its next frame — within 16 ms.
    }

    /// One drain-and-feed batch. Mirrors the loop in `SpectrogramRenderer.draw(in:)`;
    /// if the arguments there change, change them here too.
    private func pump() {
        guard let processor, let detector else { return }
        let sampleRate = processor.sampleRate
        guard sampleRate > 0 else { return }
        // Same identity the renderer uses: hop size drives column rate, not fftSize.
        let columnsPerSecond = sampleRate / Double(processor.hopSize)
        guard columnsPerSecond > 0 else { return }

        for column in processor.drain() {
            // Per-column peak, not `processor.peakLevel` — that only holds the last column
            // of the batch and would scramble pulse position. Same reasoning as `draw`.
            detector.feed(
                peakLevel: column.peakLevel,
                peakFrequency: processor.frequency(forBin: column.peakBin, level: column.peakLevel),
                columnEndSample: column.endSample,
                columnsPerSecond: columnsPerSecond,
                sampleRate: sampleRate
            )
        }
    }
}
