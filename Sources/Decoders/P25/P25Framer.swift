// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// P25-Phase-1-Empfänger für FM-Diskriminator-Audio: Filter, Rahmensynchronwort FS suchen (beide Polaritäten, Pearson-Korrelation),
// Mitte und Hub aus dem Synchronwort, NID mit BCH lesen, dann die Einheit nach der Art (DUID) auslesen. Die Einheiten folgen
// lückenlos aufeinander (LDU1, LDU2, …): das nächste FS steht genau eine Einheitenlänge später, dort werden Takt und Pegel nachgeführt.

public struct P25Voice: Sendable {
    /// IMBE-Sprachrahmen (je 18 Byte = 144 Bit der Funkstrecke, MSB zuerst), neun je LDU
    public var frames: [[UInt8]]
    public var cleanFrames: Int
    /// Verschlüsselte Sprache (Algorithmus ungleich 0x80): ohne Schlüssel unhörbar
    public var encrypted: Bool
}

public struct P25CallInfo: Equatable, Sendable {
    public var nac: Int?
    public var group: Int?
    public var target: Int?
    public var source: Int?
    public var emergency = false
    public var algorithm: Int?
    public var keyID: Int?
    public var manufacturer: Int?
    public var mi: String?
    public var format: Int?
    /// Das Dienstmerkmal „verschlüsselt“ der Linksteuerung
    public var serviceEncrypted = false
}

public enum P25Event: Sendable {
    case callStart(nac: Int)
    case voice(P25Voice)
    case info(P25CallInfo)
    case callEnd(lost: Bool)
}

public struct P25FramerStats: Equatable, Sendable {
    public var syncs = 0
    public var units = 0
    public var nidBad = 0
    public var hdu = 0, ldu1 = 0, ldu2 = 0, tdu = 0, tdulc = 0, tsdu = 0, pdu = 0
    public var lcGood = 0, lcBad = 0
    public var essGood = 0, essBad = 0
    public var voiceFrames = 0
    public var cleanFrames = 0
    public var calls = 0
    public var ends = 0
    public var lost = 0
}

public final class P25Receiver {
    public var onEvent: ((P25Event) -> Void)?
    public private(set) var stats = P25FramerStats()
    public private(set) var inverted = false
    public private(set) var level: Float = 0
    public private(set) var nac: Int?
    public var isLocked: Bool { state != .search && confirmed }
    public var acquireThreshold: Float = 0.85
    public var trackThreshold: Float = 0.55
    public let sampleRate: Double
    public let baud = P25.baud

    private enum State { case search, header, body }
    private var state = State.search
    private let nominal: Double                 // Abtastwerte je Symbol
    private var spacing: Double                 // nachgeführter Symbolabstand
    private let taps: [Float]
    private var ring: [Float]
    private var ringPos = 0
    private var y: [Float] = []
    private var base = 0
    private var searchIndex = 0
    private var syncEnd = 0.0
    private var candidateIndex = 0
    private var corrHistory: [Float] = [0, 0]
    private var misses = 0
    private var confirmed = false
    private var duid: P25.DUID = .tdu
    private var startFit: (a: Float, b: Float)?

    // Aussendung
    private var active = false
    private var info = P25CallInfo()
    private var lastInfo: P25CallInfo?
    private var haveEncryption = false
    private var lastUnitEnd = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        nominal = sampleRate / P25.baud
        spacing = nominal
        let half = max(2, Int((4 * nominal).rounded()))
        let alpha = 0.2
        var h = [Double](repeating: 0, count: 2 * half + 1)
        for i in -half...half {
            let t = Double(i) / nominal
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
        corrHistory = [0, 0]
        spacing = nominal
        inverted = false
        level = 0
        nac = nil
        forgetCall()
    }

    private func forgetCall() {
        active = false
        info = P25CallInfo()
        lastInfo = nil
        haveEncryption = false
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
        if active, end - lastUnitEnd > Int(0.8 * sampleRate) { finishCall(lost: true) }
        let anchor: Double = state == .search ? Double(searchIndex) : (confirmed ? syncEnd : min(syncEnd, Double(candidateIndex)))
        trim(to: Int(anchor - 30 * nominal))
    }

    private func trim(to absolute: Int) {
        let drop = absolute - base
        guard drop > 8000, drop < y.count else { return }
        y.removeFirst(drop)
        base += drop
    }

    private var end: Int { base + y.count }

    private func value(at t: Double) -> Float {
        let i = Int(t.rounded(.down))
        let f = Float(t - Double(i))
        let a = i - base
        guard a >= 0, a + 1 < y.count else { return 0 }
        return y[a] + (y[a + 1] - y[a]) * f
    }

    private func correlation(endingAt t: Double, spacing sp: Double) -> Float {
        let pattern = P25.fs
        let n = pattern.count
        var v = [Float](repeating: 0, count: n)
        for i in 0..<n { v[i] = value(at: t - Double(n - 1 - i) * sp) }
        let mv = v.reduce(0, +) / Float(n), mp = pattern.reduce(0, +) / Float(n)
        var cov: Float = 0, vv: Float = 0, pp: Float = 0
        for i in 0..<n {
            let a = v[i] - mv, b = pattern[i] - mp
            cov += a * b; vv += a * a; pp += b * b
        }
        guard vv > 1e-10, pp > 0 else { return 0 }
        return cov / (vv * pp).squareRoot()
    }

    /// v ≈ a + b · p (p = ±1 im Synchronwort, das zur Zeit `t` endet); b < 0 bei umgekehrter Polarität
    private func fit(endingAt t: Double) -> (a: Float, b: Float)? {
        let p = P25.fs.map { $0 / 3 }
        var sum: Float = 0, dot: Float = 0
        for i in 0..<p.count {
            let v = value(at: t - Double(p.count - 1 - i) * spacing)
            sum += v
            dot += v * p[i]
        }
        let slope = dot / Float(p.count)
        guard abs(slope) > 1e-6 else { return nil }
        return (sum / Float(p.count), slope)
    }

    private func enterSearch(after t: Double) {
        state = .search
        searchIndex = max(searchIndex, Int(t) - Int(2 * nominal))
        corrHistory = [0, 0]
        level = 0
    }

    private func abandonCandidate() {
        state = .search
        searchIndex = candidateIndex
        corrHistory = [0, 0]
    }

    private func advance() {
        switch state {
        case .search:
            while searchIndex + 1 < end {
                let c = correlation(endingAt: Double(searchIndex), spacing: nominal)
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
                        misses = 0
                        confirmed = false
                        corrHistory = [0, 0]
                        spacing = nominal
                        state = .header
                        advance()
                        return
                    }
                }
            }
        case .header:
            // NID: 32 Symbole hinter dem Synchronwort, dazwischen das Statussymbol
            guard Double(end) > syncEnd + Double(P25.nidSymbols + 3) * spacing + 4 else { return }
            guard let fit = fit(endingAt: syncEnd) else { return failHeader() }
            startFit = fit
            let sym: [Float] = (0..<(P25.nidSymbols + 1)).map { n3(value(at: syncEnd + Double($0 + 1) * spacing), fit) }
            // Statussymbol an Rahmenindex 35 = Symbol 12 hinter dem Ende des Synchronwortes (Index 23)
            var content = sym
            content.remove(at: 11)
            let bits = FourFSKBits.hardBits(content[0..<32][...])
            guard let nid = P25Codes.bchDecode(bits), let d = P25.DUID(rawValue: nid.duid) else { return failHeader() }
            duid = d
            nac = nid.nac
            level = abs(fit.b) * 3
            inverted = fit.b < 0
            state = .body
            advance()
        case .body:
            guard let length = duid.length else {
                // Steuerkanal und Paketdaten: nur erkannt; weiter hinter dem NID suchen
                countUnit()
                confirmed = true
                enterSearch(after: syncEnd + 60 * spacing)
                return
            }
            let nominalNext = syncEnd + Double(length) * spacing
            let window = max(3, 0.6 * nominal)
            guard Double(end) > nominalNext + window + 2 else { return }
            var best: Float = -2
            var bestT = nominalNext
            var t = nominalNext - window
            let pol: Float = inverted ? -1 : 1
            while t <= nominalNext + window {
                let c = pol * correlation(endingAt: t, spacing: spacing)
                if c > best { best = c; bestT = t }
                t += 0.25
            }
            let matched = best >= (confirmed ? trackThreshold : acquireThreshold)
            let endFit = matched ? fit(endingAt: bestT) : nil
            if let start = startFit {
                let levels = frameLevels(length: length, start: start, end: endFit, nextSync: matched ? bestT : nil)
                if !confirmed {
                    // Zufallstreffer verwerfen: der erste Rahmen zählt erst mit dem nächsten Synchronwort im Abstand
                    guard matched else { abandonCandidate(); return }
                    confirmed = true
                    stats.syncs += 1
                }
                decodeUnit(levels)
            }
            if matched {
                stats.syncs += 1
                let measured = (bestT - syncEnd) / Double(length)
                if abs(measured - nominal) < 0.004 * nominal { spacing = 0.5 * spacing + 0.5 * measured }
                misses = 0
                syncEnd = bestT
                state = .header
            } else {
                misses += 1
                if misses >= 3 { finishCall(lost: true); confirmed = false; enterSearch(after: nominalNext); return }
                enterSearch(after: nominalNext)
                return
            }
            advance()
        }
    }

    private func failHeader() {
        stats.nidBad += 1
        if confirmed {
            misses += 1
            if misses >= 3 { finishCall(lost: true); confirmed = false }
            enterSearch(after: syncEnd + Double(P25.syncSymbols) * spacing)
        } else {
            abandonCandidate()
        }
    }

    private func n3(_ v: Float, _ fit: (a: Float, b: Float)) -> Float { max(-3.5, min(3.5, 3 * (v - fit.a) / fit.b)) }

    // MARK: Einheit

    /// Inhaltssymbole (ohne Statussymbole) einer Einheit, normiert auf ±1/±3; Index 0 = erstes Symbol des FS
    private func frameLevels(length: Int, start: (a: Float, b: Float), end endFit: (a: Float, b: Float)?, nextSync: Double?) -> [Float] {
        let stop = endFit ?? start
        var content: [Float] = []
        content.reserveCapacity(length)
        var effectiveSpacing = spacing
        if let t = nextSync { effectiveSpacing = (t - syncEnd) / Double(length) }
        for s in 0..<length where s % 36 != 35 {
            let f = Float(s) / Float(length)
            let a = start.a + (stop.a - start.a) * f
            var b = start.b + (stop.b - start.b) * f
            if abs(b) < 1e-6 || (b < 0) != (start.b < 0) { b = start.b }
            let t = syncEnd + Double(s - (P25.syncSymbols - 1)) * effectiveSpacing
            content.append(max(-3.5, min(3.5, 3 * (value(at: t) - a) / b)))
        }
        return content
    }

    private func countUnit() {
        stats.units += 1
        switch duid {
        case .hdu: stats.hdu += 1
        case .ldu1: stats.ldu1 += 1
        case .ldu2: stats.ldu2 += 1
        case .tdu: stats.tdu += 1
        case .tdulc: stats.tdulc += 1
        case .tsdu: stats.tsdu += 1
        case .pdu: stats.pdu += 1
        }
    }

    private func bits(_ c: [Float], _ from: Int, _ count: Int) -> [UInt8] { FourFSKBits.hardBits(c[from..<(from + count)]) }

    /// Hexwörter mit Hamming (10,6): je 5 Symbole (3 Daten, 2 Prüfung)
    private func hammingWords(_ c: [Float], at pos: Int, count: Int) -> [UInt8] {
        var out: [UInt8] = []
        for w in 0..<count {
            let b = bits(c, pos + 5 * w, 5)
            let hex = Array(b[0..<6]), par = Array(b[6..<10])
            if let r = P25Codes.hammingDecode(hex: hex, parity: par) { out += r.hex.map { $0 } } else { out += hex }
        }
        return out
    }

    private func value(_ bits: ArraySlice<UInt8>) -> Int { bits.reduce(0) { ($0 << 1) | Int($1 & 1) } }

    private func decodeUnit(_ c: [Float]) {
        countUnit()
        lastUnitEnd = end
        let nidBase = P25.syncSymbols + P25.nidSymbols                      // 56
        switch duid {
        case .ldu1, .ldu2:
            decodeLDU(c, first: duid == .ldu1, base: nidBase)
        case .hdu:
            decodeHDU(c, base: nidBase)
        case .tdu:
            finishCall(lost: false)
        case .tdulc:
            decodeTDULC(c, base: nidBase)
            finishCall(lost: false)
        case .tsdu, .pdu:
            break
        }
    }

    private func decodeLDU(_ c: [Float], first: Bool, base: Int) {
        // Neun IMBE-Rahmen zu je 72 Symbolen; hinter Rahmen 2 … 7 je vier Hexwörter, hinter Rahmen 8 die Zusatzdaten (16 Symbole)
        var pos = base
        var hex: [UInt8] = []                                              // 24 Hexwörter zu je 6 Bit (Sendereihenfolge)
        var frames: [[UInt8]] = []
        var clean = 0
        var errors = 0
        for i in 0..<9 {
            let air = bits(c, pos, 72)
            pos += 72
            frames.append(P25IMBE.bytes(fromAir: air))
            if let e = P25IMBE.errorCount(air: air) { if e == 0 { clean += 1 }; errors += e } else { errors += 8 }
            if (1...6).contains(i) { hex += hammingWords(c, at: pos, count: 4); pos += 20 }
            if i == 7 { pos += 16 }
        }
        let words: [UInt8] = stride(from: 0, to: hex.count, by: 6).map { UInt8(value(hex[$0..<($0 + 6)])) }
        var changed = false
        var recognized = false
        if first {
            var w = words
            if P25RS.rs24_12_13.decode(&w) != nil {
                stats.lcGood += 1
                let lcBits = w[0..<12].flatMap { v in (0..<6).map { UInt8((Int(v) >> (5 - $0)) & 1) } }
                if let lc = P25LinkControl.parse(lcBits), !lc.protected {
                    recognized = true
                    if active, let src = info.source, let new = lc.source, src != new { finishCall(lost: false) }
                    startCall()
                    info.format = lc.opcode
                    if lc.mfid > 1 || info.manufacturer == nil { info.manufacturer = lc.mfid }
                    info.emergency = lc.emergency
                    if lc.opcode == 0x00 || lc.opcode == 0x03 || lc.opcode == 0x0A {
                        info.group = lc.group
                        info.target = lc.target
                        info.source = lc.source
                        changed = true
                    }
                    info.serviceEncrypted = lc.encrypted
                }
            } else {
                stats.lcBad += 1
            }
        } else {
            var w = words
            if P25RS.rs24_16_9.decode(&w) != nil {
                stats.essGood += 1
                let b = w[0..<16].flatMap { v in (0..<6).map { UInt8((Int(v) >> (5 - $0)) & 1) } }
                recognized = true
                startCall()
                let mi = (0..<9).map { String(format: "%02X", value(b[($0 * 8)..<($0 * 8 + 8)])) }.joined()
                info.mi = mi
                info.algorithm = value(b[72..<80])
                info.keyID = value(b[80..<96])
                haveEncryption = true
                changed = true
            } else {
                stats.essBad += 1
            }
        }
        _ = changed
        stats.voiceFrames += 9
        stats.cleanFrames += clean
        if recognized || active || clean >= 5 {
            startCall()
            publishInfo()
            let encrypted = ((info.algorithm ?? 0x80) != 0x80 && (info.algorithm ?? 0) != 0) || (info.algorithm == nil && info.serviceEncrypted)
            onEvent?(.voice(P25Voice(frames: frames, cleanFrames: clean, encrypted: encrypted)))
        }
    }

    private func decodeHDU(_ c: [Float], base: Int) {
        var words: [UInt8] = []
        var bad = false
        for w in 0..<36 {
            let p = base + 9 * w
            let data = bits(c, p, 3)
            let parity = bits(c, p + 3, 6)
            // Daten: drei Symbole (6 Bit); Prüfbits: sechs Symbole (12 Bit)
            let d = Array(data[0..<6]), q = Array(parity[0..<12])
            if let r = P25Codes.golayDecode(data: d[...], parity: q[...], dataBits: 6) { words.append(UInt8(r.data)) } else { words.append(UInt8(value(d[...]))); bad = true }
        }
        _ = bad
        var w = words
        guard P25RS.rs36_20_17.decode(&w) != nil else { stats.essBad += 1; return }
        stats.essGood += 1
        let b = w[0..<20].flatMap { v in (0..<6).map { UInt8((Int(v) >> (5 - $0)) & 1) } }
        if active, info.mi != nil || info.group != nil { finishCall(lost: false) }
        startCall()
        info.mi = (0..<9).map { String(format: "%02X", value(b[($0 * 8)..<($0 * 8 + 8)])) }.joined()
        info.manufacturer = value(b[72..<80])
        info.algorithm = value(b[80..<88])
        info.keyID = value(b[88..<104])
        info.group = value(b[104..<120])
        haveEncryption = true
        publishInfo()
    }

    private func decodeTDULC(_ c: [Float], base: Int) {
        var data: [UInt8] = []
        for w in 0..<12 {
            let p = base + 12 * w
            let d = bits(c, p, 6)
            let q = bits(c, p + 6, 6)
            guard let r = P25Codes.golayDecode(data: d[0..<12], parity: q[0..<12], dataBits: 12) else {
                data += d
                continue
            }
            data += (0..<12).map { UInt8((r.data >> (11 - $0)) & 1) }
        }
        let words: [UInt8] = stride(from: 0, to: 144, by: 6).map { UInt8(value(data[$0..<($0 + 6)])) }
        var w = words
        guard P25RS.rs24_12_13.decode(&w) != nil else { stats.lcBad += 1; return }
        stats.lcGood += 1
        let lcBits = w[0..<12].flatMap { v in (0..<6).map { UInt8((Int(v) >> (5 - $0)) & 1) } }
        if let lc = P25LinkControl.parse(lcBits), !lc.protected, active {
            if lc.opcode == 0x00 || lc.opcode == 0x03 { info.group = lc.group; info.target = lc.target; info.source = lc.source }
            publishInfo()
        }
    }

    // MARK: Aussendung

    private func startCall() {
        guard !active else { return }
        active = true
        info = P25CallInfo()
        info.nac = nac
        lastInfo = nil
        haveEncryption = false
        stats.calls += 1
        onEvent?(.callStart(nac: nac ?? 0))
    }

    private func publishInfo() {
        guard active else { return }
        info.nac = nac
        if info != lastInfo {
            lastInfo = info
            onEvent?(.info(info))
        }
    }

    private func finishCall(lost: Bool) {
        guard active else { return }
        active = false
        if lost { stats.lost += 1 } else { stats.ends += 1 }
        onEvent?(.callEnd(lost: lost))
        info = P25CallInfo()
        lastInfo = nil
        haveEncryption = false
    }
}
