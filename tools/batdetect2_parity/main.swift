//
//  main.swift
//  tools/batdetect2_parity
//
//  Dumps the exact 128×256 tensor OpenBat hands BatDetect2's CoreML model, for one
//  window of audio, so it can be compared numerically against the reference Python
//  pipeline (see compare.py). Not part of the app target: `build.sh` compiles it
//  against the app's real DSP sources, so what this prints is what ships — not a
//  re-implementation that could drift from it.
//
//  Input and output are both raw little-endian float32 files, so nothing here has to
//  parse a WAV and neither side can disagree about what samples went in.
//
//  Usage:
//      dump_tensor --input capture.f32 --output tensor.f32 [--rate 256000]
//
//  --rate is the rate of the samples in `--input`. At 384000 (the app's native
//  capture rate) this resamples first, exactly as BatDetect2Classifier does, so the
//  comparison covers the resampler too; at 256000 it renders directly and the
//  comparison isolates the spectrogram transform.
//

import Foundation

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func argument(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func readFloats(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count % MemoryLayout<Float>.size == 0 else {
        throw ToolError("\(url.lastPathComponent) is not a whole number of float32 samples")
    }
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let inputPath = argument("--input", in: args),
          let outputPath = argument("--output", in: args) else {
        throw ToolError("usage: dump_tensor --input capture.f32 --output tensor.f32 [--rate 256000]")
    }
    let rate = Double(argument("--rate", in: args) ?? "256000") ?? 256_000

    var pcm = try readFloats(URL(fileURLWithPath: inputPath))
    if rate != BatDetect2SpectrogramRenderer.targetSampleRate {
        pcm = PolyphaseResampler.resample(pcm, from: rate,
                                          to: BatDetect2SpectrogramRenderer.targetSampleRate)
    }

    guard let rendered = BatDetect2SpectrogramRenderer.render(pcm: pcm) else {
        throw ToolError("renderer returned nil — input shorter than one FFT window?")
    }
    let expected = BatDetect2SpectrogramRenderer.outH * BatDetect2SpectrogramRenderer.outW
    guard rendered.channels == 1, rendered.image.count == expected else {
        throw ToolError("unexpected tensor: \(rendered.image.count) values, \(rendered.channels) channels")
    }

    try rendered.image.withUnsafeBufferPointer {
        try Data(buffer: $0).write(to: URL(fileURLWithPath: outputPath))
    }
    FileHandle.standardError.write(Data("wrote \(expected) float32 values to \(outputPath)\n".utf8))
}

do { try run() } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
