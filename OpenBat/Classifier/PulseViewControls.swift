//
//  PulseViewControls.swift
//  OpenBat
//
//  Popover for how the captured pulse is displayed: the fixed zoom-window span
//  and the noise floor. Presented from the "Pulse view" panel header — the same
//  pattern as the spectrogram's frequency-band popover. (Detection settings live
//  separately in PulseSettingsView; this is purely display.)
//

import SwiftUI

struct PulseViewControls: View {
    @Bindable var detector: PulseDetector

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pulse view")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Zoom window").font(.subheadline)
                    Spacer()
                    Text(String(format: "%.0f ms", detector.displayWindowMs))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $detector.displayWindowMs, in: 20...200, step: 10)
                Text("Fixed time span of the captured pulse. The onset stays locked at 10% from the left, so every capture is at the same scale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Noise floor").font(.subheadline)
                    Spacer()
                    Text(String(format: "%.2f", detector.pulseNoiseFloor))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $detector.pulseNoiseFloor, in: 0...0.9, step: 0.05)
                Text("Hides energy below this brightness and stretches the rest to full contrast. Applies to both the pulse view and the live spectrogram.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
    }
}
