// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Erzeugt FM-Diskriminator-Audio aus 4FSK-Symbolen (Pegel ±1, ±3): für Prüfstände. Die Pulsform ist ein Gauß-Filter (BT 1,0, bei
// vier Pegeln darf die Zwischensymbol-Störung nicht größer sein); echte C4FM-Sender benutzen einen Wurzel-Kosinus-Puls.

public enum FourFSKModulator {
    public struct Impairments: Sendable {
        public var noise: Float = 0
        public var dc: Float = 0
        public var clockPPM: Double = 0
        public var inverted = false
        public var seed: UInt64 = 1
        public init() {}
    }

    static func pulses(levels: [Float], samplesPerSymbol sps: Double, count: Int, bt: Double) -> [Float] {
        guard !levels.isEmpty else { return [Float](repeating: 0, count: count) }
        let sigma = log(2.0).squareRoot() / (2 * Double.pi * bt)
        let s2 = sigma * 2.0.squareRoot()
        let span = 3
        let pad = span + 2
        let ext = [Float](repeating: levels[0], count: pad) + levels + [Float](repeating: levels[levels.count - 1], count: pad)
        var out = [Float](repeating: 0, count: count)
        for n in 0..<count {
            let x = Double(n) / sps + Double(pad)
            let k0 = Int(x.rounded(.down))
            var v = 0.0
            for k in max(0, k0 - span)...min(ext.count - 1, k0 + span) {
                let u = x - Double(k) - 0.5
                v += Double(ext[k]) * 0.5 * (erf((u + 0.5) / s2) - erf((u - 0.5) / s2))
            }
            out[n] = Float(v)
        }
        return out
    }

    /// Symbole (−3 … +3) → Audio; `amplitude` ist der Pegel bei Symbol ±3. Davor und danach `leadSilence` Sekunden Stille.
    public static func audio(symbols: [Float], sampleRate: Double, baud: Double = FourFSK.baud, amplitude: Float = 0.5, leadSilence: Double = 0.1,
                             bt: Double = 1.0, impairments: Impairments = Impairments()) -> [Float] {
        let sps = sampleRate / baud * (1 + impairments.clockPPM * 1e-6)
        var shaped = pulses(levels: symbols.map { $0 / 3 }, samplesPerSymbol: sps, count: Int(Double(symbols.count) * sps), bt: bt)
        if impairments.inverted { for i in 0..<shaped.count { shaped[i] = -shaped[i] } }
        var state = impairments.seed &* 6364136223846793005 &+ 1442695040888963407
        func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        func gaussian() -> Float { Float((-2 * log(max(uniform(), 1e-12))).squareRoot() * cos(2 * Double.pi * uniform())) }
        let lead = Int(leadSilence * sampleRate)
        var out = [Float](repeating: 0, count: lead + shaped.count + lead)
        for i in 0..<out.count {
            let signal: Float = (i >= lead && i < lead + shaped.count) ? shaped[i - lead] * amplitude : 0
            out[i] = signal + impairments.dc * amplitude + impairments.noise * amplitude * gaussian()
        }
        return out
    }
}
