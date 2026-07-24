//
//  WavFileInfoCard.swift
//  OpenBat
//
//  A compact card under the spectrogram showing the recording's file facts,
//  read from the WAV's embedded GUANO metadata chunk (see GuanoMetadata)
//  plus the WAV header / filesystem. Same `filledPanelCard` + `PanelTitle`
//  look as the Call Analysis stats card above the spectrogram.
//
//  Metadata is read once, off the main actor, on appear (or when the file
//  changes) — a small seek+read, but file IO nonetheless, kept out of `body`.
//

import SwiftUI

struct WavFileInfoCard: View {
    let wavURL: URL

    @State private var rows: [(label: String, value: String)] = []

    var body: some View {
        VStack(spacing: 0) {
            PanelTitle("GUANO Metadata")
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if rows.isEmpty {
                Text("No metadata")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                VStack(spacing: 3) {
                    ForEach(rows, id: \.label) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.label)
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Text(row.value)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .filledPanelCard()
        .task(id: wavURL) { rows = await Self.loadRows(wavURL: wavURL) }
    }

    /// Reads GUANO + header/filesystem facts into display rows. `nonisolated`
    /// + `Task.detached` so the file IO stays off the main actor.
    private static func loadRows(wavURL: URL) async -> [(label: String, value: String)] {
        await Task.detached(priority: .utility) { () -> [(label: String, value: String)] in
            var out: [(String, String)] = []
            let guano = GuanoMetadata.read(from: wavURL) ?? [:]

            // Pull the most useful GUANO fields when present, in a sensible
            // order. Keys follow the GUANO standard GuanoMetadata writes.
            func add(_ label: String, _ keys: [String], transform: (String) -> String = { $0 }) {
                for key in keys {
                    if let v = guano[key], !v.isEmpty {
                        out.append((label, transform(v)))
                        return
                    }
                }
            }
            add("Timestamp", ["Timestamp"])
            add("Species", ["Species Manual ID", "Species Auto ID"])
            add("Location", ["Loc Position"])
            // Device = recording hardware (mic/host); App = the recording
            // software. See AudioRecorder.makeGuanoChunk for how these map to
            // GUANO Make/Model/Firmware Version. `OpenBat|App Version` is the
            // fallback for files recorded before the app moved into
            // `Firmware Version`.
            add("Device", ["Make", "Model"])
            add("App", ["Firmware Version", "OpenBat|App Version"])

            // Header/filesystem facts — always available.
            if let header = WavHeader.read(url: wavURL) {
                let sr = Double(header.sampleRate)
                out.append(("Sample rate", String(format: "%.0f kHz", sr / 1000)))
                let samples = Double(header.dataBytes) / 2
                if sr > 0 {
                    let secs = samples / sr
                    out.append(("Duration", String(format: "%.2f s", secs)))
                }
            }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: wavURL.path),
               let size = attrs[.size] as? Int64 {
                out.append(("File size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
            }
            out.append(("Filename", wavURL.lastPathComponent))
            return out.map { (label: $0.0, value: $0.1) }
        }.value
    }
}
