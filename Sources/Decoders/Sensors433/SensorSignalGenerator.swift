// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Erzeugt I/Q-Daten (8 Bit, vorzeichenlos) von Funksensoren für Prüfstände: OOK aus Puls-/Lückenfolgen, FSK aus Bitfolgen.

public enum SensorSignalGenerator {
    public struct Options: Sendable {
        public var sampleRate = 2_000_000
        /// Träger gegenüber der Mitte in Hz (Sender und Empfänger weichen immer etwas ab)
        public var offsetHz = 25_000.0
        /// Amplitude 0 … 127
        public var amplitude = 90.0
        /// Rauschen (Standardabweichung in Stufen)
        public var noise = 2.0
        /// Gleichanteil in Stufen (Mittenspitze der Geräte)
        public var dc = 0.0
        public var leadSeconds = 0.05
        public var trailSeconds = 0.05
        public var seed: UInt64 = 7
        public init() {}
    }

    private struct Rng {
        var state: UInt64
        mutating func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double { (-2 * log(max(uniform(), 1e-12))).squareRoot() * cos(2 * Double.pi * uniform()) }
    }

    private static func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }

    /// OOK: Folge (Puls µs, Lücke µs)
    public static func ook(_ pulses: [(on: Double, off: Double)], options o: Options = Options()) -> [UInt8] {
        var rng = Rng(state: o.seed &* 2685821657736338717 &+ 1)
        let fs = Double(o.sampleRate)
        var gate: [Bool] = [Bool](repeating: false, count: Int(o.leadSeconds * fs))
        for p in pulses {
            gate += [Bool](repeating: true, count: Int(p.on * 1e-6 * fs))
            gate += [Bool](repeating: false, count: Int(p.off * 1e-6 * fs))
        }
        gate += [Bool](repeating: false, count: Int(o.trailSeconds * fs))
        return render(gate.count, o: o, rng: &rng) { n in gate[n] ? (o.offsetHz, o.amplitude) : (o.offsetHz, 0) }
    }

    /// FSK: Bits (1 = hoher Ton) mit `bitMicroseconds` je Bit und Hub `deviationHz` (Träger dauernd an)
    public static func fsk(bits: [UInt8], bitMicroseconds: Double, deviationHz: Double = 40_000, options o: Options = Options()) -> [UInt8] {
        var rng = Rng(state: o.seed &* 2685821657736338717 &+ 3)
        let fs = Double(o.sampleRate)
        let lead = Int(o.leadSeconds * fs), trail = Int(o.trailSeconds * fs)
        let perBit = bitMicroseconds * 1e-6 * fs
        let body = Int(Double(bits.count) * perBit)
        return render(lead + body + trail, o: o, rng: &rng) { n in
            guard n >= lead, n < lead + body else { return (o.offsetHz, n < lead ? 0 : 0) }
            let b = bits[min(bits.count - 1, Int(Double(n - lead) / perBit))]
            return (o.offsetHz + (b == 1 ? deviationHz : -deviationHz), o.amplitude)
        }
    }

    private static func render(_ count: Int, o: Options, rng: inout Rng, _ at: (Int) -> (freq: Double, amplitude: Double)) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count * 2)
        var phase = 0.0
        let fs = Double(o.sampleRate)
        var level = 0.0                                          // Hüllkurve glätten (Sender haben endliche Flankenzeit)
        for n in 0..<count {
            let (f, a) = at(n)
            level += (a - level) * 0.35
            phase += 2 * Double.pi * f / fs
            out[2 * n] = byte(127.5 + o.dc + level * cos(phase) + o.noise * rng.gaussian())
            out[2 * n + 1] = byte(127.5 + o.dc + level * sin(phase) + o.noise * rng.gaussian())
        }
        return out
    }
}
