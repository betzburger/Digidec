// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Bresser (auch Froggit, Ventus, Sencor, Ambient Weather, Explore Scientific): Wetterstationen und Außensensoren auf 868,3 MHz,
// FSK mit 124 µs je Bit. 5-in-1 (alt), 6-in-1 (auch neues 5-in-1, 3-in-1 Windmesser, Bodenfeuchte, Thermo-/Hygrosensor, Poolthermometer)
// und 7-in-1 (auch 3-in-1, 8-in-1, Feinstaub, CO₂, HCHO/VOC). Aufbau nach rtl_433 (`bresser_*.c`, siehe THIRD_PARTY.md).

enum SensorDevicesBresser {
    private static func padded(_ b: [UInt8], _ n: Int) -> [Int] { b.map(Int.init) + [Int](repeating: 0, count: max(0, n - b.count)) }

    // MARK: 5-in-1

    static let fiveInOne = SensorDevice("Bresser Wetterstation 5-in-1", SlicerTiming(.fskPCM, short: 124, long: 124, reset: 25000), bands: [.mhz868]) { bits in
        let preamble: [UInt8] = [0xAA, 0xAA, 0xAA, 0x2D, 0xD4]
        guard bits.numRows == 1, bits.bitsPerRow[0] >= 248, bits.bitsPerRow[0] <= 440 else { return [] }
        var start = bits.search(row: 0, start: 0, pattern: preamble, patternBits: 40)
        if start == bits.bitsPerRow[0] { return [] }
        start += 40
        var len = bits.bitsPerRow[0] - start
        if (len + 7) / 8 < 26 { return [] }
        len = min(len, 26 * 8)
        let msg = padded(bits.extractBytes(row: 0, pos: start, len: len), 26)
        for col in 0..<13 where msg[col] ^ msg[col + 13] != 0xFF { return [] }
        let sensorID = msg[14]
        let tempOK = msg[20] & 0x0F <= 9
        var tempRaw = (msg[20] & 0x0F) + ((msg[20] & 0xF0) >> 4) * 10 + (msg[21] & 0x0F) * 100
        if msg[25] & 0x0F != 0 { tempRaw = -tempRaw }
        let humOK = msg[22] & 0x0F <= 9
        let humidity = (msg[22] & 0x0F) + ((msg[22] & 0xF0) >> 4) * 10
        let dir = Double((msg[17] & 0xF0) >> 4) * 22.5
        let gust = Double(((msg[17] & 0x0F) << 8) + msg[16]) * 0.1
        let wind = Double((msg[18] & 0x0F) + ((msg[18] & 0xF0) >> 4) * 10 + (msg[19] & 0x0F) * 100) * 0.1
        var rain = Double((msg[23] & 0x0F) + ((msg[23] & 0xF0) >> 4) * 10 + (msg[24] & 0x0F) * 100 + ((msg[24] & 0xF0) >> 4) * 1000) * 0.1
        let batteryLow = msg[25] & 0x80 != 0
        let type = msg[15] & 0x7F
        if type >= 0x39 && type <= 0x3B {
            rain *= 2.5
            var m = SensorReading(model: "Bresser-ProRainGauge")
            m.add("id", sensorID)
            m.add("battery_ok", batteryLow ? 0 : 1)
            if tempOK { m.add("temperature_C", Double(tempRaw) * 0.1) }
            m.add("rain_mm", rain)
            m.add("mic", "CHECKSUM")
            return [m]
        }
        var m = SensorReading(model: "Bresser-5in1")
        m.add("id", sensorID)
        m.add("battery_ok", batteryLow ? 0 : 1)
        if tempOK { m.add("temperature_C", Double(tempRaw) * 0.1) }
        if humOK { m.add("humidity", humidity) }
        m.add("wind_max_m_s", gust)
        m.add("wind_avg_m_s", wind)
        m.add("wind_dir_deg", dir)
        m.add("rain_mm", rain)
        m.add("mic", "CHECKSUM")
        return [m]
    }

    // MARK: 6-in-1

    static let sixInOne = SensorDevice("Bresser 6-in-1, 3-in-1 Windmesser, Thermo-/Hygrosensor, Bodenfeuchte, Pool", SlicerTiming(.fskPCM, short: 124, long: 124, reset: 25000), bands: [.mhz868]) { bits in
        let preamble: [UInt8] = [0xAA, 0xAA, 0x2D, 0xD4]
        let moistureMap = [0, 7, 13, 20, 27, 33, 40, 47, 53, 60, 67, 73, 80, 87, 93, 99]
        guard bits.numRows == 1, bits.bitsPerRow[0] >= 160, bits.bitsPerRow[0] <= 440 else { return [] }
        let start = bits.search(row: 0, start: 0, pattern: preamble, patternBits: 32) + 32
        guard start < bits.bitsPerRow[0], bits.bitsPerRow[0] - start >= 18 * 8 else { return [] }
        var msg = padded(bits.extractBytes(row: 0, pos: start, len: 18 * 8), 18)
        let digest = Int(SensorBits.lfsrDigest16(msg[2..<17].map { UInt8($0) }, gen: 0x8810, key: 0x5412))
        guard (msg[0] << 8 | msg[1]) == digest else { return [] }
        guard SensorBits.addBytes(msg[2..<18].map { UInt8($0) }) & 0xFF == 0xFF else { return [] }
        let id = msg[2] << 24 | msg[3] << 16 | msg[4] << 8 | msg[5]
        let sType = msg[6] >> 4
        let startup = (msg[6] >> 3) & 1
        let chan = msg[6] & 7
        let battery = (msg[13] >> 1) & 1
        let tempOK = msg[12] <= 0x99 && (msg[13] & 0xF0) <= 0x90
        let tempRaw = (msg[12] >> 4) * 100 + (msg[12] & 0x0F) * 10 + (msg[13] >> 4)
        var tempC = Double(tempRaw) * 0.1
        if (msg[13] >> 3) & 1 == 1 { tempC = Double(tempRaw - 1000) * 0.1 }
        if tempC < -50 { tempC = -Double(tempRaw) * 0.1 }
        let humidity = (msg[14] >> 4) * 10 + (msg[14] & 0x0F)
        var uvOK = msg[16] & 0x0F == 0 && (~msg[15] & 0xFF) <= 0x99 && (~msg[16] & 0xF0) <= 0x90
        let uvRaw = ((~msg[15] & 0xF0) >> 4) * 100 + (~msg[15] & 0x0F) * 10 + ((~msg[16] & 0xF0) >> 4)
        let flags = msg[16] & 0x0F
        msg[7] ^= 0xFF; msg[8] ^= 0xFF; msg[9] ^= 0xFF
        var windOK = msg[7] <= 0x99 && msg[8] <= 0x99 && msg[9] <= 0x99
        let gust = Double((msg[7] >> 4) * 100 + (msg[7] & 0x0F) * 10 + (msg[8] >> 4)) * 0.1
        let avg = Double((msg[9] >> 4) * 100 + (msg[9] & 0x0F) * 10 + (msg[8] & 0x0F)) * 0.1
        let dir = ((msg[10] & 0xF0) >> 4) * 100 + (msg[10] & 0x0F) * 10 + ((msg[11] & 0xF0) >> 4)
        msg[12] ^= 0xFF; msg[13] ^= 0xFF; msg[14] ^= 0xFF
        let rainOK = msg[16] & 1 == 1
        let rainRaw = (msg[12] >> 4) * 100000 + (msg[12] & 0x0F) * 10000 + (msg[13] >> 4) * 1000 + (msg[13] & 0x0F) * 100 + (msg[14] >> 4) * 10 + (msg[14] & 0x0F)
        if sType == 2 || sType == 4 { windOK = false; uvOK = false }
        var moisture = -1
        if sType == 4 && tempOK && humidity >= 1 && humidity <= 16 { moisture = moistureMap[humidity - 1] }
        var m = SensorReading(model: "Bresser-6in1")
        m.add("id", id)
        m.add("channel", chan)
        if !rainOK { m.add("battery_ok", battery) }
        if tempOK { m.add("temperature_C", tempC) }
        if tempOK && moisture < 0 { m.add("humidity", humidity) }
        m.add("sensor_type", sType)
        if moisture >= 0 { m.add("moisture", moisture) }
        if windOK {
            m.add("wind_max_m_s", gust)
            m.add("wind_avg_m_s", avg)
            m.add("wind_dir_deg", dir)
        }
        if rainOK { m.add("rain_mm", Double(rainRaw) * 0.1) }
        if uvOK { m.add("uvi", Double(uvRaw) * 0.1) }
        if startup != 0 { m.add("startup", startup) }
        m.add("flags", flags)
        m.add("mic", "CRC")
        return [m]
    }

    // MARK: 7-in-1

    static let sevenInOne = SensorDevice("Bresser 7-in-1 (auch 3-in-1, 8-in-1), Feinstaub, CO₂, HCHO/VOC", SlicerTiming(.fskPCM, short: 124, long: 124, reset: 25000), bands: [.mhz868]) { bits in
        let preamble: [UInt8] = [0xAA, 0xAA, 0xAA, 0x2D, 0xD4]
        guard bits.numRows == 1, bits.bitsPerRow[0] >= 160 else { return [] }
        let start = bits.search(row: 0, start: 0, pattern: preamble, patternBits: 40) + 40
        guard start < bits.bitsPerRow[0], start + 21 * 8 < bits.bitsPerRow[0] else { return [] }
        var msg = padded(bits.extractBytes(row: 0, pos: start, len: 25 * 8), 25)
        guard msg[21] != 0 else { return [] }
        let sType = msg[6] >> 4
        let nStartup = (msg[6] & 0x08) >> 3
        let chan = msg[6] & 0x07
        for i in 0..<25 { msg[i] ^= 0xAA }
        let chk = msg[0] << 8 | msg[1]
        let digest = Int(SensorBits.lfsrDigest16(msg[2..<25].map { UInt8($0) }, gen: 0x8810, key: 0xBA95))
        guard chk ^ digest == 0x6DF1 else { return [] }
        let id = msg[2] << 8 | msg[3]
        let flags = msg[15] & 0x0F
        let batteryLow = flags & 0x06 == 0x06
        let startup = nStartup == 0
        func bcd(_ b: Int) -> Int { (b >> 4) * 10 + (b & 0x0F) }
        switch sType {
        case 1, 12, 13:
            let wdir = (msg[4] >> 4) * 100 + (msg[4] & 0x0F) * 10 + (msg[5] >> 4)
            let wgst = (msg[7] >> 4) * 100 + (msg[7] & 0x0F) * 10 + (msg[8] >> 4)
            let wavg = (msg[8] & 0x0F) * 100 + (msg[9] >> 4) * 10 + (msg[9] & 0x0F)
            let rainRaw = (msg[10] >> 4) * 100000 + (msg[10] & 0x0F) * 10000 + (msg[11] >> 4) * 1000 + (msg[11] & 0x0F) * 100 + (msg[12] >> 4) * 10 + (msg[12] & 0x0F)
            let tempRaw = (msg[14] >> 4) * 100 + (msg[14] & 0x0F) * 10 + (msg[15] >> 4)
            var tempC = Double(tempRaw) * 0.1
            if tempRaw > 600 { tempC = Double(tempRaw - 1000) * 0.1 }
            let humidity = bcd(msg[16])
            let light = (msg[17] >> 4) * 100000 + (msg[17] & 0x0F) * 10000 + (msg[18] >> 4) * 1000 + (msg[18] & 0x0F) * 100 + (msg[19] >> 4) * 10 + (msg[19] & 0x0F)
            let uvRaw = (msg[20] >> 4) * 100 + (msg[20] & 0x0F) * 10 + (msg[21] >> 4)
            let windLightOK = sType != 12
            var tglobe: Double?
            if sType == 13, (msg[23] >> 4) < 10 { tglobe = Double((msg[22] >> 4) * 10 + (msg[22] & 0x0F)) + Double(msg[23] >> 4) * 0.1 }
            var m = SensorReading(model: "Bresser-7in1")
            m.add("id", id)
            if startup { m.add("startup", 1) }
            m.add("temperature_C", tempC)
            m.add("humidity", humidity)
            if windLightOK {
                m.add("wind_max_m_s", Double(wgst) * 0.1)
                m.add("wind_avg_m_s", Double(wavg) * 0.1)
                m.add("wind_dir_deg", wdir)
            }
            m.add("rain_mm", Double(rainRaw) * 0.1)
            if windLightOK {
                m.add("light_klx", Double(light) * 0.001)
                m.add("light_lux", Double(light))
                m.add("uvi", Double(uvRaw) * 0.1)
            }
            if let tglobe { m.add("temperature_1_C", tglobe) }
            m.add("battery_ok", batteryLow ? 0 : 1)
            m.add("mic", "CRC")
            return [m]
        case 8:
            let pm25 = (msg[10] & 0x0F) * 1000 + (msg[11] >> 4) * 100 + (msg[11] & 0x0F) * 10 + (msg[12] >> 4)
            let pm10 = (msg[12] & 0x0F) * 1000 + (msg[13] >> 4) * 100 + (msg[13] & 0x0F) * 10 + (msg[14] >> 4)
            var m = SensorReading(model: "Bresser-7in1")
            m.add("id", id)
            m.add("channel", chan)
            if startup { m.add("startup", 1) }
            m.add("battery_ok", batteryLow ? 0 : 1)
            if msg[10] & 0x0F != 0x0F { m.add("pm2_5_ug_m3", pm25) }
            if msg[12] & 0x0F != 0x0F { m.add("pm10_0_ug_m3", pm10) }
            m.add("mic", "CRC")
            return [m]
        case 10:
            let co2 = (msg[4] >> 4) * 1000 + (msg[4] & 0x0F) * 100 + (msg[5] >> 4) * 10 + (msg[5] & 0x0F)
            var m = SensorReading(model: "Bresser-CO2")
            m.add("id", id)
            m.add("channel", chan)
            if startup { m.add("startup", 1) }
            m.add("battery_ok", batteryLow ? 0 : 1)
            if msg[5] & 0x0F != 0x0F { m.add("co2_ppm", co2) }
            m.add("mic", "CRC")
            return [m]
        case 11:
            let hcho = (msg[4] >> 4) * 1000 + (msg[4] & 0x0F) * 100 + (msg[5] >> 4) * 10 + (msg[5] & 0x0F)
            let voc = msg[22] & 0x0F
            var m = SensorReading(model: "Bresser-HCHOVOC")
            m.add("id", id)
            m.add("channel", chan)
            if startup { m.add("startup", 1) }
            m.add("battery_ok", batteryLow ? 0 : 1)
            if msg[5] & 0x0F != 0x0F { m.add("hcho_ppb", hcho) }
            if voc != 0x0F { m.add("voc_level", voc) }
            m.add("mic", "CRC")
            return [m]
        default:
            return []
        }
    }
}
