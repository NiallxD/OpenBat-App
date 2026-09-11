//
//  PowerLogger.swift
//  OpenBat
//
//  One row a minute saying what the app was doing and what it was costing, so
//  "the app is power hungry" can become "the app is power hungry WHEN".
//
//  It is deliberately not an energy model. Nothing on the device will tell an
//  app how many joules it just spent; what it will tell us is the battery
//  percentage, the thermal state, and how much CPU time this process has
//  accumulated — and those three, sampled against a record of what was switched
//  on at the time, are enough to find a culprit by elimination. A night where
//  the battery falls 9%/hour with the spectrogram on screen and 4%/hour with
//  the phone in a pocket is an answer; a single number for "the app" is not.
//
//  Its own cost is a rounded-up timer once a minute and about 120 bytes of
//  append — with a 10 s tolerance so the OS can coalesce the wake-up with
//  whatever else it was going to do anyway. A night of it is ~60 kB.
//
//  Separate CSV, same export. The classifier log is a wide, rectangular table
//  with one row per pulse and 48 score columns; power samples share none of
//  that shape, and wedging them in as another `type` would put empty score
//  columns on every row and make the file harder to read for both purposes.
//  It travels inside the same zip (`ClassificationLogger.makeShareItem`), which
//  is what "in the classifier log" actually means when you go to send one.
//

import Foundation
import UIKit
import Darwin

final class PowerLogger {

    static let shared = PowerLogger()

    /// What the app was doing at the moment of a sample. Supplied by the
    /// Detector, because that is what knows — see `contextProvider`.
    struct Context {
        var isRunning = false
        var isRecording = false
        var isDemo = false
        var listenMode = "off"
        var tab = "—"
        var sampleRate: Double = 0
        var pulses = 0
        var passes = 0
    }

    /// Set once by `ContentView`. Read on the main actor at each sample.
    @MainActor var contextProvider: (() -> Context)?

    private(set) var fileURL: URL
    private let queue = DispatchQueue(label: "bat.PowerLogger", qos: .background)
    private var timer: Timer?

    /// The last sample, in one line, for the Diagnostics panel — so the log can
    /// be read without exporting it. Updates once a minute, and says so there.
    @MainActor private(set) var lastSummary = "—"

    /// Previous sample's cumulative CPU time and wall clock, for the deltas.
    private var lastCPUSeconds: Double?
    private var lastSampleAt: Date?

    private static let maxBytes = 2 * 1024 * 1024

    private static let columns = [
        "timestamp", "event", "battery_pct", "battery_state", "low_power",
        "thermal", "cpu_pct", "brightness", "running", "recording", "demo",
        "listen_mode", "tab", "sample_rate", "pulses", "passes",
    ]

    private init() {
        fileURL = CloudStorage.baseDirectory.appendingPathComponent("bat_power_log.csv")
        writeHeaderIfNeeded()
    }

    // MARK: - Control

    /// Begin sampling. Safe to call more than once.
    ///
    /// Battery monitoring is switched on here and left on: it is a flag, not a
    /// subscription, and turning it off would make `batteryLevel` read −1 for
    /// any other caller.
    @MainActor func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        guard timer == nil else { return }
        sample(event: "start")
        let t = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample(event: "tick") }
        }
        // The OS may fire this up to 10 s late so it can be coalesced with
        // another wake-up. A power log that wakes the phone on its own schedule
        // would be measuring itself.
        t.tolerance = 10
        timer = t
    }

    @MainActor func stop(event: String = "stop") {
        sample(event: event)
        timer?.invalidate()
        timer = nil
    }

    /// Take a sample now, out of band — worth doing at a transition (capture
    /// started, recording armed) so a change of state is bracketed rather than
    /// discovered up to a minute later.
    @MainActor func mark(_ event: String) { sample(event: event) }

    // MARK: - Sampling

    @MainActor private func sample(event: String) {
        let device = UIDevice.current
        let context = contextProvider?() ?? Context()
        let now = Date()

        let level = device.batteryLevel                  // −1 when unavailable
        let battery = level < 0 ? "" : String(format: "%.0f", level * 100)
        let state: String
        switch device.batteryState {
        case .charging: state = "charging"
        case .full:     state = "full"
        case .unplugged: state = "unplugged"
        default:        state = "unknown"
        }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  thermal = "nominal"
        case .fair:     thermal = "fair"
        case .serious:  thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }

        // CPU as a percentage of ONE core over the interval since the last
        // sample — so 100 means one core saturated and 250 means two and a half
        // cores' worth, which is the number that matters for heat and drain.
        var cpu = ""
        if let seconds = Self.processCPUSeconds() {
            if let previous = lastCPUSeconds, let at = lastSampleAt {
                let elapsed = now.timeIntervalSince(at)
                if elapsed > 0.5 { cpu = String(format: "%.1f", (seconds - previous) / elapsed * 100) }
            }
            lastCPUSeconds = seconds
        }
        lastSampleAt = now

        let fields = [
            ISO8601DateFormatter().string(from: now),
            event,
            battery,
            state,
            ProcessInfo.processInfo.isLowPowerModeEnabled ? "1" : "0",
            thermal,
            cpu,
            String(format: "%.2f", UIScreen.main.brightness),
            context.isRunning ? "1" : "0",
            context.isRecording ? "1" : "0",
            context.isDemo ? "1" : "0",
            context.listenMode,
            context.tab,
            context.sampleRate > 0 ? String(Int(context.sampleRate)) : "",
            String(context.pulses),
            String(context.passes),
        ]
        append(fields.joined(separator: ",") + "\n")

        lastSummary = [battery.isEmpty ? "—" : battery + "%", state, thermal,
                       cpu.isEmpty ? "—" : cpu + "% CPU"].joined(separator: " · ")
    }

    /// Total CPU time this process has used, in seconds. `nil` if the kernel
    /// declines to say, which is not worth a row of its own.
    ///
    /// Two calls, because neither half is the whole answer: `MACH_TASK_BASIC_INFO`
    /// carries the time of threads that have already exited, and
    /// `TASK_THREAD_TIMES_INFO` carries the time of the ones still running. The
    /// familiar `proc_pid_rusage` would do it in one, but libproc is not in the
    /// iOS SDK's module map, so it isn't reachable from Swift here.
    private static func processCPUSeconds() -> Double? {
        func seconds(_ value: time_value_t) -> Double {
            Double(value.seconds) + Double(value.microseconds) / 1_000_000
        }

        var exited = mach_task_basic_info()
        var exitedCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let exitedResult = withUnsafeMutablePointer(to: &exited) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(exitedCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &exitedCount)
            }
        }

        var live = task_thread_times_info()
        var liveCount = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size)
        let liveResult = withUnsafeMutablePointer(to: &live) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(liveCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &liveCount)
            }
        }

        guard exitedResult == KERN_SUCCESS, liveResult == KERN_SUCCESS else { return nil }
        return seconds(exited.user_time) + seconds(exited.system_time)
             + seconds(live.user_time) + seconds(live.system_time)
    }

    // MARK: - File

    private func writeHeaderIfNeeded() {
        queue.async { [self] in
            let fm = FileManager.default
            guard !fm.fileExists(atPath: fileURL.path) else { return }
            try? (Self.columns.joined(separator: ",") + "\n")
                .write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private func append(_ line: String) {
        queue.async { [self] in
            let fm = FileManager.default
            // One previous file kept, then overwritten. A power log is only
            // ever read as "the last few nights"; keeping a season of it would
            // cost more than it answers.
            if let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
               size > Self.maxBytes {
                let previous = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("bat_power_log-previous.csv")
                try? fm.removeItem(at: previous)
                try? fm.moveItem(at: fileURL, to: previous)
                try? (Self.columns.joined(separator: ",") + "\n")
                    .write(to: fileURL, atomically: true, encoding: .utf8)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? line.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// The files to carry out with the classifier log.
    func exportURLs() -> [URL] {
        let previous = fileURL.deletingLastPathComponent()
            .appendingPathComponent("bat_power_log-previous.csv")
        return [fileURL, previous].filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
