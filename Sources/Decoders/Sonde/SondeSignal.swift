// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Testsignale für die Sonden DFM, M10 und M20 (nur für Prüfungen und Werkzeuge): Rahmen aus vorgegebenen Werten, Manchester-FSK als FM-Diskriminator-Audio.

enum SondeFSK {
    /// Rohsymbole (+1 / −1) mehrerer Aussendungen zu Audio: Rechteckimpulse, danach Glättung (Gauß-Näherung aus zwei gleitenden Mitteln)
    /// - Parameters:
    ///   - bursts: Beginn in s und Symbole
    ///   - amplitude: Spannung bei ±Hub
    ///   - offset: Gleichanteil (Frequenzablage der Sonde)
    ///   - clockError: Abweichung der Symbolrate (relativ)
    static func audio(bursts: [(start: Double, symbols: [Float])], symbolRate: Double, sampleRate: Double = 48_000, amplitude: Float = 0.25,
                      offset: Float = 0, clockError: Double = 0, duration: Double? = nil) -> [Float] {
        let sps = sampleRate / symbolRate * (1 + clockError)
        let end = bursts.map { $0.start + Double($0.symbols.count) / symbolRate }.max() ?? 0
        var out = [Float](repeating: offset, count: Int(((duration ?? (end + 0.3)) * sampleRate).rounded(.up)))
        for burst in bursts {
            var seg = [Float](repeating: 0, count: Int(Double(burst.symbols.count) * sps) + 8)
            for (j, s) in burst.symbols.enumerated() {
                let a = Int((Double(j) * sps).rounded()), z = Int((Double(j + 1) * sps).rounded())
                for n in a..<min(z, seg.count) { seg[n] = s }
            }
            let w = max(1, Int(sps / 3))
            for _ in 0..<2 {
                var sm = seg
                for n in 0..<seg.count {
                    var acc: Float = 0
                    for d in 0..<w { acc += seg[max(0, n - d)] }
                    sm[n] = acc / Float(w)
                }
                seg = sm
            }
            let base = Int((burst.start * sampleRate).rounded())
            for n in 0..<seg.count where base + n < out.count { out[base + n] = offset + amplitude * seg[n] }
        }
        return out
    }

    /// Bits → Manchester-Rohsymbole (0 → „10“, 1 → „01“)
    static func manchester(_ bits: [UInt8]) -> [Float] {
        bits.flatMap { $0 == 1 ? [Float(-1), 1] : [Float(1), -1] }
    }
}

// MARK: - Graw DFM

enum DFMSignalGenerator {
    struct Parameters {
        var serial: UInt32 = 637_797
        var latitude = 49.79, longitude = 9.95, altitude = 180.0
        var speed = 3.0, heading = 90.0, climb = 5.0
        /// UTC-Zeit des Pakets 8 (Datum, Stunde, Minute) und Sekunde der Minute (Paket 1); je Sekunde Flug anpassen
        var year = 2026, month = 10, day = 3, hour = 12, minute = 0, second = 0
        var temperature = 15.0
        var satellites = 9
    }

    /// Wert (≥ 0) als 24-Bit-Gleitzahl der Sonde: 4 Bit Exponent p, 20 Bit Mantisse, Wert = Mantisse / 2^p
    static func float24(_ v: Double) -> Int {
        var p = 0
        while p < 15, v * Double(1 << (p + 1)) < Double(1 << 20) { p += 1 }
        return (p << 20) | min((1 << 20) - 1, Int((v * Double(1 << p)).rounded()))
    }

    /// Widerstand des Thermistors (Ω) bei der Temperatur, umgekehrt zur Steinhart-Hart-Näherung der Auswertung (Halbierung)
    static func thermistor(_ celsius: Double) -> Double {
        let p0 = 1.09698417e-03, p1 = 2.39564629e-04, p2 = 2.48821437e-06, p3 = 5.84354921e-08
        var lo = 100.0, hi = 5e6
        for _ in 0..<80 {
            let r = (lo * hi).squareRoot(), l = log(r)
            let t = 1 / (p0 + p1 * l + p2 * l * l + p3 * l * l * l) - 273.15
            if t > celsius { lo = r } else { hi = r }   // höhere Temperatur: kleinerer Widerstand
        }
        return (lo * hi).squareRoot()
    }

    /// Kanalwerte (Halbbytes) des Kanalblocks nach Rahmennummer: Zyklus aus 40 Rahmen wie bei einer echten DFM-09
    static func configBlock(frame f: Int, p: Parameters, battery: Double = 5.9) -> [UInt8] {
        // Messwerte: 0 = Fühler (g·(R + Rs)), 3 = g·Rs, 4 = g·Rf mit g = 0,1 und Rs = 20 kΩ, Rf = 220 kΩ
        let g = 0.1
        var meas = [Double](repeating: 1000, count: 9)
        meas[0] = g * (thermistor(p.temperature) + 20e3)
        meas[3] = g * 20e3
        meas[4] = g * 220e3
        func block(id: Int, value: Int) -> [UInt8] { [UInt8(id)] + (0..<6).map { UInt8((value >> (20 - 4 * $0)) & 0xF) } }
        let slot = f % 4
        if slot < 3 { return block(id: slot, value: float24(meas[slot])) }
        let extras = ["9", "A1", "3", "4", "5", "6", "7", "8", "9", "A0"]
        let e = extras[(f / 4) % extras.count]
        switch e {
        case "9": return block(id: 9, value: 0)
        case "A0", "A1":
            let hl = e == "A0" ? 0 : 1
            let half = hl == 0 ? Int(p.serial >> 16) : Int(p.serial & 0xFFFF)
            return [0xA, 0xC] + (0..<4).map { UInt8((half >> (12 - 4 * $0)) & 0xF) } + [UInt8(hl)]
        default:
            let id = Int(e)!
            switch id {
            case 5: return block(id: 5, value: 0xC00000 | (Int(battery * 1000) << 4))   // Spannung in mV
            case 6: return block(id: 6, value: 0xC00000 | (30500 << 4))                 // Innentemperatur (Zehntel Kelvin·10)
            default: return block(id: id, value: float24(meas[id]))
            }
        }
    }

    /// Datenpaket `id` (13 Halbbytes: 48 Bit Nutzdaten und die Kennung)
    static func packet(id: Int, second s: Int, p: Parameters) -> [UInt8] {
        var bits = [UInt8](repeating: 0, count: 48)
        func put(_ value: Int, at start: Int, count: Int) {
            for j in 0..<count { bits[start + j] = UInt8((value >> (count - 1 - j)) & 1) }
        }
        func signed(_ v: Double, scale: Double) -> Int { Int((v * scale).rounded()) }
        switch id {
        case 0:
            put(2, at: 16, count: 8)              // Betriebsart mit Paketen für Lage, Länge, Höhe
            put(s & 0xFF, at: 24, count: 8)       // Rahmenzähler
        case 1:
            put(0x7F, at: 0, count: 32)
            put(Int(p.second * 1000 + 0) & 0xFFFF, at: 32, count: 16)
        case 2:
            put(signed(p.latitude, scale: 1e7) & 0xFFFF_FFFF, at: 0, count: 32)
            put(signed(p.speed, scale: 100) & 0xFFFF, at: 32, count: 16)
        case 3:
            put(signed(p.longitude, scale: 1e7) & 0xFFFF_FFFF, at: 0, count: 32)
            put(signed(p.heading, scale: 100) & 0xFFFF, at: 32, count: 16)
        case 4:
            put(signed(p.altitude, scale: 100) & 0xFFFF_FFFF, at: 0, count: 32)
            put(signed(p.climb, scale: 100) & 0xFFFF, at: 32, count: 16)
        case 5:
            put(signed(-47.0, scale: 100) & 0xFFFF, at: 0, count: 16)
        case 8:
            put(p.year, at: 0, count: 12)
            put(p.month, at: 12, count: 4)
            put(p.day, at: 16, count: 5)
            put(p.hour, at: 21, count: 5)
            put(p.minute, at: 26, count: 6)
            put(p.satellites, at: 32, count: 8)
        default: break
        }
        var nibbles: [UInt8] = []
        for n in 0..<12 {
            var v: UInt8 = 0
            for j in 0..<4 { v = (v << 1) | bits[4 * n + j] }
            nibbles.append(v)
        }
        nibbles.append(UInt8(id))
        return nibbles
    }

    /// Wörter (Halbbytes) → verschachtelte Bits
    static func block(_ nibbles: [UInt8], columns: Int) -> [UInt8] {
        let words = nibbles.flatMap { DFMHamming.encode($0) }
        return DFMHamming.interleave(words, columns: columns)
    }

    /// Rahmen `f` als Rohsymbole (Kopf, Kanalblock, zwei Datenblöcke); die Sekunde `s` liefert die Zeit
    static func frameSymbols(frame f: Int, flight: (Int) -> Parameters, startSecond: Int = 0) -> [Float] {
        // Jede Sekunde sendet neun Pakete (0 … 8); ein Rahmen trägt zwei davon
        func packetFor(_ index: Int) -> [UInt8] {
            let second = index / 9
            return packet(id: index % 9, second: second, p: flight(startSecond + second))
        }
        let first = flight(startSecond + (2 * f) / 9)
        var bits: [UInt8] = (0..<16).map { UInt8((0x45CF >> (15 - $0)) & 1) }
        bits += block(configBlock(frame: f, p: first), columns: 7)
        bits += block(packetFor(2 * f), columns: 13)
        bits += block(packetFor(2 * f + 1), columns: 13)
        return SondeFSK.manchester(bits)
    }

    /// Ein Flug mit `seconds` Sekunden: ununterbrochener Strom aus 280-Bit-Rahmen (4,46 Rahmen je Sekunde)
    static func audio(seconds: Int, flight: (Int) -> Parameters, sampleRate: Double = 48_000, amplitude: Float = 0.25, offset: Float = 0,
                      clockError: Double = 0, inverted: Bool = false) -> [Float] {
        let frames = Int(Double(seconds) * 2500 / 560)
        var symbols: [Float] = [Float](repeating: 0, count: 0)
        for f in 0..<frames { symbols += frameSymbols(frame: f, flight: flight) }
        if inverted { symbols = symbols.map { -$0 } }
        return SondeFSK.audio(bursts: [(0.3, symbols)], symbolRate: 2500, sampleRate: sampleRate, amplitude: amplitude, offset: offset, clockError: clockError)
    }
}

// MARK: - Meteomodem M10 und Meteosis M20

enum M10SignalGenerator {
    struct Parameters {
        var kind: M10Frame.Kind = .m20
        var week = 2400
        /// Sekunde der Woche (M10: Millisekunden stehen in `milliseconds`)
        var towSeconds = 345_600 + 12 * 3600
        var milliseconds = 0
        var utcOffset = 18
        var latitude = 49.79, longitude = 9.95, altitude = 180.0
        var vEast = 2.0, vNorth = 3.0, vUp = 5.0
        var satellites = 9
        var counter = 0
        /// M10: fünf Rohbytes der Seriennummer ab 0x5D; M20: drei Bytes ab 0x12
        var serialBytes: [UInt8] = [0x03, 0x00, 0x23, 0x2C, 0x36]
    }

    static func frame(_ p: Parameters) -> [UInt8] {
        let isM20 = p.kind == .m20
        let length = isM20 ? M10Frame.m20Length : M10Frame.m10Length
        var f = [UInt8](repeating: 0, count: length + 1)
        f[0] = UInt8(length)
        f[1] = p.kind.rawValue
        func put(_ value: Int, at pos: Int, bytes: Int) { for i in 0..<bytes { f[pos + i] = UInt8((value >> (8 * (bytes - 1 - i))) & 0xFF) } }
        if isM20 {
            put(p.towSeconds, at: 0x0F, bytes: 3)
            put(p.week, at: 0x1A, bytes: 2)
            put(Int((p.latitude * 1e6).rounded()) & 0xFFFF_FFFF, at: 0x1C, bytes: 4)
            put(Int((p.longitude * 1e6).rounded()) & 0xFFFF_FFFF, at: 0x20, bytes: 4)
            put(Int((p.altitude * 100).rounded()), at: 0x08, bytes: 3)
            put(Int((p.vEast * 100).rounded()) & 0xFFFF, at: 0x0B, bytes: 2)
            put(Int((p.vNorth * 100).rounded()) & 0xFFFF, at: 0x0D, bytes: 2)
            put(Int((p.vUp * 100).rounded()) & 0xFFFF, at: 0x18, bytes: 2)
            for i in 0..<3 { f[0x12 + i] = p.serialBytes[i] }
            f[0x15] = UInt8(p.counter & 0xFF)
        } else {
            put(p.towSeconds * 1000 + p.milliseconds, at: 0x0A, bytes: 4)
            put(Int((p.latitude * Double(1 << 30) / 90).rounded()) & 0xFFFF_FFFF, at: 0x0E, bytes: 4)
            put(Int((p.longitude * Double(1 << 30) / 90).rounded()) & 0xFFFF_FFFF, at: 0x12, bytes: 4)
            put(Int((p.altitude * 1000).rounded()) & 0xFFFF_FFFF, at: 0x16, bytes: 4)
            f[0x1E] = UInt8(p.satellites)
            f[0x1F] = UInt8(p.utcOffset)
            put(p.week, at: 0x20, bytes: 2)
            put(Int((p.vEast * 200).rounded()) & 0xFFFF, at: 0x04, bytes: 2)
            put(Int((p.vNorth * 200).rounded()) & 0xFFFF, at: 0x06, bytes: 2)
            put(Int((p.vUp * 200).rounded()) & 0xFFFF, at: 0x08, bytes: 2)
            for i in 0..<5 { f[0x5D + i] = p.serialBytes[i] }
            f[0x62] = UInt8(p.counter & 0xFF)
        }
        // Prüfsumme über alles außer den letzten beiden Bytes
        let cs = M10Frame.check(f, count: length - 1)
        f[length - 1] = UInt8(cs >> 8)
        f[length] = UInt8(cs & 0xFF)
        return f
    }

    /// Vorlauf (periodisch), Synchronkopf und der Rahmen differenziell Manchester-codiert
    static func symbols(frame: [UInt8], preambleSymbols: Int = 320) -> [Float] {
        var out: [Float] = (0..<preambleSymbols).map { [Float(1), -1, -1, 1][$0 % 4] }
        out += M10Frame.headerSymbols
        var m: UInt8 = 1
        for byte in frame {
            for b in 0..<8 {
                let d = (byte >> UInt8(7 - b)) & 1
                m = m ^ (1 - d)             // Umkehrung von: Bit = nicht (m ⊕ m_vorher)
                out += m == 1 ? [Float(-1), 1] : [Float(1), -1]
            }
        }
        return out
    }

    /// Ein Flug: ein Rahmen je Sekunde
    static func audio(seconds: Int, flight: (Int) -> Parameters, sampleRate: Double = 48_000, amplitude: Float = 0.25, offset: Float = 0,
                      clockError: Double = 0, inverted: Bool = false) -> [Float] {
        var bursts: [(Double, [Float])] = []
        for s in 0..<seconds {
            var syms = symbols(frame: frame(flight(s)))
            if inverted { syms = syms.map { -$0 } }
            bursts.append((0.3 + Double(s), syms))
        }
        return SondeFSK.audio(bursts: bursts, symbolRate: M10Frame.symbolRate, sampleRate: sampleRate, amplitude: amplitude, offset: offset, clockError: clockError)
    }
}
