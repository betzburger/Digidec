// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Vermessung eines Signals im HF-Wasserfall für den KI-Assistenten. Reine Logik (prüfbar): bekommt die letzten Zeilen des Spektrums
// (dB je Bin, neueste zuerst) und die angeklickte Frequenz und liefert, was sich am Signal messen lässt: Mitte, Rauschabstand,
// Bandbreiten, Linien, Zeitverhalten (Tastung, Periode), Drift und Tonlagen. Das Sprachmodell bekommt diese Werte als Text.

public struct SignalMeasurement: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        /// Abstand von der Mitte in Hz
        public var offsetHz: Double
        /// Pegel gegenüber dem stärksten Punkt in dB (≤ 0)
        public var relativeDB: Float
    }

    public var centerHz: Double
    public var peakDB: Float
    public var floorDB: Float
    public var bw3Hz: Double
    public var bw10Hz: Double
    public var bw20Hz: Double
    /// Breite über dem Rauschen (+6 dB), mit ihren Rändern
    public var occupiedHz: Double
    public var lowEdgeHz: Double
    public var highEdgeHz: Double
    public var lines: [Line]
    /// Abstand der Linien, wenn sie regelmäßig stehen (mindestens drei)
    public var lineSpacingHz: Double?
    /// Streuung des Spektrums im Band in dB (klein = flach wie bei OFDM oder Rauschen, groß = Linien)
    public var flatnessDB: Float
    public var binHz: Double
    public var rowInterval: Double
    public var duration: Double
    /// Pegelschwankung des Bandes über die Zeit (Spanne 10 % bis 90 %) in dB
    public var levelSwingDB: Float
    /// Anteil der Zeit mit Signal (nil bei stetigem Signal)
    public var duty: Double?
    public var onSegments: Int
    public var medianOnSeconds: Double?
    public var medianOffSeconds: Double?
    /// Wiederholdauer der Einschaltungen, wenn sie regelmäßig kommen
    public var periodSeconds: Double?
    /// Frequenzdrift in Hz je Sekunde (nil: zu wenig Zeilen)
    public var driftHzPerSecond: Double?
    /// Streuung der Spitzenlage nach Abzug der Drift in Hz
    public var peakJitterHz: Double
    /// Getrennte Tonlagen (Abstand von der Mitte in Hz), wenn die Spitze zwischen wenigen festen Lagen wechselt
    public var tones: [Double]

    public var snrDB: Float { peakDB - floorDB }
}

public enum SignalMeasure {
    /// Messung um `targetHz`. `rows`: neueste Zeile zuerst, alle gleich lang; `startHz`: Frequenz am linken Rand von Bin 0.
    public static func analyze(rows allRows: [[Float]], startHz: Double, binHz: Double, targetHz: Double, rowInterval: Double = 0.04) -> SignalMeasurement? {
        guard binHz > 0, let n = allRows.first?.count, n >= 16 else { return nil }
        let rows = allRows.filter { $0.count == n }
        guard rows.count >= 4 else { return nil }

        // Mittleres Leistungsspektrum
        var lin = [Double](repeating: 0, count: n)
        for r in rows { for i in 0..<n { lin[i] += pow(10, Double(r[i]) / 10) } }
        let avg: [Float] = lin.map { Float(10 * log10(max($0 / Double(rows.count), 1e-20))) }
        // Das Mittel über viele Zeilen glättet das Rauschen schon; bei wenigen Zeilen zusätzlich über drei Bins
        var sm = avg
        if rows.count < 20 { for i in 1..<(n - 1) { sm[i] = (avg[i - 1] + avg[i] + avg[i + 1]) / 3 } }

        // Spitze in der Nähe des Klicks
        let tb = min(max(Int(((targetHz - startHz) / binHz).rounded(.down)), 0), n - 1)
        let search = max(3, Int(2500 / binHz))
        let sLo = max(0, tb - search), sHi = min(n - 1, tb + search)
        var pk = sLo
        for i in sLo...sHi where sm[i] > sm[pk] { pk = i }

        // Rauschteppich: unteres Fünftel in der weiteren Umgebung
        let wide = max(200, n / 10)
        let wLo = max(0, pk - wide), wHi = min(n - 1, pk + wide)
        let sortedWindow = avg[wLo...wHi].sorted()
        let floorDB = sortedWindow[sortedWindow.count / 5]
        let peakDB = sm[pk]

        // Mitte aus parabolischer Interpolation
        var centerBin = Double(pk)
        if pk > 0, pk < n - 1 {
            let a = Double(avg[pk - 1]), b = Double(avg[pk]), c = Double(avg[pk + 1])
            let d = a - 2 * b + c
            if d < -1e-9 { centerBin += min(0.5, max(-0.5, 0.5 * (a - c) / d)) }
        }
        let centerHz = startHz + (centerBin + 0.5) * binHz

        func edges(level: Float, gap: Int) -> (lo: Int, hi: Int) {
            var lo = pk, last = pk
            var i = pk
            while i > 0, pk - i <= wide * 2 { i -= 1; if sm[i] >= level { last = i; lo = i } else if last - i > gap { break } }
            var hi = pk
            last = pk
            i = pk
            while i < n - 1, i - pk <= wide * 2 { i += 1; if sm[i] >= level { last = i; hi = i } else if i - last > gap { break } }
            return (lo, hi)
        }
        func width(_ e: (lo: Int, hi: Int)) -> Double { Double(e.hi - e.lo + 1) * binHz }

        let e3 = edges(level: peakDB - 3, gap: 1)
        let e10 = edges(level: peakDB - 10, gap: 1)
        let e20 = edges(level: peakDB - 20, gap: 2)
        let eOcc = edges(level: floorDB + 6, gap: max(3, Int(300 / binHz)))

        // Linien im belegten Band
        var cands: [(bin: Int, db: Float)] = []
        let bLo = max(1, eOcc.lo), bHi = min(n - 2, eOcc.hi)
        if bLo <= bHi {
            for i in bLo...bHi {
                guard avg[i] >= floorDB + 10, avg[i] >= peakDB - 25 else { continue }
                let lo = max(0, i - 2), hi = min(n - 1, i + 2)
                if avg[i] >= avg[lo...hi].max()! { cands.append((i, avg[i])) }
            }
        }
        // Benachbarte gleich hohe Plateaus nur einmal
        var picked: [(bin: Int, db: Float)] = []
        for c in cands.sorted(by: { $0.db > $1.db }) where !picked.contains(where: { abs($0.bin - c.bin) < 3 }) { picked.append(c) }
        let top = picked.prefix(8).sorted { $0.bin < $1.bin }
        let lines = top.map { SignalMeasurement.Line(offsetHz: (Double($0.bin) - centerBin) * binHz, relativeDB: $0.db - peakDB) }
        var spacing: Double?
        if top.count >= 3 {
            let diffs = zip(top.dropFirst(), top).map { Double($0.bin - $1.bin) * binHz }
            let med = diffs.sorted()[diffs.count / 2]
            if med > 0, diffs.allSatisfy({ abs($0 - med) <= 0.15 * med + binHz }) { spacing = med }
        }

        // Streuung im Band
        var flat: Float = 0
        if e10.hi > e10.lo {
            let seg = avg[e10.lo...e10.hi]
            let mean = seg.reduce(0, +) / Float(seg.count)
            flat = (seg.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(seg.count)).squareRoot()
        }

        // Zeitverhalten im belegten Band (älteste Zeile zuerst)
        var bandLo = eOcc.lo, bandHi = eOcc.hi
        if bandHi - bandLo < 2 { bandLo = max(0, pk - 1); bandHi = min(n - 1, pk + 1) }
        let ordered = rows.reversed()
        var level: [Float] = []
        var peakPos: [Int] = []
        for r in ordered {
            var sum = 0.0
            var best = bandLo
            for i in bandLo...bandHi {
                sum += pow(10, Double(r[i]) / 10)
                if r[i] > r[best] { best = i }
            }
            level.append(Float(10 * log10(max(sum, 1e-20))))
            peakPos.append(best)
        }
        let ls = level.sorted()
        let p10 = ls[ls.count / 10], p90 = ls[min(ls.count - 1, ls.count * 9 / 10)]
        let swing = p90 - p10
        var duty: Double?
        var onSegs = 0
        var medOn: Double?, medOff: Double?, period: Double?
        var on = [Bool](repeating: true, count: level.count)
        if swing >= 4 {
            let thr = (p10 + p90) / 2
            on = level.map { $0 > thr }
            duty = Double(on.filter { $0 }.count) / Double(on.count)
            // Läufe (ohne die angeschnittenen am Rand)
            var runs: [(on: Bool, start: Int, len: Int)] = []
            var s = 0
            for i in 1...on.count {
                if i == on.count || on[i] != on[s] { runs.append((on[s], s, i - s)); s = i }
            }
            let inner = runs.dropFirst().dropLast()
            onSegs = runs.filter { $0.on }.count
            let ons = inner.filter { $0.on }.map { Double($0.len) * rowInterval }.sorted()
            let offs = inner.filter { !$0.on }.map { Double($0.len) * rowInterval }.sorted()
            medOn = ons.isEmpty ? nil : ons[ons.count / 2]
            medOff = offs.isEmpty ? nil : offs[offs.count / 2]
            let starts = runs.filter { $0.on }.map { Double($0.start) * rowInterval }
            if starts.count >= 4 {
                let d = zip(starts.dropFirst(), starts).map { $0 - $1 }.sorted()
                let med = d[d.count / 2]
                if med > 0, (d.last! - d.first!) / med < 0.25 { period = med }
            }
        }

        // Lage der Spitze über die Zeit (nur Zeilen mit Signal)
        var xs: [Double] = [], ys: [Double] = []
        for (i, p) in peakPos.enumerated() where on[i] { xs.append(Double(i) * rowInterval); ys.append((Double(p) - centerBin) * binHz) }
        var drift: Double?
        var jitter = 0.0
        if xs.count >= 8 {
            let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            var sxx = 0.0, sxy = 0.0
            for (x, y) in zip(xs, ys) { sxx += (x - mx) * (x - mx); sxy += (x - mx) * (y - my) }
            let slope = sxx > 0 ? sxy / sxx : 0
            drift = slope
            var sq = 0.0
            for (x, y) in zip(xs, ys) { let r = y - (my + slope * (x - mx)); sq += r * r }
            jitter = (sq / Double(xs.count)).squareRoot()
        }

        // Feste Tonlagen: Spitzen nach Lage sortieren und bei Lücken trennen
        var tones: [Double] = []
        if ys.count >= 10, (drift.map { abs($0) * Double(rows.count) * rowInterval } ?? 0) < 3 * binHz + 50 {
            let sorted = ys.sorted()
            let tol = max(1.5 * binHz, 15)
            var groups: [[Double]] = [[sorted[0]]]
            for v in sorted.dropFirst() { if v - groups[groups.count - 1].last! > tol { groups.append([v]) } else { groups[groups.count - 1].append(v) } }
            let big = groups.filter { Double($0.count) >= 0.1 * Double(sorted.count) }
            if big.count >= 2, big.count <= 4 { tones = big.map { $0.reduce(0, +) / Double($0.count) } }
        }

        // Bei zwei oder mehr festen Tonlagen (FSK) liegt die Mitte zwischen ihnen
        var centerOut = centerHz
        var linesOut = lines
        if tones.count >= 2 {
            let mid = tones.reduce(0, +) / Double(tones.count)
            centerOut += mid
            tones = tones.map { $0 - mid }
            linesOut = lines.map { SignalMeasurement.Line(offsetHz: $0.offsetHz - mid, relativeDB: $0.relativeDB) }
        }

        return SignalMeasurement(
            centerHz: centerOut, peakDB: peakDB, floorDB: floorDB,
            bw3Hz: width(e3), bw10Hz: width(e10), bw20Hz: width(e20), occupiedHz: width(eOcc),
            lowEdgeHz: startHz + Double(eOcc.lo) * binHz, highEdgeHz: startHz + Double(eOcc.hi + 1) * binHz,
            lines: linesOut, lineSpacingHz: spacing, flatnessDB: flat, binHz: binHz, rowInterval: rowInterval,
            duration: Double(rows.count) * rowInterval, levelSwingDB: swing, duty: duty, onSegments: onSegs,
            medianOnSeconds: medOn, medianOffSeconds: medOff, periodSeconds: period, driftHzPerSecond: drift,
            peakJitterHz: jitter, tones: tones)
    }
}

// MARK: - Text für das Sprachmodell

extension SignalMeasurement {
    /// Die Messung als Text mit deutschen Zahlen. Nennt auch die Grenzen (Auflösung), damit das Modell nichts herausliest, was nicht da ist.
    public func describe() -> String {
        func f(_ v: Double, _ d: Int = 1) -> String { String(format: "%.\(d)f", v).replacingOccurrences(of: ".", with: ",") }
        func hz(_ v: Double) -> String { abs(v) >= 1000 ? f(v / 1000, 2) + " kHz" : f(v, 0) + " Hz" }
        var out: [String] = []
        out.append("Mitte: \(AssistantFormat.frequency(centerHz))")
        out.append("Pegel Spitze \(f(Double(peakDB), 1)) dBFS, Rauschteppich \(f(Double(floorDB), 1)) dBFS, Rauschabstand \(f(Double(snrDB), 1)) dB")
        out.append("Bandbreite: −3 dB \(hz(bw3Hz)), −10 dB \(hz(bw10Hz)), −20 dB \(hz(bw20Hz)); über dem Rauschen (+6 dB) \(hz(occupiedHz)) von \(AssistantFormat.frequency(lowEdgeHz)) bis \(AssistantFormat.frequency(highEdgeHz))")
        if lines.count >= 2 {
            let list = lines.map { "\($0.offsetHz >= 0 ? "+" : "−")\(hz(abs($0.offsetHz))) (\(f(Double($0.relativeDB), 0)) dB)" }.joined(separator: ", ")
            out.append("Linien im Band (Abstand von der Mitte, Pegel zur Spitze): \(list)")
            if let s = lineSpacingHz { out.append("Die Linien stehen regelmäßig im Abstand von \(hz(s))") }
        } else {
            out.append("Eine einzelne Linie, keine weiteren Träger im Band")
        }
        out.append(flatnessDB < 2.5 && occupiedHz >= 6 * binHz
                   ? "Spektrum im Band flach (Streuung \(f(Double(flatnessDB), 1)) dB): breitbandig, wie Datensignal mit vielen Trägern oder Rauschen"
                   : "Spektrum im Band nicht flach (Streuung \(f(Double(flatnessDB), 1)) dB)")
        if let duty {
            var t = "Zeitverhalten in \(f(duration, 1)) s: getastet bzw. mit Pausen, Signal an \(f(duty * 100, 0)) % der Zeit, \(onSegments) Einschaltungen, Pegelschwankung \(f(Double(levelSwingDB), 0)) dB"
            if let a = medianOnSeconds { t += ", typische Dauer an \(f(a, 2)) s" }
            if let b = medianOffSeconds { t += ", aus \(f(b, 2)) s" }
            if let p = periodSeconds { t += ", Wiederholung etwa alle \(f(p, 1)) s" }
            out.append(t)
        } else {
            out.append("Zeitverhalten in \(f(duration, 1)) s: stetiges Signal (Pegelschwankung \(f(Double(levelSwingDB), 1)) dB)")
        }
        if !tones.isEmpty {
            let list = tones.map { ($0 >= 0 ? "+" : "−") + hz(abs($0)) }.joined(separator: ", ")
            out.append("Die Spitze wechselt zwischen \(tones.count) festen Tonlagen (\(list) von der Mitte)" + (tones.count == 2 ? ", Abstand \(hz(abs(tones[1] - tones[0]))): FSK-artig" : ""))
        } else if let d = driftHzPerSecond {
            out.append("Frequenzlage: Drift \(f(d, 2)) Hz/s, Streuung \(hz(peakJitterHz))")
        }
        out.append("Messgrenzen: Frequenzauflösung \(hz(binHz)) je Bin, Zeitauflösung \(f(rowInterval * 1000, 0)) ms je Zeile, Beobachtung \(f(duration, 1)) s. Schnellere Tastung oder feinere Abstände sind darin nicht zu erkennen.")
        return out.joined(separator: "\n")
    }
}

/// Zahlen- und Frequenzformat für Texte an das Sprachmodell
public enum AssistantFormat {
    /// „10.099,8000 kHz“ bzw. „144,8000 MHz“
    public static func frequency(_ hz: Double) -> String {
        let s = hz >= 30_000_000 ? String(format: "%.4f MHz", hz / 1e6) : String(format: "%.3f kHz", hz / 1e3)
        return s.replacingOccurrences(of: ".", with: ",")
    }
}
