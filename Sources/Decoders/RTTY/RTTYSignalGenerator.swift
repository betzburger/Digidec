import Foundation

/// Erzeugt RTTY-AFSK mit bekanntem Text – für Logiktests und den Qualitätsvergleich mit fldigi (PLAN.md, Abschnitt 8).
/// Phasenkontinuierliche FSK, Startbit = Space, Datenbits LSB zuerst, Stoppbits = Mark, Ruhezustand = Mark.
public struct RTTYSignalGenerator {
    public var parameters: RTTYParameters
    public var centerHz: Double
    public var sampleRate: Double = 8000
    public var amplitude: Double = 0.5
    /// ITA2- oder US-TTY-Ziffernsatz
    public var ita2 = false
    /// Frequenzversatz des Senders gegenüber `centerHz` (für AFC-Tests)
    public var offsetHz: Double = 0

    public init(parameters: RTTYParameters, centerHz: Double) {
        self.parameters = parameters
        self.centerHz = centerHz
    }

    // Baudot-Tabellen wie fldigi (rtty.cxx)
    static let letters: [Character] = ["\0", "E", "\n", "A", " ", "S", "I", "U", "\r", "D", "R", "J", "N", "F", "C", "K",
                                       "T", "Z", "L", "W", "H", "Y", "P", "Q", "O", "B", "G", " ", "M", "X", "V", " "]
    static let usFigures: [Character] = ["\0", "3", "\n", "-", " ", "\u{07}", "8", "7", "\r", "$", "4", "'", ",", "!", ":", "(",
                                         "5", "\"", ")", "2", "#", "6", "0", "1", "9", "?", "&", " ", ".", "/", ";", " "]
    static let ita2Figures: [Character] = ["\0", "3", "\n", "-", " ", "'", "8", "7", "\r", " ", "4", "\u{07}", ",", "!", ":", "(",
                                           "5", "+", ")", "2", "#", "6", "0", "1", "9", "?", "&", " ", ".", "/", "=", " "]
    static let ltrs = 0x1F, figs = 0x1B, space = 0x04

    /// Text → Baudot-Codes mit Umschaltungen; beginnt mit LTRS. Nicht darstellbare Zeichen entfallen.
    public func baudotCodes(for text: String) -> [Int] {
        let figures = ita2 ? Self.ita2Figures : Self.usFigures
        var codes = [Self.ltrs]
        var inFigures = false
        // skalarweise: Swift behandelt „\r\n“ als ein einziges Character
        for scalar in text.uppercased().unicodeScalars {
            let ch = Character(scalar)
            if ch == " " {
                codes.append(Self.space)
                // Sender, die mit Unshift-on-Space rechnen (Amateurfunk), schalten danach neu um;
                // der DWD sendet FIGS nur einmal und bleibt über Leerzeichen hinweg in den Ziffern
                if parameters.unshiftOnSpace { inFigures = false }
                continue
            }
            if let i = Self.letters.firstIndex(of: ch), i != 0, i != Self.space {
                if inFigures && ch != "\r" && ch != "\n" { codes.append(Self.ltrs); inFigures = false }
                codes.append(i)
            } else if let i = figures.firstIndex(of: ch), i != 0, i != Self.space {
                if !inFigures { codes.append(Self.figs); inFigures = true }
                codes.append(i)
            }
        }
        return codes
    }

    /// Erzeugt Samples: `leadIn` s Ruhe-Mark, dann der Text, dann `tail` s Mark.
    public func samples(for text: String, leadIn: Double = 0.5, tail: Double = 0.5) -> [Float] {
        let codes = baudotCodes(for: text)
        let p = parameters
        let tones = p.tones(center: centerHz + offsetHz)
        var bits: [(mark: Bool, length: Double)] = [(true, leadIn * p.baud)]
        for code in codes {
            bits.append((false, 1))
            for b in 0..<5 { bits.append(((code >> b) & 1 == 1, 1)) }
            bits.append((true, p.stopBits))
        }
        bits.append((true, tail * p.baud))

        var out = [Float]()
        out.reserveCapacity(Int(Double(codes.count) * (6 + p.stopBits) / p.baud * sampleRate + (leadIn + tail) * sampleRate) + 16)
        var phase = 0.0
        var t = 0.0                       // Zeit in Bit-Einheiten, exakt über den Strom
        var produced = 0
        for bit in bits {
            t += bit.length
            let end = Int((t / p.baud * sampleRate).rounded())
            let f = bit.mark ? tones.mark : tones.space
            let dphi = 2 * Double.pi * f / sampleRate
            while produced < end {
                out.append(Float(amplitude * sin(phase)))
                phase += dphi
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                produced += 1
            }
        }
        return out
    }

    /// Weißes Rauschen so addieren, dass das Signal-Rausch-Verhältnis in 3 kHz Bandbreite `snrDB` beträgt
    /// (übliche Angabe für RTTY-Vergleiche). Deterministisch über `seed`.
    public static func addNoise(to signal: inout [Float], amplitude: Double, snrDB: Double,
                                sampleRate: Double = 8000, seed: UInt64 = 1) {
        let signalPower = amplitude * amplitude / 2
        let noiseIn3k = signalPower / pow(10, snrDB / 10)
        let sigma = (noiseIn3k * (sampleRate / 2) / 3000).squareRoot()
        var rng = SplitMix64(seed: seed)
        var i = 0
        while i < signal.count {
            // Box-Muller: zwei normalverteilte Werte
            let u1 = max(rng.nextUnit(), 1e-12), u2 = rng.nextUnit()
            let r = (-2 * log(u1)).squareRoot() * sigma
            signal[i] += Float(r * cos(2 * Double.pi * u2))
            if i + 1 < signal.count { signal[i + 1] += Float(r * sin(2 * Double.pi * u2)) }
            i += 2
        }
    }

    struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }
}
