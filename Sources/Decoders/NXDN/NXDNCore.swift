// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// NXDN (Kenwood NEXEDGE, Icom IDAS; NXDN Forum TS 1-A): 4FSK mit Pegeln ±1, ±3, Symbolraten 2400 Bd (NXDN48, 6,25 kHz) und 4800 Bd
// (NXDN96, 12,5 kHz). Das Dibit-Alphabet ist dasselbe wie bei DMR/dPMR (+3 → 01, +1 → 00, −1 → 10, −3 → 11).
//
// Rahmen zu 192 Symbolen (80 ms bei 2400 Bd, 40 ms bei 4800 Bd): Synchronwort FSW (10 Symbole), LICH (8 Symbole), SACCH (30 Symbole),
// dann 144 Symbole Nutzdaten: zwei FACCH1 zu je 72 Symbolen oder vier Sprachrahmen zu je 36 Symbolen (oder gemischt: ein FACCH1 ersetzt
// zwei Sprachrahmen). Alles hinter dem Synchronwort ist mit der Folge PN95 verwürfelt (Dibit-Vorzeichen). Die Kanäle sind gefaltet
// (K = 5, Rate 1/2), punktiert, verschachtelt und mit CRC gesichert; die Sprache ist AMBE+2 (Halbrate) wie bei DMR.

public enum NXDN {
    public static let frameSymbols = 192
    public static let syncSymbols = 10
    public static let payloadSymbols = 182
    /// Synchronwort 0xCDF59 als Pegel
    public static let fsw: [Float] = [-3, 1, -3, 3, -3, -3, 3, 3, -1, 3]
    /// Beginn der Kanäle im verwürfelten Teil (Dibit-Index ab LICH): LICH 0 … 7, SACCH 8 … 37, Nutzdaten 38 … 181
    public static let sacchStart = 8
    public static let dataStart = 38

    /// Verwürfelungsfolge PN95 (182 Werte); `true` kehrt das Vorzeichen des Symbols um
    public static let pn: [Bool] = {
        var lfsr: UInt16 = 0xE4
        var out: [Bool] = []
        for _ in 0..<payloadSymbols {
            out.append(lfsr & 1 == 1)
            let bit = ((lfsr >> 4) ^ lfsr) & 1
            lfsr >>= 1
            lfsr |= bit << 8
        }
        return out
    }()

    /// Verwürfeln und Entwürfeln sind dasselbe: Vorzeichen der Symbole mit PN = 1 umkehren
    public static func scramble(_ levels: [Float]) -> [Float] {
        var out = levels
        for i in 0..<min(levels.count, payloadSymbols) where pn[i] { out[i] = -out[i] }
        return out
    }

    public static func callTypeName(_ type: Int) -> String {
        switch type {
        case 0: return "Rundruf"
        case 1: return "Gruppe"
        case 4: return "Einzelruf"
        case 5: return "Interconnect"
        case 6: return "Kurzwahl"
        default: return "Typ \(type)"
        }
    }

    public static func cipherName(_ type: Int) -> String {
        switch type {
        case 1: return "Scrambler"
        case 2: return "DES"
        case 3: return "AES"
        default: return "offen"
        }
    }

    /// Sprachverfahren aus den Optionsbits des Rufs: Übertragungsrate und Codec
    public static func transmissionName(option: Int) -> String {
        switch option & 7 {
        case 0: return "4800 bit/s EHR"
        case 2: return "9600 bit/s EHR"
        case 3: return "9600 bit/s EFR"
        default: return "Option \(option & 7)"
        }
    }
}

// MARK: - LICH

/// Link Information Channel: 7 Bit (Funkkanal 2, Funktionskanal 2, Option 2, Richtung 1) und ein Paritätsbit
public struct NXDNLICH: Equatable, Sendable {
    public var value: Int
    public var parityOK: Bool

    /// Aus den ersten acht Symbolen (bereits entwürfelt): je Symbol das obere Bit
    public static func decode(_ levels: ArraySlice<Float>) -> NXDNLICH {
        var full = 0
        for v in levels.prefix(8) { full = (full << 1) | (v < 0 ? 1 : 0) }
        let parity = (full >> 7) + (full >> 6) + (full >> 5) + (full >> 4)
        return NXDNLICH(value: full >> 1, parityOK: (parity & 1) == (full & 1))
    }

    /// Wert + Parität als 8 Bit (für Prüfstände)
    public var encoded: Int {
        let full7 = value & 0x7F
        let parity = ((full7 >> 6) + (full7 >> 5) + (full7 >> 4) + (full7 >> 3)) & 1
        return (full7 << 1) | parity
    }

    /// Typ D (Icom IDAS): LICH-Werte 0x60 … 0x7F, der Steuerkanal SCCH statt SACCH
    public var typeD: Bool { value >= 0x60 && value <= 0x7F }

    /// Bitmaske der Sprachhälften: 1 = Rahmen 0 und 1 tragen Sprache, 2 = Rahmen 2 und 3
    public var voice: Int {
        switch value {
        case 0x32, 0x33, 0x52, 0x53, 0x72, 0x73: return 2
        case 0x34, 0x35, 0x54, 0x55, 0x75: return 1
        case 0x36, 0x37, 0x56, 0x57, 0x76, 0x77: return 3
        default: return 0
        }
    }

    /// Bitmaske der FACCH1: 1 = Block A (Symbole 38 … 109), 2 = Block B (110 … 181)
    public var facch1: Int {
        switch value {
        case 0x20, 0x21, 0x30, 0x31, 0x40, 0x41, 0x50, 0x51, 0x60, 0x61, 0x70, 0x71: return 3
        case 0x32, 0x33, 0x52, 0x53, 0x72, 0x73, 0x62, 0x63: return 1
        case 0x34, 0x35, 0x54, 0x55, 0x75: return 2
        default: return 0
        }
    }

    /// SACCH im Überrahmen (vier Teile zu 18 Bit ergeben eine Nachricht)
    public var sacchSuperframe: Bool {
        switch value {
        case 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57: return true
        default: return false
        }
    }

    /// Ein LICH-Wert, den der Empfänger auswertet (Sprache oder Signalisierung im Rufkanal)
    public var supported: Bool { voice != 0 || facch1 != 0 || sacchSuperframe }

    /// Richtung: 1 = abwärts (Relais → Gerät); beim Direktbetrieb 0
    public var outbound: Bool { value & 1 == 1 }
}

// MARK: - Kanalcodierung

public enum NXDNCodes {
    public static let sacchPuncture: [Bool] = [1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 0].map { $0 == 1 }
    public static let facchPuncture: [Bool] = [1, 0, 1, 1].map { $0 == 1 }
    /// Verschachtelung SACCH (60 Bit): 5 Zeilen × 12 Spalten, spaltenweise gesendet
    public static let sacchPermutation: [Int] = (0..<60).map { ($0 % 5) * 12 + $0 / 5 }
    /// Verschachtelung FACCH1 (144 Bit): 16 × 9
    public static let facchPermutation: [Int] = (0..<144).map { ($0 / 9) + 16 * ($0 % 9) }

    /// CRC-6 (x⁶ + x⁵ + x² + x + 1 in der Form des Standards, Anfangswert 1) über Bits
    public static func crc6(_ bits: ArraySlice<UInt8>) -> Int {
        var s = [UInt8](repeating: 1, count: 6)
        for b in bits {
            let a = (b & 1) ^ s[0]
            s = [a ^ s[1], s[2], s[3], a ^ s[4], a ^ s[5], a]
        }
        return s.reduce(0) { ($0 << 1) | Int($1) }
    }

    /// CRC-12 des FACCH1 (Anfangswert alle Einsen)
    public static func crc12(_ bits: ArraySlice<UInt8>) -> Int {
        var s = [UInt8](repeating: 1, count: 12)
        for b in bits {
            let a = (b & 1) ^ s[0]
            s = [a ^ s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], a ^ s[9], a ^ s[10], a ^ s[11], a]
        }
        return s.reduce(0) { ($0 << 1) | Int($1) }
    }

    static func value(_ bits: ArraySlice<UInt8>) -> Int { bits.reduce(0) { ($0 << 1) | Int($1 & 1) } }

    /// Weiche Werte (positiv = 1) eines Blocks → Informationsbits einschließlich Prüfsumme und Nachlauf
    static func decodeBlock(soft: [Float], permutation: [Int], puncture: [Bool], steps: Int) -> [UInt8] {
        var de = [Float](repeating: 0, count: soft.count)
        for i in 0..<soft.count { de[permutation[i]] = soft[i] }
        var coded: [Float] = []
        coded.reserveCapacity(steps * 2)
        var k = 0
        for j in 0..<(steps * 2) {
            if puncture[j % puncture.count] {
                coded.append(k < de.count ? de[k] : 0)
                k += 1
            } else {
                coded.append(0)
            }
        }
        return ConvK5.decode(soft: coded)
    }

    /// Informationsbits (mit Prüfsumme, ohne Nachlauf) → gesendete Bits
    static func encodeBlock(info: [UInt8], permutation: [Int], puncture: [Bool]) -> [UInt8] {
        let coded = ConvK5.encode(info + [0, 0, 0, 0])
        var kept: [UInt8] = []
        for (j, bit) in coded.enumerated() where puncture[j % puncture.count] { kept.append(bit) }
        precondition(kept.count == permutation.count)
        return (0..<kept.count).map { kept[permutation[$0]] }
    }

    public struct SACCH: Equatable, Sendable {
        /// 2 Bit Aufbau (3 = erster Teil … 0 = letzter), 6 Bit Funkzugangsnummer, 18 Bit Nutzdaten
        public var structure: Int
        public var ran: Int
        public var payload: [UInt8]
        public var crcOK: Bool
    }

    /// 30 Symbole (entwürfelt) → SACCH-Teil
    public static func decodeSACCH(_ levels: ArraySlice<Float>) -> SACCH {
        let soft = softBits(levels)
        let b = decodeBlock(soft: soft, permutation: sacchPermutation, puncture: sacchPuncture, steps: 36)
        return SACCH(structure: value(b[0..<2]), ran: value(b[2..<8]), payload: Array(b[8..<26]), crcOK: crc6(b[0..<26]) == value(b[26..<32]))
    }

    public static func encodeSACCH(structure: Int, ran: Int, payload: [UInt8]) -> [UInt8] {
        precondition(payload.count == 18)
        var info: [UInt8] = bits(structure, 2) + bits(ran, 6) + payload
        info += bits(crc6(info[0..<26]), 6)
        return encodeBlock(info: info, permutation: sacchPermutation, puncture: sacchPuncture)
    }

    /// 72 Symbole (entwürfelt) → 80 Nachrichtenbits und CRC-Ergebnis
    public static func decodeFACCH1(_ levels: ArraySlice<Float>) -> (bits: [UInt8], crcOK: Bool) {
        let soft = softBits(levels)
        let b = decodeBlock(soft: soft, permutation: facchPermutation, puncture: facchPuncture, steps: 96)
        return (Array(b[0..<80]), crc12(b[0..<80]) == value(b[80..<92]))
    }

    public static func encodeFACCH1(message: [UInt8]) -> [UInt8] {
        precondition(message.count == 80)
        let info = message + bits(crc12(message[0..<80]), 12)
        return encodeBlock(info: info, permutation: facchPermutation, puncture: facchPuncture)
    }

    static func softBits(_ levels: ArraySlice<Float>) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(levels.count * 2)
        for v in levels { let s = FourFSKBits.soft(v); out.append(s.0); out.append(s.1) }
        return out
    }

    static func bits(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (n - 1 - $0)) & 1) } }
}

// MARK: - Nachrichten

/// Rufnachricht (VCALL u. a.) aus 64 und mehr Bits: 2 Bit Kennzeichen, 6 Bit Typ, 8 Bit Optionen, 3 Bit Ruftyp, 5 Bit Rufoption,
/// 16 Bit Quelle, 16 Bit Ziel, 2 Bit Chiffre, 6 Bit Schlüsselnummer
public struct NXDNMessage: Equatable, Sendable {
    public var type: Int
    public var callType: Int
    public var option: Int
    public var source: Int
    public var destination: Int
    public var cipher: Int
    public var keyID: Int

    public static let vcall = 0x01
    public static let txRelEx = 0x07
    public static let txRel = 0x08
    public static let disc = 0x11

    public var startsCall: Bool { type == Self.vcall }
    public var endsCall: Bool { type == Self.txRel || type == Self.txRelEx || type == Self.disc }

    public static func parse(_ bits: [UInt8]) -> NXDNMessage? {
        guard bits.count >= 64 else { return nil }
        func v(_ from: Int, _ n: Int) -> Int { NXDNCodes.value(bits[from..<(from + n)]) }
        return NXDNMessage(type: v(2, 6), callType: v(16, 3), option: v(19, 5), source: v(24, 16), destination: v(40, 16), cipher: v(56, 2), keyID: v(58, 6))
    }

    /// 64 Bit für Prüfstände
    public func encoded() -> [UInt8] {
        NXDNCodes.bits(0, 2) + NXDNCodes.bits(type, 6) + NXDNCodes.bits(0, 8) + NXDNCodes.bits(callType, 3) + NXDNCodes.bits(option, 5)
            + NXDNCodes.bits(source, 16) + NXDNCodes.bits(destination, 16) + NXDNCodes.bits(cipher, 2) + NXDNCodes.bits(keyID, 6)
    }
}

// MARK: - Diagnose

public enum NXDNDiagnosis {
    public enum Severity: Int, Sendable { case ok, waiting, problem }

    public struct Result: Equatable, Sendable {
        public var severity: Severity
        public var title: String
        public var advice: String
    }

    public static let silenceDB = -70.0

    public static func assess(inputDB: Double, stats: NXDNFramerStats, locked: Bool) -> Result {
        if inputDB < silenceDB {
            return Result(severity: .problem, title: "Kein Audio", advice: "Am Eingang kommt kein Signal an. NXDN braucht das unbearbeitete FM-Diskriminator-Audio (Packet/Daten-Ausgang des Funkgeräts oder SDR-Programm mit FM-Audio ohne Entzerrung und ohne Hochpass).")
        }
        if locked {
            if stats.voiceFrames > 20, Double(stats.cleanFrames) / Double(stats.voiceFrames) < 0.2 {
                return Result(severity: .waiting, title: "Signal schwach oder verrauscht", advice: "Die Sprachrahmen haben viele Bitfehler (der Sprachdecoder glättet das, es kann aber rauschen oder knacken). Ein stärkeres Signal oder genaueres Abstimmen hilft.")
            }
            return Result(severity: .ok, title: "NXDN-Signal wird empfangen", advice: "")
        }
        if stats.calls > 0 { return Result(severity: .ok, title: "Warten auf die nächste Aussendung", advice: "") }
        return Result(severity: .waiting, title: "Warten auf NXDN", advice: "Noch keine NXDN-Synchronisation. Das Audio muss die 4FSK-Daten mit 2400 oder 4800 Symbolen/s unverfälscht enthalten (nicht das fertig demodulierte Sprach-Audio). NXDN48 braucht einen schmalen Filter (6,25 kHz), NXDN96 12,5 kHz.")
    }
}
