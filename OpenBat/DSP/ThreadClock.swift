//
//  ThreadClock.swift
//  OpenBat
//
//  CPU time actually consumed by the calling thread, as against wall-clock time
//  elapsed.
//
//  WHY BOTH ARE NEEDED
//  -------------------
//  Every timing in the demo log was wall-clock, and wall-clock cannot tell work
//  from waiting. The pulse render measured ~200 ms on an iPad Air 4 and did not
//  get faster in Release — which is the signature of a thread being descheduled,
//  not of slow code, because optimisation cannot speed up time spent not
//  running. The capture queue now competes with the classify queue, the audio
//  thread, the GPU spectrogram and SwiftUI on six cores, so that is a live
//  possibility rather than a theoretical one.
//
//  Logging both answers it in one run: CPU ≈ wall means the work really is that
//  expensive and the DSP is worth attacking; CPU ≪ wall means the thread is
//  starved and no amount of DSP tuning will help.
//

import Foundation

nonisolated enum ThreadClock {

    /// CPU nanoseconds consumed by the *calling thread* so far. Differences
    /// between two reads on one thread give the CPU time of the work between
    /// them; the value has no meaning across threads.
    static func cpuNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    /// Milliseconds of CPU consumed since `start`.
    static func cpuMillisecondsSince(_ start: UInt64) -> Double {
        Double(cpuNanoseconds() &- start) / 1e6
    }

    /// Runs `body`, returning its result alongside how long it took in both
    /// senses. A large gap between the two is the finding.
    static func measure<T>(_ body: () -> T) -> (value: T, wallMs: Double, cpuMs: Double) {
        let w0 = DispatchTime.now().uptimeNanoseconds
        let c0 = cpuNanoseconds()
        let v = body()
        let cpu = cpuMillisecondsSince(c0)
        let wall = Double(DispatchTime.now().uptimeNanoseconds &- w0) / 1e6
        return (v, wall, cpu)
    }
}
