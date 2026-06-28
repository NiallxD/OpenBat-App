//
//  ContentView.swift
//  OpenBat
//
//  Main screen. From bottom to top:
//    • Control bar   — play/stop, listen mode (fixed height)
//    • Live spectrogram — 50 % of the flexible area
//    • Pulse zoom    — 30 % — last detected pulse at 15 ms x-axis
//    • Stats strip   — 20 % — placeholder for future species / count data
//

import SwiftUI

struct ContentView: View {
    @State private var audio = AudioEngineController()
    @State private var processor = SpectrogramProcessor()
    @State private var pulseDetector = PulseDetector()
    @State private var showDiagnostics = false
    @State private var showPulseSettings = false
    @State private var showPulseView = false
    @State private var showBand = false
    @State private var timeWindowSeconds: Double = 0.5
    @State private var bandLow = 0.0
    @State private var bandHigh = 1.0
    @State private var dragBaseFrequency: Double?
    @State private var dragBaseHeight: CGFloat = 0
    @State private var peakHold: Double = 0          // 0–1 peak-hold position for the VU meter
    @State private var peakHoldAt: Date = .distantPast

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                GeometryReader { geo in
                    VStack(spacing: 8) {
                        statsStrip
                            .frame(height: geo.size.height * 0.15)

                        VStack(spacing: 4) {
                            panelHeader("Pulse View") { pulseViewButton }
                            pulseZoomPanel
                        }
                        .frame(height: geo.size.height * 0.34)

                        VStack(spacing: 4) {
                            panelHeader("Spectrogram") { bandButton }
                            SpectrogramView(processor: processor,
                                            maxFrequency: nyquist,
                                            bandLow: bandLow,
                                            bandHigh: bandHigh,
                                            timeWindowSeconds: timeWindowSeconds,
                                            pulseDetector: pulseDetector)
                                .overlay(alignment: .topTrailing) { tunedPillOverlay }
                        }
                        .frame(height: geo.size.height * 0.43)
                    }
                }

                controlBar
            }
            .padding()
            .navigationTitle("OpenBat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showPulseSettings = true } label: {
                        Image(systemName: "waveform.badge.magnifyingglass")
                    }
                    .accessibilityLabel("Pulse detection settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { pulseDetector.triggeredDisplayMode.toggle() } label: {
                        Image(systemName: "rectangle.compress.vertical")
                    }
                    .tint(pulseDetector.triggeredDisplayMode ? .green : .secondary)
                    .accessibilityLabel("Triggered display")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showDiagnostics = true } label: {
                        Image(systemName: "gauge.medium")
                    }
                    .accessibilityLabel("Diagnostics")
                }
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView(audio: audio)
            }
            .sheet(isPresented: $showPulseSettings) {
                PulseSettingsView(detector: pulseDetector)
            }
        }
        .onAppear {
            audio.bufferSink = { [processor] buffer in processor.process(buffer) }
            audio.autoTunePeakProvider = { [processor] in processor.peakFrequency }
            processor.sampleRate = audio.diagnostics.actualSampleRate
            applyBand()
        }
        .onChange(of: audio.diagnostics.actualSampleRate) { _, rate in
            processor.sampleRate = rate
        }
        .onChange(of: bandLow)  { _, _ in applyBand() }
        .onChange(of: bandHigh) { _, _ in applyBand() }
        .onChange(of: audio.isRunning) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
            if !running { peakHold = 0 }
        }
        .onChange(of: audio.diagnostics.currentLevelDB) { _, db in
            let n = meterNormalized(Double(db))
            if n >= peakHold {
                peakHold = n                       // jump up to a new peak and hold
                peakHoldAt = Date()
            } else if Date().timeIntervalSince(peakHoldAt) > 0.8 {
                peakHold = max(n, peakHold - 0.02) // then fall back gradually (~0.3/s at 15 Hz)
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: Panels

    private var statsStrip: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.ultraThinMaterial)
            .overlay {
                VStack(spacing: 6) {
                    HStack(spacing: 0) {
                        statCell("Fpeak",
                                 pulseDetector.capturedPeakFreq > 0
                                 ? String(format: "%.0f", pulseDetector.capturedPeakFreq / 1000) : "–",
                                 "kHz")
                        statDivider
                        statCell("Bndwth", bandwidthText, "kHz")
                        statDivider
                        statCell("Dur",
                                 pulseDetector.capturedDurationMs > 0
                                 ? String(format: "%.0f", pulseDetector.capturedDurationMs) : "–",
                                 "ms")
                        statDivider
                        statCell("Rate",
                                 pulseDetector.pulseRateHz > 0
                                 ? String(format: "%.1f", pulseDetector.pulseRateHz) : "–",
                                 "/s")
                        statDivider
                        statCell("Pulses", "\(pulseDetector.pulseCount)", "")
                        resetButton
                    }

                    amplitudeMeter

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }
    }

    private var resetButton: some View {
        Button {
            pulseDetector.resetStats()
            peakHold = 0
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(6)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reset stats")
        .padding(.leading, 6)
    }

    /// Meter floor in dBFS. Higher than the −80 capture floor because the ambient
    /// noise floor sits near −60, so the useful swing is −60…0.
    private let meterFloorDB: Double = -60

    /// Maps a dBFS value to 0…1 over the meter's [meterFloorDB, 0] range.
    private func meterNormalized(_ db: Double) -> Double {
        min(max((db - meterFloorDB) / (0 - meterFloorDB), 0), 1)
    }

    /// Retro segmented level meter with a falling peak-hold dot, driven by the
    /// input RMS level. Segments run green → yellow → red across the scale.
    private var amplitudeMeter: some View {
        let level = meterNormalized(Double(audio.diagnostics.currentLevelDB))
        let segments = 40
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("AMPLITUDE")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f dBFS", audio.diagnostics.currentLevelDB))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        ForEach(0..<segments, id: \.self) { i in
                            let frac = Double(i) / Double(segments - 1)
                            let lit = frac <= level
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(meterColor(frac).opacity(lit ? 1 : 0.12))
                        }
                    }
                    if peakHold > 0 {
                        Circle()
                            .fill(meterColor(peakHold))
                            .frame(width: 7, height: 7)
                            .shadow(color: meterColor(peakHold).opacity(0.8), radius: 2)
                            .position(x: max(3, min(geo.size.width - 3, geo.size.width * peakHold)),
                                      y: geo.size.height / 2)
                    }
                }
            }
            .frame(height: 16)

            HStack {
                meterScaleLabel("-60")
                Spacer()
                meterScaleLabel("-30")
                Spacer()
                meterScaleLabel("0 dB")
            }
        }
    }

    private func meterScaleLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 8).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// Smooth green (low) → yellow → red (high) across the meter.
    private func meterColor(_ frac: Double) -> Color {
        let f = min(max(frac, 0), 1)
        return Color(hue: 0.33 * (1 - f), saturation: 0.9, brightness: 0.95)
    }

    private var bandwidthText: String {
        let bw = pulseDetector.capturedFreqMax - pulseDetector.capturedFreqMin
        return bw > 0 ? String(format: "%.0f", bw / 1000) : "–"
    }

    private func statCell(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title3.monospacedDigit().weight(.semibold))
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .minimumScaleFactor(0.6)
        .lineLimit(1)
    }

    private var statDivider: some View {
        Divider().frame(height: 28)
    }

    private var pulseZoomPanel: some View {
        ZStack(alignment: .topLeading) {
            if let img = pulseDetector.lastPulseImage {
                // Stretch to fill exactly — spectrogram is a heatmap, not a photo.
                // No aspect ratio constraint; aspect ratio of the raw pixel image
                // (11×512) is meaningless for display.
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No pulse detected")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if pulseDetector.capturedFreqMax > 0 {
                pulseFrequencyAxis.padding(6)
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(pulseDetector.capturedDurationMs > 0
                         ? String(format: "%.0f ms", pulseDetector.capturedDurationMs)
                         : "–")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(6)
                }
            }
        }
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var pulseFrequencyAxis: some View {
        let lo = pulseDetector.capturedFreqMin
        let hi = pulseDetector.capturedFreqMax
        return VStack {
            axisLabel(hi)
            Spacer()
            axisLabel((lo + hi) / 2)
            Spacer()
            axisLabel(lo)
        }
    }

    private func axisLabel(_ hz: Double) -> some View {
        Text(hz >= 1000 ? String(format: "%.0f kHz", hz / 1000)
                        : String(format: "%.0f Hz", hz))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
            .shadow(radius: 1)
    }

    // MARK: Helpers

    private var nyquist: Double {
        let rate = audio.diagnostics.actualSampleRate
        return audio.isRunning && rate > 0 ? rate / 2 : 192_000
    }

    private func applyBand() {
        processor.peakMinFraction = max(bandLow, 0.01)
        processor.peakMaxFraction = bandHigh
        audio.heterodyne.setBand(low: bandLow, high: bandHigh)
        audio.timeExpansion.setBand(low: bandLow, high: bandHigh)
    }

    // MARK: Panel headers + per-panel setting buttons

    private func panelHeader(_ title: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 4)
    }

    private var pulseViewButton: some View {
        Button { showPulseView.toggle() } label: {
            Image(systemName: "slider.horizontal.3").font(.callout)
        }
        .accessibilityLabel("Pulse view settings")
        .popover(isPresented: $showPulseView) {
            PulseViewControls(detector: pulseDetector)
        }
    }

    private var bandButton: some View {
        Button { showBand.toggle() } label: {
            Image(systemName: "slider.horizontal.3").font(.callout)
        }
        .accessibilityLabel("Frequency range")
        .popover(isPresented: $showBand) {
            FrequencyBandControl(low: $bandLow, high: $bandHigh,
                                 maxFrequency: nyquist,
                                 timeWindowSeconds: $timeWindowSeconds)
        }
    }

    /// Heterodyne tuning pill, overlaid on the spectrogram only in that mode.
    @ViewBuilder private var tunedPillOverlay: some View {
        if audio.listenMode == .heterodyne {
            tunedPill.padding(8)
        }
    }

    private var tunedPill: some View {
        HStack(spacing: 5) {
            Image(systemName: audio.isAutoTune ? "a.circle.fill" : "hand.draw.fill")
                .font(.system(size: 11))
            Text(audio.tunedFrequency > 0
                 ? String(format: "%.1f kHz", audio.tunedFrequency / 1000)
                 : "tuning…")
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(audio.isAutoTune ? .green : .orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .gesture(tuneGesture)
    }

    private var tuneGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let dy = value.translation.height
                if dragBaseFrequency == nil {
                    guard abs(dy) > 6 else { return }
                    dragBaseFrequency = audio.tunedFrequency > 0 ? audio.tunedFrequency : nyquist * 0.25
                    dragBaseHeight = dy
                }
                guard let base = dragBaseFrequency else { return }
                let hzPerPoint = max(nyquist / 500, 50)
                audio.setManualTune(frequency: base - Double(dy - dragBaseHeight) * hzPerPoint)
            }
            .onEnded { _ in
                if dragBaseFrequency == nil { audio.enableAutoTune() }
                dragBaseFrequency = nil
            }
    }

    // MARK: Control bar

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button {
                if audio.isRunning { audio.stop() }
                else {
                    pulseDetector.resetStats()
                    Task { await audio.start() }
                }
            } label: {
                Image(systemName: audio.isRunning ? "stop.fill" : "play.fill")
                    .imageScale(.medium)
            }
            .buttonStyle(.borderedProminent)
            .tint(audio.isRunning ? .red : .accentColor)
            .accessibilityLabel(audio.isRunning ? "Stop" : "Start")

            listenModeMenu
            Spacer()
        }
        .controlSize(.regular)
        .padding(.vertical, 6)
    }

    private var listenModeMenu: some View {
        Menu {
            Picker("Listen", selection: listenModeBinding) {
                Label("Off",                   systemImage: "speaker.slash")
                    .tag(ListenMode.off)
                Label("Heterodyne",            systemImage: "antenna.radiowaves.left.and.right")
                    .tag(ListenMode.heterodyne)
                Label("RTE (time expansion)",  systemImage: "tortoise")
                    .tag(ListenMode.timeExpansion)
            }
        } label: {
            Image(systemName: listenIcon).imageScale(.medium)
        }
        .buttonStyle(.bordered)
        .tint(audio.isListening ? .green : .secondary)
        .accessibilityLabel("Listening mode")
    }

    private var listenIcon: String {
        switch audio.listenMode {
        case .off:           "headphones"
        case .heterodyne:    "antenna.radiowaves.left.and.right"
        case .timeExpansion: "tortoise"
        }
    }

    private var listenModeBinding: Binding<ListenMode> {
        Binding(get: { audio.listenMode }, set: { audio.setListenMode($0) })
    }
}

#Preview { ContentView() }
