// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// D8PSK-Demodulator für VDL Mode 2 nach dem Vorbild von dumpvdl2 (Tomasz Lemiech SP5WWP, GPL-3.0).
//
// Eingang: I/Q mit beliebiger Abtastrate (ab 105 kS/s), eine Kanalfrequenz relativ zur Mitte. Je Kanal:
//   Mischen auf 0 Hz → CIC-Dezimation (Ordnung 3, auf 200 … 400 kS/s) → Tschebyscheff-Tiefpass 2. Ordnung (8 kHz) →
//   lineare Neuabtastung auf 105 kS/s (10 Abtastwerte je Symbol) → Präambelsuche → Differenzphase je Symbol → Bits.

/// Entwurf des Tschebyscheff-Tiefpasses (nach S. W. Smith, „The Scientist and Engineer's Guide to DSP“, wie `chebyshev.c`)
enum Chebyshev {
    /// Koeffizienten `a[0...npoles]` und `b[1...npoles]` des rekursiven Filters
    /// y[n] = Σ a[i]·x[n−i] + Σ b[i]·y[n−i]; `cutoff` ist der Bruchteil der Abtastrate (0 … 0,5), `ripple` in Prozent
    static func lowpass(cutoff: Double, ripple: Double, poles: Int) -> (a: [Double], b: [Double]) {
        precondition(poles > 0 && poles % 2 == 0)
        let size = 20 + 3
        var A = [Double](repeating: 0, count: size)
        var B = [Double](repeating: 0, count: size)
        A[2] = 1
        B[2] = 1
        for p in 1...(poles / 2) {
            let (aa, bb) = pole(p, cutoff: cutoff, ripple: ripple, poles: poles)
            let ta = A, tb = B
            for i in 2..<size {
                A[i] = aa[0] * ta[i] + aa[1] * ta[i - 1] + aa[2] * ta[i - 2]
                B[i] = tb[i] - bb[1] * tb[i - 1] - bb[2] * tb[i - 2]
            }
        }
        B[2] = 0
        for i in 0..<(size - 2) {
            A[i] = A[i + 2]
            B[i] = -B[i + 2]
        }
        var sa = 0.0, sb = 0.0
        for i in 0..<(size - 2) { sa += A[i]; sb += B[i] }
        let gain = sa / (1 - sb)
        for i in 0..<(size - 2) { A[i] /= gain }
        return (Array(A[0...poles]), Array(B[0...poles]))
    }

    private static func pole(_ p: Int, cutoff: Double, ripple: Double, poles: Int) -> ([Double], [Double]) {
        let angle = Double.pi / Double(2 * poles) + Double(p - 1) * Double.pi / Double(poles)
        var ip = sin(angle)
        var rp = -cos(angle)
        if ripple != 0 {
            let n = Double(poles)
            let es = sqrt(pow(100 / (100 - ripple), 2) - 1)
            let vx = (1 / n) * log(1 / es + sqrt(1 / (es * es) + 1))
            var kx = (1 / n) * log(1 / es + sqrt(1 / (es * es) - 1))
            kx = (exp(kx) + exp(-kx)) / 2
            rp *= ((exp(vx) - exp(-vx)) / 2) / kx
            ip *= ((exp(vx) + exp(-vx)) / 2) / kx
        }
        let t = 2 * tan(0.5)
        let w = 2 * Double.pi * cutoff
        let m = rp * rp + ip * ip
        var d = 4 - 4 * rp * t + m * t * t
        let x0 = t * t / d
        let x1 = 2 * x0
        let x2 = x0
        let y1 = (8 - 2 * m * t * t) / d
        let y2 = (-4 - 4 * rp * t - m * t * t) / d
        let k = sin(0.5 - w / 2) / sin(0.5 + w / 2)
        d = 1 + y1 * k - y2 * k * k
        var aa = [Double](repeating: 0, count: 3)
        var bb = [Double](repeating: 0, count: 3)
        aa[0] = (x0 - x1 * k + x2 * k * k) / d
        aa[1] = (-2 * x0 * k + x1 + x1 * k * k - 2 * x2 * k) / d
        aa[2] = (x0 * k * k - x1 * k + x2) / d
        bb[1] = (2 * k + y1 + y1 * k * k - 2 * y2 * k) / d
        bb[2] = (-(k * k) - y1 * k + y2) / d
        return (aa, bb)
    }
}

/// Ein decodierter Burst eines Kanals
public struct VDL2Burst: Sendable {
    public var time: Date
    public var frequency: Double
    public var frames: [AVLCFrame]
    public var levelDB: Double
    public var noiseDB: Double
    public var ppm: Double
    public var corrections: Int
    public var headerSyndromeWeight: Int
}

public struct VDL2Statistics: Sendable, Equatable {
    public var syncs = 0
    public var headersOK = 0
    public var headerErrors = 0
    public var fecErrors = 0
    public var framingErrors = 0
    public var badFCS = 0
    public var frames = 0
    public var bursts = 0
}

/// Demodulator und Decodierer für einen Kanal
public final class VDL2Channel: @unchecked Sendable {
    public let frequency: Double
    public let offset: Double
    public let sampleRate: Double
    public var onBurst: ((VDL2Burst) -> Void)?
    public var now: () -> Date = { Date() }
    public private(set) var statistics = VDL2Statistics()
    public var maxPPM: Double = 0

    // Vorstufe
    private let decimation: Int
    private let rate1: Double
    private var oscRe = 1.0, oscIm = 0.0
    private let stepRe: Double, stepIm: Double
    private var renorm = 0
    private var cicInt = [Int32](repeating: 0, count: 6)       // 3 Integratoren je Achse (I: 0…2, Q: 3…5)
    private var cicComb = [Int32](repeating: 0, count: 6)
    private var cicCount = 0
    private static let cicScale = 1_048_576.0

    // Tiefpass
    private let fa: [Double], fb: [Double]
    private var xr = [Double](repeating: 0, count: 3), xi = [Double](repeating: 0, count: 3)
    private var yr = [Double](repeating: 0, count: 3), yi = [Double](repeating: 0, count: 3)

    // Neuabtastung auf 105 kS/s
    private let step: Double                    // Eingangsabtastwerte je Ausgangsabtastwert
    private var position = 0.0                  // Abstand des nächsten Ausgangs vom zuletzt gelesenen Wert (in Eingangswerten)
    private var prevRe = 0.0, prevIm = 0.0

    // Demodulator
    private static let syncSkip = 3
    private static let syncThreshold = 4.0
    private static let phaseErrorMax = 1000.0
    private static let magLP = 0.9
    private static let nfLP = 0.85
    private static let preambleSymbols = VDL2.preambleSymbols
    private static let sps = VDL2.samplesPerSymbol
    private static let syncLen = preambleSymbols * sps
    private static let gray: [UInt8] = [0, 1, 3, 2, 6, 7, 5, 4]
    private static let preamblePhase: [Double] = [0, 3, -3, 1, 1, 2, 0, 4, -3, 4, -2, 3, 1, -2, -3, 0].map { $0 * Double.pi / 4 }
    private static let lrX: [Double] = {
        let mean = Double(preambleSymbols - 1) / 2
        return (0..<preambleSymbols).map { Double($0) - mean }
    }()
    private static let lrDenom: Double = lrX.reduce(0) { $0 + $1 * $1 }

    private enum DemodState { case initial, sync }
    private enum DecoderState { case header, data, idle }
    private var demodState = DemodState.initial
    private var decoderState = DecoderState.header
    private var syncBuf = [Double](repeating: 0, count: syncLen)
    private var syncIdx = 0
    private var sclk = 0
    private var phaseErr = [Double](repeating: phaseErrorMax, count: 3)
    private var prevDphi = 0.0
    private var dphi = 0.0
    private var prevPhi = 0.0
    private var ppmError = 0.0
    private var magLP = 0.0
    private var magNF = 2.0
    private var nfCount = 0
    private var framePower = 0.0
    private var framePowerCount = 0
    private var burstTime = Date()
    private var powerLP = 0.0
    /// Mittlere Leistung des gefilterten Kanals (dB gegen Vollaussteuerung) und geschätzter Rauschboden
    public var powerDB: Double { 10 * log10(powerLP + 1e-12) }
    public var noiseDB: Double { 20 * log10(magNF + 0.001) }

    // Decoder
    private var bits: [UInt8] = []
    private var lfsr = VDL2.scramblerStart
    private var scrambledTo = 0
    private var header: VDL2.Header?
    private var requestedBits = VDL2.headerBits

    public init(frequency: Double, centerFrequency: Double, sampleRate: Double) {
        self.frequency = frequency
        self.offset = frequency - centerFrequency
        self.sampleRate = sampleRate
        decimation = max(1, Int((sampleRate / 250_000).rounded()))
        rate1 = sampleRate / Double(decimation)
        let w = -2 * Double.pi * offset / sampleRate
        stepRe = cos(w)
        stepIm = sin(w)
        let (a, b) = Chebyshev.lowpass(cutoff: 8000 / rate1, ripple: 0.5, poles: 2)
        fa = a
        fb = b
        step = rate1 / (VDL2.symbolRate * Double(VDL2.samplesPerSymbol))
        reset()
    }

    public static func isSupported(sampleRate: Double) -> Bool { sampleRate >= 105_000 }

    public func reset() {
        for i in 0..<3 { xr[i] = 0; xi[i] = 0; yr[i] = 0; yi[i] = 0 }
        for i in 0..<6 { cicInt[i] = 0; cicComb[i] = 0 }
        cicCount = 0
        position = 0
        prevRe = 0; prevIm = 0
        magLP = 0
        magNF = 2
        nfCount = 0
        powerLP = 0
        demodReset()
    }

    private func demodReset() {
        decoderReset()
        sclk = 0
        demodState = .initial
        phaseErr[1] = Self.phaseErrorMax
        phaseErr[2] = Self.phaseErrorMax
        framePower = 0
        framePowerCount = 0
    }

    private func decoderReset() {
        decoderState = .header
        requestedBits = VDL2.headerBits
        bits.removeAll(keepingCapacity: true)
        lfsr = VDL2.scramblerStart
        scrambledTo = 0
        header = nil
    }

    // MARK: Eingang

    /// I/Q-Werte (je ±1 voll ausgesteuert) verarbeiten
    public func process(i: UnsafeBufferPointer<Float>, q: UnsafeBufferPointer<Float>) {
        let n = min(i.count, q.count)
        let shifted = offset != 0
        let cic = decimation > 1
        let scale = Self.cicScale
        let norm = 1.0 / (scale * Double(decimation * decimation * decimation))
        for k in 0..<n {
            var re = Double(i[k]), im = Double(q[k])
            if shifted {
                let r = re * oscRe - im * oscIm
                let m = im * oscRe + re * oscIm
                re = r; im = m
                let nr = oscRe * stepRe - oscIm * stepIm
                oscIm = oscIm * stepRe + oscRe * stepIm
                oscRe = nr
                renorm += 1
                if renorm == 4096 {
                    renorm = 0
                    let mag = 1 / (oscRe * oscRe + oscIm * oscIm).squareRoot()
                    oscRe *= mag; oscIm *= mag
                }
            }
            if cic {
                var v0 = Int32(truncatingIfNeeded: Int64((re * scale).rounded()))
                var v1 = Int32(truncatingIfNeeded: Int64((im * scale).rounded()))
                cicInt[0] = cicInt[0] &+ v0
                cicInt[1] = cicInt[1] &+ cicInt[0]
                cicInt[2] = cicInt[2] &+ cicInt[1]
                cicInt[3] = cicInt[3] &+ v1
                cicInt[4] = cicInt[4] &+ cicInt[3]
                cicInt[5] = cicInt[5] &+ cicInt[4]
                cicCount += 1
                if cicCount < decimation { continue }
                cicCount = 0
                // Kämme
                v0 = cicInt[2]
                var t = v0 &- cicComb[0]; cicComb[0] = v0; v0 = t
                t = v0 &- cicComb[1]; cicComb[1] = v0; v0 = t
                t = v0 &- cicComb[2]; cicComb[2] = v0; v0 = t
                v1 = cicInt[5]
                t = v1 &- cicComb[3]; cicComb[3] = v1; v1 = t
                t = v1 &- cicComb[4]; cicComb[4] = v1; v1 = t
                t = v1 &- cicComb[5]; cicComb[5] = v1; v1 = t
                re = Double(v0) * norm
                im = Double(v1) * norm
            }
            stage2(re, im)
        }
    }

    /// Tiefpass und Neuabtastung
    private func stage2(_ re: Double, _ im: Double) {
        xr[2] = xr[1]; xr[1] = xr[0]; xr[0] = re
        xi[2] = xi[1]; xi[1] = xi[0]; xi[0] = im
        yr[2] = yr[1]; yr[1] = yr[0]
        yi[2] = yi[1]; yi[1] = yi[0]
        yr[0] = fa[0] * xr[0] + fa[1] * xr[1] + fa[2] * xr[2] + fb[1] * yr[1] + fb[2] * yr[2]
        yi[0] = fa[0] * xi[0] + fa[1] * xi[1] + fa[2] * xi[2] + fb[1] * yi[1] + fb[2] * yi[2]
        // Lineare Interpolation zwischen vorherigem und aktuellem Wert
        let cr = yr[0], ci = yi[0]
        while position < 1 {
            // Ausgabe bei Bruchteil `position` zwischen prev (0) und cur (1)
            let frac = position
            let or = prevRe + (cr - prevRe) * frac
            let oi = prevIm + (ci - prevIm) * frac
            position += step
            demod(or, oi)
        }
        position -= 1
        prevRe = cr; prevIm = ci
    }

    // MARK: Präambel

    private func gotSync() -> Bool {
        let n = Self.preambleSymbols
        let sps = Self.sps
        let len = Self.syncLen
        var errvec = [Double](repeating: 0, count: n)
        var unwrap = 0.0
        var prevErr = syncBuf[(syncIdx + sps) % len] - Self.preamblePhase[0]
        errvec[0] = prevErr
        var mean = prevErr
        for k in 1..<n {
            let cur = syncBuf[(syncIdx + (k + 1) * sps) % len] - Self.preamblePhase[k]
            let diff = cur - prevErr
            prevErr = cur
            if diff > Double.pi { unwrap -= 2 * Double.pi } else if diff < -Double.pi { unwrap += 2 * Double.pi }
            errvec[k] = cur + unwrap
            mean += errvec[k]
        }
        mean /= Double(n)
        for k in 0..<n { errvec[k] -= mean }
        var freqErr = 0.0
        for k in 0..<n { freqErr += Self.lrX[k] * errvec[k] }
        freqErr /= Self.lrDenom
        var total = 0.0
        for k in 0..<n {
            let e = errvec[k] - freqErr * Self.lrX[k]
            total += e * e
        }
        phaseErr[0] = total
        if phaseErr[1] < Self.syncThreshold && phaseErr[0] > phaseErr[1] {
            let x = Double(sclk)
            let d = Double(Self.syncSkip)
            let denom = d * 2 * d * (-d)
            let y1 = phaseErr[2], y2 = phaseErr[1], y3 = phaseErr[0]
            let a = (x * (y2 - y1) + (x - d) * (y1 - y3) + (x - 2 * d) * (y3 - y2)) / denom
            let b = (x * x * (y1 - y2) + (x - d) * (x - d) * (y3 - y1) + (x - 2 * d) * (x - 2 * d) * (y2 - y3)) / denom
            let vertex = -b / (2 * a)
            sclk = vertex.isFinite ? -Int(vertex.rounded()) : 0
            var sp = syncIdx - sclk
            if sp < 0 { sp += len }
            sp %= len
            prevPhi = syncBuf[sp]
            dphi = prevDphi
            ppmError = frequency != 0 ? VDL2.symbolRate * dphi / (2 * Double.pi * frequency) * 1e6 : 0
            phaseErr[1] = Self.phaseErrorMax
            phaseErr[2] = Self.phaseErrorMax
            return !(maxPPM != 0 && abs(ppmError) > maxPPM)
        }
        phaseErr[2] = phaseErr[1]
        phaseErr[1] = phaseErr[0]
        prevDphi = freqErr
        return false
    }

    // MARK: Symbole

    private func demod(_ re: Double, _ im: Double) {
        if decoderState == .idle { demodReset() }
        powerLP += (re * re + im * im - powerLP) * 0.002
        switch demodState {
        case .initial:
            syncIdx = (syncIdx + 1) % Self.syncLen
            syncBuf[syncIdx] = atan2(im, re)
            sclk += 1
            if sclk < Self.syncSkip { return }
            sclk = 0
            let mag = (re * re + im * im).squareRoot()
            magLP = magLP * Self.magLP + mag * (1 - Self.magLP)
            nfCount += 1
            if nfCount == 1000 {
                nfCount = 0
                magNF = Self.nfLP * magNF + (1 - Self.nfLP) * min(magLP, magNF) + 0.0001
            }
            if gotSync() {
                statistics.syncs += 1
                burstTime = now()
                demodState = .sync
            }
        case .sync:
            sclk += 1
            if sclk < Self.sps { return }
            sclk = 0
            let phi = atan2(im, re)
            var d = phi - prevPhi - dphi
            if d < 0 { d += 2 * Double.pi } else if d > 2 * Double.pi { d -= 2 * Double.pi }
            d /= Double.pi / 4
            let idx = ((Int(d.rounded()) % 8) + 8) % 8
            let power = re * re + im * im
            framePower = (framePower * Double(framePowerCount) + power) / Double(framePowerCount + 1)
            framePowerCount += 1
            prevPhi = phi
            let g = Self.gray[idx]
            bits.append((g >> 2) & 1); bits.append((g >> 1) & 1); bits.append(g & 1)
            if bits.count - (header == nil ? 0 : VDL2.headerBits) >= requestedBits { decodeBurst() }
        }
    }

    // MARK: Burst

    private func descrambleRest() {
        VDL2.scramble(&bits, from: scrambledTo, to: bits.count, state: &lfsr)
        scrambledTo = bits.count
    }

    private func decodeBurst() {
        switch decoderState {
        case .header:
            descrambleRest()
            guard let h = VDL2.parseHeader(bits, at: 0) else {
                statistics.headerErrors += 1
                decoderState = .idle
                return
            }
            statistics.headersOK += 1
            header = h
            requestedBits = h.requestedBits
            decoderState = .data
            if bits.count - VDL2.headerBits >= requestedBits { decodeBurst() }
        case .data:
            descrambleRest()
            decoderState = .idle
            guard let h = header else { return }
            guard let (frames, corrections) = VDL2.decodeData(bits, at: VDL2.headerBits, header: h) else {
                statistics.fecErrors += 1
                return
            }
            let level = 10 * log10(max(framePower, 1e-12))
            let noise = 20 * log10(magNF + 0.001)
            var out: [AVLCFrame] = []
            for f in frames {
                if let a = AVLC.parse(f, time: burstTime, frequency: frequency, levelDB: level, noiseDB: noise, ppm: ppmError, corrections: corrections) {
                    out.append(a)
                } else {
                    statistics.badFCS += 1
                }
            }
            statistics.bursts += 1
            statistics.frames += out.count
            if !out.isEmpty {
                onBurst?(VDL2Burst(time: burstTime, frequency: frequency, frames: out, levelDB: level, noiseDB: noise, ppm: ppmError,
                                   corrections: corrections, headerSyndromeWeight: VDL2.headerErrorWeight(syndrome: h.syndrome)))
            }
        case .idle:
            break
        }
    }
}
