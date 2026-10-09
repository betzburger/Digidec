// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// TFA Dostmann: 30.3196 (868 MHz), Twin Plus 30.3049 (auch Conrad KW9010, BL999), 30.3221 (auch 30.3249, Bauart LaCrosse TX141TH),
// 14.1504 V2 (Grillthermometer), Marbella 30.3238 (Poolthermometer, 868 MHz), Poolthermometer 30.3160. Aufbau nach rtl_433 (siehe THIRD_PARTY.md).

enum SensorDevicesTFA {
    static let tfa303196 = SensorDevice("TFA Dostmann 30.3196 Thermo-/Hygrosensor", SlicerTiming(.fskManchesterZeroBit, short: 245, reset: 22000, tolerance: 60), bands: [.mhz868]) { bits in
        let preamble: [UInt8] = [0x55, 0x56]
        let row = bits.findRepeatedRow(minRepeats: 2, minBits: 48 * 2 + 12)
        guard row >= 0 else { return [] }
        var start = bits.search(row: row, start: 0, pattern: preamble, patternBits: 16)
        start += 12
        guard bits.bitsPerRow[row] - start >= 96 else { return [] }
        var data = BitBuffer()
        _ = bits.manchesterDecode(row: row, start: start, into: &data, max: 48)
        guard data.numRows > 0, data.bitsPerRow[0] >= 48 else { return [] }
        let b = data.rows[0].map(Int.init)
        guard b[0] == 0xA8 else { return [] }
        let digest = b[4] << 8 | b[5]
        let chk = Int(SensorBits.lfsrDigest16(b[0..<4].map { UInt8($0) }, gen: 0x8810, key: 0x22D0)) ^ digest
        var m = SensorReading(model: "TFA-303196")
        m.add("id", chk)
        m.add("channel", (b[1] >> 4) + 1)
        m.add("battery_ok", b[3] >> 7 == 0 ? 1 : 0)
        m.add("temperature_C", Double((b[1] & 0x0F) << 8 | b[2] - 400) * 0.1)
        m.add("humidity", b[3] & 0x7F)
        m.add("mic", "missing")
        return [m]
    }

    static let twinPlus = SensorDevice("TFA Twin Plus 30.3049, Conrad KW9010, BL999", SlicerTiming(.ookPPM, short: 2000, long: 4000, reset: 10000, gap: 6000)) { bits in
        let row = bits.findRepeatedRow(minRepeats: 2, minBits: 36)
        guard row >= 0, bits.bitsPerRow[row] == 36 else { return [] }
        let b = bits.rows[row].map(Int.init) + [0, 0, 0, 0, 0]
        guard b[0..<5].contains(where: { $0 != 0 }) else { return [] }
        let rb = b[0..<5].map { Int(SensorBits.reverse8(UInt8($0))) }
        let sum = (rb[0] >> 4) + (rb[0] & 0xF) + (rb[1] >> 4) + (rb[1] & 0xF) + (rb[2] >> 4) + (rb[2] & 0xF) + (rb[3] >> 4) + (rb[3] & 0xF)
        guard rb[4] & 0x0F == sum & 0xF else { return [] }
        let negative = b[2] & 7
        let temp = ((rb[2] & 0x1F) << 4) | (rb[1] >> 4)
        var m = SensorReading(model: "TFA-TwinPlus")
        m.add("id", (rb[0] & 0x0F) | ((rb[0] & 0xC0) >> 2))
        m.add("channel", (b[0] >> 2) & 3)
        m.add("battery_ok", b[1] >> 7 == 0 ? 1 : 0)
        m.add("temperature_C", Double(negative != 0 ? -((1 << 9) - temp) : temp) * 0.1)
        m.add("humidity", (rb[3] & 0x7F) - 28)
        m.add("mic", "CHECKSUM")
        return [m]
    }

    static let tfa303221 = SensorDevice("TFA Dostmann 30.3221.02 / 30.3249.02", SlicerTiming(.ookPWM, short: 235, long: 480, reset: 850, sync: 836), priority: 10) { bits in
        let row = bits.findRepeatedRow(minRepeats: bits.numRows > 4 ? 4 : 2, minBits: 40)
        guard row >= 0, bits.bitsPerRow[row] <= 41 else { return [] }
        bits.invert()
        let b = bits.rows[row].map(Int.init) + [0, 0, 0, 0, 0]
        guard b[0] != 0 else { return [] }
        guard SensorBits.lfsrDigest8Reflect(b[0..<4].map { UInt8($0) }, gen: 0x31, key: 0xF4) == UInt8(b[4]) else { return [] }
        var m = SensorReading(model: "TFA-303221")
        m.add("id", b[0])
        m.add("channel", ((b[1] >> 4) & 3) + 1)
        m.add("battery_ok", b[1] >> 7 == 0 ? 1 : 0)
        m.add("temperature_C", Double(((b[1] & 0x0F) << 8 | b[2]) - 500) * 0.1)
        m.add("humidity", b[3])
        m.add("sendmode", (b[1] >> 6) & 1)
        m.add("mic", "CRC")
        return [m]
    }

    static let tfa141504 = SensorDevice("TFA Dostmann 14.1504.V2 Grillthermometer", SlicerTiming(.fskPCM, short: 360, long: 360, reset: 4096)) { bits in
        let preamble: [UInt8] = [0xAA, 0xAA, 0x5C]
        guard bits.numRows == 1 else { return [] }
        var available = bits.bitsPerRow[0]
        guard available >= 64 else { return [] }
        let start = bits.search(row: 0, start: 0, pattern: preamble, patternBits: 24)
        available -= start
        guard available >= 24, available >= 64, available <= 76 else { return [] }
        let b = bits.extractBytes(row: 0, pos: start + 24, len: 40).map(Int.init)
        let flags = b[0] >> 4
        guard flags & 0x5 != 0x5, b[2] == 0xFF else { return [] }
        let calc = Int(SensorBits.lfsrDigest16(b[0..<3].map { UInt8($0) }, gen: 0x8810, key: 0x0D42)) ^ 0x16EB
        guard calc == (b[3] << 8) + b[4] else { return [] }
        let raw = ((b[0] & 0xF) << 6) + (b[1] >> 2)
        let connected = raw != 0x1C0
        var m = SensorReading(model: "TFA-141504v2")
        m.add("battery_ok", flags & 0x2 != 0 ? 1 : 0)
        m.add("probe_fail", connected ? 0 : 1)
        if connected { m.add("temperature_C", Double(raw - 532)) }
        m.add("mic", "CRC")
        return [m]
    }

    static let marbella = SensorDevice("TFA Marbella Poolthermometer", SlicerTiming(.fskPCM, short: 105, long: 105, reset: 2000), bands: [.mhz868]) { bits in
        guard bits.numRows > 0 else { return [] }
        let preamble: [UInt8] = [0xAA, 0x2D, 0xD4]
        let start = bits.search(row: 0, start: 0, pattern: preamble, patternBits: 24)
        guard start < bits.bitsPerRow[0] else { return [] }
        let msg = bits.extractBytes(row: 0, pos: start, len: 88).map(Int.init) + [Int](repeating: 0, count: 11)
        guard msg[9] == 0xAA else { return [] }
        guard SensorBits.lfsrDigest8Reflect(msg[3..<10].map { UInt8($0) }, gen: 0x31, key: 0x31) == UInt8(msg[10]) else { return [] }
        var m = SensorReading(model: "TFA-Marbella")
        m.add("id", String(format: "%06x", msg[3] << 16 | msg[4] << 8 | msg[5]))
        m.add("counter", (msg[6] >> 1) & 7)
        m.add("battery_ok", (msg[6] >> 7) & 1 == 0 ? 1 : 0)
        m.add("temperature_C", Double(((msg[7] << 4) | (msg[8] >> 4)) - 400) * 0.1)
        m.add("mic", "CRC")
        return [m]
    }

    static let pool = SensorDevice("TFA Poolthermometer 30.3160", SlicerTiming(.ookPPM, short: 2000, long: 4600, reset: 10000, gap: 7800)) { bits in
        let row = bits.findRepeatedRow(minRepeats: 7, minBits: 28)
        guard row >= 0, bits.bitsPerRow[row] == 28 else { return [] }
        let b = bits.rows[row].map(Int.init) + [0, 0, 0, 0]
        let rx = (b[0] & 0xF0) >> 4
        let sum = (b[0] & 0x0F) + (b[1] >> 4) + (b[1] & 0x0F) + (b[2] >> 4) + (b[2] & 0x0F) + (b[3] >> 4) - 1
        guard rx == sum & 0x0F else { return [] }
        let raw = (b[1] & 0x0F) << 8 | b[2]
        var m = SensorReading(model: "TFA-Pool")
        m.add("id", ((b[0] & 0x0F) << 4) | ((b[1] & 0xF0) >> 4))
        m.add("channel", (b[3] & 0xC0) >> 6)
        m.add("battery_ok", (b[3] & 0x20) >> 5)
        m.add("temperature_C", Double(raw > 2048 ? raw - 4096 : raw) * 0.1)
        m.add("mic", "CHECKSUM")
        return [m]
    }

    static let drop = SensorDevice("TFA Drop Regenmesser 30.3233.01", SlicerTiming(.ookPWM, short: 255, long: 510, reset: 2500, gap: 1300, sync: 750)) { bits in
        bits.invert()
        let row = bits.findRepeatedRow(minRepeats: 2, minBits: 66)
        guard row >= 0, bits.bitsPerRow[row] <= 66 + 16 else { return [] }
        let b = bits.rows[row].map(Int.init) + [0, 0, 0, 0, 0, 0, 0, 0, 0]
        guard b[0] & 0xF0 == 0x30 else { return [] }
        guard SensorBits.lfsrDigest8Reflect(b[0..<7].map { UInt8($0) }, gen: 0x31, key: 0xF4) == UInt8(b[7]) else { return [] }
        let counter = (b[6] << 8 | b[4]) + 10
        var m = SensorReading(model: "TFA-Drop")
        m.add("id", (b[0] & 0x0F) << 16 | b[1] << 8 | b[2])
        m.add("battery_ok", (b[3] & 0x80) >> 7 == 0 ? 1 : 0)
        m.add("rain_mm", Double(Float(counter & 0xFFFF) * 0.254))
        m.add("mic", "CHECKSUM")
        return [m]
    }

    static let infactory = SensorDevice("inFactory, nor-tec, FreeTec NC-3982 Thermo-/Hygrosensor", SlicerTiming(.ookPPM, short: 2000, long: 4000, reset: 5000, sync: 500, tolerance: 750)) { bits in
        guard bits.numRows > 0, [40, 41, 42].contains(bits.bitsPerRow[0]) else { return [] }
        let b = bits.rows[0].map(Int.init) + [0, 0, 0, 0, 0, 0]
        let channel = b[4] & 3
        guard channel != 0 else { return [] }
        // CRC-4: die Kanalbits stehen an der CRC-Stelle
        var msg = b[0..<5].map { UInt8($0) }
        let msgCRC = msg[1] >> 4
        msg[1] = (msg[1] & 0x0F) | (msg[4] & 0x0F) << 4
        let crc = SensorBits.crc4(Array(msg[0..<4]), poly: 0x13, initial: 0) ^ (msg[4] >> 4)
        guard crc == msgCRC else { return [] }
        let tempRaw = (b[2] << 4) | (b[3] >> 4)
        let humidity = (b[3] & 0x0F) * 10 + (b[4] >> 4)
        let tempF = Double(Float(tempRaw - 900) * 0.1)
        guard humidity <= 100, tempF >= -40, tempF <= 158 else { return [] }
        var m = SensorReading(model: "inFactory-TH")
        m.add("id", b[0]); m.add("channel", channel); m.add("battery_ok", (b[1] >> 2) & 1 == 0 ? 1 : 0); m.add("button", (b[1] >> 3) & 1)
        m.add("temperature_F", tempF); m.add("humidity", humidity); m.add("mic", "CRC")
        m.add("temperature_C", (tempF - 32) / 1.8)
        return [m]
    }
}
