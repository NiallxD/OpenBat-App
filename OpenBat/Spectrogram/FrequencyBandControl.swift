//
//  FrequencyBandControl.swift
//  OpenBat
//
//  Popover for the spectrogram frequency band: a range slider whose left thumb
//  sets the high-pass (lower bound) and right thumb the low-pass (upper bound).
//  Values are fractions of Nyquist; labels show the equivalent kHz.
//

import SwiftUI

struct FrequencyBandControl: View {
    @Binding var low: Double            // fraction of Nyquist, 0...1
    @Binding var high: Double           // fraction of Nyquist, 0...1
    var maxFrequency: Double            // Nyquist, Hz
    @Binding var timeWindowSeconds: Double
    @Binding var noiseFloor: Float
    @Binding var logFrequency: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Frequency range")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Reset") {
                    low = 0
                    high = 1
                }
                .font(.caption2)
                .disabled(low == 0 && high == 1)
            }

            RangeSlider(low: $low, high: $high)
                .controlSize(.small)

            HStack {
                cutoffLabel("High-pass", low)
                Spacer()
                cutoffLabel("Low-pass", high)
            }

            Toggle("Log frequency scale", isOn: $logFrequency)

            Divider()

            HStack {
                Text("Time window")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Reset") { timeWindowSeconds = 0.5 }
                    .font(.caption2)
                    .disabled(timeWindowSeconds == 0.5)
            }

            Slider(value: $timeWindowSeconds, in: 0.1...2.0)
                .controlSize(.small)

            HStack {
                Text("Fast")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f ms", timeWindowSeconds * 1000))
                    .font(.caption.monospacedDigit())
                Spacer()
                Text("Slow")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("Noise floor")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.2f", noiseFloor))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $noiseFloor, in: 0...0.9, step: 0.05)
                .controlSize(.small)
            Text("Hides energy below this brightness.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 270)
        .presentationCompactAdaptation(.popover)
    }

    private func cutoffLabel(_ name: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(String(format: "%.1f kHz", fraction * maxFrequency / 1000))
                .font(.caption.monospacedDigit())
        }
    }
}
