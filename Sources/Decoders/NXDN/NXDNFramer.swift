// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// NXDN-Empfänger für FM-Diskriminator-Audio: angepasstes Wurzel-Kosinus-Filter (Roll-off 0,2), Synchronwort FSW suchen (beide Polaritäten,
// Pearson-Korrelation: unempfindlich gegen Pegel und Gleichanteil), Takt und Pegel aus dem Synchronwort, dann je Rahmen 182 Symbole lesen.
// Das nächste FSW steht genau 192 Symbole später: dort werden Takt und Pegel nachgeführt (das Rahmenende wartet auf das nächste Wort),
// und ein Zufallstreffer fällt hier durch. Ein Rahmen zählt erst, wenn zwei Synchronwörter im Abstand stehen und das LICH stimmt.
// Zwei Empfänger (2400 und 4800 Bd) laufen nebeneinander auf demselben Audio.

public struct NXDNVoice: Sendable {
    /// Sprachrahmen (je 9 Byte im Format des Sprachsticks): 2 oder 4 je Rahmen
    public var frames: [[UInt8]]
    public var cleanFrames: Int
    /// Chiffrierte Sprache (herstellerspezifischer Scrambler, DES, AES): ohne Schlüssel unhörbar
    public var scrambled: Bool
}

/// Angaben aus dem Rufkopf (VCALL) und dem SACCH
public struct NXDNCallInfo: Equatable, Sendable {
    public var source: Int?
    public var destination: Int?
    public var callType: Int?
    public var option: Int?
    public var cipher: Int?
    public var keyID: Int?
    public var ran: Int?
}

public enum NXDNEvent: Sendable {
    /// Beginn einer Aussendung (Symbolrate 2400 oder 4800)
    case callStart(baud: Double)
    case voice(NXDNVoice)
    case info(NXDNCallInfo)
    case callEnd(lost: Bool)
}

public struct NXDNFramerStats: Equatable, Sendable {
    public var syncs = 0
    public var frames = 0
    public var voiceFrames = 0
    public var cleanFrames = 0
    public var sacchGood = 0
    public var sacchBad = 0
    public var facchGood = 0
    public var facchBad = 0
    public var lichBad = 0
    public var calls = 0
    public var ends = 0
    public var lost = 0

    public static func + (a: NXDNFramerStats, b: NXDNFramerStats) -> NXDNFramerStats {
        var r = a
        r.syncs += b.syncs; r.frames += b.frames; r.voiceFrames += b.voiceFrames; r.cleanFrames += b.cleanFrames
        r.sacchGood += b.sacchGood; r.sacchBad += b.sacchBad; r.facchGood += b.facchGood; r.facchBad += b.facchBad
        r.lichBad += b.lichBad; r.calls += b.calls; r.ends += b.ends; r.lost += b.lost
        return r
    }
}

public final class NXDNReceiver {
    public var onEvent: ((NXDNEvent) -> Void)?
    public private(set) var stats = NXDNFramerStats()
    public private(set) var inverted = false
    /// Abstand der äußeren Pegel (0 = kein Signal)
    public private(set) var level: Float = 0
    public var isLocked: Bool { state != .search && confirmed }
    public var acquireThreshold: Float = 0.82
    public var trackThreshold: Float = 0.5
    public let sampleRate: Double
    public let baud: Double
    public var inCall: Bool { active }

    private enum State { case search, payload }
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
    private var corrHistory: [Float] = [0, 0]
    private var candidateIndex = 0           // Suchstand beim Fund des Synchronwortes: dort geht es nach einem Zufallstreffer weiter
    private var confirmed = false
    private var badLICH = 0

    // Aussendung
    private var active = false
    private var info = NXDNCallInfo()
    private var lastInfo: NXDNCallInfo?
    private var ran: Int?
    private var sacchParts: [[UInt8]?] = [nil, nil, nil, nil]

    public init(sampleRate: Double, baud: Double) {
        self.sampleRate = sampleRate
        self.baud = baud
        sps = sampleRate / baud
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
        confirmed = false
        badLICH = 0
        corrHistory = [0, 0]
        inverted = false
        level = 0
        forgetCall()
    }

    private func forgetCall() {
        active = false
        info = NXDNCallInfo()
        lastInfo = nil
        ran = nil
        sacchParts = [nil, nil, nil, nil]
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
        // Puffer begrenzen: im Suchen ab dem Suchstand, im Rahmenlauf ab dem letzten Synchronwort (ein unbestätigter Fund braucht den Weg zurück)
        let anchor: Double = state == .search ? Double(searchIndex) : (confirmed ? syncEnd : min(syncEnd, Double(candidateIndex)))
        trim(to: Int(anchor - 14 * sps))
    }

    private func trim(to absolute: Int) {
        let drop = absolute - base
        guard drop > 4000, drop < y.count else { return }
        y.removeFirst(drop)
        base += drop
    }

    private var end: Int { base + y.count }

    /// Gefilterter Wert zur Zeit `t` (absoluter, gebrochener Index), linear interpoliert
    private func value(at t: Double) -> Float {
        let i = Int(t.rounded(.down))
        let f = Float(t - Double(i))
        let a = i - base
        guard a >= 0, a + 1 < y.count else { return 0 }
        return y[a] + (y[a + 1] - y[a]) * f
    }

    /// Pearson-Korrelation (−1 … +1) der zehn Symbole, deren letztes zur Zeit `t` liegt, mit dem Synchronwort
    private func correlation(endingAt t: Double) -> Float {
        let pattern = NXDN.fsw
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

    /// Mitte `a` und Steigung `b` (v ≈ a + b · Pegel) aus dem Synchronwort, das zur Zeit `t` endet; b < 0 bei umgekehrter Polarität
    private func fit(endingAt t: Double, spacing: Double) -> (a: Float, b: Float)? {
        let p = NXDN.fsw
        var sum: Float = 0, dot: Float = 0
        for i in 0..<p.count {
            let v = value(at: t - Double(p.count - 1 - i) * spacing)
            sum += v
            dot += v * p[i]
        }
        let mean = sum / Float(p.count)
        let energy = p.reduce(0) { $0 + $1 * $1 }
        let slope = dot / energy
        guard abs(slope) > 1e-6 else { return nil }
        return (mean, slope)
    }

    private func advance() {
        switch state {
        case .search:
            // Korrelation für jeden Abtastwert; Spitze über der Schwelle (mit Parabel verfeinert) löst aus
            while searchIndex + 1 < end {
                let c = correlation(endingAt: Double(searchIndex))
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
                        confirmed = false
                        badLICH = 0
                        corrHistory = [0, 0]
                        state = .payload
                        advance()
                        return
                    }
                }
            }
        case .payload:
            let frame = Double(NXDN.frameSymbols) * sps
            let nominalNext = syncEnd + frame
            let window = max(3, 0.2 * sps)                                   // ±0,2 Symbole Abweichung: bis etwa 500 ppm
            guard Double(end) > nominalNext + window + 2 else { return }
            let pol: Float = inverted ? -1 : 1
            var best: Float = -2
            var bestT = nominalNext
            var t = nominalNext - window
            while t <= nominalNext + window {
                let c = pol * correlation(endingAt: t)
                if c > best { best = c; bestT = t }
                t += 0.25
            }
            let matched = best >= (confirmed ? trackThreshold : acquireThreshold)
            if !confirmed && !matched {
                // Zufallstreffer: gleich hinter dem Fund weitersuchen
                state = .search
                searchIndex = candidateIndex
                corrHistory = [0, 0]
                return
            }
            let spacing = matched ? (bestT - syncEnd) / Double(NXDN.frameSymbols) : sps
            guard let levels = frameLevels(spacing: spacing, nextSync: matched ? bestT : nil) else {
                // kein Pegel (Stille): wie ein verfehltes Synchronwort behandeln
                if !confirmed { state = .search; searchIndex = candidateIndex; corrHistory = [0, 0]; return }
                lostSync(nominalNext)
                return
            }
            let lich = NXDNLICH.decode(levels[0..<8])
            if !confirmed {
                guard lich.parityOK, lich.supported else {
                    state = .search
                    searchIndex = candidateIndex
                    corrHistory = [0, 0]
                    return
                }
                confirmed = true
                stats.syncs += 1
            }
            if lich.parityOK && lich.supported {
                badLICH = 0
                decodeFrame(levels, lich: lich)
            } else {
                stats.lichBad += 1
                badLICH += 1
                if badLICH >= 6 { finishCall(lost: true); confirmed = false; enterSearch(after: nominalNext); return }
            }
            if matched {
                stats.syncs += 1
                misses = 0
                syncEnd = bestT
            } else {
                misses += 1
                if misses >= 3 { finishCall(lost: true); confirmed = false; enterSearch(after: nominalNext); return }
                syncEnd = nominalNext                                                          // der Takt trägt
            }
            advance()
        }
    }

    private func lostSync(_ nominalNext: Double) {
        misses += 1
        if misses >= 3 { finishCall(lost: true); confirmed = false; enterSearch(after: nominalNext); return }
        syncEnd = nominalNext
        advance()
    }

    private func enterSearch(after t: Double) {
        state = .search
        syncEnd = t
        searchIndex = max(searchIndex, Int(t) - Int(2 * sps))
        corrHistory = [0, 0]
        level = 0
    }

    // MARK: Rahmen

    /// 182 Symbolpegel hinter dem Synchronwort, auf Pegel ±1/±3 normiert (mit der Polarität des Senders) und entwürfelt.
    /// Mitte und Hub kommen aus dem Synchronwort am Anfang und, wenn vorhanden, am Ende des Rahmens.
    private func frameLevels(spacing: Double, nextSync: Double?) -> [Float]? {
        guard let start = fit(endingAt: syncEnd, spacing: spacing) else { return nil }
        let stop = nextSync.flatMap { fit(endingAt: $0, spacing: spacing) }
        let end = stop ?? start
        level = abs(start.b) * 3
        inverted = start.b < 0
        var s = [Float](repeating: 0, count: NXDN.payloadSymbols)
        for j in 0..<NXDN.payloadSymbols {
            let k = Float(j + 1) / Float(NXDN.frameSymbols)
            let a = start.a + (end.a - start.a) * k
            var b = start.b + (end.b - start.b) * k
            if abs(b) < 1e-6 { b = start.b }
            s[j] = max(-3.5, min(3.5, (value(at: syncEnd + Double(j + 1) * spacing) - a) / b))
        }
        return NXDN.scramble(s)
    }

    private func decodeFrame(_ s: [Float], lich: NXDNLICH) {
        stats.frames += 1
        var messages: [(bits: [UInt8], ran: Int?)] = []
        if lich.sacchSuperframe, !lich.typeD {
            let sacch = NXDNCodes.decodeSACCH(s[NXDN.sacchStart..<(NXDN.sacchStart + 30)])
            if sacch.crcOK {
                stats.sacchGood += 1
                ran = sacch.ran
                if let bits = assemble(sacch) { messages.append((bits, sacch.ran)) }
            } else {
                stats.sacchBad += 1
                sacchParts = [nil, nil, nil, nil]
            }
        }
        for (mask, first) in [(1, NXDN.dataStart), (2, NXDN.dataStart + 72)] where lich.facch1 & mask != 0 {
            let f = NXDNCodes.decodeFACCH1(s[first..<(first + 72)])
            if f.crcOK { stats.facchGood += 1; messages.append((f.bits, nil)) } else { stats.facchBad += 1 }
        }
        // Nachrichten: der Ruf beginnt mit dem Rufkopf; Freigabe und Trennung beenden ihn (nach der Sprache dieses Rahmens)
        var ending = false
        for m in messages {
            guard let msg = NXDNMessage.parse(m.bits) else { continue }
            if msg.startsCall {
                if active, let src = info.source, src != msg.source, info.source != nil { finishCall(lost: false) }
                startCall()
                info.source = msg.source
                info.destination = msg.destination
                info.callType = msg.callType
                info.option = msg.option
                info.cipher = msg.cipher
                info.keyID = msg.keyID
            } else if msg.endsCall {
                ending = true
            }
        }
        if lich.voice != 0 {
            var frames: [[UInt8]] = []
            var clean = 0
            for k in 0..<4 where lich.voice & (k < 2 ? 1 : 2) != 0 {
                let first = NXDN.dataStart + 36 * k
                let bits = FourFSKBits.hardBits(s[first..<(first + 36)])
                frames.append(AMBEHalfRate.bytes(fromAir: bits))
                if AMBEHalfRate.isClean(bits) { clean += 1 }
            }
            // Ein Ruf beginnt mit dem Rufkopf oder mit Sprache, in der mindestens ein Rahmen den Golay-Test besteht (Zufallstreffer des Synchronwortes nicht)
            if active || clean > 0 {
                startCall()
                stats.voiceFrames += frames.count
                stats.cleanFrames += clean
                publishInfo()
                onEvent?(.voice(NXDNVoice(frames: frames, cleanFrames: clean, scrambled: (info.cipher ?? 0) != 0)))
            }
        }
        publishInfo()
        if ending { finishCall(lost: false) }
    }

    /// SACCH-Teile (Aufbau 3, 2, 1, 0) zu einer Nachricht sammeln
    private func assemble(_ part: NXDNCodes.SACCH) -> [UInt8]? {
        let index = 3 - part.structure
        if index == 0 { sacchParts = [nil, nil, nil, nil] }
        else if sacchParts[index - 1] == nil { sacchParts = [nil, nil, nil, nil]; return nil }
        sacchParts[index] = part.payload
        guard index == 3 else { return nil }
        let bits = sacchParts.compactMap { $0 }.flatMap { $0 }
        sacchParts = [nil, nil, nil, nil]
        return bits.count == 72 ? bits : nil
    }

    // MARK: Aussendung

    private func startCall() {
        guard !active else { return }
        active = true
        info = NXDNCallInfo()
        info.ran = ran
        lastInfo = nil
        stats.calls += 1
        onEvent?(.callStart(baud: baud))
    }

    private func publishInfo() {
        guard active else { return }
        if info.ran == nil { info.ran = ran }
        if info != lastInfo, info != NXDNCallInfo() {
            lastInfo = info
            onEvent?(.info(info))
        }
    }

    private func finishCall(lost: Bool) {
        guard active else { return }
        active = false
        if lost { stats.lost += 1 } else { stats.ends += 1 }
        onEvent?(.callEnd(lost: lost))
        info = NXDNCallInfo()
        lastInfo = nil
        sacchParts = [nil, nil, nil, nil]
    }
}
