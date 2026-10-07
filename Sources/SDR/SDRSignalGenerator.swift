// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Testsignale für den SDR-Empfänger: I/Q-Daten wie vom Gerät (8 Bit, vorzeichenlos), aus beliebig vielen Trägern und Rauschen zusammengesetzt.
/// `offsetHz` ist immer der Abstand von der Mitte des I/Q-Fensters.
public struct SDRTestSignal {
    public let sampleRate: Double
    public private(set) var i: [Float]
    public private(set) var q: [Float]

    public init(sampleRate: Double = 2_400_000, seconds: Double) {
        self.sampleRate = sampleRate
        let n = Int(sampleRate * seconds)
        i = [Float](repeating: 0, count: n)
        q = [Float](repeating: 0, count: n)
    }

    public var count: Int { i.count }

    /// Unmodulierter Träger (auch ein SSB-Ton: Träger bei Mitte + Tonhöhe)
    public mutating func addCarrier(offsetHz: Double, amplitude: Float) {
        var phase = 0.0
        let step = 2 * Double.pi * offsetHz / sampleRate
        for n in 0..<count {
            i[n] += amplitude * Float(cos(phase))
            q[n] += amplitude * Float(sin(phase))
            phase += step
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        }
    }

    /// Frequenzmodulation mit einem Ton
    public mutating func addFM(offsetHz: Double, tone: Double, deviation: Double, amplitude: Float) {
        var phase = 0.0
        for n in 0..<count {
            let t = Double(n) / sampleRate
            let f = offsetHz + deviation * sin(2 * Double.pi * tone * t)
            phase += 2 * Double.pi * f / sampleRate
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            i[n] += amplitude * Float(cos(phase))
            q[n] += amplitude * Float(sin(phase))
        }
    }

    /// Amplitudenmodulation mit einem Ton (Träger mit Modulationsgrad `depth`)
    public mutating func addAM(offsetHz: Double, tone: Double, depth: Double, amplitude: Float) {
        var phase = 0.0
        let step = 2 * Double.pi * offsetHz / sampleRate
        for n in 0..<count {
            let t = Double(n) / sampleRate
            let a = amplitude * Float(1 + depth * sin(2 * Double.pi * tone * t))
            i[n] += a * Float(cos(phase))
            q[n] += a * Float(sin(phase))
            phase += step
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        }
    }

    /// Weißes Gauß-Rauschen (Standardabweichung je Achse)
    public mutating func addNoise(sigma: Float, seed: UInt64 = 1) {
        var rng = SplitMix(seed: seed)
        for n in 0..<count {
            i[n] += sigma * rng.gauss()
            q[n] += sigma * rng.gauss()
        }
    }

    /// Wie vom Gerät: 8 Bit, vorzeichenlos, Mitte 127,5
    public func quantized() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 2 * count)
        for n in 0..<count {
            out[2 * n] = UInt8(max(0, min(255, (i[n] * 127.5 + 127.5).rounded())))
            out[2 * n + 1] = UInt8(max(0, min(255, (q[n] * 127.5 + 127.5).rounded())))
        }
        return out
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func uniform() -> Float { Float(next() >> 40) / Float(1 << 24) }
        /// Box-Muller
        mutating func gauss() -> Float {
            let u1 = max(uniform(), 1e-9), u2 = uniform()
            return (-2 * logf(u1)).squareRoot() * cosf(2 * Float.pi * u2)
        }
    }
}
