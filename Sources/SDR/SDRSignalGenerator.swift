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

    /// Frequenzmodulation mit beliebigem Basisband, z. B. dem Multiplexsignal des UKW-Rundfunks. `baseband` liegt mit `basebandRate` vor und wird
    /// linear auf die Abtastrate des Fensters hochgerechnet; 1,0 entspricht `deviation` Hz Hub.
    public mutating func addFM(offsetHz: Double, baseband: [Float], basebandRate: Double, deviation: Double, amplitude: Float) {
        var phase = 0.0
        let ratio = basebandRate / sampleRate
        for n in 0..<count {
            let pos = Double(n) * ratio
            let k = Int(pos)
            let x: Double
            if k + 1 < baseband.count {
                let f = pos - Double(k)
                x = Double(baseband[k]) * (1 - f) + Double(baseband[k + 1]) * f
            } else {
                x = k < baseband.count ? Double(baseband[k]) : 0
            }
            phase += 2 * Double.pi * (offsetHz + deviation * x) / sampleRate
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            i[n] += amplitude * Float(cos(phase))
            q[n] += amplitude * Float(sin(phase))
        }
    }

    /// Oberes Seitenband: ein NF-Signal (z. B. RTTY-Töne) wird als USB-Aussendung mit dem unterdrückten Träger bei `offsetHz` (Dial) in das Fenster gelegt.
    /// Mit `lower` das untere Seitenband. `amplitude` ist die Spitze des Hüllkurvenwertes bei NF-Amplitude 1.
    public mutating func addSSB(offsetHz: Double, audio: [Float], audioRate: Double, amplitude: Float, lower: Bool = false) {
        // Hilbert-Transformation mit einem Fenster-FIR (ungerade Länge, Hamming)
        let taps = 255, mid = taps / 2
        var h = [Double](repeating: 0, count: taps)
        for k in 0..<taps where (k - mid) % 2 != 0 {
            let n = Double(k - mid)
            h[k] = 2 / (Double.pi * n) * (0.54 + 0.46 * cos(Double.pi * n / Double(mid + 1)))
        }
        let count = audio.count
        var analytic = [(Double, Double)](repeating: (0, 0), count: count)
        for n in 0..<count {
            var q = 0.0
            for k in 0..<taps where h[k] != 0 {
                let j = n + mid - k
                if j >= 0 && j < count { q += Double(audio[j]) * h[k] }
            }
            analytic[n] = (Double(audio[n]), lower ? -q : q)
        }
        var phase = 0.0
        let step = 2 * Double.pi * offsetHz / sampleRate
        let ratio = audioRate / sampleRate
        for m in 0..<self.count {
            let pos = Double(m) * ratio
            let k = Int(pos)
            if k + 1 < count {
                let f = pos - Double(k)
                let re = analytic[k].0 * (1 - f) + analytic[k + 1].0 * f
                let im = analytic[k].1 * (1 - f) + analytic[k + 1].1 * f
                let c = cos(phase), sn = sin(phase)
                i[m] += amplitude * Float(re * c - im * sn)
                q[m] += amplitude * Float(re * sn + im * c)
            }
            phase += step
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
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
