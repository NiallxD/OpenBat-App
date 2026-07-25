//
//  WavPCMReader.swift
//  OpenBat
//
//  Reads an arbitrary sample range out of a 16-bit mono WAV written by
//  AudioRecorder (44-byte fixed header — see WavHeader.swift). Extracted from
//  the "seek to 44+n*2, read, int16→float" pattern duplicated between
//  RecordingSpectrogramRenderer (whole-file streaming) and PlaybackDriver
//  (real-time pacing) — WavSpectrogramEngine and CallAnalysis are a third and
//  fourth caller that need arbitrary, non-sequential ranges, which neither of
//  those two (each tied to their own streaming/pacing loop) exposes directly.
//

import AVFoundation
import Accelerate

/// `nonisolated`: stateless file I/O, same reasoning as `WavHeader` — safe to
/// call off the main thread (the caller decides where to run it).
nonisolated enum WavPCMReader {

    /// Reads up to `count` samples starting at `startSample`, converting
    /// 16-bit PCM to normalized Float32 ([-1, 1]) the same way AudioRecorder's
    /// writer and every other WAV reader in this codebase does (÷32767).
    /// Returns nil only if the file can't be opened/read or NO samples are
    /// available at `startSample` at all. A request that runs past the
    /// file's actual data (e.g. a selection/viewport dragged to the last
    /// sample, or a totalSamples value that's off by a handful of samples
    /// from what's actually on disk) returns a best-effort SHORTER array
    /// instead of nil — every caller here (STFTGrid, CallAnalysis) already
    /// tolerates a `pcm` shorter than requested; failing the whole read for
    /// being one sample over previously turned an at-the-edge selection into
    /// a silently empty analysis result, indistinguishable from "the
    /// analysis doesn't work".
    static func readSamples(wavURL: URL, startSample: Int, count: Int) -> [Float]? {
        guard startSample >= 0, count > 0 else {
            WavPlayerDebugLog.log("WavPCMReader", "readSamples: invalid range startSample=\(startSample) count=\(count)")
            return nil
        }
        CloudStorage.ensureDownloaded(wavURL)
        guard let handle = try? FileHandle(forReadingFrom: wavURL) else {
            WavPlayerDebugLog.log("WavPCMReader", "readSamples: FileHandle open FAILED for \(wavURL.lastPathComponent)")
            return nil
        }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(44 + startSample * 2))) != nil else {
            WavPlayerDebugLog.log("WavPCMReader", "readSamples: seek FAILED to offset \(44 + startSample * 2)")
            return nil
        }
        let data = WavPlayerDebugLog.time("WavPCMReader", "read \(count) samples (~\(count * 2 / 1024)KB)") {
            try? handle.read(upToCount: count * 2)
        }
        guard let data, !data.isEmpty else {
            WavPlayerDebugLog.log("WavPCMReader", "readSamples: read FAILED/empty at startSample=\(startSample) count=\(count)")
            return nil
        }

        let n = data.count / 2
        guard n > 0 else { return nil }
        if n < count {
            WavPlayerDebugLog.log("WavPCMReader", "readSamples: short read — got \(n) of \(count) requested (startSample=\(startSample), likely near EOF)")
        }
        var out = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            out.withUnsafeMutableBufferPointer { dst in
                vDSP_vflt16(src.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(n))
            }
        }
        var scale: Float = 1.0 / 32767.0
        vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(n))
        return out
    }
}
