//
//  SettingsDump.swift
//  OpenBat
//
//  Writes every live tunable, every persisted display/recording preference and
//  the full per-model AutoID configuration out to one JSON file, so a tuning
//  session on the device can be turned into code defaults without transcribing
//  slider positions by hand.
//
//  Reached from the Debug sheet (options menu → Debug → "Dump Settings to File",
//  debug mode only). The file lands in Documents so it survives the sheet and is
//  visible in Files.app, and the Debug sheet offers it to a ShareLink.
//
//  ⚠️ Keep this in step with `LiveTuningSnapshot`. That struct is the register of
//  every knob the tuning overlay exposes; this dump reuses it verbatim (rather
//  than re-reading each processor) precisely so a knob added there can't be
//  silently missing here. Everything OUTSIDE the overlay — the @AppStorage
//  display/recording keys and the AutoID model settings — is enumerated below by
//  hand, and does need adding to when a new one appears. See the audit note in
//  LiveTuningSnapshot.swift for how that convention has already failed once.
//

import Foundation

enum SettingsDump {

    /// Builds the JSON text. Pure — takes an already-captured tuning snapshot so
    /// it has no opinion about threading or about where the processors live.
    static func makeJSON(tuning: LiveTuningSnapshot,
                         autoID: AutoIDSettings,
                         appVersion: String) -> String {
        var root: [String: Any] = [:]

        root["_meta"] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": appVersion,
            "note": "Live values at dump time. Keys mirror the property paths they came from.",
        ]

        // MARK: Live tuning overlay (mirrors LiveTuningSnapshot field-for-field)

        root["heterodyne"] = [
            "audio.heterodyne.gain": tuning.heterodyneGain,
            "audio.audibleOffsetHz": tuning.audibleOffsetHz,
        ]

        root["haptics"] = [
            "haptics.strength": tuning.hapticStrength,
            "haptics.levelFloor": tuning.hapticLevelFloor,
            "haptics.levelCeiling": tuning.hapticLevelCeiling,
            "haptics.minIntensity": tuning.hapticMinIntensity,
            "haptics.freqFloorHz": tuning.hapticFreqFloorHz,
            "haptics.freqCeilingHz": tuning.hapticFreqCeilingHz,
            "haptics.buzzEnterHz": tuning.hapticBuzzEnterHz,
            "haptics.buzzExitHz": tuning.hapticBuzzExitHz,
            "haptics.rateWindow": tuning.hapticRateWindow,
            "haptics.buzzHangover": tuning.hapticBuzzHangover,
            "haptics.minTapInterval": tuning.hapticMinTapInterval,
        ]

        root["pulseDetector"] = [
            "pulse.triggerMode": tuning.triggerMode.rawValue,
            "pulse.amplitudeThreshold": tuning.amplitudeThreshold,
            "pulse.minFrequencyHz": tuning.minFrequencyHz,
            "pulse.minConsecutiveColumns": tuning.minConsecutiveColumns,
            "pulse.maxGapMs": tuning.maxGapMs,
            "pulse.holdOffSeconds": tuning.holdOffSeconds,
            "pulse.displayWindowMs": tuning.displayWindowMs,
            "pulse.pulseNoiseFloor": tuning.pulseNoiseFloor,
            "pulse.spectrogramNoiseFloor": tuning.spectrogramNoiseFloor,
        ]

        root["slowReplay"] = [
            "snippet.expansion": tuning.snippetExpansion,
            "snippet.memorySeconds": tuning.snippetMemorySeconds,
            "snippet.hissReductionDB": tuning.snippetHissReductionDB,
            "snippet.fadeMS": tuning.snippetFadeMS,
            "snippet.gain": tuning.snippetGain,
            "snippet.routing": tuning.snippetRouting.rawValue,
            "snippet.routingLabel": tuning.snippetRouting.label,
        ]

        root["display"] = [
            "bandLow": tuning.bandLow,
            "bandHigh": tuning.bandHigh,
            "timeWindowSeconds": tuning.timeWindowSeconds,
            "pulse.displayPalette": tuning.displayPalette.rawValue,
            "pulse.displayPaletteName": tuning.displayPalette.displayName,
        ]

        // MARK: Persisted preferences outside the overlay

        // ⚠️ The fallbacks below must match each key's real default at its
        // declaration site — they stand in for a key that has never been
        // written, so a stale one makes the dump report a value the app has
        // never used, which is worse than reporting nothing.
        //
        // Three concrete readers rather than one generic one. A generic
        // `stored<T>` assigned straight into a `[String: Any]` subscript infers
        // `T == Any?`, so a key that has never been written reads back as
        // `.some(nil)`, the `??` never fires, and assigning nil DELETES the key
        // — every not-yet-touched preference silently vanished from the dump,
        // which is exactly the set most worth seeing.
        let d = UserDefaults.standard
        func storedBool(_ key: String, _ fallback: Bool) -> Bool {
            d.object(forKey: key) as? Bool ?? fallback
        }
        func storedDouble(_ key: String, _ fallback: Double) -> Double {
            d.object(forKey: key) as? Double ?? fallback
        }
        func storedInt(_ key: String, _ fallback: Int) -> Int {
            d.object(forKey: key) as? Int ?? fallback
        }

        // Built up key by key rather than as one literal: a single heterogeneous
        // dictionary literal this size sends the type checker into the weeds
        // ("unable to type-check this expression in reasonable time").
        var appStorage: [String: Any] = [:]
        for key in ["display.showNoID",
                    "display.pulseLogFrequency",
                    "display.spectrogramLogFrequency",
                    "display.wavPlayerLogFrequency",
                    "display.spectrogramShowsSpeciesID",
                    "display.pulseShowsSpeciesID",
                    "display.wavPlayerShowFileInfo"] {
            appStorage[key] = storedBool(key, false)
        }
        appStorage["display.bandLow"] = storedDouble("display.bandLow", 0.02)
        appStorage["display.bandHigh"] = storedDouble("display.bandHigh", 0.45)
        appStorage["display.playbackThumbnailNoiseFloor"] =
            storedDouble("display.playbackThumbnailNoiseFloor", 0.40)
        appStorage["display.wavPlayerSilenceSensitivity"] =
            storedDouble("display.wavPlayerSilenceSensitivity", 0.5)
        appStorage["display.wavPlayerSilencePadding"] =
            storedDouble("display.wavPlayerSilencePadding", 0.02)
        appStorage["pulse.displayPalette"] = storedInt("pulse.displayPalette", 0)
        appStorage["recording.autoRecordOnSessionStart"] =
            storedBool("recording.autoRecordOnSessionStart", true)
        root["appStorage"] = appStorage

        // MARK: AutoID — per model, with the species table in full

        var models: [String: Any] = [:]
        for (id, m) in autoID.perModel {
            var species: [String: Any] = [:]
            for (code, s) in m.species {
                species[code] = ["enabled": s.enabled, "prior": s.prior]
            }
            var entry: [String: Any] = [:]
            entry["passTimeoutSeconds"] = m.passTimeoutSeconds
            entry["minPassConfidence"] = m.minPassConfidence
            entry["minPassPulseCount"] = m.minPassPulseCount
            entry["qualityGateEnabled"] = m.qualityGateEnabled
            entry["qualitySNThreshold"] = m.qualitySNThreshold
            entry["qualityAmpThreshold"] = m.qualityAmpThreshold
            entry["enabledSpeciesCount"] = m.species.values.filter { $0.enabled }.count
            entry["species"] = species
            models[id] = entry
        }
        root["autoID"] = [
            "activeModelID": autoID.activeModelID ?? "<none>",
            "mapPinMinConfidence": autoID.mapPinMinConfidence,
            "mapPinMinPulseCount": autoID.mapPinMinPulseCount,
            "perModel": models,
        ]

        guard let data = try? JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"could not serialise settings\"}"
        }
        return text
    }

    /// Writes the JSON into Documents under a timestamped name and returns the
    /// URL. Timestamped rather than overwritten so a run of A/B tuning leaves a
    /// trail instead of one file that only remembers the last try.
    static func write(_ json: String) -> URL? {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("OpenBat-Settings-\(stamp.string(from: Date())).json")
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
