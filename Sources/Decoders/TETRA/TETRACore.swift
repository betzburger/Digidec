// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// TETRA (ETSI EN 300 392-2, Sprachkanal EN 300 395-2): Bausteine der Bitübertragungs- und Sicherungsschicht.
// Verwürfelung, Verschachtelung, Faltungscode mit Punktierung, CRC, Reed-Muller-Code der Zugriffszuweisung und die
// Kanalcodierung der Sprache. Weiche Bits (Int8): positiv = 0, negativ = 1, 0 = unbekannt (Löschung).
// Die Zahlenwerte stammen aus den ETSI-Normen; osmo-tetra (Harald Welte u. a.) diente als Gegenprobe.

public typealias SoftBit = Int8

public enum TETRA {
    // MARK: Zeitraster

    public static let symbolRate = 18_000.0
    public static let bitsPerSlot = 510
    public static let symbolsPerSlot = 255
    public static let slotsPerFrame = 4
    public static let framesPerMultiframe = 18
    public static let multiframesPerHyperframe = 60

    // MARK: Bitfolgen

    /// Einstieg: Bits aus einem 0/1-Feld lesen (MSB zuerst)
    public static func uint(_ bits: [UInt8], _ offset: Int, _ count: Int) -> UInt32 {
        var v: UInt32 = 0
        var i = 0
        while i < count {
            let k = offset + i
            v = (v << 1) | (k < bits.count ? UInt32(bits[k] & 1) : 0)
            i += 1
        }
        return v
    }

    @inline(__always) public static func hard(_ s: SoftBit) -> UInt8 { s < 0 ? 1 : 0 }

    public static func hard(_ soft: [SoftBit]) -> [UInt8] { soft.map { $0 < 0 ? 1 : 0 } }

    /// 0/1-Bits als weiche Bits (Prüfungen, Sender)
    public static func soft(_ bits: [UInt8], level: SoftBit = 100) -> [SoftBit] { bits.map { $0 & 1 == 1 ? -level : level } }

    // MARK: Trainingsfolgen (EN 300 392-2, 9.4.4.3)

    public static let normalTrainingN: [UInt8] = [1,1, 0,1, 0,0, 0,0, 1,1, 1,0, 1,0, 0,1, 1,1, 0,1, 0,0]
    public static let normalTrainingP: [UInt8] = [0,1, 1,1, 1,0, 1,0, 0,1, 0,0, 0,0, 1,1, 0,1, 1,1, 1,0]
    public static let normalTrainingQ: [UInt8] = [1,0, 1,1, 0,1, 1,1, 0,0, 0,0, 0,1, 1,0, 1,0, 1,1, 0,1]
    public static let syncTraining: [UInt8] = [1,1, 0,0, 0,0, 0,1, 1,0, 0,1, 1,1, 0,0, 1,1, 1,0, 1,0, 0,1, 1,1, 0,0, 0,0, 0,1, 1,0, 0,1, 1,1]
    /// Frequenzkorrekturfeld des Synchronisationsbursts: 8 Einsen, 64 Nullen, 8 Einsen
    public static let frequencyCorrection: [UInt8] = {
        var f = [UInt8](repeating: 0, count: 80)
        for i in 0..<8 { f[i] = 1; f[72 + i] = 1 }
        return f
    }()

    /// Lage der Trainingsfolgen im Burst (Bitposition)
    public static let syncTrainingOffset = 214
    public static let normalTrainingOffset = 244

    // MARK: Verwürfelung (EN 300 392-2, 8.2.5)

    /// Anfangswert für die Synchronisationsblöcke (feste Verwürfelung)
    public static let defaultScramblerInit: UInt32 = 3

    public static func scramblerInit(mcc: Int, mnc: Int, colourCode: Int) -> UInt32 {
        let v = UInt32(colourCode & 0x3F) | (UInt32(mnc & 0x3FFF) << 6) | (UInt32(mcc & 0x3FF) << 20)
        return (v << 2) | 3
    }

    private static let scramblerTaps: [Int] = [32, 26, 23, 22, 16, 12, 11, 10, 8, 7, 5, 4, 2, 1]

    public static func scramblerBits(initial: UInt32, count: Int) -> [UInt8] {
        var lfsr = initial
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            var b: UInt32 = 0
            for t in scramblerTaps { b ^= (lfsr >> UInt32(32 - t)) & 1 }
            lfsr = (lfsr >> 1) | (b << 31)
            out[i] = UInt8(b)
        }
        return out
    }

    /// Verwürfelungsfolge je Anfangswert (die Zelle ändert sich selten)
    public final class ScramblerCache: @unchecked Sendable {
        private var key: UInt32 = 0
        private var bits: [UInt8] = []
        public init() {}
        public func sequence(initial: UInt32, count: Int) -> [UInt8] {
            if key != initial || bits.count < count || bits.isEmpty {
                key = initial
                bits = TETRA.scramblerBits(initial: initial, count: max(count, 432))
            }
            return bits
        }
        /// Weiche Bits entwürfeln: wo die Folge 1 ist, wird das Vorzeichen umgekehrt
        public func descramble(_ soft: ArraySlice<SoftBit>, initial: UInt32) -> [SoftBit] {
            let seq = sequence(initial: initial, count: soft.count)
            var out = [SoftBit](repeating: 0, count: soft.count)
            var i = 0
            for s in soft {
                out[i] = seq[i] == 1 ? (s == -128 ? 127 : -s) : s
                i += 1
            }
            return out
        }
    }

    // MARK: Verschachtelung (8.2.4)

    /// Blockverschachtelung für Phasenmodulation: Ausgangsbit i = Eingangsbit 1 + (a·i mod K)
    public static func blockDeinterleave(_ input: [SoftBit], a: Int) -> [SoftBit] {
        let k = input.count
        var out = [SoftBit](repeating: 0, count: k)
        for i in 1...k {
            out[i - 1] = input[(a * i) % k]
        }
        return out
    }

    public static func blockInterleave(_ input: [UInt8], a: Int) -> [UInt8] {
        let k = input.count
        var out = [UInt8](repeating: 0, count: k)
        for i in 1...k {
            out[(a * i) % k] = input[i - 1]
        }
        return out
    }

    // MARK: CRC-16 (CCITT, Anfangswert 0xFFFF, Ergebnis über Daten und CRC = 0x1D0F)

    public static let crcResidue: UInt16 = 0x1D0F

    public static func crc16(_ bits: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in bits {
            crc ^= UInt16(b & 1) << 15
            crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
        return crc
    }

    public static func crc16(_ bits: [UInt8]) -> UInt16 { crc16(bits[...]) }

    /// CRC-Bits (invertiert) zum Anhängen an `bits`
    public static func crcBits(for bits: [UInt8]) -> [UInt8] {
        let c = ~crc16(bits)
        return (0..<16).map { UInt8((c >> UInt16(15 - $0)) & 1) }
    }

    // MARK: Faltungscode

    /// Mutter-Faltungscode (Einschränkungslänge 5): `masks[j]` markiert die Abgriffe des Ausgangs j (Bit 0 = aktuelles Eingangsbit, Bit i = i Takte früher)
    public struct ConvolutionalCode: Sendable {
        public let masks: [UInt8]
        private let expected: [[Int8]]        // [Register 0..31][Ausgang] → +1 für 0, −1 für 1

        public init(masks: [UInt8]) {
            self.masks = masks
            expected = (0..<32).map { reg in
                masks.map { ($0 & UInt8(reg)).nonzeroBitCount & 1 == 0 ? 1 : -1 }
            }
        }

        /// Steuerkanäle: G1 = 1+D+D⁴, G2 = 1+D²+D³+D⁴, G3 = 1+D+D²+D⁴, G4 = 1+D+D³+D⁴ (Rate 1/4)
        public static let control = ConvolutionalCode(masks: [0b10011, 0b11101, 0b10111, 0b11011])
        /// Sprache: G1 = 1+D+D²+D³+D⁴, G2 = 1+D+D³+D⁴, G3 = 1+D²+D⁴ (Rate 1/3)
        public static let speech = ConvolutionalCode(masks: [0b11111, 0b11011, 0b10101])

        public var outputs: Int { masks.count }

        public func encode(_ bits: [UInt8]) -> [UInt8] {
            var state = 0
            var out: [UInt8] = []
            out.reserveCapacity(bits.count * masks.count)
            for b in bits {
                let reg = Int(b & 1) | (state << 1)
                for m in masks { out.append(UInt8((m & UInt8(reg)).nonzeroBitCount & 1)) }
                state = reg & 0xF
            }
            return out
        }

        /// Viterbi-Decodierung mit weichen Bits (0 = Löschung). Beginnt im Zustand 0; `terminated`: Ende im Zustand 0, sonst bester Zustand.
        public func decode(_ soft: [SoftBit], steps: Int, terminated: Bool) -> (bits: [UInt8], metric: Int) {
            let n = masks.count
            precondition(soft.count >= steps * n)
            let neg = Int32.min / 4
            var pm = [Int32](repeating: neg, count: 16)
            pm[0] = 0
            var next = pm
            var decisions = [UInt16](repeating: 0, count: steps)
            for k in 0..<steps {
                for s in 0..<16 { next[s] = neg }
                var dec: UInt16 = 0
                for ns in 0..<16 {
                    // Vorgänger: ns = ((s << 1) | b) & 15 → b = ns & 1, s = (ns >> 1) | (x << 3)
                    let b = ns & 1
                    var best = neg
                    var bestX = 0
                    for x in 0..<2 {
                        let s = (ns >> 1) | (x << 3)
                        if pm[s] <= neg { continue }
                        let reg = b | (s << 1)
                        var m = pm[s]
                        let e = expected[reg]
                        for j in 0..<n { m += Int32(e[j]) * Int32(soft[k * n + j]) }
                        if m > best { best = m; bestX = x }
                    }
                    next[ns] = best
                    if bestX == 1 { dec |= 1 << UInt16(ns) }
                }
                decisions[k] = dec
                swap(&pm, &next)
            }
            var state = 0
            if !terminated {
                var best = pm[0]
                for s in 1..<16 where pm[s] > best { best = pm[s]; state = s }
            }
            let metric = Int(pm[state])
            var out = [UInt8](repeating: 0, count: steps)
            for k in stride(from: steps - 1, through: 0, by: -1) {
                out[k] = UInt8(state & 1)
                let x = Int((decisions[k] >> UInt16(state)) & 1)
                state = (state >> 1) | (x << 3)
            }
            return (out, metric)
        }
    }

    // MARK: Punktierung (8.2.3.1)

    /// Punktierer: Mutterbit k (1-basiert) für übertragenes Bit j, mit i = f(j)
    public struct Puncturer: Sendable {
        let pattern: [Int]
        let t: Int
        let period: Int
        let indexFunction: @Sendable (Int) -> Int

        /// Rate 2/3 aus der Mutterrate 1/4 (SB1, SB2, SCH/HD, SCH/F, SCH/HU in der Variante 112/168)
        public static let rate2of3 = Puncturer(pattern: [0, 1, 2, 5], t: 3, period: 8, indexFunction: { $0 })
        public static let rate1of3 = Puncturer(pattern: [0, 1, 2, 3, 5, 6, 7], t: 6, period: 8, indexFunction: { $0 })

        /// Mutterbit-Nummern (0-basiert) der ersten `count` übertragenen Bits
        public func positions(count: Int) -> [Int] {
            (1...count).map { j in
                let i = indexFunction(j)
                return period * ((i - 1) / t) + pattern[i - t * ((i - 1) / t)] - 1
            }
        }

        /// Gelöschte Bits wieder an ihren Platz stellen (0 = Löschung); `motherLength` = Eingangsbits × Ausgänge
        public func depuncture(_ soft: [SoftBit], motherLength: Int) -> [SoftBit] {
            var out = [SoftBit](repeating: 0, count: motherLength)
            for (j, k) in positions(count: soft.count).enumerated() where k < motherLength { out[k] = soft[j] }
            return out
        }

        public func puncture(_ mother: [UInt8], count: Int) -> [UInt8] {
            positions(count: count).map { mother[$0] }
        }
    }

    // MARK: Reed-Muller (30,14) der Zugriffszuweisung (8.2.3.2)

    private static let rmGenerator: [[UInt8]] = [
        [1, 0, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 0, 0, 0, 0],
        [0, 0, 1, 0, 1, 1, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0],
        [1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0],
        [1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0],
        [1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1, 0, 1, 0],
        [0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0],
        [0, 0, 1, 0, 1, 1, 0, 0, 0, 0, 1, 0, 1, 1, 1, 0],
        [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1],
        [1, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0, 0, 1],
        [0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 1, 1, 0, 1, 0, 1],
        [0, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 0, 1],
        [0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 1],
        [0, 0, 0, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 1, 1],
        [0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1],
    ]

    /// Die 16 Prüfbits zu 14 Informationsbits (Zeile i = Informationsbit i)
    private static let rmParityRows: [UInt16] = rmGenerator.map { row in
        row.reduce(UInt16(0)) { ($0 << 1) | UInt16($1) }
    }

    public static func rm3014Encode(_ info: UInt16) -> UInt32 {
        var parity: UInt16 = 0
        for i in 0..<14 where (info >> UInt16(13 - i)) & 1 == 1 { parity ^= rmParityRows[i] }
        return (UInt32(info & 0x3FFF) << 16) | UInt32(parity)
    }

    private static let rmCodewords: [UInt32] = (0..<16384).map { rm3014Encode(UInt16($0)) }

    /// Nächstes Codewort zu 30 weichen Bits; liefert die 14 Informationsbits und die Zahl korrigierter Fehler (nach harter Entscheidung)
    public static func rm3014Decode(_ soft: [SoftBit]) -> (info: UInt16, distance: Int) {
        precondition(soft.count == 30)
        var word: UInt32 = 0
        for s in soft { word = (word << 1) | (s < 0 ? 1 : 0) }
        var best = 0
        var bestD = 99
        for (i, c) in rmCodewords.enumerated() {
            let d = (c ^ word).nonzeroBitCount
            if d < bestD { bestD = d; best = i; if d == 0 { break } }
        }
        return (UInt16(best), bestD)
    }

    // MARK: Trägerfrequenzen (EN 300 392-15)

    public static func downlinkFrequencyHz(band: Int, carrier: Int, offsetIndex: Int) -> Double {
        let offsets: [Double] = [0, 6250, -6250, 12500]
        return Double(band) * 100_000_000 + Double(carrier) * 25_000 + offsets[offsetIndex & 3]
    }

    private static let duplexSpacingKHz: [[Int]] = [
        [-1, 1600, 10000, 10000, 10000, 10000, 10000, -1, -1, -1, -1, -1, -1, -1, -1, -1],
        [-1, 4500, -1, 36000, 7000, -1, -1, -1, 45000, 45000, -1, -1, -1, -1, -1, -1],
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        [-1, -1, -1, 8000, 8000, -1, -1, -1, 18000, 18000, -1, -1, -1, -1, -1, -1],
        [-1, -1, -1, 18000, 5000, -1, 30000, 30000, -1, 39000, -1, -1, -1, -1, -1, -1],
        [-1, -1, -1, -1, 9500, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1],
        [Int](repeating: -1, count: 16),
        [Int](repeating: -1, count: 16),
    ]

    public static func uplinkFrequencyHz(band: Int, carrier: Int, offsetIndex: Int, duplex: Int, reverse: Bool) -> Double? {
        let spacing = duplexSpacingKHz[duplex & 7][band & 15]
        if spacing < 0 { return nil }
        let f = downlinkFrequencyHz(band: band, carrier: carrier, offsetIndex: offsetIndex)
        return reverse ? f + Double(spacing) * 1000 : f - Double(spacing) * 1000
    }
}
