// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Thermometer und Hygrometer mit Abstandskodierung (PPM): Nexus (auch FreeTec NC-7345, infactory NX-3980, Solight TE82S, TFA 30.3209),
// Nexus-Sauna und Prologue (FreeTec NC-7104, ThermoPro TX-2). Aufbau der Telegramme nach rtl_433 (siehe THIRD_PARTY.md).

enum SensorDevicesPPM {
    /// Vorzeichenbehaftete 16 Bit aus zwei Bytes
    static func s16(_ hi: Int, _ lo: Int) -> Int { Int(Int16(truncatingIfNeeded: (hi << 8) | lo)) }

    // MARK: Nexus

    static let nexus = SensorDevice("Nexus, FreeTec NC-7345, NX-3980, Solight TE82S, TFA 30.3209", SlicerTiming(.ookPPM, short: 1000, long: 2000, reset: 5000, gap: 3000), priority: 10) { bits in
        let r = bits.findRepeatedRow(minRepeats: 3, minBits: 36)
        guard r >= 0, bits.bitsPerRow[r] <= 37 else { return [] }
        let b = bits.rows[r].map(Int.init) + [0, 0, 0, 0, 0]
        guard b[3] & 0xF0 == 0xF0 else { return [] }                                       // Konstante 1111
        if (b[0] == 0 && b[2] == 0 && b[3] == 0) || (b[0] == 0xFF && b[2] == 0xFF && b[3] == 0xFF) { return [] }
        guard b[1] & 0x30 != 0x30 else { return [] }                                       // Kanal 1 … 3
        // Rubicson/Solight TE44 haben dieselbe Form mit CRC-8 im letzten Byte: dann ist es keiner von uns
        let crcIn: [UInt8] = [UInt8(b[0]), UInt8(b[1]), UInt8(b[2]), UInt8(b[3] & 0xF0), UInt8((b[3] & 0x0F) << 4 | (b[4] & 0xF0) >> 4)]
        guard SensorBits.crc8(crcIn, poly: 0x31, initial: 0x6C) != 0 else { return [] }
        // 12 Bit mit Vorzeichen: unteres Halbbyte von b[1] und b[2]
        let raw = Int(Int16(truncatingIfNeeded: (b[1] << 12) | (b[2] << 4)))
        let tempC = Double(raw >> 4) * 0.1
        let humidity = ((b[3] & 0x0F) << 4) | (b[4] >> 4)
        guard humidity == 0 || humidity <= 100 else { return [] }
        var m = SensorReading(model: humidity == 0 ? "Nexus-T" : "Nexus-TH")
        m.add("id", b[0])
        m.add("channel", ((b[1] & 0x30) >> 4) + 1)
        m.add("battery_ok", b[1] & 0x80 != 0 ? 1 : 0)
        m.add("temperature_C", tempC)
        if humidity != 0 { m.add("humidity", humidity) }
        if b[1] & 0x40 != 0 { m.add("test", 1) }
        return [m]
    }

    static let nexusSauna = SensorDevice("Nexus, CRX, Prego Saunathermometer", SlicerTiming(.ookPPM, short: 1000, long: 2000, reset: 5000, gap: 3000), priority: 10) { bits in
        let r = bits.findRepeatedRow(minRepeats: 3, minBits: 36)
        guard r >= 0, bits.bitsPerRow[r] <= 37 else { return [] }
        let b = bits.rows[r].map(Int.init) + [0, 0, 0, 0, 0]
        guard b[1] & 0xF == 0xF else { return [] }
        if b[0] == 0 || b[4] & 0x10 != 0x10 || (b[0] == 0xFF && b[2] == 0xFF && b[3] == 0xFF) { return [] }
        guard b[1] & 0x30 == 0x30 else { return [] }
        var m = SensorReading(model: "Nexus-Sauna")
        m.add("id", b[0])
        m.add("channel", ((b[1] & 0x30) >> 4) + 1)
        m.add("battery_ok", b[1] & 0x80 != 0 ? 1 : 0)
        m.add("temperature_C", Double(s16(b[2], b[3])) * 0.1)
        if b[1] & 0x40 != 0 { m.add("test", 1) }
        return [m]
    }

    // MARK: Prologue

    static let prologue = SensorDevice("Prologue, FreeTec NC-7104, NC-7159-675, ThermoPro TX-2", SlicerTiming(.ookPPM, short: 2000, long: 4000, reset: 10000, gap: 7000), priority: 10) { bits in
        if bits.bitsPerRow[0] <= 8 && bits.bitsPerRow[0] != 0 { return [] }                   // Alecto/Auriol hat 8 Synchronbits
        let r = bits.findRepeatedRow(minRepeats: 4, minBits: 36)
        guard r >= 0, bits.bitsPerRow[r] <= 37 else { return [] }
        let b = bits.rows[r].map(Int.init) + [0, 0, 0, 0, 0]
        guard b[0] & 0xF0 == 0x90 || b[0] & 0xF0 == 0x50 else { return [] }
        let humidity = ((b[3] & 0x0F) << 4) | (b[4] >> 4)
        let raw = s16(b[2], b[3] & 0xF0) >> 4
        var m = SensorReading(model: "Prologue-TH")
        m.add("subtype", b[0] >> 4)
        m.add("id", ((b[0] & 0x0F) << 4) | ((b[1] & 0xF0) >> 4))
        m.add("channel", (b[1] & 0x03) + 1)
        m.add("battery_ok", b[1] & 0x08 != 0 ? 1 : 0)
        m.add("temperature_C", Double(raw) * 0.1)
        if humidity != 0xCC { m.add("humidity", humidity) }
        m.add("button", (b[1] & 0x04) >> 2)
        return [m]
    }
}
