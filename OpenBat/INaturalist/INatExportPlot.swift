//
//  INatExportPlot.swift
//  OpenBat
//
//  The frame every exported spectrogram is drawn in: a log frequency axis down
//  the left, a time axis along the bottom, gridlines across the picture, and a
//  line underneath saying what the time axis means.
//
//  WHY REAL TICKS
//  --------------
//  The first version labelled three frequencies — top, middle, bottom — and the
//  start and end of the time span. That is enough to know roughly where you are
//  and not nearly enough to MEASURE anything, which is what an identifier is
//  doing with a bat call: reading a peak frequency off the picture, or the
//  duration of a pulse. Ticks on a 1-2-5 ladder give whole numbers to read
//  against, and the gridlines carry them across the picture so a call in the
//  middle can be measured without a ruler.
//
//  WHY THE TIME AXIS NEEDS A CAPTION
//  ---------------------------------
//  Two of the three pictures run on real time and one does not. The whole-pass
//  view has its silence cut out, so its axis measures *retained* audio: the
//  spacing is uniform (the packed columns are the same duration as the ones
//  they came from, they are simply not adjacent in the recording) but the jumps
//  are real, and a reader who assumes otherwise will read a gap between two
//  calls that never existed. Every plot therefore says which it is, on the
//  picture, where it cannot be separated from it.
//
//  FIXED GEOMETRY, NOT A GEOMETRYREADER
//  ------------------------------------
//  These are rendered offscreen by `ImageRenderer`, at a size nothing else
//  depends on, so the width and height are constants and every tick position is
//  arithmetic. A `GeometryReader` would be one more thing to get wrong in a view
//  nobody can see while it is being laid out.
//

import SwiftUI

struct INatExportPlot: View {

    let image: UIImage
    /// The band actually drawn, after any log-axis floor — see
    /// `INatImages.logWarped`.
    let band: ClosedRange<Double>
    /// The time the picture spans, in seconds, and where it starts. For the
    /// silence-removed view this is retained audio rather than a position in
    /// the recording, which is what `timebase` exists to say.
    let timeStart: Double
    let timeEnd: Double
    let timebase: Timebase
    /// The line above the plot: which part of the pass this is, or what the
    /// call is. Empty draws nothing.
    var title: String = ""
    /// Width over height of the picture itself. 16:9 for a slice of a pass;
    /// 3:2 for a single call, which needs the extra height because it is one
    /// shape being read rather than a sequence being counted.
    var aspect: CGFloat = 16.0 / 9.0

    enum Timebase {
        case realTime
        case silenceRemoved

        var caption: String {
            switch self {
            case .realTime: return "Real time"
            case .silenceRemoved: return "Silence removed — gaps between calls are cut"
            }
        }
    }

    // MARK: Geometry

    private static let plotWidth: CGFloat = 600
    private static let axisWidth: CGFloat = 42
    private var plotHeight: CGFloat { (Self.plotWidth / aspect).rounded() }
    private static let gap: CGFloat = 6

    private var duration: Double { max(timeEnd - timeStart, 0.000_001) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, Self.axisWidth + Self.gap)
            }

            HStack(spacing: Self.gap) {
                frequencyAxis
                plot
            }

            HStack(spacing: Self.gap) {
                label("kHz").frame(width: Self.axisWidth, alignment: .trailing)
                timeAxis
            }

            Text(timebase.caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.leading, Self.axisWidth + Self.gap)
        }
        .padding(14)
        .frame(width: Self.plotWidth + Self.axisWidth + Self.gap + 28)
        .background(Color.black)
        // Rendered outside a window there is no trait collection to resolve
        // `.secondary` against, and unforced it comes out for a light
        // appearance on top of the black — see `INatImages.pulsePlot`.
        .environment(\.colorScheme, .dark)
    }

    // MARK: The picture and its gridlines

    private var plot: some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: Self.plotWidth, height: plotHeight)
            .overlay { gridlines }
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    /// Faint, and under nothing: a gridline heavy enough to read against is
    /// heavy enough to be mistaken for signal on a spectrogram, and a harmonic
    /// that turns out to be a gridline is worse than no gridline at all.
    private var gridlines: some View {
        Canvas { context, size in
            var path = Path()
            for tick in frequencyTicks {
                let y = LogFrequencyWarp.hzToVFrac(tick, lo: band.lowerBound,
                                                   hi: band.upperBound, log: true) * size.height
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            for tick in timeTicks {
                let x = (tick - timeStart) / duration * size.width
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(path, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
        }
    }

    // MARK: Axes

    private var frequencyAxis: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
            ForEach(frequencyTicks, id: \.self) { tick in
                let y = LogFrequencyWarp.hzToVFrac(tick, lo: band.lowerBound,
                                                   hi: band.upperBound, log: true) * plotHeight
                label(String(format: "%.0f", tick / 1000))
                    // Half the line height, so the number sits centred on its
                    // gridline rather than hanging below it.
                    .offset(y: y - 6)
            }
        }
        .frame(width: Self.axisWidth, height: plotHeight, alignment: .topTrailing)
    }

    private var timeAxis: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(timeTicks, id: \.self) { tick in
                let x = (tick - timeStart) / duration * Self.plotWidth
                label(timeLabel(tick))
                    // Centred on the tick, except at the very edges where that
                    // would hang the number off the picture.
                    .offset(x: min(max(x - 14, 0), Self.plotWidth - 28))
            }
        }
        .frame(width: Self.plotWidth, height: 12, alignment: .topLeading)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
    }

    // MARK: Where the ticks go

    /// Frequencies on a 1-2-5 ladder in kHz.
    ///
    /// Chosen against the SPAN rather than the top of the band, so a picture of
    /// a 20 kHz-wide call band gets 5 kHz ticks and a full-range one gets 50s,
    /// instead of the same number of ticks crushed into whatever height it has.
    private var frequencyTicks: [Double] {
        let span = band.upperBound - band.lowerBound
        let step = Self.niceStep(span, target: 7, ladder: [1_000, 2_000, 5_000, 10_000,
                                                           20_000, 25_000, 50_000, 100_000])
        var ticks: [Double] = []
        var hz = (band.lowerBound / step).rounded(.up) * step
        while hz <= band.upperBound {
            ticks.append(hz)
            hz += step
        }
        return ticks
    }

    /// Times on a 1-2-5 ladder, from a millisecond up. The bottom of the ladder
    /// matters: a call close-up spans a few tens of milliseconds, and without
    /// 1 ms and 2 ms steps it would be labelled at its two ends and nowhere in
    /// between — which is exactly the picture somebody is trying to measure a
    /// pulse duration off.
    private var timeTicks: [Double] {
        let step = Self.niceStep(duration, target: 8,
                                 ladder: [0.001, 0.002, 0.005, 0.01, 0.02, 0.05,
                                          0.1, 0.2, 0.5, 1, 2, 5, 10, 30, 60])
        var ticks: [Double] = []
        var t = (timeStart / step).rounded(.up) * step
        while t <= timeEnd + step * 0.001 {
            ticks.append(t)
            t += step
        }
        return ticks
    }

    /// The smallest step on `ladder` that keeps the tick count at or under
    /// `target`, or the largest step there is.
    private static func niceStep(_ span: Double, target: Int, ladder: [Double]) -> Double {
        ladder.first { span / $0 <= Double(target) } ?? ladder.last ?? span
    }

    /// Milliseconds for anything under half a second, seconds above it — and
    /// the unit only on the first label, because repeating it on eight ticks is
    /// eight times the ink for the same fact.
    private func timeLabel(_ tick: Double) -> String {
        let useMilliseconds = duration < 0.5
        let isFirst = tick == timeTicks.first
        if useMilliseconds {
            return String(format: isFirst ? "%.0f ms" : "%.0f", tick * 1000)
        }
        return String(format: isFirst ? "%.2g s" : "%.2g", tick)
    }
}
