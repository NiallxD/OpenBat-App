//
//  QualityGate.swift
//  OpenBat
//
//  Reject-or-flag check on the upload copy before it's queued for upload — a
//  fail here means "don't upload this one," never "touch the on-device
//  original." Thresholds are placeholders: per the spec (§5 point 4 and §8),
//  these need calibration against real recordings from actual target hardware
//  (self-build/consumer USB mics in noisy real conditions), not lab
//  conditions — deliberately not tuned strict enough to filter out the
//  realistic noise the eventual model needs to learn to handle. See the
//  implementation plan's Phase 7.
//

import Accelerate

struct UploadQualityGateResult {
    let passed: Bool
    let snrDB: Double
    let clippingFraction: Double
    let pulseCount: Int
}

/// Named `Upload*` to avoid colliding with the unrelated `QualityGate` already
/// used by the on-device classifier (`Classifier/BatClassifier.swift`).
///
/// `nonisolated`: scans every sample of the upload copy from
/// `UploadConversionPipeline.convert`, off the main actor — see that type's
/// own `nonisolated` doc comment for why this needs it too.
nonisolated enum UploadQualityGate {
    static let minSNRdB = 6.0
    static let maxClippingFraction = 0.01
    static let minPulseCount = 1

    /// Streaming evaluator: `UploadConversionPipeline` feeds it a block at a time
    /// so a long recording never has to be resident in memory at once (a 600 s
    /// segment at 384 kHz is 230 M samples — the previous whole-array `sorted()`
    /// alone allocated ~1.8 GB for it).
    ///
    /// Exact, not approximate, despite being a histogram: the source is 16-bit
    /// PCM read back as `Int16 / 32767`, so sample magnitudes take only 32 768
    /// distinct values and one bucket per value loses nothing. Both statistics
    /// below are order statistics of |sample|, and squaring is monotonic on
    /// non-negatives, so ranking by magnitude ranks by power identically to the
    /// old sort-the-whole-array implementation.
    ///
    /// Checked against that implementation over randomised 16-bit input fed in
    /// irregular blocks: clipping fraction matches exactly, and SNR agrees to
    /// within 2e-5 dB — a `Double` accumulator here versus the old `Float`
    /// `reduce`, so the small difference is this version being the more accurate
    /// of the two, against a 6 dB threshold.
    struct Accumulator {
        /// Index = round(|sample| * 32767), i.e. the original Int16 magnitude.
        private var counts = [UInt64](repeating: 0, count: magnitudeLevels)
        private var total = 0

        init() {}

        mutating func add(_ pcm: [Float]) {
            for sample in pcm {
                // Int16.min (-32768) normalises to -1.00003, one step past the
                // top bucket — clamped rather than widening the table for a
                // single value that is, by any definition, clipped anyway.
                let level = Int((sample.magnitude * 32767).rounded())
                counts[min(level, Self.magnitudeLevels - 1)] += 1
            }
            total += pcm.count
        }

        /// `pulseCount` comes from the segment's own classification pipeline
        /// (GUANO `OpenBat|Species Pulse Count`) rather than being recomputed
        /// here — `PulseDetector` already did that work live.
        func result(pulseCount: Int) -> UploadQualityGateResult {
            let snr = estimateSNRdB()
            let clipping = clippingFraction()
            let passed = snr >= minSNRdB && clipping <= maxClippingFraction && pulseCount >= minPulseCount
            return UploadQualityGateResult(passed: passed, snrDB: snr,
                                           clippingFraction: clipping, pulseCount: pulseCount)
        }

        /// Crude proxy, not a calibrated measurement: ratio of the loudest 5% of
        /// samples (by power) to the median — "signal peaks stand out above a
        /// typical sample" rather than a true noise-floor-vs-signal measurement,
        /// which would need pulse-level timing this stage doesn't have.
        private func estimateSNRdB() -> Double {
            guard total > 0 else { return 0 }
            let median = power(atRank: total / 2)
            let topCount = max(1, total / 20)
            let topMean = meanPowerOfLoudest(topCount)
            guard median > 0 else { return topMean > 0 ? 96 : 0 }
            return 10 * log10(topMean / median)
        }

        /// Power of the sample at ascending rank `rank` — the histogram
        /// equivalent of indexing into a fully sorted array.
        private func power(atRank rank: Int) -> Double {
            var seen = 0
            for level in counts.indices {
                seen += Int(counts[level])
                if seen > rank { return Self.power(ofLevel: level) }
            }
            return Self.power(ofLevel: counts.count - 1)
        }

        /// Mean power of the loudest `count` samples, walking buckets downward.
        private func meanPowerOfLoudest(_ count: Int) -> Double {
            var remaining = count
            var sum = 0.0
            for level in counts.indices.reversed() where counts[level] > 0 {
                let taken = min(remaining, Int(counts[level]))
                sum += Double(taken) * Self.power(ofLevel: level)
                remaining -= taken
                if remaining == 0 { break }
            }
            return sum / Double(count)
        }

        private func clippingFraction() -> Double {
            guard total > 0 else { return 0 }
            let clipped = counts[Self.clippingLevel...].reduce(0) { $0 + Int($1) }
            return Double(clipped) / Double(total)
        }

        /// Normalised magnitude of a bucket, squared — matching what the old
        /// implementation computed per sample via `vDSP_vsq`.
        private static func power(ofLevel level: Int) -> Double {
            let magnitude = Double(level) / 32767
            return magnitude * magnitude
        }

        /// Lowest bucket whose normalised magnitude is >= 0.999, the old
        /// per-sample clipping test (0.999 * 32767 = 32734.2).
        private static let clippingLevel = Int((0.999 * 32767).rounded(.up))
        fileprivate static let magnitudeLevels = 32768
    }
}
