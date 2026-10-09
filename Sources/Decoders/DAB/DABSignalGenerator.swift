// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Codierer der Gegenseite für Prüfungen: Faltungscode mit Punktierung, FIB, Reed-Solomon und DAB+-Überrahmen
public enum DABTestEncoder {
    /// Faltungscode Rate 1/4 mit sechs Endbits (Nullen): 4 · (n + 6) Bits
    public static func convolve(_ bits: [UInt8]) -> [UInt8] {
        var state = 0
        var out = [UInt8]()
        out.reserveCapacity(4 * (bits.count + 6))
        for b in bits + [UInt8](repeating: 0, count: 6) {
            let reg = (Int(b) << 6) | state
            for p in DABViterbi.polynomials { out.append(UInt8((reg & p).nonzeroBitCount & 1)) }
            state = reg >> 1
        }
        return out
    }

    /// Punktieren: Abschnitte zu je 128 Bits mit Muster, am Ende 24 Bits mit PI_X
    public static func puncture(_ coded: [UInt8], segments: [(count: Int, pattern: [UInt8])]) -> [UInt8] {
        var out = [UInt8]()
        var pos = 0
        for seg in segments {
            for _ in 0..<seg.count {
                for j in 0..<128 {
                    if seg.pattern[j % 32] != 0 { out.append(coded[pos]) }
                    pos += 1
                }
            }
        }
        for k in 0..<24 {
            if DABTables.punctureTail[k] != 0 { out.append(coded[pos]) }
            pos += 1
        }
        return out
    }

    /// Bits → weiche Werte (1 = +amplitude, 0 = −amplitude)
    public static func soft(_ bits: [UInt8], amplitude: Int8 = 100) -> [Int8] { bits.map { $0 != 0 ? amplitude : -amplitude } }

    /// FIC-Codewort (2304 Bits) aus drei FIB (je 30 Bytes; die CRC wird angehängt)
    public static func ficCodeword(fibs: [[UInt8]]) -> [UInt8] {
        let prbs = DABTables.energyDispersal(count: 768)
        var bits = [UInt8]()
        for f in fibs {
            var bytes = f
            let crc = DABCRC.crc16(bytes)
            bytes.append(UInt8(crc >> 8)); bytes.append(UInt8(crc & 0xFF))
            for b in bytes { for k in 0..<8 { bits.append((b >> UInt8(7 - k)) & 1) } }
        }
        for i in 0..<768 { bits[i] ^= prbs[i] }
        let pi16 = DABTables.puncture[15], pi15 = DABTables.puncture[14]
        return puncture(convolve(bits), segments: [(21, pi16), (3, pi15)])
    }

    // MARK: FIB

    /// FIB aus FIG (je Byte-Feld mit Kopf); aufgefüllt mit dem Endezeichen
    public static func fib(figs: [[UInt8]]) -> [UInt8] {
        var out = [UInt8]()
        for f in figs { out.append(contentsOf: f) }
        while out.count < 30 { out.append(0xFF) }
        return Array(out.prefix(30))
    }

    /// FIG 0/1 mit einem EEP-Teilkanal (Profil A oder B)
    public static func fig0_1(subchannel id: Int, start: Int, profileB: Bool, level: Int, size: Int) -> [UInt8] {
        // 6 Bit Kennung, 10 Bit Start, 1 Bit lang, 3 Bit Option, 2 Bit Stufe, 10 Bit Größe
        let v: UInt32 = UInt32(id) << 26 | UInt32(start) << 16 | 1 << 15 | UInt32(profileB ? 1 : 0) << 12 | UInt32(level - 1) << 10 | UInt32(size)
        return [0x00 | 5, 0x01, UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    /// FIG 0/2: ein Dienst mit einer Audiokomponente (ASCTy 63 = DAB+)
    public static func fig0_2(sid: UInt16, subchannel: Int, audioType: Int) -> [UInt8] {
        let comp0 = UInt8(audioType & 0x3F) << 0 | 0
        // TMid 0 (2 Bit) + ASCTy (6 Bit), SubChId (6 Bit) + PS (1) + CA (0)
        let b0 = UInt8(0 << 6) | comp0
        let b1 = UInt8(subchannel << 2) | 0x02
        return [0x00 | 6, 0x02, UInt8(sid >> 8), UInt8(sid & 0xFF), 0x01, b0, b1]
    }

    /// FIG 1: Bezeichnung (Erweiterung 0 = Ensemble, 1 = Dienst), 16 Zeichen im Zeichensatz EBU Latin
    public static func fig1(extension ext: Int, id: UInt16, label: String) -> [UInt8] {
        var chars = Array(label.utf8.prefix(16))
        while chars.count < 16 { chars.append(0x20) }
        return [0x20 | 21, UInt8(ext), UInt8(id >> 8), UInt8(id & 0xFF)] + chars + [0xFF, 0x00]
    }

    // MARK: Reed-Solomon

    private static let gf: (exp: [UInt8], log: [Int]) = {
        var exp = [UInt8](repeating: 0, count: 512), log = [Int](repeating: 0, count: 256)
        var x = 1
        for i in 0..<255 { exp[i] = UInt8(x); log[x] = i; x <<= 1; if x & 0x100 != 0 { x ^= 0x11D } }
        for i in 255..<512 { exp[i] = exp[i - 255] }
        return (exp, log)
    }()

    private static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 { a == 0 || b == 0 ? 0 : gf.exp[gf.log[Int(a)] + gf.log[Int(b)]] }

    /// RS(120, 110): 110 Datenbytes → 120 Bytes (Prüfbytes hinten)
    public static func rsEncode(_ data: [UInt8]) -> [UInt8] {
        precondition(data.count == 110)
        // Generatorpolynom g(x) = Π (x − α^i), i = 0 … 9, höchste Potenz zuerst
        var g: [UInt8] = [1]
        for i in 0..<10 {
            var next = [UInt8](repeating: 0, count: g.count + 1)
            for (j, c) in g.enumerated() {
                next[j] ^= c
                next[j + 1] ^= mul(c, gf.exp[i])
            }
            g = next
        }
        var parity = [UInt8](repeating: 0, count: 10)
        for d in data {
            let feedback = d ^ parity[0]
            for k in 0..<9 { parity[k] = parity[k + 1] ^ mul(feedback, g[k + 1]) }
            parity[9] = mul(feedback, g[10])
        }
        return data + parity
    }

    // MARK: DAB+-Überrahmen

    /// Ein Überrahmen (5 Teilkanal-Rahmen) für die Datenrate `bitrate` (kbit/s, Vielfaches von 8) mit 48 kHz, SBR, Stereo und drei gleich langen Zugriffseinheiten
    public static func superframe(bitrate: Int, aus: [[UInt8]], fireError: Bool = false) -> [UInt8] {
        let sfLength = 15 * bitrate
        let blocks = sfLength / 120
        let dataLength = blocks * 110
        precondition(aus.count == 3)
        var data = [UInt8](repeating: 0, count: dataLength)
        // Zugriffseinheiten mit CRC einsetzen
        var starts = [6]
        var pos = 6
        for au in aus {
            var a = au
            let crc = DABCRC.crc16(a)
            a.append(UInt8(crc >> 8)); a.append(UInt8(crc & 0xFF))
            for (i, b) in a.enumerated() { data[pos + i] = b }
            pos += a.count
            starts.append(pos)
        }
        precondition(pos <= dataLength)
        // Kopf: Format (48 kHz, SBR, Stereo), Anfänge der Zugriffseinheiten 2 und 3 (je 12 Bit)
        data[2] = 0x40 | 0x20 | 0x10
        data[3] = UInt8(starts[1] >> 4)
        data[4] = UInt8((starts[1] & 0x0F) << 4) | UInt8(starts[2] >> 8)
        data[5] = UInt8(starts[2] & 0xFF)
        let fire = data[2..<11].withUnsafeBufferPointer { DABCRC.fireCode($0) } ^ (fireError ? 0x0001 : 0)
        data[0] = UInt8(fire >> 8); data[1] = UInt8(fire & 0xFF)
        // Reed-Solomon und Verschachtelung
        var sf = [UInt8](repeating: 0, count: sfLength)
        for i in 0..<blocks {
            var cw = [UInt8]()
            for p in 0..<110 { cw.append(data[p * blocks + i]) }
            let coded = rsEncode(cw)
            for p in 0..<120 { sf[p * blocks + i] = coded[p] }
        }
        return sf
    }
}
