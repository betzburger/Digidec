import Foundation

// MARK: - Entzerrer für verbogenes Funkruf-Audio

/// Rettet POCSAG-Aufnahmen, deren Audio so verbogen ist, dass der einfache Bit-Entscheider (`PagerBitSlicer`) kein Synchronwort findet.
///
/// Anlass: Eine echte DAPNET-Aufnahme (PCR-1500, 15/50 kHz) hatte einen Audioweg wie ein Bandpass: steiler Hochpass bei etwa 290 Hz,
/// flach bis 1 kHz, darüber fallend. Das Signal selbst war sauber (voll gesättigter Träger), aber lange gleiche Bitfolgen sanken in
/// wenigen Millisekunden auf null, die Pulse überschwangen. Der Entscheider las nur etwa jedes dritte Wort richtig.
///
/// Verfahren (arbeitet auf einem Abschnitt Audio ab dem Vorspann, nicht im Strom):
/// 1. Phasenfreie Vorfilter (Hochpass, Tiefpass, Höhenanhebung) geben ein grobes Bild der Bits.
/// 2. Eine langsame Taktschleife auf den Nulldurchgängen liefert die Bitmitten (schnell im Vorspann, danach ruhig).
/// 3. Ein linearer Entzerrer (13 Bitlängen × 4 Abtastwerte = 52 Koeffizienten) wird auf dem Vorspann und dem ersten Stück Daten
///    nach kleinsten Quadraten angelernt, dann entscheidet er alle Bits neu.
/// 4. Stapel mit gültigen Codewörtern (BCH ohne Korrektur) sind sichere Bits: der Entzerrer lernt danach nur noch auf diesen
///    Bits (Rauschen vor und nach der Aussendung verfälscht ihn nicht) und entscheidet erneut, bis nichts mehr dazukommt.
/// 5. Mehrere Startwerte der Vorfilter; gewählt wird, was die meisten gültigen Stapel liefert.
enum POCSAGEqualizer {
    /// Ergebnis eines Entzerrungsversuchs
    struct Outcome {
        /// Bits in der Polarität des Audios (der Rahmenleser erkennt beide)
        var bits: [UInt8]
        /// Bitmitte jedes Bits als Abtastindex im Abschnitt
        var times: [Double]
        /// Stapel mit mindestens 12 gültigen Codewörtern von 16
        var goodBatches = 0
        /// Meiste gültige Codewörter in einem Stapel
        var bestWords = 0
        /// Abtastindex hinter dem letzten sicher gelesenen Stapel (0 = keiner)
        var lastGoodEnd = 0
    }

    /// Koeffizienten: 2·span+1 Bitlängen, je `perBit` Abtastwerte
    static let span = 6
    static let perBit = 4
    static let taps = (2 * span + 1) * perBit

    /// Vorfilter-Startwerte: Anhebung (Faktor), Eckfrequenz der Anhebung, Hochpass (Hz bei 1200 Bd)
    static let starts: [(boost: Double, corner: Double, highpass: Double)] = [(3, 400, 100), (6, 400, 100), (4, 600, 200)]
    /// Länge des Datenstücks nach dem Vorspann (Bits), auf dem der erste Lernschritt läuft
    static let prefixes = [1100, 2200, 600]
    static let preambleBits = 576

    // MARK: Filter

    struct Biquad {
        var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

        static func highpass(_ fc: Double, _ sr: Double) -> Biquad {
            let w = 2 * Double.pi * fc / sr
            let al = sin(w) / (2 * 0.70710678), c = cos(w)
            let a0 = 1 + al
            return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - al) / a0)
        }

        static func lowpass(_ fc: Double, _ sr: Double) -> Biquad {
            let w = 2 * Double.pi * fc / sr
            let al = sin(w) / (2 * 0.70710678), c = cos(w)
            let a0 = 1 + al
            return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0, a1: -2 * c / a0, a2: (1 - al) / a0)
        }

        /// (1 + s/ωz) / (1 + s/ωp): Anhebung zwischen `fz` und `fp`
        static func shelf(zero fz: Double, pole fp: Double, _ sr: Double) -> Biquad {
            let kz = tan(Double.pi * fz / sr), kp = tan(Double.pi * fp / sr)
            let nb0 = (kz + 1) / kz, nb1 = (kz - 1) / kz
            let na0 = (kp + 1) / kp, na1 = (kp - 1) / kp
            return Biquad(b0: nb0 / na0, b1: nb1 / na0, b2: 0, a1: na1 / na0, a2: 0)
        }

        func run(_ x: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<x.count {
                let v = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x[i]; y2 = y1; y1 = v
                y[i] = v
            }
            return y
        }

        /// Vorwärts und rückwärts: keine Phasendrehung, Betrag quadriert
        func zeroPhase(_ x: [Double]) -> [Double] {
            var y = run(x)
            y.reverse()
            y = run(y)
            y.reverse()
            return y
        }
    }

    /// Vorfilter für die grobe Bitentscheidung; alle Frequenzen skaliert mit `scale` = Baudrate / 1200
    static func prefilter(_ x: [Double], sampleRate: Double, scale: Double, boost: Double, corner: Double, highpass: Double) -> [Double] {
        let nyq = 0.45 * sampleRate
        var y = Biquad.highpass(highpass * scale, sampleRate).zeroPhase(x)
        y = Biquad.lowpass(min(2400 * scale, nyq), sampleRate).zeroPhase(y)
        y = Biquad.shelf(zero: corner * scale, pole: min(corner * scale * boost, nyq), sampleRate).zeroPhase(y)
        return y
    }

    // MARK: Takt

    /// Vorspann: so viele Abstände in Folge von etwa einer Bitlänge zwischen den Nulldurchgängen
    static let preambleRun = 24

    static func lowerBound(_ a: [Double], _ v: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < v { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Bitmitten aus den Nulldurchgängen: Der Takt läuft frei mit der Sollbitlänge, jede Kreuzung nahe der erwarteten Flanke zieht ihn nach.
    /// Der Vorspann (`preambleRun` Abstände von etwa einer Bitlänge in Folge) fasst den Takt neu und zieht 160 Bits schnell nach; danach
    /// ruhig, weil Pulsform und Datenmuster die Kreuzungen verschieben. So findet der Takt jede Aussendung selbst, mit beliebiger Taktlage,
    /// auch wenn der Abschnitt viel früher beginnt. `origin` = erster Abtastindex, ab dem gesucht wird.
    static func bitCentres(_ pf: [Double], spb: Double, origin: Double) -> [Double] {
        guard pf.count > 2 else { return [] }
        var zc: [Double] = []
        for i in 1..<pf.count where (pf[i] > 0) != (pf[i - 1] > 0) {
            let t = Double(i - 1) + pf[i - 1] / (pf[i - 1] - pf[i])
            if t >= origin { zc.append(t) }
        }
        guard zc.count > preambleRun else { return [] }
        var snaps: [Double] = []
        var run = 0
        for i in 0..<(zc.count - 1) {
            let d = zc[i + 1] - zc[i]
            if d > 0.75 * spb && d < 1.25 * spb { run += 1 } else { run = 0 }
            if run == preambleRun { snaps.append(zc[i + 1]) }
        }
        guard var cur = snaps.first else { return [] }
        var out: [Double] = []
        var count = 0
        var next = 1
        let end = Double(pf.count) - 2
        while cur + spb < end {
            if next < snaps.count && cur >= snaps[next] - 0.5 * spb {
                while next < snaps.count && cur >= snaps[next] - 0.5 * spb { next += 1 }
                let snapIndex = lowerBound(zc, snaps[next - 1] - 0.5 * spb)
                if snapIndex < zc.count { cur = zc[snapIndex]; count = 0 }
            }
            let gain = count < 160 ? 0.15 : 0.01
            let k = lowerBound(zc, cur - 0.35 * spb)
            if k < zc.count && abs(zc[k] - cur) < 0.35 * spb { cur += gain * (zc[k] - cur) }
            out.append(cur + 0.5 * spb)
            cur += spb
            count += 1
        }
        return out
    }

    // MARK: Lineare Algebra

    static func interpolate(_ a: [Double], _ pos: Double) -> Double {
        if pos <= 0 { return a[0] }
        let last = Double(a.count - 1)
        if pos >= last { return a[a.count - 1] }
        let i = Int(pos)
        let f = pos - Double(i)
        return a[i] * (1 - f) + a[i + 1] * f
    }

    /// Merkmalsmatrix (Zeilen = Bits, Spalten = Koeffizienten) aus dem unveränderten Audio um jede Bitmitte
    static func features(_ raw: [Double], centres: [Double], spb: Double) -> [Double] {
        var x = [Double](repeating: 0, count: centres.count * taps)
        for (row, t) in centres.enumerated() {
            var col = row * taps
            for k in -span...span {
                for f in 0..<perBit {
                    x[col] = interpolate(raw, t + (Double(k) + Double(f) / Double(perBit) - 0.5) * spb)
                    col += 1
                }
            }
        }
        return x
    }

    /// Kleinste Quadrate über die gewählten Zeilen (Sollwert ±1), leicht geglättet. nil bei zu wenigen Zeilen oder Singularität.
    static func solve(_ x: [Double], rows: [Int], bits: [UInt8]) -> [Double]? {
        guard rows.count >= taps else { return nil }
        var a = [Double](repeating: 0, count: taps * taps)
        var b = [Double](repeating: 0, count: taps)
        for r in rows {
            let base = r * taps
            let y: Double = bits[r] == 1 ? 1 : -1
            for i in 0..<taps {
                let xi = x[base + i]
                b[i] += xi * y
                for j in i..<taps { a[i * taps + j] += xi * x[base + j] }
            }
        }
        var trace = 0.0
        for i in 0..<taps { trace += a[i * taps + i] }
        let ridge = 1e-3 * trace / Double(taps)
        for i in 0..<taps {
            a[i * taps + i] += ridge
            for j in 0..<i { a[i * taps + j] = a[j * taps + i] }
        }
        // Cholesky: a = L·Lᵀ (untere Hälfte)
        for i in 0..<taps {
            for j in 0...i {
                var sum = a[i * taps + j]
                for k in 0..<j { sum -= a[i * taps + k] * a[j * taps + k] }
                if i == j {
                    guard sum > 1e-300 else { return nil }
                    a[i * taps + i] = sum.squareRoot()
                } else {
                    a[i * taps + j] = sum / a[j * taps + j]
                }
            }
        }
        var z = b
        for i in 0..<taps {
            var sum = z[i]
            for k in 0..<i { sum -= a[i * taps + k] * z[k] }
            z[i] = sum / a[i * taps + i]
        }
        for i in stride(from: taps - 1, through: 0, by: -1) {
            var sum = z[i]
            for k in (i + 1)..<taps { sum -= a[k * taps + i] * z[k] }
            z[i] = sum / a[i * taps + i]
        }
        return z
    }

    static func decide(_ x: [Double], weights w: [Double], count n: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        for r in 0..<n {
            var sum = 0.0
            let base = r * taps
            for i in 0..<taps { sum += x[base + i] * w[i] }
            out[r] = sum > 0 ? 1 : 0
        }
        return out
    }

    // MARK: Prüfung an den Codewörtern

    /// Gültig ohne Korrektur: Rest null und passende gerade Parität
    static func isValid(_ word: UInt32) -> Bool {
        let w31 = word >> 1
        return PagerBCH.remainder(w31) == 0 && UInt32(w31.nonzeroBitCount & 1) == (word & 1)
    }

    struct Analysis {
        var goodBatches = 0
        var bestWords = 0
        /// Bit hinter dem letzten Stapel mit mindestens `minValid` gültigen Wörtern
        var lastEnd = 0
        /// Bits des Synchronworts und der gültigen Wörter solcher Stapel
        var mask: [Bool]
        var maskCount = 0
    }

    /// Sucht Synchronwörter (bis zwei Fehler, beide Polaritäten) und zählt je Stapel die gültigen Codewörter
    static func analyze(_ bits: [UInt8], minValid: Int) -> Analysis {
        var an = Analysis(mask: [Bool](repeating: false, count: bits.count))
        let n = bits.count
        guard n >= 32 + 512 else { return an }
        for inverted in [false, true] {
            let flip: UInt8 = inverted ? 1 : 0
            var reg: UInt32 = 0
            for i in 0..<n {
                reg = (reg << 1) | UInt32(bits[i] ^ flip)
                guard i >= 31, (reg ^ POCSAG.sync).nonzeroBitCount <= 2 else { continue }
                let st = i - 31
                guard st + 32 + 512 <= n else { continue }
                var ok = [Bool](repeating: false, count: 16)
                var count = 0
                for k in 0..<16 {
                    var word: UInt32 = 0
                    let a = st + 32 + 32 * k
                    for m in 0..<32 { word = (word << 1) | UInt32(bits[a + m] ^ flip) }
                    if isValid(word) { ok[k] = true; count += 1 }
                }
                an.bestWords = max(an.bestWords, count)
                if count >= 12 { an.goodBatches += 1 }
                if count >= minValid {
                    for m in st..<(st + 32) { an.mask[m] = true }
                    for k in 0..<16 where ok[k] {
                        let a = st + 32 + 32 * k
                        for m in a..<(a + 32) { an.mask[m] = true }
                    }
                    an.lastEnd = max(an.lastEnd, st + 544)
                }
            }
        }
        an.maskCount = an.mask.reduce(0) { $0 + ($1 ? 1 : 0) }
        return an
    }

    // MARK: Hauptverfahren

    /// Entzerrt einen Abschnitt Audio mit mindestens einem Vorspann (der Takt findet ihn selbst; `origin` = erster Abtastindex).
    /// Liefert den Versuch mit den meisten gültigen Stapeln; nil, wenn kein Takt gefunden wurde.
    static func equalize(_ samples: [Float], sampleRate: Double, baud: Double, origin: Double = 0) -> Outcome? {
        guard samples.count > Int(sampleRate * 0.5) else { return nil }
        let spb = sampleRate / baud
        let scale = baud / 1200
        let raw = samples.map { Double($0) }
        var best: Outcome?
        for s in starts {
            let pf = prefilter(raw, sampleRate: sampleRate, scale: scale, boost: s.boost, corner: s.corner, highpass: s.highpass)
            let centres = bitCentres(pf, spb: spb, origin: origin)
            guard centres.count >= 200 else { continue }
            let n = centres.count
            var rough = [UInt8](repeating: 0, count: n)
            for i in 0..<n { rough[i] = interpolate(pf, centres[i]) > 0 ? 1 : 0 }
            let x = features(raw, centres: centres, spb: spb)
            for p in prefixes {
                let prefixRows = Array(0..<min(n, preambleBits + p))
                guard let w0 = solve(x, rows: prefixRows, bits: rough) else { continue }
                var cur = decide(x, weights: w0, count: n)
                for _ in 0..<4 {
                    let an = analyze(cur, minValid: 5)
                    if an.maskCount < 150 { break }
                    var rows: [Int] = []
                    rows.reserveCapacity(an.maskCount)
                    for r in 0..<n where an.mask[r] { rows.append(r) }
                    guard let w = solve(x, rows: rows, bits: cur) else { break }
                    cur = decide(x, weights: w, count: n)
                }
                let an = analyze(cur, minValid: 5)
                var r = Outcome(bits: cur, times: centres)
                r.goodBatches = an.goodBatches
                r.bestWords = an.bestWords
                r.lastGoodEnd = an.lastEnd > 0 ? Int(centres[min(an.lastEnd, n - 1)]) : 0
                if let b = best {
                    if (r.goodBatches, r.bestWords) > (b.goodBatches, b.bestWords) { best = r }
                } else {
                    best = r
                }
                if r.goodBatches >= 2 { return best }
            }
        }
        return best
    }
}

// MARK: - Abschnittsverwaltung im Empfänger

/// Begleitet eine Baudrate: sammelt Audio ab dem Vorspann und liest es mit dem Entzerrer, falls der einfache Zweig nicht alles liest.
/// Der Abschnitt wird alle zwei Sekunden neu ausgewertet, die Meldungen aber erst beim Schließen ausgegeben (3 s nach dem letzten guten
/// Stapel, am Ende der Aufnahme oder nach 20 s): sonst erschienen angefangene Meldungen, und die vollständige käme nie mehr nach.
/// Was der einfache Zweig im Abschnitt schon ausgegeben hat (gleiche Rufnummer, Funktion und Text), kommt nicht noch einmal.
final class POCSAGRescue {
    let rate: Int
    let sampleRate: Double
    private let baud: Double
    private let preRoll: Int
    private let maxLength: Int
    private var tail: [Float] = []
    private var seg: [Float] = []
    private var active = false
    private var segStart = Date()
    private var nextPass = 0
    private var lastGood = 0
    private var lastPreambles = 0
    /// Meldungen der letzten Auswertung, noch nicht ausgegeben
    private var pending: [PagerMessage] = []
    /// Schon ausgegebene Meldungen dieses Abschnitts (Rufnummer, Funktion, Klartext, Ziffern)
    private var keys: Set<String> = []
    /// Vom Entzerrer gelesene Meldungen (für die Diagnose)
    private(set) var count = 0

    init(rate: Int, sampleRate: Double) {
        self.rate = rate
        self.sampleRate = sampleRate
        baud = Double(rate)
        preRoll = Int(sampleRate)
        maxLength = Int(20 * sampleRate)
    }

    func reset() {
        tail.removeAll()
        seg.removeAll()
        pending.removeAll()
        keys.removeAll()
        active = false
        lastPreambles = 0
        count = 0
    }

    /// Zähler der Diagnose auf null (die Zähler des Rahmenlesers werden gleichzeitig gelöscht)
    func resetCounters() {
        lastPreambles = 0
        count = 0
    }

    private static func key(_ m: PagerMessage) -> String {
        "\(m.address)|\(m.function)|\(m.alpha)|\(m.numeric)"
    }

    /// Meldung des einfachen Zweigs: der Entzerrer gibt dieselbe Meldung nicht noch einmal aus
    func noteEmitted(_ m: PagerMessage) {
        if active { keys.insert(Self.key(m)) }
    }

    /// Einen Block Audio aufnehmen; `stats` sind die Zähler des Rahmenlesers dieser Baudrate
    func feed(_ block: UnsafeBufferPointer<Float>, stats: POCSAGStats, now: Date, emit: (PagerMessage) -> Void) {
        if active {
            seg.append(contentsOf: block)
        } else {
            tail.append(contentsOf: block)
            // Vorlauf: mindestens eine Sekunde und der ganze letzte Block (große Blöcke melden den Vorspann spät)
            let keep = max(preRoll, block.count + preRoll / 5)
            if tail.count > keep { tail.removeFirst(tail.count - keep) }
            if stats.preambles > lastPreambles {
                active = true
                seg = tail
                segStart = now.addingTimeInterval(-Double(seg.count) / sampleRate)
                nextPass = seg.count + Int(2.5 * sampleRate)
                lastGood = 0
                pending.removeAll()
                keys.removeAll()
            }
        }
        lastPreambles = stats.preambles
        guard active, seg.count >= nextPass else { return }
        pass(emit: emit)
    }

    /// Ende der Aufnahme: letzten Abschnitt auswerten und ausgeben
    func flush(emit: (PagerMessage) -> Void) {
        guard active else { return }
        if seg.count > Int(sampleRate) { evaluate() }
        release(dropLast: false, emit: emit)
        finish()
    }

    private func finish() {
        tail = Array(seg.suffix(preRoll))
        seg.removeAll()
        pending.removeAll()
        active = false
    }

    /// Ausgewertete Meldungen ausgeben. `dropLast`: der Abschnitt wurde mitten in einer Aussendung abgeschnitten, die letzte Meldung
    /// ist dann unvollständig (der einfache Zweig liest sie weiter).
    private func release(dropLast: Bool, emit: (PagerMessage) -> Void) {
        var list = pending
        pending.removeAll()
        if dropLast && !list.isEmpty { list.removeLast() }
        for var m in list {
            let k = Self.key(m)
            if keys.contains(k) { continue }
            keys.insert(k)
            m.detail = "entzerrt"
            count += 1
            emit(m)
        }
    }

    /// Abschnitt entzerren und die Meldungen vormerken
    private func evaluate() {
        pending.removeAll()
        guard let r = POCSAGEqualizer.equalize(seg, sampleRate: sampleRate, baud: baud) else { return }
        var framer = POCSAGFramer(rate: rate)
        for i in 0..<r.bits.count {
            let when = segStart.addingTimeInterval(r.times[i] / sampleRate)
            framer.push(Int(r.bits[i]), now: when) { pending.append($0) }
        }
        pending.append(contentsOf: framer.flushMessage())
        lastGood = max(lastGood, r.lastGoodEnd)
    }

    private func pass(emit: (PagerMessage) -> Void) {
        evaluate()
        let length = seg.count
        let quietFor = Double(length - lastGood) / sampleRate
        let waited = Double(length) / sampleRate
        let capped = length > maxLength
        if (lastGood > 0 && quietFor > 3) || (lastGood == 0 && waited > 7) || capped {
            release(dropLast: capped, emit: emit)
            finish()
        } else {
            nextPass = length + Int(2 * sampleRate)
        }
    }
}
