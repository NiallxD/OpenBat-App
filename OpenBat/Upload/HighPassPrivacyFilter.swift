//
//  HighPassPrivacyFilter.swift
//  OpenBat
//
//  Irreversible privacy filter applied ONLY to the transient upload copy built
//  by UploadConversionPipeline — never to the on-device original, and never to
//  what the on-device classifier sees. Speech intelligibility lives almost
//  entirely below ~8-10kHz, so a cutoff around 12.5kHz removes it with margin.
//
//  KNOWN SCOPE LIMIT — the app has global users, and this cutoff does not suit
//  all of them.
//
//  For UK/European species the headroom is comfortable: the lowest callers
//  (noctule, Leisler's) bottom out around 17kHz, so 12.5kHz sits well clear,
//  and the worst case is mild attenuation of a sweep tail. That case was
//  reviewed and accepted — losing a little energy off the bottom of a noctule
//  call is tolerable.
//
//  Elsewhere it is not a question of attenuation but of exclusion. Several
//  species call at or below this cutoff and would be removed outright rather
//  than trimmed — the spotted bat (Euderma maculatum, ~9-12kHz) is the clearest
//  example, and various molossids (Tadarida, Otomops) and the greater noctule
//  (N. lasiopterus) run low enough to be affected. A contribution from one of
//  those is scientifically empty even though the file uploads successfully.
//
//  This is a genuine tension rather than an oversight: the cutoff cannot drop
//  much below ~12kHz without speech energy starting to survive, which would
//  undermine the basis on which contributed recordings are treated as
//  non-personal data. Privacy wins where they conflict.
//
//  What this does NOT affect is worth being clear about — a user recording
//  low-frequency species still gets full local recording, spectrograms and
//  species ID at full bandwidth. Only the contributed copy is filtered. So the
//  limitation costs those users nothing except the ability to usefully
//  contribute.
//
//  If low-frequency species become a priority, the fix is not a lower global
//  cutoff — it is deciding per species-region whether a recording is eligible
//  to contribute at all, and saying so in the UI rather than silently uploading
//  a hollowed-out file. Section count and exact cutoff are otherwise unvalidated
//  against real recordings.
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
    /// already used by `HeterodyneProcessor`.
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
