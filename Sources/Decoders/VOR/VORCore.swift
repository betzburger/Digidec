// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// VOR und ILS aus AM-demoduliertem Audio (48 kHz, Mono).
//
// VOR (108 … 117,95 MHz): Die Bodenstation sendet zwei 30-Hz-Töne. Der „variable“ Ton steckt in der Amplitudenmodulation
// (die Antenne dreht ein Richtdiagramm 30-mal je Sekunde), der „Bezugston“ ist auf einen 9960-Hz-Hilfsträger frequenzmoduliert
// (± 480 Hz Hub). Dazu kommen Sprache und die Kennung (Morse, 1020 Hz). Die Peilung (Radial, von der Station weg, gegen die
// Bezugsrichtung der Station) ist der Phasenunterschied: der variable Ton läuft dem Bezugston um den Winkel hinterher.
//
// ILS (Landekurssender 108,1 … 111,95 MHz, Gleitwegsender 328,6 … 335,4 MHz): zwei Töne, 90 Hz und 150 Hz, je etwa 20 % AM.
// Der Unterschied der Modulationsgrade (DDM) zeigt die Ablage von der Mittellinie.
//
// Alle Töne liegen bei 48 kHz auf ganzzahligen Vielfachen von 30 Hz: 1600 Abtastwerte sind genau eine Periode von 30 Hz,
// 90 Hz und 150 Hz (3 und 5 Perioden), 9960 Hz (332) und 1020 Hz (34). Darum genügt je Ton eine Korrelation mit einer
// Tabelle von 1600 Werten, ohne Filter und ohne Verzögerung; nur die Hilfsträgerkette hat einen Filter mit bekannter Laufzeit.

public enum NavAudio {
    public static let sampleRate = 48_000.0
    /// Abtastwerte je Periode von 30 Hz
    static let period = 1600
    static let window = 30                   // Blöcke (1 s) für die Mittelung

    static let cosTable: [Float] = (0..<period).map { Float(cos(2 * Double.pi * Double($0) / Double(period))) }
    static let sinTable: [Float] = (0..<period).map { Float(sin(2 * Double.pi * Double($0) / Double(period))) }
}

// MARK: - Messwerte

public struct VORReading: Sendable, Equatable {
    /// Peilung von der Station weg (0 … 360°), ungeeicht
    public var bearing: Double
    /// Frequenzhub des Hilfsträgers (Soll 480 Hz)
    public var deviationHz: Double
    /// Amplitude des variablen 30-Hz-Tons im Audio (Vollaussteuerung = 1)
    public var variableLevel: Double
    /// Leistung des Hilfsträgers (dB gegen Vollaussteuerung)
    public var subcarrierDB: Double
    /// Gleichmäßigkeit des Phasenunterschieds über das Messfenster (0 … 1)
    public var coherence: Double
    /// Hub und Phasenstabilität sprechen für ein VOR-Signal
    public var isValid: Bool
}

public struct ILSReading: Sendable, Equatable {
    public var level90: Double
    public var level150: Double
    public var noise: Double
    /// Summe der Töne, bezogen auf 40 % Modulation (Soll)
    public var depth: Double { level90 + level150 }
    /// Geschätzter DDM (Unterschied der Modulationsgrade), positiv: 90 Hz überwiegt. Bezug: Summe = 40 %.
    public var ddm: Double { depth > 0 ? 0.4 * (level90 - level150) / depth : 0 }
    public var isValid: Bool
}

// MARK: - Empfänger

public final class NavReceiver {
    public private(set) var vor: VORReading?
    public private(set) var ils: ILSReading?
    /// Pegel der Kennung (1020 Hz, 60 Werte je Sekunde) für die Anzeige
    public private(set) var identLevel = 0.0
    public private(set) var inputDB = -120.0
    /// Aufgerufen, wenn die Morse-Kennung (Buchstaben) gelesen wurde
    public var onIdent: ((String) -> Void)?
    /// Aufgerufen bei jedem Messfenster (30 Hz)
    public var onBlock: (() -> Void)?

    private var n = 0                                // Zähler der Abtastwerte (modulo 1600 · 8 für die Tabellen)
    // Blockweise Summen
    private struct Block {
        var vr = 0.0, vi = 0.0                       // variabler 30-Hz-Ton
        var rr = 0.0, ri = 0.0, fmCount = 0          // Bezugston aus der FM-Kette
        var power = 0.0                              // Hilfsträgerleistung
        var a90r = 0.0, a90i = 0.0, a150r = 0.0, a150i = 0.0
        var nzr = [Double](repeating: 0, count: 4), nzi = [Double](repeating: 0, count: 4)     // Rauschmaß: 60, 120, 180, 240 Hz
        var squares = 0.0
        var count = 0
    }
    private var block = Block()
    private var ring: [Block] = []

    // FM-Kette: Mischen mit 9960 Hz, Tiefpass (linearphasig) mit Abtastratenverminderung um 8, Frequenzdiskriminator
    private static let taps: [Float] = {
        let count = 127
        let fc = 1700.0 / NavAudio.sampleRate
        let mid = Double(count - 1) / 2
        var h = (0..<count).map { i -> Double in
            let x = Double(i) - mid
            let sinc = x == 0 ? 2 * fc : sin(2 * Double.pi * fc * x) / (Double.pi * x)
            let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(i) / Double(count - 1)) + 0.08 * cos(4 * Double.pi * Double(i) / Double(count - 1))
            return sinc * w
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 / sum }
        return h.map { Float($0) }
    }()
    private static let delay = (taps.count - 1) / 2
    private static let decimation = 8
    private var zr = [Float](repeating: 0, count: 128), zi = [Float](repeating: 0, count: 128)
    private var zIndex = 0
    private var prevR: Float = 0, prevI: Float = 0
    private var havePrev = false
    private var warm = 0

    // Kennung
    private var identR = 0.0, identI = 0.0, identCount = 0
    private var morse = MorseDecoder()

    public init() {
        morse.onText = { [weak self] text in self?.onIdent?(text) }
    }

    public func reset() {
        n = 0
        block = Block()
        ring.removeAll()
        zr = [Float](repeating: 0, count: 128); zi = [Float](repeating: 0, count: 128)
        zIndex = 0; havePrev = false; warm = 0
        identR = 0; identI = 0; identCount = 0
        morse = MorseDecoder()
        morse.onText = { [weak self] text in self?.onIdent?(text) }
        vor = nil; ils = nil
        identLevel = 0
    }

    private static let identTone = 34                // 1020 Hz = 34 · 30 Hz

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        let cosT = NavAudio.cosTable, sinT = NavAudio.sinTable
        let period = NavAudio.period
        let taps = Self.taps
        let count = taps.count
        for sample in samples {
            let x = sample
            let k = n % period
            // variabler Ton (30 Hz)
            block.vr += Double(x * cosT[k]); block.vi -= Double(x * sinT[k])
            // ILS: 90 und 150 Hz
            let k90 = (3 * n) % period, k150 = (5 * n) % period
            block.a90r += Double(x * cosT[k90]); block.a90i -= Double(x * sinT[k90])
            block.a150r += Double(x * cosT[k150]); block.a150i -= Double(x * sinT[k150])
            for j in 0..<4 {
                let kn = ((2 * j + 2) * n) % period
                block.nzr[j] += Double(x * cosT[kn]); block.nzi[j] -= Double(x * sinT[kn])
            }
            block.squares += Double(x * x)
            block.count += 1
            // Kennung (1020 Hz), Blöcke von 800 Abtastwerten
            let kid = (Self.identTone * n) % period
            identR += Double(x * cosT[kid]); identI -= Double(x * sinT[kid])
            identCount += 1
            if identCount == 800 {
                let level = 2 * (identR * identR + identI * identI).squareRoot() / 800
                identLevel = level
                morse.push(level)
                identR = 0; identI = 0; identCount = 0
            }
            // FM-Kette: Mischen mit e^{-j2π·9960·n/48000}
            let kc = (332 * n) % period
            let mr = x * cosT[kc], mi = -x * sinT[kc]
            zIndex = (zIndex + 1) & 127
            zr[zIndex] = mr; zi[zIndex] = mi
            warm += 1
            if n % Self.decimation == 0 && warm >= count {
                var yr: Float = 0, yi: Float = 0
                var idx = zIndex
                for t in 0..<count {
                    yr += taps[t] * zr[idx]; yi += taps[t] * zi[idx]
                    idx = (idx - 1) & 127
                }
                if havePrev {
                    // Frequenz = Phasenänderung zwischen zwei Ausgaben; gehört zur Zeit n − 4 − Verzögerung
                    let dr = yr * prevR + yi * prevI
                    let di = yi * prevR - yr * prevI
                    let f = Double(atan2(di, dr)) * (NavAudio.sampleRate / Double(Self.decimation)) / (2 * Double.pi)
                    var kt = (n - 4 - Self.delay) % period
                    if kt < 0 { kt += period }
                    block.rr += f * Double(cosT[kt]); block.ri -= f * Double(sinT[kt])
                    block.fmCount += 1
                    block.power += Double(yr * yr + yi * yi)
                }
                prevR = yr; prevI = yi; havePrev = true
            }
            n += 1
            if n % period == 0 { closeBlock() }
        }
    }

    private func closeBlock() {
        // Rolling window
        ring.append(block)
        if ring.count > NavAudio.window { ring.removeFirst() }
        let ms = block.squares / Double(max(1, block.count))
        inputDB = ms > 1e-12 ? max(-120, 10 * log10(ms)) : -120
        block = Block()
        guard ring.count >= 10 else { onBlock?(); return }
        var vr = 0.0, vi = 0.0, rr = 0.0, ri = 0.0, fm = 0, samples = 0, power = 0.0
        var cross = 0.0, crossI = 0.0, norm = 0.0
        var a90r = 0.0, a90i = 0.0, a150r = 0.0, a150i = 0.0
        var nzr = [Double](repeating: 0, count: 4), nzi = [Double](repeating: 0, count: 4)
        for b in ring {
            for j in 0..<4 { nzr[j] += b.nzr[j]; nzi[j] += b.nzi[j] }
            vr += b.vr; vi += b.vi; rr += b.rr; ri += b.ri; fm += b.fmCount; samples += b.count; power += b.power
            a90r += b.a90r; a90i += b.a90i; a150r += b.a150r; a150i += b.a150i
            // Phasenunterschied je Block: Σ Zr · conj(Zv)
            cross += b.rr * b.vr + b.ri * b.vi
            crossI += b.ri * b.vr - b.rr * b.vi
            norm += (b.rr * b.rr + b.ri * b.ri).squareRoot() * (b.vr * b.vr + b.vi * b.vi).squareRoot()
        }
        let nSamples = Double(samples)
        let variableLevel = 2 * (vr * vr + vi * vi).squareRoot() / nSamples
        let deviation = fm > 0 ? 2 * (rr * rr + ri * ri).squareRoot() / Double(fm) : 0
        var bearing = (atan2(ri, rr) - atan2(vi, vr)) * 180 / Double.pi
        bearing = bearing.truncatingRemainder(dividingBy: 360)
        if bearing < 0 { bearing += 360 }
        let coherence = norm > 0 ? (cross * cross + crossI * crossI).squareRoot() / norm : 0
        let subDB = fm > 0 ? 10 * log10(max(1e-12, power / Double(fm))) : -120
        let valid = deviation > 300 && deviation < 700 && coherence > 0.6 && variableLevel > 1e-5
        vor = VORReading(bearing: bearing, deviationHz: deviation, variableLevel: variableLevel, subcarrierDB: subDB, coherence: coherence, isValid: valid)
        // ILS
        let l90 = 2 * (a90r * a90r + a90i * a90i).squareRoot() / nSamples
        let l150 = 2 * (a150r * a150r + a150i * a150i).squareRoot() / nSamples
        // Rauschmaß: mittlere Amplitude der Töne bei 60, 120, 180 und 240 Hz
        let noise = (0..<4).reduce(0.0) { $0 + 2 * (nzr[$1] * nzr[$1] + nzi[$1] * nzi[$1]).squareRoot() / nSamples } / 4
        let ilsValid = l90 > 3 * noise && l150 > 3 * noise && l90 > 1e-4 && l150 > 1e-4 && !valid
        ils = ILSReading(level90: l90, level150: l150, noise: noise, isValid: ilsValid)
        onBlock?()
    }
}

// MARK: - Morse-Kennung

/// Liest die getastete 1020-Hz-Kennung (60 Hüllkurvenwerte je Sekunde)
public struct MorseDecoder {
    public var onText: ((String) -> Void)?
    private static let rate = 60.0
    private var peak = 0.0
    private var floor = 0.0
    private var on = false
    private var run = 0
    private var elements: [(on: Bool, seconds: Double)] = []
    private var started = false
    /// Erst nach einer langen Pause beginnt eine vollständige Kennung (der Anfang einer Aufnahme ist oft mitten drin)
    private var armed = false

    public init() {}

    static let table: [String: Character] = [
        ".-": "A", "-...": "B", "-.-.": "C", "-..": "D", ".": "E", "..-.": "F", "--.": "G", "....": "H", "..": "I", ".---": "J", "-.-": "K", ".-..": "L",
        "--": "M", "-.": "N", "---": "O", ".--.": "P", "--.-": "Q", ".-.": "R", "...": "S", "-": "T", "..-": "U", "...-": "V", ".--": "W", "-..-": "X",
        "-.--": "Y", "--..": "Z", "-----": "0", ".----": "1", "..---": "2", "...--": "3", "....-": "4", ".....": "5", "-....": "6", "--...": "7", "---..": "8", "----.": "9",
    ]

    public mutating func push(_ level: Double) {
        // Spitze fällt langsam (30 s), Rauschboden folgt den Werten unterhalb der Hälfte
        peak = max(level, peak * (1 - 1 / (Self.rate * 30)))
        if level < 0.5 * peak || floor == 0 { floor += (level - floor) * 0.02 }
        let span = peak - floor
        let present = peak > 3 * floor && peak > 1e-5
        let high = floor + 0.55 * span, low = floor + 0.35 * span
        let now = present && (on ? level > low : level > high)
        if now == on {
            run += 1
            if !on, Double(run) / Self.rate > 1.6 {                                       // lange Pause: Kennung zu Ende
                if started { flush() }
                armed = true
            }
            return
        }
        // Wechsel
        let seconds = Double(run) / Self.rate
        if on {
            if seconds >= 0.03 { if armed { elements.append((true, seconds)); started = true } }
            else if started { elements.append((false, seconds)) }                      // Störimpuls zählt als Pause
        } else if started {
            elements.append((false, seconds))
        }
        on = now
        run = 1
        if elements.count > 60 { elements.removeAll(); started = false }
    }

    private mutating func flush() {
        defer { elements.removeAll(); started = false; run = 0 }
        // Nachbarn gleicher Art zusammenfassen (Störimpulse)
        var merged: [(on: Bool, seconds: Double)] = []
        for e in elements {
            if let last = merged.last, last.on == e.on { merged[merged.count - 1].seconds += e.seconds } else { merged.append(e) }
        }
        elements = merged
        let ons = elements.filter { $0.on }.map(\.seconds)
        guard let shortest = ons.min(), let longest = ons.max(), !ons.isEmpty else { return }
        // Punkt und Strich: zwei Gruppen; sind alle gleich lang, entscheidet die absolute Länge
        let dahThreshold = longest / shortest > 2.0 ? (shortest + longest) / 2 : 0.22
        let dit = longest / shortest > 2.0 ? shortest : (shortest < 0.22 ? shortest : shortest / 3)
        var text = ""
        var symbols = ""
        for e in elements {
            if e.on {
                symbols.append(e.seconds >= dahThreshold ? "-" : ".")
            } else {
                if e.seconds > 2 * dit, !symbols.isEmpty {
                    guard let c = Self.table[symbols] else { return }
                    text.append(c); symbols = ""
                }
            }
        }
        if !symbols.isEmpty {
            guard let c = Self.table[symbols] else { return }
            text.append(c)
        }
        if (1...6).contains(text.count) { onText?(text) }
    }
}

// MARK: - Testsignale

public enum NavSignalGenerator {
    /// Getastete Kennung: Töne in Sekunden (Punkt, Strich, Pausen) als Liste (an?, Dauer)
    static func morseElements(_ text: String, dit: Double) -> [(Bool, Double)] {
        var out: [(Bool, Double)] = []
        let inverse = Dictionary(uniqueKeysWithValues: MorseDecoder.table.map { ($0.value, $0.key) })
        for (li, ch) in text.uppercased().enumerated() {
            guard let code = inverse[ch] else { continue }
            if li > 0 { out.append((false, 3 * dit)) }
            for (ci, s) in code.enumerated() {
                if ci > 0 { out.append((false, dit)) }
                out.append((true, s == "." ? dit : 3 * dit))
            }
        }
        return out
    }

    /// Hüllkurve der Kennung (0 oder 1, mit 5-ms-Flanken) für `seconds`, beginnend bei `start`; nach `repeatEvery` s wiederholt
    static func identEnvelope(_ text: String, dit: Double, seconds: Double, start: Double, repeatEvery: Double) -> [Float] {
        let fs = NavAudio.sampleRate
        var env = [Float](repeating: 0, count: Int(seconds * fs))
        guard !text.isEmpty else { return env }
        var t0 = start
        let elements = morseElements(text, dit: dit)
        while t0 < seconds {
            var t = t0
            for (on, d) in elements {
                if on {
                    let a = Int(t * fs), b = min(env.count, Int((t + d) * fs))
                    if a < b { for i in a..<b { env[i] = 1 } }
                }
                t += d
            }
            t0 += repeatEvery
        }
        // Flanken glätten (gleitendes Mittel 5 ms)
        let w = Int(0.005 * fs)
        var smooth = env
        var acc: Float = 0
        for i in 0..<env.count {
            acc += env[i]
            if i >= w { acc -= env[i - w] }
            smooth[i] = acc / Float(w)
        }
        return smooth
    }

    /// AM-Audio einer VOR-Station auf der Peilung `bearing` (Grad). Aufbau: Träger 1, variabler Ton 30 Hz (Grad 30 %), Hilfsträger 9960 Hz
    /// (Hub 480 Hz, Grad 30 %), Kennung 1020 Hz (10 %), optional Sprache und Rauschen. Gleichanteil wird entfernt (wie im SDR-Programm).
    public static func vor(bearing: Double, seconds: Double, ident: String = "", dit: Double = 0.11, noise: Double = 0, voice: Bool = false,
                           variableDepth: Double = 0.3, subcarrierDepth: Double = 0.3, scale: Double = 0.3, seed: UInt64 = 3, phase: Double = 0.7) -> [Float] {
        let fs = NavAudio.sampleRate
        let n = Int(seconds * fs)
        let env = identEnvelope(ident, dit: dit, seconds: seconds, start: 2.0, repeatEvery: 12)
        var rng = seed &* 6364136223846793005 &+ 1442695040888963407
        func uniform() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 11) / 9007199254740992.0 }
        var out = [Double](repeating: 0, count: n)
        let theta = bearing * Double.pi / 180
        var voicePhase = [0.0, 0.0, 0.0]
        for i in 0..<n {
            let t = Double(i) / fs
            let w30 = 2 * Double.pi * 30 * t + phase
            var v = 1 + variableDepth * cos(w30 - theta)
            v += subcarrierDepth * cos(2 * Double.pi * 9960 * t + 16 * sin(w30))
            v += 0.1 * Double(env[i]) * cos(2 * Double.pi * 1020 * t)
            if voice {
                for k in 0..<3 { voicePhase[k] += 2 * Double.pi * [440.0, 720.0, 1250.0][k] * (1 + 0.1 * sin(2 * Double.pi * 0.7 * t)) / fs }
                v += 0.08 * (sin(voicePhase[0]) + 0.6 * sin(voicePhase[1]) + 0.4 * sin(voicePhase[2])) * (0.5 + 0.5 * sin(2 * Double.pi * 2.3 * t))
            }
            if noise > 0 { v += noise * ((uniform() + uniform() + uniform() + uniform()) - 2) * 1.7 }
            out[i] = v
        }
        let mean = out.reduce(0, +) / Double(max(1, n))
        return out.map { Float(($0 - mean) * scale) }
    }

    /// AM-Audio eines Landekurs- oder Gleitwegsenders: Töne 90 Hz und 150 Hz, `ddm` = m90 − m150 (z. B. 0,155 = Vollausschlag), Summe 40 %
    public static func ils(ddm: Double, seconds: Double, ident: String = "", dit: Double = 0.11, noise: Double = 0, scale: Double = 0.3, seed: UInt64 = 5) -> [Float] {
        let fs = NavAudio.sampleRate
        let n = Int(seconds * fs)
        let env = identEnvelope(ident, dit: dit, seconds: seconds, start: 2.0, repeatEvery: 10)
        var rng = seed &* 6364136223846793005 &+ 1442695040888963407
        func uniform() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 11) / 9007199254740992.0 }
        let m90 = 0.2 + ddm / 2, m150 = 0.2 - ddm / 2
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / fs
            var v = 1 + m90 * cos(2 * Double.pi * 90 * t + 0.3) + m150 * cos(2 * Double.pi * 150 * t + 1.1)
            v += 0.1 * Double(env[i]) * cos(2 * Double.pi * 1020 * t)
            if noise > 0 { v += noise * ((uniform() + uniform() + uniform() + uniform()) - 2) * 1.7 }
            out[i] = v
        }
        let mean = out.reduce(0, +) / Double(max(1, n))
        return out.map { Float(($0 - mean) * scale) }
    }
}
