// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Accelerate

// Bausteine für den eingebauten SDR-Empfänger: Filterentwurf (Kaiser-Fenster), Faltung mit Zustand über Blockgrenzen und der Mischer.

enum SDRFilterDesign {
    /// Modifizierte Besselfunktion 0. Ordnung (Reihenentwicklung) für das Kaiser-Fenster
    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let q = x * x / 4
        for k in 1..<60 {
            term *= q / Double(k * k)
            sum += term
            if term < sum * 1e-17 { break }
        }
        return sum
    }

    /// Kaiser-β für eine Sperrdämpfung in dB
    static func kaiserBeta(attenuationDB a: Double) -> Double {
        if a > 50 { return 0.1102 * (a - 8.7) }
        if a >= 21 { return 0.5842 * pow(a - 21, 0.4) + 0.07886 * (a - 21) }
        return 0
    }

    /// Ungerade Zahl von Koeffizienten für eine Übergangsbreite (normiert auf die Abtastrate) und Sperrdämpfung
    static func tapCount(transition: Double, attenuationDB: Double = 60, minimum: Int = 11, maximum: Int = 4001) -> Int {
        let n = Int(((attenuationDB - 7.95) / (14.36 * max(transition, 1e-5))).rounded(.up)) + 1
        let odd = n % 2 == 0 ? n + 1 : n
        return min(max(odd, minimum), maximum)
    }

    /// Tiefpass (Sinc mit Kaiser-Fenster), Grenzfrequenz `cutoff` normiert auf die Abtastrate (0 … 0,5), Verstärkung 1 bei Gleichstrom
    static func lowpass(taps n: Int, cutoff fc: Double, attenuationDB: Double = 60) -> [Float] {
        let count = n % 2 == 0 ? n + 1 : n
        let m = Double(count - 1) / 2
        let beta = kaiserBeta(attenuationDB: attenuationDB)
        let i0 = besselI0(beta)
        var h = [Double](repeating: 0, count: count)
        var sum = 0.0
        for k in 0..<count {
            let t = Double(k) - m
            let x = 2 * fc * t
            let sinc = abs(x) < 1e-12 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
            let r = m > 0 ? t / m : 0
            let window = besselI0(beta * (1 - r * r).squareRoot()) / i0
            h[k] = 2 * fc * sinc * window
            sum += h[k]
        }
        return h.map { Float($0 / sum) }
    }

    /// Tiefpass nach Durchlass- und Sperrgrenze (beide normiert)
    static func lowpass(passband fp: Double, stopband fs: Double, attenuationDB: Double = 60, maximum: Int = 4001) -> [Float] {
        let n = tapCount(transition: fs - fp, attenuationDB: attenuationDB, maximum: maximum)
        return lowpass(taps: n, cutoff: (fp + fs) / 2, attenuationDB: attenuationDB)
    }

    /// Komplexer Bandpass: Tiefpass der Breite `halfWidth` (normiert), verschoben auf `center` (normiert, ±0,5).
    /// Rückgabe (Realteil, Imaginärteil) der Koeffizienten.
    static func complexBandpass(halfWidth: Double, transition: Double, center: Double, attenuationDB: Double = 55, maximum: Int = 4001) -> (re: [Float], im: [Float]) {
        let n = tapCount(transition: transition, attenuationDB: attenuationDB, maximum: maximum)
        let lp = lowpass(taps: n, cutoff: halfWidth + transition / 2, attenuationDB: attenuationDB)
        let m = Double(lp.count - 1) / 2
        var re = [Float](repeating: 0, count: lp.count)
        var im = [Float](repeating: 0, count: lp.count)
        for k in 0..<lp.count {
            let phase = 2 * Double.pi * center * (Double(k) - m)
            re[k] = lp[k] * Float(cos(phase))
            im[k] = lp[k] * Float(sin(phase))
        }
        return (re, im)
    }
}

/// Faltung (kausal) mit Zustand über Blockgrenzen, auf Wunsch mit Dezimierung. Rechnet mit `vDSP_desamp`.
final class StreamFIR {
    let decimation: Int
    private let reversed: [Float]
    private var work: [Float]
    private let tapCount: Int

    init(taps: [Float], decimation: Int = 1) {
        precondition(!taps.isEmpty && decimation >= 1)
        self.decimation = decimation
        reversed = taps.reversed()
        tapCount = taps.count
        work = [Float](repeating: 0, count: taps.count - 1)
    }

    var groupDelaySamples: Double { Double(tapCount - 1) / 2 }

    func reset() {
        work = [Float](repeating: 0, count: tapCount - 1)
    }

    /// Eingang anhängen und die fälligen Ausgabewerte in `output` schreiben (ersetzt den Inhalt)
    func process(_ input: UnsafeBufferPointer<Float>, into output: inout [Float]) {
        work.append(contentsOf: input)
        guard work.count >= tapCount else {
            output.removeAll(keepingCapacity: true)
            return
        }
        let outCount = (work.count - tapCount) / decimation + 1
        if output.count != outCount { output = [Float](repeating: 0, count: outCount) }
        work.withUnsafeBufferPointer { w in
            reversed.withUnsafeBufferPointer { f in
                output.withUnsafeMutableBufferPointer { o in
                    vDSP_desamp(w.baseAddress!, vDSP_Stride(decimation), f.baseAddress!, o.baseAddress!, vDSP_Length(outCount), vDSP_Length(tapCount))
                }
            }
        }
        work.removeFirst(outCount * decimation)
    }

    func process(_ input: [Float], into output: inout [Float]) {
        input.withUnsafeBufferPointer { process($0, into: &output) }
    }
}

/// Zwei gleiche Filter für I und Q
final class ComplexStreamFIR {
    private let i: StreamFIR
    private let q: StreamFIR

    init(taps: [Float], decimation: Int = 1) {
        i = StreamFIR(taps: taps, decimation: decimation)
        q = StreamFIR(taps: taps, decimation: decimation)
    }

    func process(i inI: [Float], q inQ: [Float], outI: inout [Float], outQ: inout [Float]) {
        i.process(inI, into: &outI)
        q.process(inQ, into: &outQ)
    }
}

/// Zwei Abtastratenwandler für I und Q (gleicher Zustand, gleiche Blocklängen)
final class ComplexRateConverter {
    private let i: SampleRateConverter
    private let q: SampleRateConverter

    init?(inputRate: Double, outputRate: Double) {
        guard let a = SampleRateConverter(inputRate: inputRate, outputRate: outputRate),
              let b = SampleRateConverter(inputRate: inputRate, outputRate: outputRate) else { return nil }
        i = a
        q = b
    }

    func process(i inI: [Float], q inQ: [Float], outI: inout [Float], outQ: inout [Float]) {
        outI.removeAll(keepingCapacity: true)
        outQ.removeAll(keepingCapacity: true)
        inI.withUnsafeBufferPointer { b in i.process(b) { outI.append(contentsOf: $0) } }
        inQ.withUnsafeBufferPointer { b in q.process(b) { outQ.append(contentsOf: $0) } }
    }
}

/// Mischer mit stetiger Phase: verschiebt ein Signal bei `+offset` auf 0 Hz und setzt dabei die 8-Bit-Rohdaten in Gleitkommazahlen um
struct SDRMixer {
    private var re = 1.0, im = 0.0              // e^(−jφ)
    private var stepRe = 1.0, stepIm = 0.0
    private(set) var offsetHz = 0.0
    private let sampleRate: Double

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    mutating func setOffset(_ hz: Double) {
        offsetHz = hz
        let w = 2 * Double.pi * hz / sampleRate
        stepRe = cos(w)
        stepIm = -sin(w)
    }

    /// 8-Bit-I/Q (vorzeichenlos, Mitte 127,5) → Gleitkomma, verschoben. Ausgabe auf `count` Paare.
    mutating func mix(_ bytes: UnsafeBufferPointer<UInt8>, pairs count: Int, i outI: inout [Float], q outQ: inout [Float]) {
        if outI.count != count { outI = [Float](repeating: 0, count: count); outQ = [Float](repeating: 0, count: count) }
        var r = re, m = im
        let sr = stepRe, si = stepIm
        let scale = 1.0 / 127.5
        outI.withUnsafeMutableBufferPointer { oi in
            outQ.withUnsafeMutableBufferPointer { oq in
                for n in 0..<count {
                    let x = (Double(bytes[2 * n]) - 127.5) * scale
                    let y = (Double(bytes[2 * n + 1]) - 127.5) * scale
                    oi[n] = Float(x * r - y * m)
                    oq[n] = Float(x * m + y * r)
                    let nr = r * sr - m * si
                    m = r * si + m * sr
                    r = nr
                }
            }
        }
        // Betrag nachführen, sonst driftet die Amplitude über Stunden
        let mag = (r * r + m * m).squareRoot()
        re = r / mag
        im = m / mag
    }
}
