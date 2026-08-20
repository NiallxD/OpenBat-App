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
//  CPU memory:  liveHistory ≈ 92 MB (60 s × 1500 cols/s × 1024 bins at UInt8);
//               snapshotHistory another ≈ 92 MB while held (COW, materialises on the
//               first post-snapshot append to the live buffer). History was 120 s
//               (≈ 184 MB resident, ≈ 368 MB peak while scrolling) — halved to 60 s to
//               cut the jetsam risk on base-model devices running CoreML alongside it.
//

import MetalKit
import QuartzCore

final class SpectrogramRenderer: NSObject, MTKViewDelegate {

    let device: MTLDevice

    /// Expected new columns per second (sampleRate / hopSize). Placeholder until
    /// SpectrogramView's updateUIView sets the real value from processor.hopSize.
    var columnsPerSecond: Double = 1500

    /// Width of the x-axis time window shown on screen, in seconds.
    var timeWindowSeconds: Double = 0.75

    /// Visible frequency band as fractions of Nyquist.
    var bandLow: Float = 0
    var bandHigh: Float = 1

    /// Display the frequency axis log-scaled within the visible band instead of
    /// linear. Independent of the pulse view's own toggle — set from Settings.
    var logFrequency: Bool = false

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

    /// Explicit palette override, independent of `pulseDetector.displayPalette` —
    /// for callers with no live PulseDetector (e.g. PlaybackView, which renders a
    /// file's spectrogram rather than the live detector's). Takes precedence over
    /// `pulseDetector` when set; falls back to inferno if neither is set.
    var palette: Palette?

    // MARK: Private Metal state

    private let processor: SpectrogramProcessor
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    // Ring texture: live path, incremental uploads only.
    private let ringTexture: MTLTexture
    private let ringTextureWidth: Int
    // Pre-allocated staging buffer for batched ring uploads; grown as needed.
    private var uploadScratch: [Float] = []

    // Seek texture: scroll path, reloaded from snapshot when position changes.
    // Double-buffered: `.replace()` on a `.shared`-storage texture is a synchronous
    // CPU memcpy with no implicit fence against an outstanding GPU read of the SAME
    // texture object. The live ring path gets away with unbuffered writes because
    // each frame only overwrites a small forward region the GPU isn't currently
    // sampling; the seek path re-uploads the ENTIRE visible window on every scrub
    // step, right before that same texture is sampled in the same draw — a real
    // write/read race that showed up as torn "stripy noise" while scrubbing.
    // Alternating between two textures means a fresh CPU write never lands on the
    // texture the GPU may still be reading from the previous frame.
    private let seekTextures: [MTLTexture]
    private var seekWriteIndex = 0
    private var seekReadIndex = 0
    private var currentSeekTexture: MTLTexture { seekTextures[seekReadIndex] }
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
    private var previousTriggeredMode: Bool = false

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
          historySeconds: Double = 60,
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
        // Two, for double-buffering — see the `seekTextures` doc comment.
        let seekDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: maxVisibleColumns, height: processor.binCount, mipmapped: false)
        seekDesc.usage = [.shaderRead]
        seekDesc.storageMode = .shared
        guard let seekTextureA = device.makeTexture(descriptor: seekDesc),
              let seekTextureB = device.makeTexture(descriptor: seekDesc)
        else { return nil }

        self.device = device
        self.processor = processor
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.ringTexture = ringTexture
        self.ringTextureWidth = ringWidth
        self.seekTextures = [seekTextureA, seekTextureB]
        self.maxVisibleColumns = maxVisibleColumns
        self.height = processor.binCount
        // 1500 cols/s = 384 kHz sample rate / 256 hop (the Griff mic's known rate).
        self.liveHistory = HistoryBuffer(capacity: Int(historySeconds * 1500), binCount: processor.binCount)

        super.init()

        clearTexture(ringTexture, width: ringWidth)
        for tex in seekTextures { clearTexture(tex, width: maxVisibleColumns) }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // When triggered display mode is first turned on, wipe liveHistory so that
        // scroll-back doesn't surface pre-trigger background noise. The seek texture
        // will be rebuilt from the fresh history on the next scroll session.
        let triggered = pulseDetector?.triggeredDisplayMode ?? false
        if triggered && !previousTriggeredMode {
            liveHistory.clear()
            snapshotHistory = nil
            lastSeekOffset = -1
        }
        previousTriggeredMode = triggered

        // Drain new FFT columns → ring texture (live path) + liveHistory (both paths).
        // In triggered display mode, only columns where a pulse is active are uploaded
        // to the ring — silent gaps are skipped so the spectrogram shows back-to-back
        // pulses. isInPulse reflects the PREVIOUS column's
        // state (updated at the end of feed()) so checking it here gives a 1-column
        // (~1 ms) lag — negligible.
        //
        // Columns are collected into a batch so the ring texture is updated in 1–2
        // MTLTexture.replace() calls instead of one per column, reducing Metal API
        // overhead from ~12–25 calls per frame to at most 2.

        var batchMagnitudes: [[Float]] = []
        for column in processor.drain() {
            let inPulse   = pulseDetector?.isInPulse ?? true
            if !triggered || inPulse {
                batchMagnitudes.append(column.magnitudes)
                liveHistory.append(column.magnitudes)
            }
            // Per-column peak — NOT processor.peakLevel, which only holds the last
            // column of the batch and would scramble pulse position.
            pulseDetector?.feed(
                peakLevel: column.peakLevel,
                peakFrequency: processor.frequency(forBin: column.peakBin, level: column.peakLevel),
                columnEndSample: column.endSample,
                columnsPerSecond: columnsPerSecond,
                sampleRate: processor.sampleRate
            )
        }
        batchUploadToRing(batchMagnitudes)

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
        var isRing: Float

        if isScrolling {
            // Seek texture is linear. Map the view across TEXEL CENTRES of the
            // uploaded columns — the right edge at column vc-0.5 (centre of texel
            // vc-1) and the left at 0.5 (centre of texel 0), which is why the span
            // is vc-1 rather than vc.
            //
            // It used to say rightEdge = vc, putting uv.x = 1 exactly on the
            // boundary between texel vc-1 and texel vc. Texel vc is outside what
            // was uploaded, so with linear filtering the rightmost pixel column was
            // a 50/50 blend with whatever the other seek texture held from a
            // previous scrub — a one-pixel stripe of stale data while scrubbing.
            // (Only visible zoomed in: at a full window vc == maxVisibleColumns, so
            // uv.x = 1 hit u = 1 and clamp_to_edge saved it.)
            renderTexture = currentSeekTexture
            rightEdge = Float(vc) - 0.5
            windowLen  = Float(vc) - 1
            texWidth   = Float(maxVisibleColumns)
            isRing = 0
        } else {
            // Ring texture: fractional display head drives smooth scrolling.
            renderTexture = ringTexture
            rightEdge = Float(displayHead.truncatingRemainder(dividingBy: Double(ringTextureWidth)))
            if rightEdge < 0 { rightEdge += Float(ringTextureWidth) }
            windowLen = Float(vc)
            texWidth  = Float(ringTextureWidth)
            isRing = 1
        }

        var low  = bandLow
        var high = bandHigh
        // Independent noise-floor setting from the pulse view's, applied live in the shader.
        var floor = pulseDetector?.spectrogramNoiseFloor ?? 0
        var paletteIndex = Float((palette ?? pulseDetector?.displayPalette ?? .inferno).rawValue)
        var logFreq: Float = logFrequency ? 1 : 0

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(renderTexture, index: 0)
        encoder.setFragmentBytes(&rightEdge, length: MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&windowLen,  length: MemoryLayout<Float>.size, index: 1)
        encoder.setFragmentBytes(&texWidth,   length: MemoryLayout<Float>.size, index: 2)
        encoder.setFragmentBytes(&low,        length: MemoryLayout<Float>.size, index: 3)
        encoder.setFragmentBytes(&high,       length: MemoryLayout<Float>.size, index: 4)
        encoder.setFragmentBytes(&floor,      length: MemoryLayout<Float>.size, index: 5)
        encoder.setFragmentBytes(&isRing,     length: MemoryLayout<Float>.size, index: 6)
        encoder.setFragmentBytes(&paletteIndex, length: MemoryLayout<Float>.size, index: 7)
        encoder.setFragmentBytes(&logFreq,    length: MemoryLayout<Float>.size, index: 8)
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

    /// Upload multiple columns to the ring texture in at most two replace() calls
    /// (one before the ring wrap, one after), instead of one call per column.
    /// Staging is transposed so the GPU sees row-major layout (bin × column).
    private func batchUploadToRing(_ columns: [[Float]]) {
        guard !columns.isEmpty else { return }
        let count = columns.count
        var remaining = columns[...]
        var xStart = Int(writeIndex)

        while !remaining.isEmpty {
            let batchCount = min(remaining.count, ringTextureWidth - xStart)
            let batch = remaining.prefix(batchCount)

            // Grow scratch to hold this batch (bin-major: staging[bin * batchCount + col]).
            let needed = batchCount * height
            if uploadScratch.count < needed {
                uploadScratch = [Float](repeating: 0, count: needed)
            }

            // Transpose: col[bin] → staging[bin * batchCount + col] (stride-batchCount write).
            uploadScratch.withUnsafeMutableBufferPointer { staging in
                for (c, col) in batch.enumerated() {
                    col.withUnsafeBufferPointer { src in
                        var dst = staging.baseAddress! + c
                        for b in 0..<height {
                            dst.pointee = src[b]
                            dst += batchCount
                        }
                    }
                }
            }

            uploadScratch.withUnsafeBytes { raw in
                ringTexture.replace(
                    region: MTLRegionMake2D(xStart, 0, batchCount, height),
                    mipmapLevel: 0,
                    withBytes: raw.baseAddress!,
                    bytesPerRow: batchCount * MemoryLayout<Float>.stride
                )
            }

            xStart = (xStart + batchCount) % ringTextureWidth
            remaining = remaining.dropFirst(batchCount)
        }

        writeIndex = UInt32((Int(writeIndex) + count) % ringTextureWidth)
        totalColumns += Double(count)
    }

    /// Reads a slice from the snapshot and uploads it to the write-side seek
    /// texture in a single replace() call (row-major layout:
    /// result[bin * count + col]), then flips the read/write buffers so `draw(in:)`
    /// renders from the texture just written while the NEXT upload targets the
    /// other one — never the one still possibly in-flight on the GPU.
    private func uploadSeekSlice(offset: Int, count: Int) {
        guard let snap = snapshotHistory, count > 0 else { return }
        let floats = snap.rowMajorSlice(offset: offset, count: count)
        floats.withUnsafeBytes { raw in
            seekTextures[seekWriteIndex].replace(
                region: MTLRegionMake2D(0, 0, count, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: count * MemoryLayout<Float>.stride
            )
        }
        seekReadIndex = seekWriteIndex
        seekWriteIndex = 1 - seekWriteIndex
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
        // Floor at 0: before `ringTextureWidth` columns have been written the
        // (totalColumns − guard) lower bound is negative, which let displayHead settle
        // at a negative value during the first ~1.7 s. Clamping to 0 keeps it pinned to
        // real, written columns from the first frame.
        displayHead = max(displayHead, max(0, totalColumns - Double(ringTextureWidth - visibleColumns)))
    }
}
