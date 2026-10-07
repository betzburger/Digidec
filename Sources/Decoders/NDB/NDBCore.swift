// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Accelerate

// NDB (Non-Directional Beacon, ungerichtetes Funkfeuer, 190 … 535 kHz): Der Empfänger liest das Audio eines Empfängers (AM, oder
// CW/USB bei unmoduliertem Träger), sucht den Ton der getasteten Kennung (400 oder 1020 Hz bei A2A, beliebiger Überlagerungston
// bei A1A), bringt ihn auf eine Hüllkurve und liest die Morse-Kennung (zwei bis vier Zeichen, etwa alle 10 bis 60 s wiederholt).

public enum NDBAudio {
    public static let sampleRate = 8000.0
    /// Hüllkurvenwerte je Sekunde für den Morse-Leser
    public static let envelopeRate = 60.0
}

public struct NDBReading: Sendable, Equatable {
    public var toneHz = 0.0
    /// Pegel des Tons gegen Vollaussteuerung (dB) und Rauschen je Bin (dB), Verhältnis darüber
    public var toneDB = -120.0
    public var noiseDB = -120.0
    public var snrDB = 0.0
    public var present = false
    /// Getastet: gerade Ton an
    public var keyed = false
    public init() {}
}

/// Tonsuche, Hüllkurve und Morse-Leser für NDB-Kennungen
public final class NDBReceiver: @unchecked Sendable {
    public var onIdent: ((String) -> Void)?
    /// Ton von Hand vorgegeben (sonst Suche)
    public var fixedToneHz: Double?
    public private(set) var reading = NDBReading()

    private static let fftSize = 1024
    private static let hop = 512
    private let log2n: vDSP_Length = 10
    private let setup: FFTSetup
    private let window: [Float]
    private var ring = [Float](repeating: 0, count: NDBReceiver.fftSize)
    private var ringPos = 0
    private var sinceFFT = 0
    private var hold = [Float](repeating: 0, count: NDBReceiver.fftSize / 2)
    private var instant = [Float](repeating: 0, count: NDBReceiver.fftSize / 2)
    private var noiseHold: Float = 0
    private var tone = 0.0
    private var candidate = 0.0
    private var candidateBlocks = 0
    private var lastToneSeen = Date.distantPast
    // Mischer und Tiefpässe
    private var phase = 0.0
    private var lp: [Float] = [Float](repeating: 0, count: 6)       // 3 Stufen je I und Q
    private var envSum: Float = 0
    private var envCount = 0
    private let envPerSample: Int
    private var morse = MorseDecoder()
    private var envPeak: Float = 0
    private var inputRMS: Float = 0

    public init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&w, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        window = w
        envPerSample = Int((NDBAudio.sampleRate / NDBAudio.envelopeRate).rounded())
        morse.onText = { [weak self] text in self?.onIdent?(text) }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    public func reset() {
        for i in 0..<hold.count { hold[i] = 0 }
        for i in 0..<lp.count { lp[i] = 0 }
        tone = 0; candidate = 0; candidateBlocks = 0
        envSum = 0; envCount = 0; envPeak = 0
        noiseHold = 0
        reading = NDBReading()
        morse = MorseDecoder()
        morse.onText = { [weak self] text in self?.onIdent?(text) }
    }

    /// Eingangspegel (Effektivwert, dB gegen Vollaussteuerung)
    public var inputDB: Double { 20 * log10(Double(inputRMS) + 1e-9) }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        var rms: Float = 0
        vDSP_rmsqv(samples.baseAddress!, 1, &rms, vDSP_Length(samples.count))
        inputRMS += (rms - inputRMS) * 0.2
        let fs = NDBAudio.sampleRate
        let active = fixedToneHz ?? (tone > 0 ? tone : 0)
        let w = 2 * Double.pi * active / fs
        let alpha = Float(1 - exp(-2 * Double.pi * 28 / fs))
        for s in samples {
            // Spektrum
            ring[ringPos] = s
            ringPos = (ringPos + 1) % Self.fftSize
            sinceFFT += 1
            if sinceFFT >= Self.hop { sinceFFT = 0; analyse() }
            // Mischen auf 0 Hz und dreistufiger Tiefpass (etwa 28 Hz)
            if active > 0 {
                let c = Float(cos(phase)), sn = Float(sin(phase))
                phase += w
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                var i = s * c, q = -s * sn
                for stage in 0..<3 {
                    lp[2 * stage] += (i - lp[2 * stage]) * alpha
                    lp[2 * stage + 1] += (q - lp[2 * stage + 1]) * alpha
                    i = lp[2 * stage]; q = lp[2 * stage + 1]
                }
                envSum += (i * i + q * q).squareRoot() * 2
            }
            envCount += 1
            if envCount >= envPerSample {
                let level = active > 0 ? Double(envSum) / Double(envCount) : 0
                envSum = 0; envCount = 0
                envPeak = max(Float(level), envPeak * 0.999)
                reading.keyed = Double(envPeak) > 0 && level > 0.5 * Double(envPeak) && Double(envPeak) > 1e-4
                morse.push(level)
            }
        }
    }

    private func analyse() {
        // Letzte 1024 Werte in Reihenfolge, Fenster, FFT
        var frame = [Float](repeating: 0, count: Self.fftSize)
        for k in 0..<Self.fftSize { frame[k] = ring[(ringPos + k) % Self.fftSize] * window[k] }
        var real = [Float](repeating: 0, count: Self.fftSize / 2)
        var imag = [Float](repeating: 0, count: Self.fftSize / 2)
        frame.withUnsafeBufferPointer { fp in
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftSize / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.fftSize / 2)) }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
        }
        let n = Self.fftSize / 2
        let binHz = NDBAudio.sampleRate / Double(Self.fftSize)
        for k in 0..<n {
            instant[k] = (real[k] * real[k] + imag[k] * imag[k]) / Float(Self.fftSize * Self.fftSize) * 4
            hold[k] = max(instant[k], hold[k] * 0.985)
        }
        let lo = Int(250 / binHz), hi = Int(2400 / binHz)
        // Rauschen: Mittelwert der unteren Hälfte der Werte (ohne die stärksten Bins)
        var sorted = Array(hold[lo..<hi])
        sorted.sort()
        let median = sorted[sorted.count / 2]
        let noiseInst = Array(instant[lo..<hi]).sorted()[(hi - lo) / 2]
        noiseHold += (noiseInst - noiseHold) * 0.1
        // Spitze
        var peak = lo
        var best: Float = 0
        for k in lo..<hi {
            let v = hold[k - 1] + hold[k] + hold[k + 1]
            if v > best { best = v; peak = k }
        }
        let ratio = Double(hold[peak] / max(median, 1e-12))
        let now = Date()
        if ratio > 8 && hold[peak] > 1e-9 {
            // Parabel durch die drei Bins (Logarithmus)
            let a = log(Double(max(hold[peak - 1], 1e-12))), b = log(Double(max(hold[peak], 1e-12))), c = log(Double(max(hold[peak + 1], 1e-12)))
            let denom = a - 2 * b + c
            let shift = denom != 0 ? 0.5 * (a - c) / denom : 0
            let f = (Double(peak) + max(-0.5, min(0.5, shift))) * binHz
            lastToneSeen = now
            if tone == 0 {
                tone = f
            } else if abs(f - tone) < 14 {
                tone += (f - tone) * 0.2
                candidate = 0; candidateBlocks = 0
            } else {
                // Anderer Ton: erst nach mehreren Blöcken übernehmen
                if abs(f - candidate) < 14 { candidateBlocks += 1 } else { candidate = f; candidateBlocks = 1 }
                if candidateBlocks >= 12 { tone = f; candidate = 0; candidateBlocks = 0 }
            }
            reading.toneDB = 10 * log10(Double(hold[peak] * 3) + 1e-12)
            reading.snrDB = 10 * log10(ratio)
        } else if tone > 0, now.timeIntervalSince(lastToneSeen) > 20 {
            tone = 0
            reading.snrDB = 0
        }
        reading.present = tone > 0 || fixedToneHz != nil
        reading.toneHz = fixedToneHz ?? tone
        reading.noiseDB = 10 * log10(Double(max(noiseHold, 1e-12)))
    }
}

// MARK: - Kennungen sammeln

/// Sammelt gelesene Kennungen: bestätigt ist, was zweimal in den letzten Lesungen vorkam
public struct NDBIdentTracker: Sendable {
    public struct Read: Sendable, Equatable { public var text: String; public var time: Date }
    public private(set) var reads: [Read] = []
    public private(set) var ident = ""
    public private(set) var confirmed = false
    public var maxReads = 8

    public init() {}

    public mutating func reset() {
        reads.removeAll(); ident = ""; confirmed = false
    }

    /// Eine Lesung aufnehmen; Rückgabe: `true`, wenn die Kennung neu bestätigt wurde
    @discardableResult
    public mutating func add(_ text: String, at time: Date = Date()) -> Bool {
        reads.append(Read(text: text, time: time))
        if reads.count > maxReads { reads.removeFirst(reads.count - maxReads) }
        var counts: [String: Int] = [:]
        for r in reads { counts[r.text, default: 0] += 1 }
        let best = counts.max { a, b in a.value != b.value ? a.value < b.value : (reads.lastIndex { $0.text == a.key } ?? 0) < (reads.lastIndex { $0.text == b.key } ?? 0) }
        let wasConfirmed = confirmed && ident == best?.key
        if let best, best.value >= 2 {
            ident = best.key
            confirmed = true
        } else {
            ident = text
            confirmed = false
        }
        return confirmed && !wasConfirmed
    }
}

// MARK: - Testsignale

public enum NDBSignalGenerator {
    /// Getastete Kennung als Audio (8 kHz): Ton an während der Morsezeichen, Rauschen mit Verhältnis `snrDB` (Ton zu Rauschen in 3 kHz)
    /// - Parameters:
    ///   - dit: Länge eines Punkts in Sekunden (NDB: etwa 0,1 bis 0,2 s)
    ///   - repeatEvery: Abstand der Wiederholungen
    public static func audio(ident: String, toneHz: Double, dit: Double = 0.12, repeatEvery: Double = 12, seconds: Double, start: Double = 1,
                             snrDB: Double? = nil, rate: Double = NDBAudio.sampleRate) -> [Float] {
        var out = [Float](repeating: 0, count: Int(seconds * rate))
        let elements = NavSignalGenerator.morseElements(ident, dit: dit)
        var t0 = start
        while t0 < seconds {
            var t = t0
            for (on, d) in elements {
                if on {
                    let a = Int(t * rate), b = min(out.count, Int((t + d) * rate))
                    if a < b {
                        for i in a..<b {
                            // Flanken 5 ms
                            let tt = Double(i) / rate
                            var env = 1.0
                            env = min(env, (tt - t) / 0.005, (t + d - tt) / 0.005)
                            out[i] = Float(0.3 * max(0, min(1, env)) * sin(2 * Double.pi * toneHz * tt))
                        }
                    }
                }
                t += d
            }
            t0 += repeatEvery
        }
        if let snrDB {
            // Rauschleistung in 3 kHz so, dass Ton (Effektivwert 0,3/√2) um snr darüber liegt; Bandbreite 4 kHz → Skalierung
            let toneRMS = 0.3 / 2.0.squareRoot()
            let sigma = Float(toneRMS * pow(10, -snrDB / 20) * (4000.0 / 3000.0).squareRoot())
            for i in 0..<out.count { out[i] += sigma * gauss() }
        }
        return out
    }

    private static func gauss() -> Float {
        (-2 * log(Float.random(in: 1e-7...1))).squareRoot() * cos(2 * .pi * Float.random(in: 0...1))
    }
}
