//
//  HighPassPrivacyFilter.swift
//  OpenBat
//
//  Irreversible privacy filter applied ONLY to the transient upload copy built
//  by UploadConversionPipeline — never to the on-device original. Speech
//  intelligibility lives almost entirely below ~8-10kHz; UK bat species call
//  no lower than ~17kHz even at the extreme low end (noctule FM sweep tail),
//  so a cutoff in the 12-13kHz target range gives headroom below that floor
//  without touching real call content.
//
//  Cutoff and section count are placeholders pending validation against real
//  noctule recordings (see openbat-onboarding-consent-upload-spec.md §5.2 and
//  the plan's Phase 7) — UK-species-scoped; revisit for any non-UK species
//  whose calls run lower.
//

import Foundation

/// `nonisolated`: same reasoning as `Biquad` itself — called per-sample, in a loop,
/// from `UploadConversionPipeline.convert` off the main actor; without this it would
/// inherit the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` default and force
/// a blocking hop for the whole filter pass.
/// Stateful so a recording can be filtered in chunks: `UploadConversionPipeline`
/// streams multi-hundred-megabyte recordings through this a block at a time, and
/// the cascade's biquad state has to carry across block boundaries or every block
/// seam becomes a filter transient (an audible click, and a spurious broadband
/// column in any spectrogram made from the result).
nonisolated struct HighPassPrivacyFilter {
    static let defaultCutoffHz: Double = 12_500

    /// A single RBJ biquad section only rolls off ~12 dB/octave — not steep
    /// enough for a "guarantee", not "reduce the likelihood", per the spec's own
    /// wording. Cascading identical sections multiplies the rolloff (4 sections
    /// ≈ 48 dB/octave), which is what makes this a guarantee rather than a
    /// gentle tilt. Section count is itself part of what Phase 7 validates.
    static let cascadedSections = 4

    /// Reuses `Biquad.highpass` (`DSP/Biquad.swift`) — the same coefficient math
    /// already used by `HeterodyneProcessor`/`TimeExpansionProcessor`.
    private var sections: [Biquad]

    init(sampleRate: Double, cutoffHz: Double = defaultCutoffHz) {
        sections = (0..<Self.cascadedSections).map { _ in
            Biquad.highpass(cutoff: cutoffHz, sampleRate: sampleRate)
        }
    }

    /// Filters `pcm` in place, carrying cascade state into the next call.
    mutating func process(_ pcm: inout [Float]) {
        for i in pcm.indices {
            var sample = pcm[i]
            for s in sections.indices { sample = sections[s].process(sample) }
            pcm[i] = sample
        }
    }
}
