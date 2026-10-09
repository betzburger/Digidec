// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// P25 Phase 1 (APCO Project 25, TIA-102.BAAA): C4FM, 4800 Symbole/s, vier Pegel (Dibit +3 → 01, +1 → 00, −1 → 10, −3 → 11).
//
// Jede Einheit beginnt mit dem Rahmensynchronwort FS (24 Symbole, nur äußere Pegel) und der Netzkennung NID (32 Symbole: NAC 12 Bit,
// DUID 4 Bit, BCH (63,16) und ein Paritätsbit). Alle 36 Symbole steht ein Statussymbol (belegt/frei), das nicht zum Inhalt gehört.
//   HDU   (DUID 0x0, 396 Symbole): Kopf mit MI, Hersteller, Algorithmus, Schlüsselnummer und Gruppe, 36 Golay-Wörter, RS (36,20,17)
//   TDU   (0x3, 72): Ende ohne Rufinformation
//   LDU1  (0x5, 864): neun IMBE-Sprachrahmen, dazwischen die Linksteuerung (LC, 12 Hexwörter, Hamming (10,6), RS (24,12,13)) und die Zusatzdaten LSD
//   TSDU  (0x7, veränderlich): Steuerkanal (hier nur erkannt)
//   LDU2  (0xA, 864): neun IMBE-Sprachrahmen, dazwischen Verschlüsselung (MI, Algorithmus, Schlüsselnummer; 16 Hexwörter, RS (24,16,9))
//   PDU   (0xC): Paketdaten (hier nur erkannt)
//   TDULC (0xF, 216): Ende mit Linksteuerung (6 Golay-(24,12)-Wörter, RS (24,12,13))

public enum P25 {
    public static let baud = 4800.0
    public static let syncSymbols = 24
    public static let nidSymbols = 32
    /// FS = 0x5575F5FF77FF
    public static let fs: [Float] = [3, 3, 3, 3, 3, -3, 3, 3, -3, -3, 3, 3, -3, -3, -3, -3, 3, -3, 3, -3, -3, -3, -3, -3]

    public enum DUID: Int, Sendable {
        case hdu = 0x0, tdu = 0x3, ldu1 = 0x5, tsdu = 0x7, ldu2 = 0xA, pdu = 0xC, tdulc = 0xF

        public static let valid = [0x0, 0x3, 0x5, 0x7, 0xA, 0xC, 0xF]

        /// Länge der Einheit in Symbolen einschließlich Statussymbolen (nil: veränderlich)
        public var length: Int? {
            switch self {
            case .hdu: return 396
            case .tdu: return 72
            case .ldu1, .ldu2: return 864
            case .tdulc: return 216
            case .tsdu, .pdu: return nil
            }
        }

        public var name: String {
            switch self {
            case .hdu: return "HDU"
            case .tdu: return "TDU"
            case .ldu1: return "LDU1"
            case .ldu2: return "LDU2"
            case .tdulc: return "TDULC"
            case .tsdu: return "TSDU"
            case .pdu: return "PDU"
            }
        }
    }

    /// Symbolindex im Rahmen (mit Statussymbolen) des k-ten Inhaltssymbols
    public static func frameIndex(ofContent k: Int) -> Int { k + k / 35 }

    /// Algorithmenkennung → Name (0x80 = offen)
    public static func algorithmName(_ id: Int) -> String {
        switch id {
        case 0x80, 0x00: return "offen"
        case 0x81: return "DES-OFB"
        case 0x84: return "AES-256"
        case 0x85: return "DES-XL"
        case 0x9F: return "DES (Motorola)"
        case 0xA0: return "DVI-XL"
        case 0xAA: return "ADP (RC4)"
        case 0x89: return "AES-128"
        default: return String(format: "0x%02X", id)
        }
    }

    /// Hersteller (MFID) → Name (Auswahl)
    public static func manufacturerName(_ id: Int) -> String {
        switch id {
        case 0x00, 0x01: return "Standard"
        case 0x09: return "Aselsan"
        case 0x10: return "Motorola"
        case 0x20: return "Racal"
        case 0x28: return "Transcrypt"
        case 0x30: return "Harris"
        case 0x34: return "Kenwood"
        case 0x38: return "Bendix/King"
        case 0x40: return "Midland"
        case 0x68: return "Tait"
        case 0x6C: return "Relm"
        case 0x7C: return "EFJohnson"
        case 0x90: return "Motorola"
        case 0xA4: return "Harris"
        default: return String(format: "MFID 0x%02X", id)
        }
    }
}

// MARK: - GF(64) und Reed-Solomon

public enum GF64 {
    /// Erzeugerpolynom x⁶ + x + 1
    public static let exp: [UInt8] = {
        var t = [UInt8](repeating: 0, count: 126)
        var v = 1
        for i in 0..<126 {
            t[i] = UInt8(v)
            v <<= 1
            if v & 0x40 != 0 { v ^= 0x43 }
        }
        return t
    }()
    public static let log: [Int] = {
        var t = [Int](repeating: -1, count: 64)
        for i in 0..<63 { t[Int(exp[i])] = i }
        return t
    }()

    public static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        if a == 0 || b == 0 { return 0 }
        return exp[log[Int(a)] + log[Int(b)]]
    }

    public static func inv(_ a: UInt8) -> UInt8 { exp[(63 - log[Int(a)]) % 63] }
    public static func div(_ a: UInt8, _ b: UInt8) -> UInt8 { a == 0 ? 0 : exp[(log[Int(a)] - log[Int(b)] + 63) % 63] }
    static func pow(_ e: Int) -> UInt8 { exp[((e % 63) + 63) % 63] }
}

/// Verkürzter Reed-Solomon-Code über GF(64) mit den Nullstellen α¹ … α^(n−k); Symbole in Sendereihenfolge (das erste hat den höchsten Grad)
public struct P25RS: Sendable {
    public let n: Int
    public let k: Int
    var parityCount: Int { n - k }
    private let generator: [UInt8]                  // Koeffizienten g₀ … g_{2t} (g_{2t} = 1)

    public static let rs24_12_13 = P25RS(n: 24, k: 12)
    public static let rs24_16_9 = P25RS(n: 24, k: 16)
    public static let rs36_20_17 = P25RS(n: 36, k: 20)

    public init(n: Int, k: Int) {
        self.n = n
        self.k = k
        var g: [UInt8] = [1]
        for i in 1...(n - k) {
            let root = GF64.pow(i)
            var next = [UInt8](repeating: 0, count: g.count + 1)
            for (j, c) in g.enumerated() {
                next[j + 1] ^= c
                next[j] ^= GF64.mul(c, root)
            }
            g = next
        }
        generator = g
    }

    /// Prüfsymbole zu k Datensymbolen (in Sendereihenfolge)
    public func parity(of data: [UInt8]) -> [UInt8] {
        precondition(data.count == k)
        let p = n - k
        var reg = [UInt8](repeating: 0, count: p)           // reg[p−1] = höchster Koeffizient
        for d in data {
            let feedback = d ^ reg[p - 1]
            for j in stride(from: p - 1, to: 0, by: -1) { reg[j] = reg[j - 1] ^ GF64.mul(feedback, generator[j]) }
            reg[0] = GF64.mul(feedback, generator[0])
        }
        return (0..<p).map { reg[p - 1 - $0] }
    }

    /// Korrigiert das Wort (n Symbole) an Ort und Stelle; Rückgabe: Zahl der korrigierten Symbole, nil wenn nicht korrigierbar
    public func decode(_ word: inout [UInt8]) -> Int? {
        precondition(word.count == n)
        let twoT = n - k
        var s = [UInt8](repeating: 0, count: twoT + 1)     // s[1…2t]
        var any = false
        for i in 1...twoT {
            var acc: UInt8 = 0
            for (t, c) in word.enumerated() where c != 0 { acc ^= GF64.pow(i * (n - 1 - t) + GF64.log[Int(c)]) }
            s[i] = acc
            if acc != 0 { any = true }
        }
        if !any { return 0 }
        // Berlekamp-Massey
        var c: [UInt8] = [1] + [UInt8](repeating: 0, count: twoT)
        var b: [UInt8] = [1] + [UInt8](repeating: 0, count: twoT)
        var l = 0, m = 1
        var bd: UInt8 = 1
        for nIdx in 0..<twoT {
            var d = s[nIdx + 1]
            if l > 0 { for i in 1...l { d ^= GF64.mul(c[i], s[nIdx + 1 - i]) } }
            if d == 0 { m += 1; continue }
            let factor = GF64.div(d, bd)
            let t = c
            for i in 0..<(twoT + 1 - m) { c[i + m] ^= GF64.mul(factor, b[i]) }
            if 2 * l <= nIdx { l = nIdx + 1 - l; b = t; bd = d; m = 1 } else { m += 1 }
        }
        guard l <= twoT / 2 else { return nil }
        // Nullstellen (Chien): Fehler an Grad p, wenn Λ(α^−p) = 0
        var positions: [Int] = []
        for p in 0..<n {
            var acc: UInt8 = 0
            for i in 0...l where c[i] != 0 { acc ^= GF64.pow(GF64.log[Int(c[i])] - i * p) }
            if acc == 0 { positions.append(p) }
        }
        guard positions.count == l else { return nil }
        // Fehlerwerte (Forney)
        var omega = [UInt8](repeating: 0, count: twoT)
        for i in 0..<twoT {
            var acc: UInt8 = 0
            for j in 0...min(i, l) { acc ^= GF64.mul(c[j], s[i - j + 1]) }
            omega[i] = acc
        }
        var fixed = word
        for p in positions {
            var num: UInt8 = 0
            for i in 0..<twoT where omega[i] != 0 { num ^= GF64.pow(GF64.log[Int(omega[i])] + i * (63 - p % 63)) }
            var den: UInt8 = 0
            for i in stride(from: 1, through: l, by: 2) where c[i] != 0 { den ^= GF64.pow(GF64.log[Int(c[i])] + (i - 1) * (63 - p % 63)) }
            guard den != 0 else { return nil }
            fixed[n - 1 - p] ^= GF64.div(num, den)
        }
        // Gegenprobe: die Syndrome des korrigierten Wortes müssen null sein
        for i in 1...twoT {
            var acc: UInt8 = 0
            for (t, v) in fixed.enumerated() where v != 0 { acc ^= GF64.pow(i * (n - 1 - t) + GF64.log[Int(v)]) }
            if acc != 0 { return nil }
        }
        word = fixed
        return positions.count
    }
}

// MARK: - Golay, Hamming, BCH

public enum P25Codes {
    // Golay (24,12): 23-Bit-Golay mit Gesamtparität; Wort als [Parität 12 | Daten 12]
    private static func golay23(_ data: Int) -> Int {
        var cw = data & 0xFFF
        let c = cw
        for _ in 0..<12 {
            if cw & 1 != 0 { cw ^= 0xAE3 }
            cw >>= 1
        }
        return (cw << 12) | c
    }

    public static func golay24(_ data12: Int) -> Int {
        var cw = golay23(data12)
        if cw.nonzeroBitCount & 1 != 0 { cw ^= 0x800000 }
        return cw
    }

    private static let golayWords: [Int] = (0..<4096).map { golay24($0) }

    /// 24 gesendete Bits → 12 Datenbits (nur Kandidaten mit den oberen `zeroBits` Bit = 0), bis zu 3 Fehler. nil bei Überschreitung.
    /// Reihenfolge der Bits auf der Leitung: Daten (MSB zuerst), danach die zwölf Prüfbits so, dass das erste das niedrigstwertige ist.
    public static func golayDecode(data bits: ArraySlice<UInt8>, parity: ArraySlice<UInt8>, dataBits: Int) -> (data: Int, errors: Int)? {
        precondition(bits.count == dataBits && parity.count == 12)
        var word = 0
        for (i, p) in parity.enumerated() { word |= Int(p & 1) << (12 + i) }
        var d = 0
        for b in bits { d = (d << 1) | Int(b & 1) }
        word |= d << (12 - dataBits)
        var best = Int.max, bestData = 0
        for cand in 0..<(1 << dataBits) {
            let cw = golayWords[cand << (12 - dataBits)]
            let dist = (cw ^ word).nonzeroBitCount
            if dist < best { best = dist; bestData = cand }
        }
        return best <= 3 ? (bestData, best) : nil
    }

    /// Prüfbits (zwölf, niedrigstwertiges zuerst) zu Daten
    public static func golayParity(_ data: Int, dataBits: Int) -> [UInt8] {
        let cw = golayWords[(data & ((1 << dataBits) - 1)) << (12 - dataBits)]
        return (0..<12).map { UInt8((cw >> (12 + $0)) & 1) }
    }

    // Hamming (10,6,3): sechs Bits (erstes zuerst) und vier Prüfbits
    public static func hammingParity(_ hex: [UInt8]) -> [UInt8] {
        precondition(hex.count == 6)
        let rows: [[Int]] = [[0, 1, 2, 5], [0, 1, 3, 5], [0, 2, 3, 4], [1, 2, 3, 4]]
        return rows.map { r in r.reduce(UInt8(0)) { $0 ^ hex[$1] } }
    }

    /// Hexwort (6 Bit) mit vier Prüfbits; korrigiert ein Bit. Rückgabe: (Wort, Fehler), nil bei zwei Fehlern
    public static func hammingDecode(hex: [UInt8], parity: [UInt8]) -> (hex: [UInt8], errors: Int)? {
        let expected = hammingParity(hex)
        var syndrome = 0
        for i in 0..<4 { syndrome = (syndrome << 1) | Int(expected[i] ^ parity[i]) }
        if syndrome == 0 { return (hex, 0) }
        // Spalten der Prüfmatrix: Wirkung eines Fehlers in Datenbit j (j = 0 … 5) bzw. Prüfbit
        var table: [Int: Int] = [:]
        for j in 0..<6 {
            var one = [UInt8](repeating: 0, count: 6); one[j] = 1
            let p = hammingParity(one)
            table[p.reduce(0) { ($0 << 1) | Int($1) }] = j
        }
        if let j = table[syndrome] {
            var fixed = hex; fixed[j] ^= 1
            return (fixed, 1)
        }
        if [8, 4, 2, 1].contains(syndrome) { return (hex, 1) }                // Fehler in einem Prüfbit
        return nil
    }

    // BCH (63,16,23) der NID
    private static let bchGenerator: [UInt8] = {                              // Koeffizienten g₀ … g₄₇ (binär)
        var roots = Set<Int>()
        for i in 1...22 {
            var e = i
            repeat { roots.insert(e); e = (e * 2) % 63 } while e != i
        }
        var g: [UInt8] = [1]
        for r in roots.sorted() {
            let root = GF64.pow(r)
            var next = [UInt8](repeating: 0, count: g.count + 1)
            for (j, c) in g.enumerated() { next[j + 1] ^= c; next[j] ^= GF64.mul(c, root) }
            g = next
        }
        return g
    }()

    /// 63 Bit des BCH-Wortes (Sendereihenfolge, erstes Bit = Grad 62) zu 16 Datenbits (NAC 12, DUID 4)
    public static func bchEncode(_ data16: Int) -> [UInt8] {
        let degree = bchGenerator.count - 1                                    // 47
        var rem = [UInt8](repeating: 0, count: degree)
        for i in stride(from: 15, through: 0, by: -1) {
            let bit = UInt8((data16 >> i) & 1)
            let feedback = bit ^ rem[degree - 1]
            for j in stride(from: degree - 1, to: 0, by: -1) { rem[j] = rem[j - 1] ^ (feedback & bchGenerator[j]) }
            rem[0] = feedback & bchGenerator[0]
        }
        var out = (0..<16).map { UInt8((data16 >> (15 - $0)) & 1) }
        for j in stride(from: degree - 1, through: 0, by: -1) { out.append(rem[j]) }
        return out
    }

    private static let bchPacked: [UInt64] = (0..<65536).map { v in
        bchEncode(v).reduce(UInt64(0)) { ($0 << 1) | UInt64($1) }
    }
    private static let nacParity: [UInt64] = (0..<4096).map { bchPacked[$0 << 4] }
    private static let duidParity: [UInt64] = (0..<16).map { bchPacked[$0] }

    /// NID aus den ersten 63 Bit (Sendereihenfolge): NAC und DUID, bis zu 11 Bitfehler
    public static func bchDecode(_ bits: [UInt8]) -> (nac: Int, duid: DUIDValue, errors: Int)? {
        precondition(bits.count >= 63)
        var word: UInt64 = 0
        for b in bits.prefix(63) { word = (word << 1) | UInt64(b & 1) }
        var best = Int.max, bestNAC = 0, bestDUID = 0
        for duid in P25.DUID.valid {
            let d = duidParity[duid]
            for nac in 0..<4096 {
                let dist = (word ^ (nacParity[nac] ^ d)).nonzeroBitCount
                if dist < best { best = dist; bestNAC = nac; bestDUID = duid }
            }
        }
        return best <= 11 ? (bestNAC, bestDUID, best) : nil
    }

    public typealias DUIDValue = Int
}

// MARK: - IMBE-Sprachrahmen

public enum P25IMBE {
    // Verschachtelung: Dibit n der Funkstrecke belegt zwei Stellen [Zeile][Spalte] des Rahmens c0 … c7
    static let iW: [Int] = [0, 2, 4, 1, 3, 5, 0, 2, 4, 1, 3, 6, 0, 2, 4, 1, 3, 6, 0, 2, 4, 1, 3, 6, 0, 2, 4, 1, 3, 6, 0, 2, 4, 1, 3, 6,
                            0, 2, 5, 1, 3, 6, 0, 2, 5, 1, 3, 6, 0, 2, 5, 1, 3, 7, 0, 2, 5, 1, 3, 7, 0, 2, 5, 1, 4, 7, 0, 3, 5, 2, 4, 7]
    static let iX: [Int] = [22, 20, 10, 20, 18, 0, 20, 18, 8, 18, 16, 13, 18, 16, 6, 16, 14, 11, 16, 14, 4, 14, 12, 9, 14, 12, 2, 12, 10, 7, 12, 10, 0, 10, 8, 5,
                            10, 8, 13, 8, 6, 3, 8, 6, 11, 6, 4, 1, 6, 4, 9, 4, 2, 6, 4, 2, 7, 2, 0, 4, 2, 0, 5, 0, 13, 2, 0, 21, 3, 21, 11, 0]
    static let iY: [Int] = [1, 3, 5, 0, 2, 4, 1, 3, 6, 0, 2, 4, 1, 3, 6, 0, 2, 4, 1, 3, 6, 0, 2, 4, 1, 3, 6, 0, 2, 4, 1, 3, 6, 0, 2, 5,
                            1, 3, 6, 0, 2, 5, 1, 3, 6, 0, 2, 5, 1, 3, 6, 0, 2, 5, 1, 3, 7, 0, 2, 5, 1, 4, 7, 0, 3, 5, 2, 4, 7, 1, 3, 5]
    static let iZ: [Int] = [21, 19, 1, 21, 19, 9, 19, 17, 14, 19, 17, 7, 17, 15, 12, 17, 15, 5, 15, 13, 10, 15, 13, 3, 13, 11, 8, 13, 11, 1, 11, 9, 6, 11, 9, 14,
                            9, 7, 4, 9, 7, 12, 7, 5, 2, 7, 5, 10, 5, 3, 0, 5, 3, 8, 3, 1, 5, 3, 1, 6, 1, 14, 3, 1, 22, 4, 22, 12, 1, 22, 20, 2]

    /// 144 Bit der Funkstrecke (je Dibit zwei) → c0 … c7 (c0 … c3 je 23 Bit, c4 … c6 je 15, c7 7 Bit)
    public static func vectors(fromAir bits: [UInt8]) -> [[UInt8]] {
        precondition(bits.count == 144)
        var fr = [[UInt8]](repeating: [UInt8](repeating: 0, count: 23), count: 8)
        for n in 0..<72 {
            fr[iW[n]][iX[n]] = bits[2 * n]
            fr[iY[n]][iZ[n]] = bits[2 * n + 1]
        }
        return fr
    }

    public static func air(fromVectors fr: [[UInt8]]) -> [UInt8] {
        var bits = [UInt8](repeating: 0, count: 144)
        for n in 0..<72 {
            bits[2 * n] = fr[iW[n]][iX[n]]
            bits[2 * n + 1] = fr[iY[n]][iZ[n]]
        }
        return bits
    }

    private static func word(_ v: [UInt8], _ count: Int) -> Int {
        var w = 0
        for j in stride(from: count - 1, through: 0, by: -1) { w = (w << 1) | Int(v[j]) }
        return w
    }

    private static func pseudoRandom(_ u0: Int) -> [UInt8] {
        var pr = [Int](repeating: 0, count: 115)
        pr[0] = (16 * u0) & 0xFFFF
        for i in 1..<115 { pr[i] = (173 * pr[i - 1] + 13849) & 0xFFFF }
        return pr.map { UInt8($0 >> 15) }
    }

    /// Zahl der korrigierten Bits in c0 … c6 (Golay (23,12) für c0 … c3, Hamming (15,11) für c4 … c6); nil, wenn c0 unbrauchbar ist.
    public static func errorCount(air bits: [UInt8]) -> Int? { errorCount(vectors: vectors(fromAir: bits)) }

    /// Wie `errorCount(air:)`, aber aus den Vektoren c0 … c7
    public static func errorCount(vectors fr: [[UInt8]]) -> Int? {
        let c0 = Golay.decode23(word(fr[0], 23))
        var errors = c0.corrected
        let pr = pseudoRandom(c0.data)
        var offset = 1
        for i in 1...3 {
            var w = 0
            for j in stride(from: 22, through: 0, by: -1) { w = (w << 1) | Int(fr[i][j] ^ pr[offset + (22 - j)]) }
            offset += 23
            errors += Golay.decode23(w).corrected
        }
        for i in 4...6 {
            var w = 0
            for j in stride(from: 14, through: 0, by: -1) { w = (w << 1) | Int(fr[i][j] ^ pr[offset + (14 - j)]) }
            offset += 15
            errors += hamming15(w)
        }
        return errors
    }

    /// Hamming (15,11): Syndrom mit den vier Prüfmasken; 0 = fehlerfrei, sonst ein (korrigierbarer) Fehler
    private static func hamming15(_ w: Int) -> Int {
        for mask in [0x7f08, 0x78e4, 0x66d2, 0x55b1] where (w & mask).nonzeroBitCount & 1 != 0 { return 1 }
        return 0
    }

    /// Eine Prüfung ohne Bitfehler
    public static func isClean(air bits: [UInt8]) -> Bool { errorCount(air: bits) == 0 }

    /// 144 Bit → 18 Byte (MSB zuerst)
    public static func bytes(fromAir bits: [UInt8]) -> [UInt8] {
        stride(from: 0, to: 144, by: 8).map { start in (0..<8).reduce(UInt8(0)) { ($0 << 1) | (bits[start + $1] & 1) } }
    }

    public static func bits(fromBytes bytes: [UInt8]) -> [UInt8] {
        bytes.flatMap { b in (0..<8).map { UInt8((b >> UInt8(7 - $0)) & 1) } }
    }
}

// MARK: - Linksteuerung (LCW)

public struct P25LinkControl: Equatable, Sendable {
    public var format: Int            // 8 Bit: Schutz, Implizit/Explizit, Opcode
    public var mfid: Int
    public var serviceOptions: Int
    public var group: Int?
    public var target: Int?
    public var source: Int?
    public var protected: Bool { format & 0x80 != 0 }
    public var opcode: Int { format & 0x3F }
    public var emergency: Bool { serviceOptions & 0x80 != 0 }
    public var encrypted: Bool { serviceOptions & 0x40 != 0 }
    public var priority: Int { serviceOptions & 7 }

    public var title: String {
        switch opcode {
        case 0x00: return "Gruppenruf"
        case 0x03: return "Einzelruf"
        case 0x02: return "Gruppenkanal-Update"
        case 0x04: return "Gruppenkanal-Update (explizit)"
        case 0x06: return "Telefonie"
        case 0x09: return "Quellkennung (erweitert)"
        case 0x0A: return "Einzelruf (erweitert)"
        default: return String(format: "LC 0x%02X", opcode)
        }
    }

    /// 72 Bit Linksteuerung
    public static func parse(_ bits: [UInt8]) -> P25LinkControl? {
        guard bits.count >= 72 else { return nil }
        func v(_ from: Int, _ n: Int) -> Int { bits[from..<(from + n)].reduce(0) { ($0 << 1) | Int($1 & 1) } }
        var lc = P25LinkControl(format: v(0, 8), mfid: v(8, 8), serviceOptions: v(16, 8))
        guard !lc.protected else { return lc }
        if lc.mfid == 0 || lc.mfid == 1 {
            switch lc.opcode {
            case 0x00:
                lc.group = v(32, 16); lc.source = v(48, 24)
            case 0x03:
                lc.target = v(24, 24); lc.source = v(48, 24)
            case 0x0A:
                lc.target = v(16, 24); lc.source = v(40, 24)
            default: break
            }
        }
        return lc
    }
}

// MARK: - Diagnose

public enum P25Diagnosis {
    public enum Severity: Int, Sendable { case ok, waiting, problem }

    public struct Result: Equatable, Sendable {
        public var severity: Severity
        public var title: String
        public var advice: String
    }

    public static let silenceDB = -70.0

    public static func assess(inputDB: Double, stats: P25FramerStats, locked: Bool) -> Result {
        if inputDB < silenceDB {
            return Result(severity: .problem, title: "Kein Audio", advice: "Am Eingang kommt kein Signal an. P25 braucht das unbearbeitete FM-Diskriminator-Audio (Packet/Daten-Ausgang des Funkgeräts oder SDR-Programm mit FM-Audio ohne Entzerrung und ohne Hochpass).")
        }
        if locked {
            if stats.voiceFrames > 18, Double(stats.cleanFrames) / Double(stats.voiceFrames) < 0.2 {
                return Result(severity: .waiting, title: "Signal schwach oder verrauscht", advice: "Die Sprachrahmen haben viele Bitfehler. Ein stärkeres Signal oder genaueres Abstimmen hilft.")
            }
            return Result(severity: .ok, title: "P25-Signal wird empfangen", advice: "")
        }
        if stats.calls > 0 || stats.units > 0 { return Result(severity: .ok, title: "Warten auf die nächste Aussendung", advice: "") }
        return Result(severity: .waiting, title: "Warten auf P25", advice: "Noch keine P25-Synchronisation. Das Audio muss die C4FM-Daten mit 4800 Symbolen/s unverfälscht enthalten (nicht das fertig demodulierte Sprach-Audio), bei einem Empfänger mit etwa 12,5 kHz Filterbreite.")
    }
}
