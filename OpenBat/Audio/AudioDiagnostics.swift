//
//  AudioDiagnostics.swift
//  OpenBat
//
//  Lightweight value types + DSP helpers used to confirm we are receiving the
//  Griff microphone's audio stream at its native (ultrasonic) sample rate.
//

import AVFoundation
import Accelerate

/// Snapshot of the current capture state, surfaced in the diagnostics UI.
///
/// v1 exists purely to *prove the stream*: that the Griff is the active input and
/// that iOS hands us buffers at the device's native rate (target 384 kHz) rather
/// than silently downsampling to the 48 kHz system-mixer rate.
struct AudioDiagnostics: Equatable {
    /// The sample rate of the buffers iOS actually *delivers* to the capture tap —
    /// the true capture rate, read from each buffer's format (not the requested or
    /// the node's advertised format, which can lie). This is the pass/fail gate.
    var actualSampleRate: Double = 0
    /// The rate the AVAudioSession negotiated. If this is the native rate but
    /// `actualSampleRate` is lower, the engine/tap is downsampling; if this is also
    /// low, iOS never granted the native rate to the session.
    var sessionSampleRate: Double = 0
    /// Human-readable name of the active input port (e.g. the Griff / a USB device).
    var inputName: String = "—"
    /// Whether the active input port reports as USB audio (vs. the built-in mic).
    var isUSBInput: Bool = false
    var channelCount: Int = 0
    /// Number of capture callbacks received since the engine started — should tick
    /// up steadily while running.
    var bufferCount: Int = 0
    /// Most recent buffer's RMS level in dBFS (~ -80...0), for the level meter.
    var currentLevelDB: Float = -80

    /// Convenience: native rate is anything meaningfully above the 48 kHz ceiling.
    var isNativeRate: Bool { actualSampleRate > 60_000 }
}

enum AudioLevel {
    /// Floor for the dBFS meter so silence maps to a finite value.
    static let minDB: Float = -80

    /// Root-mean-square level of the first channel of `buffer`, in dBFS.
    ///
    /// Uses Accelerate (`vDSP_rmsqv`) so it stays cheap enough to run on every
    /// realtime capture callback even at 384 kHz.
    static func rmsDB(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return minDB }
        let frameCount = vDSP_Length(buffer.frameLength)
        guard frameCount > 0 else { return minDB }

        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, frameCount)

        guard rms > 0 else { return minDB }
        let db = 20 * log10(rms)
        return max(db, minDB)
    }

    /// Normalised 0...1 position for a dBFS value, for `ProgressView` / bars.
    static func normalized(_ db: Float) -> Double {
        Double((db - minDB) / -minDB)
    }
}
