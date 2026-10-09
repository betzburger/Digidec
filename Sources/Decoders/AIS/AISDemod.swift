// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Accelerate

// AIS-Empfänger für FM-Diskriminator-Audio (GMSK, 9600 Bd, BT 0,4, Hub ±2,4 kHz).
//
// Ablauf je Burst: Tiefpass → gleitende Korrelation mit der bekannten Vorlage (Training 24 Bit „0101…“ und Startflagge 0x7E,
// als Pegelfolge nach NRZI, Gauß-geformt) → Treffer liefert Lage, Polarität, Gleichanteil und Amplitude →
// Bits im Bittakt abtasten, Takt aus den Nulldurchgängen nachführen → NRZI → HDLC (Entstopfen, Flaggen, CRC-16).
// Scheitert die Prüfsumme, werden Lage, Takt und Schwelle leicht verändert und neu versucht.

// MARK: - Pulsform

public enum AISPulse {
    public static let baud = 9600.0
    public static let bt = 0.4

    /// Frequenzverlauf einer Pegelfolge (±1 ↔ ±Hub), Gauß-Filter mit BT, auf dem Raster von `samplesPerBit`.
    /// Abtastwert n liegt bei der Zeit (n + phase) / samplesPerBit Bitdauern; Bit k belegt [k, k+1).
    /// Vor dem ersten und nach dem letzten Bit gilt dessen Pegel weiter.
    public static func render(levels: [Float], samplesPerBit sps: Double, count: Int, phase: Double = 0, bt: Double = AISPulse.bt) -> [Float] {
        guard !levels.isEmpty else { return [Float](repeating: 0, count: count) }
        let sigma = log(2.0).squareRoot() / (2 * Double.pi * bt)      // in Bitdauern
        let s2 = sigma * 2.0.squareRoot()
        let span = 3
        let pad = span + 2
        let ext = [Float](repeating: levels[0], count: pad) + levels + [Float](repeating: levels[levels.count - 1], count: pad)
        var out = [Float](repeating: 0, count: count)
        for n in 0..<count {
            let x = (Double(n) + phase) / sps + Double(pad)
            let k0 = Int(x.rounded(.down))
            var v = 0.0
            let lo = max(0, k0 - span), hi = min(ext.count - 1, k0 + span)
            if lo <= hi {
                for k in lo...hi {
                    let u = x - Double(k) - 0.5
                    v += Double(ext[k]) * 0.5 * (erf((u + 0.5) / s2) - erf((u - 0.5) / s2))
                }
            }
            out[n] = Float(v)
        }
        return out
    }

    /// Bekannter Anfang jedes Bursts auf der Leitung: Training 24 Bit, Startflagge 8 Bit (vor NRZI)
    public static let syncWireBits: [UInt8] = {
        var b: [UInt8] = []
        for i in 0..<24 { b.append(UInt8(i % 2)) }
        b += [0, 1, 1, 1, 1, 1, 1, 0]
        return b
    }()
}

// MARK: - Zähler

public struct AISStats: Equatable, Sendable {
    /// Treffer der Vorlage (Burst-Kandidaten mit guter Güte)
    public var bursts = 0
    /// Rahmen mit gültiger Prüfsumme (nach Zusammenfassen gleicher Rahmen der Empfängerzweige)
    public var frames = 0
    /// Burst erkannt (Güte hoch), aber kein gültiger Rahmen
    public var failed = 0
    /// Zahl der Rahmen, die erst ein Wiederholungsversuch (Lage, Takt, Schwelle verschoben) lesbar machte
    public var rescued = 0
    /// Rahmen mit gültiger Prüfsumme, aber unmöglicher Länge oder Kennung (Zufallstreffer)
    public var implausible = 0
    /// Zeitpunkt (Audiozeit in s) des letzten Rahmens
    public var lastFrameTime: Double?
}

// MARK: - Ein Demodulator

/// Ein Zweig des Empfängers mit eigenem Tiefpass
final class AISDemodulator {
    struct Config {
        var lowpassHz: Double
        var taps: Int = 41
        /// Schwelle der Korrelation (0 … 1), ab der ein Burst versucht wird
        var triggerThreshold: Float = 0.52
    }

    /// Ein vermuteter Burst
    private struct Capture {
        var start: Double            // Lage der Vorlage in Abtastwerten (absolut)
        var dc: Float
        var amplitude: Float
        var polarity: Float          // +1: Vorlage wie angenommen, −1 invertiert
        var quality: Float
        var due: Int                 // absoluter Index, ab dem versucht wird
        var stage: Int
    }

    let sampleRate: Double
    let sps: Double
    let config: Config
    var onFrame: (([UInt8], Bool) -> Void)?
    /// Burst mit guter Güte, aber ohne lesbaren Rahmen
    var onFailure: (() -> Void)?
    private(set) var bursts = 0
    private(set) var level: Float = 0

    // Filter
    private let h: [Float]
    private var ring: [Float]
    private var ringPos = 0

    // Pufferverlauf
    private var raw: [Float] = []           // Eingang unverändert (für den zweiten Versuch mit Begrenzer), parallel zu `buf`
    private var buf: [Float] = []
    private var base = 0                // absoluter Index von buf[0]
    private var count = 0               // Zahl der bisher verarbeiteten Abtastwerte

    // Vorlage
    private let tmpl: [Float]
    private let tmplMean: Float         // Mittelwert der unverschobenen Vorlage (Pegel ±1)
    private let tmplNorm: Float         // Wurzel aus der Summe der Quadrate (zentriert)
    private let tmplEnergy: Float
    private let n: Int                  // Länge der Vorlage in Abtastwerten
    private let lastLevel: Float        // Pegel des letzten Flaggenbits (Vorlage mit Startpegel +1)
    private var winSum: Double = 0
    private var winSq: Double = 0

    // Spitzensuche
    private var run: (last: Int, bestIndex: Int, best: Float, sign: Float, before: Float, after: Float, count: Int)?
    private var rhoPrev: Float = 0
    private var captures: [Capture] = []
    private var blockedUntil = 0

    /// Bits, die nach der Flagge ausgelesen werden: erster Versuch (für Rahmen bis 2 Zeitschlitze), zweiter für längere
    /// Entwicklungshilfe: AIS_STAGES (Bitmaske) schaltet Stufen ab: 1 = Bitfehler-Korrektur, 2 = Begrenzer, 4 = Wiederholungen
    static let stages: Int = Int(ProcessInfo.processInfo.environment["AIS_STAGES"] ?? "") ?? 7
    static let firstBits = 340
    static let longBits = 1_260

    init(sampleRate: Double, config: Config) {
        self.sampleRate = sampleRate
        self.config = config
        sps = sampleRate / AISPulse.baud
        // Tiefpass (Fenster-Sinc, Blackman)
        let taps = config.taps | 1
        let fc = config.lowpassHz / sampleRate
        var hh = [Float](repeating: 0, count: taps)
        let mid = Double(taps - 1) / 2
        var sum = 0.0
        for i in 0..<taps {
            let x = Double(i) - mid
            let sinc = x == 0 ? 2 * fc : sin(2 * Double.pi * fc * x) / (Double.pi * x)
            let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(i) / Double(taps - 1)) + 0.08 * cos(4 * Double.pi * Double(i) / Double(taps - 1))
            hh[i] = Float(sinc * w)
            sum += sinc * w
        }
        h = hh.map { $0 / Float(sum) }
        ring = [Float](repeating: 0, count: taps)

        // Vorlage: Pegelfolge nach NRZI mit Startpegel +1, Gauß-geformt, durch denselben Tiefpass, Verzögerung des Filters herausgerechnet
        let levels = AISFraming.nrzi(AISPulse.syncWireBits)
        lastLevel = levels.last ?? 1
        let nn = Int((Double(levels.count) * sps).rounded())
        n = nn
        let pad = taps
        // etwas Vorlauf vor dem ersten Bit, damit die Filterflanke stimmt (Pegel vor Beginn = Pegel des ersten Bits)
        let lead = Int(ceil(Double(taps) / 2)) + 2
        let wave = AISPulse.render(levels: levels, samplesPerBit: sps, count: nn + 2 * pad, phase: Double(-lead))
        // Filter anwenden und die Verzögerung (taps-1)/2 abziehen
        var filtered = [Float](repeating: 0, count: nn)
        let d = (taps - 1) / 2
        for i in 0..<nn {
            var acc: Float = 0
            for k in 0..<taps {
                // Ausgang zur Zeit i (kompensiert) = Summe h[k] * raw(i + d - k + lead)
                let idx = i + d - k + lead
                if idx >= 0 && idx < wave.count { acc += h[k] * wave[idx] }
            }
            filtered[i] = acc
        }
        let mean = filtered.reduce(0, +) / Float(nn)
        tmplMean = mean
        var centered = filtered.map { $0 - mean }
        let e = centered.reduce(Float(0)) { $0 + $1 * $1 }
        tmplEnergy = e
        tmplNorm = e.squareRoot()
        // Vorlage mit Pegeln ±1: kein Skalieren; Mittelwert der Pegel (vor Filter) ist der Gleichanteil-Anteil
        for i in 0..<centered.count { centered[i] = centered[i] }
        tmpl = centered
        buf.reserveCapacity(60_000)
        raw.reserveCapacity(60_000)
    }

    func reset() {
        ring = [Float](repeating: 0, count: ring.count)
        ringPos = 0
        buf.removeAll(keepingCapacity: true)
        raw.removeAll(keepingCapacity: true)
        base = 0
        count = 0
        winSum = 0
        winSq = 0
        run = nil
        rhoPrev = 0
        captures.removeAll()
        blockedUntil = 0
    }

    // MARK: Eingang

    func process(_ samples: UnsafeBufferPointer<Float>) {
        let taps = h.count
        for x in samples {
            ring[ringPos] = x
            var acc: Float = 0
            var p = ringPos
            for k in 0..<taps {
                acc += h[k] * ring[p]
                p -= 1
                if p < 0 { p = taps - 1 }
            }
            ringPos += 1
            if ringPos == taps { ringPos = 0 }
            let y = acc
            level += 0.0004 * (abs(y) - level)
            buf.append(y)
            raw.append(x)
            count += 1
            // gleitende Summen über das Vorlagenfenster
            winSum += Double(y)
            winSq += Double(y) * Double(y)
            if count > n {
                let old = Double(buf[count - 1 - n - base])
                winSum -= old
                winSq -= old * old
            }
            if count >= n { correlate() }
            runCaptures()
        }
        if buf.count > 400_000 {
            let drop = buf.count - 200_000
            buf.removeFirst(drop)
            raw.removeFirst(drop)
            base += drop
        }
    }

    // MARK: Burst-Suche

    private func correlate() {
        let end = count - 1                               // absoluter Index des jüngsten Werts
        let start = count - n - base
        var dot: Float = 0
        buf.withUnsafeBufferPointer { b in
            tmpl.withUnsafeBufferPointer { t in
                vDSP_dotpr(b.baseAddress! + start, 1, t.baseAddress!, 1, &dot, vDSP_Length(n))
            }
        }
        let mean = winSum / Double(n)
        let varSum = max(winSq - winSum * mean, 1e-12)
        let rho = dot / (tmplNorm * Float(varSum.squareRoot()))
        let a = abs(rho)
        let sign: Float = rho >= 0 ? 1 : -1
        defer { rhoPrev = rho }
        guard end > blockedUntil else { return }
        if a >= config.triggerThreshold {
            if var r = run, r.sign == sign {
                if a > r.best { r.best = a; r.bestIndex = end; r.before = abs(rhoPrev); r.after = 0 }
                else if end == r.bestIndex + 1 { r.after = a }
                r.last = end
                r.count += 1
                run = r
            } else {
                if run != nil { closeRun() }
                run = (end, end, a, sign, abs(rhoPrev), 0, 1)
            }
        } else if let r = run, end - r.last >= 2 {
            closeRun()
        }
    }

    /// Güte der Korrelation für das Fenster, das bei absolutem Index `end` endet (0 bei fehlenden Werten)
    private func rhoAt(_ end: Int) -> Float {
        let s0 = end - n + 1 - base
        guard s0 >= 0, end - base < buf.count else { return 0 }
        var dot: Float = 0, sum: Float = 0, sq: Float = 0
        buf.withUnsafeBufferPointer { b in
            tmpl.withUnsafeBufferPointer { t in
                vDSP_dotpr(b.baseAddress! + s0, 1, t.baseAddress!, 1, &dot, vDSP_Length(n))
            }
            vDSP_sve(b.baseAddress! + s0, 1, &sum, vDSP_Length(n))
            vDSP_svesq(b.baseAddress! + s0, 1, &sq, vDSP_Length(n))
        }
        let v = max(Double(sq) - Double(sum) * Double(sum) / Double(n), 1e-12)
        return abs(dot) / (tmplNorm * Float(v.squareRoot()))
    }

    private func closeRun() {
        guard let r = run else { return }
        run = nil
        // Spitze der Güte, parabolisch verfeinert
        let yl = rhoAt(r.bestIndex - 1), y0 = r.best, yr = rhoAt(r.bestIndex + 1)
        var delta = 0.0
        let den = yl - 2 * y0 + yr
        if den < -1e-6 { delta = Double(0.5 * (yl - yr) / den) }
        delta = max(-0.5, min(0.5, delta))
        let peak = Double(r.bestIndex) + delta                     // Ende des Vorlagenfensters
        let start = peak - Double(n) + 1
        // Verstärkung und Gleichanteil aus dem Fenster
        let s0 = Int(start.rounded()) - base
        guard s0 >= 0, s0 + n <= buf.count else { return }
        var dot: Float = 0, sum: Float = 0
        buf.withUnsafeBufferPointer { b in
            tmpl.withUnsafeBufferPointer { t in
                vDSP_dotpr(b.baseAddress! + s0, 1, t.baseAddress!, 1, &dot, vDSP_Length(n))
            }
            vDSP_sve(b.baseAddress! + s0, 1, &sum, vDSP_Length(n))
        }
        let amp = dot / tmplEnergy
        let dc = sum / Float(n) - amp * tmplMean
        let cap = Capture(start: start, dc: dc, amplitude: abs(amp), polarity: r.sign, quality: r.best,
                          due: Int(start.rounded()) + Int(Double(32 + Self.firstBits + 6) * sps) + 6, stage: 0)
        // Nebenspitze desselben Bursts (die Vorlage ist im Training periodisch): nur die bessere behalten
        if let last = captures.last, abs(last.start - start) < 12 * sps, last.stage == 0 {
            if cap.quality > last.quality { captures[captures.count - 1] = cap }
        } else {
            captures.append(cap)
            bursts += 1
        }
        blockedUntil = r.bestIndex + Int(2 * sps)
    }

    private func runCaptures() {
        guard captures.contains(where: { count - 1 >= $0.due }) else { return }
        // Einträge nach Fälligkeit abarbeiten
        var remaining: [Capture] = []
        for cap in captures {
            if count - 1 < cap.due { remaining.append(cap); continue }
            let result = decode(cap)
            switch result {
            case .frame(let bits, let rescued):
                onFrame?(bits, rescued)
            case .needMore where cap.stage == 0:
                var c = cap
                c.stage = 1
                c.due = Int(cap.start.rounded()) + Int(Double(32 + Self.longBits + 6) * sps) + 6
                remaining.append(c)
            case .needMore, .failed:
                if cap.quality >= 0.7 { onFailure?() }
            }
        }
        captures = remaining
    }

    // MARK: Auslesen eines Bursts

    private enum Outcome { case frame([UInt8], Bool), failed, needMore }

    /// Wert des gefilterten Eingangs an der (gebrochenen) absoluten Stelle `t`, kubisch zwischen den Abtastwerten
    @inline(__always)
    private func value(at t: Double) -> Float? {
        let pos = t - Double(base)
        let i = Int(pos.rounded(.down))
        guard i >= 1, i + 2 < buf.count else { return nil }
        let f = Float(pos - Double(i))
        let p0 = buf[i - 1], p1 = buf[i], p2 = buf[i + 1], p3 = buf[i + 2]
        let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3
        let b = p0 - 2.5 * p1 + 2 * p2 - 0.5 * p3
        let c = -0.5 * p0 + 0.5 * p2
        return ((a * f + b) * f + c) * f + p1
    }

    /// Weichwerte (Abstand vom Schwellwert) der Datenbits j = 0 … count-1 ab Ende der Flagge; Bit j hat seine Mitte bei start + (32 + j + 0.5) · step
    private func soft(start: Double, step: Double, dc: Float, count nb: Int) -> [Float] {
        var out = [Float](repeating: 0, count: nb)
        for j in 0..<nb {
            guard let v = value(at: start + (Double(32 + j) + 0.5) * step) else { break }
            out[j] = v - dc
        }
        return out
    }

    /// Weichwerte durch NRZI und Rahmenbildung; liefert den Rahmen oder die Lage der Endflagge (Bitnummer).
    /// Mit `repair` wird bei falscher Prüfsumme versucht, ein oder zwei unsichere Bits umzukehren.
    private func frame(from s: [Float], lastSign: Float, scale: Float, repair: Bool = false) -> (frame: [UInt8]?, flagEnd: Int?, repaired: Bool) {
        var d = AISDeframer()
        // Startflagge einspeisen
        for b in AISPulse.syncWireBits.suffix(8) { _ = d.push(b) }
        var prev = lastSign
        var prevMag: Float = scale
        var flagEnd: Int?
        var lastFlags = d.flags
        for (j, z) in s.enumerated() {
            let level: Float = z >= 0 ? 1 : -1
            let bit: UInt8 = level == prev ? 1 : 0
            let mag = abs(z)
            let conf = min(mag, prevMag) / max(scale, 1e-6)
            prev = level
            prevMag = mag
            if let f = d.push(bit, confidence: conf) { return (f.bits, j, false) }
            if d.flags != lastFlags {
                lastFlags = d.flags
                if flagEnd == nil {
                    flagEnd = j
                    // Endflagge erreicht: Rahmen mit falscher Prüfsumme reparieren
                    if repair, let bad = d.lastRejected, bad.bits.count >= AISDeframer.minPayloadBits + 16 {
                        if let fixed = AISDeframer.repair(bad.bits, confidence: bad.confidence, accept: { AISMessage.isPlausible(AISBits($0), strictMMSI: true) }) {
                            return (fixed, j, true)
                        }
                    }
                }
            }
        }
        return (nil, flagEnd, false)
    }

    private func decode(_ cap: Capture) -> Outcome {
        let bitsWanted = cap.stage == 0 ? Self.firstBits : Self.longBits
        let lastSign = lastLevel * cap.polarity

        func attempt(start: Double, step: Double, dc: Float, repair: Bool = false) -> (frame: [UInt8]?, flagEnd: Int?, soft: [Float], repaired: Bool) {
            let s = soft(start: start, step: step, dc: dc, count: bitsWanted)
            let r = frame(from: s, lastSign: lastSign, scale: cap.amplitude, repair: repair)
            return (r.frame, r.flagEnd, s, r.repaired)
        }

        var start = cap.start
        var step = sps
        let dc0 = cap.dc
        // 1. Erster Versuch mit der Lage aus der Korrelation
        let first = attempt(start: start, step: step, dc: dc0)
        if let f = first.frame { return .frame(f, false) }
        // Keine Endflagge, aber das Signal hält an: der Rahmen ist länger als das erste Fenster
        if cap.stage == 0, first.flagEnd == nil, first.soft.count == Self.firstBits, burstContinues(first.soft) { return .needMore }
        // 2. Takt und Lage aus den Nulldurchgängen: bis zur Endflagge (sonst über 280 Bit), zweimal
        var softNow = first.soft
        var fitBits = first.flagEnd.map { $0 + 1 } ?? min(bitsWanted, 280)
        for _ in 0..<2 {
            guard let fit = timingFit(soft: softNow, dc: dc0, start: start, step: step, bits: fitBits) else { break }
            start += fit.a
            step += fit.b
            let r = attempt(start: start, step: step, dc: dc0, repair: Self.stages & 1 != 0)
            if let f = r.frame { return .frame(f, true) }
            softNow = r.soft
            if let e = r.flagEnd { fitBits = e + 1 }
        }
        // 3. Begrenzer: Störspitzen des FM-Diskriminators (Klicks bei schwachem Signal) abschneiden und den Tiefpass neu rechnen
        for factor in (Self.stages & 2 != 0 && cap.quality >= 0.6 ? [1.5, 1.2] : []) as [Float] {
            if let f = decodeLimited(cap, start: start, step: step, limit: factor * cap.amplitude, bits: bitsWanted, lastSign: lastSign) { return .frame(f, true) }
        }
        // 4. Wiederholungen mit verschobener Lage, Schwelle und Takt
        let a = cap.amplitude
        let shifts: [Double] = [0, -0.35, 0.35, -0.7, 0.7]
        let dcs: [Float] = [0, -0.15 * a, 0.15 * a, -0.3 * a, 0.3 * a]
        let steps: [Double] = Self.stages & 4 != 0 && cap.quality >= 0.72 ? [0, 0.0004 * sps, -0.0004 * sps, 0.001 * sps, -0.001 * sps] : []
        for ds in steps {
            for sh in shifts {
                for dcShift in dcs {
                    if ds == 0 && sh == 0 && dcShift == 0 { continue }
                    let r = attempt(start: start + sh, step: step + ds, dc: dc0 + dcShift)
                    if let f = r.frame { return .frame(f, true) }
                }
            }
        }
        return .failed
    }

    /// Zweiter Versuch mit begrenztem Eingang: Werte weiter als `limit` vom Gleichanteil entfernt werden abgeschnitten, dann Tiefpass und Auslesen wie gewohnt
    private func decodeLimited(_ cap: Capture, start: Double, step: Double, limit: Float, bits: Int, lastSign: Float) -> [UInt8]? {
        let taps = h.count
        let from = max(base + taps, Int(start.rounded(.down)) - 4 * Int(sps))
        let to = min(count, Int(start + Double(32 + bits + 6) * step) + 8)
        guard to - from > 100 else { return nil }
        var alt = [Float](repeating: 0, count: to - from)
        let dc = cap.dc
        for i in 0..<(to - from) {
            var acc: Float = 0
            let abs0 = from + i
            for k in 0..<taps {
                let idx = abs0 - k - base
                guard idx >= 0 else { continue }
                var v = raw[idx] - dc
                if v > limit { v = limit } else if v < -limit { v = -limit }
                acc += h[k] * (v + dc)
            }
            alt[i] = acc
        }
        let savedBuf = buf, savedBase = base
        buf = alt
        base = from
        defer { buf = savedBuf; base = savedBase }
        var st = start, sp = step
        for round in 0..<3 {
            let s0 = soft(start: st, step: sp, dc: cap.dc, count: bits)
            let r = frame(from: s0, lastSign: lastSign, scale: cap.amplitude, repair: true)
            if let f = r.frame { return f }
            guard round < 2 else { break }
            let fitBits = r.flagEnd.map { $0 + 1 } ?? min(bits, 280)
            guard let fit = timingFit(soft: s0, dc: cap.dc, start: st, step: sp, bits: fitBits) else { break }
            st += fit.a
            sp += fit.b
        }
        return nil
    }

    /// Hält das Signal am Ende des ersten Fensters noch an? (mittlerer Betrag der letzten 40 Bit im Vergleich zu den ersten 40)
    private func burstContinues(_ s: [Float]) -> Bool {
        guard s.count >= 80 else { return false }
        let tail = s.suffix(40).reduce(Float(0)) { $0 + abs($1) } / 40
        let head = s.prefix(40).reduce(Float(0)) { $0 + abs($1) } / 40
        return head > 0 && tail > 0.6 * head
    }

    /// Verschiebung `a` (Abtastwerte) und Taktfehler `b` (Abtastwerte je Bit) aus den Nulldurchgängen des Eingangs gegenüber den erwarteten Bitgrenzen
    private func timingFit(soft: [Float], dc: Float, start: Double, step: Double, bits: Int) -> (a: Double, b: Double)? {
        let count = min(bits, soft.count)
        guard count > 24 else { return nil }
        var xs: [Double] = [], rs: [Double] = []
        // Grenzen innerhalb der bekannten Folge (Training und Flagge) zählen auch: Bit j = -32 … -1 hat bekannte Pegel
        func levelAt(_ j: Int) -> Float? { j >= 0 ? (j < count ? (soft[j] >= 0 ? 1 : -1) : nil) : nil }
        var prev = soft[0] >= 0 ? Float(1) : -1
        for j in 1..<count {
            let cur: Float = soft[j] >= 0 ? 1 : -1
            defer { prev = cur }
            guard cur != prev else { continue }
            let expected = start + Double(32 + j) * step
            let k0 = Int(expected.rounded(.down)) - base
            var crossing: Double?
            for k in (k0 - 3)...(k0 + 3) where k >= 0 && k + 1 < buf.count {
                let a = buf[k] - dc, b = buf[k + 1] - dc
                if (a * cur < 0 && b * cur >= 0) {
                    let c = Double(k + base) + Double(a / (a - b))
                    if crossing == nil || abs(c - expected) < abs(crossing! - expected) { crossing = c }
                }
            }
            guard let c = crossing else { continue }
            let r = c - expected
            guard abs(r) < 3.5 else { continue }
            xs.append(Double(j)); rs.append(r)
        }
        func fit(_ keep: [Int]) -> (a: Double, b: Double, sigma: Double)? {
            guard keep.count > 12 else { return nil }
            var sn = 0.0, sj = 0.0, sjj = 0.0, sr = 0.0, sjr = 0.0
            for k in keep { sn += 1; sj += xs[k]; sjj += xs[k] * xs[k]; sr += rs[k]; sjr += xs[k] * rs[k] }
            let den = sn * sjj - sj * sj
            guard den > 0 else { return nil }
            let b = (sn * sjr - sj * sr) / den, a = (sr - b * sj) / sn
            var q = 0.0
            for k in keep { let e = rs[k] - a - b * xs[k]; q += e * e }
            return (a, b, (q / sn).squareRoot())
        }
        guard let first = fit(Array(xs.indices)) else { return nil }
        let limit = max(0.5, 2.0 * first.sigma)
        let kept = xs.indices.filter { abs(rs[$0] - first.a - first.b * xs[$0]) <= limit }
        let second = fit(kept) ?? first
        // Bei Rauschen bleibt die Korrektur klein
        return (max(-2, min(2, second.a)), max(-0.01 * sps, min(0.01 * sps, second.b)))
    }
}

// MARK: - Empfänger (mehrere Zweige)

/// AIS-Empfänger: mehrere Demodulatoren mit verschiedenen Tiefpässen auf demselben Audio; gleiche Rahmen werden zusammengefasst
public final class AISReceiver {
    public struct Decoded: Sendable {
        public var bits: [UInt8]
        /// Audiozeit (Sekunden seit Start) der Auslieferung
        public var time: Double
        /// Gerettet durch Wiederholungsversuche
        public var rescued: Bool
    }

    public var onFrame: ((Decoded) -> Void)?
    public private(set) var stats = AISStats()
    public let sampleRate: Double
    /// Pegel des Eingangs (gefilterter Mittelwert des Betrags)
    public var level: Double { Double(branches.first?.level ?? 0) }

    private var branches: [AISDemodulator] = []
    private var time = 0.0
    private var recent: [(hash: Int, time: Double)] = []
    private var failedSinceFrame = 0
    private var pendingFailures: [Double] = []

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        // Entwicklungshilfe: AIS_LOWPASS="4800,6000" setzt die Tiefpässe der Zweige (Hz)
        var cutoffs = [4_800.0, 5_600.0, 6_400.0, 7_200.0]
        if let v = ProcessInfo.processInfo.environment["AIS_LOWPASS"] {
            let list = v.split(separator: ",").compactMap { Double($0) }
            if !list.isEmpty { cutoffs = list }
        }
        for hz in cutoffs {
            let d = AISDemodulator(sampleRate: sampleRate, config: .init(lowpassHz: hz))
            d.onFrame = { [unowned self] bits, rescued in self.accept(bits, rescued: rescued) }
            d.onFailure = { [unowned self] in self.pendingFailures.append(self.time) }
            branches.append(d)
        }
    }

    public func reset() {
        for b in branches { b.reset() }
        stats = AISStats()
        time = 0
        recent.removeAll()
        pendingFailures.removeAll()
        held.removeAll()
        cleanTimes.removeAll()
        known.removeAll()
        unconfirmed.removeAll()
    }

    public func resetStats() { stats = AISStats() }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        for b in branches { b.process(samples) }
        time += Double(samples.count) / sampleRate
        stats.bursts = max(stats.bursts, branches.map(\.bursts).max() ?? 0)
        releaseHeld()
        // Fehlschlag zählt erst, wenn innerhalb von 0,3 s kein Rahmen aus einem anderen Zweig kam
        while let f = pendingFailures.first, time - f > 0.3 {
            pendingFailures.removeFirst()
            stats.failed += 1
        }
    }

    /// Gerettete Rahmen warten kurz: kommt in der Zwischenzeit ein unveränderter Rahmen (derselbe Burst aus einem anderen Zweig), sind sie Zufall
    private var held: [(bits: [UInt8], time: Double)] = []
    private var cleanTimes: [Double] = []
    /// MMSI, die schon in einem unveränderten Rahmen vorkam (begrenzt)
    private var known: [UInt32: Double] = [:]
    /// Gerettete Rahmen unbekannter MMSI warten auf eine zweite Sichtung (Zufallstreffer wiederholen sich nie)
    private var unconfirmed: [UInt32: [(bits: [UInt8], time: Double)]] = [:]
    public static let confirmWindow = 900.0

    private func mmsi(of bits: [UInt8]) -> UInt32 { AISBits(bits).u(8, 30) }

    private func accept(_ bits: [UInt8], rescued: Bool) {
        // Zufallstreffer der Prüfsumme: Länge und Kennung müssen zum Nachrichtentyp passen
        guard AISMessage.isPlausible(AISBits(bits), strictMMSI: rescued) else { stats.implausible += 1; return }
        if rescued {
            held.append((bits, time))
            return
        }
        cleanTimes.append(time)
        let id = mmsi(of: bits)
        if known.count > 20_000 { known = known.filter { time - $0.value < Self.confirmWindow } }
        known[id] = time
        deliver(bits, rescued: false)
        // früher zurückgestellte gerettete Rahmen dieser MMSI sind bestätigt
        if let list = unconfirmed.removeValue(forKey: id) {
            for item in list where time - item.time < Self.confirmWindow { deliver(item.bits, rescued: true) }
        }
    }

    private func releaseHeld() {
        cleanTimes.removeAll { time - $0 > 1 }
        while let h = held.first, time - h.time >= 0.03 {
            held.removeFirst()
            // ein unveränderter Rahmen im selben Augenblick (±10 ms; der Zeitschlitz dauert 26,7 ms): dieser Burst ist schon gelesen
            if cleanTimes.contains(where: { abs($0 - h.time) < 0.01 }) { continue }
            let id = mmsi(of: h.bits)
            if let t = known[id], time - t < Self.confirmWindow {
                deliver(h.bits, rescued: true)
            } else {
                // unbekannte MMSI: erst bei zweiter Sichtung (gerettet oder unverändert) übernehmen
                var list = unconfirmed[id] ?? []
                list.removeAll { time - $0.time > Self.confirmWindow }
                list.append(h)
                if list.count >= 2 {
                    known[id] = time
                    unconfirmed[id] = nil
                    for item in list { deliver(item.bits, rescued: true) }
                } else {
                    unconfirmed[id] = list
                    if unconfirmed.count > 2_000 { unconfirmed = unconfirmed.filter { !($0.value.allSatisfy { time - $0.time > Self.confirmWindow }) } }
                }
            }
        }
    }

    private func deliver(_ bits: [UInt8], rescued: Bool) {
        var hasher = Hasher()
        hasher.combine(bits)
        let hash = hasher.finalize()
        // derselbe Burst aus mehreren Zweigen kommt im selben Augenblick; ein Burst belegt höchstens 5 Zeitschlitze (133 ms)
        recent.removeAll { time - $0.time > 0.25 }
        if recent.contains(where: { $0.hash == hash }) { return }
        recent.append((hash, time))
        stats.frames += 1
        if rescued { stats.rescued += 1 }
        stats.lastFrameTime = time
        // ein Rahmen aus einem Zweig macht gleichzeitige „Fehlschläge“ der anderen Zweige hinfällig
        pendingFailures.removeAll { abs(time - $0) < 0.3 }
        onFrame?(Decoded(bits: bits, time: time, rescued: rescued))
    }
}
