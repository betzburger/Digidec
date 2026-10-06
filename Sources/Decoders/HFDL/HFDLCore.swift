// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - HFDL (High Frequency Data Link, ARINC 635): Bitübertragung und Rahmen
//
// Eigene Umsetzung nach der Beschreibung des Signals; die Konstanten (Synchronfolgen A, M1, T, Entwürfler, Verschachteler,
// Faltungscode) und die Abfolge im Rahmen stammen aus dumphfdl (Tomasz Lemiech SP5WWP/szpajder, GPLv3), das nur gelesen wurde
// (`Vendor/_upstream/dumphfdl`, Gegenprobe der Ergebnisse). Die Signalverarbeitung ist anders aufgebaut als dort: statt
// laufender Regelschleifen erkennt ein Korrelator die Synchronfolge A (ein Burst), danach wird der Burst als Block mit den
// bekannten Folgen (A, M1, T) als Pilot demoduliert.
//
// Signal: USB-Audio, Träger bei 1440 Hz, 1800 Symbole/s. Im Rahmen: Vorlauf (448 Symbole), A1 und A2 (je 127, BPSK, bekannt),
// M1 (127, wählt Betriebsart über 8 zyklische Verschiebungen), M2 (15), 9 × T (je 15, bekannt), dann je Block 30 Datensymbole
// (BPSK/QPSK/8PSK, mit Folge 120 Symbole entwürfelt) und 15 Symbole T. Einfach-Slot 72 Blöcke, Doppel-Slot 168 Blöcke.

// MARK: Komplexe Zahl

struct Cx: Sendable {
    var re: Double
    var im: Double
    @inline(__always) init(_ re: Double, _ im: Double) { self.re = re; self.im = im }
    @inline(__always) static let zero = Cx(0, 0)
    @inline(__always) static func + (a: Cx, b: Cx) -> Cx { Cx(a.re + b.re, a.im + b.im) }
    @inline(__always) static func - (a: Cx, b: Cx) -> Cx { Cx(a.re - b.re, a.im - b.im) }
    @inline(__always) static func * (a: Cx, b: Cx) -> Cx { Cx(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re) }
    @inline(__always) static func * (a: Cx, s: Double) -> Cx { Cx(a.re * s, a.im * s) }
    @inline(__always) static func += (a: inout Cx, b: Cx) { a.re += b.re; a.im += b.im }
    @inline(__always) var conj: Cx { Cx(re, -im) }
    @inline(__always) var abs2: Double { re * re + im * im }
    @inline(__always) var abs: Double { abs2.squareRoot() }
    @inline(__always) var arg: Double { atan2(im, re) }
    @inline(__always) static func polar(_ phase: Double) -> Cx { Cx(cos(phase), sin(phase)) }
}

// MARK: - Konstanten

public enum HFDLPHY {
    public static let symbolRate = 1800.0
    /// Die Vorstufe liefert 3 Abtastwerte je Symbol (5400 Hz)
    static let sps = 3
    public static let subcarrierHz = 1440.0
    public static let sampleRate = 12_000.0

    static let aLen = 127, m1Len = 127, m2Len = 15, tLen = 15, dataFrameLen = 30
    static let preambleLen = 2 * aLen + m1Len + m2Len + 9 * tLen        // 531
    static let singleBlocks = 72, doubleBlocks = 168

    /// Synchronfolge A: 127 Bit, Bit 0 = Symbol +1
    static let aBits: [UInt8] = {
        let octets: [UInt8] = [0b01011011, 0b10111100, 0b01110100, 0b01010111, 0b00000011, 0b11011001, 0b10001001, 0b00111001,
                               0b11110010, 0b00001000, 0b11010101, 0b00110110, 0b10010100, 0b00101100, 0b00110010, 0b11111110]
        return (0..<127).map { UInt8((octets[$0 / 8] >> UInt8(7 - $0 % 8)) & 1) }
    }()

    static let m1Base: [UInt8] = [
        0,1,1,1,0,1,1,0,1,1,1,1,0,1,0,0,0,1,0,1,1,0,0,
        1,0,1,1,1,1,1,0,0,0,1,0,0,0,0,0,0,1,1,0,0,1,1,0,1,1,
        0,0,0,1,1,1,0,0,1,1,1,0,1,0,1,1,1,0,0,0,0,1,0,0,1,1,
        0,0,0,0,0,1,0,1,0,1,0,1,1,0,1,0,0,1,0,0,1,0,1,0,0,1,
        1,1,1,0,0,1,0,0,0,1,1,0,1,0,1,0,0,0,0,1,1,1,1,1,1,1
    ]
    static let m1Shifts = [72, 82, 113, 123, 61, 103, 93, 9]

    /// M1 für Betriebsart 0…7 (Bits in Zeitfolge)
    static func m1Bits(_ mode: Int) -> [UInt8] { (0..<m1Len).map { m1Base[(m1Shifts[mode] + $0) % 127] } }

    /// Trainingsfolge T (15 Symbole, ±1)
    static let tSeq: [Double] = {
        let t: UInt32 = 0x9AF
        return (0..<15).map { (t >> UInt32(14 - $0)) & 1 == 0 ? 1.0 : -1.0 }
    }()

    struct Mode {
        let bitsPerSymbol: Int
        let blocks: Int
        let codeRate: Int
        let pushShift: Int
        var bitRate: Int { Int((symbolRate * Double(bitsPerSymbol) / Double(codeRate) * 30.0 / 45.0).rounded()) }
        var double: Bool { blocks == doubleBlocks }
        var dataSymbols: Int { blocks * dataFrameLen }
        var totalSymbols: Int { preambleLen + blocks * (dataFrameLen + tLen) }
    }

    static let modes: [Mode] = [
        Mode(bitsPerSymbol: 1, blocks: singleBlocks, codeRate: 4, pushShift: 17),   // 300 bit/s, einfach
        Mode(bitsPerSymbol: 1, blocks: singleBlocks, codeRate: 2, pushShift: 17),   // 600
        Mode(bitsPerSymbol: 2, blocks: singleBlocks, codeRate: 2, pushShift: 17),   // 1200
        Mode(bitsPerSymbol: 3, blocks: singleBlocks, codeRate: 2, pushShift: 17),   // 1800
        Mode(bitsPerSymbol: 1, blocks: doubleBlocks, codeRate: 4, pushShift: 23),   // 300, doppelt
        Mode(bitsPerSymbol: 1, blocks: doubleBlocks, codeRate: 2, pushShift: 23),
        Mode(bitsPerSymbol: 2, blocks: doubleBlocks, codeRate: 2, pushShift: 23),
        Mode(bitsPerSymbol: 3, blocks: doubleBlocks, codeRate: 2, pushShift: 23)
    ]

    /// Angepasstes Filter bei 3 Abtastwerten je Symbol
    static let matchedFilter: [Double] = [
        -0.0170974647427123, 0.01148231492068473, 0.03138375667422348, 0.009454398851680437,
        -0.04161644170893816, -0.06451564801420356, -0.005495792933327306, 0.1316404671361545,
        0.2759693160697777, 0.3375901874933208, 0.2759693160697777, 0.1316404671361545,
        -0.005495792933327306, -0.06451564801420356, -0.04161644170893816, 0.009454398851680437,
        0.03138375667422348, 0.01148231492068473, -0.0170974647427123
    ]

    /// Entwürfelfolge: 15-Bit-Schieberegister (x^15 + x^14 + 1), alle 120 Symbole neu gestartet
    static func scramblerBits(count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var state: UInt32 = 0x4D4B
        for i in 0..<count {
            if i % 120 == 0 { state = 0x4D4B }
            let b = ((state >> 14) ^ state) & 1
            state = ((state << 1) | b) & 0x7FFF
            out[i] = UInt8(b)
        }
        return out
    }
}

// MARK: - Ergebnis

/// Ein decodierter Bitstrom (Burst) vor der Protokollauswertung
public struct HFDLRawFrame: Sendable {
    public var bytes: [UInt8]
    public var bitRate: Int
    public var doubleSlot: Bool
    public var freqErrorHz: Double
    /// Verhältnis Signal zu Rauschen (dB) aus den Pilotsymbolen, bezogen auf die Symbolbandbreite
    public var snrDB: Double
    /// Index des ersten Symbols (A1) im Eingang, in Abtastwerten bei 12 kHz
    public var startSample: Int64
    /// Zahl der Versuche, bis die Prüfsumme stimmte (0 = nicht geprüft)
    public var attempt: Int
}

// MARK: - Faltungscode

/// Viterbi-Decoder für Rate 1/2, K = 7, Polynome 0x6D und 0x4F (CCSDS), weiche Eingänge 0…255 (255 = Bit 1), Start im Zustand 0
enum HFDLViterbi {
    private static let parity: [UInt8] = (0..<128).map { UInt8($0.nonzeroBitCount & 1) }
    /// Je Zustand (64) und Eingabebit: die zwei Codebits
    private static let branch: [[(UInt8, UInt8)]] = (0..<64).map { s in
        (0..<2).map { u in
            let reg = (s << 1) | u
            return (parity[reg & 0x6D], parity[reg & 0x4F])
        }
    }

    /// `soft` hat 2 Werte je Datenbit. Ergebnis: Datenbits in Zeitfolge
    static func decode(soft: [UInt8], bitCount n: Int) -> [UInt8] {
        let inf = Int32.max / 4
        var metric = [Int32](repeating: inf, count: 64)
        var next = [Int32](repeating: inf, count: 64)
        metric[0] = 0
        var decisions = [UInt64](repeating: 0, count: n)
        for t in 0..<n {
            let s0 = Int32(soft[2 * t]), s1 = Int32(soft[2 * t + 1])
            for i in 0..<64 { next[i] = inf }
            var dec: UInt64 = 0
            for s in 0..<64 where metric[s] < inf {
                for u in 0..<2 {
                    let ns = ((s << 1) | u) & 63
                    let (o0, o1) = branch[s][u]
                    let c = abs(s0 - (o0 == 1 ? 255 : 0)) + abs(s1 - (o1 == 1 ? 255 : 0))
                    let m = metric[s] + c
                    if m < next[ns] {
                        next[ns] = m
                        // Vorgänger: s = (ns >> 1) oder (ns >> 1) | 32; Entscheidungsbit = oberstes Bit von s
                        if (s >> 5) & 1 == 1 { dec |= 1 << UInt64(ns) } else { dec &= ~(1 << UInt64(ns)) }
                    }
                }
            }
            decisions[t] = dec
            swap(&metric, &next)
        }
        var state = 0
        var best = metric[0]
        for s in 1..<64 where metric[s] < best { best = metric[s]; state = s }
        var bits = [UInt8](repeating: 0, count: n)
        for t in stride(from: n - 1, through: 0, by: -1) {
            bits[t] = UInt8(state & 1)
            let d = Int((decisions[t] >> UInt64(state)) & 1)
            state = (state >> 1) | (d << 5)
        }
        return bits
    }
}

// MARK: - Verschachtelung

enum HFDLInterleaver {
    static let rows = 40
    static let popRowShift = 9

    /// Entschachtelt `soft` (in Empfangsreihenfolge) nach der Reihenfolge am Eingang des Viterbi-Decoders
    static func deinterleave(_ soft: [UInt8], columns: Int, pushShift: Int) -> [UInt8] {
        var table = [UInt8](repeating: 0, count: rows * columns)
        var row = 0, col = 0
        for v in soft {
            table[row * columns + col] = v
            row += 1
            if row == rows { row = 0; col += 1 }
            col -= pushShift
            if col < 0 { col += columns }
        }
        var out = [UInt8](repeating: 0, count: soft.count)
        for i in 0..<soft.count {
            out[i] = table[row * columns + col]
            row = (row + popRowShift) % rows
            if row == 0 { col += 1 }
        }
        return out
    }
}

// MARK: - Prüfsumme

enum HFDLCRC {
    /// CRC-16/X-25 (CCITT reflektiert, Start 0xFFFF, Ergebnis invertiert): die Prüfsumme steht klein-endian hinter dem Kopf
    static let table: [UInt16] = (0..<256).map { i -> UInt16 in
        var c = UInt16(i)
        for _ in 0..<8 { c = c & 1 == 1 ? (c >> 1) ^ 0x8408 : c >> 1 }
        return c
    }

    static func crc(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var c: UInt16 = 0xFFFF
        for b in bytes { c = (c >> 8) ^ table[Int((c ^ UInt16(b)) & 0xFF)] }
        return c ^ 0xFFFF
    }

    /// Prüfsumme der `length` Bytes ab `start` stimmt mit den zwei folgenden Bytes überein
    static func check(_ bytes: [UInt8], start: Int = 0, length: Int) -> Bool {
        guard start + length + 2 <= bytes.count else { return false }
        let expected = UInt16(bytes[start + length]) | UInt16(bytes[start + length + 1]) << 8
        return crc(bytes[start..<(start + length)]) == expected
    }

    /// Wertung eines decodierten Bitstroms: Kopf in Ordnung, Zahl der LPDU mit richtiger Prüfsumme und Zahl aller LPDU
    static func score(_ b: [UInt8]) -> (header: Bool, good: Int, total: Int) {
        guard let first = b.first, headerOK(b) else { return (false, 0, 0) }
        if first & 1 == 0 { return (true, 1, 1) }
        var good = 0, total = 0
        var sizes: [Int] = []
        var hdr = 0
        if first & 2 != 0 {
            let cnt = Int((first >> 2) & 0xF)
            hdr = 6 + cnt
            sizes = (0..<cnt).map { Int(b[6 + $0]) + 1 }
        } else {
            let aircraft = Int((first & 0x70) >> 4) + 1
            hdr = 2
            for _ in 0..<aircraft {
                let cnt = Int(b[hdr + 1] >> 4)
                sizes += (0..<cnt).map { Int(b[hdr + 2 + $0]) + 1 }
                hdr += 2 + cnt
            }
        }
        var p = hdr + 2
        for len in sizes {
            total += 1
            guard p + len <= b.count else { break }
            if len >= 3 && check(b, start: p, length: len - 2) { good += 1 }
            p += len
        }
        return (true, good, total)
    }

    /// Prüfsumme des Kopfes eines MPDU (Bit 0 = 1) oder SPDU (Bit 0 = 0); die Kopflänge folgt aus dem Inhalt
    static func headerOK(_ b: [UInt8]) -> Bool {
        guard let first = b.first else { return false }
        if first & 1 == 1 {
            var hdr = 0
            if first & 2 != 0 {
                hdr = 6 + Int((first >> 2) & 0xF)                 // Abwärtsstrecke: 4 Bit LPDU-Zahl
            } else {
                let aircraft = Int((first & 0x70) >> 4) + 1       // Aufwärtsstrecke: 3 Bit Flugzeugzahl
                hdr = 2
                for _ in 0..<aircraft {
                    guard b.count >= hdr + 2 else { return false }
                    hdr += 2 + Int(b[hdr + 1] >> 4)
                }
            }
            return check(b, length: hdr)
        }
        return check(b, length: 64)
    }
}

// MARK: - Vorstufe: Mischen, Abtastratenwandlung (12 kHz → 5,4 kHz), angepasstes Filter

final class HFDLFrontEnd {
    private let l = 9
    private let m: Int
    private let taps: [Double]
    private let tapCount: Int
    private var history: [Cx]
    private var histCount: Int64 = 0
    private var nextOut: Int64 = 0
    private var phase = 0.0
    private let phaseStep: Double
    private var mfBuffer = [Cx](repeating: .zero, count: HFDLPHY.matchedFilter.count)
    private var mfIndex = 0

    init(sampleRate: Double, centerHz: Double) {
        precondition(Int(sampleRate) % 600 == 0, "HFDL: Abtastrate muss ein Vielfaches von 600 Hz sein")
        m = Int(sampleRate) / 600
        phaseStep = 2 * Double.pi * centerHz / sampleRate
        // Tiefpass bei 9 × 12 kHz = 108 kHz: Durchlass bis 1300 Hz, Sperre ab 1900 Hz (Kaiser, ca. 60 dB)
        let interp = 9
        let rate = sampleRate * Double(interp)
        let n = (interp * (Int(sampleRate) / 12_000) * 72) | 1
        tapCount = n
        let fc = 1600.0 / rate
        let beta = 5.65
        func i0(_ x: Double) -> Double {
            var s = 1.0, t = 1.0
            for k in 1..<30 { t *= (x / (2 * Double(k))) * (x / (2 * Double(k))); s += t }
            return s
        }
        let c = Double(n - 1) / 2
        taps = (0..<n).map { j in
            let x = Double(j) - c
            let sinc = x == 0 ? 2 * fc : sin(2 * Double.pi * fc * x) / (Double.pi * x)
            let r = x / c
            let w = i0(beta * (1 - r * r).squareRoot()) / i0(beta)
            return sinc * w * Double(interp)
        }
        history = [Cx](repeating: .zero, count: n / interp + 4)
    }

    func reset() {
        history = [Cx](repeating: .zero, count: history.count)
        histCount = 0; nextOut = 0; phase = 0
        mfBuffer = [Cx](repeating: .zero, count: mfBuffer.count)
    }

    /// Ein Audio-Abtastwert herein; `emit` für jeden Ausgangswert nach dem angepassten Filter (5400 Hz)
    @inline(__always)
    func push(_ x: Float, emit: (Cx) -> Void) {
        phase += phaseStep
        if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        let v = Double(x)
        history[Int(histCount % Int64(history.count))] = Cx(v * cos(phase), -v * sin(phase))
        let i = histCount
        histCount += 1
        // Ausgänge m mit 20·m ≤ 9·i + 8, d. h. alle Eingänge bis i stehen zur Verfügung
        while nextOut * Int64(m) <= Int64(l) * i + Int64(l - 1) {
            let u = nextOut * Int64(m)
            var acc = Cx.zero
            var k = u / Int64(l)                       // jüngster Eingang
            var j = Int(u - k * Int64(l))
            while j < tapCount && k >= 0 && histCount - k <= Int64(history.count) {
                let h = history[Int(k % Int64(history.count))]
                let t = taps[j]
                acc.re += h.re * t; acc.im += h.im * t
                j += l; k -= 1
            }
            nextOut += 1
            emit(matchedFilter(acc))
        }
    }

    private func matchedFilter(_ x: Cx) -> Cx {
        let n = mfBuffer.count
        mfBuffer[mfIndex] = x
        mfIndex = (mfIndex + 1) % n
        var acc = Cx.zero
        let h = HFDLPHY.matchedFilter
        for k in 0..<n {
            acc += mfBuffer[(mfIndex + k) % n] * h[n - 1 - k]
        }
        return acc
    }
}

// MARK: - Empfänger

public final class HFDLReceiver {
    public struct Statistics: Sendable {
        public var candidates = 0, confirmedA2 = 0, matchedM1 = 0, bursts = 0, goodFrames = 0
    }

    public struct Tuning: Sendable {
        public var detectThreshold = 0.22
        public var confirmThreshold = 0.28
        public var halfThreshold = 0.18
        public var coherentThreshold = 0.22
        public var m1Threshold = 0.35
        public var m1Ratio = 1.6
        public var costasAlpha = 0.10
        public var costasBeta = 0.003
        public var timingKp = 0.03
        public var timingKi = 0.0004
        public var equalizer = true
        public init() {}
    }

    public private(set) var stats = Statistics()
    public var tuning = Tuning()
    /// Debug-Ausgabe (nil = aus)
    public var trace: ((String) -> Void)?
    /// Debug: jeder Ausgangswert des angepassten Filters (Index, I, Q)
    public var sampleTap: ((Int64, Double, Double) -> Void)?
    /// true, solange ein Burst gerade empfangen wird (zwischen erkannter Synchronisation und Ende)
    public private(set) var inBurst = false

    private let sampleRate: Double
    private let front: HFDLFrontEnd
    private static let ringSize = 1 << 16
    private static let mask = ringSize - 1
    private var ring = [Cx](repeating: .zero, count: HFDLReceiver.ringSize)       // Ausgang des angepassten Filters
    private var count: Int64 = 0                                                    // Zahl der Werte im Ring
    private var inputCount: Int64 = 0                                               // Zahl der Audio-Abtastwerte
    private static let dSize = 1 << 12
    private var dRing = [Cx](repeating: .zero, count: HFDLReceiver.dSize)
    private var dAbs = [Double](repeating: 0, count: HFDLReceiver.dSize)

    // Vorlagen für die differenzielle Korrelation (Produkte aufeinanderfolgender Symbole)
    private let aTemplate: [Double]
    private let m1Templates: [[Double]]
    private let known: [Double]             // Symbol ±1 der Folge A (127)

    private struct Candidate {
        enum Stage { case awaitA2, awaitM1, awaitEnd }
        var stage: Stage
        var nC: Int64                       // Index des letzten Symbols von A1
        var n0 = 0.0                        // Index des ersten Symbols von A1 (mit Bruchteil)
        var omega = 0.0                     // Phasendrehung je Symbol
        var mode = 0
        var quality = 0.0
        var triggerAt: Int64
    }
    private var pending: [Candidate] = []
    private var mRing = [Double](repeating: 0, count: 16)

    public init(sampleRate: Double = HFDLPHY.sampleRate, centerHz: Double = HFDLPHY.subcarrierHz) {
        self.sampleRate = sampleRate
        front = HFDLFrontEnd(sampleRate: sampleRate, centerHz: centerHz)
        func sym(_ b: UInt8) -> Double { b == 0 ? 1 : -1 }
        known = HFDLPHY.aBits.map(sym)
        func products(_ bits: [UInt8]) -> [Double] { (1..<bits.count).map { sym(bits[$0]) * sym(bits[$0 - 1]) } }
        aTemplate = products(HFDLPHY.aBits)
        m1Templates = (0..<8).map { products(HFDLPHY.m1Bits($0)) }
    }

    public func reset() {
        front.reset()
        count = 0; inputCount = 0
        pending.removeAll(); mRing = [Double](repeating: 0, count: 16); inBurst = false
        ring = [Cx](repeating: .zero, count: ring.count)
        dRing = [Cx](repeating: .zero, count: dRing.count)
        dAbs = [Double](repeating: 0, count: dAbs.count)
    }

    public func process(_ samples: UnsafeBufferPointer<Float>, onFrame: (HFDLRawFrame) -> Void) {
        for x in samples {
            front.push(x) { v in self.step(v, onFrame: onFrame) }
            inputCount += 1
        }
    }

    // MARK: Korrelator

    /// Differenzielle Korrelation der Vorlage (126 Produkte) bei Index n; liefert Summe und Energie
    @inline(__always)
    private func correlate(_ template: [Double], at n: Int64) -> (s: Cx, e: Double) {
        var sr = 0.0, si = 0.0, e = 0.0
        let cnt = template.count                       // 126
        let mask = Self.dSize - 1
        for i in 0..<cnt {
            let idx = Int((n - Int64(3 * (cnt - 1 - i))) & Int64(mask))
            let d = dRing[idx]
            let p = template[i]
            sr += p * d.re; si += p * d.im
            e += dAbs[idx]
        }
        return (Cx(sr, si), e)
    }

    @inline(__always)
    private func metric(_ template: [Double], at n: Int64) -> Double {
        let c = correlate(template, at: n)
        return c.s.abs / (c.e + 1e-30)
    }

    private func step(_ v: Cx, onFrame: (HFDLRawFrame) -> Void) {
        let n = count
        ring[Int(n & Int64(Self.mask))] = v
        count += 1
        sampleTap?(n, v.re, v.im)
        if n >= 3 {
            let old = ring[Int((n - 3) & Int64(Self.mask))]
            let d = v * old.conj
            dRing[Int(n & Int64(Self.dSize - 1))] = d
            dAbs[Int(n & Int64(Self.dSize - 1))] = d.abs
        }
        guard n >= 400 else { return }

        // Spitzensuche der Korrelation mit A: Maximum im Fenster ±6 Abtastwerte
        mRing[Int(n & 15)] = metric(aTemplate, at: n)
        if n >= 420 {
            let cIdx = n - 6
            let val = mRing[Int(cIdx & 15)]
            if val > tuning.detectThreshold {
                var isMax = true
                for dlt in 1...6 {
                    if mRing[Int((cIdx - Int64(dlt)) & 15)] >= val || mRing[Int((cIdx + Int64(dlt)) & 15)] > val { isMax = false; break }
                }
                if isMax {
                    stats.candidates += 1
                    pending.append(Candidate(stage: .awaitA2, nC: cIdx, triggerAt: cIdx + 381 + 3))
                }
            }
        }

        // Weiterführen der Kandidaten
        var i = 0
        while i < pending.count {
            var c = pending[i]
            if n < c.triggerAt { i += 1; continue }
            switch c.stage {
            case .awaitA2:
                // A1 und A2 gemeinsam: 5 Lagen um die erwartete Stelle
                var best = (j: 0, val: 0.0, s: Cx.zero, minHalf: 0.0)
                var vals = [Double](repeating: 0, count: 5)
                for j in -2...2 {
                    let a = correlate(aTemplate, at: c.nC + Int64(j))
                    let b = correlate(aTemplate, at: c.nC + Int64(j) + 381)
                    let sum = a.s + b.s
                    let val = sum.abs / (a.e + b.e + 1e-30)
                    vals[j + 2] = val
                    if val > best.val { best = (j, val, sum, min(a.s.abs / (a.e + 1e-30), b.s.abs / (b.e + 1e-30))) }
                }
                if best.val < tuning.confirmThreshold || best.minHalf < tuning.halfThreshold {
                    pending.remove(at: i); continue
                }
                stats.confirmedA2 += 1
                var frac = 0.0
                if best.j > -2 && best.j < 2 {
                    let a = vals[best.j + 1], b = vals[best.j + 2], cc = vals[best.j + 3]
                    let den = a - 2 * b + cc
                    if den < 0 { frac = max(-0.5, min(0.5, 0.5 * (a - cc) / den)) }
                }
                c.nC += Int64(best.j)
                let coarse = Double(c.nC) + frac - 378
                let r = refineSync(n0: coarse)
                if r.quality < tuning.coherentThreshold {
                    trace?(String(format: "A1/A2 bei %.2f s verworfen: kohärente Güte %.2f", coarse / 5400, r.quality))
                    pending.remove(at: i); continue
                }
                c.n0 = r.n0
                c.omega = r.omega
                c.quality = r.quality
                c.stage = .awaitM1
                c.triggerAt = c.nC + 762 + 6
                trace?(String(format: "A1/A2 bei %.2f s (A2-Ende %d), Metrik %.2f, Güte %.2f, Dreh %.1f Hz", c.n0 / 5400, Int(c.nC) + 381, best.val, r.quality, c.omega * 1800 / (2 * Double.pi)))
                pending[i] = c
                i += 1
            case .awaitM1:
                let cls = classifyM1(n0: c.n0, omega: c.omega)
                if cls.best < tuning.m1Threshold || cls.best < tuning.m1Ratio * cls.second {
                    trace?(String(format: "M1 unsicher (%.2f, zweitbester %.2f)", cls.best, cls.second))
                    pending.remove(at: i); continue
                }
                // Doppelte Erkennung desselben Bursts (benachbarte Spitzen): die bessere behalten
                if let j = pending.firstIndex(where: { $0.stage == .awaitEnd && abs($0.n0 - c.n0) < 45 }) {
                    if pending[j].quality >= c.quality { pending.remove(at: i); continue }
                    pending.remove(at: j)
                    if j < i { i -= 1 }
                }
                stats.matchedM1 += 1
                c.mode = cls.mode
                let mode = HFDLPHY.modes[cls.mode]
                let endIndex = Int64(c.n0) + Int64(3 * (mode.totalSymbols - 1)) + 6
                c.stage = .awaitEnd
                c.triggerAt = endIndex
                inBurst = true
                trace?("M1 Betriebsart \(cls.mode) (\(mode.bitRate) bit/s, \(mode.double ? "doppelt" : "einfach")) Wert \(String(format: "%.2f", cls.best)), zweitbester \(String(format: "%.2f", cls.second))")
                pending[i] = c
                i += 1
            case .awaitEnd:
                pending.remove(at: i)
                stats.bursts += 1
                if let frame = demodulateBurst(c) {
                    stats.goodFrames += 1
                    onFrame(frame)
                }
                if !pending.contains(where: { $0.stage == .awaitEnd }) { inBurst = false }
            }
        }
    }

    /// Kohärente Feinsuche über A1 und A2 (254 bekannte Symbole): Zeitbruchteil (±0,6 Abtastwerte) und Frequenz (±100 Hz)
    private func refineSync(n0: Double) -> (n0: Double, omega: Double, quality: Double) {
        var best = (q: 0.0, dt: 0.0, omega: 0.0)
        let count = 254
        var v = [Cx](repeating: .zero, count: count)
        func search(dt: Double, from fLo: Double, to fHi: Double, step: Double) {
            var env = 0.0
            for k in 0..<count {
                let sv = interpolate(n0 + dt + 3 * Double(k))
                env += sv.abs
                v[k] = sv * known[k % 127]
            }
            var f = fLo
            while f <= fHi {
                let w = 2 * Double.pi * f / HFDLPHY.symbolRate
                let rot = Cx.polar(-w)
                var acc = Cx.zero
                // Horner: Σ v_k · e^{-jωk}
                for k in stride(from: count - 1, through: 0, by: -1) { acc = acc * rot + v[k] }
                let q = acc.abs / (env + 1e-30)
                if q > best.q { best = (q, dt, w) }
                f += step
            }
        }
        var dt = -0.6
        while dt <= 0.61 { search(dt: dt, from: -100, to: 100, step: 2); dt += 0.2 }
        let (dt0, f0) = (best.dt, best.omega * HFDLPHY.symbolRate / (2 * Double.pi))
        var dt2 = dt0 - 0.2
        while dt2 <= dt0 + 0.21 { search(dt: dt2, from: f0 - 2, to: f0 + 2, step: 0.5); dt2 += 0.1 }
        return (n0 + best.dt, best.omega, best.q)
    }

    /// M1 (127 Chips, 8 mögliche Verschiebungen) kohärent in vier Abschnitten am verfeinerten Takt klassifizieren
    private func classifyM1(n0: Double, omega: Double) -> (mode: Int, best: Double, second: Double) {
        var y = [Cx](repeating: .zero, count: 127)
        var env = 0.0
        for k in 0..<127 {
            let sv = interpolate(n0 + 3 * Double(254 + k)) * Cx.polar(-omega * Double(254 + k))
            y[k] = sv
            env += sv.abs
        }
        var bestMode = 0, best = 0.0, second = 0.0
        for mode in 0..<8 {
            let m = HFDLPHY.m1Bits(mode)
            var total = 0.0
            for seg in 0..<4 {
                let lo = seg * 32, hi = min(127, lo + 32)
                var acc = Cx.zero
                for k in lo..<hi { acc += y[k] * (m[k] == 0 ? 1.0 : -1.0) }
                total += acc.abs
            }
            let v = total / (env + 1e-30)
            if v > best { second = best; best = v; bestMode = mode } else if v > second { second = v }
        }
        return (bestMode, best, second)
    }

    /// Entzerrer: Halbsymbol-Abstand, 31 Koeffizienten (±7,5 Symbole, nicht kausal), NLMS auf den bekannten Folgen (A1, A2, M1, T)
    private func equalize(y: [Cx], mid: [Cx], m1: [Double]) -> (out: [Cx], noise: Double, noiseCount: Double) {
        let total = y.count
        let taps = 31, half = 15
        let pad = taps
        var u = [Cx](repeating: .zero, count: 2 * total + 2 * pad)
        for k in 0..<total {
            u[pad + 2 * k] = mid[k]
            u[pad + 2 * k + 1] = y[k]
        }
        var w = [Cx](repeating: .zero, count: taps)
        w[half] = Cx(1, 0)
        func output(_ k: Int) -> Cx {
            let base = pad + 2 * k + 1 - half
            var acc = Cx.zero
            for i in 0..<taps { acc += w[i] * u[base + i] }
            return acc
        }
        func train(_ k: Int, ref: Double, mu: Double) -> Double {
            let base = pad + 2 * k + 1 - half
            var z = Cx.zero
            var energy = 0.0
            for i in 0..<taps { z += w[i] * u[base + i]; energy += u[base + i].abs2 }
            let e = Cx(ref, 0) - z
            let g = mu / (energy + 1e-3)
            for i in 0..<taps { w[i] += e * u[base + i].conj * g }
            return e.abs2
        }
        let preKnown = 531
        for _ in 0..<5 {
            for k in 0..<preKnown {
                if let r = knownSymbol(k, m1: m1) { _ = train(k, ref: r, mu: 0.3) }
            }
        }
        // Vorwärtslauf: Koeffizienten fortlaufend an den bekannten Folgen nachführen; nach jedem T-Block (und nach der Präambel) merken
        var snapshots: [[Cx]] = []
        var out = [Cx](repeating: .zero, count: total)
        var noise = 0.0, noiseCount = 0.0
        for k in 0..<HFDLPHY.preambleLen {
            if let r = knownSymbol(k, m1: m1) {
                let e = train(k, ref: r, mu: 0.15)
                if k >= 396 { noise += e; noiseCount += 1 }
            }
        }
        snapshots.append(w)
        let blocks = (total - HFDLPHY.preambleLen) / 45
        for bIdx in 0..<blocks {
            let start = HFDLPHY.preambleLen + bIdx * 45
            for k in (start + 30)..<(start + 45) {
                if let r = knownSymbol(k, m1: m1) {
                    let e = train(k, ref: r, mu: 0.15)
                    noise += e; noiseCount += 1
                }
            }
            snapshots.append(w)
        }
        // Ausgabe: Preambel mit den Endkoeffizienten der Präambel, Datenblöcke zwischen den Koeffizienten davor und danach (linear gemischt)
        func apply(_ weights: [Cx], _ k: Int) -> Cx {
            let base = pad + 2 * k + 1 - half
            var acc = Cx.zero
            for i in 0..<taps { acc += weights[i] * u[base + i] }
            return acc
        }
        for k in 0..<HFDLPHY.preambleLen { out[k] = apply(snapshots[0], k) }
        for bIdx in 0..<blocks {
            let start = HFDLPHY.preambleLen + bIdx * 45
            for i in 0..<45 {
                let k = start + i
                if i < 30 {
                    let lambda = (Double(i) + 0.5) / 30
                    let a0 = apply(snapshots[bIdx], k), a1 = apply(snapshots[bIdx + 1], k)
                    out[k] = a0 * (1 - lambda) + a1 * lambda
                } else {
                    out[k] = apply(snapshots[bIdx + 1], k)
                }
            }
        }
        return (out, noise, noiseCount)
    }

    // MARK: Burst demodulieren

    @inline(__always)
    private func sample(_ i: Int64) -> Cx { ring[Int(i & Int64(Self.mask))] }

    /// Kubische Interpolation (Lagrange, 4 Punkte) des Ausgangs des angepassten Filters an der Stelle `pos`
    @inline(__always)
    private func interpolate(_ pos: Double) -> Cx {
        let i = Int64(pos.rounded(.down))
        let mu = pos - Double(i)
        let w0 = -mu * (mu - 1) * (mu - 2) / 6
        let w1 = (mu + 1) * (mu - 1) * (mu - 2) / 2
        let w2 = -(mu + 1) * mu * (mu - 2) / 2
        let w3 = (mu + 1) * mu * (mu - 1) / 6
        let a = sample(i - 1), b = sample(i), c = sample(i + 1), d = sample(i + 2)
        return Cx(a.re * w0 + b.re * w1 + c.re * w2 + d.re * w3, a.im * w0 + b.im * w1 + c.im * w2 + d.im * w3)
    }

    /// Bekanntes Symbol an Stelle k des Rahmens, nil wo unbekannt (M2, Daten)
    private func knownSymbol(_ k: Int, m1: [Double]) -> Double? {
        if k < 127 { return known[k] }
        if k < 254 { return known[k - 127] }
        if k < 381 { return m1[k - 254] }
        if k < 396 { return nil }
        if k < 531 { return HFDLPHY.tSeq[(k - 396) % 15] }
        let r = (k - 531) % 45
        return r >= 30 ? HFDLPHY.tSeq[r - 30] : nil
    }

    private func demodulateBurst(_ c: Candidate) -> HFDLRawFrame? {
        let mode = HFDLPHY.modes[c.mode]
        let m1Sym = HFDLPHY.m1Bits(c.mode).map { $0 == 0 ? 1.0 : -1.0 }
        let total = mode.totalSymbols
        guard c.n0 > Double(count - Int64(Self.ringSize)) + 10 else { return nil }
        var attempt = 0
        let plans: [(Double, Double, Double, Double, Bool)] = [
            (tuning.costasAlpha, tuning.costasBeta, tuning.timingKp, tuning.timingKi, tuning.equalizer),
            (0.05, 0.001, 0.02, 0.0002, tuning.equalizer),
            (0.15, 0.006, 0.05, 0.0008, tuning.equalizer),
            (0.10, 0.003, 0.0, 0.0, false),
            (0.05, 0.001, 0.0, 0.0, tuning.equalizer)
        ]
        var best: (frame: HFDLRawFrame, good: Int, total: Int)?
        for plan in plans {
            attempt += 1
            let r = demodulate(c, mode: mode, m1: m1Sym, total: total, plan: (plan.0, plan.1, plan.2, plan.3), useEqualizer: plan.4)
            guard let bytes = r.bytes else { continue }
            let sc = HFDLCRC.score(bytes)
            trace?("Versuch \(attempt): Kopf \(sc.header ? "ok" : "falsch"), LPDU \(sc.good)/\(sc.total), SNR \(String(format: "%.1f", r.snr)) dB")
            guard sc.header else { continue }
            let frame = HFDLRawFrame(bytes: bytes, bitRate: mode.bitRate, doubleSlot: mode.double, freqErrorHz: r.freqHz, snrDB: r.snr,
                                     startSample: Int64(c.n0 * sampleRate / 5400), attempt: attempt)
            if sc.good == sc.total { return frame }
            if best == nil || sc.good > best!.good { best = (frame, sc.good, sc.total) }
        }
        return best?.frame
    }

    private struct DemodResult {
        var bytes: [UInt8]?
        var freqHz: Double
        var snr: Double
    }

    private func demodulate(_ c: Candidate, mode: HFDLPHY.Mode, m1: [Double], total: Int,
                            plan: (Double, Double, Double, Double), useEqualizer: Bool) -> DemodResult {
        let (alpha, beta, kp, ki) = plan
        var y = [Cx](repeating: .zero, count: total)       // am Symboltakt, entdreht
        var mid = [Cx](repeating: .zero, count: total)     // eine halbe Symboldauer früher
        var omega = c.omega
        var pos = c.n0

        // Anfangswerte: Phase und Betrag aus A1 + A2 (bekannte Folge)
        var acc = Cx.zero
        for k in 0..<254 {
            let s = interpolate(c.n0 + 3 * Double(k))
            acc += s * Cx.polar(-omega * Double(k)) * known[k % 127]
        }
        // Frequenz verfeinern: A2 gegen A1
        var a1 = Cx.zero, a2 = Cx.zero
        for k in 0..<127 {
            let s1 = interpolate(c.n0 + 3 * Double(k)) * Cx.polar(-omega * Double(k)) * known[k]
            let s2 = interpolate(c.n0 + 3 * Double(k + 127)) * Cx.polar(-omega * Double(k + 127)) * known[k]
            a1 += s1; a2 += s2
        }
        trace?(String(format: "  Start: ω0 %.4f (%.1f Hz), |A1| %.2f |A2| %.2f, Phase A1-A2 %.2f rad, amp %.4f", omega, omega * 1800 / (2 * Double.pi), a1.abs / 127, a2.abs / 127, (a2 * a1.conj).arg, acc.abs / 254))
        omega += (a2 * a1.conj).arg / 127
        var phase = acc.arg
        let amp = max(acc.abs / 254, 1e-9)
        let norm = 1 / amp

        let scr = HFDLPHY.scramblerBits(count: mode.dataSymbols)
        var timingRate = 0.0
        var prev = Cx.zero
        let bps = mode.bitsPerSymbol
        let mpsk = 1 << bps
        var noise = 0.0, noiseCount = 0.0
        var nzA = 0.0, nzT = 0.0

        for k in 0..<total {
            let rot = Cx.polar(-phase)
            let yk = interpolate(pos) * rot * norm
            let mk = interpolate(pos - 1.5) * Cx.polar(-(phase - omega / 2)) * norm
            y[k] = yk
            mid[k] = mk
            // Zeitfehler (Gardner)
            if k > 0 && kp > 0 {
                let e = ((yk - prev) * mk.conj).re / 2
                let eClamped = max(-1.0, min(1.0, e))
                timingRate -= ki * eClamped
                pos -= kp * eClamped
            }
            prev = yk
            // Referenz und Phasenfehler
            var errPhase = 0.0
            if let kn = knownSymbol(k, m1: m1) {
                let ref = Cx(kn, 0)
                errPhase = (yk * ref.conj).im
                let d = yk - ref
                noise += d.abs2; noiseCount += 1
                if k < 381 { nzA += d.abs2 } else { nzT += d.abs2 }
            } else if k >= HFDLPHY.preambleLen && (k - HFDLPHY.preambleLen) % 45 < 30 {
                let t = (k - HFDLPHY.preambleLen) / 45 * 30 + (k - HFDLPHY.preambleLen) % 45
                let u = scr[t] == 1 ? Cx(-yk.re, -yk.im) : yk
                // nächster Punkt der Konstellation (Punkte bei Winkel j·2π/M)
                let idx = Int((u.arg / (2 * Double.pi / Double(mpsk))).rounded())
                let hat = Cx.polar(Double(idx) * 2 * Double.pi / Double(mpsk))
                errPhase = (u * hat.conj).im
            } else {
                // M2: BPSK-Entscheidung
                errPhase = yk.re >= 0 ? yk.im : -yk.im
            }
            omega += beta * errPhase
            phase += omega + alpha * errPhase
            pos += 3 + timingRate
        }

        if let tr = trace {
            tr(String(format: "  Pilot-Rauschen A/M1 %.2f, T %.2f (je Symbol), Takt-Rate %.5f, ω %.4f", nzA / 381, nzT / max(1, noiseCount - 381), timingRate, omega))
        }
        var snr = noiseCount > 0 && noise > 0 ? 10 * log10(1 / (noise / noiseCount)) : 0
        let freqHz = omega * HFDLPHY.symbolRate / (2 * Double.pi)

        // Ausgangssymbole: entzerrt oder unverändert
        var out = y
        if useEqualizer {
            let eq = equalize(y: y, mid: mid, m1: m1)
            out = eq.out
            if eq.noiseCount > 0 && eq.noise > 0 { snr = 10 * log10(1 / (eq.noise / eq.noiseCount)) }
            if let tr = trace { tr(String(format: "  Entzerrer: Pilot-Rauschen %.2f (vorher %.2f)", eq.noise / max(1, eq.noiseCount), noise / max(1, noiseCount))) }
        }
        var dataSymbols = [Cx](repeating: .zero, count: mode.dataSymbols)
        for t in 0..<mode.dataSymbols {
            let k = HFDLPHY.preambleLen + t / 30 * 45 + t % 30
            dataSymbols[t] = scr[t] == 1 ? Cx(-out[k].re, -out[k].im) : out[k]
        }

        // Weiche Bits
        var soft = [UInt8]()
        soft.reserveCapacity(mode.dataSymbols * bps)
        for u in dataSymbols { soft.append(contentsOf: Self.softBits(u, bits: bps)) }

        // Entschachteln, Viterbi
        let columns = mode.dataSymbols * bps / HFDLInterleaver.rows
        var viterbiIn = HFDLInterleaver.deinterleave(soft, columns: columns, pushShift: mode.pushShift)
        if mode.codeRate == 4 {
            var avg = [UInt8](repeating: 0, count: viterbiIn.count / 2)
            for i in 0..<avg.count { avg[i] = UInt8((Int(viterbiIn[2 * i]) + Int(viterbiIn[2 * i + 1])) / 2) }
            viterbiIn = avg
        }
        let nBits = viterbiIn.count / 2
        let bits = HFDLViterbi.decode(soft: viterbiIn, bitCount: nBits)
        var bytes = [UInt8](repeating: 0, count: (nBits + 7) / 8)
        for i in 0..<nBits where bits[i] == 1 { bytes[i / 8] |= 1 << UInt8(i % 8) }
        return DemodResult(bytes: bytes, freqHz: freqHz, snr: snr)
    }

    /// Weiche Bits wie liquid-dsp (0…255, 255 = Bit 1), höchstes Bit zuerst; Gray-Zuordnung, Punkte bei Winkel j·2π/M
    static func softBits(_ u: Cx, bits: Int) -> [UInt8] {
        func clamp(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v))) }
        if bits == 1 { return [clamp(127 - 128 * u.re)] }
        let mpsk = 1 << bits
        var dmin0 = [Double](repeating: 8, count: bits)
        var dmin1 = [Double](repeating: 8, count: bits)
        for j in 0..<mpsk {
            let p = Cx.polar(Double(j) * 2 * Double.pi / Double(mpsk))
            let d = (u - p).abs2
            let sym = j ^ (j >> 1)                         // Gray-Kodierung des Konstellationsindex
            for b in 0..<bits {
                if (sym >> (bits - 1 - b)) & 1 == 1 { dmin1[b] = min(dmin1[b], d) } else { dmin0[b] = min(dmin0[b], d) }
            }
        }
        let gamma = 1.2 * Double(mpsk)
        return (0..<bits).map { clamp((dmin0[$0] - dmin1[$0]) * gamma * 16 + 127) }
    }
}
