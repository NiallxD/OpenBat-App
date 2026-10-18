//
//  SensorDataDecoderTests.swift
//  OpenBatTests
//
//  The OpenBat Mini's weather readings, hidden in the lowest bit of each
//  sample. The encoder below is a line-for-line copy of the firmware's
//  `hidden_data.c` (build_packet + hidden_data_add), so these tests break if
//  the app's reading of the format drifts from what the board sends.
//
//  Also checked by hand on 2026-10-14 against the 105-file UK sample with
//  packets embedded by the firmware repo's `tools/hidden_data.py`: every buffer
//  decoded, and the original recordings gave no false readings.
//

import AVFoundation
import Foundation
import Testing
@testable import OpenBat

struct SensorDataDecoderTests {

    // MARK: Encoder (mirrors hidden_data.c)

    private static func packet(temperature: Double?, humidity: Double = 0, pressureHPa: Double = 0,
                               hasHumidity: Bool = true, sequence: UInt8 = 0) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 17)
        p[0] = 0x4F; p[1] = 0x42; p[2] = 0x61; p[3] = 0x74   // "OBat"
        p[4] = 1
        if let temperature {
            p[5] = 1 | (hasHumidity ? 2 : 0)
            let t = UInt16(bitPattern: Int16((temperature * 100).rounded()))
            p[7] = UInt8(t & 0xFF); p[8] = UInt8(t >> 8)
            let h = UInt16((humidity * 100).rounded())
            p[9] = UInt8(h & 0xFF); p[10] = UInt8(h >> 8)
            let pa = UInt32((pressureHPa * 100).rounded())
            for i in 0..<4 { p[11 + i] = UInt8((pa >> (8 * i)) & 0xFF) }
        }
        p[6] = sequence
        let crc = SensorDataDecoder.crc16(p[0..<15])
        p[15] = UInt8(crc & 0xFF); p[16] = UInt8(crc >> 8)
        return p
    }

    /// A packet at the start of every 384-sample block, random bits after it,
    /// over a quiet random signal, converted to floats the way CoreAudio does.
    /// `blockLengths` lets a test model USB's 383/385-sample wobble.
    private static func stream(_ packet: [UInt8], blocks: Int, blockLength: Int = 384,
                               startOffset: Int = 0, seed: UInt64 = 1) -> [Float] {
        var rng = SplitMix(seed: seed)
        var samples: [Int16] = []
        for _ in 0..<(blocks * blockLength + startOffset) {
            samples.append(Int16(truncatingIfNeeded: Int(rng.next() % 2001) - 1000))
        }
        for block in 0..<blocks {
            let start = startOffset + block * blockLength
            for i in 0..<blockLength where start + i < samples.count {
                let bit: Int16
                if i < SensorDataDecoder.packetBits {
                    bit = Int16((packet[i / 8] >> (7 - i % 8)) & 1 ^ SensorDataDecoder.scramble[i])
                } else {
                    bit = Int16(rng.next() & 1)
                }
                samples[start + i] = (samples[start + i] & ~1) | bit
            }
        }
        return samples.map { Float($0) / 32768 }
    }

    private static func decode(_ samples: [Float]) -> SensorDataDecoder.Result {
        samples.withUnsafeBufferPointer { SensorDataDecoder.decode($0) }
    }

    // MARK: Decoder

    @Test func readsTheFirmwaresPacket() {
        let samples = Self.stream(Self.packet(temperature: -3.27, humidity: 87.5, pressureHPa: 1003.21, sequence: 42),
                                  blocks: 6, startOffset: 157)
        guard case .reading(let r) = Self.decode(samples) else {
            Issue.record("no reading decoded"); return
        }
        #expect(r.temperatureC == -3.27)
        #expect(r.humidityPercent == 87.5)
        #expect(abs(r.pressureHPa - 1003.21) < 0.001)
        #expect(r.sequence == 42)
    }

    @Test func survivesUSBBlockWobble() {
        for length in [383, 385] {
            let samples = Self.stream(Self.packet(temperature: 12.0, pressureHPa: 1000),
                                      blocks: 5, blockLength: length, startOffset: 300)
            #expect(Self.decode(samples) != .nothing, "block length \(length)")
        }
    }

    @Test func bmp280HasNoHumidity() {
        let samples = Self.stream(Self.packet(temperature: 20, humidity: 0, pressureHPa: 990, hasHumidity: false), blocks: 3)
        guard case .reading(let r) = Self.decode(samples) else {
            Issue.record("no reading decoded"); return
        }
        #expect(r.humidityPercent == nil)
    }

    @Test func packetWithoutSensorIsNoReading() {
        let samples = Self.stream(Self.packet(temperature: nil), blocks: 3)
        #expect(Self.decode(samples) == .noReading)
    }

    @Test func corruptedPacketIsRejected() {
        var packet = Self.packet(temperature: 20, pressureHPa: 1000)
        packet[8] ^= 0x01   // temperature changed, CRC not updated
        #expect(Self.decode(Self.stream(packet, blocks: 4)) == .nothing)
    }

    /// Ordinary audio, with real content in its lowest bit, must never read as
    /// weather. The sync word turns up by chance; the CRC is what rejects it.
    @Test func plainAudioReadsAsNothing() {
        var rng = SplitMix(seed: 7)
        for _ in 0..<50 {
            let samples = (0..<4096).map { _ in Float(Int(rng.next() % 65536) - 32768) / 32768 }
            #expect(Self.decode(samples) == .nothing)
        }
    }

    // MARK: Monitor

    private static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 384_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, s) in samples.enumerated() { buffer.floatChannelData![0][i] = s }
        return buffer
    }

    /// One second of 2048-frame buffers is 188 of them. The monitor decodes the
    /// first, then about one per second of audio after that.
    @Test func monitorForgetsAfterThreeMissedSeconds() {
        let monitor = SensorDataMonitor()
        let carrying = Self.buffer(Array(Self.stream(Self.packet(temperature: 15, pressureHPa: 1010), blocks: 6).prefix(2048)))
        let plain = Self.buffer([Float](repeating: 0, count: 2048))
        let perSecond = Int((384_000.0 / 2048).rounded(.up))

        monitor.feed(carrying)
        #expect(monitor.current?.temperatureC == 15)

        // Two missed seconds: still showing the last reading.
        for _ in 0..<(2 * perSecond) { monitor.feed(plain) }
        #expect(monitor.current != nil)
        // The third: gone.
        for _ in 0..<perSecond { monitor.feed(plain) }
        #expect(monitor.current == nil)

        monitor.feed(carrying)
        for _ in 0..<perSecond { monitor.feed(carrying) }
        #expect(monitor.current != nil)
        monitor.reset()
        #expect(monitor.current == nil)
    }
}

/// Deterministic random numbers, so a failure reproduces.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
