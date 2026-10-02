import Foundation

// MARK: - HDLC-Empfang

/// Bitweiser HDLC-Empfänger: Flags, Entstopfen, FCS-Prüfung (AX.25)
public struct HDLCReceiver {
    public static let minimumBytes = 17      // Ziel + Quelle (14) + Control + PID + FCS (2)
    public static let maximumBytes = 400

    private var pattern: UInt8 = 0
    private var inFrame = false
    private var bytes: [UInt8] = []
    private var accumulator: UInt8 = 0
    private var bitCount = 0
    private var onesRun = 0

    public init() {}

    /// Wird gerade ein Rahmen gelesen (nach dem Anfangsflag)?
    public var isReceiving: Bool { inFrame }

    /// Ein Bit hereingeben (nach NRZI). Liefert den Rahmen samt FCS, wenn ein Schluss-Flag kam und die Länge passt
    /// (Prüfung der FCS macht der Aufrufer: er kann bei Fehlern noch reparieren).
    public mutating func push(_ bit: Int) -> [UInt8]? {
        pattern = (pattern >> 1) | (bit != 0 ? 0x80 : 0)
        if pattern == 0x7E {
            defer { startFrame() }
            if inFrame, bitCount == 7, bytes.count >= Self.minimumBytes { return bytes }
            return nil
        }
        if pattern == 0xFE {                    // sieben Einsen: Abbruch
            inFrame = false
            return nil
        }
        guard inFrame else { return nil }
        if pattern & 0xFC == 0x7C { return nil }   // eingefügte Null nach fünf Einsen
        accumulator = (accumulator >> 1) | (bit != 0 ? 0x80 : 0)
        bitCount += 1
        if bitCount == 8 {
            if bytes.count >= Self.maximumBytes {
                inFrame = false
                return nil
            }
            bytes.append(accumulator)
            bitCount = 0
        }
        return nil
    }

    private mutating func startFrame() {
        inFrame = true
        bytes.removeAll(keepingCapacity: true)
        accumulator = 0
        bitCount = 0
    }

    mutating func reset() {
        pattern = 0
        inFrame = false
        bytes.removeAll(keepingCapacity: true)
        bitCount = 0
    }
}

// MARK: - Empfänger-Ergebnis

/// Rahmen aus dem Demodulator
public struct APRSRawFrame: Sendable {
    /// Rahmen ohne FCS
    public var bytes: [UInt8]
    /// Durch Umkehren eines Bits gerettet (unsicherer)
    public var repaired: Bool
    /// Wie viele der parallelen Entscheider denselben Rahmen lieferten
    public var slicers: Int
    /// Pegel des Signals (Spitzenwert der Hüllkurve, 0…1)
    public var level: Double
    /// Nummer des Samples, bei dem das Schluss-Flag zu Ende war (gezählt ab Start des Demodulators)
    public var endSample = 0
}

// MARK: - Demodulator

/// Bell-202-AFSK (1200 und 2200 Hz, 1200 Bd) für Packet-Radio und APRS.
///
/// Aufbau: Mischer auf Mark und Space → Tiefpass → Hüllkurven → Pegelnachführung je Ton → mehrere Entscheider mit
/// unterschiedlicher Gewichtung von Space gegen Mark (für de-emphasiertes Audio und unterschiedlich laute Töne),
/// je Entscheider eine Taktrückgewinnung (DPLL auf Nulldurchgängen), NRZI, HDLC. Doppelte Rahmen aus den
/// Entscheidern werden zusammengefasst.
public final class AFSKDemodulator {
    public struct Options: Sendable, Equatable {
        public var slicers = 7
        /// Ein Bit umkehren, wenn die FCS nicht stimmt, aber der Kopf plausibel ist
        public var repairBits = true
        /// Abweichung des Tonpaars in Hz (Mitte 1700): von Hand oder aus Messung
        public var centerOffsetHz = 0.0
        /// Vorverzerrung: hebt hohe Töne an (für de-emphasiertes Audio; 0 = aus, 1 = stark)
        public var preEmphasis = 0.0
        public init() {}
    }

    public let sampleRate: Double
    public private(set) var options: Options

    public static let baud = 1200.0
    public static let markHz = 1200.0
    public static let spaceHz = 2200.0

    /// Baudrate und Töne dieser Instanz (Standard: Bell 202; UKW-DSC nutzt 1200 Bd mit 1300/2100 Hz)
    public let baudRate: Double
    public let markTone: Double
    public let spaceTone: Double
    /// Rohbit-Betrieb (z. B. UKW-DSC): statt NRZI und HDLC kommt je Takt und Entscheider ein Bit (Mark = 1)
    public var onRawBit: ((Int, UInt8) -> Void)?

    private struct Slicer {
        var gain: Double
        var pll: Int32 = 0
        var lastRaw = false
        var previousSymbol = false
        var hdlc = HDLCReceiver()
        var lockedUntil = 0
    }

    private var slicers: [Slicer] = []
    private var pllStep: Int32 = 0
    // Mischer
    private var markPhase = 0.0, spacePhase = 0.0
    private var markStep = 0.0, spaceStep = 0.0
    // Bandpass vor den Mischern (schneidet Rauschen außerhalb der beiden Töne ab, 8 Symbole lang)
    private var preTaps: [Float] = []
    private var preDelay: [Float] = []
    private var preIndex = 0
    // FIR-Tiefpass (vier Stück: I und Q je Ton), Wurzel-Kosinus-Filter
    private var taps: [Float] = []
    private var delays: [[Float]] = Array(repeating: [], count: 4)
    private var delayIndex = 0
    // Pegelnachführung
    private var markPeak = 0.0, spacePeak = 0.0, markValley = 0.0, spaceValley = 0.0
    private let attack = 0.7
    private var decay = 0.0
    private var sampleIndex = 0
    private var lastInput: Float = 0
    private var recent: [(key: [UInt8], at: Int)] = []
    /// Hüllkurve des lautesten Tons (für die Pegelanzeige), 0…1 grob
    public private(set) var levelPeak = 0.0

    public init(sampleRate: Double = 12_000, options: Options = Options(),
                baud: Double = AFSKDemodulator.baud, markHz: Double = AFSKDemodulator.markHz, spaceHz: Double = AFSKDemodulator.spaceHz) {
        self.sampleRate = sampleRate
        self.options = options
        baudRate = baud
        markTone = markHz
        spaceTone = spaceHz
        configure()
    }

    public func setOptions(_ o: Options) {
        let rebuild = o.slicers != options.slicers || o.centerOffsetHz != options.centerOffsetHz || o.preEmphasis != options.preEmphasis
        options = o
        if rebuild { configure() }
    }

    /// Mindestens ein Entscheider liest gerade einen Rahmen (Träger erkannt)
    public var isSynced: Bool { slicers.contains { $0.hdlc.isReceiving && sampleIndex < $0.lockedUntil } }

    private func configure() {
        let n = max(1, min(options.slicers, 15))
        let gains: [Double]
        if n == 1 { gains = [1] }
        else {
            // geometrisch von −9 dB … +9 dB, die Mitte immer dabei
            gains = (0..<n).map { pow(10, (-9 + 18 * Double($0) / Double(n - 1)) / 20) }
        }
        slicers = gains.map { Slicer(gain: $0) }
        pllStep = Int32(truncatingIfNeeded: Int64((4_294_967_296.0 * baudRate / sampleRate).rounded()))
        markStep = 2 * .pi * (markTone + options.centerOffsetHz) / sampleRate
        spaceStep = 2 * .pi * (spaceTone + options.centerOffsetHz) / sampleRate
        // Wurzel-Kosinus-Filter (Roll-off 0,2, 2,8 Symbole breit): angepasstes Filter für die Töne
        let sps = sampleRate / baudRate
        let len = max(5, Int((2.8 * sps).rounded()) | 1)
        let alpha = 0.2
        var t = [Double](repeating: 0, count: len)
        let mid = Double(len - 1) / 2
        for i in 0..<len {
            let x = (Double(i) - mid) / sps          // in Symbolen
            var v: Double
            if abs(x) < 1e-9 {
                v = 1 - alpha + 4 * alpha / .pi
            } else if abs(abs(x) - 1 / (4 * alpha)) < 1e-9 {
                v = alpha / 2.0.squareRoot() * ((1 + 2 / .pi) * sin(.pi / (4 * alpha)) + (1 - 2 / .pi) * cos(.pi / (4 * alpha)))
            } else {
                v = (sin(.pi * x * (1 - alpha)) + 4 * alpha * x * cos(.pi * x * (1 + alpha))) / (.pi * x * (1 - pow(4 * alpha * x, 2)))
            }
            t[i] = v
        }
        let sum = t.reduce(0, +)
        taps = t.map { Float($0 / sum) }
        // Bandpass 1014 … 2386 Hz (Mark − 0,155·Baud … Space + 0,155·Baud), Hamming-gefenstert
        let plen = max(9, Int((8 * sps).rounded()) | 1)
        let f1 = (markTone + options.centerOffsetHz - 0.155 * baudRate) / sampleRate
        let f2 = (spaceTone + options.centerOffsetHz + 0.155 * baudRate) / sampleRate
        var b = [Double](repeating: 0, count: plen)
        let pmid = Double(plen - 1) / 2
        for i in 0..<plen {
            let x = Double(i) - pmid
            let h = x == 0 ? 2 * (f2 - f1) : (sin(2 * .pi * f2 * x) - sin(2 * .pi * f1 * x)) / (.pi * x)
            b[i] = h * (0.54 - 0.46 * cos(2 * .pi * Double(i) / Double(plen - 1)))
        }
        preTaps = b.map { Float($0) }
        preDelay = [Float](repeating: 0, count: plen)
        preIndex = 0
        delays = Array(repeating: [Float](repeating: 0, count: len), count: 4)
        delayIndex = 0
        decay = 1 - exp(-1 / (0.25 * sampleRate))
        markPeak = 0; spacePeak = 0; markValley = 0; spaceValley = 0
        markPhase = 0; spacePhase = 0
    }

    public func reset() {
        configure()
        recent.removeAll()
        sampleIndex = 0
    }

    /// Verarbeitet Samples; `onFrame` für jeden neuen Rahmen mit gültiger FCS
    public func process(_ samples: UnsafeBufferPointer<Float>, onFrame: (APRSRawFrame) -> Void) {
        let len = taps.count
        let pre = Float(options.preEmphasis)
        for raw in samples {
            sampleIndex += 1
            let emphasized = raw - pre * lastInput
            lastInput = raw
            preDelay[preIndex] = emphasized
            var xf: Float = 0
            var q = preIndex
            for k in 0..<preTaps.count {
                xf += preTaps[k] * preDelay[q]
                q = q == 0 ? preTaps.count - 1 : q - 1
            }
            preIndex = preIndex + 1 == preTaps.count ? 0 : preIndex + 1
            let x = xf
            // Mischen
            let cm = Float(cos(markPhase)), sm = Float(sin(markPhase))
            let cs = Float(cos(spacePhase)), ss = Float(sin(spacePhase))
            markPhase += markStep; spacePhase += spaceStep
            if markPhase > 2 * .pi { markPhase -= 2 * .pi }
            if spacePhase > 2 * .pi { spacePhase -= 2 * .pi }
            delays[0][delayIndex] = x * cm
            delays[1][delayIndex] = x * sm
            delays[2][delayIndex] = x * cs
            delays[3][delayIndex] = x * ss
            // Tiefpass (Faltung über den Ringpuffer)
            var acc: (Float, Float, Float, Float) = (0, 0, 0, 0)
            var j = delayIndex
            for k in 0..<len {
                let tap = taps[k]
                acc.0 += tap * delays[0][j]
                acc.1 += tap * delays[1][j]
                acc.2 += tap * delays[2][j]
                acc.3 += tap * delays[3][j]
                j = j == 0 ? len - 1 : j - 1
            }
            delayIndex = delayIndex + 1 == len ? 0 : delayIndex + 1
            let m = Double((acc.0 * acc.0 + acc.1 * acc.1).squareRoot())
            let s = Double((acc.2 * acc.2 + acc.3 * acc.3).squareRoot())
            track(m, &markPeak, &markValley)
            track(s, &spacePeak, &spaceValley)
            levelPeak = max(markPeak, spacePeak) * 2
            // auf 0…1 je Ton bringen
            let mNorm = (m - markValley) / max(markPeak - markValley, 1e-7)
            let sNorm = (s - spaceValley) / max(spacePeak - spaceValley, 1e-7)
            for i in 0..<slicers.count {
                let out = mNorm - sNorm * slicers[i].gain
                step(i, out > 0, onFrame)
            }
        }
    }

    private func track(_ v: Double, _ peak: inout Double, _ valley: inout Double) {
        if v > peak { peak += (v - peak) * attack } else { peak += (v - peak) * decay }
        if v < valley { valley += (v - valley) * attack } else { valley += (v - valley) * decay }
        if valley > peak { valley = peak }
    }

    private func step(_ i: Int, _ raw: Bool, _ onFrame: (APRSRawFrame) -> Void) {
        let previous = slicers[i].pll
        slicers[i].pll = previous &+ pllStep
        if raw != slicers[i].lastRaw {
            // Übergang: Takt auf den Bitwechsel ziehen
            let inertia = sampleIndex < slicers[i].lockedUntil ? 0.74 : 0.50
            slicers[i].pll = Int32(Double(slicers[i].pll) * inertia)
        }
        slicers[i].lastRaw = raw
        guard slicers[i].pll < 0, previous >= 0 else { return }
        if let onRawBit {
            onRawBit(i, raw ? 1 : 0)
            return
        }
        // Abtastzeitpunkt: NRZI (gleich = 1)
        let bit = raw == slicers[i].previousSymbol ? 1 : 0
        slicers[i].previousSymbol = raw
        guard let bytes = slicers[i].hdlc.push(bit) else {
            if slicers[i].hdlc.isReceiving { slicers[i].lockedUntil = max(slicers[i].lockedUntil, sampleIndex + Int(sampleRate * 0.1)) }
            return
        }
        slicers[i].lockedUntil = sampleIndex + Int(sampleRate * 0.5)
        var frame = bytes
        var repaired = false
        if !HDLC.fcsValid(frame) {
            guard options.repairBits, let fixed = Self.repair(frame) else { return }
            frame = fixed
            repaired = true
        }
        deliver(Array(frame.dropLast(2)), repaired: repaired, onFrame)
    }

    private func deliver(_ bytes: [UInt8], repaired: Bool, _ onFrame: (APRSRawFrame) -> Void) {
        let window = Int(sampleRate * 0.04)
        recent.removeAll { sampleIndex - $0.at > window }
        if recent.contains(where: { $0.key == bytes }) { return }
        recent.append((bytes, sampleIndex))
        onFrame(APRSRawFrame(bytes: bytes, repaired: repaired, slicers: 1, level: min(levelPeak, 1), endSample: sampleIndex))
    }

    /// Ein Bit umkehren, bis die FCS stimmt – nur wenn der Kopf wie AX.25 aussieht (schützt vor Zufallstreffern)
    static func repair(_ frame: [UInt8]) -> [UInt8]? {
        guard frame.count >= HDLCReceiver.minimumBytes, frame.count <= 330, headerLooksValid(frame) else { return nil }
        var f = frame
        for byte in 0..<f.count {
            for bit in 0..<8 {
                f[byte] ^= 1 << UInt8(bit)
                if HDLC.fcsValid(f), let parsed = AX25Frame.parse(Array(f.dropLast(2))), parsed.hasPlausibleAddresses,
                   parsed.control & 0xEF == 0x03 {
                    return f
                }
                f[byte] ^= 1 << UInt8(bit)
            }
        }
        return nil
    }

    /// Zwei Adressen mit gültigen Zeichen (so wie sie bei einem Bitfehler im Kopf noch aussehen würden)
    private static func headerLooksValid(_ f: [UInt8]) -> Bool {
        guard f.count >= 16 else { return false }
        var ok = 0
        for i in 0..<14 where i % 7 != 6 {
            let c = f[i]
            if c & 1 == 0, (0x40...0xB4).contains(c) { ok += 1 }
        }
        return ok >= 10
    }
}

// MARK: - Empfänger (mehrere Demodulatoren)

/// Hält einen Demodulator ohne und einen mit Vorverzerrung (für de-emphasiertes Audio) parallel und fasst doppelte Rahmen zusammen.
/// Flaches Diskriminator-Audio und de-emphasiertes Lautsprecher-Audio sind so ohne Umschalten gleich gut lesbar.
public final class AFSKReceiver {
    public enum Emphasis: String, CaseIterable, Sendable {
        /// Beide Wege gleichzeitig
        case auto
        /// Nur ohne Vorverzerrung (flaches Audio)
        case off
        /// Nur mit Vorverzerrung (de-emphasiertes Audio)
        case on
    }

    public static let emphasisAmount = 0.7

    private var demods: [AFSKDemodulator] = []
    private var recent: [(key: [UInt8], at: Int)] = []
    public let sampleRate: Double
    public private(set) var emphasis: Emphasis
    private var options: AFSKDemodulator.Options

    public init(sampleRate: Double = 12_000, options: AFSKDemodulator.Options = AFSKDemodulator.Options(), emphasis: Emphasis = .auto) {
        self.sampleRate = sampleRate
        self.options = options
        self.emphasis = emphasis
        build()
    }

    private func build() {
        func make(_ pre: Double) -> AFSKDemodulator {
            var o = options
            o.preEmphasis = pre
            return AFSKDemodulator(sampleRate: sampleRate, options: o)
        }
        switch emphasis {
        case .off:  demods = [make(0)]
        case .on:   demods = [make(Self.emphasisAmount)]
        case .auto: demods = [make(0), make(Self.emphasisAmount)]
        }
    }

    public func configure(options: AFSKDemodulator.Options, emphasis: Emphasis) {
        let rebuild = emphasis != self.emphasis
        self.options = options
        self.emphasis = emphasis
        if rebuild { build(); recent.removeAll() } else {
            for (i, d) in demods.enumerated() {
                var o = options
                o.preEmphasis = (emphasis == .on || (emphasis == .auto && i == 1)) ? Self.emphasisAmount : 0
                d.setOptions(o)
            }
        }
    }

    public func reset() {
        demods.forEach { $0.reset() }
        recent.removeAll()
    }

    public var isSynced: Bool { demods.contains { $0.isSynced } }
    public var levelPeak: Double { demods.map(\.levelPeak).max() ?? 0 }

    public func process(_ block: UnsafeBufferPointer<Float>, onFrame: (APRSRawFrame) -> Void) {
        var found: [APRSRawFrame] = []
        for d in demods { d.process(block) { found.append($0) } }
        // Ein Rahmen, den mehrere Wege lesen, endet auf wenige Millisekunden genau gleich (alle sehen dieselben Samples).
        // Ein Rahmen dauert länger als 100 ms: dieselben Bytes innerhalb von 40 ms sind derselbe Rahmen.
        let window = Int(sampleRate * 0.04)
        found = found.filter { !$0.repaired } + found.filter { $0.repaired }     // unrepariert hat Vorrang
        for f in found {
            if recent.contains(where: { $0.key == f.bytes && abs($0.at - f.endSample) <= window }) { continue }
            recent.append((f.bytes, f.endSample))
            onFrame(f)
        }
        let now = found.map(\.endSample).max() ?? 0
        recent.removeAll { now - $0.at > window * 4 }
    }
}

// MARK: - Modulator (Testsignal)

public enum AFSKModulator {
    /// Bell-202-AFSK mit stetiger Phase: Rahmen (ohne FCS) mit `preamble` Flags, Stopfbits und Schlussflags
    public static func modulate(frames: [[UInt8]], sampleRate: Double = 12_000, preambleFlags: Int = 25,
                                gapSeconds: Double = 0.3, amplitude: Float = 0.5, deEmphasis: Bool = false,
                                baudError: Double = 0, toneOffsetHz: Double = 0) -> [Float] {
        var bits: [Bool] = []
        func append(_ byte: UInt8, stuff: Bool, ones: inout Int) {
            for k in 0..<8 {
                let b = (byte >> UInt8(k)) & 1 == 1
                bits.append(b)
                if stuff {
                    if b { ones += 1; if ones == 5 { bits.append(false); ones = 0 } } else { ones = 0 }
                }
            }
        }
        var out: [Float] = []
        var phase = 0.0
        var symbol = false
        var samples = 0.0
        func emit(_ bitsToSend: [Bool]) {
            let perBit = sampleRate / (AFSKDemodulator.baud * (1 + baudError))
            for b in bitsToSend {
                if !b { symbol.toggle() }               // NRZI: 0 = Wechsel
                let f = (symbol ? AFSKDemodulator.markHz : AFSKDemodulator.spaceHz) + toneOffsetHz
                samples += perBit
                while samples >= 1 {
                    out.append(Float(sin(phase)) * amplitude)
                    phase += 2 * .pi * f / sampleRate
                    if phase > 2 * .pi { phase -= 2 * .pi }
                    samples -= 1
                }
            }
        }
        for frame in frames {
            bits.removeAll()
            var dummy = 0
            for _ in 0..<preambleFlags { append(0x7E, stuff: false, ones: &dummy) }
            var ones = 0
            for byte in HDLC.withFCS(frame) { append(byte, stuff: true, ones: &ones) }
            for _ in 0..<3 { append(0x7E, stuff: false, ones: &dummy) }
            emit(bits)
            out += [Float](repeating: 0, count: Int(gapSeconds * sampleRate))
            phase = 0
        }
        if deEmphasis {
            // 6 dB/Oktave Absenkung wie hinter dem NF-Ausgang eines FM-Empfängers (ein Pol bei ≈ 500 Hz)
            let a = Float(exp(-2 * .pi * 500 / sampleRate))
            var y: Float = 0
            for i in 0..<out.count { y = (1 - a) * out[i] * 4 + a * y; out[i] = y }
        }
        return out
    }
}
