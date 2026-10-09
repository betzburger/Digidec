// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Weitere Sensoren nach rtl_433: Alecto V1 (WS3500, WS4500, Ventus W155/W044), Ambient Weather TX-8300 (TFA 30.3211.02) und die Wetterstation
// TFA 30.3151 (FSK-Fassung des Fine Offset WH1050).

enum SensorDevicesMore {
    /// Zeile als Ints, bis auf mindestens fünf Byte mit Nullen aufgefüllt (die Referenz liest über das Ende hinaus Nullen)
    private static func row(_ bits: BitBuffer, _ i: Int) -> [Int] {
        var b = i < bits.rows.count ? bits.rows[i].map(Int.init) : []
        while b.count < 5 { b.append(0) }
        return b
    }

    private static func rev(_ x: Int) -> Int { Int(SensorBits.reverse8(UInt8(truncatingIfNeeded: x))) }
    private static func bcd(_ x: Int) -> Int { ((x & 0xF0) >> 4) * 10 + (x & 0x0F) }

    // MARK: Alecto V1

    private static func alectoChecksum(_ b: [Int]) -> Bool {
        var csum = 0
        for i in 0..<4 {
            let t = rev(b[i])
            csum += (t & 0xF) + ((t & 0xF0) >> 4)
        }
        csum = (b[1] & 0x7F) == 0x6C ? csum + 7 : 0xF - csum
        csum = rev((csum & 0xF) << 4)
        return csum == (b[4] >> 4)
    }

    /// Vor Prologue (Priorität 10): beide haben 36 Bit lange, wiederholte Zeilen; die Prüfsumme (4 Bit), die BCD-Feuchte und die Gleichheit mehrerer Zeilen
    /// sprechen für Alecto, Prologue hat keine Prüfsumme
    static let alecto = SensorDevice("AlectoV1 (Alecto WS3500/WS4500, Ventus W155/W044, Oregon)", SlicerTiming(.ookPPM, short: 2000, long: 4000, reset: 10000, gap: 7000), priority: 9) { bits in
        guard bits.numRows >= 6, bits.bitsPerRow[1] == 36 else { return [] }
        let r1 = row(bits, 1), r2 = row(bits, 2), r3 = row(bits, 3), r4 = row(bits, 4), r5 = row(bits, 5), r6 = row(bits, 6)
        if r1[0] != r5[0] || r2[0] != r6[0] || (r1[4] & 0xF) != 0 || (r5[4] & 0xF) != 0 || r5[0] == 0 || r5[1] == 0 { return [] }
        guard alectoChecksum(r1), alectoChecksum(r5) else { return [] }
        let b = r1
        let batteryLow = (b[1] & 0x80) >> 7
        let msgType = (b[1] & 0x60) >> 5
        let msgRain = (b[1] & 0x0F) == 0x0C
        let channel = (b[0] & 0xC) >> 2
        let sensorID = rev(b[0])
        func start(_ model: String) -> SensorReading {
            var m = SensorReading(model: model)
            m.add("id", sensorID)
            m.add("channel", channel)
            m.add("battery_ok", batteryLow == 0 ? 1 : 0)
            return m
        }
        if msgType == 3 && !msgRain {
            var skip = -1
            if (b[1] & 0xE) == 0x8 && b[2] == 0 { skip = 0 } else if (b[1] & 0xE) == 0xE { skip = 4 }
            guard skip >= 0 else { return [] }
            let a = row(bits, 1 + skip), g = row(bits, 5 + skip)
            let speed = Double(rev(a[3])), gust = Double(rev(g[3]))
            let direction = (rev(g[2]) << 1) | (g[1] & 1)
            var m = start("AlectoV1-Wind")
            m.add("wind_avg_m_s", Double(Float(speed) * 0.2))
            m.add("wind_max_m_s", Double(Float(gust) * 0.2))
            m.add("wind_dir_deg", direction)
            m.add("mic", "CHECKSUM")
            return [m]
        } else if msgType == 3 && msgRain {
            var m = start("AlectoV1-Rain")
            m.add("rain_mm", Double((rev(b[3]) << 8) | rev(b[2])) * 0.25)
            m.add("mic", "CHECKSUM")
            return [m]
        } else if msgType != 3 && r2[0] == r3[0] && r3[0] == r4[0] && r4[0] == r5[0] && r5[0] == r6[0] && (r3[4] & 0xF) == 0 && (r5[4] & 0xF) == 0 {
            let raw = Int(Int16(truncatingIfNeeded: (rev(b[1]) & 0xF0) | (rev(b[2]) << 8)))
            let humidity = bcd(rev(b[3]))
            guard humidity <= 100 else { return [] }                      // Prologue wird manchmal für Alecto gehalten
            var m = start("AlectoV1-Temperature")
            m.add("temperature_C", Double(Float(raw >> 4) * 0.1))
            m.add("humidity", humidity)
            m.add("mic", "CHECKSUM")
            return [m]
        }
        return []
    }

    // MARK: Ambient Weather TX-8300 (TFA 30.3211.02)

    private static func tx8300Check(_ b: [Int]) -> Int {
        var x = 0, y = 0
        for i in 0..<4 {
            x += (b[i] & 0xF) + ((b[i] & 0xF0) >> 4)
            y += (b[i] & 0x5) + ((b[i] & 0x50) >> 4)
        }
        let c0 = (~x) & 0xF, c1 = (~y) & 0xF
        return (c0 << 4) | c1
    }

    static let tx8300 = SensorDevice("Ambient Weather TX-8300, TFA 30.3211.02", SlicerTiming(.ookPPM, short: 2000, long: 4000, reset: 8000, gap: 6500)) { bits in
        guard bits.numRows > 0, bits.bitsPerRow[0] == 74 else { return [] }
        var b = bits.extractBytes(row: 0, pos: 2, len: 72).map(Int.init)                // zwei Bit Zähler vorweg
        for i in 4...7 { b[i] ^= 0xFF }                                                // umgekehrte Bytes zurückdrehen
        b[0] = (b[0] & 0x7F) | (b[4] & 0x80)
        guard b[0] == b[4], b[1] == b[5], b[2] == b[6], b[3] == b[7], tx8300Check(b) == b[8] else { return [] }
        let temp = Double(b[2] & 0x0F) * 10 + Double((b[3] & 0xF0) >> 4) + Double(Float(b[3] & 0x0F) * 0.1)
        let minus = (b[1] & 0x08) >> 3
        let humidityValid = ((b[0] & 0xF0) >> 4) <= 9 && (b[0] & 0x0F) <= 9
        var m = SensorReading(model: "AmbientWeather-TX8300")
        m.add("id", ((b[1] & 0x07) << 4) | ((b[2] & 0xF0) >> 4))
        m.add("channel", (b[1] & 0x30) >> 4)
        m.add("battery", (b[1] & 0xC0) >> 6)
        m.add("temperature_C", minus == 1 ? -temp : temp)
        if humidityValid { m.add("humidity", ((b[0] & 0xF0) >> 4) * 10 + (b[0] & 0x0F)) }
        m.add("mic", "CHECKSUM")
        return [m]
    }

    // MARK: TFA 30.3151 (FSK, Fine-Offset-WH1050-Aufbau)

    private static let wh1050Preamble: [UInt8] = [0xAA, 0x2D, 0xD4]

    /// Priorität 10: Fine Offset/Ecowitt WH55 beginnt ähnlich und geht vor
    static let tfa303151 = SensorDevice("TFA 30.3151 Wetterstation", SlicerTiming(.fskPCM, short: 60, long: 60, reset: 2500), bands: [.mhz868, .mhz433], priority: 10) { bits in
        guard bits.numRows == 1 else { return [] }
        let n = bits.bitsPerRow[0]
        guard n > 112, n < 760 else { return [] }
        var out: [SensorReading] = []
        var pos = 0
        while true {
            pos = bits.search(row: 0, start: pos, pattern: wh1050Preamble, patternBits: 24)
            guard pos + 72 <= n else { break }
            let br = bits.extractBytes(row: 0, pos: pos + 24, len: 72)
            pos += 123
            guard br.count >= 9, SensorBits.crc8(Array(br[0..<9]), poly: 0x31, initial: 0) == 0 else { continue }
            let b = br.map(Int.init)
            let type = b[0] >> 4
            var m = SensorReading(model: "TFA-303151")
            let id = ((b[0] << 4) & 0xF0) | (b[1] >> 4)
            let batteryLow = b[1] & 0x04
            if type == 5 {
                let tempRaw = ((b[1] & 0x03) << 8) | b[2]
                var temperature = Double(Float(tempRaw) * 0.1)
                if (b[1] & 0x08) >> 3 == 1 { temperature = -temperature }
                m.add("id", id)
                m.add("msg_type", type)
                m.add("battery_ok", batteryLow == 0 ? 1 : 0)
                m.add("temperature_C", temperature)
                m.add("humidity", b[3])
                m.add("wind_avg_km_h", Double(Float(b[4]) * 0.34 * 3.6))
                m.add("wind_max_km_h", Double(Float(b[5]) * 0.34 * 3.6))
                m.add("rain_mm", Double(Float((b[6] << 8) | b[7]) * 0.5))
                m.add("mic", "CRC")
            } else if type == 6 {
                let hours = ((b[2] & 0x30) >> 4) * 10 + (b[2] & 0x0F)
                let minutes = ((b[3] & 0xF0) >> 4) * 10 + (b[3] & 0x0F)
                let seconds = ((b[4] & 0xF0) >> 4) * 10 + (b[4] & 0x0F)
                let year = ((b[5] & 0xF0) >> 4) * 10 + (b[5] & 0x0F) + 2000
                let month = ((b[6] & 0x10) >> 4) * 10 + (b[6] & 0x0F)
                let day = ((b[7] & 0xF0) >> 4) * 10 + (b[7] & 0x0F)
                m.add("id", id)
                m.add("msg_type", type)
                m.add("battery_ok", batteryLow == 0 ? 1 : 0)
                m.add("radio_clock", String(format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, hours, minutes, seconds))
                m.add("mic", "CRC")
            } else { continue }
            out.append(m)
        }
        return out
    }
}
