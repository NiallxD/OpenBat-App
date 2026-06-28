//
//  ClassificationStore.swift
//  OpenBat
//
//  Persistent record of AutoID "passes" (a run of pulses between silence gaps),
//  surfaced in the Sessions tab. Each pass keeps its contributing pulses with
//  their per-pulse species, confidence and a spectrogram thumbnail, so a tap can
//  reveal exactly what the aggregated ID was built from.
//
//  Records (metadata) persist as JSON; thumbnails as JPEGs under
//  Documents/Classifications/. The list is capped at `maxPasses`; pruned passes
//  have their thumbnails deleted too.
//

import UIKit
import Observation

// MARK: - Persisted records

struct ScoreEntry: Codable, Identifiable {
    let species: String
    let score: Float
    var id: String { species }
}

struct PulseRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let species: String
    let confidence: Float        // renormalized posterior of the winning species
    let peakFreqHz: Double
    let durationMs: Double
    let topScores: [ScoreEntry]  // strongest species, descending
    var imageFile: String?       // thumbnail filename under the images dir
}

struct PassRecord: Codable, Identifiable {
    let id: UUID
    let date: Date               // when the pass closed
    let species: String
    let commonName: String
    let confidence: Float        // mean posterior of the winner across pulses
    let pulseCount: Int          // pulses that contributed to the ID
    let pulses: [PulseRecord]
    /// Representative thumbnail (the highest-confidence pulse's image).
    var thumbnailFile: String? { pulses.max(by: { $0.confidence < $1.confidence })?.imageFile }
}

// MARK: - Transient capture (handed to the store before persistence)

/// One classified pulse, still holding its in-memory image. The store writes the
/// thumbnail and converts this into a `PulseRecord`.
struct CapturedPulse {
    let date: Date
    let species: String
    let confidence: Float
    let peakFreqHz: Double
    let durationMs: Double
    let topScores: [ScoreEntry]
    let image: UIImage?
}

// MARK: - Store

@Observable
final class ClassificationStore {

    private(set) var passes: [PassRecord] = []   // newest first

    private let maxPasses = 500
    private let thumbMaxWidth: CGFloat = 360

    private let dir: URL
    private let imagesDir: URL
    private let jsonURL: URL
    private let io = DispatchQueue(label: "bat.ClassificationStore.io", qos: .utility)

    // Small in-memory cache so scrolling the list doesn't re-decode JPEGs.
    private var imageCache = NSCache<NSString, UIImage>()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir       = docs.appendingPathComponent("Classifications", isDirectory: true)
        imagesDir = dir.appendingPathComponent("images", isDirectory: true)
        jsonURL   = dir.appendingPathComponent("passes.json")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: Add

    /// Build a `PassRecord` from a finished pass and persist it. Safe to call from
    /// the main thread; thumbnail encoding + disk writes happen off-thread.
    func addPass(species: String,
                 confidence: Float,
                 pulses: [CapturedPulse],
                 date: Date = Date()) {
        guard !pulses.isEmpty else { return }
        let passID = UUID()

        io.async { [weak self] in
            guard let self else { return }
            var records: [PulseRecord] = []
            records.reserveCapacity(pulses.count)
            for p in pulses {
                var file: String?
                if let img = p.image, let data = self.thumbnailJPEG(img) {
                    let name = "\(passID.uuidString)_\(records.count).jpg"
                    try? data.write(to: self.imagesDir.appendingPathComponent(name))
                    file = name
                }
                records.append(PulseRecord(id: UUID(), date: p.date, species: p.species,
                                           confidence: p.confidence, peakFreqHz: p.peakFreqHz,
                                           durationMs: p.durationMs, topScores: p.topScores,
                                           imageFile: file))
            }
            let pass = PassRecord(id: passID, date: date, species: species,
                                  commonName: SpeciesInfo.commonName[species] ?? species,
                                  confidence: confidence, pulseCount: pulses.count,
                                  pulses: records)

            DispatchQueue.main.async {
                self.passes.insert(pass, at: 0)
                self.prune()
                self.persist()
            }
        }
    }

    // MARK: Delete

    func delete(_ pass: PassRecord) {
        passes.removeAll { $0.id == pass.id }
        io.async { [weak self] in
            guard let self else { return }
            for p in pass.pulses where p.imageFile != nil {
                try? FileManager.default.removeItem(at: self.imagesDir.appendingPathComponent(p.imageFile!))
            }
        }
        persist()
    }

    func clearAll() {
        passes.removeAll()
        imageCache.removeAllObjects()
        io.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.imagesDir)
            try? FileManager.default.createDirectory(at: self.imagesDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: self.jsonURL)
        }
    }

    // MARK: Image loading

    func image(for record: PulseRecord) -> UIImage? {
        guard let file = record.imageFile else { return nil }
        if let cached = imageCache.object(forKey: file as NSString) { return cached }
        guard let img = UIImage(contentsOfFile: imagesDir.appendingPathComponent(file).path)
        else { return nil }
        imageCache.setObject(img, forKey: file as NSString)
        return img
    }

    // MARK: Private

    private func prune() {
        guard passes.count > maxPasses else { return }
        let removed = passes[maxPasses...]
        for pass in removed {
            for p in pass.pulses where p.imageFile != nil {
                let name = p.imageFile!
                io.async { [weak self] in
                    guard let self else { return }
                    try? FileManager.default.removeItem(at: self.imagesDir.appendingPathComponent(name))
                }
            }
        }
        passes.removeLast(passes.count - maxPasses)
    }

    private func thumbnailJPEG(_ image: UIImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, thumbMaxWidth / size.width)
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return scaled.jpegData(compressionQuality: 0.7)
    }

    private func persist() {
        let snapshot = passes
        io.async { [weak self] in
            guard let self else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: self.jsonURL)
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: jsonURL),
              let decoded = try? JSONDecoder().decode([PassRecord].self, from: data)
        else { return }
        passes = decoded
    }
}

// MARK: - Species names (shared)

enum SpeciesInfo {
    static let commonName: [String: String] = [
        "ANPA": "Pallid Bat",
        "COTO": "Townsend's Big-eared Bat",
        "EPFU": "Big Brown Bat",
        "EUMA": "Spotted Bat",
        "EUPE": "Western Mastiff Bat",
        "IDPH": "Allen's Big-eared Bat",
        "LABL": "Western Red Bat",
        "LABO": "Eastern Red Bat",
        "LACI": "Hoary Bat",
        "LAIN": "Northern Yellow Bat",
        "LANO": "Silver-haired Bat",
        "LASE": "Seminole Bat",
        "MYAU": "Southeastern Myotis",
        "MYCA": "California Myotis",
        "MYCI": "W. Small-footed Myotis",
        "MYEV": "Long-eared Myotis",
        "MYGR": "Gray Myotis",
        "MYLE": "E. Small-footed Myotis",
        "MYLU": "Little Brown Bat",
        "MYSE": "N. Long-eared Myotis",
        "MYSO": "Indiana Bat",
        "MYTH": "Fringed Myotis",
        "MYVE": "Cave Myotis",
        "MYVO": "Long-legged Myotis",
        "MYYU": "Yuma Myotis",
        "NOISE": "Non-bat noise",
        "NYHU": "Evening Bat",
        "NYMA": "Big Free-tailed Bat",
        "PAHE": "Canyon Bat",
        "PESU": "Tri-colored Bat",
        "TABR": "Brazilian Free-tailed Bat",
    ]
}
