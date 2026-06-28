//
//  HistoryBuffer.swift
//  OpenBat
//
//  CPU-side ring buffer that stores FFT columns as UInt8 (0–255, normalised from
//  the 0–1 float magnitude). UInt8 gives 256 brightness levels — sufficient for
//  the inferno colormap — at 4× the memory efficiency of Float32.
//
//  At 750 cols/sec (384 kHz / hop 512) and 512 bins:
//    120 s → 90 000 cols × 512 bins = ~44 MB per buffer
//
//  Snapshot semantics: snapshot() is O(1) thanks to Swift Array copy-on-write.
//  The physical ~44 MB copy materialises only when the original buffer first
//  appends a new column after the snapshot is taken — a one-time ~4 ms stall.
//

import Foundation

final class HistoryBuffer {
    let capacity: Int   // columns
    let binCount: Int

    private(set) var data: [UInt8]      // flat ring: [col * binCount + bin]
    private(set) var writeHead: Int = 0
    private(set) var totalWritten: Int = 0

    init(capacity: Int, binCount: Int) {
        self.capacity = max(1, capacity)
        self.binCount = binCount
        self.data = [UInt8](repeating: 0, count: self.capacity * binCount)
    }

    // MARK: Write (main thread, drain path)

    func append(_ column: [Float]) {
        let base = writeHead * binCount
        for i in 0..<min(column.count, binCount) {
            data[base + i] = UInt8(min(max(column[i], 0), 1) * 255)
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
    func rowMajorSlice(offset: Int, count: Int) -> [Float] {
        let available = min(totalWritten, capacity)
        var result = [Float](repeating: 0, count: count * binCount)
        for col in 0..<count {
            // col 0 = leftmost (oldest visible); col count-1 = rightmost (newest at offset).
            let stepsBack = offset + (count - 1 - col)
            guard stepsBack < available else { continue }
            let ringIdx = ((writeHead - 1 - stepsBack) % capacity + capacity) % capacity
            let src = ringIdx * binCount
            for bin in 0..<binCount {
                result[bin * count + col] = Float(data[src + bin]) / 255.0
            }
        }
        return result
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
