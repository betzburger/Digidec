// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Accelerate

/// FFT mit 2048 Punkten auf getrennten Real- und Imaginärfeldern
final class DABFFT {
    private let setup: FFTSetup
    private let log2n = vDSP_Length(11)
    let size = DABMode1.fftSize

    init() { setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))! }
    deinit { vDSP_destroy_fftsetup(setup) }

    func forward(_ re: inout [Float], _ im: inout [Float]) { run(&re, &im, FFTDirection(FFT_FORWARD)) }
    /// Rücktransformation ohne Skalierung
    func inverse(_ re: inout [Float], _ im: inout [Float]) { run(&re, &im, FFTDirection(FFT_INVERSE)) }

    private func run(_ re: inout [Float], _ im: inout [Float], _ dir: FFTDirection) {
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, dir)
            }
        }
    }
}

/// OFDM-Empfänger für DAB (Übertragungsmodus I) aus 8-Bit-I/Q mit 2,048 MS/s:
/// Nullsymbol-Suche, Zeitsynchronisation über das Phasenbezugssymbol, Frequenzkorrektur (grob in 1-kHz-Schritten aus dem Phasenbezugssymbol,
/// fein aus dem Schutzintervall), Demodulation der differentiellen QPSK-Träger zu weichen Bits.
public final class DABOFDMReceiver {
    /// Weiche Bits eines Symbols (3072 Werte, Symbole 1 … 75; Symbole 1 bis 3 sind der FIC)
    public var onSymbol: ((Int, UnsafeBufferPointer<Int8>) -> Void)?
    /// Ein Rahmen ist ganz verarbeitet
    public var onFrame: (() -> Void)?
    /// Der Empfänger hat die Synchronisation gewonnen oder verloren
    public var onSyncChange: ((Bool) -> Void)?

    public private(set) var isSynced = false
    public private(set) var snrDB = 0.0
    public private(set) var frameCount = 0
    public private(set) var coarseHz = 0.0
    public private(set) var fineHz = 0.0
    /// Abstand der Nullsymbole (Rahmenlänge) wird gemessen: Abweichung des Abtasttakts in ppm
    public private(set) var clockOffsetPPM = 0.0

    // Abtastwerte
    private var bufI: [Float] = [], bufQ: [Float] = []
    /// Absoluter Index des ersten Werts in `bufI`
    private var base = 0
    // Suche
    private var level = 0.0
    private var scan = 0
    private var dipPos = -1
    // Zustand
    private var predictedGuard = 0            // absoluter Index, wo das Schutzintervall des Phasenbezugssymbols erwartet wird
    private var failures = 0

    private let fft = DABFFT()
    private let reference = DABTables.referenceSpectrum
    private var prevRe = [Float](repeating: 0, count: DABMode1.fftSize)
    private var prevIm = [Float](repeating: 0, count: DABMode1.fftSize)
    private var wRe = [Float](repeating: 0, count: DABMode1.fftSize)
    private var wIm = [Float](repeating: 0, count: DABMode1.fftSize)
    private var rotI: [Float] = [], rotQ: [Float] = []
    private var bits = [Int8](repeating: 0, count: DABMode1.bitsPerSymbol)
    private let interleaver = DABTables.frequencyInterleaver
    private var lastPRSStart = -1

    public init() {}

    public func reset() {
        bufI.removeAll(); bufQ.removeAll(); base = 0; scan = 0; dipPos = -1; level = 0
        setSynced(false)
        failures = 0; frameCount = 0; coarseHz = 0; fineHz = 0
    }

    private func setSynced(_ s: Bool) {
        guard s != isSynced else { return }
        isSynced = s
        onSyncChange?(s)
    }

    // MARK: Eingang

    /// Rohdaten (8 Bit, vorzeichenlos, I und Q abwechselnd) verarbeiten
    public func process(_ bytes: UnsafeBufferPointer<UInt8>) {
        let n = bytes.count / 2
        let old = bufI.count
        bufI.append(contentsOf: repeatElement(0, count: n))
        bufQ.append(contentsOf: repeatElement(0, count: n))
        bufI.withUnsafeMutableBufferPointer { bi in
            bufQ.withUnsafeMutableBufferPointer { bq in
                for k in 0..<n {
                    bi[old + k] = (Float(bytes[2 * k]) - 127.5) * (1.0 / 127.5)
                    bq[old + k] = (Float(bytes[2 * k + 1]) - 127.5) * (1.0 / 127.5)
                }
            }
        }
        run()
        trim()
    }

    private func trim() {
        // alles vor der Stelle, die noch gebraucht wird, verwerfen
        let keepFrom: Int
        if isSynced { keepFrom = predictedGuard - 600 } else { keepFrom = scan - 4096 }
        let drop = keepFrom - base
        if drop > 200_000 {
            bufI.removeFirst(drop)
            bufQ.removeFirst(drop)
            base += drop
        }
    }

    // MARK: Ablauf

    private func run() {
        while true {
            if isSynced {
                guard processFrame() else { return }
            } else {
                guard search() else { return }
            }
        }
    }

    /// Suche nach dem Nullsymbol und dem Phasenbezugssymbol. `false`, wenn mehr Daten nötig sind.
    private func search() -> Bool {
        let count = bufI.count
        let start = max(scan - base, 0)
        guard count - start > DABMode1.frameLength + 4096 else { return false }
        // langfristiger Mittelwert der Hüllkurve
        var sum = 0.0
        var step = start
        var seen = 0
        while step < count { sum += Double(Swift.abs(bufI[step]) + Swift.abs(bufQ[step])); step += 37; seen += 1 }
        level = sum / Double(max(seen, 1))
        guard level > 1e-4 else { scan = base + count - DABMode1.frameLength; return true }

        var pos = start
        var window = 0.0
        for k in 0..<50 { window += Double(Swift.abs(bufI[pos + k]) + Swift.abs(bufQ[pos + k])) }
        var dip = dipPos >= 0 ? dipPos - base : -1
        var endPos = -1
        while pos + 50 < count - DABMode1.symbolLength {
            let avg = window / 50
            if dip < 0 {
                if avg < 0.5 * level { dip = pos }
            } else if avg > 0.75 * level {
                endPos = pos
                break
            }
            window += Double(Swift.abs(bufI[pos + 50]) + Swift.abs(bufQ[pos + 50])) - Double(Swift.abs(bufI[pos]) + Swift.abs(bufQ[pos]))
            pos += 1
            if dip >= 0 && pos - dip > 6000 { dip = -1 }       // zu lang für ein Nullsymbol
        }
        guard endPos >= 0 else {
            scan = base + pos
            dipPos = dip >= 0 ? base + dip : -1
            return false
        }
        dipPos = -1
        scan = base + endPos + 1000
        let nullLength = endPos - dip
        guard dip >= 0, nullLength > 1500, nullLength < 4200 else { return true }

        // Fenster im Schutzintervall des Phasenbezugssymbols
        let q = endPos + 30
        guard q + DABMode1.fftSize + 10 < count else { return false }
        guard let (idx, shift, ratio) = correlate(windowStart: q, scanShifts: true) else { return true }
        guard ratio > 3 else { return true }
        coarseHz += Double(shift) * DABMode1.carrierSpacingHz
        fineHz = 0
        let useful = base + q + idx
        predictedGuard = useful - DABMode1.guardLength
        failures = 0
        frameCount = 0
        lastPRSStart = -1
        setSynced(true)
        return true
    }

    /// Korrelation eines 2048er-Fensters mit dem Phasenbezugssymbol. Rückgabe: Index der Spitze, beste 1-kHz-Verschiebung und Spitze/Mittelwert.
    private func correlate(windowStart: Int, scanShifts: Bool) -> (Int, Int, Double)? {
        let n = DABMode1.fftSize
        guard windowStart >= 0, windowStart + n <= bufI.count else { return nil }
        // Fenster, mit der aktuellen Frequenzkorrektur entdreht
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        derotate(from: windowStart, count: n, intoI: &re, intoQ: &im)
        fft.forward(&re, &im)
        let shifts = scanShifts ? Array(-12...12) : [0]
        var best: (Int, Int, Double)? = nil
        var yRe = [Float](repeating: 0, count: n), yIm = [Float](repeating: 0, count: n)
        for s in shifts {
            for i in 0..<n {
                let j = (i + s + n) % n
                // X[j] * conj(R[i])
                yRe[i] = re[j] * reference.re[i] + im[j] * reference.im[i]
                yIm[i] = im[j] * reference.re[i] - re[j] * reference.im[i]
            }
            fft.inverse(&yRe, &yIm)
            var peak: Float = 0, peakIdx = 0, total: Float = 0
            for i in 0..<n {
                let m = (yRe[i] * yRe[i] + yIm[i] * yIm[i]).squareRoot()
                total += m
                if m > peak { peak = m; peakIdx = i }
            }
            let ratio = total > 0 ? Double(peak) * Double(n) / Double(total) : 0
            if best == nil || ratio > best!.2 { best = (peakIdx, s, ratio) }
        }
        return best
    }

    /// Abtastwerte ab Pufferstelle `from` mit der Frequenzkorrektur (Grob + Fein) entdreht
    private func derotate(from: Int, count: Int, intoI outI: inout [Float], intoQ outQ: inout [Float]) {
        let f = coarseHz + fineHz
        let w = 2 * Double.pi * f / Double(DABMode1.sampleRate)
        var phase = -w * Double(base + from)
        phase = phase.truncatingRemainder(dividingBy: 2 * Double.pi)
        var r = cos(phase), m = sin(phase)
        let sr = cos(-w), si = sin(-w)
        for k in 0..<count {
            let x = Double(bufI[from + k]), y = Double(bufQ[from + k])
            outI[k] = Float(x * r - y * m)
            outQ[k] = Float(x * m + y * r)
            let nr = r * sr - m * si
            m = r * si + m * sr
            r = nr
        }
    }

    /// Ein Rahmen ab dem vorhergesagten Phasenbezugssymbol. `false`, wenn mehr Daten nötig sind.
    private func processFrame() -> Bool {
        let n = DABMode1.fftSize
        let dataLength = n + (DABMode1.symbolsPerFrame - 1) * DABMode1.symbolLength     // Phasenbezugssymbol (Nutzteil) und 75 Datensymbole
        let guardStartRel = predictedGuard - base
        // Fenster in der Mitte des Schutzintervalls
        let windowStart = guardStartRel + DABMode1.guardLength / 2
        guard windowStart >= 0 else { resync(); return true }
        guard windowStart + dataLength + DABMode1.guardLength < bufI.count else { return false }
        guard let (idx, _, ratio) = correlate(windowStart: windowStart, scanShifts: false) else { resync(); return true }
        let delta = idx - DABMode1.guardLength / 2
        if ratio < 3 || Swift.abs(delta) > 220 {
            failures += 1
            if failures > 4 { resync(); return true }
            // Rahmen überspringen
            predictedGuard += DABMode1.frameLength
            return true
        }
        failures = 0
        let useful = windowStart + idx                            // Pufferindex des Nutzteils des Phasenbezugssymbols
        let usefulAbs = base + useful
        if lastPRSStart >= 0 {
            let spacing = usefulAbs - lastPRSStart
            clockOffsetPPM = (Double(spacing) / Double(DABMode1.frameLength) - 1) * 1e6
        }
        lastPRSStart = usefulAbs

        // gesamten Rahmen entdrehen
        if rotI.count < dataLength { rotI = [Float](repeating: 0, count: dataLength); rotQ = [Float](repeating: 0, count: dataLength) }
        derotate(from: useful, count: dataLength, intoI: &rotI, intoQ: &rotQ)

        // Phasenbezugssymbol: Referenz für das erste Datensymbol
        for k in 0..<n { wRe[k] = rotI[k]; wIm[k] = rotQ[k] }
        fft.forward(&wRe, &wIm)
        prevRe = wRe; prevIm = wIm
        updateSNR(wRe, wIm)

        var corrRe = 0.0, corrIm = 0.0
        let tu = DABMode1.fftSize, tg = DABMode1.guardLength
        for sym in 1..<DABMode1.symbolsPerFrame {
            let gs = n + (sym - 1) * DABMode1.symbolLength            // Anfang des Schutzintervalls (in `rot`)
            for k in 0..<tg {
                let ar = Double(rotI[gs + tu + k]), ai = Double(rotQ[gs + tu + k])
                let br = Double(rotI[gs + k]), bi = Double(rotQ[gs + k])
                corrRe += ar * br + ai * bi
                corrIm += ai * br - ar * bi
            }
            for k in 0..<tu { wRe[k] = rotI[gs + tg + k]; wIm[k] = rotQ[gs + tg + k] }
            fft.forward(&wRe, &wIm)
            demodulate(symbol: sym)
        }
        // feine Frequenz: Winkel der Korrelation von Schutzintervall und Symbolende
        let angle = atan2(corrIm, corrRe)
        let gain = frameCount < 6 ? 0.5 : 0.1
        fineHz += gain * angle / Double.pi * (DABMode1.carrierSpacingHz / 2)
        if fineHz > DABMode1.carrierSpacingHz / 2 { coarseHz += DABMode1.carrierSpacingHz; fineHz -= DABMode1.carrierSpacingHz }
        else if fineHz < -DABMode1.carrierSpacingHz / 2 { coarseHz -= DABMode1.carrierSpacingHz; fineHz += DABMode1.carrierSpacingHz }
        frameCount += 1
        predictedGuard = usefulAbs - DABMode1.guardLength + DABMode1.frameLength
        onFrame?()
        return true
    }

    private func resync() {
        setSynced(false)
        failures = 0
        scan = max(predictedGuard, base)
        dipPos = -1
    }

    /// Träger des Symbols (in `wRe`/`wIm`) gegen den Vorgänger demodulieren und als weiche Bits abgeben
    private func demodulate(symbol: Int) {
        let n = DABMode1.fftSize, k = DABMode1.carriers
        for i in 0..<k {
            var index = interleaver[i]
            if index < 0 { index += n }
            let xr = wRe[index], xi = wIm[index]
            // r1 = X * conj(prev)
            let rr = xr * prevRe[index] + xi * prevIm[index]
            let ri = xi * prevRe[index] - xr * prevIm[index]
            prevRe[index] = xr; prevIm[index] = xi
            let norm = Swift.abs(rr) + Swift.abs(ri)
            let scale = norm > 0 ? 127 / norm : 0
            bits[i] = Int8(max(-127, min(127, -rr * scale)))
            bits[k + i] = Int8(max(-127, min(127, -ri * scale)))
        }
        bits.withUnsafeBufferPointer { onSymbol?(symbol, $0) }
    }

    /// Träger gegen Rauschen neben dem Band (Bins 790 … 950 beiderseits der Mitte)
    private func updateSNR(_ re: [Float], _ im: [Float]) {
        var sig = 0.0, noise = 0.0
        for kk in 1...(DABMode1.carriers / 2) {
            let a = kk, b = DABMode1.fftSize - kk
            sig += Double(re[a] * re[a] + im[a] * im[a]) + Double(re[b] * re[b] + im[b] * im[b])
        }
        sig /= Double(DABMode1.carriers)
        var count = 0
        for kk in 790...950 {
            let a = kk, b = DABMode1.fftSize - kk
            noise += Double(re[a] * re[a] + im[a] * im[a]) + Double(re[b] * re[b] + im[b] * im[b])
            count += 2
        }
        noise /= Double(count)
        let snr = 10 * log10(max(sig, 1e-12) / max(noise, 1e-12))
        snrDB = frameCount == 0 ? snr : snrDB * 0.8 + snr * 0.2
    }
}
