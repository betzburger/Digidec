// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// 9600-Baud-Packet-Radio nach G3RUH (James Miller): Basisband-FSK, die AX.25-Bits werden NRZI-codiert und mit dem selbstsynchronisierenden
// Verwürfler x¹⁷ + x¹² + 1 verwürfelt (Sender), der Empfänger entwürfelt und decodiert NRZI. Das Signal ist gegenüber einer Umkehr der Polarität
// unempfindlich (der Entwürfler erzeugt dann lauter invertierte Bits, die NRZI-Decodierung achtet nur auf Gleichheit).
// Eingang ist das Diskriminator-Audio eines FM-Empfängers (oder der 9k6-Datenanschluss), gleichspannungsgekoppelt oder zumindest ohne starken Hochpass.

/// Verwürfler und Entwürfler des G3RUH-Modems
public struct G3RUHScrambler {
    private var state: UInt32 = 0
    public init() {}

    /// Sender: Bit verwürfeln
    public mutating func scramble(_ bit: Int) -> Int {
        let out = (bit ^ Int(state >> 16) ^ Int(state >> 11)) & 1
        state = (state << 1) | UInt32(out)
        return out
    }

    /// Empfänger: Bit entwürfeln (der Zustand besteht aus den empfangenen Bits, daher selbstsynchronisierend)
    public mutating func descramble(_ bit: Int) -> Int {
        let out = (bit ^ Int(state >> 16) ^ Int(state >> 11)) & 1
        state = (state << 1) | UInt32(bit & 1)
        return out
    }

    public mutating func reset() { state = 0 }
}

/// Demodulator für G3RUH-9600-Baud-Packet-Radio: liefert geprüfte AX.25-Rahmen wie der AFSK-Demodulator
public final class G3RUHDemodulator {
    public struct Options: Sendable, Equatable {
        /// Ein Bit umkehren, wenn die FCS nicht stimmt, aber der Kopf plausibel ist
        public var repairBits = true
        /// Verstärkung der Taktschleife (Phase; die Frequenz folgt mit einem Vierzigstel davon)
        public var loopGain = 0.1
        /// Anteil der Symboldauer, über den für die Entscheidung integriert wird (die Mitte; die Ränder tragen die Nachbarsymbole)
        public var decisionWidth = 0.7
        public init() {}
    }

    public static let baud = 9600.0

    public let sampleRate: Double
    private var options: Options
    private let nominalSPS: Double

    // Summen (Integration über ein Symbol mit gebrochenen Grenzen)
    private static let capacity = 1 << 16
    private static let mask = capacity - 1
    private var cum = [Double](repeating: 0, count: G3RUHDemodulator.capacity)
    private var n = 0
    private var dc: Float = 0
    private let dcAlpha: Float

    // Takt
    private var pos = 0.0
    private var sps: Double
    private var amplitude: Float = 0
    private var previousSymbolValue: Float = 0
    private var kp: Double { options.loopGain }
    private var ki: Double { options.loopGain / 20 }
    private let tolerance = 0.02

    // Bits
    private var scrambler = G3RUHScrambler()
    private var previousBit = 0
    private var hdlc = HDLCReceiver()
    private var sampleIndex = 0
    private var recentBytes: [(key: [UInt8], at: Int)] = []
    /// Pegel des Signals (0 … 1, Mittelwert des Betrags nach Abzug des Gleichanteils, auf Vollaussteuerung bezogen)
    public private(set) var levelPeak = 0.0
    private var levelAvg: Float = 0
    /// Ein Rahmen ist im Gang (nach dem Anfangsflag)
    public var isSynced: Bool { hdlc.isReceiving }
    private var lockedUntil = 0

    public init(sampleRate: Double = 48_000, options: Options = Options()) {
        precondition(sampleRate >= 4 * Self.baud, "Abtastrate zu niedrig für 9600 Bd")
        self.sampleRate = sampleRate
        self.options = options
        nominalSPS = sampleRate / Self.baud
        sps = nominalSPS
        dcAlpha = Float(1 - exp(-1 / (0.02 * sampleRate)))
    }

    public func setOptions(_ o: Options) { options = o }

    public func reset() {
        for i in 0..<cum.count { cum[i] = 0 }
        n = 0
        dc = 0
        pos = 0
        sps = nominalSPS
        amplitude = 0
        previousSymbolValue = 0
        scrambler.reset()
        previousBit = 0
        hdlc.reset()
        recentBytes.removeAll()
        lockedUntil = 0
    }

    @inline(__always)
    private func sum(_ x: Double) -> Double {
        let i = Int(x.rounded(.down))
        let f = x - Double(i)
        let a = cum[i & Self.mask]
        let b = cum[(i + 1) & Self.mask]
        return a + f * (b - a)
    }

    public func process(_ samples: UnsafeBufferPointer<Float>, onFrame: (APRSRawFrame) -> Void) {
        for x in samples {
            dc += dcAlpha * (x - dc)
            let y = x - dc
            levelAvg += 0.001 * (abs(y) - levelAvg)
            cum[(n + 1) & Self.mask] = cum[n & Self.mask] + Double(y)
            n += 1
            sampleIndex += 1
            // Anfang: die Taktlage liegt irgendwo; die Schleife zieht sie heran
            if pos == 0 { pos = Double(n) }
            while Double(n) >= pos + sps { symbol(onFrame) }
        }
        levelPeak = Double(levelAvg) * 2
    }

    /// Ein Symbol (Integration über die Symboldauer), Takt nachführen, Bit weiterreichen
    private func symbol(_ onFrame: (APRSRawFrame) -> Void) {
        let v = Float(sum(pos + sps) - sum(pos))
        let decide = Float(sum(pos + sps * (1 + options.decisionWidth) / 2) - sum(pos + sps * (1 - options.decisionWidth) / 2))
        // Gardner: Wert zwischen den Symbolen mal Änderung der Symbolwerte; e ≈ 4·d/sps bei Übergängen
        let boundary = Float(sum(pos + sps / 2) - sum(pos - sps / 2))
        let reference = max(amplitude, 1e-9)
        var e = boundary * (v - previousSymbolValue) / (reference * reference)
        e = max(-2, min(2, e))
        let d = Double(e) * sps / 4
        amplitude += 0.02 * (abs(v) - amplitude)
        previousSymbolValue = v
        pos += sps - kp * d
        sps = max(nominalSPS * (1 - tolerance), min(nominalSPS * (1 + tolerance), sps - ki * d))
        // Ohne Signal (nur Rauschen) kein Rahmen: die Schwelle liegt weit über dem Rauschen
        guard amplitude > 1e-4 else { return }
        bit(decide >= 0 ? 1 : 0, onFrame)
    }

    private func bit(_ raw: Int, _ onFrame: (APRSRawFrame) -> Void) {
        let d = scrambler.descramble(raw)
        let nrzi = d == previousBit ? 1 : 0       // gleich = 1
        previousBit = d
        guard let bytes = hdlc.push(nrzi) else {
            if hdlc.isReceiving { lockedUntil = max(lockedUntil, sampleIndex + Int(sampleRate * 0.1)) }
            return
        }
        lockedUntil = sampleIndex + Int(sampleRate * 0.5)
        var frame = bytes
        var repaired = false
        if !HDLC.fcsValid(frame) {
            guard options.repairBits, let fixed = AFSKDemodulator.repair(frame) else { return }
            frame = fixed
            repaired = true
        }
        deliver(Array(frame.dropLast(2)), repaired: repaired, onFrame)
    }

    private func deliver(_ bytes: [UInt8], repaired: Bool, _ onFrame: (APRSRawFrame) -> Void) {
        let window = Int(sampleRate * 0.04)
        recentBytes.removeAll { sampleIndex - $0.at > window }
        if recentBytes.contains(where: { $0.key == bytes }) { return }
        recentBytes.append((bytes, sampleIndex))
        onFrame(APRSRawFrame(bytes: bytes, repaired: repaired, slicers: 1, level: min(levelPeak, 1), endSample: sampleIndex))
    }
}

// MARK: - Empfänger (mehrere Demodulatoren)

/// Mehrere Demodulatoren mit unterschiedlicher Taktschleife und Entscheidungsfenster parallel; doppelte Rahmen werden zusammengefasst
/// (dasselbe Prinzip wie die parallelen Entscheider beim 1200-Baud-Modem).
public final class G3RUHReceiver {
    public let sampleRate: Double
    private var demods: [G3RUHDemodulator] = []
    private var recent: [(key: [UInt8], at: Int)] = []
    private var options: G3RUHDemodulator.Options

    /// Verstärkung und Fensterbreite der parallelen Wege
    private static let variants: [(gain: Double, width: Double)] = [(0.1, 0.7), (0.3, 0.5), (0.05, 1.0)]

    public init(sampleRate: Double = 48_000, options: G3RUHDemodulator.Options = G3RUHDemodulator.Options()) {
        self.sampleRate = sampleRate
        self.options = options
        build()
    }

    private func build() {
        demods = Self.variants.map { v in
            var o = options
            o.loopGain = v.gain
            o.decisionWidth = v.width
            return G3RUHDemodulator(sampleRate: sampleRate, options: o)
        }
    }

    public func configure(options: G3RUHDemodulator.Options) {
        self.options = options
        for (d, v) in zip(demods, Self.variants) {
            var o = options
            o.loopGain = v.gain
            o.decisionWidth = v.width
            d.setOptions(o)
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

public enum G3RUHModulator {
    /// G3RUH-Basisband: Rahmen (ohne FCS) mit `preambleFlags` Flags davor, Stopfbits, FCS, Schlussflags; NRZI, Verwürfler, Rechteckimpulse mit Glättung
    /// - Parameters:
    ///   - amplitude: Spannung bei ±Hub
    ///   - clockError: Abweichung der Bitrate (relativ)
    ///   - smoothing: Länge der Glättung in Symbolen (0 = Rechteck; 0,6 etwa Gauß-Filter des Senders)
    public static func modulate(frames: [[UInt8]], sampleRate: Double = 48_000, preambleFlags: Int = 40, gapFlags: Int = 8,
                                amplitude: Float = 0.3, offset: Float = 0, clockError: Double = 0, smoothing: Double = 0.6, inverted: Bool = false) -> [Float] {
        var bits: [Int] = []
        func flag() { for k in 0..<8 { bits.append(0x7E >> k & 1) } }
        for _ in 0..<preambleFlags { flag() }
        for f in frames {
            let payload = HDLC.withFCS(f)
            var ones = 0
            for byte in payload {
                for k in 0..<8 {
                    let b = Int(byte >> UInt8(k)) & 1
                    bits.append(b)
                    if b == 1 { ones += 1; if ones == 5 { bits.append(0); ones = 0 } } else { ones = 0 }
                }
            }
            for _ in 0..<gapFlags { flag() }
        }
        // NRZI (0 = Wechsel) und Verwürfeln
        var scrambler = G3RUHScrambler()
        var level = 1
        var symbols: [Float] = []
        for b in bits {
            if b == 0 { level ^= 1 }
            let s = scrambler.scramble(level)
            symbols.append(s == 1 ? 1 : -1)
        }
        if inverted { symbols = symbols.map { -$0 } }
        let sps = sampleRate / G3RUHDemodulator.baud * (1 + clockError)
        var audio = [Float](repeating: 0, count: Int(Double(symbols.count) * sps) + Int(sampleRate * 0.1))
        for (j, s) in symbols.enumerated() {
            let a = Int((Double(j) * sps).rounded()), z = Int((Double(j + 1) * sps).rounded())
            for n in a..<min(z, audio.count) { audio[n] = s }
        }
        let w = max(1, Int(sps * smoothing))
        if smoothing > 0 {
            for _ in 0..<2 {
                var sm = audio
                for n in 0..<audio.count {
                    var acc: Float = 0
                    for d in 0..<w { acc += audio[max(0, n - d)] }
                    sm[n] = acc / Float(w)
                }
                audio = sm
            }
        }
        return audio.map { offset + amplitude * $0 }
    }
}
