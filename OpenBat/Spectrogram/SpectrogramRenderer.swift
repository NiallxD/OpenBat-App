//
//  SpectrogramRenderer.swift
//  OpenBat
//
//  MTKView delegate that drives two display paths:
//
//  LIVE PATH  — a small Metal ring texture (~5 MB) fed by incremental column
//               uploads. The display head glides forward with the audio clock
//               for stutter-free scrolling.
//
//  SCROLL PATH — when the user drags, liveHistory is snapshotted (O(1) COW).
//               New audio keeps writing to liveHistory while the user browses
//               the frozen snapshot via a linear seek texture (~4 MB). Tapping
//               "Return to live" discards the snapshot and snaps the display
//               head back to the live edge.
//
//  GPU memory:  ring texture + seek texture ≈ 9 MB total.
//  CPU memory:  liveHistory ≈ 44 MB (120 s at UInt8); snapshotHistory another
//               ≈ 44 MB while held (COW, materialises on first post-snapshot
//               append to the live buffer).
//

import MetalKit
import QuartzCore

final class SpectrogramRenderer: NSObject, MTKViewDelegate {

    let device: MTLDevice

    /// Expected new columns per second (sampleRate / hopSize).
    var columnsPerSecond: Double = 750

    /// Width of the x-axis time window shown on screen, in seconds.
    var timeWindowSeconds: Double = 0.5

    /// Visible frequency band as fractions of Nyquist.
    var bandLow: Float = 0
    var bandHigh: Float = 1

    // MARK: User scroll state

    var isScrolling: Bool = false {
        didSet {
            if isScrolling && !oldValue {
                // Drag started: freeze a snapshot; live buffer keeps recording.
                snapshotHistory = liveHistory.snapshot()
                lastSeekOffset = -1
                lastSeekVisibleColumns = 0
            } else if !isScrolling && oldValue {
                // Returned to live: discard snapshot and snap to the live edge.
                snapshotHistory = nil
                displayHead = totalColumns
                smoothedTotal = totalColumns
                lastFrameTime = 0
            }
        }
    }

    /// Columns behind the live edge the user has scrolled (0 = at live edge).
    var scrollColumnOffset: Double = 0

    /// Pulse detector fed once per drained column. Set from updateUIView.
    var pulseDetector: PulseDetector?

    // MARK: Private Metal state

    private let processor: SpectrogramProcessor
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    // Ring texture: live path, incremental uploads only.
    private let ringTexture: MTLTexture
    private let ringTextureWidth: Int

    // Seek texture: scroll path, reloaded from snapshot when position changes.
    private let seekTexture: MTLTexture
    private let maxVisibleColumns: Int
    private let height: Int

    private var visibleColumns: Int {
        max(10, min(Int(timeWindowSeconds * columnsPerSecond), maxVisibleColumns))
    }
    private var writeIndex: UInt32 = 0

    // MARK: CPU history

    private let liveHistory: HistoryBuffer
    private var snapshotHistory: HistoryBuffer?
    private var lastSeekOffset: Int = -1
    private var lastSeekVisibleColumns: Int = 0

    // MARK: Live display head

    private var totalColumns: Double = 0
    private var smoothedTotal: Double = 0
    private var displayHead: Double = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var smoothedDt: CFTimeInterval = 0
    private let latencySeconds = 0.03

    // MARK: Init

    init?(processor: SpectrogramProcessor,
          maxVisibleColumns: Int = 2048,
          historySeconds: Double = 120,
          guardColumns: Int = 512) {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue(),
            let library = device.makeDefaultLibrary(),
            let vertexFn = library.makeFunction(name: "spectro_vertex"),
            let fragmentFn = library.makeFunction(name: "spectro_fragment")
        else { return nil }

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFn
        pipelineDesc.fragmentFunction = fragmentFn
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pipelineDesc) else { return nil }

        // Ring texture: small, just enough for the live view + write guard.
        let ringWidth = maxVisibleColumns + guardColumns
        let ringDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: ringWidth, height: processor.binCount, mipmapped: false)
        ringDesc.usage = [.shaderRead]
        ringDesc.storageMode = .shared
        guard let ringTexture = device.makeTexture(descriptor: ringDesc) else { return nil }

        // Seek texture: linear layout (no ring wrapping) for snapshot display.
        let seekDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: maxVisibleColumns, height: processor.binCount, mipmapped: false)
        seekDesc.usage = [.shaderRead]
        seekDesc.storageMode = .shared
        guard let seekTexture = device.makeTexture(descriptor: seekDesc) else { return nil }

        self.device = device
        self.processor = processor
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.ringTexture = ringTexture
        self.ringTextureWidth = ringWidth
        self.seekTexture = seekTexture
        self.maxVisibleColumns = maxVisibleColumns
        self.height = processor.binCount
        // 750 cols/s = 384 kHz sample rate / 512 hop (the Griff mic's known rate).
        self.liveHistory = HistoryBuffer(capacity: Int(historySeconds * 750), binCount: processor.binCount)

        super.init()

        clearTexture(ringTexture, width: ringWidth)
        clearTexture(seekTexture, width: maxVisibleColumns)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // Drain new FFT columns → ring texture (live path) + liveHistory (both paths).
        // In triggered display mode, only columns where a pulse is active (or within
        // the hold-off window) are uploaded to the ring — silent gaps are skipped so
        // the scrolling spectrogram shows back-to-back pulses, Wildlife Acoustics style.
        // isInPulse reflects the PREVIOUS column's state (updated at the end of feed())
        // so checking it before feed() gives a 1-column (~1 ms) lag — negligible.
        for column in processor.drain() {
            let triggered = pulseDetector?.triggeredDisplayMode ?? false
            let inPulse   = pulseDetector?.isInPulse ?? true
            if !triggered || inPulse {
                uploadToRing(column.magnitudes)
                liveHistory.append(column.magnitudes)
            }
            // Per-column peak — NOT processor.peakLevel, which only holds the last
            // column of the batch and would scramble pulse position.
            pulseDetector?.feed(
                peakLevel: column.peakLevel,
                peakFrequency: processor.frequency(forBin: column.peakBin, level: column.peakLevel),
                history: liveHistory,
                columnsPerSecond: columnsPerSecond,
                sampleRate: processor.sampleRate,
                dbRange: Double(processor.maxDB - processor.minDB)
            )
        }

        // Refresh the seek texture when scroll position or window size changes.
        if isScrolling {
            let offset = Int(scrollColumnOffset)
            let vc = visibleColumns
            if offset != lastSeekOffset || vc != lastSeekVisibleColumns {
                uploadSeekSlice(offset: offset, count: vc)
                lastSeekOffset = offset
                lastSeekVisibleColumns = vc
            }
        }

        advanceDisplayHead()

        guard
            let passDescriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { return }

        let vc = visibleColumns
        let renderTexture: MTLTexture
        var rightEdge, windowLen, texWidth: Float

        if isScrolling {
            // Seek texture is linear: tell the shader rightEdge = vc so it
            // samples [0, vc/maxVisibleColumns] of UV — exactly what we uploaded.
            renderTexture = seekTexture
            rightEdge = Float(vc)
            windowLen  = Float(vc)
            texWidth   = Float(maxVisibleColumns)
        } else {
            // Ring texture: fractional display head drives smooth scrolling.
            renderTexture = ringTexture
            rightEdge = Float(displayHead.truncatingRemainder(dividingBy: Double(ringTextureWidth)))
            if rightEdge < 0 { rightEdge += Float(ringTextureWidth) }
            windowLen = Float(vc)
            texWidth  = Float(ringTextureWidth)
        }

        var low  = bandLow
        var high = bandHigh
        // Same noise-floor setting as the captured pulse view, applied live in the shader.
        var floor = pulseDetector?.pulseNoiseFloor ?? 0

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(renderTexture, index: 0)
        encoder.setFragmentBytes(&rightEdge, length: MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&windowLen,  length: MemoryLayout<Float>.size, index: 1)
        encoder.setFragmentBytes(&texWidth,   length: MemoryLayout<Float>.size, index: 2)
        encoder.setFragmentBytes(&low,        length: MemoryLayout<Float>.size, index: 3)
        encoder.setFragmentBytes(&high,       length: MemoryLayout<Float>.size, index: 4)
        encoder.setFragmentBytes(&floor,      length: MemoryLayout<Float>.size, index: 5)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: Texture uploads

    private func clearTexture(_ texture: MTLTexture, width: Int) {
        let zeros = [Float](repeating: 0, count: width * height)
        zeros.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: width * MemoryLayout<Float>.stride
            )
        }
    }

    private func uploadToRing(_ column: [Float]) {
        guard column.count == height else { return }
        column.withUnsafeBytes { raw in
            ringTexture.replace(
                region: MTLRegionMake2D(Int(writeIndex), 0, 1, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: MemoryLayout<Float>.stride
            )
        }
        writeIndex = (writeIndex + 1) % UInt32(ringTextureWidth)
        totalColumns += 1
    }

    /// Reads a slice from the snapshot and uploads it to the seek texture in a
    /// single replace() call (row-major layout: result[bin * count + col]).
    private func uploadSeekSlice(offset: Int, count: Int) {
        guard let snap = snapshotHistory, count > 0 else { return }
        let floats = snap.rowMajorSlice(offset: offset, count: count)
        floats.withUnsafeBytes { raw in
            seekTexture.replace(
                region: MTLRegionMake2D(0, 0, count, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: count * MemoryLayout<Float>.stride
            )
        }
    }

    // MARK: Display head (live path only)

    private func advanceDisplayHead() {
        guard !isScrolling else { return }

        let now = CACurrentMediaTime()
        if lastFrameTime == 0 {
            lastFrameTime = now
            displayHead = totalColumns
            smoothedTotal = totalColumns
            return
        }

        let rawDt = min(now - lastFrameTime, 0.1)
        lastFrameTime = now
        smoothedDt = smoothedDt == 0 ? rawDt : smoothedDt + (rawDt - smoothedDt) * 0.1
        smoothedTotal += (totalColumns - smoothedTotal) * 0.1

        displayHead += columnsPerSecond * smoothedDt
        let latencyColumns = max(columnsPerSecond * latencySeconds, 4)
        let target = smoothedTotal - latencyColumns
        displayHead += (target - displayHead) * 0.05

        displayHead = min(displayHead, totalColumns)
        displayHead = max(displayHead, totalColumns - Double(ringTextureWidth - visibleColumns))
    }
}
