// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Gerätebeschreibung, Messwerte und Hilfsfunktionen (Prüfsummen, Bitumkehr) der Sensor-Decoder.
// Die Schlüssel der Messwerte entsprechen den JSON-Feldern von rtl_433 (`model`, `id`, `channel`, `battery_ok`, `temperature_C` …).

public enum SensorValue: Equatable, Sendable {
    case int(Int)
    case double(Double)
    case string(String)

    public var number: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        case .string: return nil
        }
    }

    public var text: String {
        switch self {
        case .int(let v): return String(v)
        case .double(let v): return String(format: "%g", v)
        case .string(let v): return v
        }
    }
}

/// Ein Telegramm eines Sensors, entschlüsselt zu benannten Messwerten (in der Reihenfolge des Vorbilds)
public struct SensorReading: Equatable, Sendable {
    public var model: String
    public var fields: [(key: String, value: SensorValue)] = []

    public init(model: String) { self.model = model }

    public static func == (a: SensorReading, b: SensorReading) -> Bool {
        a.model == b.model && a.fields.count == b.fields.count && zip(a.fields, b.fields).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    public subscript(key: String) -> SensorValue? { fields.first { $0.key == key }?.value }

    public mutating func add(_ key: String, _ value: Int) { set(key, .int(value)) }
    public mutating func add(_ key: String, _ value: Double) { set(key, .double(value)) }
    public mutating func add(_ key: String, _ value: String) { set(key, .string(value)) }

    private mutating func set(_ key: String, _ value: SensorValue) {
        if let i = fields.firstIndex(where: { $0.key == key }) { fields[i].value = value } else { fields.append((key, value)) }
    }

    public var id: Int? { self["id"].flatMap { $0.number }.map { Int($0) } }
    public var channel: Int? { self["channel"].flatMap { $0.number }.map { Int($0) } }
    public var temperatureC: Double? { self["temperature_C"]?.number }
    public var humidity: Double? { self["humidity"]?.number }
    /// `true` = Batterie in Ordnung
    public var batteryOK: Bool? { self["battery_ok"]?.number.map { $0 >= 0.5 } }

    /// Schlüssel des Geräts: Modell, Kennung, Kanal (zur Zusammenfassung der Wiederholungen)
    public var deviceKey: String {
        var k = model
        if let id = self["id"] { k += "/" + id.text }
        if let ch = self["channel"] { k += "/" + ch.text }
        return k
    }
}

/// Wo ein Gerät zu finden ist
public enum SensorBand: String, CaseIterable, Identifiable, Sendable {
    case mhz433 = "433.92", mhz868 = "868.3"
    public var id: String { rawValue }
    public var title: String { self == .mhz433 ? "433,92 MHz" : "868,3 MHz" }
    public var frequencyHz: Double { self == .mhz433 ? 433_920_000 : 868_300_000 }
    /// Abtastrate der Verarbeitung (wie rtl_433: über 800 MHz 1 MS/s)
    public var processingRate: Int { self == .mhz433 ? 250_000 : 1_000_000 }
}

public struct SensorDevice: Sendable {
    public var name: String
    public var timing: SlicerTiming
    public var bands: [SensorBand]
    /// Gibt die gelesenen Telegramme zurück (leer = kein Treffer). Der Puffer darf verändert werden.
    /// Niedrigere Zahlen zuerst; findet eine Stufe etwas, laufen die höheren nicht mehr (löst Kollisionen ähnlicher Protokolle)
    public var priority: Int
    public var decode: @Sendable (inout BitBuffer) -> [SensorReading]

    public init(_ name: String, _ timing: SlicerTiming, bands: [SensorBand] = [.mhz433], priority: Int = 0, decode: @escaping @Sendable (inout BitBuffer) -> [SensorReading]) {
        self.name = name
        self.timing = timing
        self.bands = bands
        self.priority = priority
        self.decode = decode
    }
}

// MARK: - Hilfsfunktionen

public enum SensorBits {
    public static func reverse8(_ x: UInt8) -> UInt8 {
        var x = x
        x = (x & 0xF0) >> 4 | (x & 0x0F) << 4
        x = (x & 0xCC) >> 2 | (x & 0x33) << 2
        x = (x & 0xAA) >> 1 | (x & 0x55) << 1
        return x
    }

    public static func reflect4(_ x: UInt8) -> UInt8 {
        var x = x
        x = (x & 0xCC) >> 2 | (x & 0x33) << 2
        x = (x & 0xAA) >> 1 | (x & 0x55) << 1
        return x
    }

    public static func reflectBytes(_ b: [UInt8]) -> [UInt8] { b.map(reverse8) }
    public static func reflectNibbles(_ b: [UInt8]) -> [UInt8] { b.map(reflect4) }

    public static func crc4(_ m: [UInt8], poly: UInt8, initial: UInt8) -> UInt8 {
        var r = UInt32(initial) << 4
        let p = UInt32(poly) << 4
        for byte in m {
            r ^= UInt32(byte)
            for _ in 0..<8 { r = r & 0x80 != 0 ? (r << 1) ^ p : r << 1 }
        }
        return UInt8((r >> 4) & 0x0F)
    }

    public static func crc7(_ m: [UInt8], poly: UInt8, initial: UInt8) -> UInt8 {
        var r = UInt32(initial) << 1
        let p = UInt32(poly) << 1
        for byte in m {
            r ^= UInt32(byte)
            for _ in 0..<8 { r = r & 0x80 != 0 ? (r << 1) ^ p : r << 1 }
        }
        return UInt8((r >> 1) & 0x7F)
    }

    public static func crc8(_ m: [UInt8], poly: UInt8, initial: UInt8) -> UInt8 {
        var r = initial
        for byte in m {
            r ^= byte
            for _ in 0..<8 { r = r & 0x80 != 0 ? (r << 1) ^ poly : r << 1 }
        }
        return r
    }

    public static func crc8le(_ m: [UInt8], poly: UInt8, initial: UInt8) -> UInt8 {
        var r = reverse8(initial)
        let p = reverse8(poly)
        for byte in m {
            r ^= byte
            for _ in 0..<8 { r = r & 1 != 0 ? (r >> 1) ^ p : r >> 1 }
        }
        return r
    }

    public static func crc16lsb(_ m: [UInt8], poly: UInt16, initial: UInt16) -> UInt16 {
        var r = initial
        for byte in m {
            r ^= UInt16(byte)
            for _ in 0..<8 { r = r & 1 != 0 ? (r >> 1) ^ poly : r >> 1 }
        }
        return r
    }

    public static func crc16(_ m: [UInt8], poly: UInt16, initial: UInt16) -> UInt16 {
        var r = initial
        for byte in m {
            r ^= UInt16(byte) << 8
            for _ in 0..<8 { r = r & 0x8000 != 0 ? (r << 1) ^ poly : r << 1 }
        }
        return r
    }

    public static func lfsrDigest8(_ m: [UInt8], gen: UInt8, key: UInt8) -> UInt8 {
        var sum: UInt8 = 0, key = key
        for data in m {
            for i in stride(from: 7, through: 0, by: -1) {
                if (data >> UInt8(i)) & 1 == 1 { sum ^= key }
                key = key & 1 != 0 ? (key >> 1) ^ gen : key >> 1
            }
        }
        return sum
    }

    public static func lfsrDigest8Reverse(_ m: [UInt8], gen: UInt8, key: UInt8) -> UInt8 {
        var sum: UInt8 = 0, key = key
        for data in m.reversed() {
            for i in stride(from: 7, through: 0, by: -1) {
                if (data >> UInt8(i)) & 1 == 1 { sum ^= key }
                key = key & 1 != 0 ? (key >> 1) ^ gen : key >> 1
            }
        }
        return sum
    }

    public static func lfsrDigest8Reflect(_ m: [UInt8], gen: UInt8, key: UInt8) -> UInt8 {
        var sum: UInt8 = 0, key = key
        for data in m.reversed() {
            for i in 0..<8 {
                if (data >> UInt8(i)) & 1 == 1 { sum ^= key }
                key = key & 0x80 != 0 ? (key << 1) ^ gen : key << 1
            }
        }
        return sum
    }

    public static func lfsrDigest16(_ m: [UInt8], gen: UInt16, key: UInt16) -> UInt16 {
        var sum: UInt16 = 0, key = key
        for data in m {
            for i in stride(from: 7, through: 0, by: -1) {
                if (data >> UInt8(i)) & 1 == 1 { sum ^= key }
                key = key & 1 != 0 ? (key >> 1) ^ gen : key >> 1
            }
        }
        return sum
    }

    public static func parity8(_ b: UInt8) -> Int { b.nonzeroBitCount & 1 }
    public static func parityBytes(_ m: [UInt8]) -> Int { m.reduce(0) { $0 ^ parity8($1) } }
    public static func xorBytes(_ m: [UInt8]) -> UInt8 { m.reduce(0, ^) }
    public static func addBytes(_ m: [UInt8]) -> Int { m.reduce(0) { $0 + Int($1) } }
    public static func addNibbles(_ m: [UInt8]) -> Int { m.reduce(0) { $0 + Int($1 >> 4) + Int($1 & 0x0F) } }

    /// Fünf-Bit-Gruppen mit Füllbit 1 (4 Bit Nutzdaten + 1): wie `extract_nibbles_4b1s`
    public static func extractNibbles4b1s(_ m: [UInt8], offsetBits: Int, numBits: Int) -> [UInt8] {
        var out: [UInt8] = []
        var offset = offsetBits, num = numBits
        while num >= 5 {
            let hi = offset / 8 < m.count ? Int(m[offset / 8]) : 0
            let lo = offset / 8 + 1 < m.count ? Int(m[offset / 8 + 1]) : 0
            var bits = (hi << 8) | lo
            bits >>= 11 - (offset % 8)
            if bits & 1 != 1 { break }
            out.append(UInt8((bits >> 1) & 0xF))
            offset += 5
            num -= 5
        }
        return out
    }

    /// Bits in einer Byte-Folge (MSB zuerst)
    public static func bit(_ m: [UInt8], _ index: Int) -> Int {
        guard index >= 0, index / 8 < m.count else { return 0 }
        return Int((m[index / 8] >> UInt8(7 - index % 8)) & 1)
    }
}
