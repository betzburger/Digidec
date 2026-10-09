// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Oregon Scientific (Protokolle 2.1 und 3.0, Manchester): Thermo-/Hygrosensoren (THGR122N, THGR228N, THGR328N, THGR810, THN132N, THN129 …),
// Baro-Thermo-Hygro (BTHR918, BTHR968, BTHGN129), Wind (WGR800, WGR968), Regen (PCR800, RGR968), UV (UVR128, UV800), Funkuhr.
// Aufbau nach rtl_433 (`oregon_scientific.c`, siehe THIRD_PARTY.md); Messgeräte für Strom (Owl CM130/160/180) fehlen.

enum SensorDevicesOregon {
    // Gerätekennungen
    private static let idTHGR122N = 0x1D20, idTHGR968 = 0x1D30, idBTHR918 = 0x5D50, idBHTR968 = 0x5D60, idRGR968 = 0x2D10
    private static let idTHR228N = 0xEC40, idAWR129 = 0xEC41, idRTGN318 = 0x0CC3, idTHGR810 = 0xF024, idTHGR810a = 0xF8B4
    private static let idTHN802 = 0xC844, idPCR800 = 0x2914, idPCR800a = 0x2D14, idWGR800 = 0x1984, idWGR800a = 0x1994, idWGR968 = 0x3D00
    private static let idUV800 = 0xD874, idTHN129 = 0xCC43, idRTHN129 = 0x0CD3, idBTHGN129 = 0x5D53, idUVR128 = 0xEC70, idTHGR328N = 0xCC23
    private static let rtgr328 = [0xDCC3, 0xCCC3, 0xBCC3, 0xACC3, 0x9CC3]

    private static func temperature(_ m: [Int]) -> Double {
        var t = Double(((m[5] >> 4) * 100) + ((m[4] & 0x0F) * 10) + ((m[4] >> 4) & 0x0F)) / 10
        t += Double(m[5] & 0x07) * 100
        if m[5] & 0x08 != 0 { t = -t }
        return t
    }
    private static func humidity(_ m: [Int]) -> Int { (m[6] & 0x0F) * 10 + (m[6] >> 4) }
    private static func uv(_ m: [Int]) -> Int { (m[4] & 0x0F) * 10 + (m[4] >> 4) }
    private static func rainRate(_ m: [Int]) -> Double { Double((m[5] & 0x0F) * 1000 + (m[5] >> 4) * 100 + (m[4] & 0x0F) * 10 + (m[4] >> 4)) / 100 }
    private static func totalRain(_ m: [Int]) -> Double {
        Double(m[8] & 0x0F) * 100 + Double((m[8] >> 4) & 0x0F) * 10 + Double(m[7] & 0x0F) + Double((m[7] >> 4) & 0x0F) / 10
            + Double(m[6] & 0x0F) / 100 + Double((m[6] >> 4) & 0x0F) / 1000
    }

    /// Prüfsumme (Summe der Halbbytes, die zwei Halbbytes der Summe vertauscht); `true` = in Ordnung
    private static func checksumOK(_ msg: [Int], _ idx: Int) -> Bool {
        var sum = 0
        var i = 0
        while i < idx - 1 { let v = msg[i >> 1]; sum += (v >> 4) + (v & 0x0F); i += 2 }
        let checksum: Int
        if idx & 1 != 0 {
            sum += msg[idx >> 1] >> 4
            checksum = (msg[idx >> 1] & 0x0F) | (msg[(idx + 1) >> 1] & 0xF0)
        } else {
            checksum = (msg[idx >> 1] >> 4) | ((msg[idx >> 1] & 0x0F) << 4)
        }
        return sum & 0xFF == checksum
    }

    private static func v2Valid(_ msg: [Int], expected: Int, bits: Int, nibbles: Int) -> Bool { expected == bits && checksumOK(msg, nibbles) }

    private static func base(_ model: String, _ id: Int, _ channel: Int, _ batteryLow: Int) -> SensorReading {
        var m = SensorReading(model: model)
        m.add("id", id); m.add("channel", channel); m.add("battery_ok", batteryLow == 0 ? 1 : 0)
        return m
    }

    // MARK: Protokoll 2.1

    private static func decodeV2(_ bitsIn: BitBuffer) -> [SensorReading] {
        let b = bitsIn.rows[0].map(Int.init) + [Int](repeating: 0, count: 8)
        guard (b[1] == 0x55 && b[2] == 0x55) || (b[1] == 0xAA && b[2] == 0xAA) else { return [] }
        var data = BitBuffer()
        let syncTest = UInt32(truncatingIfNeeded: b[3] << 24 | b[4] << 16 | b[5] << 8 | b[6])
        for patternIndex in 0..<8 {
            let mask = UInt32(0xFFFF0000) >> UInt32(patternIndex)
            let pattern = UInt32(0x55990000) >> UInt32(patternIndex)
            let pattern2 = UInt32(0xAA990000) >> UInt32(patternIndex)
            if syncTest & mask != pattern && syncTest & mask != pattern2 { continue }
            _ = bitsIn.manchesterDecode(row: 0, start: patternIndex + 40, into: &data, max: 173)
            if data.numRows > 0 { data.rows[0] = SensorBits.reflectNibbles(data.rows[0]) }
            break
        }
        let msgBits = data.numRows > 0 ? data.bitsPerRow[0] : 0
        let msg = (data.numRows > 0 ? data.rows[0].map(Int.init) : []) + [Int](repeating: 0, count: 44)
        let sensorID = msg[0] << 8 | msg[1]
        let channel = (msg[2] >> 4) & 0x0F
        let deviceID = (msg[2] & 0x0F) | (msg[3] & 0xF0)
        let batteryLow = (msg[3] >> 2) & 1

        if sensorID == idTHGR122N || sensorID == idTHGR968 {
            guard v2Valid(msg, expected: 68, bits: msgBits, nibbles: 15) || v2Valid(msg, expected: 76, bits: msgBits, nibbles: 15) else { return [] }
            let model = sensorID == idTHGR968 ? "Oregon-THGR968" : msgBits == 76 ? "Oregon-THGR122N" : "Oregon-THGR228N"
            var m = base(model, deviceID, channel, batteryLow)
            m.add("temperature_C", temperature(msg)); m.add("humidity", humidity(msg)); m.add("mic", "CHECKSUM")
            return [m]
        }
        if sensorID == idWGR968 {
            guard v2Valid(msg, expected: 94, bits: msgBits, nibbles: 17) else { return [] }
            let quadrant = Double((msg[4] & 0x0F) * 10 + ((msg[4] >> 4) & 0x0F) + ((msg[5] >> 4) & 0x0F) * 100)
            let avg = Double((msg[7] >> 4) & 0x0F) / 10 + Double(msg[7] & 0x0F) + Double((msg[8] >> 4) & 0x0F) / 10
            let gust = Double(msg[5] & 0x0F) / 10 + Double((msg[6] >> 4) & 0x0F) + Double(msg[6] & 0x0F) / 10
            var m = base("Oregon-WGR968", deviceID, channel, batteryLow)
            m.add("wind_max_m_s", gust); m.add("wind_avg_m_s", avg); m.add("wind_dir_deg", quadrant); m.add("mic", "CHECKSUM")
            return [m]
        }
        if sensorID == idBHTR968 {
            guard v2Valid(msg, expected: 92, bits: msgBits, nibbles: 19) else { return [] }
            var m = base("Oregon-BHTR968", deviceID, channel, batteryLow)
            m.add("temperature_C", temperature(msg)); m.add("humidity", humidity(msg))
            m.add("pressure_hPa", Double(((msg[7] & 0x0F) | (msg[8] & 0xF0)) + 856)); m.add("mic", "CHECKSUM")
            return [m]
        }
        if sensorID == idBTHR918 {
            guard v2Valid(msg, expected: 84, bits: msgBits, nibbles: 19) else { return [] }
            var m = base("Oregon-BTHR918", deviceID, channel, batteryLow)
            m.add("temperature_C", temperature(msg)); m.add("humidity", humidity(msg))
            m.add("pressure_hPa", Double(((msg[7] & 0x0F) | (msg[8] & 0xF0)) + 795)); m.add("mic", "CHECKSUM")
            return [m]
        }
        if sensorID == idRGR968 {
            guard v2Valid(msg, expected: 80, bits: msgBits, nibbles: 16) else { return [] }
            let rate = Double((msg[4] & 0x0F) * 100 + (msg[4] >> 4) * 10 + ((msg[5] >> 4) & 0x0F)) / 10
            let total = Double((msg[7] & 0xF) * 10000 + (msg[7] >> 4) * 1000 + (msg[6] & 0xF) * 100 + (msg[6] >> 4) * 10 + (msg[5] & 0xF)) / 10
            var m = base("Oregon-RGR968", deviceID, channel, batteryLow)
            m.add("rain_rate_mm_h", rate); m.add("rain_mm", total); m.add("mic", "CHECKSUM")
            return [m]
        }
        if (sensorID == idTHR228N || sensorID == idAWR129) && msgBits == 76 {
            guard v2Valid(msg, expected: 76, bits: msgBits, nibbles: 12) else { return [] }
            var m = base(sensorID == idTHR228N ? "Oregon-THR228N" : "Oregon-AWR129", deviceID, channel, batteryLow)
            m.add("temperature_C", temperature(msg)); m.add("mic", "CHECKSUM")
            return [m]
        }
        if sensorID == idTHR228N && msgBits == 64 {                                   // THN132N (gleiche Kennung, kürzeres Telegramm)
            guard v2Valid(msg, expected: 64, bits: msgBits, nibbles: 12) else { return [] }
            guard (msg[5] >> 4) & 0x0F <= 9, msg[4] & 0x0F <= 9, (msg[4] >> 4) & 0x0F <= 9 else { return [] }
            let t = temperature(msg)
            guard t <= 70, t >= -50 else { return [] }
            var m = base("Oregon-THN132N", deviceID, channel, batteryLow)
            m.add("temperature_C", t); m.add("mic", "CHECKSUM")
            return [m]
        }
        if sensorID & 0x0FFF == idRTGN318 && msgBits == 80 {                          // RTGN129
            guard v2Valid(msg, expected: 80, bits: msgBits, nibbles: 15) else { return [] }
            var m = base("Oregon-RTGN129", deviceID, channel, batteryLow)
            m.add("temperature_C", temperature(msg)); m.add("humidity", humidity(msg)); m.add("mic", "CHECKSUM")
            return [m]
        }
        if rtgr328.contains(sensorID) && msgBits == 173 {
            guard v2Valid(msg, expected: 173, bits: msgBits, nibbles: 15) else { return [] }
            var m = base("Oregon-RTGR328N", deviceID, channel, batteryLow)
            m.add("temperature_C", temperature(msg)); m.add("humidity", humidity(msg)); m.add("mic", "CHECKSUM")
            return [m]
        }
        if sensorID == 0x8CE3 || sensorID == 0x8AE3 {                                 // RTGR328N Funkuhr
            guard v2Valid(msg, expected: 100, bits: msgBits, nibbles: 21) else { return [] }
            let year = (msg[9] & 0x0F) * 10 + ((msg[9] & 0xF0) >> 4) + 2000
            let month = (msg[8] & 0xF0) >> 4
            let day = (msg[7] & 0x0F) * 10 + ((msg[7] & 0xF0) >> 4)
            let hours = (msg[6] & 0x0F) * 10 + ((msg[6] & 0xF0) >> 4)
            let minutes = (msg[5] & 0x0F) * 10 + ((msg[5] & 0xF0) >> 4)
            let seconds = (msg[4] & 0x0F) * 10 + ((msg[4] & 0xF0) >> 4)
            var m = base("Oregon-RTGR328N", deviceID, channel, batteryLow)
            m.add("radio_clock", String(format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, hours, minutes, seconds)); m.add("mic", "CHECKSUM")
            return [m]
        }
        if sensorID & 0x0FFF == idRTGN318 {
            if msgBits == 76 && v2Valid(msg, expected: 76, bits: msgBits, nibbles: 15) {
                var m = base("Oregon-RTGN318", deviceID, channel, batteryLow)
                m.add("temperature_C", temperature(msg)); m.add("humidity", humidity(msg)); m.add("mic", "CHECKSUM")
                return [m]
            }
            return []
        }
        if sensorID == idTHN129 || sensorID & 0x0FFF == idRTHN129 {
            if v2Valid(msg, expected: 68, bits: msgBits, nibbles: 12) {
                var m = base(sensorID == idTHN129 ? "Oregon-THN129" : "Oregon-RTHN129", deviceID, channel, batteryLow)
                m.add("temperature_C", temperature(msg)); m.add("mic", "CHECKSUM")
                return [m]
            }
            return []
        }
        if sensorID == idBTHGN129 {
            guard v2Valid(msg, expected: 92, bits: msgBits, nibbles: 19) else { return [] }
            var m = base("Oregon-BTHGN129", deviceID, channel, batteryLow)
            m.add("temperature_C", temperature(msg)); m.add("humidity", humidity(msg))
            m.add("pressure_hPa", Double(((msg[7] & 0x0F) | (msg[8] & 0xF0)) * 2 + (msg[8] & 0x01) + 600)); m.add("mic", "CHECKSUM")
            return [m]
        }
        if sensorID == idUVR128 && msgBits == 148 {
            guard v2Valid(msg, expected: 148, bits: msgBits, nibbles: 12) else { return [] }
            guard (msg[4] >> 4) & 0x0F <= 9, msg[4] & 0x0F <= 9 else { return [] }
            let index = uv(msg)
            guard index <= 25 else { return [] }
            var m = SensorReading(model: "Oregon-UVR128")
            m.add("id", deviceID); m.add("uvi", Double(index)); m.add("battery_ok", batteryLow == 0 ? 1 : 0); m.add("mic", "CHECKSUM")
            return [m]
        }
        if sensorID == idTHGR328N {
            guard v2Valid(msg, expected: 173, bits: msgBits, nibbles: 15) else { return [] }
            var m = base("Oregon-THGR328N", deviceID, channel, batteryLow)
            m.add("temperature_C", temperature(msg)); m.add("humidity", humidity(msg)); m.add("mic", "CHECKSUM")
            return [m]
        }
        return []
    }

    // MARK: Protokoll 3.0

    private static func decodeV3(_ bits: BitBuffer) -> [SensorReading] {
        let b = bits.rows[0].map(Int.init) + [Int](repeating: 0, count: 8)
        let preambleOne = (b[0] & 0xF) == 0x0F && b[1] == 0xFF && (b[2] & 0xC0) == 0xC0
        let preambleZero = (b[0] & 0xF) == 0x00 && b[1] == 0x00 && (b[2] & 0xC0) == 0x00
        guard preambleOne || preambleZero else { return [] }
        let n = bits.bitsPerRow[0]
        let osPos = bits.search(row: 0, start: 0, pattern: [0x00, 0x05], patternBits: 16) + 16
        let altPos = bits.search(row: 0, start: 0, pattern: [0xFF, 0xF5], patternBits: 16) + 16
        var msgPos = 0, msgLen = 0
        if n - osPos >= 7 * 8 { msgPos = osPos; msgLen = n - osPos }
        else if n - altPos >= 7 * 8 { msgPos = altPos; msgLen = n - altPos }
        guard msgLen > 0, msgLen <= 44 * 8 else { return [] }
        let msg = SensorBits.reflectNibbles(bits.extractBytes(row: 0, pos: msgPos, len: msgLen)).map(Int.init) + [Int](repeating: 0, count: 44)
        let sensorID = msg[0] << 8 | msg[1]
        let channel = (msg[2] >> 4) & 0x0F
        let deviceID = (msg[2] & 0x0F) | (msg[3] & 0xF0)
        let batteryLow = (msg[3] >> 2) & 1

        if sensorID & 0xF0FF == idTHGR810 || sensorID == idTHGR810a {
            guard checksumOK(msg, 15) else { return [] }
            guard (msg[5] >> 4) & 0x0F <= 9, msg[4] & 0x0F <= 9, (msg[4] >> 4) & 0x0F <= 9, msg[6] & 0x0F <= 9, (msg[6] >> 4) & 0x0F <= 9 else { return [] }
            let t = temperature(msg)
            guard t <= 70, t >= -50 else { return [] }
            var m = SensorReading(model: "Oregon-THGR810")
            m.add("id", deviceID); m.add("channel", channel)
            if msg[0] & 1 != 0 { m.add("button", 1) }
            m.add("battery_ok", batteryLow == 0 ? 1 : 0); m.add("temperature_C", t); m.add("humidity", humidity(msg)); m.add("mic", "CHECKSUM")
            return [m]
        }
        if sensorID == idTHN802 {
            guard checksumOK(msg, 12) else { return [] }
            var m = base("Oregon-THN802", deviceID, channel, batteryLow)
            m.add("temperature_C", temperature(msg)); m.add("mic", "CHECKSUM")
            return [m]
        }
        if sensorID == idUV800 {
            guard checksumOK(msg, 13) else { return [] }
            var m = base("Oregon-UV800", deviceID, channel, batteryLow)
            m.add("uvi", Double(uv(msg))); m.add("mic", "CHECKSUM")
            return [m]
        }
        if sensorID == idPCR800 || sensorID == idPCR800a {
            guard checksumOK(msg, 18) else { return [] }
            if sensorID == idPCR800 {
                for k in 4...8 where msg[k] & 0x0F > 9 || (msg[k] >> 4) & 0x0F > 9 { return [] }
            }
            var m = base(sensorID == idPCR800 ? "Oregon-PCR800" : "Oregon-PCR800a", deviceID, channel, batteryLow)
            m.add("rain_rate_in_h", rainRate(msg)); m.add("rain_in", totalRain(msg)); m.add("mic", "CHECKSUM")
            return [m]
        }
        if sensorID == idWGR800 || sensorID == idWGR800a {
            guard checksumOK(msg, 17) else { return [] }
            guard msg[5] & 0x0F <= 9, (msg[6] >> 4) & 0x0F <= 9, msg[6] & 0x0F <= 9, (msg[7] >> 4) & 0x0F <= 9, msg[7] & 0x0F <= 9, (msg[8] >> 4) & 0x0F <= 9 else { return [] }
            let gust = Double(msg[5] & 0x0F) / 10 + Double((msg[6] >> 4) & 0x0F) + Double(msg[6] & 0x0F) * 10
            let avg = Double((msg[7] >> 4) & 0x0F) / 10 + Double(msg[7] & 0x0F) + Double((msg[8] >> 4) & 0x0F) * 10
            let quadrant = Double((msg[4] >> 4) & 0x0F) * 22.5
            guard gust >= 0, gust <= 56, avg >= 0, avg <= 56 else { return [] }
            var m = base("Oregon-WGR800", deviceID, channel, batteryLow)
            m.add("wind_max_m_s", gust); m.add("wind_avg_m_s", avg); m.add("wind_dir_deg", quadrant); m.add("mic", "CHECKSUM")
            return [m]
        }
        return []
    }

    static let oregon = SensorDevice("Oregon Scientific Wettersensoren", SlicerTiming(.ookManchesterZeroBit, short: 440, reset: 2400)) { bits in
        guard bits.numRows > 0 else { return [] }
        let r = decodeV2(bits)
        return r.isEmpty ? decodeV3(bits) : r
    }

    // MARK: OSv1 und SL109H

    static let osv1 = SensorDevice("Oregon Scientific OSv1 Thermometer", SlicerTiming(.ookOSV1, short: 1465, reset: 14000, gap: 3500, sync: 5780)) { bits in
        var out: [SensorReading] = []
        for row in 0..<bits.numRows where bits.bitsPerRow[row] == 32 {
            let r = bits.rows[row]
            var nibble = [Int](repeating: 0, count: 8)
            var rawCS = 0
            for i in 0..<4 {
                let byte = SensorBits.reverse8(r[i])
                nibble[i * 2] = Int(byte & 0x0F)
                nibble[i * 2 + 1] = Int(byte >> 4)
                if i < 3 { rawCS += nibble[i * 2] + 16 * nibble[i * 2 + 1] }
            }
            if r[0] == 0xFF && r[1] == 0xFF && r[2] == 0xFF && r[3] == 0xFF { continue }
            let checksum = nibble[6] + (nibble[7] << 4)
            let fold = (rawCS & 0xFF) + (rawCS >> 8)
            let alt = (rawCS > 0x180 ? rawCS + 1 : rawCS) & 0xFF
            if checksum == 0 || (checksum != fold && checksum != alt) { continue }
            var t = Double(nibble[2]) * 0.1 + Double(nibble[3]) + Double(nibble[4]) * 10
            if (nibble[5] >> 1) & 1 == 1 { t = -t }
            var m = SensorReading(model: "Oregon-v1")
            m.add("id", nibble[0]); m.add("channel", ((nibble[1] >> 2) & 3) + 1)
            m.add("battery_ok", (nibble[5] >> 3) & 1 == 0 ? 1 : 0)
            m.add("temperature_C", t); m.add("mic", "CHECKSUM")
            out.append(m)
        }
        return out
    }

    static let sl109h = SensorDevice("Oregon Scientific SL109H Thermo-/Hygrosensor", SlicerTiming(.ookPPM, short: 2000, long: 4000, reset: 10000, gap: 5000)) { bits in
        let row = bits.findRepeatedRow(minRepeats: 2, minBits: 38)
        guard row >= 0, bits.bitsPerRow[row] == 38 else { return [] }
        let msg = bits.rows[row].map(Int.init) + [0, 0, 0, 0]
        guard !(msg[0] == 0 && msg[1] == 0 && msg[2] == 0 && msg[3] == 0) else { return [] }
        let chk = msg[0] >> 4
        var b = bits.extractBytes(row: row, pos: 2, len: 36).map(Int.init) + [0, 0, 0, 0, 0]
        b[0] &= 0x3F
        if chk == 0 && b[0] == 0 && b[1] == 0 && b[2] == 0 { return [] }
        guard SensorBits.addNibbles(b[0..<5].map { UInt8($0) }) & 0xF == chk else { return [] }
        let channelCode = b[0] >> 4
        guard channelCode != 3 else { return [] }
        let tens = b[0] & 0x0F, ones = b[1] >> 4
        guard tens <= 9, ones <= 9 else { return [] }
        let raw = Int(Int16(truncatingIfNeeded: ((b[1] & 0x0F) << 12) | (b[2] << 4)))
        let tempC = Double(raw >> 4) * 0.1
        guard tempC >= -20, tempC <= 60 else { return [] }
        var m = SensorReading(model: "Oregon-SL109H")
        m.add("id", ((b[3] & 0x0F) << 4) | (b[4] >> 4))
        m.add("channel", channelCode != 0 ? channelCode : 3)
        m.add("temperature_C", tempC)
        m.add("humidity", 10 * tens + ones)
        m.add("status", b[3] >> 4)
        m.add("mic", "CHECKSUM")
        return [m]
    }
}
