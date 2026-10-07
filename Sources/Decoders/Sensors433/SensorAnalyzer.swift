// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Pakete, die kein Gerätedecoder erkennt („unbekannte Sensoren“): Pulsanalyse nach dem Vorbild des Analysators von rtl_433 (`pulse_analyzer.c`):
// Histogramme der Puls- und Lückenbreiten, Vermutung der Modulationsart (PPM, PWM, PCM, Manchester) und Bitzeilen als Hex, damit man erkennt,
// ob sich eine Aussendung wiederholt und wie lang sie ist. Wer einen neuen Decoder bauen will, findet hier die Zeiten und die Bits.

public struct PulseBin: Equatable, Sendable {
    /// Mittlere Breite in Mikrosekunden
    public var mean: Int
    public var count: Int
    public var min: Int
    public var max: Int
}

public struct UnknownPackage: Identifiable, Sendable {
    public let id = UUID()
    /// Sekunden seit Beginn des Stroms
    public var time: Double
    public var isFSK: Bool
    public var numPulses: Int
    public var rssiDB: Double
    public var snrDB: Double
    public var frequencyOffsetHz: Double
    /// Gesamtdauer des Pakets in Mikrosekunden
    public var durationMicroseconds: Int
    public var pulseBins: [PulseBin]
    public var gapBins: [PulseBin]
    /// Vermutete Modulationsart („OOK PPM“, „FSK PCM“ …) oder „unklar“
    public var modulation: String
    /// Zeiten, mit denen die Zeilen gebildet wurden (Mikrosekunden); leer, wenn unklar
    public var shortWidth: Int
    public var longWidth: Int
    /// Bitzeilen als Hex mit Bitzahl, z. B. „{40} 1a2b3c4d5e“
    public var rows: [String]
    public var rowBits: [Int]
    /// Wie oft die häufigste Zeile vorkommt (Wiederholungen eines Telegramms gelten als Zeichen für einen echten Sensor)
    public var repeats: Int
    /// Alle Puls- und Lückenbreiten in Mikrosekunden (abwechselnd), höchstens 600 Werte
    public var widths: [Int]

    /// Gleiche Quelle = gleiche Art: Kennzeichnung nach Modulationsart, gerundeten Breiten und Bitzahl
    public var signature: String {
        func round(_ v: Int) -> Int { v < 100 ? (v + 5) / 10 * 10 : v < 1000 ? (v + 25) / 50 * 50 : (v + 250) / 500 * 500 }
        let widthsText = (pulseBins.first.map { "P\(round($0.mean))" } ?? "") + (gapBins.first.map { "/L\(round($0.mean))" } ?? "")
        let bits = rowBits.max().map { " \($0 / 4 * 4) Bit" } ?? ""
        return "\(modulation) \(widthsText)\(bits)"
    }
}

public enum SensorAnalyzer {
    /// Mindestzahl von Pulsen, damit ein Paket ohne Treffer überhaupt gezeigt wird (kürzere sind fast immer Störungen)
    public static let minimumPulses = 12

    /// Gruppiert Breiten (µs): Werte, die höchstens 12 % (und 25 µs) vom Mittel der Gruppe abweichen, gehören zusammen
    static func bins(_ values: [Int]) -> [PulseBin] {
        let sorted = values.sorted()
        var result: [PulseBin] = []
        var sum = 0
        var group: [Int] = []
        func close() {
            guard !group.isEmpty else { return }
            result.append(PulseBin(mean: sum / group.count, count: group.count, min: group.first!, max: group.last!))
            group = []; sum = 0
        }
        for v in sorted {
            if let first = group.first {
                let mean = sum / group.count
                _ = first
                if Double(v) > Double(mean) * 1.12 + 25 { close() }
            }
            group.append(v); sum += v
        }
        close()
        return result
    }

    private static func isMultiple(_ value: Int, of unit: Int) -> Bool {
        guard unit > 0 else { return false }
        let ratio = Double(value) / Double(unit)
        return abs(ratio - ratio.rounded()) < 0.22 && ratio.rounded() >= 1 && ratio.rounded() <= 8
    }

    /// Paket ohne Treffer analysieren; `nil`, wenn es zu kurz oder zu unregelmäßig ist
    public static func analyze(_ data: PulseData, isFSK: Bool, time: Double, rssiDB: Double, snrDB: Double, frequencyOffsetHz: Double) -> UnknownPackage? {
        let n = data.numPulses
        guard n >= minimumPulses else { return nil }
        let unit = 1.0e6 / Double(data.sampleRate)
        func us(_ v: Int) -> Int { Int((Double(v) * unit).rounded()) }
        let pulses = (0..<n).map { us(data.pulse[$0]) }
        let gaps = (0..<n).map { us(data.gap[$0]) }
        let duration = zip(pulses, gaps).reduce(0) { $0 + $1.0 + $1.1 }
        // Längere Pausen zwischen den Wiederholungen: ab dem Vierfachen der mittleren Lücke
        let normalGapsAll = Array(gaps.dropLast()).sorted()
        guard !normalGapsAll.isEmpty else { return nil }
        let median = normalGapsAll[normalGapsAll.count / 2]
        let separator = max(median * 4, 1500)
        let gapsNormal = Array(gaps.dropLast()).filter { $0 < separator }
        let separators = Array(gaps.dropLast()).filter { $0 >= separator }
        let minCount = max(2, n / 40)
        // Gruppen unter 20 µs sind Störspitzen an den Flanken (besonders bei FSK) und zählen nicht
        let pulseBins = bins(pulses).filter { $0.count >= minCount && $0.mean >= 20 }
        let gapBins = bins(gapsNormal).filter { $0.count >= minCount && $0.mean >= 20 }
        let allBins = pulseBins + gapBins
        let unitBin = allBins.map(\.mean).min() ?? 1
        let multiples = !allBins.isEmpty && allBins.allSatisfy { isMultiple($0.mean, of: unitBin) }
        guard !pulseBins.isEmpty, !gapBins.isEmpty, multiples || (pulseBins.count <= 4 && gapBins.count <= 4), pulseBins.count <= 8, gapBins.count <= 8 else {
            return UnknownPackage(time: time, isFSK: isFSK, numPulses: n, rssiDB: rssiDB, snrDB: snrDB, frequencyOffsetHz: frequencyOffsetHz, durationMicroseconds: duration,
                                  pulseBins: pulseBins, gapBins: gapBins, modulation: "unklar", shortWidth: 0, longWidth: 0, rows: [], rowBits: [], repeats: 0,
                                  widths: widthList(pulses, gaps))
        }
        // Zeiten und Modulationsart vermuten
        var timing: SlicerTiming?
        var name = "unklar"
        let reset = Double(separators.min().map { $0 } ?? 100_000) * 4
        let gapLimit = separators.isEmpty ? 0 : Double(separator)
        let p0 = pulseBins[0], g0 = gapBins[0]
        if !isFSK {
            if pulseBins.count == 1 && gapBins.count == 2 {
                name = "OOK PPM"
                timing = SlicerTiming(.ookPPM, short: Double(g0.mean), long: Double(gapBins[1].mean), reset: reset, gap: gapLimit)
            } else if pulseBins.count == 2 && gapBins.count == 1 {
                name = "OOK PWM"
                timing = SlicerTiming(.ookPWM, short: Double(p0.mean), long: Double(pulseBins[1].mean), reset: reset, gap: gapLimit)
            } else if pulseBins.count == 2 && gapBins.count == 2 && isMultiple(pulseBins[1].mean, of: p0.mean) && pulseBins[1].mean > p0.mean * 3 / 2
                        && abs(g0.mean - p0.mean) * 3 < p0.mean {
                name = "OOK Manchester"
                timing = SlicerTiming(.ookManchesterZeroBit, short: Double(p0.mean), long: Double(p0.mean * 2), reset: reset, gap: gapLimit, tolerance: Double(p0.mean) / 2)
            } else if multiples {
                name = "OOK PCM"
                timing = SlicerTiming(.ookPCM, short: Double(unitBin), long: Double(unitBin), reset: reset, gap: gapLimit)
            } else if pulseBins.count >= 2 && gapBins.count == 1 {
                name = "OOK PWM"
                timing = SlicerTiming(.ookPWM, short: Double(p0.mean), long: Double(pulseBins.last!.mean), reset: reset, gap: gapLimit)
            } else if gapBins.count >= 2 && pulseBins.count == 1 {
                name = "OOK PPM"
                timing = SlicerTiming(.ookPPM, short: Double(g0.mean), long: Double(gapBins.last!.mean), reset: reset, gap: gapLimit)
            }
        } else {
            if multiples {
                name = "FSK PCM"
                timing = SlicerTiming(.fskPCM, short: Double(unitBin), long: Double(unitBin), reset: reset, gap: gapLimit)
            } else if pulseBins.count == 2 && gapBins.count == 1 {
                name = "FSK PWM"
                timing = SlicerTiming(.fskPWM, short: Double(p0.mean), long: Double(pulseBins[1].mean), reset: reset, gap: gapLimit)
            }
        }
        var rows: [String] = [], rowBits: [Int] = [], repeats = 0
        if let t = timing {
            var captured: BitBuffer?
            PulseSlicer.slice(data, timing: t) { bits in if captured == nil { captured = bits } }
            if let b = captured {
                for r in 0..<min(b.numRows, 8) where b.bitsPerRow[r] > 0 {
                    let hex = b.rows[r].map { String(format: "%02x", $0) }.joined()
                    rows.append("{\(b.bitsPerRow[r])} \(hex)")
                    rowBits.append(b.bitsPerRow[r])
                }
                repeats = (0..<b.numRows).map { b.countRepeats(row: $0) }.max() ?? 0
            }
        }
        return UnknownPackage(time: time, isFSK: isFSK, numPulses: n, rssiDB: rssiDB, snrDB: snrDB, frequencyOffsetHz: frequencyOffsetHz, durationMicroseconds: duration,
                              pulseBins: pulseBins, gapBins: gapBins, modulation: name, shortWidth: Int(timing?.shortWidth ?? 0), longWidth: Int(timing?.longWidth ?? 0),
                              rows: rows, rowBits: rowBits, repeats: repeats, widths: widthList(pulses, gaps))
    }

    private static func widthList(_ pulses: [Int], _ gaps: [Int]) -> [Int] {
        var out = [Int]()
        for i in 0..<min(pulses.count, 300) { out.append(pulses[i]); out.append(gaps[i]) }
        return out
    }
}
