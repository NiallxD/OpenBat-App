//
//  SensorDataDecoder.swift
//  OpenBat
//
//  Reads the weather readings an OpenBat Mini hides in the lowest bit of its
//  audio samples.
//
//  Why it arrives this way: an iPhone can use a USB microphone but can't read
//  the board's USB serial port, and 384 kHz stereo doesn't fit on full-speed
//  USB, so there's no second channel either. The firmware puts its BME280
//  reading (temperature, humidity, pressure) into bit 0 of each 16-bit sample
//  instead. That changes the sound by at most 1 part in 32768, far below the
//  ADC's own noise. On 2026-10-14 the app's species verdicts came out 105/105
//  the same over the UK test sample with and without it.
//
//  The format is defined by the firmware repo, not here:
//  `Hardware/OpenBat Mini/docs/hidden-data-format.md`. Its reference
//  decoder is `tools/hidden_data.py`. In brief: a 17-byte packet,
//
//    0-3   "OBat"      4  version (1)    5  flags    6  sequence
//    7-8   temperature, int16, hundredths of °C
//    9-10  humidity, uint16, hundredths of % RH
//    11-14 pressure, uint32, pascals
//    15-16 CRC-16/CCITT-FALSE over bytes 0-14
//
//  sent most significant bit first, one bit per sample, XORed with a PN9
//  sequence. One copy starts every 1 ms block (384 samples). USB packets can
//  hold 383 or 385 samples, so the decoder searches for the sync word instead
//  of assuming where blocks start.
//
//  **Bit-exact input only.** The bits survive the trip as Float32 because
//  CoreAudio's int16 → float conversion is exact (s / 32768) and the capture
//  tap takes the hardware's own format in `.measurement` mode. Anything that
//  resamples or applies gain first destroys them, and then this decoder simply
//  finds nothing: the CRC rejects random bits. The same goes for the app's
//  saved WAVs at the moment, because `AudioRecorder.write` scales by 32767 and
//  truncates. So this decodes the live stream, not recordings.
//

import AVFoundation
import Foundation

/// One reading from the detector's environmental sensor.
nonisolated struct SensorReading: Equatable, Sendable {
    var temperatureC: Double
    /// `nil` on a BMP280, which looks like a BME280 but has no humidity sensor.
    var humidityPercent: Double?
    var pressureHPa: Double
    /// Counts up by one with each new reading on the board and wraps at 255.
    var sequence: UInt8
}

nonisolated enum SensorDataDecoder {

    static let packetBytes = 17
    static let packetBits = packetBytes * 8      // 136
    static let formatVersion: UInt8 = 1

    /// The PN9 scrambling sequence: a 9-bit shift register starting at 0x1FF.
    /// Restarts at every packet, so bit i of a packet is XORed with `scramble[i]`.
    static let scramble: [UInt8] = {
        var shift: UInt16 = 0x1FF
        return (0..<packetBits).map { _ in
            let out = UInt8(shift & 1)
            let new = (shift ^ (shift >> 4)) & 1
            shift = (shift >> 1) | (new << 8)
            return out
        }
    }()

    /// "OBat" as it appears on the wire: scrambled, first bit in the top bit, so
    /// it can be compared against a register that shifts each new bit in at the
    /// bottom.
    static let syncWord: UInt32 = {
        var word: UInt32 = 0
        for (i, byte) in "OBat".utf8.enumerated() {
            for b in 0..<8 {
                let bit = (UInt32(byte) >> (7 - b)) & 1
                word = (word << 1) | (bit ^ UInt32(scramble[i * 8 + b]))
            }
        }
        return word
    }()

    /// Fewest samples guaranteed to hold one whole packet wherever the block
    /// boundaries fall: a packet's worth, plus one block (at most 385 samples
    /// once USB has wobbled) so the next copy's start is always reached.
    static let minimumSamples = packetBits + 385

    /// The result of looking at one buffer.
    enum Result: Equatable {
        /// No valid packet: not an OpenBat Mini, or the bits didn't survive.
        case nothing
        /// A valid packet, but the board has no reading to give (no sensor
        /// found, or it hasn't finished its first measurement).
        case noReading
        case reading(SensorReading)
    }

    /// Decode the first valid packet in a capture buffer's first channel.
    static func decode(_ buffer: AVAudioPCMBuffer) -> Result {
        guard let channel = buffer.floatChannelData?[0] else { return .nothing }
        return decode(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// Decode the first valid packet in Float32 samples in [-1, 1].
    ///
    /// Stops at the first packet that passes the CRC, which is within the first
    /// ~520 samples of any buffer carrying them, so this costs almost nothing
    /// even at -Onone. A buffer with no packets is scanned to the end: about
    /// 2,000 iterations, once a second, from `SensorDataMonitor`.
    static func decode(_ samples: UnsafeBufferPointer<Float>) -> Result {
        let count = samples.count
        guard count >= packetBits else { return .nothing }
        var register: UInt32 = 0
        var i = 0
        while i < count {
            register = (register << 1) | UInt32(lowestBit(samples[i]))
            // `i` is the sync word's last bit, so the packet started 31 earlier.
            if i >= 31, register == syncWord {
                let start = i - 31
                if start + packetBits <= count,
                   let result = packet(in: samples, at: start) {
                    return result
                }
            }
            i += 1
        }
        return .nothing
    }

    /// Bit 0 of the int16 sample a float came from. The conversion in is exact,
    /// so `f × 32768` is a whole number. Rounding only guards against anything
    /// upstream that nudged it.
    @inline(__always)
    static func lowestBit(_ sample: Float) -> Int {
        Int((sample * 32768).rounded()) & 1
    }

    /// Unscramble and check the packet starting at `start`. `nil` if it fails
    /// the CRC or is a version this app doesn't know: the sync word alone
    /// turns up by chance in random bits about once every 4 billion samples,
    /// and a reading that isn't really there is worse than none.
    private static func packet(in samples: UnsafeBufferPointer<Float>, at start: Int) -> Result? {
        var bytes = [UInt8](repeating: 0, count: packetBytes)
        for b in 0..<packetBits {
            let bit = UInt8(lowestBit(samples[start + b])) ^ scramble[b]
            bytes[b / 8] |= bit << (7 - b % 8)
        }
        let crc = UInt16(bytes[15]) | UInt16(bytes[16]) << 8
        guard crc == crc16(bytes[0..<15]), bytes[4] == formatVersion else { return nil }

        let flags = bytes[5]
        guard flags & 1 != 0 else { return .noReading }
        let temperature = Int16(bitPattern: UInt16(bytes[7]) | UInt16(bytes[8]) << 8)
        let humidity = UInt16(bytes[9]) | UInt16(bytes[10]) << 8
        let pressure = UInt32(bytes[11]) | UInt32(bytes[12]) << 8
                     | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 24
        return .reading(SensorReading(
            temperatureC: Double(temperature) / 100,
            humidityPercent: flags & 2 != 0 ? Double(humidity) / 100 : nil,
            pressureHPa: Double(pressure) / 100,
            sequence: bytes[6]))
    }

    /// CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, no final XOR.
    static func crc16(_ data: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}

/// Watches the capture stream for sensor packets, about once a second.
///
/// Fed every capture buffer from `AudioEngineController.consume`, on the audio
/// thread. It decodes at most one buffer per second of audio, because the board
/// only measures once a second and every 1 ms block repeats the same packet, so
/// decoding more often would only find the same reading again. `current` is
/// read by the controller's 15 Hz stats flush on the main actor.
///
/// **It forgets after three misses in a row.** That's what makes the weather
/// icon disappear when the Mini is unplugged or swapped for a Griff, with no
/// timer of its own. Three rather than one so a single glitched buffer (a USB
/// hiccup mid-packet) doesn't make the icon flicker.
nonisolated final class SensorDataMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var samplesSinceDecode = Double.infinity
    private var misses = 0
    private var latest: SensorReading?

    static let missesBeforeForgetting = 3

    /// The latest reading, or `nil` if there isn't one, including when packets
    /// arrive but the board's sensor isn't answering.
    var current: SensorReading? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        let frames = Double(buffer.frameLength)
        let rate = buffer.format.sampleRate
        lock.lock()
        samplesSinceDecode += frames
        let due = samplesSinceDecode >= rate && Int(frames) >= SensorDataDecoder.minimumSamples
        lock.unlock()
        guard due else { return }

        let result = SensorDataDecoder.decode(buffer)

        lock.lock()
        samplesSinceDecode = 0
        switch result {
        case .reading(let reading):
            latest = reading
            misses = 0
        case .noReading:
            latest = nil
            misses = 0
        case .nothing:
            misses += 1
            if misses >= Self.missesBeforeForgetting { latest = nil }
        }
        lock.unlock()
    }

    /// Back to "nothing seen", for when capture stops.
    func reset() {
        lock.lock()
        samplesSinceDecode = .infinity
        misses = 0
        latest = nil
        lock.unlock()
    }
}

/// The latest packet an idle read finds, written from the audio thread and
/// polled from the main actor (`AudioEngineController.readSensorWhileOpen`).
/// Buffers that decode to `.nothing` never reach it, so a glitched buffer
/// can't overwrite a good reading.
nonisolated final class LatestSensorResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SensorDataDecoder.Result?

    var result: SensorDataDecoder.Result? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ result: SensorDataDecoder.Result) {
        lock.lock()
        stored = result
        lock.unlock()
    }
}
