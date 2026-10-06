// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Erzeugt DMR-Bursts (Basisstation mit CACH, beide Zeitschlitze) als Symbolfolge für Prüfstände:
// Sprach-Kopf, Sprachbursts mit eingebetteter Link-Control-Information, Abschluss und Leerlauf im anderen Zeitschlitz.

public enum DMRSignalGenerator {
    /// Nullsignal der Sprache: 9 Byte, die als gültiger Rahmen durchgehen (alle Nutzbits null)
    public static let silentFrame: [UInt8] = AMBEHalfRate.bytes(fromAir: AMBEHalfRate.air72(fromData49: [UInt8](repeating: 0, count: 49)))

    private static func symbols(fromBits bits: [UInt8]) -> [Float] {
        stride(from: 0, to: bits.count, by: 2).map { FourFSK.level(ofDibit: (bits[$0] << 1) | bits[$0 + 1]) }
    }

    /// Datenburst (Sprach-Kopf, Abschluss, Leerlauf …): CACH + 49 Symbole Info + Slot Type + Sync + Slot Type + 49 Symbole Info
    public static func dataBurst(slot: Int, colorCode: Int, type: DMR.DataType, info: [UInt8], kind: DMR.SyncKind = .baseData) -> [Float] {
        precondition(info.count == 196)
        let cach = DMRCach(accessType: true, slot: slot, lcss: 0).symbols()
        let slotType = DMRSlotType(colorCode: colorCode, dataType: type).bits()
        let a = symbols(fromBits: Array(info[0..<98]))
        let b = symbols(fromBits: Array(info[98..<196]))
        return cach + a + symbols(fromBits: Array(slotType[0..<10])) + kind.levels + symbols(fromBits: Array(slotType[10..<20])) + b
    }

    /// Sprachburst: Rahmen A, B, C (je 9 Byte); `center` ist entweder das Sync-Muster oder EMB + Fragment (32 Bit) + EMB
    public static func voiceBurst(slot: Int, frames: [[UInt8]], center: [Float]) -> [Float] {
        precondition(frames.count == 3 && center.count == 24)
        let cach = DMRCach(accessType: true, slot: slot, lcss: 0).symbols()
        let a = DMRVoice.symbols(ofFrame: frames[0])
        let b = DMRVoice.symbols(ofFrame: frames[1])
        let c = DMRVoice.symbols(ofFrame: frames[2])
        return cach + a + b[0..<18] + center + b[18..<36] + c
    }

    static func embeddedCenter(colorCode: Int, lcss: Int, fragment: [UInt8]) -> [Float] {
        let emb = DMREmb(colorCode: colorCode, pi: false, lcss: lcss).bits()
        return symbols(fromBits: Array(emb[0..<8])) + symbols(fromBits: fragment) + symbols(fromBits: Array(emb[8..<16]))
    }

    /// Leerlauf (Datentyp 9) für den Zeitschlitz ohne Gespräch
    public static func idleBurst(slot: Int, colorCode: Int) -> [Float] {
        dataBurst(slot: slot, colorCode: colorCode, type: .idle, info: BPTC196.encode([UInt8](repeating: 0, count: 96)))
    }

    /// Die Bursts eines Gesprächs in einem Zeitschlitz (ohne den anderen Zeitschlitz)
    /// - Parameters:
    ///   - frames: Sprachrahmen (9 Byte je 20 ms); fehlende bis zum vollen Überrahmen (6 Bursts = 18 Rahmen) werden mit Stille aufgefüllt
    ///   - withHeader: Sprach-Kopf (zwei Wiederholungen) vor dem Gespräch
    ///   - withTerminator: Abschluss nach dem letzten Überrahmen
    public static func bursts(slot: Int, colorCode: Int = 1, lc: DMRLinkControl, frames: [[UInt8]], withHeader: Bool = true,
                              withTerminator: Bool = true, embedded: Bool = true) -> [[Float]] {
        var own: [[Float]] = []
        if withHeader {
            let header = lc.encodeFull(type: .voiceHeader)
            for _ in 0..<2 { own.append(dataBurst(slot: slot, colorCode: colorCode, type: .voiceHeader, info: header)) }
        }
        var padded = frames
        while padded.count % 18 != 0 { padded.append(silentFrame) }
        let fragments = lc.encodeEmbedded()
        let empty = [UInt8](repeating: 0, count: 32)
        for superframe in 0..<(padded.count / 18) {
            for burst in 0..<6 {
                let f = Array(padded[(superframe * 18 + burst * 3)..<(superframe * 18 + burst * 3 + 3)])
                let center: [Float]
                switch burst {
                case 0: center = DMR.SyncKind.baseVoice.levels
                case 1...4: center = embeddedCenter(colorCode: colorCode, lcss: [1, 3, 3, 2][burst - 1], fragment: embedded ? fragments[burst - 1] : empty)
                default: center = embeddedCenter(colorCode: colorCode, lcss: 0, fragment: empty)
                }
                own.append(voiceBurst(slot: slot, frames: f, center: center))
            }
        }
        if withTerminator {
            own.append(dataBurst(slot: slot, colorCode: colorCode, type: .terminator, info: lc.encodeFull(type: .terminator)))
        }
        return own
    }

    /// Beide Zeitschlitze zusammen: Bursts wechseln sich ab (Zeitschlitz 0, 1, 0, 1 …); wo nichts ist, gibt es Leerlauf.
    public static func stream(slot0: [[Float]], slot1: [[Float]], colorCode: Int = 1, leadIdleBursts: Int = 4, trailIdleBursts: Int = 6) -> [Float] {
        var out: [Float] = []
        var next = [0, 0]
        let lists = [slot0, slot1]
        var t = 0, trail = 0
        while next[0] < slot0.count || next[1] < slot1.count || trail < trailIdleBursts {
            let s = t % 2
            if t >= leadIdleBursts && next[s] < lists[s].count {
                out += lists[s][next[s]]
                next[s] += 1
            } else {
                out += idleBurst(slot: s, colorCode: colorCode)
                if next[0] >= slot0.count && next[1] >= slot1.count { trail += 1 }
            }
            t += 1
        }
        return out
    }

    /// Ein Gespräch in `slot`; der andere Zeitschlitz bleibt im Leerlauf
    public static func call(slot: Int, colorCode: Int = 1, lc: DMRLinkControl, frames: [[UInt8]], withHeader: Bool = true, withTerminator: Bool = true,
                            embedded: Bool = true, leadIdleBursts: Int = 4, trailIdleBursts: Int = 6) -> [Float] {
        let own = bursts(slot: slot, colorCode: colorCode, lc: lc, frames: frames, withHeader: withHeader, withTerminator: withTerminator, embedded: embedded)
        return stream(slot0: slot == 0 ? own : [], slot1: slot == 1 ? own : [], colorCode: colorCode, leadIdleBursts: leadIdleBursts, trailIdleBursts: trailIdleBursts)
    }
}
