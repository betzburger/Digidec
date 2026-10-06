// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// LaCrosse IT+ (868,24 MHz, FSK): TX29-IT (TFA 30.3159.IT, Thermometer) und TX35DTH-IT (TFA 30.3155, Thermo-/Hygrosensor), auch TX25U.
// Beide teilen das Protokoll und unterscheiden sich in der Bitbreite (TX29 55 µs, TX35 105 µs). Aufbau nach `lacrosse_tx35.c` (rtl_433, siehe THIRD_PARTY.md).

enum SensorDevicesLaCrosseIT {
    private static func decode(_ bits: BitBuffer, model: String) -> [SensorReading] {
        let preamble: [UInt8] = [0xA2, 0xDD, 0x49]
        var out: [SensorReading] = []
        for row in 0..<bits.numRows {
            let start = bits.search(row: row, start: 0, pattern: preamble, patternBits: 24)
            if start >= bits.bitsPerRow[row] { continue }
            let b = bits.extractBytes(row: row, pos: start + 20, len: 40).map(Int.init)
            guard SensorBits.crc8(b[0..<4].map { UInt8($0) }, poly: 0x31, initial: 0) == UInt8(b[4]) else { continue }
            var sensorID = ((b[0] & 0x0F) << 2) | (b[1] >> 6)
            let temp = Double(10 * (b[1] & 0x0F) + ((b[2] >> 4) & 0x0F)) + 0.1 * Double(b[2] & 0x0F) - 40
            let humidity = b[3] & 0x7F
            var m = SensorReading(model: model)
            if humidity == 0x6A || humidity == 0x7D {
                if humidity == 0x7D { sensorID += 0x40 }                                // Fühlerkanal
                m.add("id", sensorID); m.add("battery_ok", b[3] >> 7 == 0 ? 1 : 0); m.add("newbattery", (b[1] >> 5) & 1)
                m.add("temperature_C", temp); m.add("mic", "CRC")
            } else {
                m.add("id", sensorID); m.add("battery_ok", b[3] >> 7 == 0 ? 1 : 0); m.add("newbattery", (b[1] >> 5) & 1)
                m.add("temperature_C", temp); m.add("humidity", humidity); m.add("mic", "CRC")
            }
            out.append(m)
        }
        return out
    }

    static let tx29 = SensorDevice("LaCrosse TX29-IT, TFA 30.3159.IT", SlicerTiming(.fskPCM, short: 55, long: 55, reset: 4000), bands: [.mhz868]) { decode($0, model: "LaCrosse-TX29IT") }
    static let tx35 = SensorDevice("LaCrosse TX35DTH-IT, TFA 30.3155", SlicerTiming(.fskPCM, short: 105, long: 105, reset: 4000), bands: [.mhz868]) { decode($0, model: "LaCrosse-TX35DTHIT") }
}
