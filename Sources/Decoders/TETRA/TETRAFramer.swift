// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Burst-Synchronisierung und untere MAC-Schicht für TETRA (ETSI EN 300 392-2, Kapitel 9 und 8, Abschnitt 23).
// Eingang: weiche Bits des Empfängers (zwei je Symbol). Die Synchronisierer sucht den Synchronisationsburst (Frequenzkorrekturfeld
// plus Synchronisationsfolge), liest die Zellkenndaten (BSCH) und schneidet danach Zeitschlitze zu je 510 Bits aus.

// MARK: - Zeit

/// Zeit im TDMA-Raster: Zeitschlitz 1…4, Rahmen 1…18, Mehrfachrahmen 1…60
public struct TETRATime: Equatable, Sendable, CustomStringConvertible {
    public var tn = 1
    public var fn = 1
    public var mn = 1
    public init(tn: Int = 1, fn: Int = 1, mn: Int = 1) {
        self.tn = tn; self.fn = fn; self.mn = mn
    }
    public mutating func advance() {
        tn += 1
        if tn > 4 { tn = 1; fn += 1 }
        if fn > 18 { fn = 1; mn += 1 }
        if mn > 60 { mn = 1 }
    }
    public var description: String { String(format: "%02d/%02d/%d", mn, fn, tn) }
}

// MARK: - Bursts

public enum TETRABurstKind: Sendable, Equatable {
    /// Synchronisationsburst (BSCH + AACH + SCH/HD)
    case sync
    /// Normaler Burst mit Trainingsfolge 1: ein Kanal über den ganzen Zeitschlitz (SCH/F oder TCH)
    case normal1
    /// Normaler Burst mit Trainingsfolge 2: zwei Halbschlitzkanäle (SCH/HD, STCH, TCH halb)
    case normal2
}

public struct TETRABurst: Sendable {
    /// 510 weiche Bits in der richtigen Seitenlage
    public var bits: [SoftBit]
    public var kind: TETRABurstKind
    /// Abweichende Bits der Trainingsfolge (Güte)
    public var trainingErrors: Int
    /// Globale Bitnummer des Burstanfangs
    public var index: Int
    public var inverted: Bool
}

public struct TETRASyncStatistics: Sendable, Equatable {
    public var syncBursts = 0
    public var normalBursts = 0
    public var emptySlots = 0
    public var locks = 0
    public var losses = 0
    public var inverted = false
}

/// Schneidet aus dem Bitstrom Zeitschlitze: Suche nach dem Synchronisationsburst, dann Raster mit Nachführung
public final class TETRAFramer: @unchecked Sendable {
    public var onBurst: ((TETRABurst) -> Void)?
    /// Wird aufgerufen, wenn ein Zeitschlitz keine erkennbare Trainingsfolge enthielt (nicht gesendet)
    public var onEmptySlot: (() -> Void)?
    public var onLock: ((Bool) -> Void)?
    public private(set) var locked = false
    public private(set) var inverted = false
    public private(set) var statistics = TETRASyncStatistics()

    private var buffer: [SoftBit] = []
    private var base = 0                         // globale Bitnummer von buffer[0] (immer gerade)
    private var nextBurst = 0                    // globale Bitnummer des nächsten erwarteten Bursts
    private var misses = 0
    private var hunted = 0
    /// Nach so vielen leeren Zeitschlitzen in Folge geht die Synchronisierung verloren (etwa 8 Mehrfachrahmen)
    public static let maxMisses = 1_100

    public init() {}

    public func reset() {
        buffer.removeAll()
        base = 0
        nextBurst = 0
        misses = 0
        setLocked(false)
    }

    private func setLocked(_ on: Bool) {
        guard on != locked else { return }
        locked = on
        if on { statistics.locks += 1 } else { statistics.losses += 1 }
        onLock?(on)
    }

    // Bit an globaler Stelle in der gewählten Seitenlage (spiegelverkehrt: erstes Bit eines Paares umkehren)
    @inline(__always) private func soft(_ g: Int, inverted inv: Bool) -> SoftBit {
        let v = buffer[g - base]
        if inv && (g & 1) == 0 { return v == -128 ? 127 : -v }
        return v
    }

    @inline(__always) private func hardBit(_ g: Int, inverted inv: Bool) -> UInt8 {
        let v = buffer[g - base]
        let h: UInt8 = v < 0 ? 1 : 0
        return (inv && (g & 1) == 0) ? h ^ 1 : h
    }

    private func distance(_ pattern: [UInt8], at g: Int, inverted inv: Bool, limit: Int = 99) -> Int {
        var d = 0
        for k in 0..<pattern.count {
            if hardBit(g + k, inverted: inv) != pattern[k] { d += 1; if d > limit { return d } }
        }
        return d
    }

    public func feed(_ bits: [SoftBit]) {
        buffer.append(contentsOf: bits)
        statistics.inverted = inverted
        run()
        // Puffer kürzen (gerade Anzahl)
        let keepFrom = max(base, (locked ? nextBurst - 40 : base + buffer.count - 1200))
        var drop = keepFrom - base
        drop -= drop & 1
        if drop > 4096 || (drop > 0 && buffer.count > 16_384) {
            buffer.removeFirst(drop)
            base += drop
        }
    }

    private func run() {
        while true {
            if locked {
                guard nextBurst + 510 + 12 <= base + buffer.count else { return }
                deliverSlot()
            } else {
                // Suche: Synchronisationsburst vollständig im Puffer, mit Vorlauf für das Frequenzkorrekturfeld
                let first = max(base, hunted)
                let lastStart = base + buffer.count - 510 - 4
                if lastStart < first { return }
                var found: (start: Int, inv: Bool, score: Int)?
                var g = first
                // Kandidat nach der Folge y (38 Bit, Abstand 214) und dem Frequenzkorrekturfeld (80 Bit, Abstand 14)
                while g <= lastStart {
                    for inv in [false, true] {
                        let dy = distance(TETRA.syncTraining, at: g + TETRA.syncTrainingOffset, inverted: inv, limit: 6)
                        if dy > 6 { continue }
                        let df = distance(TETRA.frequencyCorrection, at: g + 14, inverted: inv, limit: 14)
                        if df > 14 { continue }
                        let score = dy * 2 + df
                        if found == nil || score < found!.score { found = (g, inv, score) }
                    }
                    if let f = found, g > f.start + 8 { break }
                    g += 2                                   // Symbolraster: Anfang gerader Bits
                }
                if let f = found {
                    inverted = f.inv
                    nextBurst = f.start
                    hunted = f.start
                    misses = 0
                    setLocked(true)
                } else {
                    hunted = lastStart + 2
                    return
                }
            }
        }
    }

    private func deliverSlot() {
        let start = nextBurst
        // Trainingsfolge am erwarteten Ort, sonst ±3 Symbole nachsuchen
        var best: (kind: TETRABurstKind, errors: Int, shift: Int)?
        for shift in [0, -2, 2, -4, 4, -6, 6] {
            let s = start + shift
            if s < base || s + 510 > base + buffer.count { continue }
            let ds = distance(TETRA.syncTraining, at: s + TETRA.syncTrainingOffset, inverted: inverted, limit: 12)
            let dn = distance(TETRA.normalTrainingN, at: s + TETRA.normalTrainingOffset, inverted: inverted, limit: 8)
            let dp = distance(TETRA.normalTrainingP, at: s + TETRA.normalTrainingOffset, inverted: inverted, limit: 8)
            var cand: (TETRABurstKind, Int)?
            if ds <= 6 { cand = (.sync, ds) }
            if dn <= 3, cand == nil || dn * 2 < cand!.1 { cand = (.normal1, dn) }
            if dp <= 3, cand == nil || dp * 2 < cand!.1 { cand = (.normal2, dp) }
            if let c = cand, best == nil || c.1 < best!.errors { best = (c.0, c.1, shift) }
            if best != nil && shift == 0 { break }
        }
        if let b = best {
            let s = start + b.shift
            var bits = [SoftBit](repeating: 0, count: 510)
            for k in 0..<510 { bits[k] = soft(s + k, inverted: inverted) }
            if b.kind == .sync { statistics.syncBursts += 1 } else { statistics.normalBursts += 1 }
            misses = 0
            nextBurst = s + 510
            onBurst?(TETRABurst(bits: bits, kind: b.kind, trainingErrors: b.errors, index: s, inverted: inverted))
        } else {
            misses += 1
            statistics.emptySlots += 1
            nextBurst += 510
            onEmptySlot?()
            if misses > Self.maxMisses {
                setLocked(false)
                hunted = nextBurst
            }
        }
    }
}

// MARK: - Untere MAC-Schicht

/// Logische Kanäle, die der Block eines Bursts trägt
public enum TETRALogicalChannel: String, Sendable {
    case bsch = "BSCH"
    case aach = "AACH"
    case schHD = "SCH/HD"
    case bnch = "BNCH"
    case schF = "SCH/F"
    case stch = "STCH"
    case tch = "TCH/S"
}

/// Ein decodierter Steuerblock (Typ-1-Bits)
public struct TETRAMacBlock: Sendable {
    public var channel: TETRALogicalChannel
    public var bits: [UInt8]
    public var crcOK: Bool
    public var time: TETRATime
    /// Dieser Block ist der erste oder zweite des Bursts (0 bei Vollschlitz)
    public var blockNumber: Int
    /// Der Burst trug laut Zugriffszuweisung Verkehr (Gebrauchskennung ≥ 4)
    public var trafficMarker: Int
}

/// Inhalt der Synchronisationsnachricht (BSCH, 60 Bits)
public struct TETRASyncInfo: Sendable, Equatable {
    public var systemCode = 0
    public var colourCode = 0
    public var time = TETRATime()
    public var sharingMode = 0
    public var reservedFrames = 0
    public var dtx = false
    public var frame18Extension = false
    public var mcc = 0
    public var mnc = 0
    public var neighbourCellBroadcast = 0
    public var cellServiceLevel = 0
    public var lateEntry = false

    init?(bits: [UInt8]) {
        guard bits.count >= 60 else { return nil }
        systemCode = Int(TETRA.uint(bits, 0, 4))
        colourCode = Int(TETRA.uint(bits, 4, 6))
        time = TETRATime(tn: Int(TETRA.uint(bits, 10, 2)) + 1, fn: Int(TETRA.uint(bits, 12, 5)), mn: Int(TETRA.uint(bits, 17, 6)))
        sharingMode = Int(TETRA.uint(bits, 23, 2))
        reservedFrames = Int(TETRA.uint(bits, 25, 3))
        dtx = bits[28] == 1
        frame18Extension = bits[29] == 1
        mcc = Int(TETRA.uint(bits, 31, 10))
        mnc = Int(TETRA.uint(bits, 41, 14))
        neighbourCellBroadcast = Int(TETRA.uint(bits, 55, 2))
        cellServiceLevel = Int(TETRA.uint(bits, 57, 2))
        lateEntry = bits[59] == 1
        guard time.fn >= 1, time.fn <= 18, time.mn >= 1, time.mn <= 60 else { return nil }
    }
}

/// Zugriffszuweisung (AACH): wer darf auf der Aufwärtsstrecke, was liegt auf der Abwärtsstrecke
public struct TETRAAccessAssign: Sendable, Equatable {
    public var header = 0
    /// Gebrauchskennung der Abwärtsstrecke: 0 frei, 1 zugewiesene Steuerung, 2 gemeinsame Steuerung, 3 reserviert, ab 4 Verkehr
    public var downlinkUsage: Int?
    public var uplinkUsage: Int?
    public var field1 = 0
    public var field2 = 0

    init(info: UInt16, frame18: Bool) {
        header = Int(info >> 12) & 3
        field1 = Int(info >> 6) & 0x3F
        field2 = Int(info) & 0x3F
        if !frame18 {
            switch header {
            case 0: break                                  // beide Felder sind Zugriffsfelder, Abwärts: gemeinsame Steuerung
            case 1, 2: downlinkUsage = field1
            default: downlinkUsage = field1; uplinkUsage = field2
            }
        }
    }

    public var isTraffic: Bool { (downlinkUsage ?? 0) >= 4 }
}

/// Ein Sprachblock aus einem Verkehrsburst: zwei Rahmen zu 30 ms (nil = nicht verfügbar, etwa durch Blockraub)
public struct TETRATrafficBlock: Sendable {
    public var time: TETRATime
    public var usageMarker: Int
    public var frames: [TETRASpeechFrame?]
}

public enum TETRALowerEvent: Sendable {
    case sync(TETRASyncInfo, TETRATime)
    case access(TETRAAccessAssign, TETRATime)
    case block(TETRAMacBlock)
    case traffic(TETRATrafficBlock)
}

/// Untere MAC-Schicht: Burst → Blöcke (Verwürfelung, Entschachtelung, Viterbi, CRC)
public final class TETRALowerMAC: @unchecked Sendable {
    public private(set) var time = TETRATime()
    public private(set) var timeKnown = false
    public private(set) var cell: TETRASyncInfo?
    public private(set) var scrambler: UInt32 = 0
    public var onEvent: ((TETRALowerEvent) -> Void)?
    private let cache = TETRA.ScramblerCache()
    private let initCache = TETRA.ScramblerCache()
    /// Zähler zur Überwachung
    public private(set) var crcOK = 0
    public private(set) var crcBad = 0

    public init() {}

    public func reset() {
        timeKnown = false
        cell = nil
    }

    /// Zeitschlitz ohne erkennbaren Burst
    public func skipSlot() {
        if timeKnown { time.advance() }
    }

    struct BlockParameters {
        let k: Int
        let type2: Int
        let type1: Int
        let a: Int
    }
    static let sb1 = BlockParameters(k: 120, type2: 80, type1: 60, a: 11)
    static let halfSlot = BlockParameters(k: 216, type2: 144, type1: 124, a: 101)
    static let fullSlot = BlockParameters(k: 432, type2: 288, type1: 268, a: 103)

    private func decodeControl(_ soft: ArraySlice<SoftBit>, _ p: BlockParameters, scramblerInit: UInt32, scrambling: TETRA.ScramblerCache) -> (bits: [UInt8], ok: Bool) {
        let t4 = scrambling.descramble(soft, initial: scramblerInit)
        let t3 = TETRA.blockDeinterleave(t4, a: p.a)
        let mother = TETRA.Puncturer.rate2of3.depuncture(t3, motherLength: p.type2 * 4)
        let r = TETRA.ConvolutionalCode.control.decode(mother, steps: p.type2, terminated: true)
        let crc = TETRA.crc16(r.bits[0..<(p.type1 + 16)])
        return (Array(r.bits[0..<p.type1]), crc == TETRA.crcResidue)
    }

    private func decodeAccess(_ bbk: [SoftBit], frame18: Bool) -> TETRAAccessAssign? {
        guard timeKnown, bbk.count == 30, cell != nil else { return nil }
        let t4 = cache.descramble(bbk[...], initial: scrambler)
        let r = TETRA.rm3014Decode(t4)
        // Mehr als 3 Fehler bei 30 Bits: unzuverlässig
        guard r.distance <= 4 else { return nil }
        return TETRAAccessAssign(info: r.info, frame18: frame18)
    }

    public func process(_ burst: TETRABurst) {
        let bits = burst.bits
        switch burst.kind {
        case .sync:
            // SB1: Bits 94…213, BBK: 252…281, SB2: 282…497
            let sb1 = decodeControl(bits[94..<214], Self.sb1, scramblerInit: TETRA.defaultScramblerInit, scrambling: initCache)
            if sb1.ok, let info = TETRASyncInfo(bits: sb1.bits) {
                crcOK += 1
                time = info.time
                timeKnown = true
                if cell == nil || cell!.mcc != info.mcc || cell!.mnc != info.mnc || cell!.colourCode != info.colourCode {
                    scrambler = TETRA.scramblerInit(mcc: info.mcc, mnc: info.mnc, colourCode: info.colourCode)
                }
                cell = info
                onEvent?(.sync(info, time))
            } else {
                crcBad += 1
                if timeKnown { time.advance() }
                return
            }
            if let a = decodeAccess(Array(bits[252..<282]), frame18: time.fn == 18) { onEvent?(.access(a, time)) }
            let sb2 = decodeControl(bits[282..<498], Self.halfSlot, scramblerInit: scrambler, scrambling: cache)
            if sb2.ok { crcOK += 1 } else { crcBad += 1 }
            onEvent?(.block(TETRAMacBlock(channel: .bnch, bits: sb2.bits, crcOK: sb2.ok, time: time, blockNumber: 2, trafficMarker: 0)))
        case .normal1, .normal2:
            guard timeKnown, cell != nil else { return }
            // AACH: 14 Bits ab 230 und 16 Bits ab 266 (die Trainingsfolge liegt dazwischen)
            let bbk = Array(bits[230..<244]) + Array(bits[266..<282])
            let access = decodeAccess(bbk, frame18: time.fn == 18)
            if let a = access { onEvent?(.access(a, time)) }
            let marker = (access?.isTraffic ?? false) ? (access?.downlinkUsage ?? 0) : 0
            let b1 = bits[14..<230], b2 = bits[282..<498]
            if burst.kind == .normal1 {
                if marker >= 4 {
                    // Verkehr über den ganzen Zeitschlitz
                    // Die Verwürfelungsfolge läuft über beide Hälften (432 Bits am Stück)
                    let whole = cache.descramble((Array(b1) + Array(b2))[...], initial: scrambler)
                    if let frames = TETRASpeech.decodeBlock(whole) {
                        onEvent?(.traffic(TETRATrafficBlock(time: time, usageMarker: marker, frames: frames.map { Optional($0) })))
                    }
                } else {
                    let all = Array(b1) + Array(b2)
                    let r = decodeControl(all[...], Self.fullSlot, scramblerInit: scrambler, scrambling: cache)
                    if r.ok { crcOK += 1 } else { crcBad += 1 }
                    onEvent?(.block(TETRAMacBlock(channel: .schF, bits: r.bits, crcOK: r.ok, time: time, blockNumber: 0, trafficMarker: 0)))
                }
            } else {
                let r1 = decodeControl(b1, Self.halfSlot, scramblerInit: scrambler, scrambling: cache)
                if r1.ok { crcOK += 1 } else { crcBad += 1 }
                let chan: TETRALogicalChannel = marker >= 4 ? .stch : .schHD
                onEvent?(.block(TETRAMacBlock(channel: chan, bits: r1.bits, crcOK: r1.ok, time: time, blockNumber: 1, trafficMarker: marker)))
                if marker >= 4 {
                    // Zweite Hälfte: Sprache, außer der erste Block meldet „zweite Hälfte ebenfalls geraubt“
                    if r1.ok && TETRALowerMAC.secondBlockStolen(r1.bits) {
                        let r2 = decodeControl(b2, Self.halfSlot, scramblerInit: scrambler, scrambling: cache)
                        if r2.ok { crcOK += 1 } else { crcBad += 1 }
                        onEvent?(.block(TETRAMacBlock(channel: .stch, bits: r2.bits, crcOK: r2.ok, time: time, blockNumber: 2, trafficMarker: marker)))
                        onEvent?(.traffic(TETRATrafficBlock(time: time, usageMarker: marker, frames: [nil, nil])))
                    } else {
                        let t4 = cache.descramble(b2, initial: scrambler)
                        let half = TETRASpeech.decodeHalf(t4)
                        onEvent?(.traffic(TETRATrafficBlock(time: time, usageMarker: marker, frames: [nil, half])))
                    }
                } else {
                    let r2 = decodeControl(b2, Self.halfSlot, scramblerInit: scrambler, scrambling: cache)
                    if r2.ok { crcOK += 1 } else { crcBad += 1 }
                    onEvent?(.block(TETRAMacBlock(channel: .schHD, bits: r2.bits, crcOK: r2.ok, time: time, blockNumber: 2, trafficMarker: 0)))
                }
            }
        }
        time.advance()
    }

    /// MAC-RESOURCE mit Längenangabe 0x3E: der zweite Halbschlitz ist ebenfalls für Signalisierung geraubt
    static func secondBlockStolen(_ bits: [UInt8]) -> Bool {
        guard bits.count > 13 else { return false }
        return TETRA.uint(bits, 0, 2) == 0 && TETRA.uint(bits, 7, 6) == 0x3E
    }
}
