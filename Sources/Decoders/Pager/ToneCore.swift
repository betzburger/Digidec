// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - Normen

/// Tonfolgen: DTMF (Zweitonwahl) und Selektivrufe mit Einzeltönen
public enum ToneStandard: String, CaseIterable, Identifiable, Sendable {
    case dtmf, zvei1, zvei2, zvei3, dzvei, pzvei, ccir, eea, eia, selcal

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .dtmf:  return "DTMF"
        case .zvei1: return "ZVEI 1"
        case .zvei2: return "ZVEI 2"
        case .zvei3: return "ZVEI 3"
        case .dzvei: return "DZVEI"
        case .pzvei: return "PZVEI"
        case .ccir:  return "CCIR"
        case .eea:   return "EEA"
        case .eia:   return "EIA"
        case .selcal: return "SELCAL"
        }
    }

    public var note: String {
        switch self {
        case .dtmf:  return "Tastenwahl (Telefon, Relais, Fernwirken): 697–941 Hz und 1209–1633 Hz, je Taste zwei Töne"
        case .zvei1: return "Fünftonfolge, 70 ms je Ton, Feuerwehr und BOS in Deutschland (Alarmierung, Kennungen)"
        case .zvei2: return "ZVEI 2: wie ZVEI 1, Wiederholton 885 Hz statt 2600 Hz"
        case .zvei3: return "ZVEI 3, selten"
        case .dzvei: return "DZVEI (niederländische Variante)"
        case .pzvei: return "PZVEI (britische Variante)"
        case .ccir:  return "CCIR, 100 ms je Ton (Seefunk, Schiffsrufe, Betriebsfunk)"
        case .eea:   return "EEA, 40 ms je Ton"
        case .eia:   return "EIA, 33 ms je Ton"
        case .selcal: return "SELCAL (ARINC 714, Flugfunk auf HF): vier Buchstaben aus zwei Doppeltönen von je 1 s, 0,2 s Pause; ruft ein Flugzeug (z. B. AB-CD)"
        }
    }

    /// Töne in Hz; Index = Zeichen (0–9, dann A–F). Bei DTMF: Zeilen- und Spaltentöne.
    public var frequencies: [Double] {
        switch self {
        case .dtmf:  return [697, 770, 852, 941, 1209, 1336, 1477, 1633]
        case .zvei1: return [2400, 1060, 1160, 1270, 1400, 1530, 1670, 1830, 2000, 2200, 2800, 810, 970, 885, 2600, 680]
        case .zvei2: return [2400, 1060, 1160, 1270, 1400, 1530, 1670, 1830, 2000, 2200, 885, 825, 740, 680, 970, 2600]
        case .zvei3: return [2400, 1060, 1160, 1270, 1400, 1530, 1670, 1830, 2000, 2200, 885, 810, 2800, 680, 970, 2600]
        case .dzvei: return [2200, 970, 1060, 1160, 1270, 1400, 1530, 1670, 1830, 2000, 825, 740, 2600, 885, 2400, 680]
        case .pzvei: return [2400, 1060, 1160, 1270, 1400, 1530, 1670, 1830, 2000, 2200, 970, 810, 2800, 885, 2400, 680]
        case .ccir:  return [1981, 1124, 1197, 1275, 1358, 1446, 1540, 1640, 1747, 1860, 2400, 930, 2247, 991, 2110, 1055]
        case .eea:   return [1981, 1124, 1197, 1275, 1358, 1446, 1540, 1640, 1747, 1860, 1055, 930, 2400, 991, 2110, 2247]
        case .eia:   return [600, 741, 882, 1023, 1164, 1305, 1446, 1587, 1728, 1869, 2151, 2433, 2010, 2292, 459, 1091]
        case .selcal: return ToneStandard.selcalFrequencies
        }
    }

    /// Sollzeit eines Tons in Sekunden
    public var toneSeconds: Double {
        switch self {
        case .dtmf: return 0.07
        case .zvei1, .zvei2, .zvei3, .dzvei, .pzvei: return 0.07
        case .ccir: return 0.1
        case .eea: return 0.04
        case .eia: return 0.033
        case .selcal: return 1.0
        }
    }

    /// SELCAL-Töne (ARINC 714) in Hz, Index = Buchstabe A B C D E F G H J K L M P Q R S
    public static let selcalFrequencies: [Double] = [312.6, 346.7, 384.6, 426.6, 473.2, 524.8, 582.1, 645.7, 716.1, 794.3, 881.0, 977.2, 1083.9, 1202.3, 1333.5, 1479.1]
    public static let selcalLetters = Array("ABCDEFGHJKLMPQRS")

    /// Zeichen für einen Tonindex
    public func symbol(_ i: Int) -> Character {
        if self == .selcal { return Self.selcalLetters[i] }
        return Array("0123456789ABCDEF")[i]
    }
}

/// Eine erkannte Tonfolge
public struct ToneSequence: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public var start: Date
    public var standard: ToneStandard
    public var text: String
    public var isComplete = false

    public static func == (a: ToneSequence, b: ToneSequence) -> Bool { a.id == b.id && a.text == b.text && a.isComplete == b.isComplete }
}

// MARK: - Goertzel

/// Leistung bei einer Frequenz über ein Fenster (Goertzel-Filter)
struct Goertzel {
    let coeff: Double

    init(frequency: Double, sampleRate: Double) {
        coeff = 2 * cos(2 * .pi * frequency / sampleRate)
    }

    /// Leistung (Betragsquadrat) des Fensters, normiert auf die Fensterlänge: Amplitude² / 4 bei einem Sinus
    func power(_ x: ArraySlice<Float>) -> Double {
        var s1 = 0.0, s2 = 0.0
        for v in x {
            let s = Double(v) + coeff * s1 - s2
            s2 = s1
            s1 = s
        }
        let p = s1 * s1 + s2 * s2 - coeff * s1 * s2
        let n = Double(x.count)
        return p / (n * n)
    }
}

// MARK: - Selektivrufe und DTMF

/// Erkennt Tonfolgen einer Norm im 8-kHz-Audio und meldet sie, sobald ein Zeichen feststeht und wenn die Folge endet
public final class ToneDecoder {
    public let standard: ToneStandard
    public let sampleRate: Double
    private var goertzels: [Goertzel] = []
    private var window: [Float] = []
    private let windowLength: Int
    private let hop: Int
    private var sinceHop = 0
    private var candidate = -1
    private var candidateHops = 0
    private var lastEmitted = -2
    private var silentHops = 0
    private var sequence = ""
    private var sequenceStart = Date()
    private var active = false
    private var releaseHops = 0
    // SELCAL: zwei Impulse mit je zwei gleichzeitigen Tönen
    private var hann: [Float] = []
    private var selHop = 0
    private var selCandidate: String?
    private var selCandidateHops = 0
    private var selCounted = false
    private var selFirst: (pair: String, lastHop: Int, start: Date)?

    public init(standard: ToneStandard, sampleRate: Double = 8_000) {
        self.standard = standard
        self.sampleRate = sampleRate
        goertzels = standard.frequencies.map { Goertzel(frequency: $0, sampleRate: sampleRate) }
        // Fenster: bei dichten Tönen (Abstand ≥ 73 Hz) mindestens 20 ms, höchstens 60 % der Tondauer
        let w = standard == .selcal ? 0.08 : max(0.02, min(0.04, standard.toneSeconds * 0.6))
        windowLength = Int(w * sampleRate)
        hop = Int((standard == .selcal ? 0.025 : 0.005) * sampleRate)
        if standard == .selcal {
            hann = (0..<windowLength).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(windowLength - 1))) }
        }
    }

    public func reset() {
        window.removeAll()
        candidate = -1; candidateHops = 0; lastEmitted = -2; silentHops = 0; sequence = ""; active = false; sinceHop = 0
        selCandidate = nil; selCandidateHops = 0; selCounted = false; selFirst = nil
    }

    /// `onChange`: Folge hat sich geändert (Text, abgeschlossen?)
    public func process(_ block: UnsafeBufferPointer<Float>, now: Date = Date(), onChange: (ToneSequence) -> Void) {
        for v in block {
            window.append(v)
            if window.count > windowLength { window.removeFirst(window.count - windowLength) }
            sinceHop += 1
            if sinceHop >= hop, window.count == windowLength {
                sinceHop = 0
                step(now: now, onChange: onChange)
            }
        }
    }

    private func step(now: Date, onChange: (ToneSequence) -> Void) {
        if standard == .selcal { stepSelcal(now: now, onChange: onChange); return }
        let detected = standard == .dtmf ? detectDTMF() : detectSingle()
        // Schritte, in denen das Fenster ganz im Ton liegt: (Tondauer − Fenster) / Schritt + 1; davon gut die Hälfte genügt
        let steady = (standard.toneSeconds - Double(windowLength) / sampleRate) / 0.005 + 1
        let minHops = max(2, Int(steady * 0.55))
        if detected >= 0 {
            silentHops = 0
            if detected == candidate { candidateHops += 1 } else { candidate = detected; candidateHops = 1 }
            if candidateHops >= minHops && detected != lastEmitted {
                lastEmitted = detected
                if !active { active = true; sequence = ""; sequenceStart = now }
                sequence.append(standard == .dtmf ? Array("123A456B789C*0#D")[detected] : standard.symbol(detected))
                onChange(ToneSequence(start: sequenceStart, standard: standard, text: sequence, isComplete: false))
            }
        } else {
            silentHops += 1
            candidate = -1; candidateHops = 0
            // Zwischen zwei gleichen DTMF-Tasten liegt eine Pause: danach darf dieselbe Taste wieder zählen
            if standard == .dtmf, silentHops >= 3 { lastEmitted = -2 }
            let endHops = standard == .dtmf ? 160 : max(12, Int(standard.toneSeconds * 4 / 0.005))
            if active && silentHops >= endHops {
                active = false
                lastEmitted = -2
                onChange(ToneSequence(start: sequenceStart, standard: standard, text: sequence, isComplete: true))
            }
        }
    }

    /// Einzelton der Norm: stärkster Ton, deutlich vor allen anderen und mit Anteil an der Gesamtleistung
    private func detectSingle() -> Int {
        let slice = window[...]
        var total = 0.0
        for v in slice { total += Double(v) * Double(v) }
        total /= Double(slice.count)
        guard total > 1e-6 else { return -1 }
        var best = -1, bestP = 0.0, second = 0.0
        for (i, g) in goertzels.enumerated() {
            // Gleiche Frequenz unter mehreren Zeichen (PZVEI): nur das erste zählt
            if let j = standard.frequencies.firstIndex(of: standard.frequencies[i]), j != i { continue }
            let p = g.power(slice)
            if p > bestP { second = bestP; bestP = p; best = i } else if p > second { second = p }
        }
        // Ein reiner Sinus hat die Leistung A²/2 = total, im Goertzel-Wert A²/4
        guard best >= 0, bestP * 2 > 0.4 * total, bestP > 6 * second else { return -1 }
        return best
    }

    /// DTMF: je ein Zeilen- und ein Spaltenton, Abstand zu den anderen, Pegelunterschied („Twist“) begrenzt
    private func detectDTMF() -> Int {
        let slice = window[...]
        var total = 0.0
        for v in slice { total += Double(v) * Double(v) }
        total /= Double(slice.count)
        guard total > 1e-6 else { return -1 }
        let p = goertzels.map { $0.power(slice) }
        // Frequenzen: Index 0–3 = 697–941 (tiefe Gruppe, Zeilen), 4–7 = 1209–1633 (hohe Gruppe, Spalten)
        let low = Array(p[0..<4]), high = Array(p[4..<8])
        let rowIdx = (0..<4).max { low[$0] < low[$1] }!
        let colIdx = (0..<4).max { high[$0] < high[$1] }!
        let rowP = low[rowIdx], colP = high[colIdx]
        let otherRow = (0..<4).filter { $0 != rowIdx }.map { low[$0] }.max() ?? 0
        let otherCol = (0..<4).filter { $0 != colIdx }.map { high[$0] }.max() ?? 0
        guard rowP > 6 * otherRow, colP > 6 * otherCol else { return -1 }
        guard (rowP + colP) * 2 > 0.5 * total else { return -1 }
        let twist = 10 * log10(colP / rowP)
        guard twist > -9 && twist < 6 else { return -1 }
        return rowIdx * 4 + colIdx
    }
}

// MARK: - SELCAL

extension ToneDecoder {
    /// Ein Schritt der SELCAL-Erkennung: zwei Impulse (je zwei Töne, mindestens 0,35 s stabil), Pause höchstens 0,6 s
    fileprivate func stepSelcal(now: Date, onChange: (ToneSequence) -> Void) {
        selHop += 1
        let minStable = 14, maxGap = 24
        if let pair = detectSelcalPair() {
            if pair == selCandidate { selCandidateHops += 1 } else { selCandidate = pair; selCandidateHops = 1; selCounted = false }
            if selCandidateHops >= minStable && !selCounted {
                selCounted = true
                if let first = selFirst, (selHop - selCandidateHops + 1) - first.lastHop <= maxGap, first.pair != pair {   // Pause bis zum Beginn des zweiten Impulses
                    onChange(ToneSequence(start: first.start, standard: .selcal, text: first.pair + "-" + pair, isComplete: true))
                    selFirst = nil
                } else {
                    selFirst = (pair, selHop, now)
                }
            }
            if selCounted, selFirst?.pair == pair { selFirst?.lastHop = selHop }
        } else {
            selCandidate = nil; selCandidateHops = 0; selCounted = false
            if let first = selFirst, selHop - first.lastHop > maxGap { selFirst = nil }
        }
    }

    /// Die beiden stärksten SELCAL-Töne (Hann-Fenster, 80 ms): Buchstabenpaar in aufsteigender Reihenfolge, oder nil
    fileprivate func detectSelcalPair() -> String? {
        var total = 0.0
        for v in window { total += Double(v) * Double(v) }
        total /= Double(window.count)
        guard total > 1e-6 else { return nil }
        var weighted = [Float](repeating: 0, count: window.count)
        for i in 0..<window.count { weighted[i] = window[i] * hann[i] }
        // Hann-Fenster: kohärente Verstärkung 0,5, Leistung also 0,25
        let p = goertzels.map { $0.power(weighted[...]) / 0.25 }
        let order = (0..<16).sorted { p[$0] > p[$1] }
        let a = order[0], b = order[1], c = order[2]
        guard (p[a] + p[b]) * 2 > 0.35 * total, p[b] * 16 > p[a], p[c] * 8 < p[b] else { return nil }
        let lo = min(a, b), hi = max(a, b)
        return String(ToneStandard.selcalLetters[lo]) + String(ToneStandard.selcalLetters[hi])
    }
}

// MARK: - Testsignal

public enum ToneSignalGenerator {
    /// Selektivruf: je Zeichen ein Ton der Dauer `toneSeconds` (Norm), danach Stille
    public static func selcall(_ standard: ToneStandard, symbols: [Int], sampleRate: Double = 8_000, amplitude: Float = 0.5,
                               lead: Double = 0.2, tail: Double = 1.0) -> [Float] {
        var out = [Float](repeating: 0, count: Int(lead * sampleRate))
        var phase = 0.0
        for s in symbols {
            let f = standard.frequencies[s]
            let n = Int(standard.toneSeconds * sampleRate)
            for _ in 0..<n {
                out.append(Float(sin(phase)) * amplitude)
                phase += 2 * .pi * f / sampleRate
            }
        }
        out += [Float](repeating: 0, count: Int(tail * sampleRate))
        return out
    }

    /// DTMF-Tasten: je 70 ms Ton, 70 ms Pause
    public static func dtmf(_ keys: String, sampleRate: Double = 8_000, amplitude: Float = 0.25, tone: Double = 0.07, gap: Double = 0.07) -> [Float] {
        let layout = Array("123A456B789C*0#D")
        let rows = [697.0, 770, 852, 941], cols = [1209.0, 1336, 1477, 1633]
        var out = [Float](repeating: 0, count: Int(0.2 * sampleRate))
        for ch in keys {
            guard let idx = layout.firstIndex(of: ch) else { continue }
            let fr = rows[idx / 4], fc = cols[idx % 4]
            let n = Int(tone * sampleRate)
            for i in 0..<n {
                let t = Double(i) / sampleRate
                out.append(amplitude * (Float(sin(2 * .pi * fr * t)) + Float(sin(2 * .pi * fc * t))))
            }
            out += [Float](repeating: 0, count: Int(gap * sampleRate))
        }
        out += [Float](repeating: 0, count: Int(1.0 * sampleRate))
        return out
    }

    /// SELCAL: Code aus vier Buchstaben (z. B. „ABCD“): zwei Impulse von je 1 s mit je zwei Tönen, 0,2 s Pause
    public static func selcal(_ code: String, sampleRate: Double = 8_000, amplitude: Float = 0.25, lead: Double = 0.3, tail: Double = 1.0,
                              pulse: Double = 1.0, gap: Double = 0.2) -> [Float] {
        let letters = Array(code.uppercased().filter { ToneStandard.selcalLetters.contains($0) })
        guard letters.count == 4 else { return [] }
        var out = [Float](repeating: 0, count: Int(lead * sampleRate))
        for pair in [letters[0..<2], letters[2..<4]] {
            let f = pair.map { ToneStandard.selcalFrequencies[ToneStandard.selcalLetters.firstIndex(of: $0)!] }
            for i in 0..<Int(pulse * sampleRate) {
                let t = Double(i) / sampleRate
                out.append(amplitude * (Float(sin(2 * .pi * f[0] * t)) + Float(sin(2 * .pi * f[1] * t))))
            }
            out += [Float](repeating: 0, count: Int(gap * sampleRate))
        }
        out += [Float](repeating: 0, count: Int(tail * sampleRate))
        return out
    }
}
