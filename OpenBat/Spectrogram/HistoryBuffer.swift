//
//  HistoryBuffer.swift
//  OpenBat
//
//  CPU-side ring buffer that stores FFT columns as UInt8 (0–255, normalised from
//  the 0–1 float magnitude). UInt8 gives 256 brightness levels — sufficient for
//  the inferno colormap — at 4× the memory efficiency of Float32.
//
//  At 1500 cols/sec (384 kHz / hop 256) and 1024 bins:
//    120 s → 180 000 cols × 1024 bins ≈ 176 MB per buffer
//
//  Snapshot semantics: snapshot() is O(1) thanks to Swift Array copy-on-write.
//  The physical ~44 MB copy materialises only when the original buffer first
//  appends a new column after the snapshot is taken — a one-time ~4 ms stall.
//

import Foundation
import Accelerate

final class HistoryBuffer {
    let capacity: Int   // columns
    let binCount: Int

    private(set) var data: [UInt8]      // flat ring: [col * binCount + bin]
    private(set) var writeHead: Int = 0
    private(set) var totalWritten: Int = 0

    // Reusable scratch for the float→UInt8 conversion in append() — keeps the hot
    // path (called once per drained column, ~750/sec) allocation-free.
    private var scratch: [Float]
    // Reusable result buffer for rowMajorSlice(), sized to the largest requested
    // slice so scroll-path reads don't allocate on the main thread. Returning it
    // directly is safe: the caller releases its reference before the next call, so
    // the in-place mutation never triggers a CoW copy (and if a caller ever did
    // retain it, CoW would kick in rather than corrupt it).
    private var resultScratch: [Float] = []

    init(capacity: Int, binCount: Int) {
        self.capacity = max(1, capacity)
        self.binCount = binCount
        self.data = [UInt8](repeating: 0, count: self.capacity * binCount)
        self.scratch = [Float](repeating: 0, count: binCount)
    }

    // MARK: Write (main thread, drain path)

    func append(_ column: [Float]) {
        let base = writeHead * binCount
        let n = min(column.count, binCount)
        // Vectorised clamp(0,1)·255 → UInt8 (replaces a per-bin scalar loop).
        var scale: Float = 255, lo: Float = 0, hi: Float = 255
        let len = vDSP_Length(n)
        column.withUnsafeBufferPointer { src in
            vDSP_vsmul(src.baseAddress!, 1, &scale, &scratch, 1, len)
        }
        vDSP_vclip(scratch, 1, &lo, &hi, &scratch, 1, len)
        data.withUnsafeMutableBufferPointer { dst in
            vDSP_vfixu8(scratch, 1, dst.baseAddress! + base, 1, len)
        }
        writeHead = (writeHead + 1) % capacity
        totalWritten += 1
    }

    // MARK: Read

    /// Returns `count` columns as a row-major Float array ready for a Metal
    /// texture upload (layout: `result[bin * count + col]`, matching Metal's
    /// expected layout when `bytesPerRow = count * sizeof(Float)`).
    ///
    /// - Parameters:
    ///   - offset: Columns behind the most recent (0 = ending at the most
    ///             recent column in the ring).
    ///   - count:  Width of the slice; columns beyond the available history
    ///             are left as zero.
    ///
    /// Writes each column's `binCount` UInt8 values directly into their final
    /// bin-major positions (`result[bin * count + col]`) with a single strided
    /// `vDSP_vfltu8` call per column (output stride `count`), instead of writing
    /// to a col-major staging buffer and then transposing it as a separate pass —
    /// no separate transpose step, so there's no M/N-ordering to get wrong (an
    /// earlier `vDSP_mtrans`-based version of this function had exactly that bug,
    /// and it's what caused the scrolled-back view's diagonal stripe corruption).
    func rowMajorSlice(offset: Int, count: Int) -> [Float] {
        let available = min(totalWritten, capacity)
        let totalLen = count * binCount

        if resultScratch.count != totalLen { resultScratch = [Float](repeating: 0, count: totalLen) }

        data.withUnsafeBufferPointer { src in
            resultScratch.withUnsafeMutableBufferPointer { dst in
                for col in 0..<count {
                    let stepsBack = offset + (count - 1 - col)
                    guard stepsBack < available else {
                        // Zero out so stale data from a previous call doesn't bleed
                        // through — same output stride as the real write below.
                        vDSP_vclr(dst.baseAddress! + col, count, vDSP_Length(binCount))
                        continue
                    }
                    let ringIdx = ((writeHead - 1 - stepsBack) % capacity + capacity) % capacity
                    vDSP_vfltu8(src.baseAddress! + ringIdx * binCount, 1,
                                dst.baseAddress! + col, count,
                                vDSP_Length(binCount))
                }
            }
        }

        // Scale 0–255 → 0–1 across the whole result in one pass.
        var scale: Float = 1.0 / 255.0
        vDSP_vsmul(resultScratch, 1, &scale, &resultScratch, 1, vDSP_Length(totalLen))
        return resultScratch
    }

    // MARK: Reset

    /// Discards all history. Sets totalWritten and writeHead to 0; existing `data`
    /// bytes are left untouched — rowMajorSlice() ignores them because available=0
    /// causes every column to be zeroed via the guard.
    func clear() {
        writeHead = 0
        totalWritten = 0
    }

    // MARK: Snapshot

    /// Returns an independent copy of this buffer. O(1) via Swift COW; the
    /// physical copy is deferred until the next append() on `self`.
    func snapshot() -> HistoryBuffer {
        let snap = HistoryBuffer(capacity: capacity, binCount: binCount)
        snap.data = data
        snap.writeHead = writeHead
        snap.totalWritten = totalWritten
        return snap
    }
}
