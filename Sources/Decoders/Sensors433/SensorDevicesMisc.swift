// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Weitere Wetter- und Temperatursensoren: Hideki TS04 (auch Bresser 5CH, Wind- und Regenmesser), LaCrosse TX141 (TX141-Bv2/Bv3,
// TX141TH-Bv2, TX141W, TX145wsdth; auch TFA 30.3221, 30.3222, 30.3243, 30.3249, 30.3251). Aufbau nach rtl_433 (siehe THIRD_PARTY.md).

enum SensorDevicesMisc {
    // MARK: Hideki

    static let hideki = SensorDevice("Hideki TS04 (auch Bresser 5CH), Wind, Regen", SlicerTiming(.ookDMC, short: 520, long: 1040, reset: 4000, tolerance: 240)) { bits in
        for row in 0..<bits.numRows {
            // 8, 9, 10 oder 14 entstopfte Bytes, bis zu vier fehlende Bits sind erlaubt
            var unstuffed = (bits.bitsPerRow[row] + 4) / 9
            enum Kind { case wind, ts04, rain, temp }
            let kind: Kind
            switch unstuffed {
            case 14: kind = .wind
            case 10: kind = .ts04
            case 9: kind = .rain
            case 8: kind = .temp
            default: continue
            }
            unstuffed -= 1                                                              // Synchronbyte nicht mitzählen
            var b = bits.rows[row].map(Int.init) + [0, 0]
            // Anfang (nicht invertiert) 00000110 1, fehlende Bits erlaubt
            var sync = b[0] << 1 | b[1] >> 7
            var startPos = -1
            for i in 0..<4 {
                if sync == 0x0D { startPos = 9 - i; break }
                sync >>= 1
            }
            if startPos < 0 { continue }
            bits.invert()
            b = bits.rows[row].map(Int.init) + [0, 0, 0]
            var packet = [UInt8](repeating: 0, count: 14)
            var parityError = false
            for i in 0..<unstuffed {
                let offset = startPos + i * 9
                let value = (b[offset / 8] << (offset % 8) | b[offset / 8 + 1] >> (8 - offset % 8)) & 0xFF
                packet[i] = UInt8(value)
                let parity = (b[offset / 8 + 1] >> (7 - offset % 8)) & 1
                if parity != SensorBits.parity8(packet[i]) { parityError = true; break }
            }
            if parityError { continue }
            let p0 = Array(packet[0..<unstuffed])
            if SensorBits.xorBytes(Array(p0[0..<(unstuffed - 1)])) != 0 { continue }
            if SensorBits.crc8(p0, poly: 0x07, initial: 0) != 0 { continue }
            let p = SensorBits.reflectBytes(p0).map(Int.init)
            let pktLen = (p[1] >> 1) & 0x1F
            if pktLen + 2 != unstuffed { continue }
            var channel = (p[0] >> 5) & 0x0F
            if channel >= 5 { channel -= 1 }
            let rc = p[0] & 0x0F
            var temp = (p[4] & 0x0F) * 100 + ((p[3] & 0xF0) >> 4) * 10 + (p[3] & 0x0F)
            if (p[4] >> 7) & 1 == 0 { temp = -temp }
            var battery = (p[4] >> 6) & 1
            switch kind {
            case .ts04:
                var m = SensorReading(model: "Hideki-TS04")
                m.add("id", rc); m.add("channel", channel); m.add("battery_ok", battery)
                m.add("temperature_C", Double(temp) / 10)
                m.add("humidity", ((p[5] & 0xF0) >> 4) * 10 + (p[5] & 0x0F))
                m.add("mic", "CRC")
                return [m]
            case .wind:
                let wd = [0, 15, 13, 14, 9, 10, 12, 11, 1, 2, 4, 3, 8, 7, 5, 6]
                let direction = wd[(p[10] & 0xF0) >> 4] * 225
                let speed = (p[8] & 0x0F) * 100 + (p[7] >> 4) * 10 + (p[7] & 0x0F)
                let gust = (p[9] >> 4) * 100 + (p[9] & 0x0F) * 10 + (p[8] >> 4)
                let ad = [0, 1, -1, 2]
                var m = SensorReading(model: "Hideki-Wind")
                m.add("id", rc); m.add("channel", channel); m.add("battery_ok", battery)
                m.add("temperature_C", Double(temp) * 0.1)
                m.add("wind_avg_mi_h", Double(speed) * 0.1)
                m.add("wind_max_mi_h", Double(gust) * 0.1)
                m.add("wind_approach", ad[(p[10] >> 2) & 3])
                m.add("wind_dir_deg", Double(direction) * 0.1)
                m.add("mic", "CRC")
                return [m]
            case .temp:
                var m = SensorReading(model: "Hideki-Temperature")
                m.add("id", rc); m.add("channel", channel); m.add("battery_ok", battery)
                m.add("temperature_C", Double(temp) * 0.1)
                m.add("mic", "CRC")
                return [m]
            case .rain:
                battery = (p[1] >> 6) & 1
                var m = SensorReading(model: "Hideki-Rain")
                m.add("id", rc); m.add("channel", channel); m.add("battery_ok", battery)
                m.add("rain_mm", Double((p[4] << 8) | p[3]) * 0.7)
                m.add("mic", "CRC")
                return [m]
            }
        }
        return []
    }

    // MARK: LaCrosse TX141

    static let lacrosseTX141 = SensorDevice("LaCrosse TX141-Bv2/Bv3, TX141TH-Bv2, TX141W, TX145wsdth, TFA 30.3221/30.3222/30.3243/30.3249/30.3251",
                                            SlicerTiming(.ookPWM, short: 208, long: 417, reset: 1700, gap: 625, sync: 833)) { bits in
        guard bits.numRows > 0 else { return [] }
        bits.invert()
        var r = bits.findRepeatedRow(minRepeats: bits.numRows > 5 ? 5 : 3, minBits: 32)
        if r < 0 { r = bits.findRepeatedRow(minRepeats: 2, minBits: 64) }
        if r < 0 && bits.numRows <= 4 {
            for row in 0..<bits.numRows where bits.bitsPerRow[row] == 40 || bits.bitsPerRow[row] == 41 {
                let b = bits.rows[row]
                if b.count >= 5, SensorBits.lfsrDigest8Reflect(Array(b[0..<4]), gen: 0x31, key: 0xF4) == b[4] { r = row; break }
            }
        }
        guard r >= 0 else { return [] }
        enum Device { case b, standard, th, bv3, w }
        let n = bits.bitsPerRow[r]
        let device: Device
        if n >= 64 { device = .w }
        else if n > 41 { return [] }
        else if n >= 41 { if bits.numRows > 12 { return [] }; device = .th }
        else if n >= 40 { device = .th }
        else if n >= 37 { device = .standard }
        else if n == 32 { device = .b }
        else { device = .bv3 }
        let b = bits.rows[r].map(Int.init) + [0, 0, 0, 0, 0, 0, 0, 0, 0]

        if device == .w {
            guard b[0] >> 3 == 0x01 else { return [] }
            guard SensorBits.crc8(b[0..<8].map { UInt8($0) }, poly: 0x31, initial: 0) == 0 else { return [] }
            let id = (b[0] & 0x07) << 16 | b[1] << 8 | b[2]
            let batteryLow = b[3] >> 7
            let test = (b[3] & 0x40) >> 6
            let channel = (b[3] & 0x30) >> 4
            let type = b[3] & 0x0F
            let tempRaw = b[4] << 4 | b[5] >> 4
            let humidity = (b[5] & 0x0F) << 8 | b[6]
            var m = SensorReading(model: "LaCrosse-TX141W")
            m.add("id", id); m.add("channel", channel); m.add("battery_ok", batteryLow == 0 ? 1 : 0)
            if type == 1 {
                m.add("temperature_C", Double(tempRaw - 500) * 0.1)
                m.add("humidity", humidity)
            } else if type == 2 {
                m.add("wind_avg_km_h", Double(tempRaw) * 0.1)
                m.add("wind_dir_deg", humidity)
            } else { return [] }
            m.add("test", test)
            m.add("mic", "CRC")
            return [m]
        }

        let id = b[0]
        let batteryLow = device == .th ? b[1] >> 7 : (b[1] >> 7 == 0 ? 1 : 0)
        let test = (b[1] & 0x40) >> 6
        let channel = (b[1] & 0x30) >> 4
        let tempRaw = (b[1] & 0x0F) << 8 | b[2]
        let tempC = Double(tempRaw - 500) * 0.1
        let humidity = device == .th ? b[3] : 0
        if id == 0 || (device == .th && (humidity == 0 || humidity > 100)) || tempC < -40 || tempC > 140 { return [] }
        var m: SensorReading
        switch device {
        case .b:
            m = SensorReading(model: "LaCrosse-TX141B")
            m.add("id", id); m.add("temperature_C", tempC); m.add("battery_ok", batteryLow == 0 ? 1 : 0)
            m.add("test", test != 0 ? "Yes" : "No")
            return [m]
        case .standard:
            m = SensorReading(model: "LaCrosse-TX141Bv2")
            m.add("id", id); m.add("channel", channel); m.add("temperature_C", tempC); m.add("battery_ok", batteryLow == 0 ? 1 : 0)
            m.add("test", test != 0 ? "Yes" : "No")
            return [m]
        case .bv3:
            m = SensorReading(model: "LaCrosse-TX141Bv3")
            m.add("id", id); m.add("channel", channel); m.add("battery_ok", batteryLow == 0 ? 1 : 0); m.add("temperature_C", tempC)
            m.add("test", test != 0 ? "Yes" : "No")
            return [m]
        default:
            guard SensorBits.lfsrDigest8Reflect(b[0..<4].map { UInt8($0) }, gen: 0x31, key: 0xF4) == UInt8(b[4]) else { return [] }
            m = SensorReading(model: "LaCrosse-TX141THBv2")
            m.add("id", id); m.add("channel", channel); m.add("battery_ok", batteryLow == 0 ? 1 : 0)
            m.add("temperature_C", tempC); m.add("humidity", humidity)
            m.add("test", test != 0 ? "Yes" : "No")
            m.add("mic", "CRC")
            return [m]
        }
    }
}
