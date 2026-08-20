//
//  SpeciesGuideLookup.swift
//  OpenBat
//
//  Resolves a classifier species CODE (the 4-letter NABat "MYCA" / 6-letter
//  BatDetect2 "PIPPIP" labels that appear on passes, recordings and the live
//  stats strip) to a field-guide page, so a detection can link straight to the
//  species profile.
//
//  The two vocabularies are joined on scientific name, not on the code: the
//  guide JSON is community-edited and deliberately knows nothing about which
//  model produced a detection, while every model descriptor already carries an
//  authoritative code → scientific name table (ModelRegistry's
//  `scientificNames`, cross-checked against NABat's own reference sheet — see
//  BatClassifier.scientificNames). Joining there means a new model, or a new
//  guide entry, needs no third mapping table kept in sync with the other two.
//

import Foundation

extension SpeciesGuide {
    /// The guide page for a classifier species code, or nil if the guide has no
    /// entry for it yet. Callers use the nil case to decide whether the code is
    /// worth making tappable at all — the community guide covers far fewer
    /// species than the models can name, and offering a link to a page that
    /// doesn't exist is worse than offering none.
    func species(forCode code: String) -> GuideSpecies? {
        guard let scientific = Self.scientificName(forCode: code) else { return nil }
        let target = Self.normalized(scientific)
        return species.first { Self.normalized($0.scientificName) == target }
    }

    /// The classifier code for a guide species, or nil when no model can name
    /// it. The inverse of `scientificName(forCode:)`, and joined the same way.
    ///
    /// Needed because `SpeciesPresenceData.json` is keyed by code (one code can
    /// span several taxa — see SpeciesPresenceStore's header) while the guide
    /// knows only scientific names. Guide coverage and model coverage are
    /// different sets in both directions: the guide describes bats no model can
    /// name, and the models name far more bats than the guide describes.
    static func code(forScientificName scientific: String) -> String? {
        let target = normalized(scientific)
        for model in ModelRegistry.all {
            for (code, name) in model.scientificNames where normalized(name) == target {
                return code
            }
        }
        return nil
    }

    /// Scientific name for a code, from whichever model names it. Codes are
    /// unique per model but not formally reserved across models, so this takes
    /// the first match; the two bundled models use different code lengths (4 vs
    /// 6 letters) and don't currently collide.
    ///
    /// Non-taxon classes ("NOISE", "NOID") are absent from every descriptor's
    /// `scientificNames` by construction, so they resolve to nil here and never
    /// reach the guide.
    private static func scientificName(forCode code: String) -> String? {
        for model in ModelRegistry.all {
            if let name = model.scientificNames[code] { return name }
        }
        return nil
    }

    /// Case- and whitespace-insensitive: the guide is hand-edited JSON, so a
    /// stray trailing space or a lowercased genus in a contributed entry
    /// shouldn't silently break the link to a detection.
    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension GuideSpecies {
    /// The presence-grid key for this species — what `SpeciesPresenceData.json`
    /// is keyed by, and what `GBIFDistributionCard` / "bats near you" look
    /// each guide entry up with.
    ///
    /// **Never nil, which is the point.** The guide used to carry a `code`
    /// field a contributor filled in for a species no model names, and an
    /// entry that left it blank got no distribution map and never appeared in
    /// the near-you list. That was an unanswerable question to put to a
    /// contributor — a classifier code is a fact about our models, not about
    /// the bat — and it only got worse with scale: the guide is heading for
    /// ~1500 species against the models' 47, so for the overwhelming majority
    /// there is no model label to know, and hand-minted codes collide (both
    /// *Myotis nattereri* and *M. natalensis* want MYONAT).
    ///
    /// So: a model's own code when one names this species — the classifier
    /// stores, tags and exports detections under that code, so the presence
    /// entry must share it — and otherwise the entry's `id` slug, which is
    /// already unique and already the stable identity everything else
    /// references. A slug key is never displayed: a species no model names
    /// can never be a detection, so nothing shows it where a code belongs.
    var presenceCode: String {
        SpeciesGuide.code(forScientificName: scientificName) ?? id
    }
}
