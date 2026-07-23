//
//  CallAnnotationOverlay.swift
//  OpenBat
//
//  Draws the labelled call landmarks (Hi f, Peak, Fc, Lo f — see
//  CallAnalysis.Result.points) over the spectrogram when a selection has been
//  measured. Each landmark is an audio position (display-domain sample) plus a
//  frequency, mapped to screen coordinates through the current viewport — the
//  same maths WavAxisOverlay / the playhead use — so the markers track pan and
//  zoom. Purely visual (`allowsHitTesting(false)`), sitting above the
//  spectrogram but below the gesture layer.
//

import SwiftUI

/// One placed landmark, in the display (virtual, if hide-silence is on) sample
/// domain — WavPlayerView builds these from a CallAnalysis result.
struct CallAnnotation: Identifiable {
    let id = UUID()
    let label: String
    let sample: Int
    let freqHz: Double
}

struct CallAnnotationOverlay: View {
    let annotations: [CallAnnotation]
    let viewport: WavViewport
    let sampleRate: Double
    let logFrequency: Bool
    let geoSize: CGSize

    /// Per-label colour + which way to nudge the text off its marker, roughly
    /// matching where each landmark sits on a typical downward FM sweep so the
    /// labels fall clear of the call rather than on top of it.
    private static func style(_ label: String) -> (color: Color, dx: CGFloat, dy: CGFloat) {
        switch label {
        case "Hi f": return (.orange, -18, -10)   // call start, top-left: label left/up
        case "Peak": return (.yellow, 0, -14)     // loudest: label up
        case "Fc":   return (Color(red: 1, green: 0.6, blue: 0.2), 16, 10)  // tail: label right/down
        case "Lo f": return (.green, 18, 12)      // call end, bottom-right: label right/down
        default:     return (.white, 0, -12)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(annotations) { a in
                if let p = screenPoint(a) {
                    let s = Self.style(a.label)
                    // Marker on the exact landmark.
                    Circle()
                        .strokeBorder(s.color, lineWidth: 1.5)
                        .frame(width: 7, height: 7)
                        .position(p)
                    // Label, nudged clear of the marker and clamped on-screen.
                    Text(a.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(s.color)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                        .position(labelPosition(p, style: s))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func screenPoint(_ a: CallAnnotation) -> CGPoint? {
        guard viewport.sampleSpan > 0, geoSize.width > 0, geoSize.height > 0 else { return nil }
        let xFrac = Double(a.sample - viewport.startSample) / Double(viewport.sampleSpan)
        let vFrac = LogFrequencyWarp.hzToVFrac(a.freqHz, lo: viewport.minFreqHz,
                                               hi: viewport.maxFreqHz, log: logFrequency)
        // Off the visible window (in time or frequency) — don't draw it.
        guard xFrac >= 0, xFrac <= 1, vFrac >= 0, vFrac <= 1 else { return nil }
        return CGPoint(x: CGFloat(xFrac) * geoSize.width, y: CGFloat(vFrac) * geoSize.height)
    }

    private func labelPosition(_ marker: CGPoint, style s: (color: Color, dx: CGFloat, dy: CGFloat)) -> CGPoint {
        CGPoint(x: min(max(marker.x + s.dx, 18), geoSize.width - 18),
                y: min(max(marker.y + s.dy, 8), geoSize.height - 8))
    }
}
