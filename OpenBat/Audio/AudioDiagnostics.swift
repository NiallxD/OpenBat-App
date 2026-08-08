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
    /// For USB audio this is the device's own USB product string — vendor-chosen,
    /// not ours, which is why the contributed copy runs it through
    /// `AnonymizedUploadBuilder.sanitizedHardwareName` first.
    var inputName: String = "—"
    /// The port's unique identifier. NEVER contributed and never written to a
    /// recording — surfaced in Diagnostics only, because this is the field most
    /// likely to contain a hardware serial and the only way to find out what a
    /// given microphone actually reports is to look at it with one attached.
    var inputUID: String = "—"
    /// Whether the active input port reports as USB audio (vs. the built-in mic).
    var isUSBInput: Bool = false
    /// Whether any USB audio input (the Griff) is attached at all, active route or
    /// not — drives the mic-connection pill even while capture is stopped.
    var usbMicAvailable: Bool = false
    var channelCount: Int = 0
    /// Number of capture callbacks received since the engine started — should tick
    /// up steadily while running.
    var bufferCount: Int = 0
    /// Most recent buffer's RMS level in dBFS (~ -80...0), for the level meter.
    var currentLevelDB: Float = -80

    // MARK: Mic QA metrics
    //
    // Running stats accumulated since the current capture started (reset in
    // `AudioEngineController.start()`/`stop()`), meant for comparing microphone
    // units unit-to-unit rather than for the live meter above. Read these after
    // running the same short, repeatable test (e.g. N seconds in a quiet box,
    // then N seconds of a known loud source) so numbers are comparable across
    // units.

    /// Quietest buffer RMS seen this session, in dBFS — the mic's self-noise
    /// floor. Capture in a quiet enclosure; lower (more negative) is better.
    /// Starts at 0 dBFS (loudest possible), so the very first real buffer
    /// always lowers it to an actual reading.
    var noiseFloorDB: Float = 0
    /// Loudest buffer RMS seen this session, in dBFS — headroom/overload check.
    /// Close to 0 dBFS indicates clipping risk on loud calls.
    var peakLevelDB: Float = AudioLevel.minDB
    /// DC offset of the most recent buffer, as a percentage of full scale.
    /// A healthy capsule/ADC should center near 0%; a persistent nonzero
    /// offset points at a hardware fault (bad bias, faulty ADC channel).
    var dcOffsetPercent: Float = 0
    /// Samples at or above `AudioLevel.clipThreshold` this session — counts
    /// actual overload events, not just a level reading close to 0 dBFS.
    var clippedSampleCount: Int = 0
    /// Total samples processed this session, for turning `clippedSampleCount`
    /// into a rate.
    var totalSampleCount: Int64 = 0
    /// Fraction of samples this session that clipped, 0...1.
    var clipRate: Double {
        totalSampleCount > 0 ? Double(clippedSampleCount) / Double(totalSampleCount) : 0
    }

    /// Convenience: native rate is anything meaningfully above the 48 kHz ceiling.
    var isNativeRate: Bool { actualSampleRate > 60_000 }
}

/// `nonisolated`: same reasoning as `Biquad` — the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` would otherwise make this
/// stateless enum implicitly `@MainActor`, but `rmsDB(of:)` is called from
/// `AudioEngineController`'s real-time audio-tap closure (`installTap`), which
/// is `nonisolated` by design.
nonisolated enum AudioLevel {
    /// Floor for the dBFS meter so silence maps to a finite value.
    static let minDB: Float = -80
    /// Samples at or above this magnitude (full scale = 1.0) count as clipped.
    /// Set just under 0 dBFS rather than exactly 1.0 so a capsule/ADC that's
    /// pinned at the rail for a few samples below true full scale still gets
    /// caught, not just mathematically exact clipping.
    static let clipThreshold: Float = 0.98

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

    /// Peak level (dBFS), DC offset (fraction of full scale, signed), and
    /// clipped-sample count for the first channel of `buffer` — the mic-QA
    /// metrics surfaced in `AudioDiagnostics`. One Accelerate pass for peak
    /// and mean, plus a scalar pass for the clip count (buffers are at most a
    /// few thousand frames, so this stays cheap on the realtime tap).
    static func analyze(_ buffer: AVAudioPCMBuffer) -> (peakDB: Float, dcOffset: Float, clipped: Int, sampleCount: Int) {
        guard let channel = buffer.floatChannelData?[0] else { return (minDB, 0, 0, 0) }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return (minDB, 0, 0, 0) }

        var peakMagnitude: Float = 0
        vDSP_maxmgv(channel, 1, &peakMagnitude, vDSP_Length(frameCount))
        let peakDB = peakMagnitude > 0 ? max(20 * log10(peakMagnitude), minDB) : minDB

        var dcOffset: Float = 0
        vDSP_meanv(channel, 1, &dcOffset, vDSP_Length(frameCount))

        var clipped = 0
        for i in 0..<frameCount where abs(channel[i]) >= clipThreshold {
            clipped += 1
        }

        return (peakDB, dcOffset, clipped, frameCount)
    }

    /// Normalised 0...1 position for a dBFS value, for `ProgressView` / bars.
    static func normalized(_ db: Float) -> Double {
        Double((db - minDB) / -minDB)
    }
}
