// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - Bit-Entscheider

/// Liest aus FM-Diskriminator-Audio (die FSK-Töne des RS41 als Spannung, 4800 Bd, ±2,4 kHz Hub) die Bitfolgen der Rahmen.
///
/// Ablauf: Gleichanteil abziehen (Frequenzablage der Sonde ergibt Versatz) → Mittelwert über eine Bitdauer (angepasstes Filter) →
/// Korrelation mit dem 64-Bit-Kopf (beide Polaritäten) → bei Treffer die Bits des ganzen Rahmens im Bittakt abtasten.
/// Wenn die Prüfung des Rahmens scheitert, werden leicht verschobene Abtastzeitpunkte und Taktabweichungen (Abtastuhr gegen Sonde) probiert.
final class RS41Demodulator {
    static let baud = 4800.0
    /// Kopf der Rahmen, wie gesendet (10 B6 CA 11 22 96 12 F8), Bit für Bit mit dem niederwertigen Bit zuerst
    static let headerBits: [Float] = {
        var out: [Float] = []
        for byte in [0x10, 0xB6, 0xCA, 0x11, 0x22, 0x96, 0x12, 0xF8] as [UInt8] {
            for i in 0..<8 { out.append((byte >> UInt8(i)) & 1 == 1 ? 1 : -1) }
        }
        return out
    }()
    /// Bytes, die nach dem Kopf ausgelesen werden: so viele wie der längste Rahmen
    static let frameBytes = RS41FrameParser.extendedLength
    private static let threshold: Float = 0.68

    let sps: Int
    /// Wird mit den rohen (noch verwürfelten) Rahmenbytes gerufen, bis ein Aufruf `true` liefert
    var attempt: (([UInt8]) -> Bool)?
    /// Vom Rahmen nicht angenommen, aber der Kopf wurde gefunden: bestes Bytefeld (für Teilauswertung)
    var rejected: (([UInt8], Float) -> Void)?

    private(set) var headers = 0
    /// Hilfen für Prüfstände: laufende Nummer des Kopfes und des Versuchs sowie die gewählte Lage
    private(set) var attemptIndex = 0
    private(set) var lastShift = 0.0
    private(set) var lastTrigger = 0
    private(set) var lastRatio: Float = 0
    private(set) var level: Float = 0           // Mittelwert des Betrags (Eingangspegel)

    private let dcAlpha: Float
    private var dc: Float = 0
    private var window: [Float]
    private var windowPos = 0
    private var windowSum: Float = 0
    private var mf: [Float] = []
    private var yv: [Float] = []                // Eingang nach Abzug des Gleichanteils (für die Nulldurchgänge)
    private var base = 0                        // absolute Nummer des ersten Werts in `mf`
    private var count = 0                       // absolute Zahl der verarbeiteten Abtastwerte
    /// Ein Treffer der Kopfsuche: Mitte des Plateaus, Güte (1 = alle Vorzeichen stimmen) und Polarität
    private struct Peak { var n: Int; var ratio: Float; var sign: Float }
    private var run: (first: Int, last: Int, plateauFirst: Int, plateauLast: Int, maxRatio: Float, sign: Float)?
    private var peaks: [Peak] = []
    private var windowEnd = 0
    /// Rahmen in Aufnahme: Treffer und Zeitpunkt, an dem alle Bits da sind. Mehrere zugleich, denn ein falscher Treffer in der
    /// Vorbereitungsfolge darf den echten Kopf danach nicht verpassen.
    private var captures: [(peaks: [Peak], end: Int)] = []
    private var lastGood = -1_000_000
    private var blockedUntil = 0
    /// Bitdauer der Sonde im Verhältnis zur Nenndauer (die Sondenuhr weicht um einige 100 ppm ab); aus dem letzten gelesenen Rahmen
    private var step_ = 1.0

    init(sampleRate: Double) {
        sps = max(2, Int((sampleRate / Self.baud).rounded()))
        dcAlpha = 1 / Float(sps * 24)
        window = [Float](repeating: 0, count: sps)
        mf.reserveCapacity(120_000)
        yv.reserveCapacity(120_000)
    }

    func reset() {
        dc = 0
        window = [Float](repeating: 0, count: sps)
        windowPos = 0
        windowSum = 0
        mf.removeAll(keepingCapacity: true)
        yv.removeAll(keepingCapacity: true)
        step_ = 1
        base = 0
        count = 0
        run = nil
        peaks.removeAll()
        windowEnd = 0
        captures.removeAll()
        lastGood = -1_000_000
        blockedUntil = 0
    }

    func process(_ samples: UnsafeBufferPointer<Float>) {
        for x in samples {
            dc += dcAlpha * (x - dc)
            let y = x - dc
            level += 0.0005 * (abs(y) - level)
            windowSum += y - window[windowPos]
            window[windowPos] = y
            windowPos += 1
            if windowPos == sps { windowPos = 0 }
            mf.append(windowSum / Float(sps))
            yv.append(y)
            count += 1
            step()
        }
        // Verlauf kürzen, aber mehr als zwei Rahmenlängen behalten (offene Aufnahmen brauchen bis zu 1,3 s Vorgeschichte)
        let keep = (Self.frameBytes * 8 + 800) * sps
        if mf.count > 4 * keep {
            mf.removeFirst(2 * keep)
            yv.removeFirst(2 * keep)
            base += 2 * keep
        }
    }

    // MARK: Suche und Aufnahme

    private func step() {
        if let cap = captures.first, count - 1 >= cap.end {
            captures.removeFirst()
            finish(cap.peaks)
        }
        guard count > blockedUntil else { return }
        let n = count - 1                                  // absoluter Index des jüngsten mf-Werts
        let i = n - base
        guard i >= 63 * sps else { return }
        var c: Float = 0, e: Float = 0
        for k in 0..<64 {
            let v = mf[i - (63 - k) * sps]
            c += Self.headerBits[k] * v
            e += abs(v)
        }
        let ratio = e > 1e-6 ? c / e : 0
        let magnitude = abs(ratio), sign: Float = ratio >= 0 ? 1 : -1
        if magnitude >= Self.threshold {
            if var r = run, r.sign == sign {
                // das Verhältnis ist 1, solange alle Vorzeichen stimmen: ein Plateau, dessen Mitte die beste Abtastlage ist
                if magnitude > r.maxRatio + 0.02 { r.maxRatio = magnitude; r.plateauFirst = n; r.plateauLast = n }
                else if magnitude >= r.maxRatio - 0.02 { r.plateauLast = n; r.maxRatio = max(r.maxRatio, magnitude) }
                r.last = n
                run = r
            } else {
                closeRun()
                run = (n, n, n, n, magnitude, sign)
                if peaks.isEmpty && windowEnd <= n { windowEnd = n + 100 * sps }
            }
        } else if let r = run, n - r.last >= 2 {
            closeRun()
        }
        // Sammelfenster (100 Bit) vorbei: die besten Treffer aufnehmen. Ein falscher Treffer in der Vorbereitungsfolge (0101…) darf den
        // echten Kopf nicht verdecken, der gleich danach mit besserem Verhältnis folgt.
        if !peaks.isEmpty || run != nil, n >= windowEnd, windowEnd > 0 {
            closeRun()
            let ranked = peaks.sorted { $0.ratio > $1.ratio }
            peaks.removeAll()
            windowEnd = 0
            guard let top = ranked.first else { return }
            headers += 1
            let last = ranked.map(\.n).max() ?? top.n
            captures.append((Array(ranked.prefix(3)), last + (Self.frameBytes * 8 - 64) * sps + 24))
        }
    }

    private func closeRun() {
        guard let r = run else { return }
        peaks.append(Peak(n: (r.plateauFirst + r.plateauLast) / 2, ratio: r.maxRatio, sign: r.sign))
        run = nil
    }

    /// Weichwerte (Mittelwert über das Bit) an den Bitenden t0 + j·step, linear zwischen den Abtastwerten
    private func soft(t0: Double, step: Double, count: Int) -> [Float]? {
        var out = [Float](repeating: 0, count: count)
        for j in 0..<count {
            let pos = t0 + Double(j) * step - Double(base)
            let i = Int(pos.rounded(.down))
            guard i >= 0 else { return nil }
            guard i + 1 < mf.count else { out[j] = 0; continue }       // hinter dem letzten Wert: Lücke nach dem Rahmen
            let f = Float(pos - Double(i))
            out[j] = mf[i] * (1 - f) + mf[i + 1] * f
        }
        return out
    }

    private func bytes(from soft: [Float], sign: Float, offset: Float) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Self.frameBytes)
        for byte in 0..<Self.frameBytes {
            var v: UInt8 = 0
            for bit in 0..<8 where (soft[byte * 8 + bit] - offset) * sign >= 0 { v |= 1 << UInt8(bit) }
            out[byte] = v
        }
        return out
    }

    /// Bitgrenzen (Nulldurchgänge der Eingangsspannung) gegen den angenommenen Takt: liefert Verschiebung `a` und Taktfehler `b` (Abtastwerte je Bit),
    /// aus der Ausgleichsgeraden der Abweichungen über die Bitnummer; Ausreißer (Rauschen nahe der Grenze) fallen in einem zweiten Durchgang heraus
    private func timingFit(soft: [Float], offset: Float, sign: Float, t0: Double, step: Double, bits: Int, window: Int) -> (a: Double, b: Double)? {
        var xs: [Double] = [], rs: [Double] = []
        var previous = (soft[0] - offset) * sign >= 0
        for j in 1..<bits {
            let cur = (soft[j] - offset) * sign >= 0
            defer { previous = cur }
            guard cur != previous else { continue }
            // Grenze zwischen Bit j-1 und j liegt bei e_j − sps + 0.5 (Zeit der Punktabtastwerte)
            let expected = t0 + Double(j) * step - Double(sps) + 0.5
            let k0 = Int(expected.rounded(.down)) - base
            var crossing: Double?
            for k in (k0 - window)...(k0 + window) where k >= 0 && k + 1 < yv.count {
                let a = yv[k] - offset, b = yv[k + 1] - offset
                if (a * sign < 0 && b * sign >= 0 && cur) || (a * sign >= 0 && b * sign < 0 && !cur) {
                    let c = Double(k + base) + Double(a / (a - b))
                    // bei Rauschen mehrere Durchgänge: der nächste zur Erwartung zählt
                    if crossing == nil || abs(c - expected) < abs(crossing! - expected) { crossing = c }
                }
            }
            guard let c = crossing else { continue }
            let r = c - expected
            guard abs(r) < Double(window) + 0.5 else { continue }
            xs.append(Double(j)); rs.append(r)
        }
        func fit(_ keep: [Int]) -> (a: Double, b: Double, sigma: Double)? {
            guard keep.count > 16 else { return nil }
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
        let limit = max(0.6, 2.0 * first.sigma)
        let kept = xs.indices.filter { abs(rs[$0] - first.a - first.b * xs[$0]) <= limit }
        let second = fit(kept) ?? first
        return (second.a, second.b)
    }

    private func finish(_ candidates: [Peak]) {
        var firstBytes: [UInt8]?
        for cap in candidates {
            // derselbe Rahmen wurde schon gelesen (zweiter Treffer im selben Rahmen)
            if abs(cap.n - lastGood) < 20_000 / 10 * sps { continue }
            lastTrigger = cap.n
            lastRatio = cap.ratio
            if let bytes = decode(cap) {
                if bytes.isEmpty { lastGood = cap.n; return }
                if firstBytes == nil { firstBytes = bytes }
            }
        }
        if let f = firstBytes { rejected?(f, lastRatio) }
    }

    /// Ein Treffer ausgewertet. Rückgabe: leeres Feld = angenommen, sonst die ersten gelesenen Bytes (für die Teilauswertung), nil = nicht lesbar.
    /// Stufen: (A) Takt aus den Nulldurchgängen, (B) Takt und Lage aus der größten Augenöffnung, (C) Entzerrer.
    private func decode(_ cap: Peak) -> [UInt8]? {
        let bitCount = Self.frameBytes * 8
        let t0c = Double(cap.n - 63 * sps)
        var first: [UInt8]?
        let ds5 = 5e-5 * Double(sps), ds10 = 1e-4 * Double(sps)
        let tries: [(Double, Double)] = [(0, 0), (-1, 0), (1, 0), (0, ds5), (0, -ds5), (-1, ds5), (1, -ds5), (0, ds10), (0, -ds10), (-2, 0), (2, 0)]
        /// Versuche um ein Zeitmodell herum; `true` bei Erfolg
        func run(_ t0: Double, _ step: Double, _ list: [(Double, Double)], index: Int) -> Bool {
            for (k, (shift, ds)) in list.enumerated() {
                attemptIndex = index + k
                guard let s = soft(t0: t0 + shift, step: step + ds, count: bitCount) else { continue }
                let b = bytes(from: s, sign: cap.sign, offset: frameOffset(s))
                if first == nil { first = b }
                if attempt?(b) == true { step_ = (step + ds) / Double(sps); return true }
            }
            return false
        }
        // (A) Nulldurchgänge, Stück für Stück über immer mehr Bits: die Abweichung am Anfang ist klein (Lage ±4 Abtastwerte),
        // der Taktfehler wird mit jedem Stück genauer und die Gerade wird weiter hinaus verlängert
        var t0 = t0c, step = Double(sps) * step_
        for (bits, window) in [(96, 4), (256, 3), (640, 3), (1600, 3), (2560, 3), (2560, 2)] {
            guard let s = soft(t0: t0, step: step, count: bitCount) else { return nil }
            guard let fit = timingFit(soft: s, offset: frameOffset(s), sign: cap.sign, t0: t0, step: step, bits: bits, window: window) else { continue }
            t0 += fit.a
            step += fit.b
        }
        // Die Nulldurchgänge eilen den idealen Bitgrenzen durch die Filter der Funkkette nach: die Abtastlage folgt der größten Augenöffnung
        if let eye = bestEye(t0: t0, step: step) { t0 += eye }
        if run(t0, step, tries, index: 0) { return [] }
        // (B) Bei Rauschen sind die Nulldurchgänge unzuverlässig: Takt (±600 ppm) und Lage (±5 Abtastwerte) nach der größten Augenöffnung über den ganzen Rahmen
        if let grid = eyeGrid(t0: t0c, step: Double(sps) * step_, offset: frameOffset(soft(t0: t0, step: step, count: 2560) ?? [])) {
            if run(grid.t0, grid.step, Array(tries.prefix(5)), index: 20) { return [] }
            t0 = grid.t0; step = grid.step
        }
        // (C) Funkkette verzerrt das Signal (De-Emphase, Kopplungs-Hochpass, Sprachband): Entzerrer aus Kopf und Vorbereitungsfolge anlernen
        if let equalized = equalize(cap: cap, t0: t0, step: step) {
            attemptIndex = 100
            for b in equalized where attempt?(b) == true {
                step_ = step / Double(sps)
                return []
            }
            if first == nil { first = equalized.first }
        }
        return first
    }

    /// Takt und Lage mit der größten Augenöffnung (mittlerer Betrag der Weichwerte über die ersten 2560 Bits), in einem Raster um die Nennwerte
    private func eyeGrid(t0: Double, step: Double, offset: Float) -> (t0: Double, step: Double)? {
        var best: (m: Float, t0: Double, step: Double)?
        var d = -0.006 * Double(sps) / 10
        while d <= 0.006 * Double(sps) / 10 + 1e-9 {
            let st = step + d
            var shift = -5.0
            while shift <= 5.0 {
                var m: Float = 0
                var ok = true
                for j in 0..<2560 {
                    let idx = Int((t0 + shift + Double(j) * st).rounded()) - base
                    guard idx >= 0, idx < mf.count else { ok = false; break }
                    m += abs(mf[idx] - offset)
                }
                if ok, m > (best?.m ?? -1) { best = (m, t0 + shift, st) }
                shift += 0.5
            }
            d += 0.00025 * Double(sps) / 10
        }
        return best.map { ($0.t0, $0.step) }
    }

    // MARK: Entzerrer

    /// Eingangswert zur Zeit t (Abtastwerte), linear zwischen den Punkten
    private func yAt(_ t: Double) -> Double {
        let pos = t - Double(base)
        let i = Int(pos.rounded(.down))
        guard i >= 0, i + 1 < yv.count else { return 0 }
        let f = pos - Double(i)
        return Double(yv[i]) * (1 - f) + Double(yv[i + 1]) * f
    }

    /// Entscheidungsrückgekoppelter Entzerrer, per Kleinste-Quadrate angelernt: erst an den bekannten Bits (Vorbereitungsfolge und Kopf), dann an den
    /// eigenen Entscheidungen über den ganzen Rahmen. Eingänge: Abtastwerte rund um das Bit (±1,5 Bitdauern), die letzten Entscheidungen, ein Festwert.
    /// Liefert die Bytefelder der Durchläufe (der Aufrufer prüft sie mit der Fehlerkorrektur).
    private func equalize(cap: Peak, t0: Double, step: Double) -> [[UInt8]]? {
        let ffSpan = Int(1.5 * Double(sps))                   // Abtastwerte beiderseits der Bitmitte
        let ffCount = 2 * ffSpan + 1
        let fbCount = 14
        let n = ffCount + fbCount + 1
        let known = 64 + 64                                   // 64 Bits Vorbereitungsfolge davor, 64 Bits Kopf
        let frameBits = 2560
        let sign = Double(cap.sign)
        let centerOf = { (j: Int) -> Double in t0 + Double(j) * step - Double(self.sps) / 2 + 0.5 }
        // Bits der Vorbereitungsfolge: wechseln, das letzte vor dem Kopf ist eine 1
        func trainBit(_ j: Int) -> Double {
            if j >= 0 { return Double(Self.headerBits[j]) }
            return (-j) % 2 == 1 ? 1 : -1
        }
        // Merkmalsvektor des Bits j mit den Rückkopplungsbits aus `past`
        func features(_ j: Int, _ past: (Int) -> Double) -> [Double] {
            var f = [Double](repeating: 0, count: n)
            let c = centerOf(j)
            for k in 0..<ffCount { f[k] = sign * yAt(c + Double(k - ffSpan)) }
            for k in 0..<fbCount { f[ffCount + k] = past(j - 1 - k) }
            f[n - 1] = 1
            return f
        }
        func solve(_ rows: [[Double]], _ target: [Double]) -> [Double]? {
            var a = [Double](repeating: 0, count: n * n), b = [Double](repeating: 0, count: n)
            for (r, f) in rows.enumerated() {
                for i in 0..<n {
                    b[i] += f[i] * target[r]
                    let fi = f[i]
                    if fi == 0 { continue }
                    for k in 0...i { a[i * n + k] += fi * f[k] }
                }
            }
            let ridge = 1e-3 * (a.enumerated().filter { $0.offset % (n + 1) == 0 }.map(\.element).reduce(0, +) / Double(n))
            for i in 0..<n {
                for k in 0..<i { a[k * n + i] = a[i * n + k] }
                a[i * n + i] += ridge
            }
            // Cholesky
            var l = [Double](repeating: 0, count: n * n)
            for i in 0..<n {
                for k in 0...i {
                    var sum = a[i * n + k]
                    for m in 0..<k { sum -= l[i * n + m] * l[k * n + m] }
                    if i == k { guard sum > 1e-12 else { return nil }; l[i * n + i] = sum.squareRoot() } else { l[i * n + k] = sum / l[k * n + k] }
                }
            }
            var z = [Double](repeating: 0, count: n)
            for i in 0..<n { var sum = b[i]; for k in 0..<i { sum -= l[i * n + k] * z[k] }; z[i] = sum / l[i * n + i] }
            var w = [Double](repeating: 0, count: n)
            for i in stride(from: n - 1, through: 0, by: -1) { var sum = z[i]; for k in (i + 1)..<n { sum -= l[k * n + i] * w[k] }; w[i] = sum / l[i * n + i] }
            return w
        }
        // 1. Anlernen an den bekannten Bits
        var rows: [[Double]] = [], target: [Double] = []
        for j in (-64)..<64 {
            rows.append(features(j) { trainBit($0) })
            target.append(trainBit(j))
        }
        _ = known
        guard var w = solve(rows, target) else { return nil }
        var results: [[UInt8]] = []
        var decisions = [Double](repeating: 0, count: frameBits)
        for _ in 0..<3 {
            // 2. Entscheiden (Kopf ist bekannt)
            for j in 0..<frameBits {
                if j < 64 { decisions[j] = Double(Self.headerBits[j]); continue }
                let f = features(j) { k in k >= 0 ? decisions[k] : trainBit(k) }
                var o = 0.0
                for i in 0..<n { o += w[i] * f[i] }
                decisions[j] = o >= 0 ? 1 : -1
            }
            var out = [UInt8](repeating: 0, count: Self.frameBytes)
            for byte in 0..<(frameBits / 8) {
                var v: UInt8 = 0
                for bit in 0..<8 where decisions[byte * 8 + bit] > 0 { v |= 1 << UInt8(bit) }
                out[byte] = v
            }
            results.append(out)
            if results.count >= 3 { break }
            // 3. Nachlernen an den eigenen Entscheidungen
            var r2 = rows, t2 = target
            for j in 64..<frameBits {
                r2.append(features(j) { k in k >= 0 ? decisions[k] : trainBit(k) })
                t2.append(decisions[j])
            }
            guard let w2 = solve(r2, t2) else { break }
            w = w2
        }
        return results
    }

    /// Verschiebung (in Abtastwerten, ±4) mit der größten Augenöffnung: mittlerer Betrag der Weichwerte der ersten 2560 Bits
    private func bestEye(t0: Double, step: Double) -> Double? {
        var bestShift = 0.0, bestMetric: Float = -1
        var shift = -4.0
        while shift <= 4.0 {
            guard let s = soft(t0: t0 + shift, step: step, count: 2560) else { return nil }
            let off = frameOffset(s)
            var m: Float = 0
            for v in s { m += abs(v - off) }
            if m > bestMetric { bestMetric = m; bestShift = shift }
            shift += 0.5
        }
        return bestShift
    }

    /// Gleichanteil des Rahmens: Mitte zwischen den Mittelwerten der positiven und der negativen Weichwerte der ersten 2560 Bits
    private func frameOffset(_ s: [Float]) -> Float {
        var p: Float = 0, m: Float = 0
        var np = 0, nm = 0
        for v in s.prefix(2560) {
            if v >= 0 { p += v; np += 1 } else { m += v; nm += 1 }
        }
        guard np > 20, nm > 20 else { return 0 }
        let mean = (p / Float(np) + m / Float(nm)) / 2
        return mean
    }
}

// MARK: - Empfänger

/// Zähler für die Anzeige und die Diagnose
public struct RS41Stats: Equatable, Sendable {
    /// Kopf (Synchronwort) gefunden
    public var headers = 0
    /// Rahmen mit bestandener Fehlerkorrektur
    public var frames = 0
    /// Nur Teile mit gültiger Prüfsumme lesbar (Fehlerkorrektur scheiterte)
    public var partial = 0
    /// Kopf gefunden, aber nichts Lesbares
    public var failed = 0
    /// Von der Fehlerkorrektur behobene Bytes (Summe)
    public var corrected = 0
    /// Zeitpunkt (Audiozeit in s) des letzten Rahmens
    public var lastFrameTime: Double?
}

/// Sondenempfänger für 4800-Bd-RS41-Rahmen aus FM-Audio
public final class RS41Receiver {
    public var onTelemetry: ((RS41Telemetry) -> Void)?
    public private(set) var stats = RS41Stats()
    /// Eingangspegel (Mittelwert des Betrags nach Abzug des Gleichanteils)
    public var level: Double { Double(demod.level) }
    public let sampleRate: Double

    private let demod: RS41Demodulator
    private var calibration = RS41Calibration()
    private var lastSerial: String?
    private var time = 0.0
    /// Treffer guter Güte ohne Rahmen: erst als verloren gezählt, wenn innerhalb von 1,3 s kein Rahmen folgt (die Vorbereitungsfolge ähnelt dem Kopf)
    private var pendingFailures: [Double] = []

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        demod = RS41Demodulator(sampleRate: sampleRate)
        demod.attempt = { [unowned self] raw in self.accept(raw) }
        demod.rejected = { [unowned self] raw, quality in self.salvage(raw, quality: quality) }
    }

    public func reset() {
        demod.reset()
        calibration = RS41Calibration()
        lastSerial = nil
        stats = RS41Stats()
        pendingFailures.removeAll()
        time = 0
    }

    public func resetStats() { stats = RS41Stats() }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        demod.process(samples)
        time += Double(samples.count) / sampleRate
        while let f = pendingFailures.first, time - f > 1.3 { stats.failed += 1; pendingFailures.removeFirst() }
        stats.headers = max(stats.headers, demod.headers)
    }

    // MARK: Rahmen prüfen

    /// Entwürfelte Bytes eines Rahmens (die Länge 320 oder 518) per Reed-Solomon prüfen und korrigieren
    static func correct(_ f: inout [UInt8], length: Int) -> Int? {
        let msgLen = (length - RS41FrameParser.typeByte) / 2
        var cw1 = [UInt8](repeating: 0, count: 24 + msgLen), cw2 = cw1
        for i in 0..<24 {
            cw1[i] = f[8 + i]
            cw2[i] = f[32 + i]
        }
        for i in 0..<msgLen {
            cw1[24 + i] = f[56 + 2 * i]
            cw2[24 + i] = f[57 + 2 * i]
        }
        guard let e1 = RS41ReedSolomon.decode(&cw1), let e2 = RS41ReedSolomon.decode(&cw2) else { return nil }
        for i in 0..<24 {
            f[8 + i] = cw1[i]
            f[32 + i] = cw2[i]
        }
        for i in 0..<msgLen {
            f[56 + 2 * i] = cw1[24 + i]
            f[57 + 2 * i] = cw2[24 + i]
        }
        return e1 + e2
    }

    private func descramble(_ raw: [UInt8]) -> [UInt8] {
        var f = raw
        for i in 0..<f.count { f[i] ^= RS41FrameParser.mask[i % RS41FrameParser.mask.count] }
        return f
    }

    private func headerErrors(_ f: [UInt8]) -> Int {
        var e = 0
        for i in 0..<8 { e += (f[i] ^ RS41FrameParser.headerBytes[i]).nonzeroBitCount }
        return e
    }

    private func accept(_ raw: [UInt8]) -> Bool {
        var f = descramble(raw)
        guard headerErrors(f) <= 10 else { return false }
        for length in [RS41FrameParser.standardLength, RS41FrameParser.extendedLength] {
            var g = f
            guard let fixed = Self.correct(&g, length: length) else { continue }
            let expected: UInt8 = length == RS41FrameParser.standardLength ? 0x0F : 0xF0
            guard g[RS41FrameParser.typeByte] == expected else { continue }
            f = g
            guard var t = RS41FrameParser.parse(Array(f.prefix(length)), calibration: &calibration, previousSerial: lastSerial) else { return false }
            t.correctedBytes = fixed
            lastSerial = t.serial
            stats.frames += 1
            stats.corrected += fixed
            pendingFailures.removeAll { time - $0 < 1.3 }
            stats.lastFrameTime = time
            onTelemetry?(t)
            return true
        }
        return false
    }

    /// Fehlerkorrektur gescheitert: Blöcke mit gültiger Prüfsumme trotzdem auswerten
    private func salvage(_ raw: [UInt8], quality: Float) {
        var f = descramble(raw)
        // Die Vorbereitungsfolge (0101…) ähnelt dem Kopf: Treffer mit schlechtem Verhältnis zählen nicht als verlorener Rahmen
        let counts = quality >= 0.85
        guard headerErrors(f) <= 10 else { if counts { pendingFailures.append(time) }; return }
        // jede Hälfte, die sich korrigieren lässt, übernehmen
        var g = f
        _ = Self.correct(&g, length: RS41FrameParser.standardLength)
        if g[RS41FrameParser.typeByte] == 0x0F { f = g }
        guard f[RS41FrameParser.typeByte] == 0x0F || f[RS41FrameParser.typeByte] == 0xF0 else { if counts { pendingFailures.append(time) }; return }
        let length = f[RS41FrameParser.typeByte] == 0x0F ? RS41FrameParser.standardLength : RS41FrameParser.extendedLength
        if var t = RS41FrameParser.parse(Array(f.prefix(length)), calibration: &calibration, previousSerial: lastSerial), t.hasPosition || t.frame > 0 {
            t.correctedBytes = -1
            lastSerial = t.serial
            stats.partial += 1
            stats.lastFrameTime = time
            onTelemetry?(t)
        } else if counts {
            pendingFailures.append(time)
        }
    }
}
