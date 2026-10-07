// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Faltungsdecoder der Norm (Abschnitt 11.1): Beschränkungslänge 7, Rate 1/4, Erzeugerpolynome 133, 171, 145, 133 (oktal).
/// Weiche Eingangswerte (Int8; 0 = unbekannt, so stehen die herausgenommenen Bits der Punktierung), Entscheidung über den ganzen Block mit Endzustand 0.
public final class DABViterbi {
    public static let polynomials: [Int] = [0o133, 0o171, 0o145, 0o133]
    private static let states = 64

    /// Erwartete Ausgangsbits (vier, in Bits 0 … 3) je Eingangsbit und Zustand: Index `bit * 64 + state`
    private let expected: [UInt8]
    private var decisions: [UInt64] = []
    /// Positives Vorzeichen eines Eingangswerts bedeutet das Bit 1 (sonst 0); beide Lagen kommen vor, je nach Demodulator
    public var positiveIsOne = true

    public init() {
        var e = [UInt8](repeating: 0, count: 2 * Self.states)
        for bit in 0..<2 {
            for s in 0..<Self.states {
                let reg = (bit << 6) | s
                var out: UInt8 = 0
                for (i, p) in Self.polynomials.enumerated() {
                    out |= UInt8((reg & p).nonzeroBitCount & 1) << UInt8(i)
                }
                e[bit * 64 + s] = out
            }
        }
        expected = e
    }

    /// `soft` hat vier Werte je Schritt; `bitCount` Nutzbits, danach folgen sechs Endschritte. Rückgabe: `bitCount` Bits (0 oder 1).
    public func decode(soft: UnsafeBufferPointer<Int8>, bitCount: Int) -> [UInt8] {
        let steps = bitCount + 6
        precondition(soft.count >= steps * 4)
        if decisions.count < steps { decisions = [UInt64](repeating: 0, count: steps) }
        var metric = [Int32](repeating: Int32.min / 4, count: Self.states)
        metric[0] = 0
        var next = [Int32](repeating: 0, count: Self.states)
        let sign: Int32 = positiveIsOne ? 1 : -1
        // Zweigmetriken je Schritt für alle 16 möglichen Ausgangsmuster
        var branch = [Int32](repeating: 0, count: 16)
        expected.withUnsafeBufferPointer { exp in
            for k in 0..<steps {
                let r0 = sign * Int32(soft[4 * k]), r1 = sign * Int32(soft[4 * k + 1]), r2 = sign * Int32(soft[4 * k + 2]), r3 = sign * Int32(soft[4 * k + 3])
                for m in 0..<16 {
                    branch[m] = ((m & 1) != 0 ? r0 : -r0) + ((m & 2) != 0 ? r1 : -r1) + ((m & 4) != 0 ? r2 : -r2) + ((m & 8) != 0 ? r3 : -r3)
                }
                var dec: UInt64 = 0
                for ns in 0..<Self.states {
                    let bit = ns >> 5
                    let s0 = (ns & 31) << 1
                    let s1 = s0 | 1
                    let m0 = metric[s0] + branch[Int(exp[bit * 64 + s0])]
                    let m1 = metric[s1] + branch[Int(exp[bit * 64 + s1])]
                    if m1 > m0 { next[ns] = m1; dec |= UInt64(1) << UInt64(ns) } else { next[ns] = m0 }
                }
                decisions[k] = dec
                // Normieren
                let base = next[0]
                for s in 0..<Self.states { metric[s] = next[s] - base }
            }
        }
        var out = [UInt8](repeating: 0, count: bitCount)
        var state = 0
        var k = steps - 1
        while k >= 0 {
            if k < bitCount { out[k] = UInt8(state >> 5) }
            let x = Int((decisions[k] >> UInt64(state)) & 1)
            state = ((state & 31) << 1) | x
            k -= 1
        }
        return out
    }
}

public enum DABCRC {
    /// CRC-16 nach CCITT (Polynom 0x1021, Startwert 0xFFFF), das Ergebnis wird für die Übertragung invertiert
    public static func crc16(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return ~crc
    }

    public static func crc16(_ bytes: [UInt8]) -> UInt16 { bytes.withUnsafeBufferPointer { crc16($0) } }

    /// Feuercode für die Kopfzeile des DAB+-Überrahmens: Polynom x¹⁶ + x¹¹ + x⁵ + x³ + x² + x + 1 (0x782F), Startwert 0, Ergebnis nicht invertiert
    public static func fireCode(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x782F : crc << 1 }
        }
        return crc
    }
}
