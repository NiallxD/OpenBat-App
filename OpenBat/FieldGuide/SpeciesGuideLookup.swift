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
