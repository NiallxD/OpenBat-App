//
//  RangeSlider.swift
//  OpenBat
//
//  A two-thumb slider over 0...1. Used for the spectrogram frequency band: the
//  left thumb is the high-pass (lower bound), the right thumb the low-pass
//  (upper bound).
//

import SwiftUI

struct RangeSlider: View {
    @Binding var low: Double   // 0...1
    @Binding var high: Double  // 0...1
    var minGap: Double = 0.02

    private let thumbSize: CGFloat = 28
    private let space = "rangeslider"

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - thumbSize, 1)
            let lowX = CGFloat(low) * usable + thumbSize / 2
            let highX = CGFloat(high) * usable + thumbSize / 2
            let midY = geo.size.height / 2

            ZStack {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 4)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(highX - lowX, 0), height: 4)
                    .position(x: (lowX + highX) / 2, y: midY)

                thumb
                    .position(x: lowX, y: midY)
                    .gesture(drag(usable: usable) { p in
                        low = min(max(p, 0), high - minGap)
                    })

                thumb
                    .position(x: highX, y: midY)
                    .gesture(drag(usable: usable) { p in
                        high = max(min(p, 1), low + minGap)
                    })
            }
        }
        .coordinateSpace(.named(space))
        .frame(height: thumbSize)
    }

    private var thumb: some View {
        Circle()
            .fill(.white)
            .frame(width: thumbSize, height: thumbSize)
            .shadow(radius: 2)
    }

    private func drag(usable: CGFloat, update: @escaping (Double) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { value in
                update(Double((value.location.x - thumbSize / 2) / usable))
            }
    }
}
