import Foundation

// MARK: - Testsignale für den Skimmer (nur für Logiktests und Tools/SkimBench)

/// Erzeugt CW und BPSK mit bekanntem Text, Rauschen und Schwund; Abtastrate 8 kHz
enum SkimTestSignal {
    static let sampleRate = 8000.0

    /// Zeichen → Muster (aus der Morsetabelle umgekehrt)
    private static let patterns: [Character: String] = {
        var d: [Character: String] = [:]
        for (p, c) in SkimTables.morse where c.count == 1 { d[c.first!] = p }
        return d
    }()

    /// Morse: Punkt = 1,2 s / WpM, weiche Flanken (`riseMs`), Ton `toneHz`; `leadSeconds` Stille davor, `tailSeconds` danach
    static func cw(text: String, wpm: Double, toneHz: Double, amplitude: Float = 0.1, riseMs: Double = 5,
                   leadSeconds: Double = 0.5, tailSeconds: Double = 1.0, weighting: Double = 1.0, jitter: Double = 0, seed: UInt64 = 1) -> [Float] {
        var rng = SkimRNG(seed: seed)
        let dit = 1.2 / wpm
        // Schaltfolge: (Dauer, an)
        var keys: [(Double, Bool)] = []
        func gap(_ units: Double) { keys.append((units * dit, false)) }
        let words = text.uppercased().split(separator: " ", omittingEmptySubsequences: false)
        for (wi, w) in words.enumerated() {
            if wi > 0 { gap(7) }                                  // Wortzwischenraum: 7 Punktlängen
            for (ci, ch) in w.enumerated() {
                guard let p = patterns[ch] else { continue }
                if ci > 0 { gap(3) }
                for (ei, e) in p.enumerated() {
                    if ei > 0 { gap(1) }
                    let units = e == "-" ? 3.0 : 1.0
                    let j = jitter > 0 ? 1 + jitter * (rng.uniform() - 0.5) * 2 : 1
                    keys.append((units * dit * weighting * j, true))
                }
            }
        }
        var env: [Float] = [Float](repeating: 0, count: Int(leadSeconds * sampleRate))
        let rise = max(1, Int(riseMs / 1000 * sampleRate))
        for (d, on) in keys {
            let n = max(1, Int((d * sampleRate).rounded()))
            if on {
                for i in 0..<n {
                    var a: Float = 1
                    if i < rise { a = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(rise))) }
                    if i >= n - rise { a = min(a, Float(0.5 - 0.5 * cos(Double.pi * Double(n - 1 - i) / Double(rise)))) }
                    env.append(a)
                }
            } else {
                env.append(contentsOf: [Float](repeating: 0, count: n))
            }
        }
        env.append(contentsOf: [Float](repeating: 0, count: Int(tailSeconds * sampleRate)))
        let w = 2 * Double.pi * toneHz / sampleRate
        return env.enumerated().map { amplitude * $1 * Float(sin(w * Double($0))) }
    }

    /// BPSK31/63 mit Varicode: Vorlauf mit Leerlauf (Nullen = Phasenumkehr), Text, danach Leerlauf. Raised-Cosine-Übergänge.
    /// `driftHzPerSecond`: der Träger wandert linear (Sender ohne Frequenzstabilität).
    static func bpsk(text: String, mode: SkimMode = .psk31, carrierHz: Double, amplitude: Float = 0.1, idleSymbols: Int = 64, tailSymbols: Int = 48,
                     leadSeconds: Double = 0, tailSeconds: Double = 0.5, driftHzPerSecond: Double = 0) -> [Float] {
        var bits: [UInt8] = [UInt8](repeating: 0, count: idleSymbols)
        for ch in text.utf8 { bits += SkimTables.varicode(ch) }
        bits += [UInt8](repeating: 0, count: tailSymbols)
        // Phasenfolge: eine 0 dreht die Phase um 180°
        var c: [Double] = [1]
        for b in bits { c.append(b == 0 ? -c.last! : c.last!) }
        let per = sampleRate / mode.baud
        let n = Int(Double(bits.count) * per)
        var out = [Float](repeating: 0, count: Int(leadSeconds * sampleRate))
        let w = 2 * Double.pi * carrierHz / sampleRate
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / per
            let k = min(Int(t), c.count - 2)
            let u = t - Double(k)
            let b = c[k] * (1 + cos(Double.pi * u)) / 2 + c[k + 1] * (1 - cos(Double.pi * u)) / 2
            if driftHzPerSecond == 0 {
                out.append(amplitude * Float(b * sin(w * Double(out.count))))
            } else {
                phase += w + 2 * Double.pi * driftHzPerSecond * Double(i) / sampleRate / sampleRate
                out.append(amplitude * Float(b * sin(phase)))
            }
        }
        out.append(contentsOf: [Float](repeating: 0, count: Int(tailSeconds * sampleRate)))
        return out
    }

    /// Verstärkung um `startSeconds` verschieben (Stille davor)
    static func delayed(_ x: [Float], seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * sampleRate)) + x
    }

    /// Langsamer Schwund (Fading) mit Tiefe 0…1 und Periode `period` Sekunden
    static func fading(_ x: [Float], depth: Double, period: Double, phase: Double = 0) -> [Float] {
        x.enumerated().map { i, v in
            let a = 1 - depth * (0.5 - 0.5 * cos(2 * Double.pi * (Double(i) / sampleRate / period + phase)))
            return v * Float(a)
        }
    }

    /// Signale übereinanderlegen (kürzere werden mit Stille aufgefüllt), dazu weißes Rauschen mit Standardabweichung `noise`
    static func mix(_ signals: [[Float]], noise: Float, seconds: Double? = nil, seed: UInt64 = 7) -> [Float] {
        let length = Int((seconds ?? 0) * sampleRate) > 0 ? Int((seconds ?? 0) * sampleRate) : (signals.map(\.count).max() ?? 0)
        var rng = SkimRNG(seed: seed)
        var out = [Float](repeating: 0, count: length)
        for i in 0..<length {
            var v: Float = noise > 0 ? noise * Float(rng.gauss()) : 0
            for s in signals where i < s.count { v += s[i] }
            out[i] = v
        }
        return out
    }

    /// Standardabweichung des Rauschens für einen Rauschabstand `snr` (dB) in 500 Hz zu einem Träger der Amplitude `amplitude` (Spitze, Zeichen gedrückt)
    static func noiseSigma(snr500 snr: Double, amplitude: Float) -> Float {
        // Signalleistung A²/2; Rauschleistung in 500 Hz = σ² · 500 / 4000
        let signalPower = Double(amplitude) * Double(amplitude) / 2
        let noisePower500 = signalPower / pow(10, snr / 10)
        return Float((noisePower500 * 4000 / 500).squareRoot())
    }
}

/// Kleiner Zufallsgenerator (deterministisch)
struct SkimRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gauss() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}
