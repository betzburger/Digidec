// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Ecowitt / Ambient Weather / Fine Offset (FSK, 56 µs je Bit): WH31E und WH31B (Thermo-/Hygrosensor), WH40 und WN20 (Regenmesser), WS68 (Windmesser mit
// Licht und UV), Funkuhr; dazu der Außenthermometer WH53/WH0280 (OOK). Aufbau nach rtl_433 (siehe THIRD_PARTY.md).

enum SensorDevicesEcowitt {
    static let wh31 = SensorDevice("Ecowitt/Ambient Weather WH31E, WH31B, WH40, WN20, WS68", SlicerTiming(.fskPCM, short: 56, long: 56, reset: 1500, gap: 1800), bands: [.mhz433, .mhz868]) { bits in
        let preamble: [UInt8] = [0xAA, 0x2D, 0xD4]
        var out: [SensorReading] = []
        for row in 0..<bits.numRows {
            let start = bits.search(row: row, start: 0, pattern: preamble, patternBits: 24)
            if start == bits.bitsPerRow[row] { continue }
            let b = bits.extractBytes(row: row, pos: start + 24, len: 18 * 8).map(Int.init) + [Int](repeating: 0, count: 18)
            let type = b[0]
            func checks(_ n: Int) -> Bool {
                SensorBits.crc8(b[0..<n].map { UInt8($0) }, poly: 0x31, initial: 0) == 0 && (SensorBits.addBytes(b[0..<n].map { UInt8($0) }) & 0xFF) == b[n]
            }
            switch type {
            case 0x30, 0x37:
                guard checks(6) else { continue }
                var m = SensorReading(model: type == 0x30 ? "AmbientWeather-WH31E" : "AmbientWeather-WH31B")
                m.add("id", b[1]); m.add("channel", ((b[2] & 0x70) >> 4) + 1); m.add("battery_ok", (b[2] & 0x04) >> 2 == 0 ? 1 : 0)
                m.add("temperature_C", Double(((b[2] & 0x03) << 8 | b[3]) - 400) * 0.1); m.add("humidity", b[4])
                m.add("data", String(format: "%02x%02x%02x%02x%02x", b[6], b[7], b[8], b[9], b[10])); m.add("mic", "CRC")
                out.append(m)
            case 0x52:
                guard checks(10) else { continue }
                let year = ((b[3] & 0xF0) >> 4) * 10 + (b[3] & 0x0F) + 2000
                let month = ((b[4] & 0x10) >> 4) * 10 + (b[4] & 0x0F)
                let day = ((b[5] & 0x30) >> 4) * 10 + (b[5] & 0x0F)
                let hours = ((b[6] & 0x30) >> 4) * 10 + (b[6] & 0x0F)
                let minutes = ((b[7] & 0x70) >> 4) * 10 + (b[7] & 0x0F)
                let seconds = ((b[8] & 0x70) >> 4) * 10 + (b[8] & 0x0F)
                var m = SensorReading(model: "AmbientWeather-WH31E")
                m.add("id", b[1]); m.add("data", b[2])
                m.add("radio_clock", String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", year, month, day, hours, minutes, seconds)); m.add("mic", "CRC")
                out.append(m)
            case 0x40:
                guard checks(8) else { continue }
                let battery = b[4] & 0x1F
                let level = battery <= 9 ? 0 : min(100, 100 * (battery - 9) / 6)
                var m = SensorReading(model: "EcoWitt-WH40")
                m.add("id", ((b[1] & 0x0F) << 16) | (b[2] << 8) | b[3])
                if battery != 0 { m.add("battery_V", Double(Float(battery) * 0.1)); m.add("battery_ok", Double(level) * 0.01) }
                m.add("rain_mm", Double((b[5] << 8) | b[6]) * 0.1)
                m.add("data", String(format: "%02x%02x%02x%02x%02x", b[9], b[10], b[11], b[12], b[13])); m.add("mic", "CRC")
                out.append(m)
            case 0x20:
                guard checks(9) else { continue }
                let raw = b[4]
                let level = raw <= 90 ? 0 : min(100, 100 * (raw - 90) / 60)
                var m = SensorReading(model: "EcoWitt-WN20")
                m.add("id", (b[2] << 8) | b[3])
                m.add("battery_V", Double(Float(raw) * 0.02)); m.add("battery_ok", level > 0 ? 1 : 0); m.add("battery_pct", level)
                m.add("rain_mm", Double((b[5] << 8) | b[6]) * 0.1)
                m.add("data", String(format: "%02x%02x%02x%02x%02x", b[10], b[11], b[12], b[13], b[14])); m.add("mic", "CRC")
                out.append(m)
            case 0x68:
                guard checks(15) else { continue }
                let batt = b[6]
                var m = SensorReading(model: "EcoWitt-WS68")
                m.add("id", (b[2] << 8) | b[3]); m.add("battery_raw", batt); m.add("battery_ok", batt > 0x20 ? 1 : 0)
                m.add("light_lux", ((b[4] << 8) | b[5]) * 10)
                m.add("wind_avg_m_s", Double(Float(((b[7] & 0x10) << 4) | b[10]) * 0.1))
                m.add("wind_max_m_s", Double(Float(((b[7] & 0x40) << 2) | b[12]) * 0.1))
                m.add("uvi", Double(Int(Float(b[13]) * 0.1)))
                m.add("wind_dir_deg", ((b[7] & 0x20) << 3) | b[11])
                m.add("data", String(format: "%02x%01x", b[16], b[17] >> 4)); m.add("mic", "CRC")
                out.append(m)
            default:
                continue
            }
        }
        return out
    }

    static let wh53 = SensorDevice("Ecowitt WH53/WH0280/WH0281A Außenthermometer", SlicerTiming(.ookPWM, short: 500, long: 1480, reset: 2000, gap: 1500)) { bits in
        guard bits.numRows == 1 else { return [] }
        let pos = bits.search(row: 0, start: 0, pattern: [0xF5, 0x30], patternBits: 12)
        guard pos < bits.bitsPerRow[0], bits.bitsPerRow[0] - pos >= 52 else { return [] }
        let b = bits.extractBytes(row: 0, pos: pos + 4, len: 48).map(Int.init)
        guard SensorBits.crc8(b.map { UInt8($0) }, poly: 0x31, initial: 0) == 0 else { return [] }
        let channel = (b[2] >> 4) + 1
        guard channel <= 3, b[2] & 0x0C == 0, b[4] == 0xFF else { return [] }
        var m = SensorReading(model: "Ecowitt-WH53")
        m.add("id", b[1]); m.add("channel", channel)
        m.add("temperature_C", Double(((b[2] & 3) << 8 | b[3]) - 400) * 0.1)
        m.add("mic", "CRC")
        return [m]
    }
}
