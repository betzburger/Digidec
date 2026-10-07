// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Accelerate

// π/4-DQPSK-Empfänger für TETRA (18 000 Symbole/s, Wurzel-Kosinus-Filter α = 0,35, Kanalraster 25 kHz).
//
// I/Q mit beliebiger Abtastrate (ab 48 kS/s) → Mischen auf die Kanalmitte → FIR-Dezimation auf etwa 72 kS/s →
// angepasstes Filter → Symboltakt blockweise aus der Hüllkurvenlinie bei 18 kHz (Oerder/Meyr) mit Nachführung →
// Frequenzversatz aus der 4. Potenz der Differenzphase (Grobsuche aus dem Spektrum) → weiche Bits je Symbol.
//
// Die Bits kommen für die „normale“ Seitenlage; ist der Empfänger spiegelverkehrt (I und Q vertauscht), dreht sich nur das
// erste Bit jedes Paares um – das prüft der Burst-Synchronisierer (`TETRAFramer`).

/// Komplexer FIR-Dezimator mit reellen, symmetrischen Koeffizienten
final class ComplexFIR: @unchecked Sendable {
    let taps: [Float]
    let decimation: Int
    private var histI: [Float]
    private var histQ: [Float]
    private var skip = 0
    private var work: [Float] = []

    init(taps: [Float], decimation: Int) {
        self.taps = taps
        self.decimation = max(1, decimation)
        histI = [Float](repeating: 0, count: taps.count - 1)
        histQ = histI
    }

    func reset() {
        for i in 0..<histI.count { histI[i] = 0; histQ[i] = 0 }
        skip = 0
    }

    /// Eingang anhängen, Ausgabe (I, Q) hinten anhängen
    func process(i: UnsafePointer<Float>, q: UnsafePointer<Float>, count n: Int, outI: inout [Float], outQ: inout [Float]) {
        let l = taps.count
        let total = histI.count + n
        if work.count < 2 * total { work = [Float](repeating: 0, count: 2 * total) }
        work.withUnsafeMutableBufferPointer { w in
            let wi = w.baseAddress!
            let wq = wi + total
            histI.withUnsafeBufferPointer { h in for k in 0..<h.count { wi[k] = h[k] } }
            histQ.withUnsafeBufferPointer { h in for k in 0..<h.count { wq[k] = h[k] } }
            let off = histI.count
            for k in 0..<n { wi[off + k] = i[k]; wq[off + k] = q[k] }
            // Ausgang j: Fenster [p, p + l) mit p = skip + j·D (p + l − 1 ist der neueste Wert)
            var p = skip
            taps.withUnsafeBufferPointer { t in
                while p + l <= total {
                    var ri: Float = 0, rq: Float = 0
                    vDSP_dotpr(wi + p, 1, t.baseAddress!, 1, &ri, vDSP_Length(l))
                    vDSP_dotpr(wq + p, 1, t.baseAddress!, 1, &rq, vDSP_Length(l))
                    outI.append(ri)
                    outQ.append(rq)
                    p += decimation
                }
            }
            skip = p - (total - (l - 1))
            if skip < 0 { skip = 0 }
            // Verlauf: letzte l − 1 Werte
            let keep = l - 1
            for k in 0..<keep { histI[k] = wi[total - keep + k]; histQ[k] = wq[total - keep + k] }
        }
    }
}

public final class TETRAReceiver: @unchecked Sendable {
    public static let minimumSampleRate = 48_000.0

    public let inputRate: Double
    /// Abstand des Kanals von der Mitte des Eingangs in Hz (Sollwert; die Nachführung ändert `tuneHz`)
    public let nominalOffsetHz: Double
    public private(set) var tuneHz: Double
    public let decimation: Int
    public let rate1: Double
    public let sps: Double

    /// Neue weiche Bits (zwei je Symbol), im Takt der Blöcke
    public var onBits: (([SoftBit]) -> Void)?

    // Messwerte
    public private(set) var powerDB = -120.0
    public private(set) var coherence = 0.0
    public private(set) var offsetErrorHz = 0.0
    public private(set) var symbolsOut = 0
    public private(set) var acquired = false

    // Mischer
    private var oscRe = 1.0, oscIm = 0.0
    private var stepRe = 1.0, stepIm = 0.0
    private var renorm = 0

    // Filter
    private let decimator: ComplexFIR?
    private let matched: ComplexFIR
    private var mixI: [Float] = [], mixQ: [Float] = []
    private var z0I: [Float] = [], z0Q: [Float] = []
    private var zI: [Float] = [], zQ: [Float] = []      // gefiltert; zI[0] hat den globalen Index `zBase`
    private var zBase = 0

    // Takt
    static let blockSize = 2048
    private var pos = 0.0                  // globale Lage des nächsten Symbols
    private var spsEff: Double
    private var timingInitialised = false
    private let timingTable: [(Float, Float)]
    private var prevI: Float = 0, prevQ: Float = 0
    private var havePrev = false
    private var meanPower: Float = 0

    // Frequenznachführung
    private var spectrum = [Float](repeating: 0, count: 1024)
    private var spectrumBlocks = 0
    private var fftBuffer: [Float] = []
    private let fftSetup: FFTSetup?
    private var afcAccRe = 0.0, afcAccIm = 0.0, afcCount = 0
    /// Hat eine Grobsuche stattgefunden? Neustart über `reacquire()`
    private var coarseDone = false

    public init(inputRate: Double, nominalOffsetHz: Double) {
        self.inputRate = inputRate
        self.nominalOffsetHz = nominalOffsetHz
        tuneHz = nominalOffsetHz
        decimation = max(1, Int((inputRate / 72_000).rounded()))
        rate1 = inputRate / Double(decimation)
        sps = rate1 / TETRA.symbolRate
        spsEff = sps
        if decimation > 1 {
            // Tiefpass 15 kHz, Hamming-Fenster, Länge 8·D + 1
            let l = 8 * decimation + 1
            let fc = 15_000.0 / inputRate
            var t = [Double](repeating: 0, count: l)
            var sum = 0.0
            for k in 0..<l {
                let m = Double(k) - Double(l - 1) / 2
                let sinc = m == 0 ? 2 * fc : sin(2 * Double.pi * fc * m) / (Double.pi * m)
                let w = 0.54 - 0.46 * cos(2 * Double.pi * Double(k) / Double(l - 1))
                t[k] = sinc * w
                sum += t[k]
            }
            decimator = ComplexFIR(taps: t.map { Float($0 / sum) }, decimation: decimation)
        } else {
            decimator = nil
        }
        let spsLocal = (inputRate / Double(max(1, Int((inputRate / 72_000).rounded())))) / TETRA.symbolRate
        matched = ComplexFIR(taps: TETRAReceiver.rootRaisedCosine(beta: 0.35, samplesPerSymbol: spsLocal, span: 10), decimation: 1)
        timingTable = (0..<TETRAReceiver.blockSize).map { k in
            let a = -2 * Double.pi * Double(k) / spsLocal
            return (Float(cos(a)), Float(sin(a)))
        }
        fftSetup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))
        updateStep()
    }

    deinit { if let s = fftSetup { vDSP_destroy_fftsetup(s) } }

    public static func isSupported(sampleRate: Double) -> Bool { sampleRate >= minimumSampleRate }

    /// Wurzel-Kosinus-Filter, normiert auf Energie 1; ungerade Länge
    static func rootRaisedCosine(beta: Double, samplesPerSymbol sps: Double, span: Int) -> [Float] {
        let half = Int((Double(span) * sps / 2).rounded())
        var h = [Double](repeating: 0, count: 2 * half + 1)
        for k in -half...half {
            let t = Double(k) / sps
            var v: Double
            if abs(t) < 1e-9 {
                v = 1 - beta + 4 * beta / Double.pi
            } else if abs(abs(4 * beta * t) - 1) < 1e-6 {
                v = beta / sqrt(2) * ((1 + 2 / Double.pi) * sin(Double.pi / (4 * beta)) + (1 - 2 / Double.pi) * cos(Double.pi / (4 * beta)))
            } else {
                v = (sin(Double.pi * t * (1 - beta)) + 4 * beta * t * cos(Double.pi * t * (1 + beta))) / (Double.pi * t * (1 - pow(4 * beta * t, 2)))
            }
            h[k + half] = v
        }
        let e = sqrt(h.reduce(0) { $0 + $1 * $1 })
        return h.map { Float($0 / e) }
    }

    private func updateStep() {
        let w = -2 * Double.pi * tuneHz / inputRate
        stepRe = cos(w)
        stepIm = sin(w)
    }

    /// Frequenzsuche neu starten (nach Verlust des Signals)
    public func reacquire() {
        coarseDone = false
        spectrumBlocks = 0
        for i in 0..<spectrum.count { spectrum[i] = 0 }
        acquired = false
    }

    public func reset() {
        decimator?.reset()
        matched.reset()
        zI.removeAll(); zQ.removeAll(); zBase = 0
        timingInitialised = false
        havePrev = false
        tuneHz = nominalOffsetHz
        updateStep()
        reacquire()
    }

    // MARK: Eingang

    public func process(i: UnsafeBufferPointer<Float>, q: UnsafeBufferPointer<Float>) {
        // In Stücken, damit die Frequenznachführung zwischen den Stücken wirkt (sonst gilt eine Korrektur mehrfach für dieselben Daten)
        let n = min(i.count, q.count)
        let piece = max(256, Self.blockSize * decimation / 2)
        var start = 0
        while start < n {
            let m = min(piece, n - start)
            processPiece(i: UnsafeBufferPointer(rebasing: i[start..<(start + m)]), q: UnsafeBufferPointer(rebasing: q[start..<(start + m)]))
            start += m
        }
    }

    private func processPiece(i: UnsafeBufferPointer<Float>, q: UnsafeBufferPointer<Float>) {
        let n = min(i.count, q.count)
        guard n > 0 else { return }
        if mixI.count < n { mixI = [Float](repeating: 0, count: n); mixQ = mixI }
        // Mischen
        var re = oscRe, im = oscIm
        let sr = stepRe, si = stepIm
        mixI.withUnsafeMutableBufferPointer { mi in
            mixQ.withUnsafeMutableBufferPointer { mq in
                for k in 0..<n {
                    let a = Double(i[k]), b = Double(q[k])
                    mi[k] = Float(a * re - b * im)
                    mq[k] = Float(a * im + b * re)
                    let nr = re * sr - im * si
                    im = re * si + im * sr
                    re = nr
                }
            }
        }
        renorm += n
        if renorm >= 1 << 14 {
            let m = sqrt(re * re + im * im)
            re /= m; im /= m
            renorm = 0
        }
        oscRe = re; oscIm = im
        // Dezimieren
        z0I.removeAll(keepingCapacity: true)
        z0Q.removeAll(keepingCapacity: true)
        mixI.withUnsafeBufferPointer { mi in
            mixQ.withUnsafeBufferPointer { mq in
                if let d = decimator {
                    d.process(i: mi.baseAddress!, q: mq.baseAddress!, count: n, outI: &z0I, outQ: &z0Q)
                } else {
                    z0I.append(contentsOf: mi[0..<n])
                    z0Q.append(contentsOf: mq[0..<n])
                }
            }
        }
        guard !z0I.isEmpty else { return }
        // Pegel und Spektrum
        var p: Float = 0
        vDSP_svesq(z0I, 1, &p, vDSP_Length(z0I.count))
        var p2: Float = 0
        vDSP_svesq(z0Q, 1, &p2, vDSP_Length(z0Q.count))
        let power = Double(p + p2) / Double(z0I.count)
        powerDB += (10 * log10(power + 1e-12) - powerDB) * 0.2
        if !coarseDone { accumulateSpectrum() }
        // Angepasstes Filter
        var f1I: [Float] = [], f1Q: [Float] = []
        f1I.reserveCapacity(z0I.count); f1Q.reserveCapacity(z0I.count)
        z0I.withUnsafeBufferPointer { a in
            z0Q.withUnsafeBufferPointer { b in
                matched.process(i: a.baseAddress!, q: b.baseAddress!, count: a.count, outI: &f1I, outQ: &f1Q)
            }
        }
        zI.append(contentsOf: f1I)
        zQ.append(contentsOf: f1Q)
        while zI.count >= Self.blockSize + 8 { processBlock() }
    }

    // MARK: Grobsuche

    private func accumulateSpectrum() {
        let n = 1024
        var idx = 0
        while idx + n <= z0I.count {
            // Hann-Fenster, FFT
            var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
            for k in 0..<n {
                let w = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(k) / Double(n)))
                re[k] = z0I[idx + k] * w
                im[k] = z0Q[idx + k] * w
            }
            fft(&re, &im)
            for k in 0..<n { spectrum[k] += re[k] * re[k] + im[k] * im[k] }
            spectrumBlocks += 1
            idx += n
            if spectrumBlocks >= 16 {
                finishCoarse()
                return
            }
        }
    }

    private func fft(_ re: inout [Float], _ im: inout [Float]) {
        guard let setup = fftSetup else { return }
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, 10, FFTDirection(FFT_FORWARD))
            }
        }
    }

    private func finishCoarse() {
        coarseDone = true
        let n = spectrum.count
        let binHz = rate1 / Double(n)
        // PSD in Frequenzordnung (−rate/2 … +rate/2)
        var psd = [Double](repeating: 0, count: n)
        for k in 0..<n { psd[(k + n / 2) % n] = Double(spectrum[k]) }
        // Rauschteppich: kleinster Mittelwert über 16 benachbarte Bins
        var floorLevel = Double.greatestFiniteMagnitude
        for s in stride(from: 0, to: n - 16, by: 8) {
            let m = psd[s..<(s + 16)].reduce(0, +) / 16
            if m < floorLevel { floorLevel = m }
        }
        // Schwerpunkt in ±16 kHz um die laufende Schätzung (Mitte = Bin n/2)
        var centre = 0.0
        for _ in 0..<4 {
            var sw = 0.0, sf = 0.0
            let lo = Int((centre - 16_000) / binHz) + n / 2, hi = Int((centre + 16_000) / binHz) + n / 2
            for k in max(0, lo)..<min(n, hi) {
                let w = max(0, psd[k] - 2 * floorLevel)
                sw += w
                sf += w * Double(k - n / 2) * binHz
            }
            if sw > 0 { centre = sf / sw }
        }
        let total = psd.reduce(0, +)
        let inBand = psd[max(0, Int((centre - 12_000) / binHz) + n / 2)..<min(n, Int((centre + 12_000) / binHz) + n / 2)].reduce(0, +)
        // Nur übernehmen, wenn im Band deutlich mehr Leistung steckt als im Rauschen und die Verschiebung plausibel ist
        let bandBins = 24_000 / binHz
        if inBand > 3 * floorLevel * bandBins && abs(centre) < 9_000 && total > 0 {
            tuneHz += centre
            updateStep()
            acquired = true
        }
        // Spektrum verwerfen
        for i in 0..<spectrum.count { spectrum[i] = 0 }
    }

    // MARK: Block

    private func cubic(_ a: [Float], _ p: Double, _ base: Int) -> Float {
        // Catmull-Rom zwischen a[i] und a[i+1], Lage p (relativ zu `base`)
        let i = Int(p.rounded(.down)) - base
        let f = Float(p - Double(Int(p.rounded(.down))))
        let y0 = a[i - 1], y1 = a[i], y2 = a[i + 1], y3 = a[i + 2]
        let c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return ((c3 * f + c2) * f + c1) * f + y1
    }

    private func processBlock() {
        let b = Self.blockSize
        // Zeittakt: Hüllkurve bei der Symbolrate
        var cr: Float = 0, ci: Float = 0
        for k in 0..<b {
            let e = zI[k] * zI[k] + zQ[k] * zQ[k]
            cr += e * timingTable[k].0
            ci += e * timingTable[k].1
        }
        let k0 = -atan2(Double(ci), Double(cr)) / (2 * Double.pi) * sps      // Lage der Hüllkurvenspitze, relativ zum Blockanfang
        let blockStart = Double(zBase)
        if !timingInitialised {
            pos = blockStart + (k0 < 0 ? k0 + sps : k0)
            timingInitialised = true
        } else {
            // Vorhersage nahe der Blockmitte gegen Messung
            let centre = blockStart + Double(b) / 2
            let pc = pos + sps * ((centre - pos) / sps).rounded()
            let est = blockStart + k0 + sps * ((pc - blockStart - k0) / sps).rounded()
            var e = est - pc
            if e > sps / 2 { e -= sps }
            if e < -sps / 2 { e += sps }
            pos += 0.4 * e
            spsEff += 0.002 * e / Double(b) * sps
            let limit = sps * 1e-3
            spsEff = min(max(spsEff, sps - limit), sps + limit)
        }
        // Symbole entnehmen
        var out: [SoftBit] = []
        out.reserveCapacity(b / 2)
        let limit = blockStart + Double(b)
        var acc = (re: 0.0, im: 0.0)
        var count = 0
        while pos < limit {
            let rel = pos - Double(zBase)
            if rel < 1 { pos += spsEff; continue }
            let si = cubic(zI, pos, zBase)
            let sq = cubic(zQ, pos, zBase)
            let pw = si * si + sq * sq
            meanPower += (pw - meanPower) * 0.01
            if havePrev {
                // Differenz: s · conj(prev)
                let dr = si * prevI + sq * prevQ
                let di = sq * prevI - si * prevQ
                let norm = max(meanPower, 1e-12)
                let sr = dr / norm, sim = di / norm
                // Bits: b0 = 1 bei Im < 0; b1 = 1 bei Re < 0 (Sollpunkte bei ±0,707)
                let scale: Float = 160
                out.append(SoftBit(max(-127, min(127, Int(sim * scale)))))
                out.append(SoftBit(max(-127, min(127, Int(sr * scale)))))
                // 4. Potenz der normierten Differenz
                let mag = (dr * dr + di * di).squareRoot()
                if mag > 1e-9 {
                    let ur = Double(dr / mag), ui = Double(di / mag)
                    let r2 = ur * ur - ui * ui, i2 = 2 * ur * ui
                    acc.re += r2 * r2 - i2 * i2
                    acc.im += 2 * r2 * i2
                    count += 1
                }
            }
            prevI = si; prevQ = sq
            havePrev = true
            pos += spsEff
        }
        // Frequenzfehler: dd⁴ = −e^{j4δ}
        if count > 64 {
            let mag = (acc.re * acc.re + acc.im * acc.im).squareRoot() / Double(count)
            coherence += (mag - coherence) * 0.3
            if mag > 0.25 && coarseDone {
                let delta = atan2(-acc.im, -acc.re) / 4          // Phase je Symbol
                let hz = delta / (2 * Double.pi) * TETRA.symbolRate
                offsetErrorHz = hz
                tuneHz += 0.5 * hz
                updateStep()
            }
        }
        symbolsOut += out.count / 2
        // Block verwerfen (4 Werte Vorlauf behalten)
        let drop = b - 4
        zI.removeFirst(drop)
        zQ.removeFirst(drop)
        zBase += drop
        if !out.isEmpty { onBits?(out) }
    }
}
