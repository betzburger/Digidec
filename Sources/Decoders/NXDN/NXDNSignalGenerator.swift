// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Sendeseite von NXDN für Tests und Prüfstände: Rahmen mit LICH, SACCH, FACCH1 und Sprache zu Symbolen (Pegel ±1, ±3); das Audio
// entsteht mit `FourFSKModulator` bei 2400 oder 4800 Symbolen/s.

public enum NXDNSignalGenerator {
    /// Ein Rahmen (192 Symbole): Synchronwort, LICH, SACCH und Nutzdaten
    /// - Parameters:
    ///   - sacch: Aufbau (3 … 0), Funkzugangsnummer und 18 Nutzbits; `nil` = Nullen
    ///   - facch: Nachrichten (80 Bit) für Block A und B
    ///   - voice: Sprachrahmen (9 Byte) für die vier Plätze; fehlende Plätze werden mit Nullrahmen gefüllt
    public static func frame(lich: Int, sacch: (structure: Int, ran: Int, payload: [UInt8])? = nil, facchA: [UInt8]? = nil, facchB: [UInt8]? = nil,
                             voice: [[UInt8]] = []) -> [Float] {
        let l = NXDNLICH(value: lich, parityOK: true)
        var dibits: [UInt8] = []
        dibits.reserveCapacity(NXDN.payloadSymbols)
        // LICH: oberes Bit trägt die Information, das untere ist immer 1
        let code = l.encoded
        for i in 0..<8 { dibits.append((UInt8((code >> (7 - i)) & 1) << 1) | 1) }
        let s = sacch ?? (3, 0, [UInt8](repeating: 0, count: 18))
        dibits += pairs(NXDNCodes.encodeSACCH(structure: s.structure, ran: s.ran, payload: s.payload))
        let zeroMessage = [UInt8](repeating: 0, count: 80)
        func channel(_ k: Int) -> [UInt8] {                      // Block A = Rahmen 0 und 1, Block B = Rahmen 2 und 3
            if l.voice & (k < 2 ? 1 : 2) != 0 {
                let a = AMBEHalfRate.bits(fromBytes: k < voice.count ? voice[k] : [UInt8](repeating: 0, count: 9))
                let b = AMBEHalfRate.bits(fromBytes: k + 1 < voice.count ? voice[k + 1] : [UInt8](repeating: 0, count: 9))
                return a + b
            }
            return NXDNCodes.encodeFACCH1(message: (k < 2 ? facchA : facchB) ?? zeroMessage)
        }
        dibits += pairs(channel(0))
        dibits += pairs(channel(2))
        precondition(dibits.count == NXDN.payloadSymbols)
        let payload = dibits.map { FourFSK.level(ofDibit: $0) }
        return NXDN.fsw + NXDN.scramble(payload)
    }

    private static func pairs(_ bits: [UInt8]) -> [UInt8] {
        stride(from: 0, to: bits.count - 1, by: 2).map { (bits[$0] << 1) | bits[$0 + 1] }
    }

    /// Nachricht (64 Bit) auf 80 Bit (FACCH1) füllen
    public static func facchMessage(_ m: NXDNMessage) -> [UInt8] { m.encoded() + [UInt8](repeating: 0, count: 16) }

    /// SACCH-Teile (Aufbau 3, 2, 1, 0) einer Nachricht aus 64 Bit (auf 72 aufgefüllt)
    public static func sacchParts(_ m: NXDNMessage, ran: Int) -> [(structure: Int, ran: Int, payload: [UInt8])] {
        let bits = m.encoded() + [UInt8](repeating: 0, count: 8)
        return (0..<4).map { (3 - $0, ran, Array(bits[($0 * 18)..<($0 * 18 + 18)])) }
    }

    /// Ein Gespräch: zwei Rufköpfe (FACCH1), Sprachrahmen (4 je Rahmen, das SACCH trägt der Reihe nach die Rufnachricht), Freigabe (FACCH1)
    /// - Parameters:
    ///   - frames: Sprachrahmen (9 Byte), ein Vielfaches von vier wird verwendet (der Rest mit Nullrahmen aufgefüllt)
    ///   - interleaveData: NXDN96: nach jedem Sprachrahmen ein Rahmen mit zwei FACCH1 (der Rufkopf wird wiederholt)
    public static func call(source: Int, destination: Int, callType: Int = 1, ran: Int = 1, option: Int = 0, cipher: Int = 0, keyID: Int = 0,
                            frames: [[UInt8]], interleaveData: Bool = false, withEnd: Bool = true, headers: Int = 2) -> [Float] {
        let vcall = NXDNMessage(type: NXDNMessage.vcall, callType: callType, option: option, source: source, destination: destination, cipher: cipher, keyID: keyID)
        let release = NXDNMessage(type: NXDNMessage.txRel, callType: callType, option: option, source: source, destination: destination, cipher: 0, keyID: 0)
        let parts = sacchParts(vcall, ran: ran)
        var padded = frames
        while padded.isEmpty || padded.count % 4 != 0 { padded.append([UInt8](repeating: 0, count: 9)) }
        var out: [Float] = []
        var n = 0
        func next() -> (structure: Int, ran: Int, payload: [UInt8]) { defer { n += 1 }; return parts[n % 4] }
        for _ in 0..<headers {
            out += frame(lich: 0x51, sacch: next(), facchA: facchMessage(vcall), facchB: facchMessage(vcall))
        }
        for g in 0..<(padded.count / 4) {
            out += frame(lich: 0x57, sacch: next(), voice: Array(padded[(g * 4)..<(g * 4 + 4)]))
            if interleaveData { out += frame(lich: 0x51, sacch: next(), facchA: facchMessage(vcall), facchB: facchMessage(vcall)) }
        }
        if withEnd {
            for _ in 0..<2 { out += frame(lich: 0x51, sacch: next(), facchA: facchMessage(release), facchB: facchMessage(release)) }
        }
        return out
    }
}
