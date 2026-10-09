// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Yaesu System Fusion (C4FM): Rahmenschicht.
//
// Rahmen: 100 ms = 480 Symbole (4800 Symbole/s): Rahmensynchronisation 20 Symbole (0xD4 71 C9 63 4D), FICH 100 Symbole
// (Faltungscode K=5, vier Golay-Wörter (24,12), CRC-16), dann 360 Symbole Nutzdaten. Je nach Datentyp (FICH.DT):
//   DT 2 (V/D-Modus 2): fünf Kanäle zu je 20 Symbolen Daten (DCH) und 52 Symbolen Sprache (VeCH, 104 Bit: Wiederholungscode)
//   DT 0 (V/D-Modus 1), DT 3 (Vollrate-Sprache), DT 1 (Daten): Sprache hier nicht unterstützt, Rufzeichen aus Kopf und Abschluss
// Kopf (FI 0) und Abschluss (FI 2) tragen zwei Datenkanäle zu je 180 Symbolen mit den Rufzeichen.
// Quellen: Beschreibung des Verfahrens (Yaesu-Spezifikation „System Fusion“ in der Fassung der Amateurfunk-Gemeinde),
// Reihenfolgen und Verwürfelung an einer echten Aufnahme geprüft (dsdcc/samples). Siehe THIRD_PARTY.md.

public enum YSF {
    public static let frameSymbols = 480
    public static let syncSymbols = 20
    public static let fichSymbols = 100
    public static let payloadSymbols = 360

    /// Rahmensynchronisation als Bytes (MSB zuerst), je zwei Bit ein Symbol
    public static let syncBytes: [UInt8] = [0xD4, 0x71, 0xC9, 0x63, 0x4D]
    public static let syncLevels: [Float] = syncBytes.flatMap { b in (0..<4).map { FourFSK.level(ofDibit: (b >> UInt8(6 - 2 * $0)) & 3) } }

    /// Verwürfelungsfolge der Nutzdaten: 9-Bit-Schieberegister (x⁹ + x⁴ + 1), Anfangswert 0x1C9, Periode 511
    public static let whitening: [UInt8] = {
        var state = 0x1C9
        var out: [UInt8] = []
        for _ in 0..<512 {
            out.append(UInt8(state & 1))
            let feedback = ((state >> 4) ^ state) & 1
            state = (state >> 1) | (feedback << 8)
        }
        return out
    }()

    /// Stelle k (0…103) im gesendeten Sprachkanal → Bitposition (Verschachtelung 26 × 4)
    static let voiceInterleave: [Int] = (0..<104).map { ($0 / 4) + 26 * ($0 % 4) }
}

// MARK: - FICH

public struct YSFFich: Equatable, Sendable {
    /// Rahmenart: 0 Kopf, 1 Kommunikation, 2 Abschluss, 3 Test
    public var fi: Int
    public var cs: Int
    /// Ruftyp: 0 CQ/Gruppe, 1 Funkgeräte-ID, 3 privat
    public var cm: Int
    public var bn: Int, bt: Int
    /// Rahmennummer und -zahl (je 0…7)
    public var fn: Int, ft: Int
    public var mr: Int
    /// Über das Netz (Repeater) statt direkt
    public var viaRepeater: Bool
    /// Datentyp: 0 V/D-Modus 1, 1 Daten (Vollrate), 2 V/D-Modus 2, 3 Sprache (Vollrate)
    public var dt: Int
    public var squelchEnabled: Bool
    public var squelchCode: Int

    public var isHeader: Bool { fi == 0 }
    public var isCommunication: Bool { fi == 1 }
    public var isTerminator: Bool { fi == 2 }

    /// Decodiert 100 Symbole nach der Rahmensynchronisation. `nil`, wenn Golay oder Prüfsumme versagen.
    public static func decode(symbols: ArraySlice<Float>) -> YSFFich? {
        guard symbols.count == YSF.fichSymbols else { return nil }
        let sym = Array(symbols)
        var soft: [Float] = []
        soft.reserveCapacity(200)
        for symbol in YSFInterleave.deinterleave(sym, columns: 20, rows: 5) {
            let s = FourFSKBits.soft(symbol)
            soft.append(s.0); soft.append(s.1)
        }
        let bits = ConvK5.decode(soft: soft)
        guard bits.count >= 96 else { return nil }
        var data: [UInt8] = []
        for w in 0..<4 { data += Golay.decode24(bits[(w * 24)..<(w * 24 + 24)]).data }
        guard YaesuCRC.remainder(data) == 0 else { return nil }
        func n(_ a: Int, _ c: Int) -> Int { data[a..<(a + c)].reduce(0) { ($0 << 1) | Int($1) } }
        return YSFFich(fi: n(0, 2), cs: n(2, 2), cm: n(4, 2), bn: n(6, 2), bt: n(8, 2), fn: n(10, 3), ft: n(13, 3), mr: n(18, 3),
                       viaRepeater: data[21] != 0, dt: n(22, 2), squelchEnabled: data[24] != 0, squelchCode: n(25, 7))
    }

    /// Erzeugt die 100 Symbole (für Prüfstände)
    public func symbols() -> [Float] {
        var data = [UInt8](repeating: 0, count: 32)
        func put(_ value: Int, _ at: Int, _ count: Int) { for i in 0..<count { data[at + i] = UInt8((value >> (count - 1 - i)) & 1) } }
        put(fi, 0, 2); put(cs, 2, 2); put(cm, 4, 2); put(bn, 6, 2); put(bt, 8, 2); put(fn, 10, 3); put(ft, 13, 3); put(mr, 18, 3)
        data[21] = viaRepeater ? 1 : 0
        put(dt, 22, 2)
        data[24] = squelchEnabled ? 1 : 0
        put(squelchCode, 25, 7)
        let full = data + YaesuCRC.checkBits(for: data)                       // 48 Bit
        var coded: [UInt8] = []
        for w in 0..<4 { coded += Golay.encode24(Array(full[(w * 12)..<(w * 12 + 12)])) }      // 96 Bit
        let conv = ConvK5.encode(coded + [0, 0, 0, 0])                                          // 200 Bit
        let dibits = stride(from: 0, to: conv.count, by: 2).map { Float(0) + FourFSK.level(ofDibit: (conv[$0] << 1) | conv[$0 + 1]) }
        return YSFInterleave.interleave(dibits, columns: 20, rows: 5)
    }
}

enum YSFInterleave {
    /// Empfangsreihenfolge → Codereihenfolge: buf[j + rows·i] = in[i + columns·j]
    static func deinterleave<T>(_ input: [T], columns: Int, rows: Int) -> [T] {
        var out = input
        for i in 0..<columns { for j in 0..<rows { out[j + rows * i] = input[i + columns * j] } }
        return out
    }

    static func interleave<T>(_ input: [T], columns: Int, rows: Int) -> [T] {
        var out = input
        for i in 0..<columns { for j in 0..<rows { out[i + columns * j] = input[j + rows * i] } }
        return out
    }
}

// MARK: - Datenkanäle (Rufzeichen)

public enum YSFText: Equatable, Sendable {
    case destination(String)
    case source(String)
    case uplink(String)
    case downlink(String)
    case remarks(String)
    /// Funkgeräte-Kennungen (RID-Modus: Ziel und Quelle zu je 5 Zeichen)
    case radioIDs(destination: String, source: String)
}

public enum YSFDataChannel {
    /// Zeichen aus Bytes (druckbar, sonst Leerzeichen), Leerzeichen am Ende entfernt
    static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes.map { ($0 >= 0x20 && $0 < 0x7F) ? Character(UnicodeScalar($0)) : " " }).trimmingCharacters(in: .whitespaces)
    }

    static func bytes(_ bits: ArraySlice<UInt8>) -> [UInt8] {
        let b = Array(bits)
        return stride(from: 0, to: b.count - 7, by: 8).map { i in (0..<8).reduce(UInt8(0)) { ($0 << 1) | b[i + $1] } }
    }

    /// Kommunikationsrahmen im V/D-Modus 2: fünf mal 20 Symbole → 10 Byte (Rufzeichen o. Ä., je nach Rahmennummer)
    public static func decodeVD2(symbols: [Float]) -> [UInt8]? {
        guard symbols.count == 100 else { return nil }
        var soft: [Float] = []
        for s in YSFInterleave.deinterleave(symbols, columns: 20, rows: 5) { let v = FourFSKBits.soft(s); soft.append(v.0); soft.append(v.1) }
        let bits = ConvK5.decode(soft: soft)
        guard bits.count >= 96, YaesuCRC.remainder(Array(bits[0..<96])) == 0 else { return nil }
        let clear = (0..<80).map { bits[$0] ^ YSF.whitening[$0] }
        return bytes(clear[...])
    }

    /// Kopf und Abschluss: ein Kanal zu 180 Symbolen → 20 Byte
    public static func decodeFull(symbols: [Float]) -> [UInt8]? {
        guard symbols.count == 180 else { return nil }
        var soft: [Float] = []
        for s in YSFInterleave.deinterleave(symbols, columns: 20, rows: 9) { let v = FourFSKBits.soft(s); soft.append(v.0); soft.append(v.1) }
        let bits = ConvK5.decode(soft: soft)
        guard bits.count >= 176, YaesuCRC.remainder(Array(bits[0..<176])) == 0 else { return nil }
        let clear = (0..<160).map { bits[$0] ^ YSF.whitening[$0] }
        return bytes(clear[...])
    }

    /// Text zu einem Datenkanal von V/D-Modus 2 (Rahmennummer fn)
    public static func textVD2(fn: Int, cm: Int, bytes b: [UInt8]) -> YSFText? {
        switch fn {
        case 0: return cm == 1 ? .radioIDs(destination: text(b[0..<5]), source: text(b[5..<10])) : .destination(text(b[0..<10]))
        case 1: return .source(text(b[0..<10]))
        case 2: return .uplink(text(b[0..<10]))
        case 3: return .downlink(text(b[0..<10]))
        case 4: return .remarks(text(b[0..<10]))
        default: return nil
        }
    }
}

// MARK: - Sprachkanal V/D-Modus 2

public enum YSFVoice {
    /// 52 Symbole → 104 Bit (entschachtelt und entwürfelt)
    static func channelBits(_ symbols: ArraySlice<Float>) -> [UInt8] {
        var bits = [UInt8](repeating: 0, count: 104)
        var k = 0
        for s in symbols {
            let h = FourFSKBits.hard(s)
            let a = YSF.voiceInterleave[k], b = YSF.voiceInterleave[k + 1]
            k += 2
            bits[a] = h.0 ^ YSF.whitening[a]
            bits[b] = h.1 ^ YSF.whitening[b]
        }
        return bits
    }

    /// 104 Bit → 49 Nutzbits: die ersten 81 Bit sind dreifach wiederholt (Mehrheit), dann folgen 22 ungeschützte Bits
    public static func data49(fromChannelBits v: [UInt8]) -> (data: [UInt8], disagreements: Int) {
        var out: [UInt8] = []
        var disagreements = 0
        for t in 0..<27 {
            let ones = Int(v[3 * t]) + Int(v[3 * t + 1]) + Int(v[3 * t + 2])
            out.append(ones >= 2 ? 1 : 0)
            if ones == 1 || ones == 2 { disagreements += 1 }
        }
        out += v[81..<103]
        return (out, disagreements)
    }

    /// 52 Symbole → Sprachrahmen (9 Byte im Format des Sprachsticks) und die Zahl uneiniger Wiederholungen (0…27)
    public static func frame(_ symbols: ArraySlice<Float>) -> (ambe: [UInt8], disagreements: Int) {
        let d = data49(fromChannelBits: channelBits(symbols))
        return (AMBEHalfRate.bytes(fromAir: AMBEHalfRate.air72(fromData49: d.data)), d.disagreements)
    }

    /// Gegenstück für Prüfstände: 49 Nutzbits → 52 Symbole
    public static func symbols(forData49 d: [UInt8]) -> [Float] {
        var bits = [UInt8](repeating: 0, count: 104)
        for t in 0..<27 { for r in 0..<3 { bits[3 * t + r] = d[t] } }
        for i in 0..<22 { bits[81 + i] = d[27 + i] }
        var out: [Float] = []
        var k = 0
        for _ in 0..<52 {
            let a = YSF.voiceInterleave[k], b = YSF.voiceInterleave[k + 1]
            k += 2
            out.append(FourFSK.level(ofDibit: ((bits[a] ^ YSF.whitening[a]) << 1) | (bits[b] ^ YSF.whitening[b])))
        }
        return out
    }
}
