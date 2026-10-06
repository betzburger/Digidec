// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Fine Offset Electronics und Abkömmlinge (Ecowitt, Misol, Froggit, ELV, TFA, Agimex): WH2 (Thermo/Hygro, OOK), WH24/WH65B/WS69
// (Wetterstation mit Wind, Regen, UV, Licht, FSK 868/915/433 MHz) und WH25/WH32/WH32B (Thermo/Hygro/Druck, FSK).
// Aufbau der Telegramme nach rtl_433 (`fineoffset.c`, siehe THIRD_PARTY.md).

enum SensorDevicesFineOffset {
    // MARK: WH2

    static let wh2 = SensorDevice("Fine Offset WH2, WH5, Telldus, TFA 30.3157/30.3225", SlicerTiming(.ookPWM, short: 500, long: 1500, reset: 1200, tolerance: 160)) { bits in
        guard bits.numRows > 0 else { return [] }
        let first = bits.rows[0]
        let n0 = bits.bitsPerRow[0]
        var b: [UInt8]
        enum Model { case wh2, wh2a, wh5, tp, tfa303225 }
        var model: Model
        if n0 == 48 && first[0] == 0xFF {
            b = bits.extractBytes(row: 0, pos: 8, len: 40); model = .wh2
        } else if n0 == 55 && first[0] == 0xFE {
            b = bits.extractBytes(row: 0, pos: 7, len: 48)
            model = b[3] == 0xFF ? .tfa303225 : .wh2a
        } else if n0 == 47 && first[0] == 0xFE {
            b = bits.extractBytes(row: 0, pos: 7, len: 40); model = .wh5
        } else if n0 == 49 && first[0] == 0xFF && first.count > 1 && first[1] & 0x80 == 0x80 {
            b = bits.extractBytes(row: 0, pos: 9, len: 40); model = .tp
        } else { return [] }
        b += [0, 0, 0, 0, 0, 0]
        guard b[4] == SensorBits.crc8(Array(b[0..<4]), poly: 0x31, initial: 0) else { return [] }
        if model == .tfa303225 && SensorBits.addBytes(Array(b[0..<5])) & 0xFF != Int(b[5]) { return [] }
        guard b[0] >> 4 == 4 else { return [] }
        let id = Int(b[0] & 0x0F) << 4 | Int(b[1] & 0xF0) >> 4
        var temp = Int(b[1] & 0x0F) << 8 | Int(b[2])
        var lowBattery = false
        switch model {
        case .tfa303225:
            lowBattery = temp & 0x800 != 0
            temp &= 0x7FF
            temp -= 400
        case .wh5:
            temp -= 400
        default:
            if temp & 0x800 != 0 { temp &= 0x7FF; temp = -temp }
        }
        let temperature = Double(temp) * 0.1
        if model == .wh5 && (temperature < -40 || temperature > 60) { return [] }
        let humidity = Int(b[3])
        var m = SensorReading(model: ["Fineoffset-WH2", "Fineoffset-WH2A", "Fineoffset-WH5", "Fineoffset-TelldusProove", "TFA-303225"][[Model.wh2, .wh2a, .wh5, .tp, .tfa303225].firstIndex(of: model)!])
        m.add("id", id)
        if model == .tfa303225 { m.add("battery_ok", lowBattery ? 0 : 1) }
        m.add("temperature_C", temperature)
        if humidity != 0xFF { m.add("humidity", humidity) }
        m.add("mic", "CRC")
        return [m]
    }

    // MARK: WH24, WH65B, WS69, WH25, WH32

    static let wh25 = SensorDevice("Fine Offset WH24, WH65B, WS69, WH25, WH32, WH32B", SlicerTiming(.fskPCM, short: 58, long: 58, reset: 20000), bands: [.mhz433, .mhz868]) { bits in
        guard bits.numRows > 0 else { return [] }
        let n0 = bits.bitsPerRow[0]
        if n0 < 160 { return [] }                                                    // WH0290 (Luftgüte) nicht unterstützt
        if n0 < 190 { return wh25Family(bits, type: 32) }                            // WN32B: 173 Bit
        if n0 < 440 { return wh24Family(bits) }                                      // WH24, WH65B, WS69
        return wh25Family(bits, type: n0 > 510 ? 32 : 25)
    }

    private static let preamble: [UInt8] = [0xAA, 0x2D, 0xD4]

    private static func wh25Family(_ bits: BitBuffer, type initial: Int) -> [SensorReading] {
        var type = initial
        let offset = bits.search(row: 0, start: 0, pattern: preamble, patternBits: 24) + 24
        guard offset + 64 <= bits.bitsPerRow[0] else { return [] }
        let b = bits.extractBytes(row: 0, pos: offset, len: 64)
        let msg = b[0] & 0xF0
        if type == 32 && msg == 0xD0 { type = 31 } else if msg != 0xE0 { return [] }
        guard (SensorBits.addBytes(Array(b[0..<6])) & 0xFF) - Int(b[6]) == 0 else { return [] }
        var bitsum = SensorBits.xorBytes(Array(b[0..<6]))
        bitsum = ((bitsum & 0x0F) << 4) | (bitsum >> 4)
        if type == 25 && bitsum != b[7] { return [] }
        let tempRaw = Int(b[1] & 0x03) << 8 | Int(b[2])
        let pressureRaw = Int(b[4]) << 8 | Int(b[5])
        var m = SensorReading(model: type == 31 ? "Fineoffset-WH32" : type == 32 ? "Fineoffset-WH32B" : "Fineoffset-WH25")
        m.add("id", Int(b[0] & 0x0F) << 4 | Int(b[1] >> 4))
        m.add("battery_ok", (b[1] & 0x08) >> 3 == 0 ? 1 : 0)
        m.add("temperature_C", Double(tempRaw - 400) * 0.1)
        m.add("humidity", Int(b[3]))
        if pressureRaw != 0xFFFF { m.add("pressure_hPa", Double(pressureRaw) * 0.1) }
        m.add("mic", "CRC")
        return [m]
    }

    private static func wh24Family(_ bits: BitBuffer) -> [SensorReading] {
        let n0 = bits.bitsPerRow[0]
        guard n0 >= 190, n0 <= 268 else { return [] }
        let bitOffset = bits.search(row: 0, start: 0, pattern: preamble, patternBits: 24) + 24
        guard bitOffset + 17 * 8 <= n0 else { return [] }
        enum Model { case wh24, wh65, ws69 }
        var type: Model
        if n0 - bitOffset - 17 * 8 < 8 { type = bitOffset < 61 ? .wh24 : .wh65 } else { type = .wh65 }
        if n0 > 215 { type = .ws69 }
        let b = bits.extractBytes(row: 0, pos: bitOffset, len: 25 * 8)
        guard b[0] == 0x24 else { return [] }
        let crc = SensorBits.crc8(Array(b[0..<16]), poly: 0x31, initial: 0)
        let sum = UInt8(truncatingIfNeeded: SensorBits.addBytes(Array(b[0..<16])))
        guard crc == 0, sum == b[16] else { return [] }
        var pressureHPa = -1.0
        if type == .ws69 {
            let raw = Int(b[17]) << 16 | Int(b[18]) << 8 | Int(b[19])
            let pcrc = SensorBits.crc8(Array(b[0..<24]), poly: 0x31, initial: 0)
            let psum = UInt8(truncatingIfNeeded: SensorBits.addBytes(Array(b[0..<24])))
            if pcrc == 0 && psum == b[24] && raw < 0x01FFFF { pressureHPa = Double(raw) * 0.01 }
        }
        let windDir = Int(b[2]) | (Int(b[3]) & 0x80) << 1
        let lowBattery = (Int(b[3]) & 0x08) >> 3
        let tempRaw = (Int(b[3]) & 0x07) << 8 | Int(b[4])
        let humidity = Int(b[5])
        let windRaw = Int(b[6]) | (Int(b[3]) & 0x10) << 4
        let windFactor = type == .wh24 ? 1.12 : 0.51
        let rainCup = type == .wh24 ? 0.3 : 0.254
        let gustRaw = Int(b[7])
        let rainRaw = Int(b[8]) << 8 | Int(b[9])
        let uvRaw = Int(b[10]) << 8 | Int(b[11])
        let lightRaw = Int(b[12]) << 16 | Int(b[13]) << 8 | Int(b[14])
        let upper = [432, 851, 1210, 1570, 2017, 2450, 2761, 3100, 3512, 3918, 4277, 4650, 5029]
        var uvi = 0
        while uvi < 13 && upper[uvi] < uvRaw { uvi += 1 }
        var m = SensorReading(model: type == .wh24 ? "Fineoffset-WH24" : type == .wh65 ? "Fineoffset-WH65B" : "Fineoffset-WS69")
        m.add("id", Int(b[1]))
        m.add("battery_ok", lowBattery == 0 ? 1 : 0)
        if tempRaw != 0x7FF { m.add("temperature_C", Double(tempRaw - 400) * 0.1) }
        if humidity != 0xFF { m.add("humidity", humidity) }
        if pressureHPa >= 0 { m.add("pressure_hPa", pressureHPa) }
        if windDir != 0x1FF { m.add("wind_dir_deg", windDir) }
        if windRaw != 0x1FF { m.add("wind_avg_m_s", Double(windRaw) * 0.125 * windFactor) }
        if gustRaw != 0xFF { m.add("wind_max_m_s", Double(gustRaw) * windFactor) }
        m.add("rain_mm", Double(rainRaw) * rainCup)
        if uvRaw != 0xFFFF { m.add("uv", uvRaw); m.add("uvi", Double(uvi)) }
        if lightRaw != 0xFFFFFF { m.add("light_lux", Double(lightRaw) * 0.1) }
        m.add("mic", "CRC")
        return [m]
    }
}
