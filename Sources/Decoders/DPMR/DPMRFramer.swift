// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// dPMR-Empfänger für FM-Diskriminator-Audio: angepasstes Wurzel-Kosinus-Filter (Roll-off 0,2), Synchronwort FS2 suchen (beide
// Polaritäten, Pearson-Korrelation: unempfindlich gegen Pegel und Gleichanteil), Takt und Pegel aus dem Synchronwort, dann je 372
// Symbole (zwei Nutzrahmen, acht Sprachrahmen) lesen. Das nächste FS2 steht genau 384 Symbole später: dort wird der Takt nachgeführt;
// kommt FS3 (Ende) oder zweimal nichts, endet das Gespräch.
// Der Vierpegel-Empfänger von DMR (Takt aus Nulldurchgängen) eignet sich hier nicht: bei 2400 Symbolen/s mit schmalem Roll-off liegt der
// Takt in den Nulldurchgängen zu unsicher; das bekannte Synchronwort alle 160 ms ist die bessere Quelle.

public struct DPMRVoice: Sendable {
    /// Sprachrahmen (je 9 Byte im Format des Sprachsticks, 4 je Nutzrahmen)
    public var frames: [[UInt8]]
    /// Rahmennummer 0 … 3 des Nutzrahmens (aus dem Steuerkanal, falls lesbar)
    public var frameNumber: Int?
    public var cleanFrames: Int
    public var scrambled: Bool
}

public enum DPMREvent: Sendable {
    case callStart
    case voice(DPMRVoice)
    /// Kennungen und Kanalcode (neu gelesen oder bestätigt): gerufen, rufend, Farbcode, Notruf
    case info(called: String?, calling: String?, colorCode: Int?, emergency: Bool)
    case callEnd(lost: Bool)
}

public struct DPMRFramerStats: Equatable, Sendable {
    public var syncs = 0
    public var superframes = 0
    public var voiceFrames = 0
    public var cleanFrames = 0
    public var cchGood = 0
    public var cchBad = 0
    public var calls = 0
    public var ends = 0
    public var lost = 0
}

public final class DPMRReceiver {
    public var onEvent: ((DPMREvent) -> Void)?
    public private(set) var stats = DPMRFramerStats()
    public private(set) var inverted = false
    /// Halber Abstand der äußeren Pegel (0 = kein Signal)
    public private(set) var level: Float = 0
    public var isLocked: Bool { state != .search }
    public var acquireThreshold: Float = 0.82
    public var trackThreshold: Float = 0.5
    public let sampleRate: Double

    private enum State { case search, payload, expectSync }
    private var state = State.search
    private let sps: Double
    private let taps: [Float]
    private var ring: [Float]
    private var ringPos = 0
    private var y: [Float] = []              // gefilterte Abtastwerte
    private var base = 0                     // absoluter Index von y[0]
    private var searchIndex = 0              // nächster Index der Suche
    private var syncEnd = 0.0                // Zeit (absoluter Index, gebrochen) der Mitte des letzten Synchronsymbols
    private var misses = 0
    private var inCall = false
    /// Ein Gespräch gilt erst als echt, wenn beide Steuerkanäle eines Überrahmens die Prüfsumme bestehen oder das nächste Synchronwort an der erwarteten Stelle steht
    private var confirmed = false
    private var pending: [DPMREvent] = []
    private var pendingStats = DPMRFramerStats()       // Zähler eines noch unbestätigten Fundes (zählen erst mit der Bestätigung)
    private var corrHistory: [Float] = [0, 0]
    private var candidateIndex = 0           // Suchstand beim Fund des Synchronwortes: dort geht es nach einem Zufallstreffer weiter

    // Kennungen
    private var calledID: String?
    private var callingID: String?
    private var colorCode: Int?
    private var emergency = false
    private var lastMode = 0
    private var nextPart = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        sps = sampleRate / DPMR.baud
        let half = max(2, Int((4 * sps).rounded()))
        let alpha = 0.2
        var h = [Double](repeating: 0, count: 2 * half + 1)
        for i in -half...half {
            let t = Double(i) / sps
            var v: Double
            if abs(t) < 1e-9 { v = 1 - alpha + 4 * alpha / Double.pi }
            else if abs(abs(t) - 1 / (4 * alpha)) < 1e-6 { v = alpha / 2.0.squareRoot() * ((1 + 2 / Double.pi) * sin(Double.pi / (4 * alpha)) + (1 - 2 / Double.pi) * cos(Double.pi / (4 * alpha))) }
            else { v = (sin(Double.pi * t * (1 - alpha)) + 4 * alpha * t * cos(Double.pi * t * (1 + alpha))) / (Double.pi * t * (1 - pow(4 * alpha * t, 2))) }
            h[i + half] = v
        }
        let sum = h.reduce(0, +)
        taps = h.map { Float($0 / sum) }
        ring = [Float](repeating: 0, count: taps.count)
    }

    public func reset() {
        ring = [Float](repeating: 0, count: taps.count)
        ringPos = 0
        y.removeAll(keepingCapacity: true)
        base = 0
        searchIndex = 0
        state = .search
        misses = 0
        inCall = false
        confirmed = false
        pending.removeAll()
        inverted = false
        level = 0
        calledID = nil; callingID = nil; colorCode = nil; emergency = false
        lastMode = 0; nextPart = 0
    }

    // MARK: Eingang

    public func process(_ samples: [Float]) {
        let n = taps.count
        for sample in samples {
            ring[ringPos] = sample
            ringPos += 1
            if ringPos == n { ringPos = 0 }
            var acc: Float = 0
            var index = ringPos
            for tap in taps {
                acc += tap * ring[index]
                index += 1
                if index == n { index = 0 }
            }
            y.append(acc)
            advance()
        }
        // Puffer begrenzen: im Suchen ab dem Suchstand, im Gespräch ab dem letzten Synchronwort (ein unbestätigter Fund braucht den Weg zurück)
        let anchor: Double = state == .search ? Double(searchIndex) : (confirmed ? syncEnd : min(syncEnd, Double(candidateIndex)))
        trim(to: Int(anchor - 14 * sps))
    }

    private func trim(to absolute: Int) {
        let drop = absolute - base
        guard drop > 4000, drop < y.count else { return }
        y.removeFirst(drop)
        base += drop
    }

    private var end: Int { base + y.count }                    // erster noch nicht vorhandener absoluter Index

    /// Gefilterter Wert zur Zeit `t` (absoluter, gebrochener Index), linear interpoliert
    private func value(at t: Double) -> Float {
        let i = Int(t.rounded(.down))
        let f = Float(t - Double(i))
        let a = i - base
        guard a >= 0, a + 1 < y.count else { return 0 }
        return y[a] + (y[a + 1] - y[a]) * f
    }

    /// Pearson-Korrelation (−1 … +1) der zwölf Symbole, deren letztes zur Zeit `t` liegt, mit einem Muster
    private func correlation(endingAt t: Double, pattern: [Float]) -> Float {
        let n = pattern.count
        var v = [Float](repeating: 0, count: n)
        for i in 0..<n { v[i] = value(at: t - Double(n - 1 - i) * sps) }
        let mv = v.reduce(0, +) / Float(n), mp = pattern.reduce(0, +) / Float(n)
        var cov: Float = 0, vv: Float = 0, pp: Float = 0
        for i in 0..<n {
            let a = v[i] - mv, b = pattern[i] - mp
            cov += a * b; vv += a * a; pp += b * b
        }
        guard vv > 1e-10, pp > 0 else { return 0 }
        return cov / (vv * pp).squareRoot()
    }

    private func advance() {
        switch state {
        case .search:
            // Korrelation für jeden Abtastwert; Spitze über der Schwelle (mit Parabel verfeinert) löst aus
            while searchIndex + 1 < end {
                let c = correlation(endingAt: Double(searchIndex), pattern: DPMR.fs2)
                corrHistory.append(c)
                if corrHistory.count > 3 { corrHistory.removeFirst() }
                searchIndex += 1
                if corrHistory.count == 3 {
                    let a = abs(corrHistory[0]), b = abs(corrHistory[1]), d = abs(corrHistory[2])
                    if b >= acquireThreshold && b >= a && b > d {
                        let denom = a - 2 * b + d
                        let delta = abs(denom) > 1e-6 ? Double(0.5 * (a - d) / denom) : 0
                        syncEnd = Double(searchIndex - 2) + max(-0.5, min(0.5, delta))
                        candidateIndex = searchIndex
                        inverted = corrHistory[1] < 0
                        misses = 0
                        inCall = false
                        confirmed = false
                        pending.removeAll()
                        corrHistory = [0, 0]
                        state = .payload
                        advance()
                        return
                    }
                }
            }
        case .payload:
            // Erst wenn das nächste Synchronwort da ist: aus seiner Lage ergibt sich der tatsächliche Symbolabstand (Taktfehler von
            // Sender und Soundkarte), mit dem der Überrahmen dazwischen abgetastet wird.
            let nominalNext = syncEnd + Double(DPMR.superframeSymbols + DPMR.syncSymbols) * sps
            let window = max(3, 0.2 * sps)                                   // ±0,2 Symbole Abweichung: bis etwa 500 ppm
            guard Double(end) > nominalNext + window + 2 else { return }
            let pol: Float = inverted ? -1 : 1
            var best: Float = -2
            var bestT = nominalNext
            var t = nominalNext - window
            while t <= nominalNext + window {
                let c = pol * correlation(endingAt: t, pattern: DPMR.fs2)
                if c > best { best = c; bestT = t }
                t += 0.25
            }
            let matched = best >= (confirmed ? trackThreshold : acquireThreshold)
            let c3 = pol * correlation(endingAt: nominalNext, pattern: DPMR.fs3)
            let spacing = matched ? (bestT - syncEnd) / Double(DPMR.superframeSymbols + DPMR.syncSymbols) : sps
            let before = stats
            decodeSuperframe(spacing: spacing)
            if !confirmed {
                pendingStats.superframes += stats.superframes - before.superframes; pendingStats.voiceFrames += stats.voiceFrames - before.voiceFrames
                pendingStats.cleanFrames += stats.cleanFrames - before.cleanFrames; pendingStats.cchGood += stats.cchGood - before.cchGood; pendingStats.cchBad += stats.cchBad - before.cchBad
                stats.superframes = before.superframes; stats.voiceFrames = before.voiceFrames; stats.cleanFrames = before.cleanFrames
                stats.cchGood = before.cchGood; stats.cchBad = before.cchBad
            }
            if matched {
                if confirmed { stats.syncs += 1 }                                    // das Synchronwort am Ende dieses Überrahmens
                confirm()
                misses = 0
                syncEnd = bestT
            } else if c3 >= 0.75 && confirmed {
                finishCall(lost: false)
                stats.ends += 1
                syncEnd = nominalNext
                enterSearch()
                return
            } else {
                misses += 1
                if !confirmed { discard(); searchIndex = candidateIndex; state = .search; corrHistory = [0, 0]; return }       // Zufallstreffer: gleich hinter dem Fund weitersuchen
                if misses >= 2 { finishCall(lost: true); syncEnd = nominalNext; enterSearch(); return }
                syncEnd = nominalNext                                                          // der Takt trägt
            }
            advance()
        case .expectSync:
            state = .payload
        }
    }

    private func enterSearch() {
        state = .search
        searchIndex = max(searchIndex, Int(syncEnd) - Int(2 * sps))
        corrHistory = [0, 0]
    }

    private func emit(_ event: DPMREvent) {
        if confirmed { onEvent?(event) } else { pending.append(event) }
    }

    private func confirm() {
        guard !confirmed else { return }
        confirmed = true
        stats.syncs += 1                                                          // das erste Synchronwort des Gesprächs
        if inCall { stats.calls += 1 }
        stats.superframes += pendingStats.superframes; stats.voiceFrames += pendingStats.voiceFrames; stats.cleanFrames += pendingStats.cleanFrames
        stats.cchGood += pendingStats.cchGood; stats.cchBad += pendingStats.cchBad
        pendingStats = DPMRFramerStats()
        for e in pending { onEvent?(e) }
        pending.removeAll()
    }

    private func discard() {
        pending.removeAll()
        pendingStats = DPMRFramerStats()
        inCall = false
        calledID = nil; callingID = nil; colorCode = nil; emergency = false
        nextPart = 0
        level = 0
    }

    private func finishCall(lost: Bool) {
        guard inCall, confirmed else { discard(); return }
        inCall = false
        if lost { stats.lost += 1 }
        onEvent?(.callEnd(lost: lost))
        calledID = nil; callingID = nil; colorCode = nil; emergency = false
        nextPart = 0
        level = 0
    }

    // MARK: Nutzdaten

    /// Mitte und halber Abstand der äußeren Pegel aus Symbolen, von denen die Vorzeichen bekannt sind
    private func levels(_ symbols: [Float], signs: [Float]) -> (center: Float, half: Float)? {
        var hi: Float = 0, lo: Float = 0, nh = 0, nl = 0
        for (v, p) in zip(symbols, signs) { if p > 0 { hi += v; nh += 1 } else { lo += v; nl += 1 } }
        guard nh > 0, nl > 0 else { return nil }
        hi /= Float(nh); lo /= Float(nl)
        guard hi - lo > 1e-6 else { return nil }
        return ((hi + lo) / 2, (hi - lo) / 2)
    }

    private func decodeSuperframe(spacing: Double) {
        let pol: Float = inverted ? -1 : 1
        let raw: [Float] = (0..<DPMR.superframeSymbols).map { value(at: syncEnd + Double($0 + 1) * spacing) }
        let syncRaw: [Float] = (0..<DPMR.syncSymbols).map { value(at: syncEnd - Double(DPMR.syncSymbols - 1 - $0) * spacing) }
        // Pegel nachführen: der Diskriminator verschiebt sich mit der Frequenzablage des Senders. Anfang: FS2 (bekanntes Muster);
        // Mitte: der Kanalcode (nur äußere Pegel, Vorzeichen nach der alten Mitte).
        let start = levels(syncRaw, signs: DPMR.fs2.map { $0 * pol }) ?? (0, 1)
        var middle = start
        let ccRaw = Array(raw[180..<192])
        if let m = levels(ccRaw, signs: ccRaw.map { $0 > start.center ? 1 : -1 }) { middle = m }
        level = middle.half
        let s: [Float] = raw.enumerated().map { j, v in
            let t = min(1, Float(j) / 186)
            let center = start.center + (middle.center - start.center) * t
            let half = max(start.half + (middle.half - start.half) * t, 1e-6)
            let n = max(-3, min(3, 3 * (v - center) / half))
            return inverted ? -n : n
        }
        stats.superframes += 1
        // Aufteilung nach Symbolen: CCH₀ 0 … 35, TCH₀ … ₃ 36 … 179, CC 180 … 191, CCH₁ 192 … 227, TCH₄ … ₇ 228 … 371
        let cch = [DPMRCCH.decode(DPMRSymbols.bits(s[0..<36])), DPMRCCH.decode(DPMRSymbols.bits(s[192..<228]))]
        let channelCode = DPMR.colorCode(ofBits: DPMRSymbols.bits(s[180..<192]))
        for c in cch { if c.crcOK { stats.cchGood += 1 } else { stats.cchBad += 1 } }
        let bothOK = cch.allSatisfy { $0.crcOK }                           // zwei Prüfsummen zugleich sind kein Zufall (1 : 16 000)
        if !inCall {
            inCall = true
            emit(.callStart)
        }
        updateInfo(cch, colorCode: channelCode)
        if bothOK { confirm() }
        for half in 0..<2 {
            let c = cch[half]
            let usableMode = c.crcOK
            if usableMode { lastMode = c.mode }
            let voice = usableMode ? c.carriesVoice : (lastMode == 0 || lastMode == 1 || lastMode == 5)
            guard voice else { continue }
            let first = half == 0 ? 36 : 228
            var frames: [[UInt8]] = []
            var clean = 0
            for k in 0..<4 {
                let bits = DPMRSymbols.bits(s[(first + 36 * k)..<(first + 36 * k + 36)])
                frames.append(AMBEHalfRate.bytes(fromAir: bits))
                if AMBEHalfRate.isClean(bits) { clean += 1 }
            }
            stats.voiceFrames += 4
            stats.cleanFrames += clean
            emit(.voice(DPMRVoice(frames: frames, frameNumber: c.numberUsable ? c.frameNumber : nil, cleanFrames: clean, scrambled: c.isScrambled && c.crcOK)))
        }
    }

    /// Kennungen aus zwei Nutzrahmen: Teil 1 (Rahmen 0, 1) gerufen, Teil 2 (Rahmen 2, 3) rufend
    private func updateInfo(_ cch: [DPMRCCH], colorCode channelCode: Int?) {
        var changed = false
        var part = 0
        if (cch[0].numberUsable && cch[0].frameNumber == 0) || (cch[1].numberUsable && cch[1].frameNumber == 1) { part = 1 }
        else if (cch[0].numberUsable && cch[0].frameNumber == 2) || (cch[1].numberUsable && cch[1].frameNumber == 3) { part = 2 }
        else { part = nextPart }
        nextPart = part == 1 ? 2 : part == 2 ? 1 : 0
        if part == 1 || part == 2, cch[0].idUsable, cch[1].idUsable {
            let id = UInt32((cch[0].idPart << 12) | cch[1].idPart)
            let text = DPMR.idText(id)
            if part == 1 { if calledID != text { calledID = text; changed = true } } else if callingID != text { callingID = text; changed = true }
        }
        if let cc = channelCode, cc != colorCode, cch[0].crcOK || cch[1].crcOK { colorCode = cc; changed = true }
        let emergencyNow = (cch[0].crcOK && cch[0].emergency) || (cch[1].crcOK && cch[1].emergency)
        if emergencyNow != emergency { emergency = emergencyNow; changed = true }
        if changed { emit(.info(called: calledID, calling: callingID, colorCode: colorCode, emergency: emergency)) }
    }
}
