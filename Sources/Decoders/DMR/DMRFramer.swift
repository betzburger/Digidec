// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// DMR-Burstautomat über dem 4-Pegel-Empfänger: Synchronmuster suchen (vier Arten, beide Polaritäten), dann die Bursts im Takt
// von 144 Symbolen lesen. Sprachbursts B bis F haben kein Synchronmuster, sie folgen aus dem Takt und dem Zustand des Zeitschlitzes.
// Je Zeitschlitz wird mitgeführt, ob gerade ein Gespräch läuft, welcher Burst des Überrahmens als nächster kommt und welche
// Fragmente der eingebetteten Link-Control-Information schon da sind.

public struct DMRVoiceBurst: Sendable {
    /// Zeitschlitz 0 oder 1 (Zeitschlitz 1 bzw. 2); im Direktmodus (ohne CACH) immer 0
    public var slot: Int
    /// Burst im Überrahmen: 0 = A (Sync), 1 … 5 = B bis F
    public var index: Int
    public var colorCode: Int?
    /// Drei Sprachrahmen A, B, C (je 9 Byte im Format des Sprachsticks)
    public var frames: [[UInt8]]
    /// Wie viele der drei Rahmen in C0 und C1 fehlerfrei waren (Maß für die Empfangsgüte)
    public var cleanFrames: Int
}

public enum DMREvent: Sendable {
    case voice(DMRVoiceBurst)
    /// Ein Gespräch beginnt (`lc` aus dem Sprach-Kopf; `nil` bei spätem Einstieg ohne Kopf)
    case callStart(slot: Int, colorCode: Int?, lc: DMRLinkControl?)
    /// Link Control aus der eingebetteten Information (später Einstieg) oder dem Abschluss
    case linkControl(slot: Int, lc: DMRLinkControl)
    case callEnd(slot: Int, lc: DMRLinkControl?, lost: Bool)
    /// Anderer Datenburst (Leerlauf, CSBK, Daten) mit Datentyp; nur zur Anzeige und für die Zähler
    case data(slot: Int, type: DMR.DataType, colorCode: Int)
    case lost
}

public struct DMRFramerStats: Equatable, Sendable {
    public var bursts = 0
    public var syncs = 0
    public var voiceBursts = 0
    public var cleanFrames = 0
    public var frames = 0
    public var headers = 0
    public var terminators = 0
    public var embeddedLC = 0
    public var cachBad = 0
    public var slotTypeBad = 0
    public var lcBad = 0
    public var idleBursts = 0
    public var calls = 0
    public var lost = 0
}

public final class DMRFramer {
    public var onEvent: ((DMREvent) -> Void)?
    public private(set) var stats = DMRFramerStats()
    public private(set) var inverted = false
    public private(set) var isBaseStation = true
    public var isLocked: Bool { locked }
    /// Farbcode, auf den gefiltert wird (`nil` = alle)
    public var colorCodeFilter: Int?
    public var acquireThreshold: Float = 0.8

    private struct Slot {
        var active = false
        var nextIndex = 0
        var colorCode: Int?
        var misses = 0
        var voiceBursts = 0
        var fragments = [[UInt8]?](repeating: nil, count: 4)
        var lc: DMRLinkControl?
    }

    private var buffer: [Float] = []
    private var base = 0                      // absoluter Index von buffer[0]
    private var count = 0                     // bisher empfangene Symbole
    private var locked = false
    private var nextCenter = 0                // absoluter Index der Mitte des nächsten Bursts
    private var slots = [Slot(), Slot()]
    private var lastSlot = 1
    private var burstsWithoutSync = 0
    // Einrasten am besten Treffer
    private var acquireCountdown = 0
    private var acquireBestIndex = 0
    private var acquireBestValue: Float = 0
    /// Gefunden, aber noch nicht gesperrt: erst die Polarität an den ersten Bursts entscheiden (Daten-Sync = Negativ des Sprach-Sync)
    private var pendingLock = false

    public init() {}

    public func reset() {
        buffer.removeAll(keepingCapacity: true)
        base = 0; count = 0
        locked = false
        slots = [Slot(), Slot()]
        inverted = false
        burstsWithoutSync = 0
        acquireCountdown = 0
        pendingLock = false
    }

    // MARK: Eingang

    public func push(symbol: Float) {
        buffer.append(symbol)
        count += 1
        if pendingLock {
            if count >= nextCenter + 3 * DMR.symbolsPerBurst + DMR.afterCenter { decidePolarityAndLock() }
        } else if !locked {
            search()
        } else {
            while locked && count >= nextCenter + DMR.afterCenter { processBurst() }
        }
        // Puffer begrenzen: nur etwa zwei Bursts Vorlauf behalten
        let keepFrom = (locked ? nextCenter - DMR.beforeCenter - 2 : count - 400)
        if keepFrom - base > 2000 {
            let drop = keepFrom - base - 1000
            buffer.removeFirst(drop)
            base += drop
        }
    }

    private func slice(_ from: Int, _ to: Int) -> [Float] {
        let a = from - base, b = to - base
        guard a >= 0, b <= buffer.count else { return [Float](repeating: 0, count: max(0, to - from)) }
        let s = Array(buffer[a..<b])
        return inverted ? s.map { -$0 } : s
    }

    // MARK: Suche

    private func search() {
        guard count - base >= DMR.syncSymbols else { return }
        let window = buffer[(buffer.count - DMR.syncSymbols)...]
        var bestValue: Float = 0
        for kind in DMR.SyncKind.allCases {
            let c = DMR.correlation(window, kind)
            if abs(c) > abs(bestValue) { bestValue = c }
        }
        if acquireCountdown > 0 {
            if abs(bestValue) > abs(acquireBestValue) { acquireBestValue = bestValue; acquireBestIndex = count - DMR.syncSymbols }
            acquireCountdown -= 1
            if acquireCountdown == 0 {
                nextCenter = acquireBestIndex
                pendingLock = true
            }
        } else if abs(bestValue) >= acquireThreshold {
            acquireBestValue = bestValue
            acquireBestIndex = count - DMR.syncSymbols
            acquireCountdown = 3
        }
    }

    /// Bewertung einer Polaritätsannahme an den ersten vier Bursts: gültige Slot Types (Datenbursts) und fehlerfreie Sprachrahmen
    private func polarityScore(center: Int, inverted flip: Bool) -> Float {
        var total: Float = 0
        for k in 0..<4 {
            let c = center + k * DMR.symbolsPerBurst
            let raw = Array(buffer[(c - DMR.beforeCenter - base)..<(c + DMR.afterCenter - base)])
            let burst = flip ? raw.map { -$0 } : raw
            var best: Float = 0
            var kind: DMR.SyncKind?
            for candidate in DMR.SyncKind.allCases {
                let value = DMR.correlation(burst[66..<90], candidate)
                if value > best { best = value; kind = candidate }
            }
            guard best >= 0.7, let kind else { continue }
            if kind.isData {
                if let r = DMRSlotType.decodeWithDistance(before: burst[61..<66], after: burst[90..<95]) { total += Float(4 - r.distance) }
            } else {
                let frames = DMRVoice.frames(burst: burst[...])
                total += 1.5 * Float(frames.filter { AMBEHalfRate.isClean(AMBEHalfRate.bits(fromBytes: $0)) }.count)
            }
        }
        return total
    }

    private func decidePolarityAndLock() {
        pendingLock = false
        if nextCenter - DMR.beforeCenter - base < 0 { return }
        let normal = polarityScore(center: nextCenter, inverted: false)
        let flipped = polarityScore(center: nextCenter, inverted: true)
        inverted = flipped > normal
        locked = true
        burstsWithoutSync = 0
        while locked && count >= nextCenter + DMR.afterCenter { processBurst() }
    }

    // MARK: Burst


    private func processBurst() {
        var center = nextCenter
        // Synchronmuster mit kleiner Zeitkorrektur (−1 … +1 Symbol)
        var kind: DMR.SyncKind?
        var best: Float = 0
        var bestOffset = 0
        for offset in -1...1 {
            let w = slice(center + offset, center + offset + DMR.syncSymbols)
            for k in DMR.SyncKind.allCases {
                let c = DMR.correlation(w[...], k)
                if c > best { best = c; kind = k; bestOffset = offset }
            }
        }
        if best < 0.7 { kind = nil } else { center += bestOffset }
        let burst = slice(center - DMR.beforeCenter, center + DMR.afterCenter)      // 144 Symbole mit CACH
        stats.bursts += 1

        if let kind {
            stats.syncs += 1
            burstsWithoutSync = 0
            isBaseStation = kind.isBase
        } else {
            burstsWithoutSync += 1
        }

        // Zeitschlitz: aus dem CACH (Basisstation), sonst abwechselnd (bei fehlerhaftem CACH) bzw. 0 im Direktmodus
        var slot = 0
        if isBaseStation {
            if let cach = DMRCach.decode(burst[0..<DMR.cachSymbols]) { slot = cach.slot } else { stats.cachBad += 1; slot = 1 - lastSlot }
            lastSlot = slot
        }

        if let kind {
            if kind.isVoice { voiceSync(burst, slot: slot) } else { dataBurst(burst, slot: slot) }
        } else if slots[slot].active {
            embeddedVoice(burst, slot: slot)
        } else {
            // Weder Sync noch laufendes Gespräch: Rauschen oder Lücke
            if burstsWithoutSync > 12 { lose() ; return }
        }
        nextCenter = center + DMR.symbolsPerBurst
    }

    private func lose() {
        stats.lost += 1
        for s in 0..<2 where slots[s].active { onEvent?(.callEnd(slot: s, lc: slots[s].lc, lost: true)) }
        slots = [Slot(), Slot()]
        locked = false
        inverted = false
        acquireCountdown = 0
        onEvent?(.lost)
    }

    // MARK: Sprachbursts

    private func voiceBurst(_ burst: [Float], slot: Int, index: Int) {
        let frames = DMRVoice.frames(burst: burst[...])
        let clean = frames.filter { AMBEHalfRate.isClean(AMBEHalfRate.bits(fromBytes: $0)) }.count
        slots[slot].voiceBursts += 1
        stats.voiceBursts += 1
        stats.frames += frames.count
        stats.cleanFrames += clean
        onEvent?(.voice(DMRVoiceBurst(slot: slot, index: index, colorCode: slots[slot].colorCode, frames: frames, cleanFrames: clean)))
    }

    private func voiceSync(_ burst: [Float], slot: Int) {
        if !slots[slot].active {
            slots[slot] = Slot(active: true, nextIndex: 0)
            stats.calls += 1
            onEvent?(.callStart(slot: slot, colorCode: nil, lc: nil))
        }
        slots[slot].nextIndex = 0
        slots[slot].misses = 0
        slots[slot].fragments = [[UInt8]?](repeating: nil, count: 4)
        voiceBurst(burst, slot: slot, index: 0)
        slots[slot].nextIndex = 1
    }

    private func embeddedVoice(_ burst: [Float], slot: Int) {
        let index = slots[slot].nextIndex
        let center = burst[66..<90]
        let emb = DMREmb.decode(center: center)
        let known = slots[slot].colorCode
        // Gültig: lesbare EMB mit dem bekannten Farbcode (Zufallstreffer des Codes sind sonst zu häufig)
        let valid = emb != nil && (known == nil || emb!.colorCode == known!) && (colorCodeFilter == nil || emb!.colorCode == colorCodeFilter!)
        if !valid {
            slots[slot].misses += 1
            if slots[slot].misses >= 3 { endCall(slot: slot, lc: nil, lost: true); return }
        } else {
            slots[slot].misses = 0
            if slots[slot].colorCode == nil { slots[slot].colorCode = emb!.colorCode }
        }
        // Fragmente der eingebetteten Information: Bursts B bis E (Index 1 … 4), Folge der LCSS: 1, 3, 3, 2
        if (1...4).contains(index), let e = emb, valid {
            let expected = [1, 3, 3, 2][index - 1]
            if e.lcss == expected {
                let fragment = Array(FourFSKBits.hardBits(Array(center)[4..<20][...]))
                if index == 1 { slots[slot].fragments = [[UInt8]?](repeating: nil, count: 4) }
                slots[slot].fragments[index - 1] = fragment
                if index == 4, slots[slot].fragments.allSatisfy({ $0 != nil }), let lc = DMRLinkControl.decodeEmbedded(fragments: slots[slot].fragments.map { $0! }) {
                    stats.embeddedLC += 1
                    if lc.isCall { slots[slot].lc = lc }
                    onEvent?(.linkControl(slot: slot, lc: lc))
                }
            }
        }
        voiceBurst(burst, slot: slot, index: index)
        slots[slot].nextIndex = index == 5 ? 0 : index + 1
        if index == 5 { slots[slot].nextIndex = 0 }
    }

    private func endCall(slot: Int, lc: DMRLinkControl?, lost: Bool) {
        guard slots[slot].active else { return }
        onEvent?(.callEnd(slot: slot, lc: lc ?? slots[slot].lc, lost: lost))
        slots[slot] = Slot()
    }

    // MARK: Datenbursts

    private func dataBurst(_ burst: [Float], slot: Int) {
        guard let slotType = DMRSlotType.decode(before: burst[61..<66], after: burst[90..<95]) else {
            stats.slotTypeBad += 1
            return
        }
        if let filter = colorCodeFilter, slotType.colorCode != filter { return }
        let info = FourFSKBits.hardBits(burst[12..<61]) + FourFSKBits.hardBits(burst[95..<144])
        switch slotType.dataType {
        case .voiceHeader:
            stats.headers += 1
            let lc = DMRLinkControl.decodeFull(info: info, type: .voiceHeader)
            if lc == nil { stats.lcBad += 1 }
            // Der Kopf wird zwei- bis dreimal wiederholt: die Wiederholung gehört zum selben Gespräch
            if slots[slot].active && slots[slot].voiceBursts == 0 {
                if let lc, slots[slot].lc == nil { slots[slot].lc = lc; slots[slot].colorCode = slotType.colorCode; onEvent?(.linkControl(slot: slot, lc: lc)) }
                return
            }
            if slots[slot].active { endCall(slot: slot, lc: nil, lost: true) }
            slots[slot] = Slot(active: true, nextIndex: 0, colorCode: slotType.colorCode)
            slots[slot].lc = lc
            stats.calls += 1
            onEvent?(.callStart(slot: slot, colorCode: slotType.colorCode, lc: lc))
        case .terminator:
            stats.terminators += 1
            let lc = DMRLinkControl.decodeFull(info: info, type: .terminator)
            if lc == nil { stats.lcBad += 1 }
            if slots[slot].active { endCall(slot: slot, lc: lc, lost: false) }
            else if let lc { onEvent?(.linkControl(slot: slot, lc: lc)) }
        default:
            if slotType.dataType == .idle { stats.idleBursts += 1 }
            // Ein Datenburst mitten im Sprachgespräch beendet es (der Abschluss ist verloren gegangen)
            if slots[slot].active { endCall(slot: slot, lc: nil, lost: true) }
            if slotType.dataType != .idle { onEvent?(.data(slot: slot, type: slotType.dataType, colorCode: slotType.colorCode)) }
        }
    }
}
