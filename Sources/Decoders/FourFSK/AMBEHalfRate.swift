// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Rahmenform des Sprachcodecs mit halber Rate (3600 bit/s Kanalbits, 2450 bit/s Nutzbits) für DMR, YSF (V/D-Modus 2) und NXDN:
// 72 Bit je 20 ms = vier Teile C0 (24 Bit: Golay), C1 (23 Bit: Golay, mit Pseudozufallsfolge verwürfelt), C2 (11 Bit), C3 (14 Bit).
// Der Sprachstick erwartet diese 72 Bit in der Reihenfolge der Funkstrecke (die Bytes MSB zuerst); YSF liefert nur die 49 Nutzbits
// (mit Wiederholungscode), daraus erzeugt `air72` den Rahmen neu. Die Tabellen der Bitreihenfolge und die Verwürfelung sind in
// der Literatur und in mbelib (ISC-Lizenz) beschrieben; hier eigene Umsetzung, an echten DMR-Aufnahmen und am Chip geprüft.

public enum AMBEHalfRate {
    public static let airBits = 72
    public static let dataBits = 49

    // Bitreihenfolge: Dibit n der Funkstrecke belegt zwei Stellen [Zeile][Spalte] des 4×24-Rahmens
    private static let rowA: [Int] = [0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 2, 0, 2, 0, 2, 0, 2, 0, 2, 0, 2, 0, 2]
    private static let colA: [Int] = [23, 10, 22, 9, 21, 8, 20, 7, 19, 6, 18, 5, 17, 4, 16, 3, 15, 2, 14, 1, 13, 0, 12, 10, 11, 9, 10, 8, 9, 7, 8, 6, 7, 5, 6, 4]
    private static let rowB: [Int] = [0, 2, 0, 2, 0, 2, 0, 2, 0, 3, 0, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3, 1, 3]
    private static let colB: [Int] = [5, 3, 4, 2, 3, 1, 2, 0, 1, 13, 0, 12, 22, 11, 21, 10, 20, 9, 19, 8, 18, 7, 17, 6, 16, 5, 15, 4, 14, 3, 13, 2, 12, 1, 11, 0]

    /// Verwürfelungsbit für C1 (k = 1 … 23): Pseudozufallsfolge, Startwert aus den 12 Bits von C0
    private static func scramble(_ u0: Int) -> [UInt8] {
        var pr = [Int](repeating: 0, count: 24)
        pr[0] = (16 * u0) & 0xFFFF
        for i in 1..<24 { pr[i] = (173 * pr[i - 1] + 13849) & 0xFFFF }
        return pr.map { UInt8($0 >> 15) }
    }

    private static func frame(fromAir bits: [UInt8]) -> [[UInt8]] {
        var fr = [[UInt8]](repeating: [UInt8](repeating: 0, count: 24), count: 4)
        for n in 0..<36 {
            fr[rowA[n]][colA[n]] = bits[2 * n]
            fr[rowB[n]][colB[n]] = bits[2 * n + 1]
        }
        return fr
    }

    private static func air(fromFrame fr: [[UInt8]]) -> [UInt8] {
        var bits = [UInt8](repeating: 0, count: 72)
        for n in 0..<36 {
            bits[2 * n] = fr[rowA[n]][colA[n]]
            bits[2 * n + 1] = fr[rowB[n]][colB[n]]
        }
        return bits
    }

    /// 49 Nutzbits (u0: 12, u1: 12, u2: 11, u3: 14) → 72 Bit der Funkstrecke
    public static func air72(fromData49 d: [UInt8]) -> [UInt8] {
        precondition(d.count == 49)
        var fr = [[UInt8]](repeating: [UInt8](repeating: 0, count: 24), count: 4)
        var u0 = 0
        for b in d[0..<12] { u0 = (u0 << 1) | Int(b & 1) }
        let c0 = Golay.encode23(u0)
        for j in 0..<23 { fr[0][j + 1] = UInt8((c0 >> j) & 1) }
        fr[0][0] = UInt8(c0.nonzeroBitCount & 1)                  // Gesamtparität (gerade)
        var u1 = 0
        for b in d[12..<24] { u1 = (u1 << 1) | Int(b & 1) }
        let c1 = Golay.encode23(u1)
        let pr = scramble(u0)
        for j in 0..<23 { fr[1][j] = UInt8((c1 >> j) & 1) ^ pr[23 - j] }
        for i in 0..<11 { fr[2][10 - i] = d[24 + i] & 1 }
        for i in 0..<14 { fr[3][13 - i] = d[35 + i] & 1 }
        return air(fromFrame: fr)
    }

    /// 72 Bit der Funkstrecke → 49 Nutzbits mit Fehlerkorrektur von C0 und C1; `corrected`: Zahl der korrigierten Bits
    public static func data49(fromAir bits: [UInt8]) -> (data: [UInt8], corrected: Int) {
        precondition(bits.count == 72)
        let fr = frame(fromAir: bits)
        var w0 = 0
        for j in stride(from: 23, through: 1, by: -1) { w0 = (w0 << 1) | Int(fr[0][j]) }
        let c0 = Golay.decode23(w0)
        let pr = scramble(c0.data)
        var w1 = 0
        for j in stride(from: 22, through: 0, by: -1) { w1 = (w1 << 1) | Int(fr[1][j] ^ pr[23 - j]) }
        let c1 = Golay.decode23(w1)
        var out: [UInt8] = []
        for i in 0..<12 { out.append(UInt8((c0.data >> (11 - i)) & 1)) }
        for i in 0..<12 { out.append(UInt8((c1.data >> (11 - i)) & 1)) }
        for j in stride(from: 10, through: 0, by: -1) { out.append(fr[2][j]) }
        for j in stride(from: 13, through: 0, by: -1) { out.append(fr[3][j]) }
        return (out, c0.corrected + c1.corrected)
    }

    /// C0 und C1 ohne Bitfehler (und Parität in Ordnung)?
    public static func isClean(_ bits: [UInt8]) -> Bool {
        let fr = frame(fromAir: bits)
        var w0 = 0
        for j in stride(from: 23, through: 1, by: -1) { w0 = (w0 << 1) | Int(fr[0][j]) }
        let c0 = Golay.decode23(w0)
        guard c0.corrected == 0 else { return false }
        let pr = scramble(c0.data)
        var w1 = 0
        for j in stride(from: 22, through: 0, by: -1) { w1 = (w1 << 1) | Int(fr[1][j] ^ pr[23 - j]) }
        return Golay.decode23(w1).corrected == 0
    }

    /// 72 Bit → 9 Byte, MSB zuerst (Format des Sprachsticks)
    public static func bytes(fromAir bits: [UInt8]) -> [UInt8] {
        stride(from: 0, to: bits.count, by: 8).map { start in
            (0..<8).reduce(UInt8(0)) { ($0 << 1) | (bits[start + $1] & 1) }
        }
    }

    public static func bits(fromBytes bytes: [UInt8]) -> [UInt8] {
        bytes.flatMap { b in (0..<8).map { UInt8((b >> UInt8(7 - $0)) & 1) } }
    }
}
