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
    /// Independent of the spectrogram's own log toggle (`display.spectrogramLogFrequency`)
    /// — see PulseZoomView's row-warp for how this is applied to the captured image.
    @AppStorage("display.pulseLogFrequency") private var pulseLogFrequency = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pulse view")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Zoom window").font(.caption)
                    Spacer()
                    Text(String(format: "%.0f ms", detector.displayWindowMs))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $detector.displayWindowMs, in: 6...40, step: 2)
                    .controlSize(.small)
                Text("Time span per capture; onset locked at 25% from the left.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Noise floor").font(.caption)
                    Spacer()
                    Text(String(format: "%.2f", detector.pulseNoiseFloor))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $detector.pulseNoiseFloor, in: 0...0.9, step: 0.05)
                    .controlSize(.small)
                Text("Hides energy below this brightness.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Log frequency scale", isOn: $pulseLogFrequency)
        }
        .padding(12)
        .frame(width: 270)
        .presentationCompactAdaptation(.popover)
    }
}
