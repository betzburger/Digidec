// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Acurite: 592TXR/592TX „Tower“ (Thermo/Hygro), 609TXC (Thermo/Hygro), 606TX/Technoline TX960 (Thermometer).
// Aufbau nach rtl_433 (`acurite.c`, siehe THIRD_PARTY.md). Wetterstationen, Blitz-, Regen- und Kühlschranksensoren der Marke fehlen.

enum SensorDevicesAcurite {
    private static func channel(_ byte: Int) -> String { ["C", "E", "B", "A"][(byte & 0xC0) >> 6] }

    static let tower = SensorDevice("Acurite 592TXR/592TX Tower", SlicerTiming(.ookPWM, short: 220, long: 408, reset: 4000, gap: 500, sync: 620)) { bits in
        bits.invert()
        var out: [SensorReading] = []
        for row in 0..<bits.numRows {
            let browlen = bits.bitsPerRow[row] / 8
            guard browlen >= 6, browlen <= 10 else { continue }
            let bb = bits.rows[row].map(Int.init)
            if bb[0] == 0 && bb[1] == 0 && bb[2] == 0 && bb[browlen - 1] == 0 { continue }
            guard bb[2] & 0x3F == 0x04, browlen >= 7 else { continue }                          // Meldungsart Tower
            guard SensorBits.addBytes(bb[0..<6].map { UInt8($0) }) & 0xFF == bb[6] else { continue }
            guard SensorBits.parityBytes(bb[2..<6].map { UInt8($0) }) == 0 else { continue }
            let ch = channel(bb[0])
            guard ch != "E" else { continue }
            let humidity = bb[3] & 0x7F
            guard humidity <= 100 || humidity == 127 else { continue }
            let tempRaw = (bb[4] & 0x7F) << 7 | (bb[5] & 0x7F)
            let tempC = Double(tempRaw - 1000) * 0.1
            guard tempC >= -40, tempC <= 70 else { continue }
            var m = SensorReading(model: "Acurite-Tower")
            m.add("id", (bb[0] & 0x3F) << 8 | bb[1])
            m.add("channel", ch)
            m.add("battery_ok", bb[2] & 0x40 == 0 ? 0 : 1)
            m.add("temperature_C", tempC)
            if humidity != 127 { m.add("humidity", humidity) }
            m.add("mic", "CHECKSUM")
            out.append(m)
        }
        return out
    }

    static let th609 = SensorDevice("Acurite 609TXC Thermo-/Hygrosensor", SlicerTiming(.ookPPM, short: 1000, long: 2000, reset: 10000, gap: 3000)) { bits in
        var out: [SensorReading] = []
        for row in 0..<bits.numRows where bits.bitsPerRow[row] == 40 {
            let bb = bits.rows[row].map(Int.init)
            let sum = bb[0] + bb[1] + bb[2] + bb[3]
            guard sum != 0, sum & 0xFF == bb[4] else { continue }
            let raw = Int(Int16(truncatingIfNeeded: ((bb[1] & 0x0F) << 12) | (bb[2] << 4)))
            let humidity = bb[3]
            guard humidity <= 100 else { return [] }
            let status = (bb[1] & 0xF0) >> 4
            var m = SensorReading(model: "Acurite-609TXC")
            m.add("id", bb[0])
            m.add("battery_ok", status & 8 != 0 ? 0 : 1)
            m.add("temperature_C", Double(raw >> 4) * 0.1)
            m.add("humidity", humidity)
            m.add("status", status)
            m.add("mic", "CHECKSUM")
            out.append(m)
        }
        return out
    }

    static let tx606 = SensorDevice("Acurite 606TX, Technoline TX960", SlicerTiming(.ookPPM, short: 2000, long: 4000, reset: 10000, gap: 7000)) { bits in
        let row = bits.findRepeatedRow(minRepeats: 3, minBits: 32)
        guard row >= 0, bits.bitsPerRow[row] <= 33 else { return [] }
        let b = bits.rows[row].map(Int.init) + [0, 0, 0, 0, 0]
        guard !(b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] == 0) else { return [] }
        guard SensorBits.lfsrDigest8(b[0..<3].map { UInt8($0) }, gen: 0x98, key: 0xF1) == UInt8(b[3]) else { return [] }
        let raw = Int(Int16(truncatingIfNeeded: (b[1] << 12) | (b[2] << 4))) >> 4
        var m = SensorReading(model: "Acurite-606TX")
        m.add("id", b[0])
        m.add("channel", ((b[1] & 0x30) >> 4) + 1)
        m.add("battery_ok", (b[1] & 0x80) >> 7)
        m.add("button", (b[1] & 0x40) >> 6)
        m.add("temperature_C", Double(raw) * 0.1)
        m.add("mic", "CHECKSUM")
        return [m]
    }
}
