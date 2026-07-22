//
//  WavPlayerDebugLog.swift
//  OpenBat
//
//  Toggleable diagnostic logging for the WavPlayer feature (offline
//  spectrogram rendering, call analysis, playback transport) — added while
//  tracking down a string of performance/correctness bugs in that pipeline
//  (undebounced sliders spawning hundreds of redundant renders, a whole-file
//  PCM read defeating a "cheap recolor" path, a resolution mismatch between
//  two overview render call sites). Every one of those was only found by
//  reading actual on-device console output, not by static review — this
//  makes that loop faster for whatever turns up next.
//
//  Deliberately compiles to nothing in Release (`isEnabled` is a `let false`
//  there, and every call site guards on it before doing any string
//  interpolation), so it's safe to leave in permanently rather than having
//  to strip call sites back out. `nonisolated`: called from background
//  render tasks as often as from the main actor.
//
//  NOT used inside PlaybackDriver's pacing loop or SpectrogramProcessor's
//  per-buffer path — both run on realtime/near-realtime threads (the audio
//  pacing thread, up to ~1500 columns/sec) where even a skipped `isEnabled`
//  check plus a closure capture per call isn't a cost worth risking. Those
//  two are the live-capture/playback-audio hot paths; everything else this
//  logs (file scans, detail-tile renders, gesture bookkeeping, transport
//  calls) runs at UI-gesture or user-action frequency, orders of magnitude
//  rarer.
//

import Foundation

nonisolated enum WavPlayerDebugLog {
#if DEBUG
    static var isEnabled = true
#else
    static let isEnabled = false
#endif

    static func log(_ category: String, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        print("[\(category) DEBUG] \(message())")
    }

    /// Runs `body`, logging how long it took alongside `label`. Use for any
    /// unit of work worth profiling — a file scan, an FFT pass, a colorize
    /// loop — never inside a realtime-thread hot path (see file doc comment).
    @discardableResult
    static func time<T>(_ category: String, _ label: String, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let start = CFAbsoluteTimeGetCurrent()
        let result = try body()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("[\(category) DEBUG] \(label): \(String(format: "%.1f", ms))ms")
        return result
    }
}
