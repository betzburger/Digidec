// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Fine Offset WH1080/WH3080 und Gleiche: Froggit WH1080, Watson W-8681, Digitech XC0348, PCE-FWS 20, Elecsa AstroTouch 6975, ELV WS 1080.
// Wetterstation mit Wind, Regen, Temperatur, Feuchte; WH3080 zusätzlich UV und Licht; dazu Funkuhr (DCF77/WWVB/MSF).
// Zwei Fassungen: OOK (433 MHz) und FSK (868 MHz). Aufbau nach rtl_433 (`fineoffset_wh1080.c`, siehe THIRD_PARTY.md).

enum SensorDevicesWH1080 {
    private static let windDirection = [0, 23, 45, 68, 90, 113, 135, 158, 180, 203, 225, 248, 270, 293, 315, 338]

    private static func decode(_ bits: BitBuffer, fsk: Bool) -> [SensorReading] {
        guard bits.numRows == 1 else { return [] }
        let n0 = bits.bitsPerRow[0]
        var br: [Int]
        var sensMsg = 10
        var shortPreamble = false
        if fsk {
            let preamble: [UInt8] = [0xAA, 0x2D, 0xD4]
            let offset = bits.search(row: 0, start: 0, pattern: preamble, patternBits: 24) + 24
            guard offset + 88 <= n0 else { return [] }
            br = bits.extractBytes(row: 0, pos: offset - 8, len: 88).map(Int.init)
            br[0] = 0xFF
        } else if n0 >= 88 && n0 < 100 {
            br = bits.rows[0].map(Int.init)
        } else if n0 == 87 {
            shortPreamble = true
            br = [(Int(bits.rows[0][0]) >> 1) | 0x80] + bits.extractBytes(row: 0, pos: 7, len: 80).map(Int.init)
        } else if n0 == 64 {
            sensMsg = 7
            br = bits.rows[0].map(Int.init)
        } else if n0 == 63 {
            sensMsg = 7
            shortPreamble = true
            br = [(Int(bits.rows[0][0]) >> 1) | 0x80] + bits.extractBytes(row: 0, pos: 7, len: 56).map(Int.init)
        } else { return [] }
        br += [Int](repeating: 0, count: 12)
        guard br[0] == 0xFF else { return [] }
        let crcLen = sensMsg == 10 ? 11 : 8
        guard SensorBits.crc8(br[0..<crcLen].map { UInt8($0) }, poly: 0x31, initial: 0xFF) == 0 else { return [] }
        let msgType: Int
        switch br[1] >> 4 {
        case 0x0A: msgType = 0
        case 0x0B: msgType = 1
        case 0x07: msgType = 2
        default: return []
        }
        var m = SensorReading(model: "Fineoffset-WHx080")
        if msgType == 0 {
            var tempRaw: Int
            var temperature: Double
            if !fsk {
                tempRaw = (br[2] & 0x03) << 8 | br[3]
                temperature = Double(tempRaw - 400) * 0.1
            } else {
                tempRaw = (br[2] & 0x0F) << 8 | br[3]
                if tempRaw & 0x800 != 0 { tempRaw &= 0x7FF; tempRaw = -tempRaw }
                temperature = Double(tempRaw) * 0.1
            }
            m.add("subtype", msgType)
            m.add("id", (br[1] << 4 & 0xF0) | (br[2] >> 4))
            m.add("battery_ok", (br[9] >> 4) == 1 ? 0 : 1)
            m.add("temperature_C", temperature)
            m.add("humidity", br[4])
            m.add("wind_dir_deg", windDirection[br[9] & 0x0F])
            m.add("wind_avg_km_h", Double(Float(br[5]) * 0.34 * 3.6))
            m.add("wind_max_km_h", Double(Float(br[6]) * 0.34 * 3.6))
            m.add("rain_mm", Double(Float(((br[7] & 0x0F) << 8) | br[8]) * 0.3))
        } else if msgType == 1 {
            let signalType = (br[2] & 0x0F) == 10
            let hours = ((br[3] & 0x30) >> 4) * 10 + (br[3] & 0x0F)
            let minutes = ((br[4] & 0xF0) >> 4) * 10 + (br[4] & 0x0F)
            let seconds = ((br[5] & 0xF0) >> 4) * 10 + (br[5] & 0x0F)
            let year = ((br[6] & 0xF0) >> 4) * 10 + (br[6] & 0x0F) + 2000
            let month = ((br[7] & 0x10) >> 4) * 10 + (br[7] & 0x0F)
            let day = ((br[8] & 0xF0) >> 4) * 10 + (br[8] & 0x0F)
            m.add("subtype", msgType)
            m.add("id", (br[1] << 4 & 0xF0) | (br[2] >> 4))
            m.add("signal", signalType ? "DCF77" : "WWVB/MSF")
            m.add("radio_clock", String(format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, hours, minutes, seconds))
        } else {
            let light = br[4] << 16 | br[5] << 8 | br[6]
            m.add("subtype", msgType)
            m.add("uv_sensor_id", (br[1] << 4 & 0xF0) | (br[2] >> 4))
            m.add("uv_status", br[3] == 85 ? "OK" : "ERROR")
            m.add("uv_index", br[2] & 0x0F)
            m.add("lux", Double(light) * 0.1)
            m.add("wm", Double(shortPreamble ? Float(light) / 1265.8 : Float(light) / 6830.0))
        }
        m.add("mic", "CRC")
        return [m]
    }

    static let ook = SensorDevice("Fine Offset WH1080/WH3080 Wetterstation", SlicerTiming(.ookPWM, short: 544, long: 1524, reset: 2800)) { decode($0, fsk: false) }
    static let fsk = SensorDevice("Fine Offset WH1080/WH3080 Wetterstation (FSK)", SlicerTiming(.fskPCM, short: 58, long: 58, reset: 5800), bands: [.mhz868]) { decode($0, fsk: true) }
}
