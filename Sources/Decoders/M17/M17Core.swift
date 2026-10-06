// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// M17: offenes digitales Sprach- und Datenverfahren für den Amateurfunk (M17 Project, Spezifikation 2.0/3.0), 4FSK mit 4800 Symbolen/s.
// Ein Rahmen dauert 40 ms: 8 Symbole Synchronwort + 184 Symbole (368 Bit) Nutzlast.
//
//   Sendeweg:  Bits → (Faltungscode K = 5, punktiert) → QPP-Verschachtelung π(x) = (45x + 92x²) mod 368 → Zufallsmaske → 4FSK
//   LSF-Rahmen  (Synchronwort 0x55F7): 240 Bit „Link Setup Frame“ (Ziel, Quelle, Typ, Meta, CRC) + 4 Nachlaufbits, Muster P1 (488 → 368 Bit)
//   Strom-Rahmen (Synchronwort 0xFF5D): 96 Bit LICH (vier Golay-Blöcke mit einem Fünftel des LSF und dem Zähler 0 … 5), danach
//              1 Bit Ende + 15 Bit Rahmennummer + 128 Bit Nutzlast, K = 5, Muster P2 (296 → 272 Bit)
//
// Quellen: M17-Spezifikation (m17project.org), Tabellen und Reihenfolgen am Verhalten von libM17 / dsd-fme geprüft (siehe THIRD_PARTY.md).

public enum M17 {
    public static let baud = 4800.0
    public static let syncSymbols = 8
    public static let frameSymbols = 192
    public static let payloadSymbols = 184
    public static let payloadBits = 368
    /// Zeit je Rahmen in Sekunden
    public static let frameSeconds = 0.04

    // MARK: Synchronwörter

    public enum SyncKind: Int, CaseIterable, Sendable {
        case lsf, stream, packet, bert, eot

        public var word: UInt16 {
            switch self {
            case .lsf: return 0x55F7
            case .stream: return 0xFF5D
            case .packet: return 0x75FF
            case .bert: return 0xDF55
            case .eot: return 0x555D
            }
        }

        public var levels: [Float] { M17.levels(ofWord: word) }
    }

    /// Acht Symbole zu einem 16-Bit-Wort (höchstes Bit-Paar zuerst, Dibit-Zuordnung wie bei allen 4FSK-Verfahren: 01 = +3 … 11 = −3)
    public static func levels(ofWord word: UInt16) -> [Float] {
        (0..<8).map { FourFSK.level(ofDibit: UInt8((word >> UInt16(14 - 2 * $0)) & 3)) }
    }

    /// Normierte Korrelation (−1 … +1) von acht Symbolen mit einem Muster
    static func correlation(_ window: ArraySlice<Float>, _ pattern: [Float]) -> Float {
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

    // MARK: Tabellen

    /// Zufallsmaske (368 Bit; 46 Byte, höchstes Bit zuerst)
    static let randomizer: [UInt8] = {
        let bytes: [UInt8] = [
            0xD6, 0xB5, 0xE2, 0x30, 0x82, 0xFF, 0x84, 0x62, 0xBA, 0x4E, 0x96, 0x90, 0xD8, 0x98, 0xDD, 0x5D, 0x0C, 0xC8, 0x52, 0x43, 0x91, 0x1D, 0xF8,
            0x6E, 0x68, 0x2F, 0x35, 0xDA, 0x14, 0xEA, 0xCD, 0x76, 0x19, 0x8D, 0xD5, 0x80, 0xD1, 0x33, 0x87, 0x13, 0x57, 0x18, 0x2D, 0x29, 0x78, 0xC3,
        ]
        return bytes.flatMap { b in (0..<8).map { UInt8((b >> UInt8(7 - $0)) & 1) } }
    }()

    /// QPP-Verschachtelung: Bit i der Nutzlast liegt auf der Leitung an Stelle π(i)
    static let permutation: [Int] = (0..<368).map { (45 * $0 + 92 * $0 * $0) % 368 }

    /// P1 (LSF): 61 Einträge, Periode „1101 1101“ (Faltungscode 488 → 368 Bit)
    static let puncture1: [Bool] = (0..<61).map { [true, true, false, true, true, true, false, true][$0 % 8] }
    /// P2 (Strom): 12 Einträge, nur der letzte fehlt (296 → 272 Bit)
    static let puncture2: [Bool] = (0..<12).map { $0 != 11 }

    static func puncture(_ bits: [UInt8], pattern: [Bool]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bits.count)
        for (i, b) in bits.enumerated() where pattern[i % pattern.count] { out.append(b) }
        return out
    }

    /// Fehlende (punktierte) Stellen mit Wert 0 (= unbekannt) auffüllen
    static func depuncture(_ soft: ArraySlice<Float>, pattern: [Bool], length: Int) -> [Float] {
        var out = [Float](repeating: 0, count: length)
        var k = soft.startIndex
        for u in 0..<length where pattern[u % pattern.count] {
            if k < soft.endIndex { out[u] = soft[k]; k += 1 }
        }
        return out
    }

    // MARK: Rufzeichen und Adressen

    static let alphabet: [Character] = Array(" ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-/.")
    public static let broadcast: UInt64 = 0xFFFF_FFFF_FFFF
    /// Ab hier (bis auf Rundruf) reserviert: 40⁹
    public static let firstReserved: UInt64 = 0xEE6B_2800_0000

    /// Ende des Hash-Bereichs („#“ + Rufzeichen): 40⁹ + 40⁸
    public static let hashEnd: UInt64 = firstReserved + 6_553_600_000_000

    /// Adresse → Rufzeichen (das erste Zeichen steht in der niedrigsten Stelle zur Basis 40); Hash-Adressen mit „#“ davor,
    /// der Rundruf als „@ALL“; `nil` für reservierte Adressen
    public static func callsign(from address: UInt64) -> String? {
        var value = address
        var prefix = ""
        if address == broadcast { return "@ALL" }
        if address >= firstReserved {
            guard address < hashEnd else { return nil }
            value -= firstReserved
            prefix = "#"
        }
        guard value > 0 else { return prefix.isEmpty ? nil : prefix }
        var s = prefix
        while value > 0 { s.append(alphabet[Int(value % 40)]); value /= 40 }
        return s
    }

    /// Rufzeichen (bis zu 9 Zeichen A–Z, 0–9, „-“, „/“, „.“; Kleinbuchstaben gelten als große; „#…“ im Hash-Bereich; „@ALL“ = Rundruf) → Adresse
    public static func address(fromCallsign text: String) -> UInt64? {
        let upper = text.uppercased()
        if upper == "@ALL" { return broadcast }
        var chars = Array(upper)
        var offset: UInt64 = 0
        if chars.first == "#" { chars.removeFirst(); offset = firstReserved }
        guard !chars.isEmpty, chars.count <= 9 else { return nil }
        var value: UInt64 = 0
        for c in chars.reversed() {
            guard let i = alphabet.firstIndex(of: c) else { return nil }
            value = value * 40 + UInt64(i)
        }
        return value + offset
    }

    /// Anzeigetext einer Adresse (Rundruf, unbekannt, reserviert)
    public static func name(ofAddress a: UInt64, isSource: Bool = false) -> String {
        if a == broadcast && isSource { return "?" }
        return callsign(from: a) ?? String(format: "%012llX", a)
    }

    // MARK: CRC

    /// CRC-16 mit Polynom 0x5935, Startwert 0xFFFF, ohne Spiegelung (über die 28 Byte des LSF; über alle 30 Byte ergibt sich 0)
    public static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt32 = 0xFFFF
        for b in bytes {
            crc ^= UInt32(b) << 8
            for _ in 0..<8 {
                crc <<= 1
                if crc & 0x10000 != 0 { crc = (crc ^ 0x5935) & 0xFFFF }
            }
        }
        return UInt16(crc & 0xFFFF)
    }

    // MARK: Bits

    static func bits(ofBytes bytes: [UInt8]) -> [UInt8] { bytes.flatMap { b in (0..<8).map { UInt8((b >> UInt8(7 - $0)) & 1) } } }

    static func bytes(ofBits bits: ArraySlice<UInt8>) -> [UInt8] {
        let a = Array(bits)
        return stride(from: 0, to: a.count - a.count % 8, by: 8).map { i in (0..<8).reduce(UInt8(0)) { ($0 << 1) | (a[i + $1] & 1) } }
    }

    static func value(ofBits bits: ArraySlice<UInt8>) -> Int { bits.reduce(0) { ($0 << 1) | Int($1 & 1) } }

    // MARK: Schichtung der Leitungsbits

    /// Symbole → weiche Bits (positiv = 1), davon Zufallsmaske entfernt und entschachtelt: Bit i der Nutzlast
    static func deliver(_ symbols: ArraySlice<Float>) -> [Float] {
        var soft = [Float]()
        soft.reserveCapacity(368)
        for s in symbols {
            let (a, b) = FourFSKBits.soft(s)
            soft.append(a); soft.append(b)
        }
        guard soft.count == payloadBits else { return [] }
        var out = [Float](repeating: 0, count: payloadBits)
        for i in 0..<payloadBits {
            let p = permutation[i]
            out[i] = randomizer[p] == 1 ? -soft[p] : soft[p]
        }
        return out
    }

    /// Nutzlast-Bits → Symbole (verschachteln, maskieren, je zwei Bit ein Symbol)
    static func symbols(ofPayloadBits bits: [UInt8]) -> [Float] {
        precondition(bits.count == payloadBits)
        var wire = [UInt8](repeating: 0, count: payloadBits)
        for i in 0..<payloadBits { wire[permutation[i]] = bits[i] }
        for j in 0..<payloadBits { wire[j] ^= randomizer[j] }
        return stride(from: 0, to: payloadBits, by: 2).map { FourFSK.level(ofDibit: (wire[$0] << 1) | wire[$0 + 1]) }
    }

    /// Faltungscode: Viterbi über weiche Werte; liefert die Daten (ohne die vier Nachlaufbits) und den Anteil gestörter Bits
    static func viterbi(_ soft: ArraySlice<Float>, pattern: [Bool], coded: Int) -> (bits: [UInt8], errorRate: Float) {
        let full = depuncture(soft, pattern: pattern, length: coded)
        let decoded = ConvK5.decode(soft: full)
        let again = ConvK5.encode(decoded)
        var wrong = 0, known = 0
        for i in 0..<min(again.count, full.count) where full[i] != 0 {
            known += 1
            if (full[i] > 0) != (again[i] == 1) { wrong += 1 }
        }
        return (Array(decoded.dropLast(4)), known > 0 ? Float(wrong) / Float(known) : 1)
    }
}

// MARK: - LSF

/// Link Setup Frame: wer spricht mit wem, wie, mit welchen Zusatzdaten
public struct M17LSF: Equatable, Sendable {
    public var destination: UInt64
    public var source: UInt64
    public var type: UInt16
    /// 14 Byte: Zusatzdaten (Text, Position, erweitertes Rufzeichen) oder bei AES der Initialisierungsvektor
    public var meta: [UInt8]

    public init(destination: UInt64, source: UInt64, type: UInt16, meta: [UInt8] = [UInt8](repeating: 0, count: 14)) {
        self.destination = destination
        self.source = source
        self.type = type
        self.meta = meta
    }

    public enum Payload: Sendable { case reserved, data, voice3200, voice1600, packet }

    /// Typfeld nach Fassung 3.0 (obere vier Bit ungleich 0) oder 2.0
    public var isVersion3: Bool { type >> 12 != 0 }

    public var payload: Payload {
        if isVersion3 {
            switch type >> 12 {
            case 1: return .data
            case 2: return .voice3200
            case 3: return .voice1600
            case 0xF: return .packet
            default: return .reserved
            }
        }
        if type & 1 == 0 { return .packet }
        switch (type >> 1) & 3 {
        case 1: return .data
        case 2: return .voice3200
        case 3: return .voice1600
        default: return .reserved
        }
    }

    public var isVoice: Bool { payload == .voice3200 || payload == .voice1600 }

    /// Kanalzugriffsnummer 0 … 15 (trennt Gespräche auf derselben Frequenz)
    public var channelAccessNumber: Int { isVersion3 ? Int(type & 0xF) : Int((type >> 7) & 0xF) }

    public var isSigned: Bool { isVersion3 ? (type >> 8) & 1 == 1 : (type >> 11) & 1 == 1 }

    /// 0 = keine, sonst Art der Verschlüsselung
    public var encryption: Int { isVersion3 ? Int((type >> 9) & 7) : Int((type >> 3) & 3) }

    public var isEncrypted: Bool { encryption != 0 }

    public var encryptionText: String {
        if isVersion3 {
            switch encryption {
            case 1: return "Scrambler 8 Bit"
            case 2: return "Scrambler 16 Bit"
            case 3: return "Scrambler 24 Bit"
            case 4: return "AES 128"
            case 5: return "AES 192"
            case 6: return "AES 256"
            case 7: return "reserviert"
            default: return ""
            }
        }
        switch encryption {
        case 1: return "Scrambler"
        case 2: return "AES"
        case 3: return "reserviert"
        default: return ""
        }
    }

    public var payloadText: String {
        switch payload {
        case .voice3200: return "Sprache 3200"
        case .voice1600: return "Sprache 1600 + Daten"
        case .data: return "Daten"
        case .packet: return "Paket"
        case .reserved: return "reserviert"
        }
    }

    public var destinationName: String { M17.name(ofAddress: destination) }
    public var sourceName: String { M17.name(ofAddress: source, isSource: true) }

    // MARK: Meta

    public enum Meta: Equatable, Sendable {
        case none
        /// Textabschnitt: Nummer (ab 1), Gesamtzahl, Text (13 Byte)
        case text(segment: Int, total: Int, text: String)
        case position(latitude: Double, longitude: Double, altitude: Double?, speed: Double?, bearing: Int?, station: String)
        case extendedCallsign(first: String, second: String?)
        case unknown
    }

    public var content: Meta {
        guard meta.contains(where: { $0 != 0 }) else { return .none }
        let kind: Int
        if isVersion3 {
            kind = Int((type >> 4) & 0xF)
            if kind == 0 || kind == 0xF { return .none }       // keine Zusatzdaten oder Initialisierungsvektor
        } else {
            guard encryption == 0 else { return .none }
            kind = [3, 1, 2, 0][Int((type >> 5) & 3)]          // Unterart 0 Text, 1 Position, 2 erweitertes Rufzeichen
        }
        switch kind {
        case 1: return position()
        case 2: return extendedCallsign()
        case 3: return textSegment(version3: isVersion3)
        default: return .unknown
        }
    }

    private func textSegment(version3: Bool) -> Meta {
        let control = meta[0]
        var total = Int(control >> 4), number = Int(control & 0xF)
        if !version3 {
            // Fassung 2.0: Bitmuster 1, 3, 7, 15 (Gesamtzahl) und 1, 2, 4, 8 (dieser Abschnitt)
            total = [0x1: 1, 0x3: 2, 0x7: 3, 0xF: 4][control >> 4] ?? 1
            number = [0x1: 1, 0x2: 2, 0x4: 3, 0x8: 4][control & 0xF] ?? 1
        }
        guard number >= 1, total >= 1, number <= total else { return .unknown }
        let raw = Array(meta[1...13].prefix(while: { $0 != 0 }))
        return .text(segment: number, total: total, text: String(decoding: raw, as: UTF8.self))
    }

    private func position() -> Meta {
        func signed24(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Int {
            let v = (Int(a) << 16) | (Int(b) << 8) | Int(c)
            return v >= 0x800000 ? v - 0x1000000 : v
        }
        let validity = meta[1] >> 4
        guard validity & 0x8 != 0 else { return .unknown }
        let latitude = Double(signed24(meta[3], meta[4], meta[5])) * 90 / 8_388_607
        let longitude = Double(signed24(meta[6], meta[7], meta[8])) * 180 / 8_388_607
        let altitude = validity & 0x4 != 0 ? Double((Int(meta[9]) << 8) | Int(meta[10])) * 0.5 - 500 : nil
        let speed = validity & 0x2 != 0 ? Double((Int(meta[11]) << 4) | Int(meta[12] >> 4)) * 0.5 : nil
        let bearing = validity & 0x2 != 0 ? Int(meta[1] & 1) << 8 | Int(meta[2]) : nil
        let stations = ["fest", "mobil", "Handfunkgerät"]
        let station = Int(meta[0] & 0xF) < stations.count ? stations[Int(meta[0] & 0xF)] : "?"
        return .position(latitude: latitude, longitude: longitude, altitude: altitude, speed: speed, bearing: bearing, station: station)
    }

    private func extendedCallsign() -> Meta {
        func address(_ b: ArraySlice<UInt8>) -> UInt64 { b.reduce(0) { ($0 << 8) | UInt64($1) } }
        guard let first = M17.callsign(from: address(meta[0..<6])) else { return .unknown }
        return .extendedCallsign(first: first, second: M17.callsign(from: address(meta[6..<12])))
    }

    // MARK: Bytes

    /// 30 Byte: Ziel, Quelle, Typ, Meta und CRC
    public var bytes: [UInt8] {
        var b: [UInt8] = []
        for shift in stride(from: 40, through: 0, by: -8) { b.append(UInt8((destination >> UInt64(shift)) & 0xFF)) }
        for shift in stride(from: 40, through: 0, by: -8) { b.append(UInt8((source >> UInt64(shift)) & 0xFF)) }
        b.append(UInt8(type >> 8)); b.append(UInt8(type & 0xFF))
        b += meta.prefix(14) + [UInt8](repeating: 0, count: max(0, 14 - meta.count))
        let crc = M17.crc16(b)
        b.append(UInt8(crc >> 8)); b.append(UInt8(crc & 0xFF))
        return b
    }

    /// Aus 30 Byte, wenn die CRC stimmt
    public init?(bytes b: [UInt8]) {
        guard b.count == 30, M17.crc16(Array(b[0..<28])) == (UInt16(b[28]) << 8 | UInt16(b[29])) else { return nil }
        destination = b[0..<6].reduce(0) { ($0 << 8) | UInt64($1) }
        source = b[6..<12].reduce(0) { ($0 << 8) | UInt64($1) }
        type = UInt16(b[12]) << 8 | UInt16(b[13])
        meta = Array(b[14..<28])
    }

    /// Typfeld nach Fassung 3.0
    public static func type3(payload: Int, encryption: Int = 0, signed: Bool = false, meta: Int = 0, can: Int = 0) -> UInt16 {
        UInt16(payload & 0xF) << 12 | UInt16(encryption & 7) << 9 | (signed ? 1 << 8 : 0) | UInt16(meta & 0xF) << 4 | UInt16(can & 0xF)
    }

    /// Typfeld nach Fassung 2.0 (Strom; `dataType` 1 Daten, 2 Sprache 3200, 3 Sprache 1600)
    public static func type2(dataType: Int, encryption: Int = 0, subtype: Int = 0, can: Int = 0) -> UInt16 {
        1 | UInt16(dataType & 3) << 1 | UInt16(encryption & 3) << 3 | UInt16(subtype & 3) << 5 | UInt16(can & 0xF) << 7
    }
}

// MARK: - Rahmen

public struct M17StreamFrame: Equatable, Sendable {
    /// Ein Fünftel des LSF (5 Byte) und dessen Nummer 0 … 5
    public var lichChunk: [UInt8]
    public var lichCounter: Int
    /// Korrigierte Bitfehler in den vier Golay-Blöcken
    public var lichErrors: Int
    public var isLast: Bool
    public var frameNumber: Int
    /// 16 Byte: zwei Sprachrahmen Codec2 3200, oder Codec2 1600 + 8 Byte Daten
    public var payload: [UInt8]
    /// Anteil der Bits, in denen das Empfangene vom neu berechneten Code abweicht (0 … 0,5)
    public var errorRate: Float

    public init(lichChunk: [UInt8], lichCounter: Int, lichErrors: Int = 0, isLast: Bool, frameNumber: Int, payload: [UInt8], errorRate: Float = 0) {
        self.lichChunk = lichChunk
        self.lichCounter = lichCounter
        self.lichErrors = lichErrors
        self.isLast = isLast
        self.frameNumber = frameNumber
        self.payload = payload
        self.errorRate = errorRate
    }
}

extension M17 {
    /// Strom-Rahmen aus den 184 Symbolen hinter dem Synchronwort; `nil`, wenn der LICH-Zähler unmöglich ist
    public static func decodeStreamFrame(_ symbols: ArraySlice<Float>) -> M17StreamFrame? {
        let soft = deliver(symbols)
        guard soft.count == payloadBits else { return nil }
        var lich: [UInt8] = []
        var errors = 0
        for block in 0..<4 {
            let hard = (0..<24).map { soft[block * 24 + $0] > 0 ? UInt8(1) : 0 }
            let r = Golay.decode24(hard[...])
            lich += r.data
            errors += r.corrected
        }
        let counter = value(ofBits: lich[40..<43])
        guard counter <= 5 else { return nil }
        let decoded = viterbi(soft[96..<368], pattern: puncture2, coded: 296)
        guard decoded.bits.count == 144 else { return nil }
        return M17StreamFrame(lichChunk: bytes(ofBits: lich[0..<40]), lichCounter: counter, lichErrors: errors, isLast: decoded.bits[0] == 1,
                              frameNumber: value(ofBits: decoded.bits[1..<16]), payload: bytes(ofBits: decoded.bits[16..<144]), errorRate: decoded.errorRate)
    }

    /// LSF-Rahmen; `nil`, wenn die CRC nicht stimmt
    public static func decodeLSFFrame(_ symbols: ArraySlice<Float>) -> (lsf: M17LSF, errorRate: Float)? {
        let soft = deliver(symbols)
        guard soft.count == payloadBits else { return nil }
        let decoded = viterbi(soft[0..<368], pattern: puncture1, coded: 488)
        guard decoded.bits.count == 240, let lsf = M17LSF(bytes: bytes(ofBits: decoded.bits[...])) else { return nil }
        return (lsf, decoded.errorRate)
    }

    // MARK: Senden (Prüfstände)

    /// Symbole eines Synchronworts
    public static func syncSymbols(_ kind: SyncKind) -> [Float] { kind.levels }

    public static func lsfFrameSymbols(_ lsf: M17LSF) -> [Float] {
        let coded = ConvK5.encode(bits(ofBytes: lsf.bytes) + [0, 0, 0, 0])
        return SyncKind.lsf.levels + symbols(ofPayloadBits: puncture(coded, pattern: puncture1))
    }

    public static func streamFrameSymbols(lichChunk: [UInt8], counter: Int, last: Bool, frameNumber: Int, payload: [UInt8]) -> [Float] {
        precondition(lichChunk.count == 5 && payload.count == 16 && (0...5).contains(counter))
        var lichBits = bits(ofBytes: lichChunk) + (0..<3).map { UInt8((counter >> (2 - $0)) & 1) } + [UInt8](repeating: 0, count: 5)
        lichBits = (0..<4).flatMap { Golay.encode24(Array(lichBits[($0 * 12)..<($0 * 12 + 12)])) }
        let head: [UInt8] = [last ? 1 : 0] + (0..<15).map { UInt8((frameNumber >> (14 - $0)) & 1) }
        let coded = ConvK5.encode(head + bits(ofBytes: payload) + [0, 0, 0, 0])
        return SyncKind.stream.levels + symbols(ofPayloadBits: lichBits + puncture(coded, pattern: puncture2))
    }

    /// Vorspann: 40 ms abwechselnd +3 und −3 (Synchronwort 0x7777)
    public static func preambleSymbols() -> [Float] { (0..<frameSymbols).map { $0 % 2 == 0 ? 3 : -3 } }

    /// Ende: 40 ms Synchronwort 0x555D
    public static func endSymbols() -> [Float] { (0..<24).flatMap { _ in SyncKind.eot.levels } }
}
