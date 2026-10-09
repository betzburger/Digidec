// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Accelerate

// UKW-Rundfunk (WFM): Stereodecoder für das Multiplexsignal (Diskriminator-Ausgang bei 480 kS/s, 1,0 = 75 kHz Hub).
//
//   MPX = (L+R)/2·0,9 + 0,1·sin(Φp) + (L−R)/2·0,9·sin(2Φp) + RDS (57 kHz)        Φp = 19-kHz-Pilotphase
//
// Der Pilot wird mit einer Phasenregelschleife verfolgt (Mischen auf 0 Hz, zweistufige Dezimierung auf 10 kS/s, Regelschleife zweiter Ordnung).
// Das Multiplexsignal läuft um die Gruppenlaufzeit der Pilotkette verzögert durch einen Puffer, damit die Phase aus der Schleife genau zu dem
// Signal gehört, das damit demoduliert wird. Das Differenzsignal entsteht durch Mischen mit dem verdoppelten Pilot (38 kHz); beide Zweige gehen
// durch denselben 15-kHz-Tiefpass (Sperre ab 18,5 kHz: der Pilot fällt heraus) mit Dezimierung auf 48 kS/s.
// Je nach Pilot-Rauschabstand wird das Differenzsignal langsam zu- oder abgeblendet (Stereo → Mono bei schwachem Empfang).

final class WFMStereoDecoder {
    struct Status: Equatable, Sendable {
        /// Pilot gefunden und Schleife eingerastet
        var locked = false
        /// Pilot als Hub in kHz (nominal 6,75 kHz)
        var pilotKHz = 0.0
        /// Verhältnis Pilotleistung zu Restleistung in der Schleife (dB)
        var pilotSNR = -30.0
        /// Anteil des Differenzsignals im Ausgang (0 = Mono, 1 = volles Stereo)
        var blend = 0.0
        /// Rauschen im Differenzsignal (Effektivwert über 15 kHz, 1,0 = 75 kHz Hub), gemessen im programmfreien Band 62,5 … 65,5 kHz
        var noiseRMS = 0.0
    }

    static let rate = 480_000.0
    /// Rauschen im Differenzsignal (Effektivwert), unter dem volles Stereo läuft, und darüber, ab dem reines Mono läuft
    static let noiseStereo = 0.006
    static let noiseMono = 0.020

    private(set) var status = Status()
    /// Stereo erlaubt (sonst immer Mono)
    var stereoEnabled = true

    // Pilotkette
    private let mixCos: [Float], mixSin: [Float]          // e^(−jω0 m), ω0 = 2π·19/480 (Periode 480)
    private let dblCos: [Double], dblSin: [Double]         // 2ω0·m (Periode 240)
    private let fir1I: StreamFIR, fir1Q: StreamFIR         // 480 → 60 kS/s
    private let fir2I: StreamFIR, fir2Q: StreamFIR         // 60 → 10 kS/s
    private let delay: Double                               // Gruppenlaufzeit der Kette in Eingangswerten
    private var globalIndex = 0                             // Zahl der bisher gelesenen Eingangswerte
    private var mixI: [Float] = [], mixQ: [Float] = []
    private var s1I: [Float] = [], s1Q: [Float] = [], s2I: [Float] = [], s2Q: [Float] = []

    // Regelschleife
    private var psi = 0.0
    private var omega = 0.0
    private var steps = 0                                   // Zahl der Schleifenschritte (10 kS/s)
    private var amp = 0.0
    private var quad = 0.0
    private var lockCount = 0
    private var unlockCount = 0
    private var locked = false

    // Verzögerungspuffer und Stützstellen der Phase
    private var fifo: [Float] = []
    private var consumed = 0                                // globaler Index von fifo[0]
    private var anchors: [(c: Double, psi: Double, target: Double)] = []

    // Zweige
    private let lpSum: StreamFIR
    private let lpDiff: StreamFIR
    // Rauschmessung im programmfreien Band 62,5 … 65,5 kHz (zwischen RDS und SCA)
    private let noiseCos: [Float], noiseSin: [Float]        // e^(−jω t), ω = 2π·64/480 (Periode 15)
    private let noiseI: StreamFIR, noiseQ: StreamFIR
    private var noiseMixI: [Float] = [], noiseMixQ: [Float] = [], noiseOutI: [Float] = [], noiseOutQ: [Float] = []
    private var noisePhase = 0
    private var noisePending: [Float] = []                  // Leistung je Rauschwert, noch nicht verbraucht
    private var noiseBase = 0                               // globaler Index von noisePending[0]
    private var noiseUsed = 0                               // Zahl der verbrauchten Rauschwerte
    private var noisePower = 0.0
    private var target = 0.0                                // Zielwert der Überblendung, vom letzten Schleifenschritt
    private var sumIn: [Float] = [], diffIn: [Float] = [], phaseBuf: [Float] = []
    private var targetIn: [Float] = []                      // Zielwert je Eingangswert der Zweige
    private var targetBase = 0                              // globaler Index von targetIn[0]
    private var outEmitted = 0
    private var sumOut: [Float] = [], diffOut: [Float] = []
    private var blend: Double = 0
    /// Messhilfe für die Prüfungen: Effektivwert des Differenzsignals vor dem Überblenden
    private(set) var diffSquares = 0.0, diffCount = 0

    init() {
        var c = [Float](repeating: 0, count: 480), s = c
        for k in 0..<480 {
            let w = 2 * Double.pi * 19.0 * Double(k) / 480.0
            c[k] = Float(cos(w)); s[k] = Float(sin(w))
        }
        mixCos = c; mixSin = s
        dblCos = (0..<240).map { cos(2 * Double.pi * 19.0 * Double($0) / 240.0) }
        dblSin = (0..<240).map { sin(2 * Double.pi * 19.0 * Double($0) / 240.0) }
        let t1 = SDRFilterDesign.lowpass(passband: 3_000 / 480_000, stopband: 26_000 / 480_000, attenuationDB: 60)
        let t2 = SDRFilterDesign.lowpass(passband: 100.0 / 60_000, stopband: 1_500.0 / 60_000, attenuationDB: 60)
        fir1I = StreamFIR(taps: t1, decimation: 8); fir1Q = StreamFIR(taps: t1, decimation: 8)
        fir2I = StreamFIR(taps: t2, decimation: 6); fir2Q = StreamFIR(taps: t2, decimation: 6)
        delay = Double(t1.count - 1) / 2 + 4.0 * Double(t2.count - 1)
        let audio = SDRFilterDesign.lowpass(passband: 15_000 / 480_000, stopband: 18_500 / 480_000, attenuationDB: 62)
        lpSum = StreamFIR(taps: audio, decimation: 10)
        lpDiff = StreamFIR(taps: audio, decimation: 10)
        noiseCos = (0..<15).map { Float(cos(2 * Double.pi * 64.0 * Double($0) / 480.0)) }
        noiseSin = (0..<15).map { Float(sin(2 * Double.pi * 64.0 * Double($0) / 480.0)) }
        let nt = SDRFilterDesign.lowpass(passband: 1_500.0 / 480_000, stopband: 5_000.0 / 480_000, attenuationDB: 60)
        noiseI = StreamFIR(taps: nt, decimation: 24); noiseQ = StreamFIR(taps: nt, decimation: 24)
    }

    func reset() {
        fir1I.reset(); fir1Q.reset(); fir2I.reset(); fir2Q.reset()
        lpSum.reset(); lpDiff.reset(); noiseI.reset(); noiseQ.reset()
        noisePhase = 0
        globalIndex = 0
        psi = 0; omega = 0; steps = 0; amp = 0; quad = 0
        lockCount = 0; unlockCount = 0; locked = false
        noisePending.removeAll(); noiseBase = 0; noiseUsed = 0; noisePower = 0; target = 0
        fifo.removeAll(); consumed = 0; anchors.removeAll()
        targetIn.removeAll(); targetBase = 0; outEmitted = 0
        blend = 0
        diffSquares = 0; diffCount = 0
        status = Status()
    }

    /// Ein Block Multiplexsignal; hängt Mono (L+R) und verschachtelt L, R (48 kS/s) an die Ausgaben an
    func process(mpx: UnsafeBufferPointer<Float>, mono: inout [Float], stereo: inout [Float], wantStereo: Bool) {
        let n = mpx.count
        guard n > 0 else { return }
        fifo.append(contentsOf: mpx)
        runNoiseChain(mpx)
        runPilotChain(mpx)

        // Alle Werte, für die die Phase zwischen zwei Stützstellen bekannt ist, durch die Zweige schicken
        sumIn.removeAll(keepingCapacity: true)
        diffIn.removeAll(keepingCapacity: true)
        while anchors.count >= 2 {
            let left = anchors[0], right = anchors[1]
            let end = min(Int(right.c.rounded(.up)), consumed + fifo.count)
            let count = end - consumed
            if count > 0 {
                if phaseBuf.count < count { phaseBuf = [Float](repeating: 0, count: count) }
                let dpsi = (right.psi - left.psi) / max(1.0, right.c - left.c)
                // sin(2ω0·m + 2ψ(m)) aus Tabelle (Periode 240) und der Phase der Schleife, die zwischen den Stützstellen linear läuft
                for k in 0..<count {
                    let m = consumed + k
                    let b = 2 * (left.psi + dpsi * (Double(m) - left.c))
                    let idx = ((m % 240) + 240) % 240
                    phaseBuf[k] = Float(dblSin[idx] * cos(b) + dblCos[idx] * sin(b))
                }
                let t = Float(left.target)
                for k in 0..<count {
                    let x = fifo[k]
                    sumIn.append(x)
                    diffIn.append(-2 * x * phaseBuf[k])   // Pilot = sin(Φ), die Schleife liegt −90° daneben: Träger = −sin(2ω0 m + 2ψ)
                    targetIn.append(t)
                }
                fifo.removeFirst(count)
                consumed = end
            }
            if Double(consumed) >= right.c { anchors.removeFirst() } else { break }
        }

        guard !sumIn.isEmpty else { return }
        lpSum.process(sumIn, into: &sumOut)
        lpDiff.process(diffIn, into: &diffOut)
        let outCount = min(sumOut.count, diffOut.count)
        guard outCount > 0 else { return }

        // Zu- und Abblenden des Differenzsignals; der Zielwert gehört zum Eingangswert, aus dem der Ausgangswert entsteht (Index 10·J)
        let up = 1.0 / (0.08 * 48_000)     // Zublenden in etwa 80 ms
        let down = 1.0 / (0.01 * 48_000)   // Abblenden in 10 ms
        for k in 0..<outCount {
            let local = 10 * (outEmitted + k) - targetBase
            let tgt = local >= 0 && local < targetIn.count ? Double(targetIn[local]) : 0
            blend += (tgt - blend) * (tgt > blend ? up : down)
            let m = sumOut[k]
            diffSquares += Double(diffOut[k]) * Double(diffOut[k]); diffCount += 1
            mono.append(m)
            if wantStereo {
                let d = diffOut[k] * Float(blend)
                stereo.append(m + d)
                stereo.append(m - d)
            }
        }
        outEmitted += outCount
        let drop = min(targetIn.count, max(0, 10 * outEmitted - targetBase))
        if drop > 0 { targetIn.removeFirst(drop); targetBase += drop }
        status.blend = blend
    }

    // MARK: Rauschmessung

    /// Rauschen im Differenzsignal aus der Leistung im programmfreien Band 62,5 … 65,5 kHz. Die Rauschdichte der FM steigt mit dem Quadrat der
    /// Frequenz; das Differenzsignal nimmt Rauschen aus 23 … 53 kHz mit (bei 38 ± f im Mittel das 0,74-fache der Dichte bei 64 kHz). Der Umrechnungsfaktor 1,3 ist an einem Rauschen mit f²-Dichte geeicht (Logiktest).
    private func runNoiseChain(_ mpx: UnsafeBufferPointer<Float>) {
        let n = mpx.count
        if noiseMixI.count != n { noiseMixI = [Float](repeating: 0, count: n); noiseMixQ = noiseMixI }
        var ph = noisePhase
        for i in 0..<n {
            noiseMixI[i] = mpx[i] * noiseCos[ph]
            noiseMixQ[i] = -mpx[i] * noiseSin[ph]
            ph += 1
            if ph == 15 { ph = 0 }
        }
        noisePhase = ph
        noiseI.process(noiseMixI, into: &noiseOutI)
        noiseQ.process(noiseMixQ, into: &noiseOutQ)
        let k = min(noiseOutI.count, noiseOutQ.count)
        for j in 0..<k { noisePending.append(noiseOutI[j] * noiseOutI[j] + noiseOutQ[j] * noiseOutQ[j]) }
    }

    // MARK: Pilotkette und Regelschleife

    private func runPilotChain(_ mpx: UnsafeBufferPointer<Float>) {
        let n = mpx.count
        if mixI.count != n { mixI = [Float](repeating: 0, count: n); mixQ = mixI }
        var ph = globalIndex % 480
        for i in 0..<n {
            let x = mpx[i]
            mixI[i] = x * mixCos[ph]
            mixQ[i] = -x * mixSin[ph]
            ph += 1
            if ph == 480 { ph = 0 }
        }
        globalIndex += n
        fir1I.process(mixI, into: &s1I)
        fir1Q.process(mixQ, into: &s1Q)
        guard !s1I.isEmpty, s1I.count == s1Q.count else { return }
        fir2I.process(s1I, into: &s2I)
        fir2Q.process(s1Q, into: &s2Q)
        let k = min(s2I.count, s2Q.count)
        for j in 0..<k { pllStep(zi: Double(s2I[j]), zq: Double(s2Q[j])) }
        let used = noiseUsed - noiseBase
        if used > 4096 { noisePending.removeFirst(used); noiseBase += used }
    }

    private func pllStep(zi: Double, zq: Double) {
        if steps == 0 { psi = atan2(zq, zi) }
        let c = cos(psi), s = sin(psi)
        let di = zi * c + zq * s
        let dq = zq * c - zi * s
        let err = atan2(dq, di)
        // Bandbreite: breit zum Einrasten (20 Hz), schmal im Betrieb (4 Hz)
        let wn = 2 * Double.pi * (locked ? 4.0 : 20.0) * 1e-4
        let kp = 2 * 0.8 * wn, ki = wn * wn
        omega += ki * err
        psi += omega + kp * err
        if steps < 8 { omega = 0 }

        let mag = (di * di + dq * dq).squareRoot()
        let a = steps < 50 ? 0.1 : 0.003
        amp += (mag - amp) * a
        quad += (dq * dq - quad) * a

        // Rauschleistung: die Werte dieses Schrittes (Index 2k−1 und 2k) einarbeiten
        let first = steps == 0 ? 0 : 2 * steps - 1
        let alphaN = 1.0 / (20_000 * 0.4)
        for idx in first...(2 * steps) {
            let local = idx - noiseBase
            guard local >= 0, local < noisePending.count else { continue }
            noisePower += (Double(noisePending[local]) - noisePower) * max(alphaN, 1.0 / Double(idx + 1))
            noiseUsed = idx + 1
        }
        steps += 1

        // Mittelpunkt der Stufe in Eingangswerten (Zeit, auf die sich dieser Wert bezieht)
        let c0 = Double(steps - 1) * 48 - delay

        let pilot = 2 * amp                                     // Spitze des Pilots in MPX-Einheiten
        let snr = 10 * log10(max(amp * amp, 1e-18) / max(quad, 1e-18))
        status.pilotKHz = pilot * 75
        status.pilotSNR = max(-30, min(60, snr))
        // Einrasten: Pilot mindestens 1,5 kHz Hub und ruhige Phase; Ausrasten erst nach 0,3 s
        let good = pilot > 0.02 && snr > 8
        if good { lockCount += 1; unlockCount = 0 } else { unlockCount += 1; lockCount = 0 }
        if !locked && lockCount >= 300 { locked = true }
        if locked && unlockCount >= 3000 { locked = false }
        status.locked = locked
        status.noiseRMS = (noisePower * 1.3).squareRoot()

        // Zielwert der Überblendung nach dem Rauschen im Differenzsignal
        if stereoEnabled && locked {
            let t = max(0, min(1, (Self.noiseMono - status.noiseRMS) / (Self.noiseMono - Self.noiseStereo)))
            target = t * t * (3 - 2 * t)
        } else {
            target = 0
        }

        if anchors.isEmpty { anchors.append((c0 - 48, psi, target)) }
        anchors.append((c0, psi, target))
    }
}
