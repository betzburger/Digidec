// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import JS8

// Nachrichtenschicht von JS8: die 12 Zeichen eines Rahmens (6 Bit je Zeichen, 72 Bit) zu Text auspacken.
// Nach Varicode und DecodedText aus JS8Call (C) 2018 Jordan Sherer KN4CRD, GPLv3 (varicode.cpp, jsc.cpp, decodedtext.cpp).
// Nur Empfang: Digidec sendet nie. Herkunft und Abweichungen: Vendor/JS8/UPSTREAM_JS8.md

/// Übertragungsart eines Rahmens (die 3 Bit „i3bit“ des Decoders)
public struct JS8FrameBits: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Erster Rahmen einer Nachricht
    public static let first = JS8FrameBits(rawValue: 1)
    /// Letzter Rahmen einer Nachricht
    public static let last = JS8FrameBits(rawValue: 2)
    /// Datenrahmen ohne Kopf (schnelle Betriebsarten)
    public static let data = JS8FrameBits(rawValue: 4)
}

/// Art eines ausgepackten Rahmens (die ersten 3 Bit des Rahmens)
public enum JS8FrameKind: Int, Sendable {
    case heartbeat = 0
    case compound = 1
    case compoundDirected = 2
    case directed = 3
    case data = 4
    case unknown = 255
}

/// Ein ausgepackter Rahmen
public struct JS8Unpacked: Sendable, Equatable {
    public var kind: JS8FrameKind
    /// Anzeigetext wie in JS8Call („KN4CRD: W1AW ACK “, „DL1ABC: @HB HEARTBEAT JN49 “)
    public var text: String
    /// Absender (Heartbeat, Compound, Directed)
    public var from: String?
    /// Empfänger (Directed)
    public var to: String?
    /// Befehl (mit führendem Leerzeichen wie in JS8Call: „ ACK“, „ SNR?“), auch bei Compound-Directed
    public var command: String?
    /// Zahl zum Befehl (SNR oder Wert), schon formatiert
    public var number: String?
    /// Locator (4 Stellen), wenn im Rahmen
    public var grid: String?
    /// Heartbeat: „CQ …“ statt „HB“
    public var isCQ = false

    public init(kind: JS8FrameKind, text: String, from: String? = nil, to: String? = nil, command: String? = nil,
                number: String? = nil, grid: String? = nil, isCQ: Bool = false) {
        self.kind = kind; self.text = text; self.from = from; self.to = to; self.command = command
        self.number = number; self.grid = grid; self.isCQ = isCQ
    }
}

public enum JS8Varicode {
    // MARK: Tabellen

    /// Zeichen der 6-Bit-Wörter eines Rahmens (der Decoder liefert nur die ersten 64)
    static let frameAlphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-+/?.")
    /// Zeichen für Rufzeichen und Gruppen: 0–9, A–Z, Leerzeichen, „/“, „@“
    static let alphanumeric = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ /@")

    static let nbasecall: UInt32 = 37 * 36 * 10 * 27 * 27 * 27
    static let nbasegrid: UInt32 = 180 * 180
    static let nusergrid: UInt32 = nbasegrid + 10
    static let nmaxgrid: UInt32 = (1 << 15) - 1

    /// Gruppen und besondere „Rufzeichen“, Index = Wert − nbasecall − 1
    static let baseCalls: [String] = [
        "<....>", "@ALLCALL", "@JS8NET",
        "@DX/NA", "@DX/SA", "@DX/EU", "@DX/AS", "@DX/AF", "@DX/OC", "@DX/AN",
        "@REGION/1", "@REGION/2", "@REGION/3",
        "@GROUP/0", "@GROUP/1", "@GROUP/2", "@GROUP/3", "@GROUP/4", "@GROUP/5", "@GROUP/6", "@GROUP/7", "@GROUP/8", "@GROUP/9",
        "@COMMAND", "@CONTROL", "@NET", "@NTS",
        "@RESERVE/0", "@RESERVE/1", "@RESERVE/2", "@RESERVE/3", "@RESERVE/4",
        "@APRSIS", "@RAGCHEW", "@JS8", "@EMCOMM", "@ARES", "@MARS", "@AMRRON", "@RACES", "@RAYNET", "@RADAR", "@SKYWARN",
        "@CQ", "@HB", "@QSO", "@QSOPARTY", "@CONTEST", "@FIELDDAY", "@SOTA", "@IOTA", "@POTA", "@QRP", "@QRO",
    ]

    /// Befehle: Wert (5 Bit) → Schreibweise. Wo JS8Call mehrere Schreibweisen kennt, gilt die erste in der Sortierung
    /// von QMap::key() (die kürzere zuerst, Leerzeichen vor Satzzeichen).
    static let commands: [Int: String] = [
        0: " SNR?", 1: " DIT DIT", 2: " NACK", 3: " HEARING?", 4: " GRID?", 5: ">", 6: " STATUS?", 7: " STATUS", 8: " HEARING",
        9: " MSG", 10: " MSG TO:", 11: " QUERY", 12: " QUERY MSGS", 13: " QUERY CALL", 14: " ACK", 15: " GRID",
        16: " INFO?", 17: " INFO", 18: " FB", 19: " HW CPY?", 20: " SK", 21: " RR", 22: " QSL?", 23: " QSL", 24: " CMD",
        25: " SNR", 26: " NO", 27: " YES", 28: " 73", 29: " HEARTBEAT SNR", 30: " AGN?", 31: " ",
    ]

    /// Befehle mit angehängter SNR
    static let snrCommands: Set<Int> = [25, 29]

    /// Heartbeat/CQ-Art (3 Bit)
    static let cqs = ["CQ CQ CQ", "CQ DX", "CQ QRP", "CQ CONTEST", "CQ FIELD", "CQ FD", "CQ CQ", "CQ"]

    /// Huffman-Tabelle der alten Datenrahmen (Zeichen → Bits)
    static let huffman: [(String, String)] = [
        (" ", "01"), ("E", "100"), ("T", "1101"), ("A", "0011"), ("O", "11111"), ("I", "11100"), ("N", "10111"), ("S", "10100"),
        ("H", "00011"), ("R", "00000"), ("D", "111011"), ("L", "110011"), ("C", "110001"), ("U", "101101"), ("M", "101011"),
        ("W", "001011"), ("F", "001001"), ("G", "000101"), ("Y", "000011"), ("P", "1111011"), ("B", "1111001"), (".", "1110100"),
        ("V", "1100101"), ("K", "1100100"), ("-", "1100001"), ("+", "1100000"), ("?", "1011001"), ("!", "1011000"),
        ("\"", "1010101"), ("X", "1010100"), ("0", "0010101"), ("J", "0010100"), ("1", "0010001"), ("Q", "0010000"),
        ("2", "0001001"), ("Z", "0001000"), ("3", "0000101"), ("5", "0000100"), ("4", "11110101"), ("9", "11110100"),
        ("8", "11110001"), ("6", "11110000"), ("7", "11101011"), ("/", "11101010"),
    ]

    private static let huffmanDecode: [String: Character] = {
        var d: [String: Character] = [:]
        for (ch, code) in huffman { d[code] = Character(ch) }
        return d
    }()

    // MARK: Rahmen

    /// 72 Bit eines Rahmens (12 Zeichen zu je 6 Bit), nil bei Zeichen außerhalb der 64 des Decoders
    static func bits(of frame: String) -> [UInt8]? {
        let chars = Array(frame)
        guard chars.count == 12 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(72)
        for c in chars {
            guard let v = frameAlphabet.firstIndex(of: c), v < 64 else { return nil }
            for b in stride(from: 5, through: 0, by: -1) { out.append(UInt8((v >> b) & 1)) }
        }
        return out
    }

    /// Zahl aus `count` Bit ab `start` (höchstwertiges zuerst)
    static func number(_ bits: [UInt8], _ start: Int, _ count: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in start..<(start + count) { v = (v << 1) | UInt64(bits[i]) }
        return v
    }

    // MARK: Rufzeichen, Locator, Befehle

    static func unpackAlphaNumeric50(_ packed: UInt64) -> String {
        var p = packed
        var word = [Character](repeating: " ", count: 11)
        func take(_ index: Int, _ mod: UInt64) {
            word[index] = alphanumeric[Int(p % mod)]
            p /= mod
        }
        take(10, 38); take(9, 38); take(8, 38)
        word[7] = p % 2 == 1 ? "/" : " "; p /= 2
        take(6, 38); take(5, 38); take(4, 38)
        word[3] = p % 2 == 1 ? "/" : " "; p /= 2
        take(2, 38); take(1, 38); take(0, 39)
        return String(word).replacingOccurrences(of: " ", with: "")
    }

    static func unpackCallsign(_ value: UInt32, portable: Bool) -> String {
        if value > nbasecall, Int(value - nbasecall - 1) < baseCalls.count { return baseCalls[Int(value - nbasecall - 1)] }
        var v = value
        var word = [Character](repeating: " ", count: 6)
        for i in [5, 4, 3] {
            word[i] = alphanumeric[Int(v % 27) + 10]
            v /= 27
        }
        word[2] = alphanumeric[Int(v % 10)]; v /= 10
        word[1] = alphanumeric[Int(v % 36)]; v /= 36
        guard Int(v) < alphanumeric.count else { return "" }
        word[0] = alphanumeric[Int(v)]
        var call = String(word)
        if call.hasPrefix("3D0") { call = "3DA0" + call.dropFirst(3) }
        if call.hasPrefix("Q"), let second = call.dropFirst().first, ("A"..."Z").contains(second) { call = "3X" + call.dropFirst(1) }
        if portable { call = call.trimmingCharacters(in: .whitespaces) + "/P" }
        return call.trimmingCharacters(in: .whitespaces)
    }

    /// Vier Zeichen eines Locators („JN49“) aus dem 15-Bit-Wert, "" bei Werten oberhalb der Karte
    static func unpackGrid(_ value: UInt32) -> String {
        guard value <= nbasegrid else { return "" }
        let dlat = Double(Int(value) % 180 - 90)
        let dlong = Double(Int(value) / 180 * 2 - 180 + 2)
        return deg2grid(dlong: dlong, dlat: dlat)
    }

    static func deg2grid(dlong: Double, dlat: Double) -> String {
        var lon = dlong
        if lon < -180 { lon += 360 }
        if lon > 180 { lon -= 360 }
        let nlong = Int(60.0 * (180.0 - lon) / 5)
        let a1 = nlong / 240
        let a2 = (nlong - 240 * a1) / 24
        let nlat = Int(60.0 * (dlat + 90) / 2.5)
        let b1 = nlat / 240
        let b2 = (nlat - 240 * b1) / 24
        func letter(_ n: Int) -> Character { Character(UnicodeScalar(UInt8(65 + max(0, min(n, 25))))) }
        func digit(_ n: Int) -> Character { Character(UnicodeScalar(UInt8(48 + max(0, min(n, 9))))) }
        return String([letter(a1), letter(b1), digit(a2), digit(b2)])
    }

    /// „+05“, „-12“ (wie Varicode::formatSNR), "" außerhalb ±60
    static func formatSNR(_ snr: Int) -> String {
        guard (-60...60).contains(snr) else { return "" }
        let mag = String(format: "%02d", abs(snr))
        return snr >= 0 ? "+" + mag : "-" + mag
    }

    /// Befehl und Zahl aus dem 8-Bit-Wert eines Compound-Rahmens (Varicode::unpackCmd)
    static func unpackCmd(_ value: UInt8) -> (cmd: Int, num: UInt8) {
        if value & 0x80 != 0 {
            return ((value & 0x40) != 0 ? 29 : 25, value & 0x3F)
        }
        return (Int(value & 0x7F), 0)
    }

    // MARK: Auspacken

    /// Packt einen Rahmen aus: dieselbe Reihenfolge der Versuche wie `DecodedText` in JS8Call.
    /// - Returns: nil, wenn der Rahmen zu keiner Art passt (Zeichen außerhalb oder Prüfungen scheitern)
    public static func unpack(_ frame: String, bits flags: JS8FrameBits) -> JS8Unpacked? {
        guard let b = bits(of: frame), frame.count == 12 else { return nil }
        if flags.contains(.data) {
            return unpackFastData(b)
        }
        if b[0] == 1 { return unpackData(b) }
        if let u = unpackHeartbeat(b) { return u }
        if let u = unpackCompound(b) { return u }
        return unpackDirected(b)
    }

    /// Schnelle Betriebsarten: alle 72 Bit sind Daten (JSC), das Auffüllen endet mit einer 0 und lauter Einsen
    static func unpackFastData(_ b: [UInt8]) -> JS8Unpacked? {
        guard let n = b.lastIndex(of: 0) else { return nil }
        let text = JS8JSC.decompress(Array(b[0..<n]))
        return text.isEmpty ? nil : JS8Unpacked(kind: .data, text: text)
    }

    /// Alte Datenrahmen (Bit 0 = 1): Bit 1 = JSC-komprimiert oder Huffman
    static func unpackData(_ b: [UInt8]) -> JS8Unpacked? {
        let rest = Array(b[1...])
        guard let n = rest.lastIndex(of: 0), n >= 1 else { return nil }
        let content = Array(rest[1..<n])
        let text: String
        if rest[0] == 1 {
            text = JS8JSC.decompress(content)
        } else {
            text = huffmanText(content)
        }
        return text.isEmpty ? nil : JS8Unpacked(kind: .data, text: text)
    }

    static func huffmanText(_ bits: [UInt8]) -> String {
        var out = ""
        var current = ""
        for bit in bits {
            current.append(bit == 1 ? "1" : "0")
            if let ch = huffmanDecode[current] {
                out.append(ch)
                current = ""
            } else if current.count > 8 {
                break
            }
        }
        return out
    }

    /// Gemeinsamer Kopf von Heartbeat und Compound: [3 Art][50 Rufzeichen][11+5 Zusatz][3 Bit]
    static func compoundFrame(_ b: [UInt8]) -> (kind: Int, call: String, num: UInt32, bits3: Int)? {
        let kind = Int(number(b, 0, 3))
        guard kind != 4, kind != 3 else { return nil }
        let call = unpackAlphaNumeric50(number(b, 3, 50))
        let packed11 = UInt32(number(b, 53, 11))
        let packed5 = UInt32(number(b, 64, 5))
        let bits3 = Int(number(b, 69, 3))
        return (kind, call, (packed11 << 5) | packed5, bits3)
    }

    static func unpackHeartbeat(_ b: [UInt8]) -> JS8Unpacked? {
        guard let f = compoundFrame(b), f.kind == 0 else { return nil }
        let grid = unpackGrid(f.num & ((1 << 15) - 1))
        let isAlt = (f.num & (1 << 15)) != 0
        var text = f.call + ": "
        if isAlt {
            text += "@ALLCALL " + cqs[f.bits3]
        } else {
            text += "@HB HEARTBEAT"
        }
        text += " " + grid + " "
        return JS8Unpacked(kind: .heartbeat, text: text, from: f.call, grid: grid.isEmpty ? nil : grid, isCQ: isAlt)
    }

    static func unpackCompound(_ b: [UInt8]) -> JS8Unpacked? {
        guard let f = compoundFrame(b), f.kind == 1 || f.kind == 2 else { return nil }
        var extra: [String] = []
        var grid: String?
        var command: String?
        var number: String?
        if f.num <= nbasegrid {
            let g = unpackGrid(f.num)
            extra.append(" " + g)
            grid = g.isEmpty ? nil : g
        } else if nusergrid <= f.num, f.num < nmaxgrid {
            let (cmd, num) = unpackCmd(UInt8(truncatingIfNeeded: f.num - nusergrid))
            let name = commands[cmd] ?? ""
            extra.append(name)
            command = name
            if snrCommands.contains(cmd) {
                let snr = formatSNR(Int(num) - 31)
                extra.append(snr)
                number = snr
            }
        }
        let joined = extra.joined(separator: " ")
        let text = f.kind == 1 ? f.call + ": " : f.call + joined + " "
        return JS8Unpacked(kind: f.kind == 1 ? .compound : .compoundDirected, text: text, from: f.call, command: command, number: number, grid: grid)
    }

    static func unpackDirected(_ b: [UInt8]) -> JS8Unpacked? {
        guard number(b, 0, 3) == 3 else { return nil }
        let from = UInt32(number(b, 3, 28))
        let to = UInt32(number(b, 31, 28))
        let cmd = Int(number(b, 59, 5))
        let portableFrom = b[64] == 1
        let portableTo = b[65] == 1
        let extra = Int(number(b, 66, 6))
        let fromCall = unpackCallsign(from, portable: portableFrom)
        let toCall = unpackCallsign(to, portable: portableTo)
        let name = commands[cmd] ?? ""
        var parts = [name]
        var num: String?
        if extra != 0 {
            let s = snrCommands.contains(cmd) ? formatSNR(extra - 31) : String(extra - 31)
            parts.append(s)
            num = s
        }
        let text = fromCall + ": " + toCall + parts.joined(separator: " ") + " "
        return JS8Unpacked(kind: .directed, text: text, from: fromCall, to: toCall, command: name, number: num)
    }
}

// MARK: - JSC

/// JSC-Wörterbuch (262 144 Wörter, (s,c)-dichte Codierung) wie in JS8Call: nur Entpacken
public enum JS8JSC {
    static let b = 4
    static let s = 7
    static let c = 9   // 2^b − s

    /// Wort Nr. `index` (im Wörterbuch Latin-1)
    static func word(_ index: Int) -> String? {
        guard index >= 0, index < Int(jsc_word_count) else { return nil }
        var length: UInt32 = 0
        guard let p = jsc_word(UInt32(index), &length) else { return nil }
        return p.withMemoryRebound(to: UInt8.self, capacity: Int(length)) { raw in
            String(bytes: UnsafeBufferPointer(start: raw, count: Int(length)), encoding: .isoLatin1)
        }
    }

    /// Entpackt die Bits (ohne Auffüllung) zu Text
    public static func decompress(_ bits: [UInt8]) -> String {
        var base = [Int](repeating: 0, count: 8)
        base[1] = s
        var power = s
        for k in 2..<8 {
            power *= c
            base[k] = base[k - 1] + power
        }
        var bytes: [Int] = []
        var separators: [Int] = []
        var i = 0
        while i + 4 <= bits.count {
            var v = 0
            for j in 0..<4 { v = (v << 1) | Int(bits[i + j]) }
            bytes.append(v)
            i += 4
            if v < s {
                if bits.count - i > 0, bits[i] == 1 { separators.append(bytes.count - 1) }
                i += 1
            }
        }
        var out = ""
        var start = 0
        var sepIndex = 0
        let size = Int(jsc_word_count)
        while start < bytes.count {
            var k = 0
            var j = 0
            while start + k < bytes.count, bytes[start + k] >= s {
                j = j * c + (bytes[start + k] - s)
                k += 1
            }
            if j >= size { break }
            if start + k >= bytes.count { break }
            j = j * s + bytes[start + k] + base[k]
            if j >= size { break }
            if let w = word(j) { out += w }
            if sepIndex < separators.count, separators[sepIndex] == start + k {
                out += " "
                sepIndex += 1
            }
            start += k + 1
        }
        return out
    }
}
