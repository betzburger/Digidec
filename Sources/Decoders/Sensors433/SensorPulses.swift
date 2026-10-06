// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Funksensoren im 433-, 868- und 915-MHz-Band (Wetterstationen, Thermometer, Regenmesser …): Basisband und Pulserkennung.
//
// Aus dem I/Q-Strom (8 Bit, vorzeichenlos) entsteht eine Hüllkurve für OOK (Ein-Aus-Tastung) und eine Momentanfrequenz für FSK.
// Ein Zustandsautomat schneidet daraus „Pakete“ aus Pulsen und Lücken (Breiten in Abtastwerten) und erkennt an der Frequenz, ob das
// Paket OOK oder FSK ist. Verfahren und Zahlenwerte folgen dem Vorbild rtl_433 (Benjamin Larsson, Tommy Vestermark, Christian W.
// Zuckschwerdt und Mitwirkende, GPL-2.0-oder-später): Pegelschätzung für hoch und niedrig mit Hysterese, Mindestlängen, Paketende bei
// langer Lücke, FSK-Erkennung mit „klassischem“ und „Min/Max“-Verfahren (siehe THIRD_PARTY.md).

public enum Sensor433 {
    public static let maxPulses = 1200
    public static let minPulses = 16
    public static let minPulseSamples = 10
    public static let minGapMs = 10
    public static let maxGapMs = 100
    public static let maxGapRatio = 10
}

/// Pulse und Lücken eines Pakets (Breiten in Abtastwerten)
public struct PulseData: Sendable {
    public var sampleRate = 250_000
    /// Abtastwerte seit Beginn des Stroms bis zum ersten Puls
    public var offset = 0
    public var numPulses = 0
    public var pulse = [Int](repeating: 0, count: Sensor433.maxPulses)
    public var gap = [Int](repeating: 0, count: Sensor433.maxPulses)
    public var ookLowEstimate = 0
    public var ookHighEstimate = 0
    public var fskF1Estimate = 0
    public var fskF2Estimate = 0

    public init() {}

    mutating func clear() { self = PulseData() }

    /// Die Hälfte der Daten hinausschieben, um Platz zu schaffen
    mutating func shift() {
        let n = Sensor433.maxPulses / 2
        pulse.replaceSubrange(0..<(Sensor433.maxPulses - n), with: pulse[n...])
        gap.replaceSubrange(0..<(Sensor433.maxPulses - n), with: gap[n...])
        numPulses -= n
        offset += n
    }

    /// Bitte nur für Hilfs- und Prüfzwecke: Breite in Mikrosekunden
    public func microseconds(_ samples: Int) -> Double { Double(samples) * 1e6 / Double(sampleRate) }

    /// Signalstärke des Pakets in dB (rtl_433: Quadrat der Hüllkurve, Vollaussteuerung = 0 dB)
    public var rssiDB: Double { 10 * log10(Double(max(1, ookHighEstimate))) - 42.1442 }
    public var noiseDB: Double { 10 * log10(Double(max(1, ookLowEstimate))) - 42.1442 }
    public var snrDB: Double {
        let high = Double(max(1, min(ookHighEstimate, 16384)))
        return 10 * log10(high / Double(max(1, ookLowEstimate)))
    }
}

// MARK: - Basisband

/// Hüllkurve, Tiefpass und FM-Demodulator mit Festkommarechnung wie im Vorbild (gleiche Schwellen gelten dann auch hier)
public final class Baseband433 {
    private static let fixScale = 15
    private func fix(_ x: Double) -> Int { Int(x * Double(1 << Baseband433.fixScale)) }

    // AM-Tiefpass: [b, a] = butter(1, 0.05), Koeffizienten durch 2 vorskaliert
    private let amA1: Int
    private let amB0: Int
    private var amX0 = 0, amY0 = 0
    // FM
    private var fmRate = 0
    private var fmA1 = 0, fmB0 = 0
    private var xr = 0, xi = 0, xf = 0, yf = 0

    public init() {
        amA1 = Int(0.85408 * 32768) >> 1
        amB0 = Int(0.07296 * 32768) >> 1
    }

    public func reset() {
        amX0 = 0; amY0 = 0
        xr = 0; xi = 0; xf = 0; yf = 0
    }

    /// Quadrat der Hüllkurve (16384 = Vollaussteuerung) aus 8-Bit-I/Q, Mittelpunkt 127 wie im Vorbild
    public func envelope(_ iq: UnsafeBufferPointer<UInt8>, into out: inout [UInt16]) -> Float {
        let n = iq.count / 2
        if out.count < n { out = [UInt16](repeating: 0, count: n) }
        var sum: UInt64 = 0
        for i in 0..<n {
            let x = 127 - Int(iq[2 * i]), y = 127 - Int(iq[2 * i + 1])
            let v = x * x + y * y
            out[i] = UInt16(truncatingIfNeeded: v)
            sum += UInt64(v)
        }
        return n > 0 && sum >= UInt64(n) ? 10 * log10(Float(sum) / Float(n)) - 42.1442 : -42.1442
    }

    /// Tiefpass der Hüllkurve
    public func lowPass(_ x: [UInt16], count n: Int, into y: inout [Int16]) {
        guard n >= 1 else { return }
        if y.count < n { y = [Int16](repeating: 0, count: n) }
        let shift = Baseband433.fixScale - 1
        y[0] = Int16(truncatingIfNeeded: (amA1 * amY0 + amB0 * (Int(x[0]) + amX0)) >> shift)
        for i in 1..<max(1, n) {
            y[i] = Int16(truncatingIfNeeded: (amA1 * Int(y[i - 1]) + amB0 * (Int(x[i]) + Int(x[i - 1]))) >> shift)
        }
        amX0 = Int(x[n - 1])
        amY0 = Int(y[n - 1])
    }

    /// Winkel zwischen −π und π als ±32767 (Fehler höchstens 0,07 rad, wie im Vorbild)
    private func atan2Int16(_ y: Int, _ x: Int) -> Int {
        let piOver4 = Int(Int16.max) / 4
        let threePiOver4 = 3 * Int(Int16.max) / 4
        let absY = abs(y)
        if x == 0 && y == 0 { return 0 }
        var angle: Int
        if x >= 0 {
            var denom = absY + x
            if denom == 0 { denom = 1 }
            angle = piOver4 - piOver4 * (x - absY) / denom
        } else {
            var denom = absY - x
            if denom == 0 { denom = 1 }
            angle = threePiOver4 - piOver4 * (x + absY) / denom
        }
        return y < 0 ? -angle : angle
    }

    /// Momentanfrequenz mit Tiefpass (`lowPass` als Bruchteil der Abtastrate, 0,1 klassisch, 0,2 Min/Max)
    public func demodulateFM(_ iq: UnsafeBufferPointer<UInt8>, sampleRate: Int, lowPass: Double, into out: inout [Int16]) {
        let n = iq.count / 2
        if out.count < n { out = [Int16](repeating: 0, count: n) }
        if fmRate != sampleRate {
            let ita = 1.0 / tan(Double.pi / 2 * lowPass)
            let gain = 1.0 / (1.0 + ita) / 2
            fmA1 = fix((ita - 1.0) * gain)
            fmB0 = fix(gain)
            fmRate = sampleRate
        }
        var x0r = xr, x0i = xi, x0f = xf, y0f = yf
        let shift = Baseband433.fixScale - 1
        for k in 0..<n {
            let x1r = x0r, x1i = x0i, y1f = y0f, x1f = x0f
            x0r = Int(iq[2 * k]) - 128
            x0i = Int(iq[2 * k + 1]) - 128
            let pr = x0r * x1r + x0i * x1i
            let pi = x0i * x1r - x0r * x1i
            x0f = atan2Int16(pi, pr)
            y0f = Int(Int16(truncatingIfNeeded: (fmA1 * y1f + fmB0 * (x0f + x1f)) >> shift))
            out[k] = Int16(truncatingIfNeeded: y0f)
        }
        xr = x0r; xi = x0i; xf = x0f; yf = y0f
    }
}

// MARK: - Pulserkennung

public enum PulsePackage: Sendable { case ook, fsk }

/// Zustandsautomat des Vorbilds: OOK-Pakete aus der Hüllkurve, FSK-Pakete aus der Frequenz während der Trägerzeit
public final class PulseDetector433 {
    private enum OOKState { case idle, pulse, gapStart, gap }
    private enum FSKState { case initial, high, low }

    // Konstanten der Pegelschätzung (Quadrat der Hüllkurve)
    private let maxHighLevel = 16384                  // 0 dB
    private let estHighRatio = 64
    private let estLowRatio = 1024
    private var minHighLevel = 1000                   // −12,1442 dB
    private var highLowRatio = 8                      // 9 dB

    private var state = OOKState.idle
    private var pulseLength = 0
    private var maxPulse = 0
    private var dataCounter = 0
    private var leadIn = 0
    private var lowEstimate = 0
    private var highEstimate = 0

    // FSK
    private var fskState = FSKState.initial
    private var fskPulseLength = 0
    private var f1 = 0, f2 = 0
    private var varMax = Int(Int16.min), varMin = Int(Int16.max)
    private var skipSamples = 40
    private let fskFastEst = 16, fskSlowEst = 64, fskDefaultDelta = 6000
    /// `true`: Min/Max-Verfahren (für Frequenzen über 800 MHz), sonst das klassische
    public var minMaxFSK = false

    public init() {
        highLowRatio = Int(0.5 + pow(10.0, 9.0 / 10.0))        // wie DB_TO_AMP_F(9): 8
        reset()
    }

    public func reset() {
        state = .idle
        pulseLength = 0; maxPulse = 0; dataCounter = 0; leadIn = 0
        lowEstimate = 0; highEstimate = 0
        fskInit()
    }

    private func fskInit() {
        fskState = .initial
        fskPulseLength = 0
        f1 = 0; f2 = 0
        varMax = Int(Int16.min); varMin = Int(Int16.max)
        skipSamples = 40
    }

    // MARK: FSK klassisch

    private func fskClassic(_ fm: Int, _ p: inout PulseData) {
        let d1 = abs(fm - f1), d2 = abs(fm - f2)
        fskPulseLength += 1
        switch fskState {
        case .initial:
            if fskPulseLength < Sensor433.minPulseSamples {
                f1 = f1 / 2 + fm / 2
            } else if d1 > fskDefaultDelta / 2 {
                if fm > f1 {
                    fskState = .high
                    f2 = f1
                    f1 = fm
                    p.pulse[0] = 0
                    p.gap[0] = fskPulseLength
                    p.numPulses += 1
                    fskPulseLength = 0
                } else {
                    fskState = .low
                    f2 = fm
                    p.pulse[0] = fskPulseLength
                    fskPulseLength = 0
                }
            } else {
                f1 += fm / fskFastEst - f1 / fskFastEst
            }
        case .high:
            if d1 > d2 {
                fskState = .low
                if fskPulseLength >= Sensor433.minPulseSamples {
                    p.pulse[p.numPulses] = fskPulseLength
                    fskPulseLength = 0
                } else {
                    fskPulseLength += p.gap[p.numPulses - 1]
                    p.numPulses -= 1
                    if p.numPulses == 0 && p.pulse[0] == 0 {
                        f1 = f2
                        fskState = .initial
                    }
                }
            } else if fm > f1 {
                f1 += fm / fskFastEst - f1 / fskFastEst
            } else {
                f1 += fm / fskSlowEst - f1 / fskSlowEst
            }
        case .low:
            if d2 > d1 {
                fskState = .high
                if fskPulseLength >= Sensor433.minPulseSamples {
                    p.gap[p.numPulses] = fskPulseLength
                    p.numPulses += 1
                    fskPulseLength = 0
                    if p.numPulses >= Sensor433.maxPulses { p.shift() }
                } else {
                    fskPulseLength += p.pulse[p.numPulses]
                    if p.numPulses == 0 { fskState = .initial }
                }
            } else if fm < f2 {
                f2 += fm / fskFastEst - f2 / fskFastEst
            } else {
                f2 += fm / fskSlowEst - f2 / fskSlowEst
            }
        }
    }

    private func fskWrapUp(_ p: inout PulseData) {
        guard p.numPulses < Sensor433.maxPulses else { return }
        fskPulseLength += 1
        if fskState == .high {
            p.pulse[p.numPulses] = fskPulseLength
            p.gap[p.numPulses] = 0
        } else {
            p.gap[p.numPulses] = fskPulseLength
        }
        p.numPulses += 1
    }

    // MARK: FSK Min/Max

    private func fskMinMax(_ fm: Int, _ p: inout PulseData) {
        if skipSamples == 0 {
            varMax = max(fm, varMax)
            varMin = min(fm, varMin)
            let mid = (varMax + varMin) / 2
            if fm > mid { varMax -= 10 }
            if fm < mid { varMin += 10 }
            fskPulseLength += 1
            switch fskState {
            case .initial:
                fskState = fm > mid ? .high : .low
            case .high:
                if fm < mid {
                    fskState = .low
                    p.pulse[p.numPulses] = fskPulseLength
                    fskPulseLength = 0
                }
                f2 += fm / fskSlowEst - f2 / fskSlowEst
            case .low:
                if fm > mid {
                    fskState = .high
                    p.gap[p.numPulses] = fskPulseLength
                    p.numPulses += 1
                    fskPulseLength = 0
                    if p.numPulses >= Sensor433.maxPulses { p.shift() }
                }
                f1 += fm / fskSlowEst - f1 / fskSlowEst
            }
        }
        if skipSamples > 0 { skipSamples -= 1 }
    }

    // MARK: Paketerkennung

    /// Verarbeitet einen Block (Hüllkurve nach dem Tiefpass und Frequenz) und liefert ein Paket, wenn eines zu Ende ist. Mit `flush`
    /// (len = 0 im Vorbild) wird ein angefangenes Paket abgeschlossen. Der Aufruf muss wiederholt werden, bis `nil` kommt.
    public func nextPackage(envelope: [Int16], fm: [Int16], count len: Int, sampleRate: Int, offset: Int, ook: inout PulseData, fsk: inout PulseData, flush: Bool = false) -> PulsePackage? {
        if flush {
            switch state {
            case .idle:
                return nil
            case .pulse:
                if pulseLength < Sensor433.minPulseSamples {
                    if ook.numPulses <= 1 { state = .idle; return nil }
                    state = .gap
                } else {
                    ook.pulse[ook.numPulses] = pulseLength
                    maxPulse = max(pulseLength, maxPulse)
                    pulseLength = 0
                    state = .gapStart
                }
                fallthrough
            case .gapStart:
                state = .gap
                if fsk.numPulses > Sensor433.minPulses {
                    if !minMaxFSK { fskWrapUp(&fsk) }
                    fsk.fskF1Estimate = f1; fsk.fskF2Estimate = f2
                    fsk.ookLowEstimate = lowEstimate; fsk.ookHighEstimate = highEstimate
                    state = .idle
                    return .fsk
                }
                fallthrough
            case .gap:
                ook.gap[ook.numPulses] = pulseLength
                ook.numPulses += 1
                state = .idle
                ook.ookLowEstimate = lowEstimate
                ook.ookHighEstimate = highEstimate
                return .ook
            }
        }

        let samplesPerMs = sampleRate / 1000
        highEstimate = max(highEstimate, minHighLevel)
        var eopOnSpurious = false

        while dataCounter < len {
            let am = Int(envelope[dataCounter])
            let threshold = (lowEstimate + min(highEstimate, maxHighLevel)) / 2
            let hysteresis = threshold / 8
            switch state {
            case .idle:
                if am > threshold + hysteresis && leadIn > estLowRatio {
                    ook.clear(); fsk.clear()
                    ook.sampleRate = sampleRate; fsk.sampleRate = sampleRate
                    ook.offset = offset + dataCounter
                    fsk.offset = offset + dataCounter
                    pulseLength = 0
                    maxPulse = 0
                    fskInit()
                    state = .pulse
                } else {
                    let delta = am - lowEstimate
                    lowEstimate += delta / estLowRatio
                    lowEstimate += delta > 0 ? 1 : -1
                    highEstimate = highLowRatio * lowEstimate
                    highEstimate = max(highEstimate, minHighLevel)
                    if leadIn <= estLowRatio { leadIn += 1 }
                }
            case .pulse:
                pulseLength += 1
                if am < threshold - hysteresis {
                    if pulseLength < Sensor433.minPulseSamples {
                        if ook.numPulses <= 1 {
                            state = .idle
                        } else {
                            eopOnSpurious = true
                            state = .gap
                        }
                    } else {
                        ook.pulse[ook.numPulses] = pulseLength
                        maxPulse = max(pulseLength, maxPulse)
                        pulseLength = 0
                        state = .gapStart
                    }
                } else {
                    highEstimate += am / estHighRatio - highEstimate / estHighRatio
                    highEstimate = max(highEstimate, minHighLevel)
                    ook.fskF1Estimate += Int(fm[dataCounter]) / estHighRatio - ook.fskF1Estimate / estHighRatio
                }
                if ook.numPulses == 0 {
                    if minMaxFSK { fskMinMax(Int(fm[dataCounter]), &fsk) } else { fskClassic(Int(fm[dataCounter]), &fsk) }
                }
            case .gapStart:
                pulseLength += 1
                if am > threshold + hysteresis {
                    pulseLength += ook.pulse[ook.numPulses]
                    state = .pulse
                } else if pulseLength >= Sensor433.minPulseSamples {
                    state = .gap
                    if fsk.numPulses > Sensor433.minPulses {
                        if !minMaxFSK { fskWrapUp(&fsk) }
                        fsk.fskF1Estimate = f1; fsk.fskF2Estimate = f2
                        fsk.ookLowEstimate = lowEstimate; fsk.ookHighEstimate = highEstimate
                        state = .idle
                        return .fsk
                    }
                }
                if ook.numPulses == 0 {
                    if minMaxFSK { fskMinMax(Int(fm[dataCounter]), &fsk) } else { fskClassic(Int(fm[dataCounter]), &fsk) }
                }
            case .gap:
                pulseLength += 1
                if am > threshold + hysteresis {
                    ook.gap[ook.numPulses] = pulseLength
                    ook.numPulses += 1
                    if ook.numPulses >= Sensor433.maxPulses {
                        state = .idle
                        ook.ookLowEstimate = lowEstimate
                        ook.ookHighEstimate = highEstimate
                        return .ook
                    }
                    pulseLength = 0
                    state = .pulse
                }
                if eopOnSpurious
                    || (pulseLength > Sensor433.maxGapRatio * maxPulse && pulseLength > Sensor433.minGapMs * samplesPerMs)
                    || pulseLength > Sensor433.maxGapMs * samplesPerMs {
                    ook.gap[ook.numPulses] = pulseLength
                    ook.numPulses += 1
                    state = .idle
                    ook.ookLowEstimate = lowEstimate
                    ook.ookHighEstimate = highEstimate
                    return .ook
                }
            }
            dataCounter += 1
        }
        dataCounter = 0
        return nil
    }
}
