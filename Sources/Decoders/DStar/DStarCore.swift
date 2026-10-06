// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// D-Star (JARL), Betriebsart DV: Rahmenschicht.
//
// Ablauf einer Aussendung: Bitsynchronisation (alternierende Bits) → Rahmensynchronisation (15 Bit) → Kopf (660 Bit:
// 41 Byte, Faltungscode Rate 1/2, verschachtelt, verwürfelt) → Sprachrahmen zu 96 Bit (72 Bit AMBE-Kanalbits + 24 Bit
// Langsamdaten), alle 21 Rahmen ein Synchronrahmen → Ende-Muster.
// Jedes Byte geht mit dem niederwertigen Bit zuerst auf die Leitung (so passt das Synchronmuster 0x55 0x2D 0x16).
// Quellen: Beschreibung des Verfahrens (JARL-Spezifikation, Vorträge und Quelltexte der Amateurfunk-Gemeinde),
// Gegenprobe der Bitfolgen und Tabellen gegen dsd-fme (nur gelesen, nichts übernommen). Siehe THIRD_PARTY.md.

// MARK: - Konstanten

public enum DStarConstants {
    public static let baud = 4800.0
    /// Hub ±1,2 kHz, Gauß-Filter BT 0,5
    public static let bt = 0.5

    public static let headerBits = 660
    public static let headerBytes = 41
    public static let voiceFrameBits = 96
    public static let ambeBits = 72
    public static let slowDataBits = 24
    /// Rahmen je Überrahmen (der erste ist der Synchronrahmen)
    public static let framesPerSuperframe = 21

    /// Bitsynchronisation: alternierend, dann Rahmensynchronisation (15 Bit), in der Reihenfolge der Leitung.
    public static let frameSync15: [UInt8] = [1, 1, 1, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0, 0]
    /// Kopfsynchronisation, die der Empfänger sucht: letzte 8 Bit der Bitsynchronisation, ein weiteres Bit und die 15 Bit.
    public static let headerSync24: [UInt8] = [0, 1, 0, 1, 0, 1, 0, 1, 0] + frameSync15
    /// Synchronmuster der Langsamdaten im Synchronrahmen: Bytes 0x55 0x2D 0x16, niederwertiges Bit zuerst.
    public static let voiceSync24: [UInt8] = DStarBits.bits(fromBytes: [0x55, 0x2D, 0x16])
    /// Ende der Aussendung: 0x55 0x55 0x55 0x55 0xC8 0x7A, niederwertiges Bit zuerst (48 Bit).
    public static let endPattern48: [UInt8] = DStarBits.bits(fromBytes: [0x55, 0x55, 0x55, 0x55, 0xC8, 0x7A])
    /// Leerer Sprachrahmen (Stille), 9 Byte, wie ihn ein Funkgerät sendet
    public static let nullAmbe: [UInt8] = [0x9E, 0x8D, 0x32, 0x88, 0x26, 0x1A, 0x3F, 0x61, 0xE8]
    /// Langsamdaten ohne Inhalt (0x66 0x66 0x66, bevor sie verwürfelt werden)
    public static let nullSlowData: [UInt8] = [0x66, 0x66, 0x66]
    /// Verwürfelung der Langsamdaten je Rahmen (XOR)
    public static let slowDataScramble: [UInt8] = [0x70, 0x4F, 0x93]
}

// MARK: - Bits und Bytes

public enum DStarBits {
    /// Bytes → Bits, niederwertiges Bit zuerst
    public static func bits(fromBytes bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 8)
        for byte in bytes { for bit in 0..<8 { out.append((byte >> UInt8(bit)) & 1) } }
        return out
    }

    /// Bits (niederwertiges zuerst) → Bytes; ein unvollständiges Byte am Ende wird aufgefüllt
    public static func bytes(fromBits bits: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        var current: UInt8 = 0
        var count = 0
        for bit in bits {
            if bit != 0 { current |= 1 << UInt8(count) }
            count += 1
            if count == 8 { out.append(current); current = 0; count = 0 }
        }
        if count > 0 { out.append(current) }
        return out
    }

    public static func bytes(fromBits bits: [UInt8]) -> [UInt8] { bytes(fromBits: bits[...]) }
}

// MARK: - Prüfsumme

public enum DStarCRC {
    private static let table: [UInt16] = (0..<256).map { index in
        var value = UInt16(index)
        for _ in 0..<8 { value = (value & 1) != 0 ? (value >> 1) ^ 0x8408 : value >> 1 }
        return value
    }

    /// CRC-16/X-25 (CCITT, gespiegelt, Anfangswert 0xFFFF, Ergebnis invertiert)
    public static func fcs(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes { crc = (crc >> 8) ^ table[Int((crc ^ UInt16(byte)) & 0xFF)] }
        return ~crc
    }

    public static func fcs(_ bytes: [UInt8]) -> UInt16 { fcs(bytes[...]) }
}

// MARK: - Kopf

public struct DStarHeader: Equatable, Sendable {
    public var flag1: UInt8 = 0
    public var flag2: UInt8 = 0
    public var flag3: UInt8 = 0
    /// Rufzeichen mit 8 Zeichen (rechts mit Leerzeichen aufgefüllt, hier ohne): Zielrepeater, Heimrepeater, Gegenstation
    public var repeater2: String
    public var repeater1: String
    public var yourCall: String
    /// Eigenes Rufzeichen (8 Zeichen) und Zusatz (4 Zeichen)
    public var myCall: String
    public var myCall2: String

    public init(flag1: UInt8 = 0, flag2: UInt8 = 0, flag3: UInt8 = 0, repeater2: String = "", repeater1: String = "", yourCall: String = "CQCQCQ", myCall: String, myCall2: String = "") {
        self.flag1 = flag1; self.flag2 = flag2; self.flag3 = flag3
        self.repeater2 = repeater2; self.repeater1 = repeater1; self.yourCall = yourCall
        self.myCall = myCall; self.myCall2 = myCall2
    }

    /// Daten statt Sprache
    public var isData: Bool { flag1 & 0x80 != 0 }
    /// Über Repeater
    public var isRepeater: Bool { flag1 & 0x40 != 0 }
    public var isInterrupted: Bool { flag1 & 0x20 != 0 }
    public var isControlSignal: Bool { flag1 & 0x10 != 0 }
    public var isUrgent: Bool { flag1 & 0x08 != 0 }

    private static func field(_ text: String, _ length: Int) -> [UInt8] {
        var bytes = Array(text.uppercased().utf8.prefix(length))
        while bytes.count < length { bytes.append(0x20) }
        return bytes
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        let printable = bytes.map { ($0 >= 0x20 && $0 < 0x7F) ? Character(UnicodeScalar($0)) : " " }
        return String(printable).trimmingCharacters(in: .whitespaces)
    }

    /// Die 39 Bytes vor der Prüfsumme
    public var payload: [UInt8] {
        [flag1, flag2, flag3] + Self.field(repeater2, 8) + Self.field(repeater1, 8) + Self.field(yourCall, 8) + Self.field(myCall, 8) + Self.field(myCall2, 4)
    }

    /// Alle 41 Bytes mit Prüfsumme (niederwertiges Byte zuerst)
    public var bytes: [UInt8] {
        let body = payload
        let crc = DStarCRC.fcs(body)
        return body + [UInt8(crc & 0xFF), UInt8(crc >> 8)]
    }

    /// Liest 41 Bytes. `crcOK` sagt, ob die Prüfsumme stimmt (in beiden Bytefolgen akzeptiert, `crcSwapped` meldet die vertauschte).
    public static func parse(_ bytes: [UInt8]) -> (header: DStarHeader, crcOK: Bool, crcSwapped: Bool)? {
        guard bytes.count == DStarConstants.headerBytes else { return nil }
        let crc = DStarCRC.fcs(bytes[0..<39])
        let little = UInt16(bytes[39]) | UInt16(bytes[40]) << 8
        let big = UInt16(bytes[40]) | UInt16(bytes[39]) << 8
        let header = DStarHeader(flag1: bytes[0], flag2: bytes[1], flag3: bytes[2],
                                 repeater2: text(bytes[3..<11]), repeater1: text(bytes[11..<19]), yourCall: text(bytes[19..<27]),
                                 myCall: text(bytes[27..<35]), myCall2: text(bytes[35..<39]))
        return (header, crc == little || crc == big, crc != little && crc == big)
    }
}

// MARK: - Verwürfelung, Verschachtelung, Faltungscode des Kopfes

public enum DStarHeaderCodec {
    /// Verwürfelungsfolge: Schieberegister x⁷ + x⁴ + 1 (Periode 127), Anfangszustand 7, Ausgabe aus dem obersten Bit
    public static let scrambleSequence: [UInt8] = {
        var state: UInt8 = 7
        var out: [UInt8] = []
        out.reserveCapacity(DStarConstants.headerBits)
        for _ in 0..<DStarConstants.headerBits {
            out.append((state >> 6) & 1)
            let feedback = ((state >> 6) ^ (state >> 3)) & 1
            state = ((state << 1) | feedback) & 0x7F
        }
        return out
    }()

    /// Verschachtelung: gesendet wird an Stelle i das Bit k(i) der ungemischten Folge; k springt um 24 mit Übertrag
    public static let interleave: [Int] = {
        var table: [Int] = []
        var k = 0
        for _ in 0..<DStarConstants.headerBits {
            table.append(k)
            k += 24
            if k >= 672 { k -= 671 } else if k >= 660 { k -= 647 }
        }
        return table
    }()

    /// Faltungscode: Rate 1/2, Einflusslänge 3, Polynome 111 und 101 (Ausgabe in dieser Reihenfolge)
    public static func convolve(_ bits: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bits.count * 2)
        var u1: UInt8 = 0, u2: UInt8 = 0
        for bit in bits {
            out.append(bit ^ u1 ^ u2)
            out.append(bit ^ u2)
            u2 = u1
            u1 = bit
        }
        return out
    }

    /// Viterbi-Decoder mit weichen Werten (positiv = Bit 1, Betrag = Sicherheit). Endet im Zustand 0 (Nachlauf aus Nullen).
    public static func viterbi(soft: [Float]) -> [UInt8] {
        let steps = soft.count / 2
        guard steps > 0 else { return [] }
        let negInf: Float = -1e30
        var metric: [Float] = [0, negInf, negInf, negInf]          // Zustand = (u1 << 1) | u2
        var survivors = [[UInt8]](repeating: [UInt8](repeating: 0, count: 4), count: steps)   // Vorgängerzustand je Schritt
        var decisions = [[UInt8]](repeating: [UInt8](repeating: 0, count: 4), count: steps)   // Eingangsbit je Schritt
        for step in 0..<steps {
            let r0 = soft[step * 2], r1 = soft[step * 2 + 1]
            var next: [Float] = [negInf, negInf, negInf, negInf]
            for state in 0..<4 where metric[state] > negInf / 2 {
                let u1 = UInt8((state >> 1) & 1), u2 = UInt8(state & 1)
                for input in 0..<2 {
                    let bit = UInt8(input)
                    let o0 = bit ^ u1 ^ u2, o1 = bit ^ u2
                    let cost = (o0 != 0 ? r0 : -r0) + (o1 != 0 ? r1 : -r1)
                    let target = (Int(bit) << 1) | Int(u1)
                    let value = metric[state] + cost
                    if value > next[target] {
                        next[target] = value
                        survivors[step][target] = UInt8(state)
                        decisions[step][target] = bit
                    }
                }
            }
            metric = next
        }
        var state = 0          // der Nachlauf bringt den Coder in den Zustand 0
        var bits = [UInt8](repeating: 0, count: steps)
        for step in stride(from: steps - 1, through: 0, by: -1) {
            bits[step] = decisions[step][state]
            state = Int(survivors[step][state])
        }
        return bits
    }

    /// Kopf → 660 gesendete Bits (nach Reihenfolge der Leitung)
    public static func encode(_ header: DStarHeader) -> [UInt8] {
        let plain = DStarBits.bits(fromBytes: header.bytes) + [0, 0]                 // 328 Bit + 2 Bit Nachlauf
        let coded = convolve(plain)                                                   // 660
        let order = interleave
        var sent = [UInt8](repeating: 0, count: coded.count)
        for i in 0..<coded.count { sent[i] = coded[order[i]] }
        for i in 0..<sent.count { sent[i] ^= scrambleSequence[i] }
        return sent
    }

    /// 660 empfangene weiche Werte (positiv = Bit 1) → Kopf. `nil`, wenn die Länge nicht stimmt.
    public static func decode(soft: [Float]) -> (header: DStarHeader, crcOK: Bool, crcSwapped: Bool)? {
        guard soft.count == DStarConstants.headerBits else { return nil }
        var descrambled = soft
        for i in 0..<soft.count where scrambleSequence[i] != 0 { descrambled[i] = -descrambled[i] }
        let order = interleave
        var plain = [Float](repeating: 0, count: soft.count)
        for i in 0..<soft.count { plain[order[i]] = descrambled[i] }
        let bits = viterbi(soft: plain)
        return DStarHeader.parse(DStarBits.bytes(fromBits: bits[0..<328]))
    }

    public static func decode(bits: [UInt8]) -> (header: DStarHeader, crcOK: Bool, crcSwapped: Bool)? {
        decode(soft: bits.map { $0 != 0 ? 1 : -1 })
    }
}

// MARK: - Sprachrahmen

public struct DStarVoiceFrame: Equatable, Sendable {
    /// Nummer im Überrahmen: 0 = Synchronrahmen, 1…20 = mit Langsamdaten
    public let index: Int
    /// 72 Kanalbits des Sprachcodecs, in der Byte-Reihenfolge der Leitung (9 Byte)
    public let ambe: [UInt8]
    /// Langsamdaten (3 Byte, entwürfelt); im Synchronrahmen leer
    public let slowData: [UInt8]
    public var isSync: Bool { index == 0 }

    public init(index: Int, ambe: [UInt8], slowData: [UInt8]) {
        self.index = index; self.ambe = ambe; self.slowData = slowData
    }
}

// MARK: - GPS-Zeile (DPRS)

/// Positionsmeldung in den Langsamdaten (DPRS, APRS-Format): `$$CRC1234,RUFZEICHEN>API51,DSTAR*:/080933h4318.65N/00641.10E[…Kommentar`
public struct DStarPosition: Equatable, Sendable {
    public var callsign: String
    public var latitude: Double
    public var longitude: Double
    public var comment: String

    /// Liest eine Zeile; `nil`, wenn die Prüfsumme nicht stimmt oder keine Position darin steht.
    /// Die Prüfsumme (CRC-16/X-25) läuft über alles nach dem ersten Komma einschließlich des Zeilenendes (CR).
    public static func parse(_ line: String) -> DStarPosition? {
        guard line.hasPrefix("$$CRC"), let comma = line.firstIndex(of: ","), line.distance(from: line.startIndex, to: comma) == 9 else { return nil }
        let claimed = String(line[line.index(line.startIndex, offsetBy: 5)..<comma])
        let body = String(line[line.index(after: comma)...])
        guard let expected = UInt16(claimed, radix: 16), DStarCRC.fcs(Array((body + "\r").utf8)) == expected else { return nil }
        guard let colon = body.firstIndex(of: ":"), let arrow = body.firstIndex(of: ">") else { return nil }
        let callsign = String(body[body.startIndex..<arrow]).trimmingCharacters(in: .whitespaces)
        let data = Array(body[body.index(after: colon)...].utf8)
        // ddmm.mmN, Symboltabelle, dddmm.mmE
        func digits(_ at: Int, _ count: Int) -> Int? {
            guard at + count <= data.count else { return nil }
            var value = 0
            for i in 0..<count { guard data[at + i] >= 0x30, data[at + i] <= 0x39 else { return nil }; value = value * 10 + Int(data[at + i] - 0x30) }
            return value
        }
        for start in 0..<max(0, data.count - 17) {
            guard let latDeg = digits(start, 2), let latMin = digits(start + 2, 2), data[start + 4] == 0x2E, let latFrac = digits(start + 5, 2),
                  data[start + 7] == 0x4E || data[start + 7] == 0x53,
                  let lonDeg = digits(start + 9, 3), let lonMin = digits(start + 12, 2), data[start + 14] == 0x2E, let lonFrac = digits(start + 15, 2),
                  start + 17 < data.count, data[start + 17] == 0x45 || data[start + 17] == 0x57 else { continue }
            var lat = Double(latDeg) + (Double(latMin) + Double(latFrac) / 100) / 60
            var lon = Double(lonDeg) + (Double(lonMin) + Double(lonFrac) / 100) / 60
            if data[start + 7] == 0x53 { lat = -lat }
            if data[start + 17] == 0x57 { lon = -lon }
            guard abs(lat) <= 90, abs(lon) <= 180 else { continue }
            let rest = data[min(start + 19, data.count)...]
            let comment = String(rest.map { ($0 >= 0x20 && $0 < 0x7F) ? Character(UnicodeScalar($0)) : " " }).trimmingCharacters(in: .whitespaces)
            return DStarPosition(callsign: callsign, latitude: lat, longitude: lon, comment: comment)
        }
        return nil
    }
}

// MARK: - Langsamdaten

/// Setzt die Langsamdaten aus je zwei Rahmen (6 Byte: Kennung + 5 Nutzbytes) zusammen: Textnachricht (20 Zeichen),
/// Kopf-Wiederholung (für späten Einstieg) und Datenzeilen (GPS/DPRS). `add` meldet nur Änderungen.
public struct DStarSlowData: Sendable {
    public private(set) var message: String?
    /// Letzte vollständige Datenzeile (Zeilen mit `$$CRC` nur, wenn ihre Prüfsumme stimmt)
    public private(set) var dataLine: String?
    public private(set) var position: DStarPosition?
    /// Kopf aus der Wiederholung (nur mit gültiger Prüfsumme)
    public private(set) var header: DStarHeader?

    private var pending: [UInt8] = []
    private var messageParts = [[UInt8]?](repeating: nil, count: 4)
    private var headerBytes: [UInt8] = []
    private var dataBytes: [UInt8] = []

    public init() {}

    /// Beginn einer Aussendung
    public mutating func reset() { self = DStarSlowData() }

    /// Ein Rahmen mit 3 Byte Langsamdaten (Rahmen 1…20 des Überrahmens, in der Reihenfolge).
    /// Gibt `true` zurück, wenn sich Nachricht, Datenzeile, Position oder Kopf geändert haben.
    @discardableResult
    public mutating func add(frameIndex: Int, bytes: [UInt8]) -> Bool {
        guard frameIndex >= 1, frameIndex <= 20, bytes.count == 3 else { return false }
        if frameIndex % 2 == 1 { pending = bytes; return false }          // erste Hälfte des Blocks
        guard pending.count == 3 else { return false }
        let block = pending + bytes
        pending = []
        let count = min(Int(block[0] & 0x0F), 5)
        switch block[0] >> 4 {
        case 0x4:                                                           // Textnachricht, Teil 0…3 zu 5 Zeichen
            let part = Int(block[0] & 0x0F)
            guard part < 4 else { return false }
            messageParts[part] = Array(block[1...5])
            if messageParts.allSatisfy({ $0 != nil }) {
                let raw = messageParts.flatMap { $0! }
                let text = String(raw.map { ($0 >= 0x20 && $0 < 0x7F) ? Character(UnicodeScalar($0)) : " " }).trimmingCharacters(in: .whitespaces)
                messageParts = [[UInt8]?](repeating: nil, count: 4)
                if !text.isEmpty, text != message { message = text; return true }
            }
        case 0x5:
            // Kopf-Wiederholung: Blöcke zu 5 Byte, der letzte kürzer (Kennung 0x51): danach ist der Kopf vollständig
            guard count >= 1 else { return false }
            headerBytes += block[1...count]
            if headerBytes.count > 41 { headerBytes = [] }
            if count < 5 {
                let complete = headerBytes
                headerBytes = []
                if complete.count == DStarConstants.headerBytes, let parsed = DStarHeader.parse(complete), parsed.crcOK, parsed.header != header {
                    header = parsed.header
                    return true
                }
            }
        case 0x3:                                                           // Datenzeile (GPS/DPRS), bis Zeilenende
            guard count >= 1 else { return false }
            dataBytes += block[1...count]
            if let end = dataBytes.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(dataBytes[0..<end].map { ($0 >= 0x20 && $0 < 0x7F) ? Character(UnicodeScalar($0)) : "?" })
                dataBytes = []
                guard !line.isEmpty else { return false }
                if line.hasPrefix("$$CRC") {
                    guard let found = DStarPosition.parse(line) else { return false }     // beschädigt: verwerfen
                    if line != dataLine { dataLine = line; position = found; return true }
                } else if line != dataLine {
                    dataLine = line
                    return true
                }
            } else if dataBytes.count > 200 {
                dataBytes = []
            }
        default:
            break
        }
        return false
    }
}
