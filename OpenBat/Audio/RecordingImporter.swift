//
//  RecordingImporter.swift
//  OpenBat
//
//  Brings a WAV the user picks with the system document picker into the
//  recordings library, so an external file — a reference recording, something
//  from another detector, a call library download — opens in WavPlayerView and
//  auditions through the listening modes exactly like a recording the app made
//  itself.
//
//  This is the only way to get a known-good bat call through the listening modes
//  without a live bat. `PlaybackEngine` drives heterodyne / time expansion from
//  a file at its NATIVE sample rate (see
//  `PlaybackEngine.load`, which passes the file's rate straight into each
//  processor's `reset`), so importing a 384 kHz recording exercises the real DSP
//  path with no microphone, speaker or signal generator in the loop — none of
//  which can reproduce ultrasound faithfully enough to judge the result.
//
//  SPLIT IN TWO ON PURPOSE, and the split matters:
//
//    • `copyIntoLibrary` MUST run synchronously inside the `.fileImporter`
//      completion handler — the sandbox extension the document picker grants
//      is scoped to that call, so deferring the copy to a detached task loses
//      it and `copyItem` fails. A file copy is fast enough to accept on the
//      main actor.
//
//    • `renderOverview` is the genuinely slow part (a full FFT pass over the
//      file) and takes a URL inside our OWN container, so it needs no sandbox
//      extension and belongs on a background task.
//

import Accelerate
import AVFoundation
import CoreLocation
import Foundation
import UIKit

nonisolated enum RecordingImporter {

    enum ImportError: LocalizedError {
        case noAccess
        case notAudio(String)
        case emptyFile
        case copyFailed(String)
        case convertFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAccess:
                return "The file could not be opened. If it's stored in iCloud Drive, open it in the Files app once to download it, then try again."
            case .notAudio(let why):
                return "That file could not be read as audio. \(why)"
            case .emptyFile:
                return "That file contains no audio."
            case .copyFailed(let why):
                return "The file could not be copied into the recordings library. \(why)"
            case .convertFailed(let why):
                return "That file could not be converted into a format the app can play. \(why)"
            }
        }
    }

    /// A file already copied into our container, ready for `renderOverview` and
    /// then `ClassificationStore.addRecording`. `Sendable` so it can cross into
    /// the background render task.
    struct Copied: Sendable {
        let url: URL
        let relativeWavPath: String
        let date: Date
        let durationSeconds: Double
        let sampleRate: Double
        /// From the file's own GUANO chunk when it has one. `species` is "NOID"
        /// for a file with no usable metadata.
        let species: String
        let confidence: Float?
        let pulseCount: Int
        let coordinate: CLLocationCoordinate2D?
    }

    /// Copies the picked file into `Recordings/Imported/<day>/` and probes its
    /// format. **Call this synchronously from the `.fileImporter` completion
    /// handler** — see the file comment for why deferring it breaks.
    static func copyIntoLibrary(source: URL) throws -> Copied {
        // A document-picker URL points outside the app container and needs an
        // explicit sandbox extension held across the read.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        // A URL already inside our container isn't security-scoped and
        // `startAccessing...` correctly returns false for it, so failing on
        // that alone would be wrong — test actual readability instead.
        guard scoped || FileManager.default.isReadableFile(atPath: source.path) else {
            throw ImportError.noAccess
        }

        let probe: AVAudioFile
        do {
            probe = try AVAudioFile(forReading: source)
        } catch {
            throw ImportError.notAudio(error.localizedDescription)
        }
        let sampleRate = probe.fileFormat.sampleRate
        let frames = probe.length
        guard sampleRate > 0, frames > 0 else { throw ImportError.emptyFile }

        // Deliberately its own `Imported/` tree rather than mixing into
        // `Listening/` or `Sessions/`: `RecordingMigration` scans those to
        // re-adopt WAVs the store lost track of, and inferring a session or a
        // capture date from an imported filename would be wrong.
        let docs = CloudStorage.baseDirectory
        let dayFormatter = ISO8601DateFormatter()
        dayFormatter.formatOptions = [.withFullDate]
        let dir = docs.appendingPathComponent(
            "Recordings/Imported/\(dayFormatter.string(from: Date()))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let base = source.deletingPathExtension().lastPathComponent
        var dest = dir.appendingPathComponent("\(base).wav")
        var suffix = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base)-\(suffix).wav")
            suffix += 1
        }
        do {
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }

        // Same relative-path derivation `AudioRecorder` uses.
        let relative = String(dest.path.dropFirst(docs.path.count + 1))

        // Read the file's own GUANO chunk if it has one, so re-importing a
        // recording OpenBat exported round-trips its species, confidence, pulse
        // count, capture timestamp and GPS position instead of arriving as a
        // dateless "NoID". Shared with RecordingMigration — see
        // GuanoRecordingFields.
        //
        // Falls back to the file's modification date so an imported file with no
        // metadata still sorts by roughly when it was recorded rather than when
        // it was imported.
        let fallbackDate = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let guano = GuanoMetadata.read(from: dest).map {
            GuanoRecordingFields.parse($0, wavURL: dest, fallbackDate: fallbackDate)
        }

        // Unlike RecordingMigration, a NOISE tag is not grounds for rejection
        // here: the user deliberately picked this file, and silently refusing it
        // would be baffling. Demote it to NOID and let them listen.
        let species = (guano?.isNoise ?? true) ? "NOID" : (guano?.species ?? "NOID")

        // GUANO's own "Length" is authoritative when present, but the frame count
        // we just probed is measured from the actual data chunk, so prefer that.
        let measured = Double(frames) / sampleRate

        return Copied(url: dest,
                      relativeWavPath: relative,
                      date: guano?.date ?? fallbackDate,
                      durationSeconds: measured > 0 ? measured : (guano?.durationSeconds ?? 0),
                      sampleRate: sampleRate,
                      species: species,
                      confidence: species == "NOID" ? nil : guano?.confidence,
                      pulseCount: guano?.pulseCount ?? 0,
                      coordinate: guano?.coordinate)
    }

    /// Rewrites an imported file into the canonical 16-bit mono PCM layout the
    /// rest of the app assumes, unless it is already in it.
    ///
    /// **Why this exists.** Four readers — the WAV player's PCM reader, the STFT
    /// grid, the playback engine and the header parser — all seek straight to byte
    /// 44 and read 16-bit mono samples. That is true of every file `AudioRecorder`
    /// writes and of almost nothing else. A WAV with a `LIST`/`INFO` chunk (which
    /// Audacity, Wildlife Acoustics and Pettersson all commonly write), an
    /// extensible `fmt `, a stereo file, 24-bit or float PCM, or an AIFF/m4a the
    /// picker also accepts, would have its audio read from the wrong offset in the
    /// wrong format — showing a noise spectrogram and playing as static, with no
    /// error. Those are exactly the files the importer exists for.
    ///
    /// Converting on the way in was chosen over teaching all four readers to parse
    /// the chunk table: one place changes instead of four, and anything that can't
    /// be converted fails loudly here rather than silently downstream.
    ///
    /// **A file already in canonical shape is left byte-for-byte alone**, which is
    /// what preserves the `guan` chunk when someone re-imports an OpenBat export —
    /// rewriting the samples would drop the trailing metadata and cost the
    /// round-trip that `copyIntoLibrary` reads it for.
    ///
    /// Slow for a long file, and safe to defer (the URL is inside our own
    /// container and needs no sandbox extension), so this is deliberately NOT part
    /// of `copyIntoLibrary` — see this file's header comment for that split.
    static func normalizeIfNeeded(at url: URL) throws {
        CloudStorage.ensureDownloaded(url)
        if let format = WavHeader.describe(url: url), format.isCanonical { return }

        let source: AVAudioFile
        do { source = try AVAudioFile(forReading: url) }
        catch { throw ImportError.convertFailed(error.localizedDescription) }

        // The processing format is always deinterleaved Float32; reading through it
        // lets AVAudioFile handle 24-bit, float, big-endian AIFF and compressed
        // sources uniformly, so none of that decoding lives here.
        let readFormat = source.processingFormat
        let sampleRate = source.fileFormat.sampleRate
        let frames = source.length
        guard sampleRate > 0, frames > 0 else { throw ImportError.emptyFile }

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).converting")
        try? FileManager.default.removeItem(at: temp)
        guard FileManager.default.createFile(atPath: temp.path, contents: nil),
              let out = try? FileHandle(forWritingTo: temp)
        else { throw ImportError.convertFailed("Could not create a working file.") }
        var completed = false
        defer {
            try? out.close()
            if !completed { try? FileManager.default.removeItem(at: temp) }
        }

        // Placeholder sizes, patched once the true length is known — the same
        // two-pass write `AudioRecorder` does, and for the same reason: the frame
        // count a decoder reports is not always what it ultimately yields.
        try? out.write(contentsOf: AudioRecorder.wavHeader(sampleRate: UInt32(sampleRate.rounded()),
                                                           dataBytes: 0))

        let chunkFrames: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: chunkFrames)
        else { throw ImportError.convertFailed("Could not allocate a conversion buffer.") }

        let channels = Int(readFormat.channelCount)
        var mono = [Float](repeating: 0, count: Int(chunkFrames))
        var pcm  = [Int16](repeating: 0, count: Int(chunkFrames))
        var totalFrames = 0

        // Loop on the file's own position, NOT on `read` returning zero frames.
        // `AVAudioFile.read` is documented to come back with a frameLength of 0 at
        // end of file; it actually THROWS. Trusting the documented behaviour made
        // every conversion fail on its last iteration, after all the audio had been
        // written — so a perfectly good import was reported as unconvertible and
        // deleted. Caught by `RecordingImporterTests`, not by inspection.
        while source.framePosition < frames {
            buffer.frameLength = 0
            do { try source.read(into: buffer, frameCount: chunkFrames) }
            catch { throw ImportError.convertFailed(error.localizedDescription) }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }

            // Downmix by averaging: a stereo file read as consecutive mono samples
            // was one of the ways this went wrong before, and dropping a channel
            // would throw away half the recording on a two-mic setup.
            if channels == 1 {
                mono.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.update(from: data[0], count: n)
                }
            } else {
                mono.withUnsafeMutableBufferPointer { dst in
                    guard let d = dst.baseAddress else { return }
                    vDSP_vclr(d, 1, vDSP_Length(n))
                    for c in 0..<channels { vDSP_vadd(d, 1, data[c], 1, d, 1, vDSP_Length(n)) }
                    var scale = Float(1) / Float(channels)
                    vDSP_vsmul(d, 1, &scale, d, 1, vDSP_Length(n))
                }
            }

            // Clamp before scaling: a float WAV is not guaranteed to sit inside
            // [-1, 1], and vDSP_vfix16 wraps rather than saturates, which would
            // turn a hot sample into full-scale noise of the opposite sign.
            var low: Float = -1, high: Float = 1
            mono.withUnsafeMutableBufferPointer { m in
                vDSP_vclip(m.baseAddress!, 1, &low, &high, m.baseAddress!, 1, vDSP_Length(n))
                var scale = Float(Int16.max)
                vDSP_vsmul(m.baseAddress!, 1, &scale, m.baseAddress!, 1, vDSP_Length(n))
                pcm.withUnsafeMutableBufferPointer { p in
                    vDSP_vfix16(m.baseAddress!, 1, p.baseAddress!, 1, vDSP_Length(n))
                }
            }

            pcm.withUnsafeBufferPointer { p in
                try? out.write(contentsOf: Data(bytes: p.baseAddress!, count: n * 2))
            }
            totalFrames += n
        }

        guard totalFrames > 0 else { throw ImportError.emptyFile }
        try? out.seek(toOffset: 0)
        try? out.write(contentsOf: AudioRecorder.wavHeader(sampleRate: UInt32(sampleRate.rounded()),
                                                           dataBytes: UInt32(totalFrames * 2)))
        try? out.close()

        // Swap the converted file in. Deliberately remove-then-move rather than
        // `replaceItemAt`, which fails here with an opaque generic error — and the
        // atomicity it offers buys nothing at this point: the only file at stake is
        // a copy the importer made moments ago, and every throw out of this function
        // makes the caller delete it anyway.
        do {
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temp, to: url)
        } catch {
            throw ImportError.convertFailed(error.localizedDescription)
        }
        completed = true
    }

    /// Overview thumbnail for an already-copied file. Slow (a full FFT pass), so
    /// call it off the main actor — but safe to defer, because the URL is inside
    /// our own container and needs no sandbox extension.
    ///
    /// maxWidth 4096 matches what `AudioRecorder` requests and what
    /// `WavSpectrogramEngine.renderOverview` looks for, so the WAV player's cache
    /// hits instead of re-rendering on first open.
    static func renderOverview(at url: URL) -> UIImage? {
        RecordingSpectrogramRenderer.render(wavURL: url, maxWidth: 4096)
    }
}
