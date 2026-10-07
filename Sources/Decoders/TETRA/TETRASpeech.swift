// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Kanalcodierung des TETRA-Sprachkanals TCH/S (ETSI EN 300 395-2, Abschnitt 5): Ein Sprachblock (432 Bits, 60 ms) trägt zwei
// Sprachrahmen zu je 137 Bits in drei Empfindlichkeitsklassen: Klasse 0 ungeschützt (2·51 Bits), Klasse 1 Rate 8/12
// (2·56 Bits), Klasse 2 Rate 8/18 mit 8 Prüfbits (2·30 Bits). Bei Blockraub (STCH in der ersten Hälfte) trägt die zweite Hälfte
// (216 Bits) nur einen Sprachrahmen (Klasse 2 mit Rate 8/17 und 4 Prüfbits).

public struct TETRASpeechFrame: Sendable, Equatable {
    /// 137 Bits eines Sprachrahmens (0/1)
    public var bits: [UInt8]
    /// Fehlerkennung (Prüfbits der Klasse 2 stimmen nicht)
    public var badFrame: Bool
    public init(bits: [UInt8], badFrame: Bool) {
        self.bits = bits
        self.badFrame = badFrame
    }
}

public enum TETRASpeech {
    public static let frameBits = 137
    public static let blockBits = 432
    public static let halfBlockBits = 216

    // Reihenfolge der Bits in den drei Klassen (1-basierte Plätze im Sprachrahmen)
    static let class0: [Int] = [35, 36, 37, 38, 39, 40, 41, 42, 43, 47, 48, 56, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 74, 75, 83, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 101, 102, 110, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 128, 129, 137]
    static let class1: [Int] = [58, 85, 112, 54, 81, 108, 135, 50, 77, 104, 131, 45, 72, 99, 126, 55, 82, 109, 136, 5, 13, 34, 8, 16, 17, 22, 23, 24, 25, 26, 6, 14, 7, 15, 60, 87, 114, 46, 73, 100, 127, 44, 71, 98, 125, 33, 49, 76, 103, 130, 59, 86, 113, 57, 84, 111]
    static let class2: [Int] = [18, 19, 20, 21, 31, 32, 53, 80, 107, 134, 1, 2, 3, 4, 9, 10, 11, 12, 27, 28, 29, 30, 52, 79, 106, 133, 51, 78, 105, 132]

    // Prüfbits der Klasse 2 (Plätze 1…60 bzw. 1…30 innerhalb der Klasse)
    static let crcTaps: [[Int]] = [
        [1, 5, 8, 9, 13, 15, 16, 17, 19, 21, 22, 24, 25, 31, 32, 35, 36, 38, 40, 43, 44, 45, 48, 49, 50, 51, 53, 54, 56],
        [2, 6, 9, 10, 14, 16, 17, 18, 20, 22, 23, 25, 26, 32, 33, 36, 37, 39, 41, 44, 45, 46, 49, 50, 51, 52, 54, 55, 57],
        [3, 7, 10, 11, 15, 17, 18, 19, 21, 23, 24, 26, 27, 33, 34, 37, 38, 40, 42, 45, 46, 47, 50, 51, 52, 53, 55, 56, 58],
        [1, 4, 5, 9, 11, 12, 13, 15, 17, 18, 20, 21, 27, 28, 31, 32, 34, 36, 39, 40, 41, 44, 45, 46, 47, 49, 50, 52, 57, 59],
        [2, 5, 6, 10, 12, 13, 14, 16, 18, 19, 21, 22, 28, 29, 32, 33, 35, 37, 40, 41, 42, 45, 46, 47, 48, 50, 51, 53, 58, 60],
        [3, 6, 7, 11, 13, 14, 15, 17, 19, 20, 22, 23, 29, 30, 33, 34, 36, 38, 41, 42, 43, 46, 47, 48, 49, 51, 52, 54, 59],
        [4, 7, 8, 12, 14, 15, 16, 18, 20, 21, 23, 24, 30, 31, 34, 35, 37, 39, 42, 43, 44, 47, 48, 49, 50, 52, 53, 55, 60],
        [1, 2, 3, 4, 8, 13, 14, 16, 19, 20, 22, 23, 25, 26, 27, 28, 29, 30, 32, 33, 34, 36, 37, 40, 41, 42, 44, 48, 50, 53, 56, 57, 58, 59, 60],
    ]
    static let crcTapsHalf: [[Int]] = [
        [1, 4, 5, 7, 9, 10, 11, 12, 16, 19, 20, 22, 24, 25, 26, 27],
        [1, 2, 4, 6, 7, 8, 9, 13, 16, 17, 19, 21, 22, 23, 24, 28],
        [2, 3, 5, 7, 8, 9, 10, 14, 17, 18, 20, 22, 23, 24, 25, 29],
        [3, 4, 6, 8, 9, 10, 11, 15, 18, 19, 21, 23, 24, 25, 26, 30],
    ]

    // Punktierung: je Eingangsbit werden g1, g2, g3 in dieser Reihenfolge gesendet, wenn die Tabelle 1 hat (Periode 8)
    static let puncture1: [[Bool]] = [[true, true, true, true, true, true, true, true],
                                      [true, false, true, false, true, false, true, false],
                                      [Bool](repeating: false, count: 8)]
    static let puncture2: [[Bool]] = [[Bool](repeating: true, count: 8),
                                      [Bool](repeating: true, count: 8),
                                      [true, false, false, false, true, false, false, false]]
    static let puncture2Half: [[Bool]] = [[Bool](repeating: true, count: 8),
                                          [Bool](repeating: true, count: 8),
                                          [true, false, false, false, false, false, false, false]]

    /// Punktierte Bits eines Blocks in das Mutterraster der Rate 1/3 stellen (0 = nicht gesendet)
    static func depuncture(_ coded: ArraySlice<SoftBit>, table: [[Bool]], steps: Int) -> [SoftBit] {
        var out = [SoftBit](repeating: 0, count: steps * 3)
        var idx = coded.startIndex
        for k in 0..<steps {
            for j in 0..<3 where table[j][k % 8] {
                if idx < coded.endIndex { out[k * 3 + j] = coded[idx] }
                idx += 1
            }
        }
        return out
    }

    static func punctureCount(table: [[Bool]], steps: Int) -> Int {
        var n = 0
        for k in 0..<steps { for j in 0..<3 where table[j][k % 8] { n += 1 } }
        return n
    }

    private static func parity(_ bits: [UInt8], taps: [Int], base: Int) -> UInt8 {
        var p: UInt8 = 0
        for t in taps { p ^= bits[base + t - 1] }
        return p
    }

    /// Sprachblock aus zwei Hälften (432 entwürfelte weiche Bits, vor der Entschachtelung) → zwei Sprachrahmen
    public static func decodeBlock(_ type4: [SoftBit]) -> [TETRASpeechFrame]? {
        guard type4.count == blockBits else { return nil }
        // Matrix-Entschachtelung: 24 Zeilen, 18 Spalten
        var d = [SoftBit](repeating: 0, count: blockBits)
        for col in 0..<18 { for line in 0..<24 { d[line * 18 + col] = type4[col * 24 + line] } }
        let c0 = d[0..<102]
        let c1 = d[102..<270]
        let c2 = d[270..<432]
        // Der Codierer läuft über beide Klassen durch: 112 Bits Klasse 1, dann 60 + 8 Prüfbits + 4 Endbits Klasse 2 (Zustand 0 am Ende)
        let mother = depuncture(c1, table: puncture1, steps: 112) + depuncture(c2, table: puncture2, steps: 72)
        let dec = TETRA.ConvolutionalCode.speech.decode(mother, steps: 184, terminated: true)
        let r1 = (bits: Array(dec.bits[0..<112]), metric: dec.metric)
        let r2 = (bits: Array(dec.bits[112..<184]), metric: dec.metric)
        // Klasse 2 prüfen: 8 Prüfbits
        var bad = false
        for i in 0..<8 where parity(r2.bits, taps: crcTaps[i], base: 0) != r2.bits[60 + i] { bad = true }
        var frames = [[UInt8]](repeating: [UInt8](repeating: 0, count: frameBits), count: 2)
        for i in 0..<51 {
            for f in 0..<2 { frames[f][class0[i] - 1] = c0[c0.startIndex + 2 * i + f] < 0 ? 1 : 0 }
        }
        for i in 0..<56 {
            for f in 0..<2 { frames[f][class1[i] - 1] = r1.bits[2 * i + f] }
        }
        for i in 0..<30 {
            for f in 0..<2 { frames[f][class2[i] - 1] = r2.bits[2 * i + f] }
        }
        return [TETRASpeechFrame(bits: frames[0], badFrame: bad), TETRASpeechFrame(bits: frames[1], badFrame: bad)]
    }

    /// Zweite Hälfte eines Sprachblocks bei Blockraub (216 entwürfelte weiche Bits) → ein Sprachrahmen
    public static func decodeHalf(_ type4: [SoftBit]) -> TETRASpeechFrame? {
        guard type4.count == halfBlockBits else { return nil }
        let d = TETRA.blockDeinterleave(type4, a: 101)
        let c0 = d[0..<51]
        let c1 = d[51..<135]
        let c2 = d[135..<216]
        let mother = depuncture(c1, table: puncture1, steps: 56) + depuncture(c2, table: puncture2Half, steps: 38)
        let dec = TETRA.ConvolutionalCode.speech.decode(mother, steps: 94, terminated: true)
        let r1 = (bits: Array(dec.bits[0..<56]), metric: dec.metric)
        let r2 = (bits: Array(dec.bits[56..<94]), metric: dec.metric)
        var bad = false
        for i in 0..<4 where parity(r2.bits, taps: crcTapsHalf[i], base: 0) != r2.bits[30 + i] { bad = true }
        var frame = [UInt8](repeating: 0, count: frameBits)
        for i in 0..<51 { frame[class0[i] - 1] = c0[c0.startIndex + i] < 0 ? 1 : 0 }
        for i in 0..<56 { frame[class1[i] - 1] = r1.bits[i] }
        for i in 0..<30 { frame[class2[i] - 1] = r2.bits[i] }
        return TETRASpeechFrame(bits: frame, badFrame: bad)
    }

    // MARK: Codierer (für Tests und den Sender)

    /// Zwei Sprachrahmen → 432 Kanalbits (verschachtelt, noch nicht verwürfelt)
    public static func encodeBlock(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var c0 = [UInt8](), c1 = [UInt8](), c2 = [UInt8]()
        for i in 0..<51 { c0.append(a[class0[i] - 1]); c0.append(b[class0[i] - 1]) }
        for i in 0..<56 { c1.append(a[class1[i] - 1]); c1.append(b[class1[i] - 1]) }
        for i in 0..<30 { c2.append(a[class2[i] - 1]); c2.append(b[class2[i] - 1]) }
        for i in 0..<8 { c2.append(parity(c2, taps: crcTaps[i], base: 0)) }
        c2 += [0, 0, 0, 0]
        func puncture(_ mother: [UInt8], table: [[Bool]], steps: Int) -> [UInt8] {
            var out = [UInt8]()
            for k in 0..<steps { for j in 0..<3 where table[j][k % 8] { out.append(mother[k * 3 + j]) } }
            return out
        }
        let mother = TETRA.ConvolutionalCode.speech.encode(c1 + c2)
        let p1 = puncture(Array(mother[0..<336]), table: puncture1, steps: 112)
        let p2 = puncture(Array(mother[336...]), table: puncture2, steps: 72)
        let d = c0 + p1 + p2
        var out = [UInt8](repeating: 0, count: blockBits)
        for col in 0..<18 { for line in 0..<24 { out[col * 24 + line] = d[line * 18 + col] } }
        return out
    }
}
