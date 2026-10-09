// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Fehlerschutz-Bausteine für DMR, YSF (C4FM) und andere Vierpegel-Sprachverfahren:
// Golay (23,12) und (24,12), Faltungscode K = 5 mit weichem Viterbi-Decoder, CRC-16 (CCITT-Teiler, wie bei Yaesu).
// Quellen: Beschreibung der Codes (Golay: Generator x¹¹+x¹⁰+x⁶+x⁵+x⁴+x²+1; Faltungscode wie NXDN/YSF), Tabellen und
// Reihenfolgen an echten Aufnahmen geprüft (siehe THIRD_PARTY.md).

// MARK: - Golay

public enum Golay {
    /// Erzeugerpolynom des Golay-Codes (23,12): x¹¹ + x¹⁰ + x⁶ + x⁵ + x⁴ + x² + 1
    public static let generator = 0xC75

    /// Die 11 Prüfbits zu 12 Datenbits (Rest der Division von Daten · x¹¹ durch das Erzeugerpolynom)
    public static func parity11(_ data12: Int) -> Int {
        var v = (data12 & 0xFFF) << 11
        for i in stride(from: 22, through: 11, by: -1) where (v >> i) & 1 != 0 { v ^= generator << (i - 11) }
        return v & 0x7FF
    }

    /// 23-Bit-Codewort: Daten oben (Bit 22 … 11), Prüfbits unten (Bit 10 … 0)
    public static func encode23(_ data12: Int) -> Int { ((data12 & 0xFFF) << 11) | parity11(data12) }

    /// Syndrom → Fehlermuster (bis zu 3 Fehler, der Code ist perfekt: alle 2047 Syndrome kommen genau einmal vor)
    private static let errorTable: [Int] = {
        var table = [Int](repeating: 0, count: 2048)
        func syndrome(_ word: Int) -> Int {
            var v = word
            for i in stride(from: 22, through: 11, by: -1) where (v >> i) & 1 != 0 { v ^= generator << (i - 11) }
            return v & 0x7FF
        }
        for a in 0..<23 {
            table[syndrome(1 << a)] = 1 << a
            for b in (a + 1)..<23 {
                table[syndrome((1 << a) | (1 << b))] = (1 << a) | (1 << b)
                for c in (b + 1)..<23 { table[syndrome((1 << a) | (1 << b) | (1 << c))] = (1 << a) | (1 << b) | (1 << c) }
            }
        }
        return table
    }()

    /// Decodiert ein 23-Bit-Wort (Bit 22 = erstes Datenbit). Gibt die 12 Datenbits und die Zahl der korrigierten Bits zurück.
    public static func decode23(_ word: Int) -> (data: Int, corrected: Int) {
        var v = word & 0x7FFFFF
        var r = v
        for i in stride(from: 22, through: 11, by: -1) where (r >> i) & 1 != 0 { r ^= generator << (i - 11) }
        let syndrome = r & 0x7FF
        guard syndrome != 0 else { return (v >> 11, 0) }
        let error = errorTable[syndrome]
        v ^= error
        return (v >> 11, error.nonzeroBitCount)
    }

    /// Golay (24,12) wie im FICH: 12 Datenbits, 11 Prüfbits, 1 Gesamtparität (gerade); Reihenfolge der Bits wie auf der Leitung
    public static func decode24(_ bits: ArraySlice<UInt8>) -> (data: [UInt8], corrected: Int) {
        var word = 0
        for b in bits.prefix(23) { word = (word << 1) | Int(b & 1) }
        let r = decode23(word)
        let data = (0..<12).map { UInt8((r.data >> (11 - $0)) & 1) }
        return (data, r.corrected)
    }

    public static func encode24(_ data12: [UInt8]) -> [UInt8] {
        var d = 0
        for b in data12 { d = (d << 1) | Int(b & 1) }
        let word = encode23(d)
        var out = (0..<23).map { UInt8((word >> (22 - $0)) & 1) }
        out.append(UInt8(word.nonzeroBitCount & 1))
        return out
    }
}

// MARK: - CRC (Yaesu)

public enum YaesuCRC {
    /// Teiler x¹⁶ + x¹² + x⁵ + 1, Bits nacheinander eingeschoben, am Ende invertiert. Gültig, wenn der Wert über Nutzdaten + CRC null ergibt.
    public static func remainder(_ bits: [UInt8]) -> UInt16 {
        let poly: UInt32 = (1 << 12) + (1 << 5) + 1
        var crc: UInt32 = 0
        for bit in bits {
            crc = ((crc << 1) | UInt32(bit & 1)) & 0x1FFFF
            if crc & 0x10000 != 0 { crc = (crc & 0xFFFF) ^ poly }
        }
        return UInt16((crc ^ 0xFFFF) & 0xFFFF)
    }

    /// CRC (16 Bit, MSB zuerst), die an die Nutzdaten angehängt den Rest 0 ergibt
    public static func checkBits(for data: [UInt8]) -> [UInt8] {
        // Der Rest der Daten mit 16 Nullen hängt linear vom Anhang ab: Anhang = (Rest bei Nullen) so wählen, dass der Gesamtrest 0xFFFF^… ergibt
        var crc: UInt32 = 0
        let poly: UInt32 = (1 << 12) + (1 << 5) + 1
        for bit in data + [UInt8](repeating: 0, count: 16) {
            crc = ((crc << 1) | UInt32(bit & 1)) & 0x1FFFF
            if crc & 0x10000 != 0 { crc = (crc & 0xFFFF) ^ poly }
        }
        // Soll: Rest nach dem Anhang = 0xFFFF; der Rest ist linear, mit dem Anhang a: rest(data‖0) ^ a (Ergebnis mit Bits des Anhangs addiert)
        let wanted = (UInt32(crc) & 0xFFFF) ^ 0xFFFF
        return (0..<16).map { UInt8((wanted >> UInt32(15 - $0)) & 1) }
    }
}

// MARK: - Faltungscode K = 5

public enum ConvK5 {
    /// Rate 1/2, Polynome G1 = 1 + D³ + D⁴ (0x13) und G2 = 1 + D + D² + D⁴ (0x1D), Ausgabe (g1, g2) je Eingangsbit.
    public static func encode(_ bits: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bits.count * 2)
        var state = 0                                         // u(n-1) in Bit 3 … u(n-4) in Bit 0
        for bit in bits {
            let reg = (Int(bit & 1) << 4) | state
            out.append(UInt8((reg & 0x13).nonzeroBitCount & 1))
            out.append(UInt8((reg & 0x1D).nonzeroBitCount & 1))
            state = reg >> 1
        }
        return out
    }

    /// Viterbi-Decoder mit weichen Werten (positiv = Bit 1). Beginnt und endet im Zustand 0 (Nachlauf aus vier Nullen).
    public static func decode(soft: [Float]) -> [UInt8] {
        let steps = soft.count / 2
        guard steps > 0 else { return [] }
        let negInf: Float = -1e30
        var metric = [Float](repeating: negInf, count: 16)
        metric[0] = 0
        var from = [UInt8](repeating: 0, count: steps * 16)
        var input = [UInt8](repeating: 0, count: steps * 16)
        // Ausgangsbits je (Zustand, Eingang) vorab
        var out0 = [Bool](repeating: false, count: 32), out1 = [Bool](repeating: false, count: 32)
        for s in 0..<16 { for u in 0..<2 { let reg = (u << 4) | s; out0[reg] = (reg & 0x13).nonzeroBitCount & 1 == 1; out1[reg] = (reg & 0x1D).nonzeroBitCount & 1 == 1 } }
        for t in 0..<steps {
            let r0 = soft[2 * t], r1 = soft[2 * t + 1]
            var next = [Float](repeating: negInf, count: 16)
            for s in 0..<16 where metric[s] > negInf / 2 {
                for u in 0..<2 {
                    let reg = (u << 4) | s
                    let cost = (out0[reg] ? r0 : -r0) + (out1[reg] ? r1 : -r1)
                    let target = reg >> 1
                    let value = metric[s] + cost
                    if value > next[target] { next[target] = value; from[t * 16 + target] = UInt8(s); input[t * 16 + target] = UInt8(u) }
                }
            }
            metric = next
        }
        var state = 0
        var bits = [UInt8](repeating: 0, count: steps)
        for t in stride(from: steps - 1, through: 0, by: -1) {
            bits[t] = input[t * 16 + state]
            state = Int(from[t * 16 + state])
        }
        return bits
    }
}

// MARK: - Symbole ↔ Bits

public enum FourFSKBits {
    /// Zwei weiche Bitwerte (positiv = 1) aus einem Symbolpegel: erstes Bit (oberes) = Vorzeichen, zweites Bit = Betrag > 2
    public static func soft(_ level: Float) -> (Float, Float) { (-level / 3, abs(level) - 2) }

    /// Harte Bits eines Symbols (oberes zuerst)
    public static func hard(_ level: Float) -> (UInt8, UInt8) {
        let d = FourFSK.dibit(ofLevel: level)
        return ((d >> 1) & 1, d & 1)
    }

    public static func hardBits(_ symbols: ArraySlice<Float>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(symbols.count * 2)
        for s in symbols { let h = hard(s); out.append(h.0); out.append(h.1) }
        return out
    }
}
