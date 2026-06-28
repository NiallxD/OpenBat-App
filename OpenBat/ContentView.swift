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
    @State private var recorder = AudioRecorder()
    @State private var screenRecorder = ScreenRecorder()
    @State private var autoIDSettings = AutoIDSettings()
    @State private var classStore = ClassificationStore()
    @State private var showDiagnostics = false
    @State private var showPulseSettings = false
    @State private var showSettings = false
    @State private var showPulseView = false
    @State private var showBand = false
    @State private var timeWindowSeconds: Double = 0.5
    @State private var bandLow = 0.0
    @State private var bandHigh = 1.0
    @State private var dragBaseFrequency: Double?
    @State private var dragBaseHeight: CGFloat = 0
    @State private var peakHold: Double = 0          // 0–1 peak-hold position for the VU meter
    @State private var peakHoldAt: Date = .distantPast
    // .compact vertical size class == iPhone landscape → use the wide layout.
    @Environment(\.verticalSizeClass) private var vSizeClass
    // When on, arming the recorder also starts ReplayKit screen capture.
    @AppStorage("recording.screenCaptureEnabled") private var screenCaptureEnabled = true

    var body: some View {
        TabView {
            detectorTab
                .tabItem { Label("Detector", systemImage: "waveform") }
            SessionsView(store: classStore)
                .tabItem { Label("Sessions", systemImage: "square.stack.3d.up") }
        }
    }

    private var detectorTab: some View {
        NavigationStack {
            detectorLayout
            .navigationTitle("OpenBat")
            .navigationBarTitleDisplayMode(.inline)
            // Landscape hides the nav bar to reclaim vertical space; the menu moves
            // into the landscape controls panel so Settings/Diagnostics stay reachable.
            .toolbar(vSizeClass == .compact ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { optionsMenu }
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView(audio: audio, recorder: recorder)
            }
            .sheet(isPresented: $showPulseSettings) {
                PulseSettingsView(detector: pulseDetector)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: autoIDSettings)
            }
        }
        .onAppear {
            audio.bufferSink = { [processor, recorder] buffer in
                processor.process(buffer)
                recorder.append(buffer)
            }
            audio.autoTunePeakProvider = { [processor] in processor.peakFrequency }
            processor.sampleRate = audio.diagnostics.actualSampleRate
            pulseDetector.pcmProvider = { [processor] count, startSamplesBack in
                processor.pcmSnapshot(count: count, startSamplesBack: startSamplesBack)
            }
            pulseDetector.autoIDSettings = autoIDSettings
            pulseDetector.store = classStore
            applyBand()
        }
        .onChange(of: audio.diagnostics.actualSampleRate) { _, rate in
            processor.sampleRate = rate
        }
        .onChange(of: bandLow)  { _, _ in applyBand() }
        .onChange(of: bandHigh) { _, _ in applyBand() }
        .onChange(of: audio.isRunning) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
            if !running {
                peakHold = 0
                pulseDetector.finalizePass()   // close any pending pass so it's saved
                recorder.audioStopped()
                if recorder.isArmed { recorder.setArmed(false); screenRecorder.stop() }
            }
        }
        .onChange(of: pulseDetector.isInPulse) { _, active in
            recorder.setPulseActive(active)
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

    // MARK: Adaptive layout

    @ViewBuilder private var detectorLayout: some View {
        if vSizeClass == .compact {
            landscapeLayout
        } else {
            portraitLayout
        }
    }

    /// Settings / diagnostics menu — shown in the nav bar (portrait) and inside the
    /// landscape controls panel (where the nav bar is hidden).
    private var optionsMenu: some View {
        Menu {
            Button { showPulseSettings = true } label: {
                Label("Pulse Detection", systemImage: "waveform.badge.magnifyingglass")
            }
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Divider()
            Button { showDiagnostics = true } label: {
                Label("Diagnostics", systemImage: "gauge.medium")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Menu")
    }

    /// Portrait: stacked panels with a fixed stats slot and the control bar below.
    private var portraitLayout: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let spacing: CGFloat = 10
                let statsHeight: CGFloat = 112
                let flex = max(120, geo.size.height - statsHeight - spacing * 2)
                VStack(spacing: spacing) {
                    statsBlock(landscape: false).frame(height: statsHeight)
                    pulseBlock.frame(height: flex * 0.42)
                    spectrogramBlock.frame(height: flex * 0.58)
                }
            }
            controlBar
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }

    /// Landscape: spectrogram dominates the left column (stats above it); the right
    /// column carries the pulse view over a controls/ID panel. Extends into the
    /// horizontal safe-area margins (the wide notch insets) so the panels aren't
    /// squeezed into the centre — only a small edge gutter is kept.
    private var landscapeLayout: some View {
        GeometryReader { geo in
            let pad: CGFloat = 8
            let spacing: CGFloat = 8
            let w = geo.size.width  - pad * 2
            let h = geo.size.height - pad * 2
            HStack(spacing: spacing) {
                VStack(spacing: spacing) {
                    statsBlock(landscape: true).frame(height: (h - spacing) * 0.27)
                    spectrogramBlock.frame(height: (h - spacing) * 0.73)
                }
                .frame(maxWidth: .infinity)        // remaining width (~74%)

                VStack(spacing: spacing) {
                    pulseBlock.frame(height: (h - spacing) * 0.5)
                    landscapeControlsPanel.frame(height: (h - spacing) * 0.5)
                }
                .frame(width: w * 0.26)
            }
            .frame(width: w, height: h)
            .padding(pad)
        }
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    // MARK: Reusable panel blocks

    private func statsBlock(landscape: Bool) -> some View {
        VStack(spacing: 4) {
            panelHeader("Stats") { resetButton }
            if landscape { statsStripLandscape } else { statsStrip }
        }
    }

    private var pulseBlock: some View {
        VStack(spacing: 4) {
            panelHeader("Pulse View") { pulseViewButton }
            pulseZoomPanel.panelCard()
        }
    }

    private var spectrogramBlock: some View {
        VStack(spacing: 4) {
            panelHeader("Spectrogram") { bandButton }
            SpectrogramView(processor: processor,
                            maxFrequency: nyquist,
                            bandLow: bandLow,
                            bandHigh: bandHigh,
                            timeWindowSeconds: timeWindowSeconds,
                            pulseDetector: pulseDetector)
                .overlay(alignment: .topTrailing) { tunedPillOverlay }
                .panelCard()
        }
    }

    /// Fills the landscape bottom-right: the latest ID plus the transport controls.
    private var landscapeControlsPanel: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.ultraThinMaterial)
            .overlay {
                VStack(spacing: 10) {
                    speciesCell
                    Divider()
                    playStopButton
                    HStack(spacing: 10) {
                        listenModeMenu
                        triggeredDisplayButton
                        recordButton
                        optionsMenu
                            .controlIcon()
                            .buttonStyle(.bordered)
                            .tint(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .controlSize(.regular)
                .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Panels

    /// The horizontal row of stat readouts, shared by both orientations.
    private func statCellsRow(includeSpecies: Bool) -> some View {
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
            if includeSpecies {
                statDivider
                speciesCell
            }
        }
    }

    private var statsStrip: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.ultraThinMaterial)
            .overlay {
                VStack(spacing: 4) {
                    statCellsRow(includeSpecies: true)
                    amplitudeMeter
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Compact landscape stats: the readout cells on the left, amplitude meter on the
    /// right, all on one row so it fits the short landscape height. (Species ID is
    /// shown in the landscape controls panel instead.)
    private var statsStripLandscape: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.ultraThinMaterial)
            .overlay {
                HStack(spacing: 12) {
                    statCellsRow(includeSpecies: false)
                        .frame(maxWidth: .infinity)
                    Divider().frame(height: 30)
                    amplitudeMeter
                        .frame(width: 200)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
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
        return VStack(alignment: .leading, spacing: 3) {
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
            .frame(height: 13)

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

    private var speciesCell: some View {
        VStack(spacing: 2) {
            Text("SPECIES")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            if let pass = pulseDetector.lastPassResult {
                HStack(alignment: .center, spacing: 4) {
                    Text(pass.species)
                        .font(.system(size: 15, weight: .semibold))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(pulseDetector.lastPassPulseCount)p")
                        Text(String(format: "%.0f%%", pass.confidence * 100))
                    }
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("–")
                    .font(.title3.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity)
        .minimumScaleFactor(0.6)
        .lineLimit(1)
    }

    private var pulseZoomPanel: some View {
        ZStack(alignment: .topLeading) {
            if let img = pulseDetector.lastPulseImage {
                // Stretch to fill exactly — spectrogram is a heatmap, not a photo.
                // The image is now a high-resolution PCM render (~480 cols), so .high
                // interpolation looks crisp instead of the old blurry upscale.
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No pulse detected")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            pulseGrid

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
    }

    /// Faint analysis grid over the pulse capture. Vertical lines mark time
    /// (the brighter one at 10% is the locked pulse onset); horizontal lines mark
    /// frequency, aligned with the hi / mid / lo axis labels.
    private var pulseGrid: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Path { p in
                    for f in [0.25, 0.5, 0.75] as [CGFloat] {   // time divisions
                        p.move(to: CGPoint(x: w * f, y: 0)); p.addLine(to: CGPoint(x: w * f, y: h))
                    }
                    for f in [0.25, 0.5, 0.75] as [CGFloat] {   // frequency divisions
                        p.move(to: CGPoint(x: 0, y: h * f)); p.addLine(to: CGPoint(x: w, y: h * f))
                    }
                }
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)

                Path { p in                                      // onset marker @ 10%
                    p.move(to: CGPoint(x: w * 0.10, y: 0)); p.addLine(to: CGPoint(x: w * 0.10, y: h))
                }
                .stroke(Color.white.opacity(0.30), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
            }
        }
        .allowsHitTesting(false)
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
            playStopButton
            listenModeMenu
            triggeredDisplayButton
            recordButton
            Spacer()
        }
        .controlSize(.regular)
        .padding(.vertical, 6)
    }

    private var playStopButton: some View {
        Button {
            if audio.isRunning { audio.stop() }
            else {
                pulseDetector.resetStats()
                Task { await audio.start() }
            }
        } label: {
            Image(systemName: audio.isRunning ? "stop.fill" : "play.fill")
                .controlIcon()
        }
        .buttonStyle(.borderedProminent)
        .tint(audio.isRunning ? .red : .accentColor)
        .accessibilityLabel(audio.isRunning ? "Stop" : "Start")
    }

    private var recordButton: some View {
        Button { toggleRecording() } label: {
            Image(systemName: recorder.isWriting ? "record.circle.fill" : "record.circle")
                .controlIcon()
        }
        .buttonStyle(.bordered)
        .tint(recorder.isArmed ? .red : .secondary)
        .accessibilityLabel(recorder.isArmed ? "Stop recording" : "Record")
    }

    /// Record button arms the triggered WAV recorder and starts/stops the
    /// whole-session ReplayKit screen capture together.
    private func toggleRecording() {
        let willArm = !recorder.isArmed
        recorder.setArmed(willArm)
        if willArm {
            if screenCaptureEnabled { screenRecorder.start() }
        } else {
            screenRecorder.stop()
        }
    }

    private var triggeredDisplayButton: some View {
        Button { pulseDetector.triggeredDisplayMode.toggle() } label: {
            Image(systemName: "rectangle.compress.vertical").controlIcon()
        }
        .buttonStyle(.bordered)
        .tint(pulseDetector.triggeredDisplayMode ? .green : .secondary)
        .accessibilityLabel("Triggered display")
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
            Image(systemName: listenIcon).controlIcon()
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

private extension View {
    /// Transparent rounded card with a thin hairline border — used to tighten up
    /// the spectrogram and pulse-view panels without a heavy filled background.
    /// Fixed-size control-bar icon: keeps every button the same width and stops it
    /// resizing when the SF Symbol swaps (play↔stop, the listen-mode icons, etc.).
    func controlIcon() -> some View {
        font(.body)
            .frame(width: 24, height: 22)
    }

    func panelCard(cornerRadius: CGFloat = 10) -> some View {
        clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            )
    }
}

#Preview { ContentView() }
