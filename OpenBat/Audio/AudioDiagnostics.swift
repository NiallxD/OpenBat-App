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

    /// The mic's own noise floor: the level 90% of this session was louder
    /// than, in dBFS. Capture in a quiet enclosure; lower is better.
    ///
    /// **A tenth percentile, not the quietest buffer seen** (2026-09-09). The
    /// running minimum this used to be measured one buffer out of hundreds of
    /// thousands, so it reported whatever the single quietest instant of the
    /// whole capture was — and since a capture's first buffers are routinely
    /// digital silence, that was the -80 dBFS floor, every time, on every
    /// microphone. A percentile over the whole capture is the number the label
    /// always claimed: what this mic sounds like when nothing is happening.
    var noiseFloorDB: Float = 0
    /// Whether `noiseFloorDB` holds a reading yet. False until enough of the
    /// capture is past the settling window — and false for a capture that is
    /// nothing but digital silence, which is a broken input rather than a very
    /// good one and must not be reported as -80 dBFS.
    var hasNoiseFloor: Bool = false
    /// Loudest buffer RMS seen this session, in dBFS — headroom/overload check.
    /// Close to 0 dBFS indicates clipping risk on loud calls.
    var peakLevelDB: Float = AudioLevel.minDB
    /// Mean DC offset ACROSS the session, as a percentage of full scale.
    /// A healthy capsule/ADC should centre near 0%; a persistent nonzero
    /// offset points at a hardware fault (bad bias, faulty ADC channel).
    ///
    /// Was the latest buffer's own mean until 2026-09-09, which is a different
    /// measurement entirely: a single ~10 ms window of real audio has a nonzero
    /// mean whether or not the hardware has any offset at all, so the number
    /// flickered at 15 Hz and said nothing. Averaged over a session, honest
    /// audio cancels and only a real offset survives.
    var dcOffsetPercent: Float = 0
    /// Samples at or above `AudioLevel.clipThreshold` this session — counts
    /// actual overload events, not just a level reading close to 0 dBFS.
    var clippedSampleCount: Int = 0
    /// Samples measured this session, for turning `clippedSampleCount` into a
    /// rate. Excludes the settling window (see
    /// `AudioLevel.micQASettleSeconds`), so it is a little short of the samples
    /// actually captured — the QA numbers are all quoted over the same span.
    var totalSampleCount: Int64 = 0
    /// Fraction of samples this session that clipped, 0...1.
    var clipRate: Double {
        totalSampleCount > 0 ? Double(clippedSampleCount) / Double(totalSampleCount) : 0
    }

    /// Convenience: native rate is anything meaningfully above the 48 kHz ceiling.
    var isNativeRate: Bool { actualSampleRate > 60_000 }

    /// Whether there is anything attached that calibration could meaningfully
    /// measure.
    ///
    /// Calibration exists to flatten an affordable ultrasonic microphone's
    /// uneven response across the bat band — the phone's built-in mic cannot
    /// reach that band at all, so calibrating it measures nothing and corrects
    /// nothing. Offering it anyway is how a new user ended up watching a
    /// fifteen-second countdown on a simulator with no mic attached, reassured
    /// it was "nice and quiet", before being told it hadn't worked.
    var canCalibrate: Bool { usbMicAvailable }

    /// The microphone's name for display, or a generic phrase when there isn't a
    /// usable one.
    ///
    /// `inputName` is the port name iOS reports, which for USB audio is the
    /// device's own product string — the right thing to show. For anything else
    /// it is a system identifier like "MicrophoneBuiltIn", which is a code name
    /// leaking into a sentence a user reads.
    var micDisplayName: String {
        guard isUSBInput, inputName != "—", !inputName.isEmpty else {
            return "your ultrasonic microphone"
        }
        return inputName
    }
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

    /// Audio ignored at the start of a capture before the QA numbers begin.
    ///
    /// An input unit's first moments are not the microphone: buffers of exact
    /// zeroes while the graph settles, and often one transient as it opens.
    /// Both landed in the old numbers — the zeroes pinned the noise floor to
    /// the meter's floor and the transient set the session peak — so both are
    /// measuring the start of a capture rather than a microphone.
    static let micQASettleSeconds = 0.25

    /// 1 dB bins from `minDB` up to 0 dBFS, for the noise-floor percentile.
    static let noiseHistogramBins = Int(-minDB) + 1

    /// Bin index for a buffer level, clamped into the histogram.
    static func noiseHistogramBin(_ db: Float) -> Int {
        min(max(Int((db - minDB).rounded(.down)), 0), noiseHistogramBins - 1)
    }

    /// The level `fraction` of the histogram's buffers sit at or below, taken
    /// at each bin's centre. `nil` when nothing has been counted.
    static func noisePercentileDB(_ histogram: [Int], fraction: Float) -> Float? {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return nil }
        let target = max(1, Int((Float(total) * fraction).rounded()))
        var seen = 0
        for (bin, count) in histogram.enumerated() {
            seen += count
            if seen >= target { return minDB + Float(bin) + 0.5 }
        }
        return minDB + Float(histogram.count - 1) + 0.5
    }

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

        // Clipped-sample count. The scalar loop is only entered when the peak
        // magnitude already computed above says at least one sample COULD be
        // clipped — which, on any capture that isn't actually clipping, is never.
        // This runs on the realtime capture thread at 384 kHz, so skipping the
        // pass in the ordinary case removes ~384 000 iterations a second for the
        // cost of one comparison.
        //
        // Deliberately not `vDSP_vclipc` (which does return clip tallies): that
        // needs an output buffer, and a reusable one would mean static mutable
        // state on a stateless enum touched from a realtime thread — a worse
        // trade than the loop it saves.
        var clipped = 0
        if peakMagnitude >= clipThreshold {
            for i in 0..<frameCount where abs(channel[i]) >= clipThreshold {
                clipped += 1
            }
        }

        return (peakDB, dcOffset, clipped, frameCount)
    }

    /// Normalised 0...1 position for a dBFS value, for `ProgressView` / bars.
    static func normalized(_ db: Float) -> Double {
        Double((db - minDB) / -minDB)
    }
}
