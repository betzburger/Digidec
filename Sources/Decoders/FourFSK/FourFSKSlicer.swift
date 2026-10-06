// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// 4FSK-Empfänger für FM-Diskriminator-Audio (4800 Symbole/s, vier Pegel ±1/±3): gemeinsame Grundlage von DMR, YSF (C4FM)
// und anderen Verfahren mit Vierpegel-Modulation. Tiefpass → Pegel aus Spitzenwerten → Takt aus den Nulldurchgängen →
// ein Symbol je Bit-Paar mit weichem Wert (−3 … +3) und harter Entscheidung (Dibit).
//
// Dibit-Zuordnung wie in ETSI TS 102 361 (DMR) und bei C4FM: +3 → 01, +1 → 00, −1 → 10, −3 → 11.

public enum FourFSK {
    public static let baud = 4800.0

    /// Dibit (0…3, Bit 1 = oberes Bit) zum Pegel
    public static func level(ofDibit d: UInt8) -> Float {
        switch d & 3 {
        case 1: return 3
        case 0: return 1
        case 2: return -1
        default: return -3
        }
    }

    /// Pegel zum Dibit (Schwellen bei 0 und ±2)
    public static func dibit(ofLevel v: Float) -> UInt8 {
        if v >= 2 { return 1 }
        if v >= 0 { return 0 }
        if v > -2 { return 2 }
        return 3
    }
}

public final class FourFSKSlicer {
    public let sampleRate: Double
    public let sps: Double
    /// Je Symbol: weicher Wert (−3 … +3, 0 = unsicher)
    public var onSymbol: ((Float) -> Void)?
    public var loopGain = 0.12
    public private(set) var level: Float = 0

    private let taps: [Float]
    private var ring: [Float]
    private var ringPos = 0
    private var peakHigh: Float = 0
    private var peakLow: Float = 0
    private let peakDecay: Float
    private var phase = 0.0
    private var emitted = false
    private var previous: Float = 0
    private var previousSign = false
    private var started = false
    /// Signalbeginn: der Takt soll schnell einrasten (Anfang der Aussendung hat keinen Vorspann)
    private var slowHalf: Float = 0
    private var boost = 0

    public init(sampleRate: Double, baud: Double = FourFSK.baud) {
        self.sampleRate = sampleRate
        sps = sampleRate / baud
        // Fenster-Sinc, Grenzfrequenz etwa 0,65 · Symbolrate (Blackman)
        let count = max(11, Int(sps * 3.2) | 1)
        let fc = min(0.45, 0.65 * baud / sampleRate)
        var h = [Float](repeating: 0, count: count)
        let mid = Double(count - 1) / 2
        var sum = 0.0
        for n in 0..<count {
            let x = Double(n) - mid
            let sinc = x == 0 ? 2 * fc : sin(2 * Double.pi * fc * x) / (Double.pi * x)
            let window = 0.42 - 0.5 * cos(2 * Double.pi * Double(n) / Double(count - 1)) + 0.08 * cos(4 * Double.pi * Double(n) / Double(count - 1))
            h[n] = Float(sinc * window)
            sum += sinc * window
        }
        taps = h.map { $0 / Float(sum) }
        ring = [Float](repeating: 0, count: count)
        peakDecay = Float(1.0 / (sampleRate * 0.02))
    }

    public func reset() {
        ring = [Float](repeating: 0, count: ring.count)
        peakHigh = 0; peakLow = 0
        phase = 0; emitted = false; started = false
        slowHalf = 0; boost = 0
    }

    public func process(_ samples: [Float]) {
        let count = taps.count
        for sample in samples {
            ring[ringPos] = sample
            ringPos += 1
            if ringPos == count { ringPos = 0 }
            var acc: Float = 0
            var index = ringPos
            for tap in taps {
                acc += tap * ring[index]
                index += 1
                if index == count { index = 0 }
            }
            step(acc)
        }
    }

    private func step(_ x: Float) {
        if !started { peakHigh = x; peakLow = x; previous = x; started = true }
        if x > peakHigh { peakHigh = x } else { peakHigh += (x - peakHigh) * peakDecay }
        if x < peakLow { peakLow = x } else { peakLow += (x - peakLow) * peakDecay }
        let center = (peakHigh + peakLow) / 2
        let half = max((peakHigh - peakLow) / 2, 1e-6)       // entspricht Pegel ±3
        level = half
        // Pegelsprung (Beginn einer Aussendung) → einige Dutzend Symbole lang schneller regeln
        if half > 3 * slowHalf + 0.002 { boost = 100 }
        slowHalf += (half - slowHalf) * Float(1 / (sampleRate * 0.05))
        let s = x - center
        let sign = s > 0
        let ds = 1 / sps
        var next = phase + ds
        // Nulldurchgänge liegen bei Wechsel zwischen Symbolen mit verschiedenem Vorzeichen auf der Symbolgrenze
        if sign != previousSign {
            let prevS = previous - center
            let frac = Double(abs(prevS) / max(abs(prevS) + abs(s), 1e-9))
            var e = next - (1 - frac) * ds
            e -= e.rounded()
            next -= (boost > 0 ? 0.4 : loopGain) * e
        }
        previousSign = sign
        if next < 0 { next += 1; emitted = true }
        if next >= 1 { next -= 1; emitted = false }
        if !emitted && next >= 0.5 {
            emitted = true
            if boost > 0 { boost -= 1 }
            onSymbol?(max(-3, min(3, 3 * s / half)))
        }
        phase = next
        previous = x
    }
}
