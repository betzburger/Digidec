// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Fehlerschutz-Codes von DMR (ETSI TS 102 361-1, Anhang B): Hamming (7,4,3), (13,9,3), (15,11,3), (16,11,4), Golay (20,8,7),
// quadratischer Rest (16,7,6), BPTC (196,96) und (128,77), Reed-Solomon (12,9) über GF(256).
// Die Codes sind durch ihre Prüfmatrizen (Syndrome der Spalten) beziehungsweise Erzeugermatrizen festgelegt; Reihenfolgen und
// Verschachtelungen wurden an einer echten Aufnahme (dsdcc/samples, `dmr_it_8.dis`) geprüft. Siehe THIRD_PARTY.md.

// MARK: - Hamming-Codes (systematisch, Prüfbits am Ende)

public struct HammingCode: Sendable {
    /// Syndrom je Bitstelle (zuerst die Datenbits, dann die Prüfbits als Einheitsvektoren)
    let columns: [Int]
    let dataBits: Int
    let parityBits: Int
    private let lookup: [Int: Int]

    init(dataSyndromes: [Int], parityBits: Int) {
        columns = dataSyndromes + (0..<parityBits).map { 1 << (parityBits - 1 - $0) }
        dataBits = dataSyndromes.count
        self.parityBits = parityBits
        var table: [Int: Int] = [:]
        for (position, syndrome) in columns.enumerated() { table[syndrome] = position }
        lookup = table
    }

    public var length: Int { dataBits + parityBits }

    func syndrome(_ bits: [UInt8]) -> Int {
        var s = 0
        for (position, bit) in bits.enumerated() where bit != 0 { s ^= columns[position] }
        return s
    }

    /// Korrigiert höchstens einen Fehler. `ok` = false: nicht korrigierbar (z. B. zwei Fehler).
    public func decode(_ bits: [UInt8]) -> (bits: [UInt8], ok: Bool, corrected: Bool) {
        let s = syndrome(bits)
        if s == 0 { return (bits, true, false) }
        guard let position = lookup[s] else { return (bits, false, false) }
        var fixed = bits
        fixed[position] ^= 1
        return (fixed, true, true)
    }

    public func encode(_ data: [UInt8]) -> [UInt8] {
        precondition(data.count == dataBits)
        var s = 0
        for (position, bit) in data.enumerated() where bit != 0 { s ^= columns[position] }
        return data + (0..<parityBits).map { UInt8((s >> (parityBits - 1 - $0)) & 1) }
    }

    /// Hamming (7,4,3): TACT im CACH
    public static let h74 = HammingCode(dataSyndromes: [0b101, 0b111, 0b110, 0b011], parityBits: 3)
    /// Hamming (13,9,3): Spalten von BPTC (196,96)
    public static let h139 = HammingCode(dataSyndromes: [0b1111, 0b1110, 0b0111, 0b1010, 0b0101, 0b1011, 0b1100, 0b0110, 0b0011], parityBits: 4)
    /// Hamming (15,11,3): Zeilen von BPTC (196,96)
    public static let h1511 = HammingCode(dataSyndromes: [0b1001, 0b1101, 0b1111, 0b1110, 0b0111, 0b1010, 0b0101, 0b1011, 0b1100, 0b0110, 0b0011], parityBits: 4)
    /// Hamming (16,11,4): Zeilen von BPTC (128,77), erweitert (zwei Fehler werden erkannt)
    public static let h16114 = HammingCode(dataSyndromes: [0b10011, 0b11010, 0b11111, 0b11100, 0b01110, 0b10101, 0b01011, 0b10110, 0b11001, 0b01101, 0b00111], parityBits: 5)
}

// MARK: - Codes mit Erzeugermatrix (kleine Tabelle, Decodierung durch das nächste Codewort)

public struct TableCode: Sendable {
    public let dataBits: Int
    public let length: Int
    let words: [[UInt8]]

    init(generator rows: [[UInt8]]) {
        dataBits = rows.count
        length = rows[0].count
        var all: [[UInt8]] = []
        for message in 0..<(1 << rows.count) {
            var word = [UInt8](repeating: 0, count: rows[0].count)
            for i in 0..<rows.count where (message >> (rows.count - 1 - i)) & 1 != 0 {
                for j in 0..<word.count { word[j] ^= rows[i][j] }
            }
            all.append(word)
        }
        words = all
    }

    public func encode(_ data: Int) -> [UInt8] { words[data] }

    /// Nächstes Codewort; `maxDistance` = größter erlaubter Abstand (Fehlerzahl). `nil`, wenn keins nah genug ist.
    public func decode(_ bits: [UInt8], maxDistance: Int) -> (data: Int, distance: Int)? {
        var best = (data: 0, distance: Int.max)
        for (message, word) in words.enumerated() {
            var d = 0
            for j in 0..<length where word[j] != bits[j] { d += 1 }
            if d < best.distance { best = (message, d) }
        }
        return best.distance <= maxDistance ? best : nil
    }

    /// Golay (20,8,7): Slot Type (Farbcode 4 Bit, Datentyp 4 Bit), korrigiert bis zu 3 Fehler
    public static let golay208 = TableCode(generator: [
        [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 1, 1, 0, 1, 0],
        [0, 1, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1],
        [0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1],
        [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0, 0, 1, 1, 1],
        [0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 1, 1, 1, 0, 0, 0, 1, 1, 0],
        [0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 1, 0, 1, 1, 1],
        [0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1, 0, 0, 1, 1, 1, 1, 1, 0],
        [0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 1, 0, 1, 0, 1, 1]
    ])

    /// Quadratischer-Rest-Code (16,7,6): EMB (Farbcode 4 Bit, PI 1 Bit, LCSS 2 Bit), korrigiert bis zu 2 Fehler
    public static let qr1676 = TableCode(generator: [
        [1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 1],
        [0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1, 0],
        [0, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0, 1, 1, 1],
        [0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 1, 0],
        [0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 0, 1],
        [0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 1],
        [0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 1]
    ])
}

// MARK: - BPTC (196,96): Sprach-Kopf, Abschluss, Steuerdaten

public enum BPTC196 {
    /// 196 empfangene Bits → 96 Nutzbits. `errors`: nach zwei Durchläufen verbleibende nicht korrigierbare Zeilen und Spalten.
    public static func decode(_ info: [UInt8]) -> (data: [UInt8], errors: Int) {
        precondition(info.count == 196)
        var deinterleaved = [UInt8](repeating: 0, count: 196)
        for i in 0..<196 { deinterleaved[(i * 13) % 196] = info[i] & 1 }
        var matrix = (0..<13).map { row in (0..<15).map { deinterleaved[1 + row * 15 + $0] } }
        var errors = 0
        for _ in 0..<2 {
            errors = 0
            for row in 0..<9 {
                let r = HammingCode.h1511.decode(matrix[row])
                matrix[row] = r.bits
                if !r.ok { errors += 1 }
            }
            for column in 0..<15 {
                let r = HammingCode.h139.decode((0..<13).map { matrix[$0][column] })
                for row in 0..<13 { matrix[row][column] = r.bits[row] }
                if !r.ok { errors += 1 }
            }
        }
        var data = Array(matrix[0][3..<11])
        for row in 1..<9 { data += matrix[row][0..<11] }
        return (data, errors)
    }

    public static func encode(_ data: [UInt8]) -> [UInt8] {
        precondition(data.count == 96)
        var matrix = [[UInt8]](repeating: [UInt8](repeating: 0, count: 15), count: 13)
        var position = 0
        for column in 3..<11 { matrix[0][column] = data[position]; position += 1 }
        for row in 1..<9 { for column in 0..<11 { matrix[row][column] = data[position]; position += 1 } }
        for row in 0..<9 { matrix[row] = HammingCode.h1511.encode(Array(matrix[row][0..<11])) }
        for column in 0..<15 {
            let word = HammingCode.h139.encode((0..<9).map { matrix[$0][column] })
            for row in 9..<13 { matrix[row][column] = word[row] }
        }
        var deinterleaved = [UInt8](repeating: 0, count: 196)
        for row in 0..<13 { for column in 0..<15 { deinterleaved[1 + row * 15 + column] = matrix[row][column] } }
        return (0..<196).map { deinterleaved[($0 * 13) % 196] }
    }
}

// MARK: - BPTC (128,77): eingebettete Link-Control-Information

public enum BPTC128 {
    /// 128 Bit (Spalte für Spalte in acht Zeilen zu je 16 Spalten gelegt, wie sie aus vier Fragmenten entstehen) → 77 Bit
    public static func decode(_ bits: [UInt8]) -> (data: [UInt8], errors: Int) {
        precondition(bits.count == 128)
        var matrix = (0..<8).map { row in (0..<16).map { column in bits[column * 8 + row] } }
        var errors = 0
        for row in 0..<7 {
            let r = HammingCode.h16114.decode(matrix[row])
            matrix[row] = r.bits
            if !r.ok { errors += 1 }
        }
        for column in 0..<16 {
            let sum = (0..<7).reduce(0) { $0 ^ Int(matrix[$1][column]) }
            if sum != Int(matrix[7][column]) { errors += 1 }
        }
        var data: [UInt8] = []
        for row in 0..<2 { data += matrix[row][0..<11] }
        for row in 2..<7 { data += matrix[row][0..<10] }
        for row in 2..<7 { data.append(matrix[row][10]) }
        return (data, errors)
    }

    public static func encode(_ data: [UInt8]) -> [UInt8] {
        precondition(data.count == 77)
        var matrix = [[UInt8]](repeating: [UInt8](repeating: 0, count: 16), count: 8)
        var p = 0
        for row in 0..<2 { for column in 0..<11 { matrix[row][column] = data[p]; p += 1 } }
        for row in 2..<7 { for column in 0..<10 { matrix[row][column] = data[p]; p += 1 } }
        for row in 2..<7 { matrix[row][10] = data[p]; p += 1 }
        for row in 0..<7 { matrix[row] = HammingCode.h16114.encode(Array(matrix[row][0..<11])) }
        for column in 0..<16 { matrix[7][column] = (0..<7).reduce(0) { $0 ^ matrix[$1][column] } }
        var out = [UInt8](repeating: 0, count: 128)
        for row in 0..<8 { for column in 0..<16 { out[column * 8 + row] = matrix[row][column] } }
        return out
    }
}

// MARK: - Reed-Solomon (12,9) über GF(256), Polynom x⁸+x⁴+x³+x²+1

public enum ReedSolomon129 {
    private static let tables: (exp: [UInt8], log: [Int]) = {
        var exp = [UInt8](repeating: 0, count: 512)
        var log = [Int](repeating: 0, count: 256)
        var x = 1
        for i in 0..<255 {
            exp[i] = UInt8(x)
            log[x] = i
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11D }
        }
        for i in 255..<512 { exp[i] = exp[i - 255] }
        return (exp, log)
    }()

    static func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        a == 0 || b == 0 ? 0 : tables.exp[tables.log[Int(a)] + tables.log[Int(b)]]
    }

    static func power(_ exponent: Int) -> UInt8 { tables.exp[((exponent % 255) + 255) % 255] }

    /// Syndrome zu den Nullstellen α¹, α², α³ (erstes Byte = höchste Potenz)
    public static func syndromes(_ word: [UInt8]) -> [UInt8] {
        (1...3).map { j in word.reduce(UInt8(0)) { multiply(power(j), $0) ^ $1 } }
    }

    /// Prüfbytes zu 9 Nutzbytes: Rest der Division durch (x+α)(x+α²)(x+α³)
    public static func parity(_ message: [UInt8]) -> [UInt8] {
        precondition(message.count == 9)
        // g(x) = x³ + g2 x² + g1 x + g0
        var g: [UInt8] = [1]
        for j in 1...3 {
            var next = [UInt8](repeating: 0, count: g.count + 1)
            for (i, c) in g.enumerated() {
                next[i] ^= c                                  // · x
                next[i + 1] ^= multiply(c, power(j))          // · α^j
            }
            g = next
        }
        var remainder = message + [0, 0, 0]
        for i in 0..<9 where remainder[i] != 0 {
            let factor = remainder[i]
            for k in 0..<g.count { remainder[i + k] ^= multiply(g[k], factor) }
        }
        return Array(remainder[9..<12])
    }

    /// Prüft ein Wort aus 12 Bytes und korrigiert ein fehlerhaftes Byte. `nil`, wenn nicht korrigierbar.
    public static func correct(_ word: [UInt8]) -> (word: [UInt8], corrected: Bool)? {
        let s = syndromes(word)
        if s.allSatisfy({ $0 == 0 }) { return (word, false) }
        guard s[0] != 0, s[1] != 0, s[2] != 0 else { return nil }
        // Ein Fehler e an Potenz p: S1 = e·α^p, S2 = e·α^2p, S3 = e·α^3p
        let ratio1 = (tables.log[Int(s[1])] - tables.log[Int(s[0])] + 255) % 255
        let ratio2 = (tables.log[Int(s[2])] - tables.log[Int(s[1])] + 255) % 255
        guard ratio1 == ratio2, ratio1 < 12 else { return nil }
        let e = multiply(s[0], power(-ratio1))
        var fixed = word
        fixed[11 - ratio1] ^= e
        return syndromes(fixed).allSatisfy { $0 == 0 } ? (fixed, true) : nil
    }
}
