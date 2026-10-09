// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Accelerate

// RDS-Demodulator: UKW-Multiplexsignal (Diskriminator-Ausgang, 1,0 = 75 kHz Hub) → Bits.
//
// Signalweg:
//   1. Mischen des 57-kHz-Unterträgers auf 0 Hz (Tabelle, exakt für ganzzahlige Abtastraten).
//   2. Tiefpass und Dezimierung auf etwa 48 kS/s (Durchlass 8 kHz), danach Tiefpass auf die RDS-Bandbreite (Durchlass 2,4 kHz, Sperre 4,6 kHz),
//      damit das untere Seitenband des Stereo-Differenzsignals (bis 53 kHz) nicht hereinragt.
//   3. Wandlung auf 19 kS/s = genau 16 Abtastwerte je Bit (1187,5 Bit/s).
//   4. Costas-Schleife (zweiter Ordnung, pegelnormiert) mit angepasstem Biphase-Filter; sie bringt das Datensignal auf die I-Achse.
//   5. Taktnachführung mit Early-Late-Detektor und linearer Interpolation (Zweig mit Frequenz), grobe Phasensuche beim Start und bei Verlust.
//   6. Differentielle Entscheidung → Bits für RDSStreamDecoder.

public final class RDSDemodulator: @unchecked Sendable {
    public let streamDecoder = RDSStreamDecoder()

    /// Messwerte des Signalwegs für die Anzeige
    public struct Metrics: Sendable, Equatable {
        /// Träger bei 57 kHz als Hub in kHz (Spitze, grob; Rauschen erhöht den Wert); echte Sender liegen bei 1 bis 4 kHz
        public var carrierDeviationKHz = 0.0
        /// Verhältnis von Datenleistung zu Restleistung nach der Costas-Schleife in dB
        public var snrDB = -30.0
        /// Costas-Schleife eingerastet (Quadraturanteil klein gegen Datenanteil)
        public var locked = false
        public init() {}
    }

    private static let bitRate = 1187.5
    private static let symbolSamples = 16.0      // bei 19 kS/s
    private static let earlyLate = 2.0           // Abstand der Early/Late-Proben in Abtastwerten

    private let lock = NSLock()

    // Kette je Eingangsrate
    private var chain: Chain?

    // 19-kS/s-Stufe: Costas
    private var theta = 0.0
    private var freq = 0.0
    private let costasKp: Double
    private let costasKi: Double
    private var power = 0.0
    private var samplesSeen = 0
    private var ringI = [Float](repeating: 0, count: 16)
    private var ringQ = [Float](repeating: 0, count: 16)
    private var ringIndex = 0
    private var pI = 0.0, pQ = 0.0, carrierAvg = 0.0

    // Takt
    private var yRing = [Float](repeating: 0, count: 64)
    private var sampleIndex = 0                 // Zähler der 19-kS/s-Werte
    private var nextSymbol = 0.0                // Zeitpunkt (in Abtastwerten) des nächsten Symbolmittelpunkts
    private var timingSet = false
    private var period = RDSDemodulator.symbolSamples
    private var phaseEnergy = [Float](repeating: 0, count: 16)
    private var acquireCounter = 0
    private var previousSymbol = 0
    private var metrics = Metrics()

    private let timingKp = 0.09
    private let timingKi = 0.0012

    public init() {
        // Eigenfrequenz 15 Hz, Dämpfung 0,8 bei 19 kS/s
        let wn = 2 * Double.pi * 15.0 / 19_000.0
        costasKp = 2 * 0.8 * wn
        costasKi = wn * wn
    }

    public var currentMetrics: Metrics { lock.withLock { metrics } }

    public func reset() {
        lock.withLock {
            streamDecoder.reset()
            chain?.reset()
            theta = 0; freq = 0; power = 0; samplesSeen = 0
            ringI = [Float](repeating: 0, count: 16)
            ringQ = ringI
            ringIndex = 0
            pI = 0; pQ = 0; carrierAvg = 0
            yRing = [Float](repeating: 0, count: 64)
            sampleIndex = 0
            nextSymbol = 0
            timingSet = false
            period = Self.symbolSamples
            phaseEnergy = [Float](repeating: 0, count: 16)
            acquireCounter = 0
            previousSymbol = 0
            metrics = Metrics()
        }
    }

    /// Ein Block Multiplexsignal; die Abtastrate ist ganzzahlig und mindestens 192 kS/s (üblich: 480 kS/s)
    public func process(mpx: UnsafeBufferPointer<Float>, sampleRate: Double = 480_000) {
        lock.withLock { processInternal(mpx: mpx, sampleRate: sampleRate) }
    }

    // MARK: Kette

    private final class Chain {
        let rate: Double
        let period: Int
        let cosT: [Float]
        let sinT: [Float]
        let decim: Int
        let firAI: StreamFIR, firAQ: StreamFIR
        let firBI: StreamFIR, firBQ: StreamFIR
        let rsI: SampleRateConverter, rsQ: SampleRateConverter
        var phase = 0
        var mixI: [Float] = [], mixQ: [Float] = []
        var aI: [Float] = [], aQ: [Float] = [], bI: [Float] = [], bQ: [Float] = []
        var outI: [Float] = [], outQ: [Float] = []

        init?(rate: Double) {
            guard rate >= 150_000, rate == rate.rounded() else { return nil }
            self.rate = rate
            let r = Int(rate)
            var a = r, b = 57_000
            while b != 0 { (a, b) = (b, a % b) }
            period = r / a
            var c = [Float](repeating: 0, count: period), s = c
            for k in 0..<period {
                let w = 2 * Double.pi * Double(k) / Double(period) * Double(57_000 / a)
                c[k] = Float(cos(w)); s[k] = Float(sin(w))
            }
            cosT = c; sinT = s
            decim = max(1, Int((rate / 48_000).rounded()))
            let rateA = rate / Double(decim)
            let tapsA = SDRFilterDesign.lowpass(passband: 8_000 / rate, stopband: 20_000 / rate, attenuationDB: 60)
            firAI = StreamFIR(taps: tapsA, decimation: decim); firAQ = StreamFIR(taps: tapsA, decimation: decim)
            let tapsB = SDRFilterDesign.lowpass(passband: 2_400 / rateA, stopband: 4_600 / rateA, attenuationDB: 60)
            firBI = StreamFIR(taps: tapsB); firBQ = StreamFIR(taps: tapsB)
            guard let ri = SampleRateConverter(inputRate: rateA, outputRate: 19_000),
                  let rq = SampleRateConverter(inputRate: rateA, outputRate: 19_000) else { return nil }
            rsI = ri; rsQ = rq
        }

        func reset() {
            phase = 0
            firAI.reset(); firAQ.reset(); firBI.reset(); firBQ.reset()
            rsI.reset(); rsQ.reset()
        }
    }

    // MARK: Verarbeitung

    private func processInternal(mpx: UnsafeBufferPointer<Float>, sampleRate: Double) {
        let count = mpx.count
        guard count > 0 else { return }
        if chain == nil || chain!.rate != sampleRate {
            chain = Chain(rate: sampleRate)
        }
        guard let ch = chain else { return }

        if ch.mixI.count != count {
            ch.mixI = [Float](repeating: 0, count: count)
            ch.mixQ = [Float](repeating: 0, count: count)
        }
        var ph = ch.phase
        let period = ch.period
        ch.cosT.withUnsafeBufferPointer { cosT in
            ch.sinT.withUnsafeBufferPointer { sinT in
                ch.mixI.withUnsafeMutableBufferPointer { mi in
                    ch.mixQ.withUnsafeMutableBufferPointer { mq in
                        for i in 0..<count {
                            let s = mpx[i]
                            mi[i] = s * cosT[ph]
                            mq[i] = -s * sinT[ph]
                            ph += 1
                            if ph == period { ph = 0 }
                        }
                    }
                }
            }
        }
        ch.phase = ph

        ch.firAI.process(ch.mixI, into: &ch.aI)
        ch.firAQ.process(ch.mixQ, into: &ch.aQ)
        guard !ch.aI.isEmpty, ch.aI.count == ch.aQ.count else { return }
        ch.firBI.process(ch.aI, into: &ch.bI)
        ch.firBQ.process(ch.aQ, into: &ch.bQ)
        guard !ch.bI.isEmpty, ch.bI.count == ch.bQ.count else { return }
        ch.outI.removeAll(keepingCapacity: true)
        ch.outQ.removeAll(keepingCapacity: true)
        ch.bI.withUnsafeBufferPointer { b in ch.rsI.process(b) { ch.outI.append(contentsOf: $0) } }
        ch.bQ.withUnsafeBufferPointer { b in ch.rsQ.process(b) { ch.outQ.append(contentsOf: $0) } }
        let n = min(ch.outI.count, ch.outQ.count)
        guard n > 0 else { return }
        run19k(i: ch.outI, q: ch.outQ, count: n)
    }

    /// Costas-Schleife, angepasstes Filter, Takt und Entscheidung bei 19 kS/s
    private func run19k(i zi: [Float], q zq: [Float], count n: Int) {
        for k in 0..<n {
            // 1. Trägerdrehung
            let c = Float(cos(theta)), s = Float(sin(theta))
            let di = zi[k] * c + zq[k] * s
            let dq = zq[k] * c - zi[k] * s
            ringI[ringIndex] = di
            ringQ[ringIndex] = dq
            ringIndex = (ringIndex + 1) & 15

            // 2. Angepasstes Filter für den Biphase-Impuls: neueste acht Werte minus die acht davor
            var yi: Float = 0, yq: Float = 0
            for j in 0..<8 {
                let a = (ringIndex - 1 - j) & 15
                let b = (ringIndex - 9 - j) & 15
                yi += ringI[a] - ringI[b]
                yq += ringQ[a] - ringQ[b]
            }

            // 3. Costas-Fehler, auf die mittlere Leistung normiert
            let pw = Double(yi * yi + yq * yq)
            samplesSeen += 1
            let alpha = samplesSeen < 4_000 ? 0.01 : 0.0004
            power += (pw - power) * alpha
            var err = power > 1e-14 ? Double(yi * yq) / power : 0
            err = max(-1, min(1, err))
            freq += costasKi * err
            freq = max(-0.02, min(0.02, freq))
            theta += freq + costasKp * err
            if theta > Double.pi { theta -= 2 * Double.pi } else if theta < -Double.pi { theta += 2 * Double.pi }

            // Messwerte
            pI += (Double(yi * yi) - pI) * 0.0005
            pQ += (Double(yq * yq) - pQ) * 0.0005
            carrierAvg += (Double((zi[k] * zi[k] + zq[k] * zq[k]).squareRoot()) - carrierAvg) * 0.001

            // 4. Taktphasen-Energie (grobe Suche)
            yRing[sampleIndex & 63] = yi
            let e = abs(yi)
            let pidx = sampleIndex & 15
            phaseEnergy[pidx] += (e - phaseEnergy[pidx]) * 0.01

            sampleIndex += 1
            if sampleIndex & 0xFFF == 0 { checkAcquisition() }

            // 5. Symbolentscheidung, sobald die späte Probe vorliegt
            let latest = Double(sampleIndex - 1)
            while timingSet && nextSymbol + Self.earlyLate + 1 <= latest {
                decideSymbol()
            }
        }
        updateMetrics()
    }

    private func interpolate(_ t: Double) -> Float {
        let i = Int(t.rounded(.down))
        let f = Float(t - Double(i))
        return yRing[i & 63] * (1 - f) + yRing[(i + 1) & 63] * f
    }

    private func decideSymbol() {
        let t = nextSymbol
        let yc = interpolate(t)
        let ye = interpolate(t - Self.earlyLate)
        let yl = interpolate(t + Self.earlyLate)
        let sym = yc >= 0 ? 1 : 0
        streamDecoder.process(bit: sym ^ previousSymbol)
        previousSymbol = sym
        // Early-Late: die Probe mit dem größeren Betrag liegt näher am Mittelpunkt
        let denom = abs(yl) + abs(ye)
        let terr = denom > 1e-12 ? Double((abs(yl) - abs(ye)) / denom) : 0
        period += timingKi * terr
        period = max(Self.symbolSamples - 0.25, min(Self.symbolSamples + 0.25, period))
        nextSymbol += period + timingKp * terr
    }

    /// Grobe Taktsuche: beim Start und solange kein Blocktakt steht, auf die Phase mit der größten Energie springen
    private func checkAcquisition() {
        let state = streamDecoder.syncState
        var best = 0
        var maxE: Float = 0
        for p in 0..<16 where phaseEnergy[p] > maxE { maxE = phaseEnergy[p]; best = p }
        guard maxE > 0 else { return }
        if !timingSet {
            nextSymbol = nextPhase(best)
            timingSet = true
            return
        }
        if state == .search {
            acquireCounter += 1
            if acquireCounter >= 2 {
                acquireCounter = 0
                // Abstand der aktuellen Taktlage zur besten Phase (zyklisch über 16)
                let cur = nextSymbol.truncatingRemainder(dividingBy: 16)
                var d = Double(best) - cur
                while d > 8 { d -= 16 }
                while d < -8 { d += 16 }
                if abs(d) > 2.5 {
                    nextSymbol += d
                    period = Self.symbolSamples
                }
            }
        } else {
            acquireCounter = 0
        }
    }

    /// Nächster Abtastwert mit der Nummer ≡ `phase` (mod 16), der noch nicht verarbeitet ist
    private func nextPhase(_ phase: Int) -> Double {
        var t = sampleIndex + 24
        while t & 15 != phase { t += 1 }
        return Double(t)
    }

    private func updateMetrics() {
        var m = Metrics()
        m.carrierDeviationKHz = 2 * carrierAvg * 75
        let sig = max(pI - pQ, 1e-18), noise = max(pQ, 1e-18)
        m.snrDB = max(-30, min(40, 10 * log10(sig / noise)))
        m.locked = pI > 1e-14 && pQ < 0.35 * pI
        metrics = m
    }
}
