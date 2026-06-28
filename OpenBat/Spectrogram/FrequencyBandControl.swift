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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Frequency range")
                    .font(.headline)
                Spacer()
                Button("Reset") {
                    low = 0
                    high = 1
                }
                .font(.caption)
                .disabled(low == 0 && high == 1)
            }

            RangeSlider(low: $low, high: $high)

            HStack {
                cutoffLabel("High-pass", low)
                Spacer()
                cutoffLabel("Low-pass", high)
            }

            Divider()

            HStack {
                Text("Time window")
                    .font(.headline)
                Spacer()
                Button("Reset") { timeWindowSeconds = 0.5 }
                    .font(.caption)
                    .disabled(timeWindowSeconds == 0.5)
            }

            Slider(value: $timeWindowSeconds, in: 0.1...2.0)

            HStack {
                Text("Fast")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f ms", timeWindowSeconds * 1000))
                    .font(.callout.monospacedDigit())
                Spacer()
                Text("Slow")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
    }

    private func cutoffLabel(_ name: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(String(format: "%.1f kHz", fraction * maxFrequency / 1000))
                .font(.callout.monospacedDigit())
        }
    }
}
