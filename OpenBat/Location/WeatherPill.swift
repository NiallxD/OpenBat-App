//
//  WeatherPill.swift
//  OpenBat
//
//  A weather icon beside the sun clock, for the OpenBat Micro's environmental
//  sensor (see `SensorDataDecoder`). Tapping it opens a popover with the
//  readings.
//
//  Shown while a Micro is plugged in, or while its readings are in the capture
//  stream. The popover is live, updating every second. During a session the
//  readings come from the capture stream; idle, opening it opens the mic until
//  it closes (`AudioEngineController.startSensorReadings`). Niall chose that
//  on 2026-10-15 over sampling in the background.
//
//  **The icon is drawn only when there's something to open.** ContentView puts
//  this `ToolbarItem` inside its `if`, outside the item rather than inside its
//  content, because a toolbar item whose content resolves to nothing is never
//  hosted (see `SunWindowPill`'s history). So this view always draws its glyph
//  and never has to decide whether to show itself.
//
//  **Only the popover reads `sensorReading`.** It changes about once a second
//  while capturing. Reading it here in the pill's body would redraw the toolbar
//  every second. The popover is the only place the numbers are shown, so it's
//  the only place that needs to be invalidated.
//
//  Same visual language as the sun clock: bare content in the bar's own glass,
//  an orange glyph, no background of its own.
//

import SwiftUI

struct WeatherPill: View {
    let audio: AudioEngineController

    @State private var showReadings = false

    var body: some View {
        Button { showReadings = true } label: {
            Image(systemName: "cloud.sun.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.batAccent)
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Weather")
        .accessibilityHint("Shows the readings from your detector's weather sensor")
        .popover(isPresented: $showReadings) {
            WeatherReadingsPopover(audio: audio)
                .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - Popover

/// Temperature, humidity and pressure from the detector's sensor.
///
/// Live, updating each second: it reads `audio.sensorReading`, which the
/// controller updates as each new reading arrives, from the capture stream
/// during a session or from an idle read held open while this is showing.
/// Until the first idle reading lands it shows the last one kept, with the
/// time it was taken.
private struct WeatherReadingsPopover: View {
    let audio: AudioEngineController

    private static let temperature: MeasurementFormatter = {
        let f = MeasurementFormatter()
        f.numberFormatter.maximumFractionDigits = 1
        f.numberFormatter.minimumFractionDigits = 1
        return f
    }()

    /// Held in hPa wherever the phone is: it's what bat survey forms and
    /// weather records use, and converting to inHg would add digits the
    /// sensor can't back up.
    private static let pressure: MeasurementFormatter = {
        let f = MeasurementFormatter()
        f.unitOptions = .providedUnit
        f.numberFormatter.maximumFractionDigits = 1
        f.numberFormatter.minimumFractionDigits = 1
        return f
    }()

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Weather")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .center)

            if let reading = audio.sensorReading {
                VStack(spacing: 8) {
                    row("thermometer.medium", "Temperature",
                        Self.temperature.string(from: Measurement(value: reading.temperatureC, unit: UnitTemperature.celsius)))
                    // A BMP280 has no humidity sensor, so leave the row out
                    // rather than show an empty value.
                    if let humidity = reading.humidityPercent {
                        row("humidity.fill", "Humidity", "\(Int(humidity.rounded()))%")
                    }
                    row("gauge.medium", "Pressure",
                        Self.pressure.string(from: Measurement(value: reading.pressureHPa, unit: UnitPressure.hectopascals)))
                }
            }

            status
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        // Idle: hold the mic open and take readings while this is showing.
        // During a session the stream already carries them, and this does
        // nothing.
        .onAppear { audio.startSensorReadings() }
        .onDisappear { audio.stopSensorReadings() }
    }

    @ViewBuilder
    private var status: some View {
        if audio.sensorConnected {
            Text("Live from the sensor on your OpenBat detector, updated every second.")
        } else {
            switch audio.sensorReadState {
            case .reading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading from your detector…")
                }
            case .noSensor:
                Text("Your detector's weather sensor isn't answering. Check its wiring.")
            case .failed:
                Text("Couldn't get a reading from your detector.")
            case .idle:
                if audio.isSensorReadingLive {
                    Text("Live from the sensor on your OpenBat detector, updated every second.")
                } else if let time = audio.sensorReadingTime {
                    Text("Taken at \(Self.clock.string(from: time)) by the sensor on your OpenBat detector.")
                } else {
                    Text("From the sensor on your OpenBat detector.")
                }
            }
        }
    }

    private func row(_ icon: String, _ name: String, _ value: String) -> some View {
        HStack {
            Label {
                Text(name).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: icon).foregroundStyle(Color.batAccent)
            }
            .font(.callout)
            Spacer()
            Text(value)
                .font(.body.weight(.semibold).monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }
}
