// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// DMR (Digital Mobile Radio, ETSI TS 102 361-1, Stufe 1 mit zwei Zeitschlitzen): Rahmenschicht.
//
// Ein Burst dauert 30 ms = 144 Symbole bei 4800 Symbolen/s (4FSK):
//   CACH 12 Symbole (nur Basisstation) · Nutzdaten 132 Symbole: 54 | Mitte 24 (Sync oder EMB + Fragment) | 54
// Sprachburst: Rahmen A = 36 Symbole, Rahmen B = 18 + 18 (um die Mitte herum), Rahmen C = 36; je 72 Bit Sprachcodec (Halbrate).
// Datenburst: 98 Bit | Slot Type 10 | Sync 48 Bit | Slot Type 10 | 98 Bit; die 196 Infobits sind BPTC (196,96).
// Sechs Sprachbursts desselben Zeitschlitzes bilden einen Überrahmen (A mit Sync, B bis F mit EMB). Die beiden Zeitschlitze
// wechseln sich Burst für Burst ab (Basisstation: gekennzeichnet durch TACT im CACH).

public enum DMR {
    public static let symbolsPerBurst = 144
    public static let cachSymbols = 12
    public static let syncSymbols = 24
    /// Abstand von der Mitte (Sync) zum Beginn des CACH und zum Ende des Bursts
    public static let beforeCenter = 66
    public static let afterCenter = 78

    public enum SyncKind: Int, Sendable, CaseIterable {
        case baseVoice, baseData, mobileVoice, mobileData

        var bytes: [UInt8] {
            switch self {
            case .baseVoice: return [0x75, 0x5F, 0xD7, 0xDF, 0x75, 0xF7]
            case .baseData: return [0xDF, 0xF5, 0x7D, 0x75, 0xDF, 0x5D]
            case .mobileVoice: return [0x7F, 0x7D, 0x5D, 0xD5, 0x7D, 0xFD]
            case .mobileData: return [0xD5, 0xD7, 0xF7, 0x7F, 0xD7, 0x57]
            }
        }

        public var isVoice: Bool { self == .baseVoice || self == .mobileVoice }
        public var isData: Bool { !isVoice }
        public var isBase: Bool { self == .baseVoice || self == .baseData }

        /// Pegel der 24 Symbole (je zwei Bit ein Symbol: 01 → +3, 00 → +1, 10 → −1, 11 → −3)
        var levels: [Float] { bytes.flatMap { b in (0..<4).map { FourFSK.level(ofDibit: (b >> UInt8(6 - 2 * $0)) & 3) } } }
    }

    /// Korrelation der 24 Symbole in `window` (Normalpolarität) mit einem Syncmuster, −1 … +1
    static func correlation(_ window: ArraySlice<Float>, _ kind: SyncKind) -> Float {
        let pattern = patterns[kind.rawValue]
        var dot: Float = 0, energy: Float = 0, patternEnergy: Float = 0
        var i = 0
        for value in window {
            dot += value * pattern[i]
            energy += value * value
            patternEnergy += pattern[i] * pattern[i]
            i += 1
        }
        return dot / max(1e-6, (energy * patternEnergy).squareRoot())
    }

    static let patterns: [[Float]] = SyncKind.allCases.map(\.levels)

    /// Datentypen im Slot Type
    public enum DataType: Int, Sendable {
        case piHeader = 0, voiceHeader, terminator, csbk, multiBlockHeader, multiBlockContinuation, dataHeader
        case rate12Data, rate34Data, idle, rate1Data
        case unknown = 15

        public var title: String {
            switch self {
            case .piHeader: return "PI-Kopf"
            case .voiceHeader: return "Sprach-Kopf"
            case .terminator: return "Abschluss"
            case .csbk: return "CSBK"
            case .multiBlockHeader: return "MBC-Kopf"
            case .multiBlockContinuation: return "MBC"
            case .dataHeader: return "Daten-Kopf"
            case .rate12Data: return "Daten 1/2"
            case .rate34Data: return "Daten 3/4"
            case .idle: return "Leerlauf"
            case .rate1Data: return "Daten 1"
            case .unknown: return "?"
            }
        }
    }
}

// MARK: - CACH

public struct DMRCach: Equatable, Sendable {
    /// Zugriffsart (Kanal belegt), Zeitschlitz des folgenden Bursts (0 = Zeitschlitz 1, 1 = Zeitschlitz 2), Teil von Short-LC
    public var accessType: Bool
    public var slot: Int
    public var lcss: Int

    private static let interleave = [0, 7, 8, 9, 1, 10, 11, 12, 2, 13, 14, 15, 3, 16, 4, 17, 18, 19, 5, 20, 21, 22, 6, 23]

    /// Aus den 12 Symbolen vor einem Burst; `nil` bei Fehlern, die das Hamming (7,4) nicht korrigiert
    public static func decode(_ symbols: ArraySlice<Float>) -> DMRCach? {
        guard symbols.count == DMR.cachSymbols else { return nil }
        let raw = FourFSKBits.hardBits(symbols)
        var cach = [UInt8](repeating: 0, count: 24)
        for i in 0..<24 { cach[interleave[i]] = raw[i] }
        let r = HammingCode.h74.decode(Array(cach[0..<7]))
        guard r.ok else { return nil }
        return DMRCach(accessType: r.bits[0] != 0, slot: Int(r.bits[1]), lcss: Int(r.bits[2]) << 1 | Int(r.bits[3]))
    }

    /// 12 Symbole für Prüfstände (der Rest der 24 Bit ist Short-LC und bleibt null)
    public func symbols() -> [Float] {
        let tact = HammingCode.h74.encode([accessType ? 1 : 0, UInt8(slot), UInt8(lcss >> 1), UInt8(lcss & 1)])
        var cach = [UInt8](repeating: 0, count: 24)
        for i in 0..<7 { cach[i] = tact[i] }
        // Die übrigen 17 Bit tragen in Wirklichkeit Short-LC-Daten; für Prüfstände eine feste Pseudozufallsfolge (lange Nullfolgen
        // ohne Nulldurchgang brächten den Bittakt des Empfängers aus dem Tritt, das kommt im Funkbetrieb nicht vor)
        var fill: UInt32 = 0xACE1
        for i in 7..<24 {
            let bit = ((fill >> 0) ^ (fill >> 2) ^ (fill >> 3) ^ (fill >> 5)) & 1
            fill = (fill >> 1) | (bit << 15)
            cach[i] = UInt8(fill & 1)
        }
        var bits = [UInt8](repeating: 0, count: 24)
        for i in 0..<24 { bits[i] = cach[Self.interleave[i]] }
        return stride(from: 0, to: 24, by: 2).map { FourFSK.level(ofDibit: (bits[$0] << 1) | bits[$0 + 1]) }
    }
}

// MARK: - Slot Type und EMB

public struct DMRSlotType: Equatable, Sendable {
    public var colorCode: Int
    public var dataType: DMR.DataType

    /// Aus den 5 Symbolen vor und den 5 Symbolen nach der Mitte (20 Bit); `nil`, wenn mehr als 3 Fehler
    public static func decode(before: ArraySlice<Float>, after: ArraySlice<Float>) -> DMRSlotType? {
        decodeWithDistance(before: before, after: after)?.slotType
    }

    /// Wie `decode`, dazu die Zahl der korrigierten Bitfehler (0 … 3)
    public static func decodeWithDistance(before: ArraySlice<Float>, after: ArraySlice<Float>) -> (slotType: DMRSlotType, distance: Int)? {
        let bits = FourFSKBits.hardBits(before) + FourFSKBits.hardBits(after)
        guard bits.count == 20, let r = TableCode.golay208.decode(bits, maxDistance: 3) else { return nil }
        return (DMRSlotType(colorCode: r.data >> 4, dataType: DMR.DataType(rawValue: r.data & 15) ?? .unknown), r.distance)
    }

    public func bits() -> [UInt8] { TableCode.golay208.encode((colorCode << 4) | dataType.rawValue) }
}

public struct DMREmb: Equatable, Sendable {
    public var colorCode: Int
    public var pi: Bool
    /// Fragmentkennung: 0 einzeln, 1 erstes, 3 mittleres, 2 letztes Fragment der eingebetteten Information
    public var lcss: Int

    /// Aus den 16 Bit der Mitte (je vier Symbole am Anfang und am Ende); `nil`, wenn mehr als 2 Fehler
    public static func decode(center: ArraySlice<Float>) -> DMREmb? {
        guard center.count == DMR.syncSymbols else { return nil }
        let c = Array(center)
        let bits = FourFSKBits.hardBits(c[0..<4][...]) + FourFSKBits.hardBits(c[20..<24][...])
        guard let r = TableCode.qr1676.decode(bits, maxDistance: 2) else { return nil }
        return DMREmb(colorCode: (r.data >> 3) & 15, pi: (r.data >> 2) & 1 != 0, lcss: r.data & 3)
    }

    public func bits() -> [UInt8] { TableCode.qr1676.encode((colorCode << 3) | (pi ? 4 : 0) | lcss) }
}

// MARK: - Link Control

/// Link Control: Wer ruft wen (Sprach-Kopf, Abschluss, eingebettet in den Sprachbursts)
public struct DMRLinkControl: Equatable, Sendable {
    /// 0 Gruppenruf, 3 Einzelruf; andere: Talker Alias, GPS, herstellerspezifisch
    public var flco: Int
    public var featureID: Int
    public var serviceOptions: Int
    public var destination: Int
    public var source: Int

    public var isGroupCall: Bool { flco == 0 }
    public var isPrivateCall: Bool { flco == 3 }
    /// Gespräch mit Ziel und Quelle (Gruppen- oder Einzelruf)
    public var isCall: Bool { flco == 0 || flco == 3 }
    public var isEmergency: Bool { serviceOptions & 0x80 != 0 }
    public var isEncrypted: Bool { serviceOptions & 0x40 != 0 }

    public init(flco: Int = 0, featureID: Int = 0, serviceOptions: Int = 0, destination: Int, source: Int) {
        self.flco = flco; self.featureID = featureID; self.serviceOptions = serviceOptions
        self.destination = destination; self.source = source
    }

    /// 9 Bytes: FLCO (6 Bit; zwei Bit PF und reserviert), FID, Dienstmerkmale, Ziel (24), Quelle (24)
    public init(bytes b: [UInt8]) {
        flco = Int(b[0] & 0x3F)
        featureID = Int(b[1])
        serviceOptions = Int(b[2])
        destination = Int(b[3]) << 16 | Int(b[4]) << 8 | Int(b[5])
        source = Int(b[6]) << 16 | Int(b[7]) << 8 | Int(b[8])
    }

    public var bytes: [UInt8] {
        [UInt8(flco & 0x3F), UInt8(featureID), UInt8(serviceOptions),
         UInt8((destination >> 16) & 255), UInt8((destination >> 8) & 255), UInt8(destination & 255),
         UInt8((source >> 16) & 255), UInt8((source >> 8) & 255), UInt8(source & 255)]
    }

    static func bits(ofBytes bytes: [UInt8]) -> [UInt8] { bytes.flatMap { b in (0..<8).map { UInt8((b >> UInt8(7 - $0)) & 1) } } }
    static func bytes(ofBits bits: ArraySlice<UInt8>) -> [UInt8] {
        let b = Array(bits)
        return stride(from: 0, to: b.count - 7, by: 8).map { i in (0..<8).reduce(UInt8(0)) { ($0 << 1) | b[i + $1] } }
    }

    // MARK: Sprach-Kopf und Abschluss (BPTC 196,96 mit Reed-Solomon)

    /// Maske auf den drei Prüfbytes: Sprach-Kopf 0x969696, Abschluss 0x999999
    static func mask(for type: DMR.DataType) -> [UInt8] { type == .terminator ? [0x99, 0x99, 0x99] : [0x96, 0x96, 0x96] }

    /// 196 Infobits eines Datenbursts → Link Control (mit Reed-Solomon-Prüfung); `nil` bei nicht korrigierbaren Fehlern
    public static func decodeFull(info: [UInt8], type: DMR.DataType) -> DMRLinkControl? {
        let d = BPTC196.decode(info)
        let b = bytes(ofBits: d.data[...])
        guard b.count == 12 else { return nil }
        let mask = mask(for: type)
        var word = b
        for i in 0..<3 { word[9 + i] ^= mask[i] }
        guard let fixed = ReedSolomon129.correct(word) else { return nil }
        return DMRLinkControl(bytes: Array(fixed.word[0..<9]))
    }

    /// Link Control → 196 Infobits eines Datenbursts (für Prüfstände)
    public func encodeFull(type: DMR.DataType) -> [UInt8] {
        let message = bytes
        let mask = Self.mask(for: type)
        let parity = ReedSolomon129.parity(message)
        let word = message + (0..<3).map { parity[$0] ^ mask[$0] }
        return BPTC196.encode(Self.bits(ofBytes: word))
    }

    // MARK: Eingebettet (BPTC 128,77 mit Summe modulo 31)

    /// Summe der neun Bytes modulo 31
    static func checksum5(_ bytes: [UInt8]) -> Int { bytes.reduce(0) { $0 + Int($1) } % 31 }

    /// 4 Fragmente zu je 32 Bit → Link Control; `nil`, wenn Prüfsumme oder Fehlerschutz versagen
    public static func decodeEmbedded(fragments: [[UInt8]]) -> DMRLinkControl? {
        guard fragments.count == 4, fragments.allSatisfy({ $0.count == 32 }) else { return nil }
        let d = BPTC128.decode(fragments.flatMap { $0 })
        let lc = bytes(ofBits: d.data[0..<72])
        let crc = d.data[72..<77].reduce(0) { ($0 << 1) | Int($1) }
        guard lc.count == 9, checksum5(lc) == crc else { return nil }
        return DMRLinkControl(bytes: lc)
    }

    public func encodeEmbedded() -> [[UInt8]] {
        let message = bytes
        let crc = Self.checksum5(message)
        let bits = Self.bits(ofBytes: message) + (0..<5).map { UInt8((crc >> (4 - $0)) & 1) }
        let all = BPTC128.encode(bits)
        return (0..<4).map { Array(all[($0 * 32)..<($0 * 32 + 32)]) }
    }
}

// MARK: - Sprachbursts

public enum DMRVoice {
    /// Aus den 144 Symbolen eines Bursts (CACH inklusive) die drei Sprachrahmen A, B, C (je 72 Luftbits, MSB-zuerst in 9 Byte)
    public static func frames(burst: ArraySlice<Float>) -> [[UInt8]] {
        let s = Array(burst)
        func bits(_ range: Range<Int>) -> [UInt8] { FourFSKBits.hardBits(s[range][...]) }
        let a = bits(12..<48)
        let b = bits(48..<66) + bits(90..<108)
        let c = bits(108..<144)
        return [a, b, c].map { AMBEHalfRate.bytes(fromAir: $0) }
    }

    /// Umkehrung für Prüfstände: drei Sprachrahmen (9 Byte) → 3 Teile der Symbole (A 36, B 18 + 18, C 36)
    static func symbols(ofFrame bytes: [UInt8]) -> [Float] {
        let bits = AMBEHalfRate.bits(fromBytes: bytes)
        return stride(from: 0, to: 72, by: 2).map { FourFSK.level(ofDibit: (bits[$0] << 1) | bits[$0 + 1]) }
    }
}
