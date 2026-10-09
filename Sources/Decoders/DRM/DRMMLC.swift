// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Kanalcodierung von DRM (ETSI ES 201 980, Abschnitt 7): Energieverwischung, Faltungscode (Mutter code 1/4, K = 7) mit Punktierung,
// Bitverschachtelung, QAM mit mehrstufiger Codierung (MLC, Standardabbildung: 4-, 16-, 64-QAM). Hierarchische Abbildungen sind nicht enthalten.

public enum DRMScheme: Int, Sendable {
    case qam4 = 1, qam16 = 2, qam64 = 3
    public var levels: Int { rawValue }
}

/// Aufteilung eines codierten Blocks (FAC, SDC oder MSC-Rahmen): Zellen, Stufen, Bitzahlen und Raten je Stufe und Schutzteil
public struct DRMBlockLayout: Sendable {
    public var scheme: DRMScheme
    public var cells: Int
    public var n1: Int
    public var n2: Int
    /// Eingangsbits je Stufe und Teil [Stufe][A, B]
    public var bits: [[Int]]
    /// Punktierungsmuster je Stufe und Teil
    public var patterns: [[Int]]
    /// Bitverschachtelung je Stufe: −1 keine, 0 → t₀ = 13, 1 → t₀ = 21
    public var interleavers: [Int]
    public var isFAC = false

    public var bitsPartA: Int { bits.reduce(0) { $0 + $1[0] } }
    public var bitsPartB: Int { bits.reduce(0) { $0 + $1[1] } }
    public var totalBits: Int { bitsPartA + bitsPartB }

    static func rate(_ p: Int) -> Double { Double(DRMTables.puncturing[p].length) / Double(DRMTables.puncturing[p].ry) }

    /// FAC: 65 Zellen, 4-QAM, 72 Bit
    public static func fac() -> DRMBlockLayout {
        DRMBlockLayout(scheme: .qam4, cells: 65, n1: 0, n2: 65, bits: [[0, 72]], patterns: [[0, DRMTables.rateCombFAC]], interleavers: [1], isFAC: true)
    }

    /// SDC: 4- oder 16-QAM, alle Zellen im Teil B
    public static func sdc(cells: Int, scheme: DRMScheme) -> DRMBlockLayout? {
        switch scheme {
        case .qam4:
            let p = DRMTables.rateCombSDC4
            let m = DRMTables.puncturing[p].length * ((2 * cells - 12) / DRMTables.puncturing[p].ry)
            return DRMBlockLayout(scheme: .qam4, cells: cells, n1: 0, n2: cells, bits: [[0, m]], patterns: [[0, p]], interleavers: [1])
        case .qam16:
            let ps = DRMTables.rateCombSDC16
            let m = ps.map { DRMTables.puncturing[$0].length * ((2 * cells - 12) / DRMTables.puncturing[$0].ry) }
            return DRMBlockLayout(scheme: .qam16, cells: cells, n1: 0, n2: cells, bits: m.map { [0, $0] }, patterns: ps.map { [0, $0] }, interleavers: [0, 1])
        case .qam64: return nil
        }
    }

    /// MSC: Zellen je Rahmen, Längen des Teils A in Byte (Summe aller Ströme) und Schutzstufen
    public static func msc(cells: Int, scheme: DRMScheme, lengthA: Int, protectionA: Int, protectionB: Int) -> DRMBlockLayout? {
        let rows: [[Int]]
        let interleavers: [Int]
        switch scheme {
        case .qam16: rows = DRMTables.rateCombMSC16; interleavers = [0, 1]
        case .qam64: rows = DRMTables.rateCombMSC64; interleavers = [-1, 0, 1]
        case .qam4: return nil
        }
        guard protectionA < rows.count, protectionB < rows.count else { return nil }
        let levels = scheme.levels
        let ra = rows[protectionA], rb = rows[protectionB]
        let ryIcm = ra[levels]
        let sumR = (0..<levels).reduce(0.0) { $0 + rate(ra[$1]) }
        var n1 = Int((8.0 * Double(lengthA) / (2.0 * Double(ryIcm) * sumR)).rounded(.up)) * ryIcm
        if n1 > cells { n1 = 0 }
        let n2 = cells - n1
        var bits: [[Int]] = []
        var patterns: [[Int]] = []
        for i in 0..<levels {
            let pa = DRMTables.puncturing[ra[i]], pb = DRMTables.puncturing[rb[i]]
            let m1 = Int(Double(2 * n1) * Double(pa.length) / Double(pa.ry))
            let m2 = pb.length * ((2 * n2 - 12) / pb.ry)
            bits.append([m1, m2])
            patterns.append([ra[i], rb[i]])
        }
        return DRMBlockLayout(scheme: scheme, cells: cells, n1: n1, n2: n2, bits: bits, patterns: patterns, interleavers: interleavers)
    }
}

enum DRMCoding {
    // MARK: Energieverwischung

    static func disperse(_ bits: inout [UInt8]) {
        var reg = ~UInt32(0)
        for i in 0..<bits.count {
            let prbs = UInt8(((reg >> 4) & 1) ^ ((reg >> 8) & 1))
            reg = (reg << 1) | UInt32(prbs)
            bits[i] ^= prbs
        }
    }

    // MARK: Bitverschachtelung

    nonisolated(unsafe) private static var tableCache: [Int: [Int]] = [:]
    private static let lock = NSLock()

    static func interleaverTable(_ n: Int, _ t0: Int) -> [Int] {
        let key = n * 100 + t0
        lock.lock(); defer { lock.unlock() }
        if let t = tableCache[key] { return t }
        var s = 1
        while s <= n { s <<= 1 }                                    // kleinste Zweierpotenz über n (wie im Referenzcode)
        let q = s / 4 - 1
        var tab = [Int](repeating: 0, count: n)
        if n > 1 {
            for i in 1..<n {
                tab[i] = (t0 * tab[i - 1] + q) % s
                while tab[i] >= n { tab[i] = (t0 * tab[i] + q) % s }
            }
        }
        tableCache[key] = tab
        return tab
    }

    static func interleave<T>(_ data: [T], n1: Int, n2: Int, t0: Int) -> [T] {
        var out = data
        if n1 > 0 { let t = interleaverTable(n1, t0); for i in 0..<n1 { out[i] = data[t[i]] } }
        let t = interleaverTable(n2, t0)
        for i in 0..<n2 { out[n1 + i] = data[n1 + t[i]] }
        return out
    }

    static func deinterleave<T>(_ data: [T], n1: Int, n2: Int, t0: Int) -> [T] {
        var out = data
        if n1 > 0 { let t = interleaverTable(n1, t0); for i in 0..<n1 { out[t[i]] = data[i] } }
        let t = interleaverTable(n2, t0)
        for i in 0..<n2 { out[n1 + t[i]] = data[n1 + i] }
        return out
    }

    // MARK: Punktierung

    /// Muster je Eingangsbit (einschließlich der sechs Nachlaufbits)
    static func puncturePattern(inA: Int, inB: Int, patternA: Int, patternB: Int, cellsB: Int, isFAC: Bool) -> [Int] {
        let nin = inA + inB
        let pb = DRMTables.puncturing[patternB]
        let t = 2 * cellsB - 12
        let tailIndex = t - pb.ry * (t / pb.ry)
        let pa = DRMTables.puncturing[patternA]
        var out: [Int] = []
        out.reserveCapacity(nin + 6)
        var cnt = 0
        for i in 0..<(nin + 6) {
            if i < inA {
                out.append(pa.types[cnt]); cnt = (cnt + 1) % pa.length
            } else if i < nin || isFAC {
                if i == inA { cnt = 0 }
                out.append(pb.types[cnt]); cnt = (cnt + 1) % pb.length
            } else {
                if i == nin { cnt = 0 }
                out.append(DRMTables.tail[min(tailIndex, DRMTables.tail.count - 1)][cnt]); cnt += 1
            }
        }
        return out
    }

    // MARK: Faltungscode

    static func parity(_ v: Int) -> Int { v.nonzeroBitCount & 1 }

    /// Codiert Bits (ohne Nachlauf) und gibt die gesendeten Bits zurück
    static func encode(_ bits: [UInt8], pattern: [Int]) -> [UInt8] {
        var out: [UInt8] = []
        var reg = 0
        for i in 0..<(bits.count + 6) {
            reg = (reg << 1) & 0xFF
            if i < bits.count, bits[i] != 0 { reg |= 1 }
            for g in DRMTables.typeOutputs[pattern[i]] { out.append(UInt8(parity(reg & DRMTables.generators[g]))) }
        }
        return out
    }

    private static let trellisOut: [[UInt8]] = {                        // [Zustand * 2 + Bit] → vier Ausgangsbits
        var t = [[UInt8]](repeating: [0, 0, 0, 0], count: 128)
        for s in 0..<64 { for b in 0..<2 {
            let reg = ((s << 1) | b) & 0x7F
            t[s * 2 + b] = (0..<4).map { UInt8(parity(reg & DRMTables.generators[$0])) }
        } }
        return t
    }()

    /// Viterbi-Decoder mit weichen Werten (positiv = Bit 1); `soft` enthält die empfangenen Bits in Sendereihenfolge. Rückgabe: `inputBits` Datenbits.
    static func viterbi(soft: [Float], pattern: [Int], inputBits: Int) -> [UInt8] {
        let steps = pattern.count
        var metric = [Float](repeating: -1e30, count: 64)
        metric[0] = 0
        var next = [Float](repeating: 0, count: 64)
        var decisions = [UInt64](repeating: 0, count: steps)
        var pos = 0
        for i in 0..<steps {
            let outs = DRMTables.typeOutputs[pattern[i]]
            let s = soft[pos..<(pos + outs.count)]
            pos += outs.count
            // Zweigmetriken für alle 128 Übergänge
            for ns in 0..<64 { next[ns] = -1e30 }
            let allowedOne = i < inputBits
            var dec: UInt64 = 0
            for st in 0..<64 where metric[st] > -1e29 {
                for b in 0..<2 where b == 0 || allowedOne {
                    let o = trellisOut[st * 2 + b]
                    var m = metric[st]
                    var k = 0
                    for g in outs { m += o[g] != 0 ? s[s.startIndex + k] : -s[s.startIndex + k]; k += 1 }
                    let ns = ((st << 1) | b) & 0x3F
                    if m > next[ns] {
                        next[ns] = m
                        if st & 0x20 != 0 { dec |= UInt64(1) << UInt64(ns) } else { dec &= ~(UInt64(1) << UInt64(ns)) }
                    }
                }
            }
            decisions[i] = dec
            swap(&metric, &next)
        }
        var state = 0
        var bits = [UInt8](repeating: 0, count: steps)
        for i in stride(from: steps - 1, through: 0, by: -1) {
            bits[i] = UInt8(state & 1)
            let hi = (decisions[i] >> UInt64(state)) & 1
            state = (state >> 1) | (Int(hi) << 5)
        }
        return Array(bits[0..<inputBits])
    }

    // MARK: QAM

    static func table(_ scheme: DRMScheme) -> [Float] {
        switch scheme {
        case .qam4: return DRMTables.qam4
        case .qam16: return DRMTables.qam16
        case .qam64: return DRMTables.qam64
        }
    }

    /// Zellenwerte aus den Bits der Stufen (je 2N Bits je Stufe: gerade Stellen Realteil, ungerade Imaginärteil)
    static func map(levels: [[UInt8]], scheme: DRMScheme, cells: Int) -> [(Float, Float)] {
        let t = table(scheme)
        let n = scheme.levels
        return (0..<cells).map { i in
            var ir = 0, ii = 0
            for l in 0..<n { ir = (ir << 1) | Int(levels[l][2 * i] & 1); ii = (ii << 1) | Int(levels[l][2 * i + 1] & 1) }
            return (t[ir], t[ii])
        }
    }

    /// Weicher Wert (positiv = Bit 1) der Stufe `level` für einen Achsenwert `v`. `known` gibt je Stufe 0/1 für bekannte Bits, −1 für unbekannte.
    static func softBit(value v: Float, level: Int, known: [Int], table t: [Float], levels n: Int) -> Float {
        var d0 = Float.greatestFiniteMagnitude, d1 = Float.greatestFiniteMagnitude
        for idx in 0..<t.count {
            var match = true
            for l in 0..<n where l != level && known[l] >= 0 {
                if ((idx >> (n - 1 - l)) & 1) != known[l] { match = false; break }
            }
            guard match else { continue }
            let d = (v - t[idx]) * (v - t[idx])
            if (idx >> (n - 1 - level)) & 1 == 0 { d0 = min(d0, d) } else { d1 = min(d1, d) }
        }
        if d0 == .greatestFiniteMagnitude { d0 = d1 + 1 }
        if d1 == .greatestFiniteMagnitude { d1 = d0 + 1 }
        return d0 - d1
    }

    // MARK: Gesamte Decodierung

    /// Decodiert die entzerrten Zellen eines Blocks. `weights` gewichtet die Zuverlässigkeit je Zelle (Kanalleistung). Rückgabe: Bits nach Energieentwischung
    /// in der Reihenfolge Teil A (alle Stufen), Teil B (alle Stufen); `reencodedMismatch` ist der Anteil der Bits, die nach erneutem Codieren nicht mit den empfangenen
    /// harten Entscheidungen der ersten Stufe übereinstimmen (Güte des Empfangs, 0 = fehlerfrei).
    static func decode(cells: [(Float, Float)], weights: [Float], layout: DRMBlockLayout, iterations: Int = 1) -> (bits: [UInt8], quality: Float) {
        let n = layout.scheme.levels
        let t = table(layout.scheme)
        let total = 2 * layout.cells
        var axis = [Float](repeating: 0, count: total)
        var w = [Float](repeating: 1, count: total)
        for i in 0..<layout.cells {
            axis[2 * i] = cells[i].0; axis[2 * i + 1] = cells[i].1
            w[2 * i] = weights[i]; w[2 * i + 1] = weights[i]
        }
        var decoded = [[UInt8]](repeating: [], count: n)
        var coded = [[UInt8]](repeating: [], count: n)          // erneut codiert und verschachtelt
        var known = [[Int]](repeating: [Int](repeating: -1, count: n), count: total)
        var mismatch = 0, checked = 0
        for pass in 0...iterations {
            for level in 0..<n {
                // weiche Werte dieser Stufe
                var soft = [Float](repeating: 0, count: total)
                for k in 0..<total { soft[k] = softBit(value: axis[k], level: level, known: known[k], table: t, levels: n) * w[k] }
                let t0 = layout.interleavers[level]
                if t0 >= 0 { soft = deinterleave(soft, n1: 2 * layout.n1, n2: 2 * layout.n2, t0: t0 == 0 ? 13 : 21) }
                let pattern = puncturePattern(inA: layout.bits[level][0], inB: layout.bits[level][1], patternA: layout.patterns[level][0],
                                              patternB: layout.patterns[level][1], cellsB: layout.n2, isFAC: layout.isFAC)
                let inBits = layout.bits[level][0] + layout.bits[level][1]
                var punctured = [Float](); punctured.reserveCapacity(total)
                // Entpunktieren: das Eingangsmuster gibt vor, wie viele Bits je Schritt gesendet wurden; die gesendeten Bits stehen hintereinander
                punctured = soft
                decoded[level] = viterbi(soft: punctured, pattern: pattern, inputBits: inBits)
                var enc = encode(decoded[level], pattern: pattern)
                if pass == 0 && level == 0 {
                    for k in 0..<min(enc.count, soft.count) { checked += 1; if (soft[k] > 0) != (enc[k] != 0) { mismatch += 1 } }
                }
                if t0 >= 0 { enc = interleave(enc, n1: 2 * layout.n1, n2: 2 * layout.n2, t0: t0 == 0 ? 13 : 21) }
                coded[level] = enc
                for k in 0..<total where k < enc.count { known[k][level] = Int(enc[k]) }
            }
            // letzte Runde: die Bits der höheren Stufen stehen fest; weitere Runden verfeinern jede Stufe mit den übrigen als bekannt
            if pass == 0 { for k in 0..<total { for l in 0..<n { known[k][l] = Int(coded[l][k]) } } }
        }
        // Teile zusammensetzen
        var out: [UInt8] = []
        out.reserveCapacity(layout.totalBits)
        for l in 0..<n { out += decoded[l][0..<layout.bits[l][0]] }
        for l in 0..<n { out += decoded[l][layout.bits[l][0]..<(layout.bits[l][0] + layout.bits[l][1])] }
        disperse(&out)
        return (out, checked > 0 ? Float(mismatch) / Float(checked) : 0)
    }

    /// Codiert Nutzbits (Teil A, Teil B) zu Zellen (für Prüfungen und Sender)
    static func encodeBlock(bits input: [UInt8], layout: DRMBlockLayout) -> [(Float, Float)] {
        var bits = input
        disperse(&bits)
        let n = layout.scheme.levels
        var inA = 0
        var partsA: [[UInt8]] = [], partsB: [[UInt8]] = []
        var posA = 0, posB = layout.bitsPartA
        for l in 0..<n {
            partsA.append(Array(bits[posA..<(posA + layout.bits[l][0])])); posA += layout.bits[l][0]
        }
        for l in 0..<n {
            partsB.append(Array(bits[posB..<(posB + layout.bits[l][1])])); posB += layout.bits[l][1]
        }
        inA += 0
        var stages: [[UInt8]] = []
        for l in 0..<n {
            let pattern = puncturePattern(inA: layout.bits[l][0], inB: layout.bits[l][1], patternA: layout.patterns[l][0], patternB: layout.patterns[l][1], cellsB: layout.n2, isFAC: layout.isFAC)
            var enc = encode(partsA[l] + partsB[l], pattern: pattern)
            let t0 = layout.interleavers[l]
            if t0 >= 0 { enc = interleave(enc, n1: 2 * layout.n1, n2: 2 * layout.n2, t0: t0 == 0 ? 13 : 21) }
            stages.append(enc)
        }
        return map(levels: stages, scheme: layout.scheme, cells: layout.cells)
    }
}
