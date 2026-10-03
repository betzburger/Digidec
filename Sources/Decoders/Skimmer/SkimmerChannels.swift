import Foundation

// MARK: - Gemeinsame Bausteine eines Kanals

/// Zweipoliger Tiefpass (Biquad, Butterworth), Zustände in Double: bei Grenzfrequenzen von 50 Hz auf 8 kHz Abtastrate nötig
struct SkimBiquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1 = 0.0, z2 = 0.0

    init() {}

    init(lowpass fc: Double, sampleRate: Double, q: Double = 0.70710678) {
        let w = 2 * Double.pi * fc / sampleRate, c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al
        b0 = (1 - c) / 2 / a0
        b1 = (1 - c) / a0
        b2 = (1 - c) / 2 / a0
        a1 = -2 * c / a0
        a2 = (1 - al) / a0
    }

    @inline(__always)
    mutating func step(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Mischer und Tiefpass: Audio (8 kHz) → komplexes Basisband um die Kanalfrequenz, 500 Abtastwerte je Sekunde.
/// Tiefpass vierter Ordnung (zwei Biquads, Butterworth) auf I und Q, danach Dezimierung durch 16.
struct SkimDownconverter {
    static let sampleRate = 8000.0
    static let decimation = 16
    static let outputRate = sampleRate / Double(decimation)

    private(set) var frequencyHz: Double
    private(set) var cutoffHz: Double
    private var phase = 0.0
    private var omega: Double
    private var i1 = SkimBiquad(), i2 = SkimBiquad(), q1 = SkimBiquad(), q2 = SkimBiquad()
    private var count = 0

    init(frequencyHz: Double, cutoffHz: Double) {
        self.frequencyHz = frequencyHz
        self.cutoffHz = cutoffHz
        omega = 2 * Double.pi * frequencyHz / Self.sampleRate
        design(cutoffHz)
    }

    private mutating func design(_ fc: Double) {
        // Butterworth 4. Ordnung = zwei Abschnitte mit Güte 0,5412 und 1,3066
        let a = SkimBiquad(lowpass: fc, sampleRate: Self.sampleRate, q: 0.5411961)
        let b = SkimBiquad(lowpass: fc, sampleRate: Self.sampleRate, q: 1.3065630)
        (i1.b0, i1.b1, i1.b2, i1.a1, i1.a2) = (a.b0, a.b1, a.b2, a.a1, a.a2)
        (q1.b0, q1.b1, q1.b2, q1.a1, q1.a2) = (a.b0, a.b1, a.b2, a.a1, a.a2)
        (i2.b0, i2.b1, i2.b2, i2.a1, i2.a2) = (b.b0, b.b1, b.b2, b.a1, b.a2)
        (q2.b0, q2.b1, q2.b2, q2.a1, q2.a2) = (b.b0, b.b1, b.b2, b.a1, b.a2)
    }

    mutating func setFrequency(_ hz: Double) {
        frequencyHz = hz
        omega = 2 * Double.pi * hz / Self.sampleRate
    }

    mutating func setCutoff(_ fc: Double) {
        guard abs(fc - cutoffHz) > 0.5 else { return }
        cutoffHz = fc
        design(fc)           // Zustände bleiben: kleine Änderung, kein Sprung
    }

    /// Ein Abtastwert; liefert alle 16 Abtastwerte ein Basisbandsample (I, Q)
    @inline(__always)
    mutating func process(_ x: Float) -> (i: Double, q: Double)? {
        phase += omega
        if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        let v = Double(x)
        let i = i2.step(i1.step(v * cos(phase)))
        let q = q2.step(q1.step(-v * sin(phase)))
        count += 1
        if count == Self.decimation {
            count = 0
            return (i, q)
        }
        return nil
    }
}

// MARK: - CW-Kanal

/// Decodiert ein Morsesignal auf einer Trägerfrequenz: Basisband → Hüllkurve → Schwellen mit Hysterese → Elemente → Zeichen.
/// Die Geschwindigkeit folgt den letzten Strichen und Punkten. Alle Zustände gehören einer Instanz (mehrere Kanäle laufen nebeneinander).
final class SkimCWChannel {
    private var down: SkimDownconverter
    private let r = SkimDownconverter.outputRate

    /// Zeichen, Wortzwischenräume (" ") und Zeichen mit Steuerinhalt „*“ für unbekannte Muster
    var onText: ((String) -> Void)?

    // Hüllkurve und Pegel
    private var env = 0.0
    /// Summe und Anzahl der Hüllkurvenwerte im laufenden Zeichen (Mittel für den Schwund, siehe `endMark`)
    private var plateauSum = 0.0
    private var plateauCount = 0
    private var markLevel = 0.0
    private var spaceLevel = 0.0
    private var warmup = 0
    // Tastung
    private var isMark = false
    private var run = 0                    // Länge des laufenden Elements oder Zwischenraums (Abtastwerte à 2 ms)
    private var previousSpace = 0
    private var lastMark = 0
    private var pattern = ""
    private var wordSpacePending = false
    // Zeitbasis: Punktlänge T in Abtastwerten
    private(set) var dit = 30.0
    private var marks: [Double] = []
    private var spaces: [Double] = []
    // Kennzahlen
    private(set) var characters = 0
    private(set) var unknownPatterns = 0
    private(set) var knownPatterns = 0
    private(set) var markCount = 0
    private(set) var lastEdgeTime = 0.0
    private(set) var framesProcessed = 0

    /// Geschwindigkeit in Wörtern je Minute (PARIS: Punkt = 1,2 s / WpM)
    var wpm: Double { 1.2 / (dit / r) }
    /// Abstand des Zeichenpegels vom Zwischenraum (Amplitudenverhältnis), Maß der Öffnung
    var openRatio: Double { markLevel / max(spaceLevel, 1e-12) }
    var frequencyHz: Double { down.frequencyHz }
    var isKeyDown: Bool { isMark }
    var signalLevel: Double { markLevel }
    var noiseLevel: Double { spaceLevel }
    /// Anteil bekannter Zeichen an allen gelesenen Mustern
    var plausibility: Double {
        let n = knownPatterns + unknownPatterns
        return n == 0 ? 0 : Double(knownPatterns) / Double(n)
    }

    init(frequencyHz: Double) {
        down = SkimDownconverter(frequencyHz: frequencyHz, cutoffHz: 80)
    }

    func setFrequency(_ hz: Double) { down.setFrequency(hz) }

    func process(_ block: UnsafeBufferPointer<Float>) {
        for x in block {
            if let (i, q) = down.process(x) {
                step(hypot(i, q))
                framesProcessed += 1
            }
        }
    }

    // MARK: Schritt je Basisbandsample (2 ms)

    private func step(_ e: Double) {
        // Glättung: ein Viertel Punktlänge, mindestens 2 Abtastwerte
        let tau = max(0.004, dit / r / 4)
        env += (1 - exp(-1 / (tau * r))) * (e - env)
        // Einschwingen: der Pegel soll aus dem Eingang kommen, nicht aus Null
        let warm = Int(0.4 * r)
        if warmup < warm {
            warmup += 1
            let k = 1 / Double(warmup)
            markLevel += k * (env - markLevel)
            spaceLevel = markLevel
            return
        }
        // Pegelverfolgung: Zeichenpegel steigt schnell, fällt langsam; Zwischenraumpegel umgekehrt.
        // Der Zeichenpegel fällt in den Pausen mit mindestens 1 s (bei langsamer Telegrafie 12 Punktlängen) und nach jedem Zeichen auf dessen Mittel
        // (`endMark`): Schwund bis 14 dB in wenigen Sekunden verschiebt die Schwellen rechtzeitig.
        let fast = 1 - exp(-1 / (0.004 * r)), slow = 1 - exp(-1 / (max(1.0, 12 * dit / r) * r))
        markLevel += (env > markLevel ? fast : slow) * (env - markLevel)
        spaceLevel += (env < spaceLevel ? fast : slow * 0.5) * (env - spaceLevel)
        // Das Rauschen gilt nur, wenn es erkennbar unter dem Zeichenpegel liegt
        let span = markLevel - spaceLevel
        let open = markLevel > 2.2 * spaceLevel && span > 1e-9
        let thOn = spaceLevel + 0.55 * span
        let thOff = spaceLevel + 0.40 * span

        run += 1
        if !isMark {
            if open && env > thOn {
                startMark()
            } else {
                spaceTick()
            }
        } else {
            if run > 2 { plateauSum += env; plateauCount += 1 }
            if env < thOff || !open { endMark() }
        }
    }

    private func startMark() {
        let gap = run
        // Lücke innerhalb eines Zeichens (kürzer als 0,3 Punkt): derselbe Strich, Element wieder aufnehmen
        if gap < max(2, Int(0.3 * dit)), lastMark > 0, !pattern.isEmpty {
            pattern.removeLast()
            isMark = true
            run = lastMark + gap
            lastMark = 0
            return
        }
        previousSpace = gap
        isMark = true
        run = 0
        plateauSum = 0
        plateauCount = 0
    }

    private func endMark() {
        let len = run
        isMark = false
        if len < max(2, Int(0.3 * dit)) {
            // zu kurz für ein Element (Störimpuls): als Zwischenraum weiterzählen
            run = previousSpace + len
            return
        }
        // Schwund: der Zeichenpegel nähert sich dem mittleren Pegel dieses Zeichens (nach oben genügt der schnelle Anstieg)
        if plateauCount > 0 {
            let mean = plateauSum / Double(plateauCount)
            if mean < markLevel { markLevel += 0.9 * (mean - markLevel) }
        }
        markCount += 1
        marks.append(Double(len))
        if marks.count > 24 { marks.removeFirst() }
        let isDah = Double(len) > 2.0 * dit
        pattern += isDah ? "-" : "."
        lastMark = len
        run = 0
        wordSpacePending = false
        updateTiming()
        if pattern.count > 9 { flushPattern() }
    }

    /// Zwischenraum: nach 2 Punktlängen ist das Zeichen zu Ende, nach 5 das Wort
    private func spaceTick() {
        if !pattern.isEmpty && Double(run) >= 2.0 * dit {
            flushPattern()
            wordSpacePending = true
        }
        if wordSpacePending && Double(run) >= 5.0 * dit {
            wordSpacePending = false
            onText?(" ")
        }
    }

    private func flushPattern() {
        guard !pattern.isEmpty else { return }
        if let c = SkimTables.morse[pattern] {
            knownPatterns += 1
            characters += 1
            onText?(c)
        } else {
            unknownPatterns += 1
            onText?("*")
        }
        pattern = ""
        lastMark = 0
    }

    // MARK: Zeitbasis

    /// Punktlänge aus den letzten 24 Strichen und Punkten: kurze und lange Marken trennen, dort wo das Längenverhältnis am größten ist
    private func updateTiming() {
        guard marks.count >= 3 else { return }
        let sorted = marks.sorted()
        var splitAt = -1
        var bestRatio = 1.0
        for i in 0..<(sorted.count - 1) {
            let ratio = sorted[i + 1] / max(sorted[i], 1)
            if ratio > bestRatio { bestRatio = ratio; splitAt = i }
        }
        var estimate: Double
        if bestRatio >= 1.8, splitAt >= 0 {
            let shorts = sorted[0...splitAt], longs = sorted[(splitAt + 1)...]
            let ms = shorts.reduce(0, +) / Double(shorts.count), ml = longs.reduce(0, +) / Double(longs.count)
            let ratio = ml / ms
            if ratio >= 3.0, ratio <= 3.85, shorts.count >= 2, longs.count >= 2 {
                // gleichmäßige Verkürzung aller Marken durch Kanten herausrechnen
                estimate = (ml - ms) / 2
            } else {
                estimate = (ms + ml / 3) / 2
            }
        } else {
            // alle Marken gleich lang: Punkte, außer sie sind deutlich länger als die bisherige Punktlänge
            let mean = sorted.reduce(0, +) / Double(sorted.count)
            estimate = mean > 2.0 * dit ? mean / 3 : mean
        }
        // 5 … 60 WpM: Punkt 20 … 240 ms = 10 … 120 Abtastwerte
        estimate = min(max(estimate, 10), 120)
        dit += 0.5 * (estimate - dit)
        // Tiefpass der Geschwindigkeit anpassen: schmaler bei langsamer Telegrafie, breiter bei schneller
        down.setCutoff(min(max(1.6 * wpm + 40, 60), 130))
    }
}

// MARK: - BPSK-Kanal

/// Decodiert BPSK31 oder BPSK63 auf einer Trägerfrequenz: Basisband (500 Hz) → Symboltakt aus den Amplitudeneinbrüchen der Phasenumkehr
/// (Oerder-Meyr: Phase der Taktkomponente im Betragsquadrat) → differentielle Entscheidung → Varicode. Die Frequenz folgt dem Phasenfehler.
final class SkimPSKChannel {
    let mode: SkimMode
    private var down: SkimDownconverter
    private let cell: Int
    private let window: [Double]
    private let windowSum: Double
    var onText: ((String) -> Void)?

    // Symboltakt: Ringpuffer der letzten Zelle, laufender Zähler und Taktkomponente
    private var history: [(i: Double, q: Double)]
    private var count = 0
    private let phasors: [(c: Double, s: Double)]
    private var clockI = 0.0, clockQ = 0.0
    private let clockDecay: Double
    private var nextDecision = -1
    // Entscheidung
    private var previous: (i: Double, q: Double) = (1, 0)
    private var havePrevious = false
    private var shiftRegister: UInt32 = 0
    // Güte und Frequenz
    private(set) var quality = 0.5
    /// Schnelle Güte für den Ausgabeschalter (Träger erkannt) mit Hysterese
    private var qualityFast = 0.5
    private var gateOpen = false
    /// Mittlerer Betrag des Symbolwerts (Basisband, entspricht der halben Trägeramplitude), geglättet
    private(set) var signalLevel = 0.0
    private(set) var frequencyErrorHz = 0.0
    /// Frequenz, um die die Nachführung höchstens ±25 Hz wandern darf (Entdeckung, später die Spur der Engine)
    private var anchorFrequency: Double
    private(set) var characters = 0
    private(set) var printable = 0
    private(set) var symbols = 0
    private(set) var zeroBits = 0
    /// Anteil der Phasenumkehrungen (Nullen) in den letzten Symbolen: ein unmodulierter Träger hat fast keine, Text etwa die Hälfte
    private var zeroShare = 0.5

    var frequencyHz: Double { down.frequencyHz }
    /// Träger erkannt: saubere Entscheidungen (schnell, mit Hysterese: öffnet nach wenigen Symbolen, schließt, wenn das Signal verschwindet)
    var carrierDetected: Bool { gateOpen }
    /// Anteil lesbarer Zeichen an allen gelesenen
    var plausibility: Double { characters == 0 ? 0 : Double(printable) / Double(characters) }

    init(mode: SkimMode, frequencyHz: Double) {
        self.mode = mode
        cell = mode.symbolSamples
        anchorFrequency = frequencyHz
        down = SkimDownconverter(frequencyHz: frequencyHz, cutoffHz: mode == .psk63 ? 85 : 48)
        // Fenster über die Zelle: Höchstwert in der Mitte (dort ist der Betrag am größten), Null an den Rändern
        window = (0..<mode.symbolSamples).map { j in
            let s = sin(Double.pi * (Double(j) + 0.5) / Double(mode.symbolSamples))
            return s * s
        }
        windowSum = window.reduce(0, +)
        history = [(i: Double, q: Double)](repeating: (0, 0), count: mode.symbolSamples)
        phasors = (0..<mode.symbolSamples).map { k in
            let a = 2 * Double.pi * Double(k) / Double(mode.symbolSamples)
            return (cos(a), -sin(a))
        }
        clockDecay = exp(-1 / (8 * Double(mode.symbolSamples)))      // Gedächtnis etwa 8 Symbole
    }

    /// Frequenz von außen setzen (die Spur der Engine hat sich bewegt): auch die Nachführung wandert von hier aus
    func setFrequency(_ hz: Double) {
        down.setFrequency(hz)
        anchorFrequency = hz
    }

    /// Die Spur der Engine liegt bei `hz`: die Nachführung darf höchstens 25 Hz davon abweichen (schützt vor dem Wandern zum Nachbarsignal,
    /// lässt aber Signale mit Drift folgen); der Mischer bleibt unverändert
    func anchor(to hz: Double) { anchorFrequency = hz }

    func process(_ block: UnsafeBufferPointer<Float>) {
        for x in block {
            if let (i, q) = down.process(x) { sample(i, q) }
        }
    }

    private func sample(_ i: Double, _ q: Double) {
        let slot = count % cell
        history[slot] = (i, q)
        // Taktkomponente des Betragsquadrats: arg(S) = −2π·Lage des Maximums / Zellenlänge
        let m = i * i + q * q
        clockI = clockI * clockDecay + m * phasors[slot].c
        clockQ = clockQ * clockDecay + m * phasors[slot].s
        count += 1
        // Entscheidungszeitpunkt: Zelle endet eine halbe Zelle nach dem Betragsmaximum
        if nextDecision < 0 {
            if count >= 4 * cell { nextDecision = count + cell / 2 }
            else { return }
        }
        if count >= nextDecision {
            decide()
            // Lage des Maximums (Abtastwerte) aus der Taktkomponente
            var peak = -atan2(clockQ, clockI) * Double(cell) / (2 * Double.pi)
            if peak < 0 { peak += Double(cell) }
            // Ziel: Zelle endet eine halbe Zelle nach dem Maximum (Index des letzten Abtastwerts, modulo Zelle).
            // Die Korrektur gegenüber dem bisherigen Takt ist je Symbol auf einen Abtastwert begrenzt (kein doppeltes oder verlorenes Symbol).
            let target = Int((peak + Double(cell) / 2).rounded(.down)) % cell + 1
            var delta = (target - count % cell) % cell
            if delta >= cell / 2 { delta -= cell }
            if delta < -cell / 2 { delta += cell }
            nextDecision = count + cell + max(-1, min(1, delta))
        }
    }

    /// Eine Symbolzelle ist gefüllt: Entscheidung, Bit
    private func decide() {
        // die letzten `cell` Abtastwerte in zeitlicher Reihenfolge
        var zi = 0.0, zq = 0.0
        for j in 0..<cell {
            let idx = (count - cell + j) % cell
            zi += window[j] * history[idx].i
            zq += window[j] * history[idx].q
        }
        let level = hypot(zi, zq) / windowSum
        signalLevel += (signalLevel == 0 ? 1 : 0.03) * (level - signalLevel)
        defer { previous = (zi, zq); havePrevious = true }
        guard havePrevious else { return }
        // differentiell: d = z · conj(vorher)
        let di = zi * previous.i + zq * previous.q
        let dq = zq * previous.i - zi * previous.q
        let mag = hypot(di, dq)
        guard mag > 1e-12 else { return }
        symbols += 1
        let bit = di >= 0 ? 1 : 0
        let ratio = abs(di) / mag
        quality += 0.03 * (ratio - quality)
        qualityFast += 0.2 * (ratio - qualityFast)
        if gateOpen {
            if qualityFast < 0.72 { gateOpen = false; shiftRegister = 0 }
        } else if qualityFast > 0.86 && symbols > 24 {
            gateOpen = true
            shiftRegister = 0
        }
        // Frequenznachführung: Phasendrehung zwischen den Symbolen nach Entfernen der Umkehrung
        let phaseError = bit == 1 ? atan2(dq, di) : atan2(-dq, -di)
        let errHz = phaseError / (2 * Double.pi * (Double(cell) / SkimDownconverter.outputRate))
        frequencyErrorHz += 0.05 * (errHz - frequencyErrorHz)
        if gateOpen {
            let f = down.frequencyHz + 0.02 * errHz
            if abs(f - anchorFrequency) < 25 { down.setFrequency(f) }
        }
        pushBit(bit)
    }

    private func pushBit(_ bit: Int) {
        if bit == 0 { zeroBits += 1 }
        zeroShare += 0.02 * ((bit == 0 ? 1 : 0) - zeroShare)
        shiftRegister = (shiftRegister << 1) | UInt32(bit)
        guard shiftRegister & 3 == 0 else { return }
        // zwei Nullen: Zeichenende
        let code = shiftRegister >> 2
        shiftRegister = 0
        guard code != 0, code < 0x1000, gateOpen, zeroShare > 0.12 else { return }
        // Zeichen, die bei geöffnetem Träger gelesen wurden: Code gültig oder nicht (ungültige Codes sind ein Zeichen von Rauschen)
        characters += 1
        guard let ch = SkimTables.varicodeDecode[UInt16(code)] else { return }
        switch ch {
        case 0x0A, 0x0D:
            printable += 1
            onText?("\n")
        case 0x20...0x7E:
            printable += 1
            onText?(String(UnicodeScalar(ch)))
        case 0x09:
            printable += 1
            onText?(" ")
        default:
            break
        }
    }
}
