// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// DRM30-Empfänger: Eingang reelles Audio (48 kHz, das Signal irgendwo zwischen 3 und 21 kHz, z. B. USB-Audio eines Empfängers mit 10 bis 20 kHz Breite)
// oder komplexes Basisband. Ablauf: analytisches Signal (Hilbert) → Erfassung (Guard-Intervall-Korrelation für Modus, Takt und Bruchteil der
// Frequenz, Pilotsuche für die ganzzahlige Trägerlage, Rahmenbeginn durch Dekodieren des FAC) → Nachführung (Frequenz, Takt) → Kanalschätzung
// aus den Piloten → FAC, SDC, MSC → Audio-Überrahmen.

public struct DRMStatus: Equatable, Sendable {
    public var locked = false
    public var mode: DRMMode?
    public var occupancy: DRMOccupancy?
    public var longInterleaver = true
    public var mscMode = 0
    public var sdcMode = 0
    public var services: [DRMService] = []
    public var streams: [DRMStream] = []
    public var protectionA = 0
    public var protectionB = 0
    /// Signal-Rausch-Verhältnis aus den FAC-Zellen in dB
    public var snr = 0.0
    public var frequencyOffset = 0.0
    public var facGood = 0, facBad = 0, sdcGood = 0, sdcBad = 0
    public var mscFrames = 0, audioFramesGood = 0, audioFramesBad = 0
    public var date: (year: Int, month: Int, day: Int, minutes: Int)?

    public static func == (a: DRMStatus, b: DRMStatus) -> Bool {
        a.locked == b.locked && a.mode == b.mode && a.occupancy == b.occupancy && a.services == b.services && a.streams == b.streams && a.snr == b.snr
            && a.facGood == b.facGood && a.facBad == b.facBad && a.sdcGood == b.sdcGood && a.sdcBad == b.sdcBad && a.mscFrames == b.mscFrames
            && a.audioFramesGood == b.audioFramesGood && a.audioFramesBad == b.audioFramesBad
    }
}

/// Die AAC-Rahmen eines Audio-Überrahmens (400 ms): je Rahmen CRC-Byte vorn, dann die Daten (so erwartet es der DRM-Modus von FAAD2)
public struct DRMAudioUnit: Sendable {
    public var shortID: Int
    public var param: DRMAudioParam
    public var frames: [[UInt8]]
    /// Textnachrichten-Bytes (4 je Überrahmen), falls die Textkennung gesetzt ist
    public var text: [UInt8]?
}

public enum DRMEvent: Sendable {
    case status(DRMStatus)
    case audio(DRMAudioUnit)
    case text(String)
}

public final class DRMReceiver {
    nonisolated(unsafe) public static var debug = ProcessInfo.processInfo.environment["DRM_DEBUG"] != nil
    public var onEvent: ((DRMEvent) -> Void)?
    /// Für Prüfungen: die decodierten Bytes jedes MSC-Rahmens (Teil A, dann Teil B), unabhängig vom Inhalt
    public var onMSCFrame: (([UInt8]) -> Void)?
    public private(set) var status = DRMStatus()
    public let sampleRate = 48_000.0
    /// Dienst, dessen Audio ausgegeben wird (Kurzkennung 0 … 3)
    public var selectedService = 0

    // Analytisches Signal
    private let hilbertHalf = 127
    private var hilbert: [Float] = []
    private var ringRe: [Float]
    private var ringPos = 0

    // Puffer des analytischen Signals
    private var bufRe: [Float] = []
    private var bufIm: [Float] = []
    private var base = 0                                   // absoluter Index von buf[0]
    private var total: Int { base + bufRe.count }

    private enum State { case search, locked }
    private var state = State.search
    private var lastAcquire = 0

    // Erfassung / Nachführung
    private var mode = DRMMode.b
    private var fft = DRMFFT(size: 1024)
    private var map: DRMCellMap?
    private var centerBin = 0                              // FFT-Bin von Träger 0
    private var symbolPos = 0.0                            // absoluter Index des Beginns (Guard) des nächsten auszuwertenden Symbols
    private var freqOffset = 0.0                           // Hz, aus dem Signal herauszudrehen
    private var phaseRef = 0.0
    private var phaseRefIndex = 0
    private var earlyShift = 0
    private var kLo = 0, kHi = 0

    // Symbole
    private var rowsRe: [[Float]] = []
    private var rowsIm: [[Float]] = []
    private var rowBase = 0                                // absoluter Symbolindex von rows[0]
    private var frameAlign = 0                             // absoluter Symbolindex eines Rahmenanfangs (mod symbolsPerFrame)
    private var nextFrame = 0                              // absoluter Symbolindex des nächsten zu dekodierenden Rahmens
    private var symbolCounter = 0                          // absoluter Index des nächsten zu liefernden Symbols

    // Rahmen und Überrahmen
    private var fac: DRMFAC?
    private var frameInSuperframe = 0
    private var facFailures = 0
    private var sdc: DRMSDC?
    private var sdcOK = false
    private var superCells: [(Float, Float)] = []
    private var superWeights: [Float] = []
    private var deintMemory: [[(Float, Float)]] = []
    private var deintWeights: [[Float]] = []
    private var deintIndex = [0, 1, 2, 3, 4]
    private var deintFill = 0
    private var snrFilter = 0.0
    private var delayFilter = 0.0
    private var lastDelay = 0.0
    /// Summe der Verschiebungen des FFT-Fensters (Abtastwerte): die Zeilen werden um die dadurch entstandene Phasensteigung zurückgedreht, damit der Kanalschätzer keine Sprünge sieht
    private var cumulativeSlip = 0
    private var mscDeinterleaverTable: [Int] = []

    public init() {
        ringRe = [Float](repeating: 0, count: 2 * hilbertHalf + 1)
        var h = [Float](repeating: 0, count: 2 * hilbertHalf + 1)
        for i in -hilbertHalf...hilbertHalf where i % 2 != 0 {
            let w = 0.42 + 0.5 * cos(Double.pi * Double(i) / Double(hilbertHalf + 1)) + 0.08 * cos(2 * Double.pi * Double(i) / Double(hilbertHalf + 1))
            h[i + hilbertHalf] = Float(2 / (Double.pi * Double(i)) * w)
        }
        hilbert = h
    }

    public func reset() {
        ringRe = [Float](repeating: 0, count: ringRe.count)
        ringPos = 0
        bufRe.removeAll(); bufIm.removeAll()
        base = 0
        state = .search
        lastAcquire = 0
        map = nil
        rowsRe.removeAll(); rowsIm.removeAll()
        fac = nil; sdc = nil; sdcOK = false
        deintMemory = []
        status = DRMStatus()
    }

    // MARK: Eingang

    /// Reelles Audio (48 kHz)
    public func process(_ samples: [Float]) {
        var re = [Float](repeating: 0, count: samples.count)
        var im = [Float](repeating: 0, count: samples.count)
        let n = hilbert.count
        for (k, x) in samples.enumerated() {
            ringRe[ringPos] = x
            ringPos += 1
            if ringPos == n { ringPos = 0 }
            // Ring: ältester Wert bei ringPos. Der Mittelwert (Verzögerung) steht um hilbertHalf Schritte zurück.
            var acc: Float = 0
            var idx = ringPos
            for t in 0..<n {
                acc += hilbert[n - 1 - t] * ringRe[idx]
                idx += 1
                if idx == n { idx = 0 }
            }
            let mid = (ringPos + hilbertHalf) % n
            re[k] = ringRe[mid]
            im[k] = acc
        }
        processComplex(re: re, im: im)
    }

    /// Komplexes Basisband (48 kHz)
    public func processComplex(re: [Float], im: [Float]) {
        bufRe += re; bufIm += im
        run()
        trim()
    }

    private func trim() {
        // Puffer begrenzen: im Suchen die letzten 1,5 s, sonst ab dem ältesten noch gebrauchten Symbol
        let keepFrom: Int
        if state == .search { keepFrom = total - Int(1.5 * sampleRate) }
        else { keepFrom = Int(symbolPos) - 4 * mode.symbolSize }
        let drop = keepFrom - base
        if drop > 100_000, drop < bufRe.count {
            bufRe.removeFirst(drop); bufIm.removeFirst(drop)
            base += drop
        }
    }

    private func run() {
        switch state {
        case .search:
            let window = Int(1.2 * sampleRate)
            guard total - base >= window, total - lastAcquire >= Int(0.4 * sampleRate) else { return }
            lastAcquire = total
            acquire(window: window)
        case .locked:
            track()
        }
    }

    // MARK: Hilfsfunktionen

    private func sample(_ n: Int) -> (Float, Float) { (bufRe[n - base], bufIm[n - base]) }

    /// FFT-Bins eines Symbols; `start`: absoluter Index des ersten Abtastwertes der FFT-Eingabe
    private func transform(at start: Int, df: Double, ref: Int, refPhase: Double, fft f: DRMFFT, size n: Int) -> (re: [Float], im: [Float]) {
        var re = [Float](repeating: 0, count: n), im = [Float](repeating: 0, count: n)
        let step = -2 * Double.pi * df / sampleRate
        var phase = refPhase + step * Double(start - ref)
        var c = Float(cos(phase)), s = Float(sin(phase))
        let dc = Float(cos(step)), ds = Float(sin(step))
        let off = start - base
        for i in 0..<n {
            let xr = bufRe[off + i], xi = bufIm[off + i]
            re[i] = xr * c - xi * s
            im[i] = xr * s + xi * c
            let nc = c * dc - s * ds, ns = s * dc + c * ds
            c = nc; s = ns
            if i & 511 == 511 {                               // Amplitude nachziehen
                phase += step * 512
                c = Float(cos(phase)); s = Float(sin(phase))
            }
        }
        return f.forward(re, im)
    }

    // MARK: Erfassung

    private struct Candidate { var mode: DRMMode; var offset: Int; var df: Double; var score: Float }

    private func acquire(window: Int) {
        let start = total - window
        var best: Candidate?
        var scores: [Float] = []
        for m in DRMMode.allCases {
            let tu = m.fftSize, tg = m.guardSize, ts = m.symbolSize
            let len = window - tu
            guard len > 3 * ts else { continue }
            // p[n] = x[n] · conj(x[n + Tu]), Fenstersumme über Tg
            var pr = [Float](repeating: 0, count: len + 1), pi = [Float](repeating: 0, count: len + 1)
            var energy: Float = 0
            var cr: Float = 0, ci: Float = 0
            for n in 0..<len {
                let a = sample(start + n), b = sample(start + n + tu)
                cr += a.0 * b.0 + a.1 * b.1
                ci += a.1 * b.0 - a.0 * b.1
                pr[n + 1] = cr; pi[n + 1] = ci
                energy += a.0 * a.0 + a.1 * a.1
            }
            guard energy > 1e-9 else { continue }
            var foldRe = [Float](repeating: 0, count: ts), foldIm = [Float](repeating: 0, count: ts)
            for n in 0..<(len - tg) {
                let r = pr[n + tg] - pr[n], i = pi[n + tg] - pi[n]
                foldRe[n % ts] += r; foldIm[n % ts] += i
            }
            var peak: Float = 0, at = 0
            var mean: Float = 0
            for t in 0..<ts {
                let a = (foldRe[t] * foldRe[t] + foldIm[t] * foldIm[t]).squareRoot()
                mean += a
                if a > peak { peak = a; at = t }
            }
            mean /= Float(ts)
            let symbols = Float(len - tg) / Float(ts)
            let norm = energy / Float(len) * Float(tg) * symbols
            let score = peak / max(norm, 1e-12)
            scores.append(score)
            let contrast = peak / max(mean, 1e-12)
            if DRMReceiver.debug { fputs("DRM acquire mode \(m.letter) score \(score) contrast \(contrast) at \(at)\n", stderr) }
            if score > 0.3, contrast > 1.4, score > (best?.score ?? 0) {
                let df = -Double(atan2(foldIm[at], foldRe[at])) * sampleRate / (2 * Double.pi * Double(tu))
                best = Candidate(mode: m, offset: start + at, df: df, score: score)
            }
        }
        guard let cand = best else { return }
        // zweitbester Modus muss deutlich schlechter sein
        let sorted = scores.sorted(by: >)
        if sorted.count > 1, sorted[1] > 0.6 * cand.score { return }
        establish(cand, start: start, window: window)
    }

    /// Mit Modus, Takt und Bruchteil der Frequenz die Trägerlage und den Rahmenbeginn suchen (FAC als Prüfung)
    private func establish(_ cand: Candidate, start: Int, window: Int) {
        let m = cand.mode
        let tu = m.fftSize, ts = m.symbolSize, tg = m.guardSize
        let f = DRMFFT(size: tu)
        let early = tg / 4
        // Symbole der Erfassungsfenster; FFT-Fenster beginnt `early` Abtastwerte vor dem Beginn des nutzbaren Teils
        var first = cand.offset
        while first < start + 2 * ts { first += ts }
        var spectra: [(re: [Float], im: [Float])] = []
        var pos = first
        let phaseRef0 = 0.0
        while pos + tg - early + tu <= total, spectra.count < 70 {
            spectra.append(transform(at: pos + tg - early, df: cand.df, ref: first, refPhase: phaseRef0, fft: f, size: tu))
            pos += ts
        }
        guard spectra.count >= 2 * m.symbolsPerFrame + 4 else { return }
        // Trägerlage: frequenzstabile Pilote (an festen Trägern, konstante Phase von Symbol zu Symbol)
        let pilots = DRMTables.freqPilotsFor(m)
        let pilotCarriers = [pilots[0], pilots[2], pilots[4]]
        var bestD = -1
        var bestScore: Float = 0, second: Float = 0
        let dLow = 4, dHigh = tu / 2 - 2 - (pilotCarriers.max() ?? 0)
        guard dHigh > dLow else { return }
        for d in dLow...dHigh {
            var minCoherence: Float = 1
            for kp in pilotCarriers {
                let b = d + kp
                var sumRe: Float = 0, sumIm: Float = 0, norm: Float = 0
                for s in 1..<spectra.count {
                    let a = spectra[s], p = spectra[s - 1]
                    sumRe += a.re[b] * p.re[b] + a.im[b] * p.im[b]
                    sumIm += a.im[b] * p.re[b] - a.re[b] * p.im[b]
                    norm += ((a.re[b] * a.re[b] + a.im[b] * a.im[b]) * (p.re[b] * p.re[b] + p.im[b] * p.im[b])).squareRoot()
                }
                minCoherence = min(minCoherence, (sumRe * sumRe + sumIm * sumIm).squareRoot() / max(norm, 1e-12))
                if minCoherence < 0.2 { break }
            }
            let sc = minCoherence
            if DRMReceiver.debug && sc > 0.4 { fputs("  d \(d) sc \(sc)\n", stderr) }
            if sc > bestScore { second = bestScore; bestScore = sc; bestD = d } else if sc > second { second = sc }
        }
        if DRMReceiver.debug { fputs("DRM carrier search: best d \(bestD) score \(bestScore) second \(second)\n", stderr) }
        guard bestD >= 0, bestScore > 0.5, bestScore > 1.6 * second else { return }
        // Träger 0 mit der gesamten Frequenz (ganzzahliger Anteil dΔf plus Bruchteil) auf Gleichanteil mischen: dann drehen sich die Zellen nicht von Symbol zu Symbol
        let dfTotal = cand.df + Double(bestD) * m.carrierSpacing
        spectra.removeAll(keepingCapacity: true)
        pos = first
        while pos + tg - early + tu <= total, spectra.count < 70 {
            spectra.append(transform(at: pos + tg - early, df: dfTotal, ref: first, refPhase: phaseRef0, fft: f, size: tu))
            pos += ts
        }
        let zeroBin = bestD
        _ = zeroBin
        // Belegung aus dem mittleren Leistungsspektrum
        let occupancy = guessOccupancy(spectra: spectra, d: 0, mode: m)
        let cellMap = DRMCellMap(mode: m, occupancy: occupancy)
        if DRMReceiver.debug { fputs("DRM occupancy guess \(occupancy.title)\n", stderr) }
        // Rahmenbeginn: jeden möglichen Beginn über den FAC prüfen
        let uLo = DRMOccupancy.allCases.map { DRMTables.kmin(m, $0) }.min()!
        let uHi = DRMOccupancy.allCases.map { DRMTables.kmax(m, $0) }.max()!
        func rowFor(_ s: Int) -> (re: [Float], im: [Float]) {
            var re = [Float](repeating: 0, count: uHi - uLo + 1), im = re
            for k in uLo...uHi {
                let b = ((k % tu) + tu) % tu
                re[k - uLo] = spectra[s].re[b]; im[k - uLo] = spectra[s].im[b]
            }
            return (re, im)
        }
        let rows = (0..<spectra.count).map { rowFor($0) }
        let rowsRe = rows.map { $0.re }, rowsIm = rows.map { $0.im }
        let F = m.symbolsPerFrame
        for j in 0..<F {
            // Rahmen ab Symbol j (im Fenster); Vorlauf wird durch Festhalten ersetzt
            guard j + F + y(m) < rows.count else { continue }
            let est = estimate(rowsRe: rowsRe, rowsIm: rowsIm, first: j, frameAlign: j, kLo: uLo, map: cellMap, rowBase: 0)
            if let (facInfo, _) = decodeFAC(first: j, rowsRe: rowsRe, rowsIm: rowsIm, est: est, kLo: uLo, map: cellMap), let facv = facInfo {
                // gefunden: Zustand aufbauen
                mode = m
                fft = f
                map = DRMCellMap(mode: m, occupancy: facv.occupancy)
                centerBin = 0
                kLo = uLo; kHi = uHi
                earlyShift = early
                freqOffset = dfTotal
                phaseRef = phaseRef0
                phaseRefIndex = first
                // Das nächste auszuwertende Symbol ist das erste hinter den bereits vorliegenden Zeilen
                symbolPos = Double(first + rows.count * ts)
                self.rowsRe = rowsRe
                self.rowsIm = rowsIm
                rowBase = 0
                symbolCounter = rows.count
                frameAlign = j
                nextFrame = j
                fac = facv
                frameInSuperframe = facv.frameIdentity
                facFailures = 0
                cumulativeSlip = 0
                delayFilter = 0
                sdc = nil; sdcOK = false
                deintMemory = []
                deintFill = 0
                deintIndex = [0, 1, 2, 3, 4]
                superCells = []; superWeights = []
                // Frames vor der Erfassung nicht erneut auswerten: ab dem erkannten Rahmen, aber den Überrahmen neu beginnen lassen
                status.locked = true
                status.mode = m
                status.occupancy = facv.occupancy
                state = .locked
                emitStatus()
                return
            }
        }
    }

    private func y(_ m: DRMMode) -> Int { m.scatY }

    private func guessOccupancy(spectra: [(re: [Float], im: [Float])], d: Int, mode m: DRMMode) -> DRMOccupancy {
        let tu = m.fftSize
        let uLo = DRMOccupancy.allCases.map { DRMTables.kmin(m, $0) }.min()! - 12
        let uHi = DRMOccupancy.allCases.map { DRMTables.kmax(m, $0) }.max()! + 12
        var power = [Float](repeating: 0, count: uHi - uLo + 1)
        for s in spectra {
            for k in uLo...uHi {
                let b = ((d + k) % tu + tu) % tu
                power[k - uLo] += s.re[b] * s.re[b] + s.im[b] * s.im[b]
            }
        }
        func mean(_ a: Int, _ b: Int) -> Float {
            guard b >= a else { return 0 }
            var sum: Float = 0
            for k in a...b where k - uLo >= 0 && k - uLo < power.count { sum += power[k - uLo] }
            return sum / Float(b - a + 1)
        }
        var bestOcc = DRMOccupancy.khz10
        var bestScore = -Float.infinity
        for o in DRMOccupancy.allCases {
            let lo = DRMTables.kmin(m, o), hi = DRMTables.kmax(m, o)
            let inside = mean(lo + 2, hi - 2)
            let below = mean(lo - 10, lo - 3), above = mean(hi + 3, hi + 10)
            // Energie innen minus Außenbereiche, normiert; Sprünge an beiden Kanten
            let score = (inside - 0.5 * (below + above)) / max(inside, 1e-12) * (hi - lo > 0 ? 1 : 0) + Float(hi - lo) * 1e-4
            if score > bestScore { bestScore = score; bestOcc = o }
        }
        return bestOcc
    }

    // MARK: Kanalschätzung

    /// Kanalschätzung für den Rahmen ab Symbol `first` (Index in `rows`). Rückgabe: H je Symbol des Rahmens und Träger (Träger − map.kmin)
    private func estimate(rowsRe: [[Float]], rowsIm: [[Float]], first: Int, frameAlign: Int, kLo: Int, map: DRMCellMap, rowBase: Int) -> (re: [[Float]], im: [[Float]]) {
        let m = map.mode
        let F = m.symbolsPerFrame
        let yTime = m.scatY
        let nCar = map.carriers
        let from = max(0, first - yTime - 1), to = min(rowsRe.count, first + F + yTime + 1)
        // Beobachtungen an den Piloten
        var obsCols: [Int: [(sym: Int, re: Float, im: Float)]] = [:]
        for a in from..<to {
            let fs = (((a - frameAlign) % F) + F) % F
            for i in 0..<nCar where map.isPilot(fs, i) {
                let p = map.pilot(fs, i)
                let pp = p.re * p.re + p.im * p.im
                guard pp > 0 else { continue }
                let xr = rowsRe[a][map.kmin + i - kLo], xi = rowsIm[a][map.kmin + i - kLo]
                obsCols[i, default: []].append((a, (xr * p.re + xi * p.im) / pp, (xi * p.re - xr * p.im) / pp))
            }
        }
        let cols = obsCols.keys.sorted()
        // Zeitliche Interpolation je Pilotträger auf die Symbole des Rahmens
        var colRe = [[Float]](repeating: [Float](repeating: 0, count: F), count: cols.count)
        var colIm = colRe
        for (ci, c) in cols.enumerated() {
            let obs = obsCols[c]!.sorted { $0.sym < $1.sym }
            for k in 0..<F {
                let a = first + k
                var left: Int?, right: Int?
                for (idx, o) in obs.enumerated() { if o.sym <= a { left = idx } else { right = idx; break } }
                if let l = left, let r = right, obs[l].sym != obs[r].sym {
                    let t = Float(a - obs[l].sym) / Float(obs[r].sym - obs[l].sym)
                    colRe[ci][k] = obs[l].re + (obs[r].re - obs[l].re) * t
                    colIm[ci][k] = obs[l].im + (obs[r].im - obs[l].im) * t
                } else if let l = left { colRe[ci][k] = obs[l].re; colIm[ci][k] = obs[l].im }
                else if let r = right { colRe[ci][k] = obs[r].re; colIm[ci][k] = obs[r].im }
            }
        }
        // Frequenzinterpolation je Symbol (mit Entdrehung der mittleren Phasensteigung)
        var hRe = [[Float]](repeating: [Float](repeating: 0, count: nCar), count: F)
        var hIm = hRe
        guard cols.count >= 2 else { return (hRe, hIm) }
        for k in 0..<F {
            // Steigung der Phase je Träger aus benachbarten Pilotträgern
            var sr: Float = 0, si: Float = 0
            for ci in 0..<(cols.count - 1) {
                let dc = Float(cols[ci + 1] - cols[ci])
                guard dc > 0 else { continue }
                let ar = colRe[ci + 1][k] * colRe[ci][k] + colIm[ci + 1][k] * colIm[ci][k]
                let ai = colIm[ci + 1][k] * colRe[ci][k] - colRe[ci + 1][k] * colIm[ci][k]
                let ang = atan2(ai, ar) / dc
                let w = (ar * ar + ai * ai).squareRoot()
                sr += w * cos(ang); si += w * sin(ang)
            }
            let slope = atan2(si, sr)                           // Radiant je Träger
            // entdrehte Stützstellen
            var dr = [Float](repeating: 0, count: cols.count), di = dr
            for ci in 0..<cols.count {
                let a = -slope * Float(cols[ci])
                let c = cos(a), s = sin(a)
                dr[ci] = colRe[ci][k] * c - colIm[ci][k] * s
                di[ci] = colRe[ci][k] * s + colIm[ci][k] * c
            }
            var seg = 0
            for i in 0..<nCar {
                while seg + 1 < cols.count - 1, cols[seg + 1] < i { seg += 1 }
                let c0 = cols[seg], c1 = cols[min(seg + 1, cols.count - 1)]
                var t: Float = 0
                if c1 > c0 { t = max(0, min(1, Float(i - c0) / Float(c1 - c0))) }
                let r = dr[seg] + (dr[min(seg + 1, cols.count - 1)] - dr[seg]) * t
                let im = di[seg] + (di[min(seg + 1, cols.count - 1)] - di[seg]) * t
                let a = slope * Float(i)
                let c = cos(a), s = sin(a)
                hRe[k][i] = r * c - im * s
                hIm[k][i] = r * s + im * c
            }
            lastSlope = slope
        }
        return (hRe, hIm)
    }

    private var lastSlope: Float = 0

    // MARK: FAC

    /// Entzerrte Zellen des FAC eines Rahmens und Decodierung; Rückgabe: ((FAC oder nil), SNR) oder nil bei fehlenden Daten
    private func decodeFAC(first: Int, rowsRe: [[Float]], rowsIm: [[Float]], est: (re: [[Float]], im: [[Float]]), kLo: Int, map: DRMCellMap) -> (DRMFAC?, Float)? {
        var cells: [(Float, Float)] = []
        var weights: [Float] = []
        for c in map.facCells {
            let a = first + c.symbol
            guard a < rowsRe.count else { return nil }
            let hr = est.re[c.symbol][c.index], hi = est.im[c.symbol][c.index]
            let hh = hr * hr + hi * hi
            guard hh > 1e-12 else { return (nil, 0) }
            let xr = rowsRe[a][map.kmin + c.index - kLo], xi = rowsIm[a][map.kmin + c.index - kLo]
            cells.append(((xr * hr + xi * hi) / hh, (xi * hr - xr * hi) / hh))
            weights.append(hh)
        }
        let r = DRMCoding.decode(cells: cells, weights: weights, layout: DRMBlockLayout.fac(), iterations: 0)
        // SNR aus dem Abstand der Zellen von den 4-QAM-Punkten
        var err: Float = 0
        for (re, im) in cells {
            let er = abs(re) - 0.7071068, ei = abs(im) - 0.7071068
            err += er * er + ei * ei
        }
        let snr = 1 / max(err / Float(cells.count), 1e-9)
        return (DRMFAC.parse(r.bits), snr)
    }

    // MARK: Nachführung und Dekodierung

    private func track() {
        guard let map = map else { state = .search; return }
        let ts = mode.symbolSize, tu = mode.fftSize, tg = mode.guardSize
        let F = mode.symbolsPerFrame
        // Symbole lesen, soweit die Abtastwerte da sind
        while Int(symbolPos) + tg + tu + 4 <= total {
            let start = Int(symbolPos) + tg - earlyShift
            let spec = transform(at: start, df: freqOffset, ref: phaseRefIndex, refPhase: phaseRef, fft: fft, size: tu)
            // Frequenznachführung aus dem Guard-Intervall dieses Symbols
            var cr: Float = 0, ci: Float = 0
            let g0 = Int(symbolPos)
            for n in 0..<tg {
                let a = sample(g0 + n), b = sample(g0 + n + tu)
                // um die gleiche Drehung korrigieren wie die FFT: wir messen den Restfehler grob im unkorrigierten Signal und ziehen den bekannten Teil ab
                cr += a.0 * b.0 + a.1 * b.1
                ci += a.1 * b.0 - a.0 * b.1
            }
            let total = -Double(atan2(ci, cr)) * sampleRate / (2 * Double.pi * Double(tu))
            // `total` ist der gesamte Fehler im Rohsignal (Bruchteil modulo Trägerabstand); der Rest zum aktuellen Wert ist der Fehler der Korrektur
            let spacing = mode.carrierSpacing
            var diff = total - freqOffset
            diff -= (diff / spacing).rounded() * spacing
            if abs(diff) < spacing / 2 { freqOffsetUpdate(diff * 0.15) }
            var re = [Float](repeating: 0, count: kHi - kLo + 1), im = re
            for k in kLo...kHi {
                let b = ((centerBin + k) % tu + tu) % tu
                if cumulativeSlip == 0 {
                    re[k - kLo] = spec.re[b]; im[k - kLo] = spec.im[b]
                } else {
                    let a = -2 * Double.pi * Double(((k * cumulativeSlip) % tu + tu) % tu) / Double(tu)
                    let c = Float(cos(a)), sn = Float(sin(a))
                    re[k - kLo] = spec.re[b] * c - spec.im[b] * sn
                    im[k - kLo] = spec.re[b] * sn + spec.im[b] * c
                }
            }
            rowsRe.append(re); rowsIm.append(im)
            symbolPos += Double(ts)
            symbolCounter += 1
            _ = map
        }
        // Rahmen auswerten, wenn die Vorschau reicht
        while nextFrame + F + mode.scatY < rowBase + rowsRe.count {
            decodeFrame(at: nextFrame)
            nextFrame += F
            if state == .search { return }
        }
        // alte Zeilen verwerfen
        let keepFrom = nextFrame - F - mode.scatY - 2
        if keepFrom - rowBase > 2 * F, keepFrom > rowBase {
            let d = keepFrom - rowBase
            rowsRe.removeFirst(d); rowsIm.removeFirst(d)
            rowBase += d
        }
    }

    private func freqOffsetUpdate(_ delta: Double) {
        // Phase stetig halten: neue Referenz am aktuellen Symbol
        let n = Int(symbolPos)
        phaseRef += -2 * Double.pi * freqOffset / sampleRate * Double(n - phaseRefIndex)
        phaseRefIndex = n
        freqOffset += delta
    }

    private func decodeFrame(at first: Int) {
        guard let map = map else { return }
        let m = mode
        let F = m.symbolsPerFrame
        let rel = first - rowBase
        let est = estimate(rowsRe: rowsRe, rowsIm: rowsIm, first: rel, frameAlign: frameAlign - rowBase, kLo: kLo, map: map, rowBase: rowBase)
        // Takt nachführen aus der Phasensteigung der Kanalschätzung (Verzögerung des Hauptpfades)
        let slope = Double(lastSlope)
        let delay = -(slope * Double(m.fftSize) / (2 * Double.pi)) - Double(earlyShift) - Double(cumulativeSlip)
        delayFilter += 0.3 * (delay - delayFilter)
        if abs(delayFilter) > 1 {
            let adjust = Int(delayFilter)
            symbolPos += Double(adjust)
            cumulativeSlip += adjust
            delayFilter -= Double(adjust)
        }
        guard let (facResult, snr) = decodeFAC(first: rel, rowsRe: rowsRe, rowsIm: rowsIm, est: est, kLo: kLo, map: map) else { return }
        if DRMReceiver.debug { fputs("DRM frame \(first) fac \(facResult != nil) snr \(snr) slope \(lastSlope) delayFilter \(delayFilter) df \(freqOffset)\n", stderr) }
        guard let f = facResult else {
            status.facBad += 1
            facFailures += 1
            frameInSuperframe = (frameInSuperframe + 1) % 3
            if facFailures >= 6 { dropLock(); return }
            emitStatus()
            return
        }
        facFailures = 0
        status.facGood += 1
        let snrDB = 10 * log10(Double(max(snr, 1e-6)))
        snrFilter = snrFilter == 0 ? snrDB : snrFilter + 0.3 * (snrDB - snrFilter)
        status.snr = snrFilter
        status.frequencyOffset = freqOffset
        // Rahmennummer aus dem FAC: Überrahmenbeginn ist Identität 0
        frameInSuperframe = f.frameIdentity
        if fac?.occupancy != f.occupancy || fac?.mscMode != f.mscMode || fac?.sdcMode != f.sdcMode || fac?.longInterleaver != f.longInterleaver {
            self.map = DRMCellMap(mode: m, occupancy: f.occupancy)
            sdc = nil; sdcOK = false
            deintMemory = []; deintFill = 0; superCells = []; superWeights = []
            status.occupancy = f.occupancy
        }
        fac = f
        status.longInterleaver = f.longInterleaver
        status.mscMode = f.mscMode
        status.sdcMode = f.sdcMode
        updateService(f)
        guard let map = self.map else { return }
        // Zellen dieses Rahmens sammeln (nur nach Überrahmenbeginn vollständig)
        let fi = f.frameIdentity
        if fi == 0 { superCells = []; superWeights = []; sdcOK = false }
        if fi == 0 { decodeSDC(first: rel, rowsRe: rowsRe, rowsIm: rowsIm, est: est, map: map) }
        collectMSC(frameInSuper: fi, first: rel, est: est, map: map)
        if fi == 2 { finishSuperframe(map: map, fac: f) }
        emitStatus()
    }

    private func updateService(_ f: DRMFAC) {
        var s = f.service
        if let existing = status.services.first(where: { $0.shortID == s.shortID }) { s.label = existing.label; s.audio = existing.audio }
        if let l = sdc?.labels[s.shortID] { s.label = l }
        if let a = sdc?.audio[s.shortID] { s.audio = a }
        if let i = status.services.firstIndex(where: { $0.shortID == s.shortID }) { status.services[i] = s } else { status.services.append(s); status.services.sort { $0.shortID < $1.shortID } }
    }

    private func decodeSDC(first: Int, rowsRe: [[Float]], rowsIm: [[Float]], est: (re: [[Float]], im: [[Float]]), map: DRMCellMap) {
        guard let f = fac, let layout = DRMBlockLayout.sdc(cells: map.sdcCellsPerSuperframe, scheme: f.sdcScheme) else { return }
        var cells: [(Float, Float)] = [], weights: [Float] = []
        for c in map.sdcCells {
            let a = first + c.symbol
            guard a < rowsRe.count else { status.sdcBad += 1; return }
            let hr = est.re[c.symbol][c.index], hi = est.im[c.symbol][c.index]
            let hh = max(hr * hr + hi * hi, 1e-9)
            let xr = rowsRe[a][map.kmin + c.index - kLo], xi = rowsIm[a][map.kmin + c.index - kLo]
            cells.append(((xr * hr + xi * hi) / hh, (xi * hr - xr * hi) / hh)); weights.append(hh)
        }
        let r = DRMCoding.decode(cells: cells, weights: weights, layout: layout, iterations: 0)
        if let parsed = DRMSDC.parse(r.bits) {
            sdc = parsed
            sdcOK = true
            status.sdcGood += 1
            status.streams = parsed.streams
            status.protectionA = parsed.protectionA
            status.protectionB = parsed.protectionB
            if let mjd = parsed.modifiedJulianDay, let min = parsed.minutesOfDay {
                let d = DRMDate.fromMJD(mjd)
                status.date = (d.year, d.month, d.day, min)
            }
            for i in status.services.indices {
                if let l = parsed.labels[status.services[i].shortID] { status.services[i].label = l }
                if let a = parsed.audio[status.services[i].shortID] { status.services[i].audio = a }
            }
        } else {
            status.sdcBad += 1
        }
    }

    private var textMessage = DRMTextMessage()
    private var frameMSC: [Int: [(Float, Float, Float)]] = [:]

    private func collectMSC(frameInSuper: Int, first: Int, est: (re: [[Float]], im: [[Float]]), map: DRMCellMap) {
        var out: [(Float, Float, Float)] = []
        let F = mode.symbolsPerFrame
        for sym in 0..<F {
            let a = first + sym
            let superSym = frameInSuper * F + sym
            for i in 0..<map.carriers where map.kind[superSym * map.carriers + i] & DRMCellMap.msc != 0 {
                guard a < rowsRe.count else { continue }
                let hr = est.re[sym][i], hi = est.im[sym][i]
                let hh = max(hr * hr + hi * hi, 1e-9)
                let xr = rowsRe[a][map.kmin + i - kLo], xi = rowsIm[a][map.kmin + i - kLo]
                out.append(((xr * hr + xi * hi) / hh, (xi * hr - xr * hi) / hh, hh))
            }
        }
        frameMSC[frameInSuper] = out
    }

    private func finishSuperframe(map: DRMCellMap, fac f: DRMFAC) {
        defer { frameMSC.removeAll() }
        guard let sdc = sdc, sdcOK, let scheme = f.mscScheme, let st = sdc.streams.first, frameMSC.count == 3 else { return }
        let n = map.mscCellsPerFrame
        var all: [(Float, Float, Float)] = frameMSC[0]! + frameMSC[1]! + frameMSC[2]!
        guard all.count >= 3 * n else { return }
        all = Array(all[0..<(3 * n)])
        let depth = f.longInterleaver ? 5 : 1
        if deintMemory.count != 5 || deintMemory[0].count != n {
            deintMemory = [[(Float, Float)]](repeating: [(Float, Float)](repeating: (0, 0), count: n), count: 5)
            deintWeights = [[Float]](repeating: [Float](repeating: 0, count: n), count: 5)
            deintFill = 0
            deintIndex = [0, 1, 2, 3, 4]
            mscDeinterleaverTable = DRMCoding.interleaverTable(n, 5)
        }
        let lenA = sdc.streams.reduce(0) { $0 + $1.lengthA }
        guard let layout = DRMBlockLayout.msc(cells: n, scheme: scheme, lengthA: lenA, protectionA: sdc.protectionA, protectionB: sdc.protectionB) else { return }
        for chunk in 0..<3 {
            let block = Array(all[(chunk * n)..<((chunk + 1) * n)])
            for i in 0..<n {
                let slot = deintIndex[i % depth]
                deintMemory[slot][mscDeinterleaverTable[i]] = (block[i].0, block[i].1)
                deintWeights[slot][mscDeinterleaverTable[i]] = block[i].2
            }
            let out = deintMemory[deintIndex[depth - 1]]
            let outW = deintWeights[deintIndex[depth - 1]]
            for j in 0..<5 { deintIndex[j] -= 1; if deintIndex[j] < 0 { deintIndex[j] = 4 } }
            deintFill += 1
            guard deintFill >= depth else { continue }
            let r = DRMCoding.decode(cells: out, weights: outW, layout: layout, iterations: scheme == .qam16 ? 0 : 1)
            status.mscFrames += 1
            handleMSC(bits: r.bits, layout: layout, sdc: sdc, fac: f, quality: r.quality)
        }
        _ = st
    }

    private func handleMSC(bits: [UInt8], layout: DRMBlockLayout, sdc: DRMSDC, fac f: DRMFAC, quality: Float) {
        if let cb = onMSCFrame { cb(stride(from: 0, to: bits.count - 7, by: 8).map { UInt8(DRMCRC.value(bits[$0..<($0 + 8)])) }) }
        // Dienst und Strom wählen
        let services = status.services
        guard let service = services.first(where: { $0.shortID == selectedService }) ?? services.first(where: { $0.isAudio }),
              let audio = service.audio ?? sdc.audio[service.shortID], audio.coding == .aac else { return }
        let streamIndex = audio.streamID
        guard streamIndex < sdc.streams.count else { return }
        let totalA = sdc.streams.reduce(0) { $0 + $1.lengthA }
        var offA = 0, offB = 0
        for i in 0..<streamIndex { offA += sdc.streams[i].lengthA; offB += sdc.streams[i].lengthB }
        let lenA = sdc.streams[streamIndex].lengthA, lenB = sdc.streams[streamIndex].lengthB
        let bytes = stride(from: 0, to: bits.count - 7, by: 8).map { UInt8(DRMCRC.value(bits[$0..<($0 + 8)])) }
        guard totalA + offB + lenB <= bytes.count else { return }
        let part = Array(bytes[offA..<(offA + lenA)]) + Array(bytes[(totalA + offB)..<(totalA + offB + lenB)])
        var frames = parseAAC(superframe: part, lenA: lenA, lenB: lenB, param: audio)
        var text: [UInt8]?
        if audio.textMessage, part.count >= 4 {
            let piece = Array(part.suffix(4))
            text = piece
            if textMessage.feed(piece) { onEvent?(.text(textMessage.text)) }
        }
        if frames.isEmpty { status.audioFramesBad += audio.framesPerSuperframe; return }
        frames = frames.filter { !$0.isEmpty }
        onEvent?(.audio(DRMAudioUnit(shortID: service.shortID, param: audio, frames: frames, text: text)))
    }

    /// AAC-Überrahmen: Kopf mit Rahmengrenzen (12 Bit je Grenze), CRC-Bytes und der höher geschützte Teil aller Rahmen, dahinter der niedriger geschützte
    func parseAAC(superframe data: [UInt8], lenA: Int, lenB: Int, param: DRMAudioParam) -> [[UInt8]] {
        let n = param.framesPerSuperframe
        let borders = n - 1
        var headerBits = 12 * borders
        if borders == 9 { headerBits += 4 }
        let headerBytes = headerBits / 8
        let textBytes = param.textMessage ? 4 : 0
        let payload = lenA + lenB - headerBytes - n - textBytes
        guard payload > 0, data.count >= lenA + lenB - textBytes, headerBytes <= data.count else { return [] }
        var lengths: [Int] = []
        var previous = 0
        var pos = 0
        func take(_ bits: Int) -> Int {
            var v = 0
            for _ in 0..<bits { v = (v << 1) | Int((data[pos / 8] >> UInt8(7 - pos % 8)) & 1); pos += 1 }
            return v
        }
        var sum = 0
        for _ in 0..<borders {
            var b = take(12)
            if b < previous { b += 4096 }
            lengths.append(b - previous)
            sum += b - previous
            previous = b
        }
        lengths.append(payload - previous)
        guard lengths.allSatisfy({ $0 > 0 }), payload - previous > 0 else { return [] }
        let hp = lenA > 0 ? (lenA - headerBytes - n) / n : 0
        guard lengths.allSatisfy({ $0 >= hp }) else { return [] }
        var higher: [[UInt8]] = [], crc: [UInt8] = []
        var p = headerBytes
        for _ in 0..<n {
            guard p + hp + (lenA > 0 ? 1 : 0) <= data.count else { return [] }
            higher.append(Array(data[p..<(p + hp)]))
            crc.append(lenA > 0 ? data[p + hp] : 0)
            p += hp + (lenA > 0 ? 1 : 0)
        }
        var low = lenA
        var frames: [[UInt8]] = []
        for f in 0..<n {
            let lo = lengths[f] - hp
            guard low + lo <= data.count else { return [] }
            frames.append([crc[f]] + higher[f] + Array(data[low..<(low + lo)]))
            low += lo
        }
        return frames
    }

    private func dropLock() {
        state = .search
        status.locked = false
        lastAcquire = total
        rowsRe.removeAll(); rowsIm.removeAll()
        map = nil
        emitStatus()
    }

    private func emitStatus() {
        status.mode = mode
        onEvent?(.status(status))
    }
}
