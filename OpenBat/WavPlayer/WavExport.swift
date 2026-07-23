//
//  WavExport.swift
//  OpenBat
//
//  Bundles a recording's WAV plus a rendered spectrogram PNG into a single
//  .zip for the share sheet. Uses NSFileCoordinator's `.forUploading`
//  coordinated read — which hands back a zipped copy of a directory — so no
//  third-party zip dependency is needed. Falls back to sharing just the WAV
//  if zipping fails for any reason.
//

import SwiftUI
import UIKit

nonisolated enum WavExport {

    /// Builds a temp `.zip` containing the WAV and (if provided) a PNG of the
    /// spectrogram overview, named after the recording. Returns the zip URL,
    /// or the plain WAV URL as a fallback if zipping fails. Safe to call off
    /// the main actor — pure file IO.
    static func makeShareItem(wavURL: URL, overview: UIImage?, baseName: String) -> URL {
        let fm = FileManager.default
        let safeName = baseName.replacingOccurrences(of: "/", with: "-")
        let stageDir = fm.temporaryDirectory.appendingPathComponent(safeName, isDirectory: true)
        try? fm.removeItem(at: stageDir)
        guard (try? fm.createDirectory(at: stageDir, withIntermediateDirectories: true)) != nil else {
            return wavURL
        }

        // Copy the WAV in under a clean, recording-named filename.
        let wavDest = stageDir.appendingPathComponent("\(safeName).wav")
        try? fm.copyItem(at: wavURL, to: wavDest)

        if let overview, let png = overview.pngData() {
            try? png.write(to: stageDir.appendingPathComponent("\(safeName)-spectrogram.png"))
        }

        var zipURL: URL?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: stageDir, options: [.forUploading], error: &coordError) { tempZip in
            // `tempZip` is a system-managed zipped copy that's deleted when
            // this closure returns — move it somewhere we control and hand
            // that back.
            let dest = fm.temporaryDirectory.appendingPathComponent("\(safeName).zip")
            try? fm.removeItem(at: dest)
            do {
                try fm.moveItem(at: tempZip, to: dest)
                zipURL = dest
            } catch {
                zipURL = nil
            }
        }
        return zipURL ?? wavURL
    }
}

/// Minimal UIActivityViewController wrapper — the app shares via ShareLink
/// elsewhere (DiagnosticsView), but the export item here is prepared
/// asynchronously on tap, so a presented sheet fits better than ShareLink's
/// prepare-upfront model.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
