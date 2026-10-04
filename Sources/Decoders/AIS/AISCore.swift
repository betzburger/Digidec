import Foundation

// AIS (Automatic Identification System, ITU-R M.1371): Rahmenschicht.
// Bitstrom → HDLC (NRZI, Bit-Stopfen, Flaggen 0x7E, CRC-16) → Nutzbits → NMEA-Sätze (!AIVDM) und Nachrichten (AISMessage.swift).
// Bitordnung: Auf der Leitung geht in jedem Byte das niederwertige Bit zuerst (HDLC), die Felder der Nachricht sind aber MSB-zuerst
// definiert. `AISBits` und die !AIVDM-Sätze verwenden die Nachrichtenordnung (Bits jedes Bytes umgekehrt gegenüber der Leitung);
// die Prüfsumme läuft über die Bits in der Reihenfolge der Leitung.

// MARK: - Bitfelder

/// Die Nutzbits einer AIS-Nachricht (ohne Prüfsumme) mit Zugriff auf Felder
public struct AISBits: Equatable, Sendable {
    public var bits: [UInt8]

    public init(_ bits: [UInt8]) { self.bits = bits }

    public var count: Int { bits.count }

    /// Vorzeichenloses Feld (MSB zuerst); Bits hinter dem Ende zählen als 0
    public func u(_ start: Int, _ length: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<length {
            let k = start + i
            v = (v << 1) | (k < bits.count ? UInt32(bits[k] & 1) : 0)
        }
        return v
    }

    /// Feld mit Vorzeichen (Zweierkomplement)
    public func i(_ start: Int, _ length: Int) -> Int {
        let v = Int(u(start, length))
        return v >= 1 << (length - 1) ? v - (1 << length) : v
    }

    public func flag(_ at: Int) -> Bool { at < bits.count && bits[at] & 1 == 1 }

    /// Text in 6-Bit-ASCII; angehängte „@“ (Füllzeichen) und Leerzeichen entfallen
    public func text(_ start: Int, chars: Int) -> String {
        var out = ""
        for c in 0..<chars {
            let k = start + c * 6
            guard k + 6 <= bits.count else { break }
            let v = u(k, 6)
            out.unicodeScalars.append(UnicodeScalar(v < 32 ? v + 64 : v)!)
        }
        while let last = out.last, last == "@" || last == " " { out.removeLast() }
        return out
    }
}

// MARK: - CRC

public enum AISBitOrder {
    /// Bits jedes vollständigen Bytes umkehren (Leitungsordnung ↔ Nachrichtenordnung); ein unvollständiges Ende bleibt, wie es ist
    public static func swapBytes(_ bits: [UInt8]) -> [UInt8] {
        var out = bits
        var i = 0
        while i + 8 <= bits.count {
            for k in 0..<8 { out[i + k] = bits[i + 7 - k] }
            i += 8
        }
        return out
    }
}

public enum AISCRC {
    /// CRC-16 nach HDLC/X.25 (Polynom 0x1021 gespiegelt = 0x8408, Start 0xFFFF, Ergebnis invertiert), Bits in Sendereihenfolge.
    /// Bezieht man die 16 Prüfbits mit ein, bleibt der Rest 0xF0B8.
    public static func residue(_ bits: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in bits {
            let mix = (crc ^ UInt16(b & 1)) & 1
            crc >>= 1
            if mix == 1 { crc ^= 0x8408 }
        }
        return crc
    }

    public static let goodResidue: UInt16 = 0xF0B8

    /// Prüfsumme für die Nutzbits (in Sendereihenfolge, erstes zu sendendes Bit zuerst)
    public static func checksumBits(_ payload: [UInt8]) -> [UInt8] {
        let crc = ~residue(payload)
        return (0..<16).map { UInt8((crc >> UInt16($0)) & 1) }
    }
}

// MARK: - 6-Bit-Panzerung (NMEA)

public enum AISArmor {
    /// Nutzbits → Zeichenkette der !AIVDM-Sätze und Zahl der Füllbits
    public static func encode(_ bits: [UInt8]) -> (payload: String, fill: Int) {
        var out = ""
        var i = 0
        while i < bits.count {
            var v = 0
            for k in 0..<6 { v = (v << 1) | (i + k < bits.count ? Int(bits[i + k] & 1) : 0) }
            let c = v < 40 ? v + 48 : v + 56
            out.unicodeScalars.append(UnicodeScalar(UInt8(c)))
            i += 6
        }
        return (out, (6 - bits.count % 6) % 6)
    }

    public static func decode(_ payload: String, fill: Int) -> [UInt8]? {
        var bits: [UInt8] = []
        bits.reserveCapacity(payload.utf8.count * 6)
        for ch in payload.utf8 {
            var v = Int(ch) - 48
            if v > 40 { v -= 8 }
            guard (0..<64).contains(v) else { return nil }
            for k in (0..<6).reversed() { bits.append(UInt8((v >> k) & 1)) }
        }
        guard fill >= 0, fill < 6, bits.count >= fill else { return nil }
        bits.removeLast(fill)
        return bits
    }
}

// MARK: - NMEA

public enum AISNMEA {
    public static func checksum(_ body: String) -> UInt8 {
        body.utf8.reduce(0) { $0 ^ $1 }
    }

    public static func line(_ body: String) -> String {
        String(format: "!%@*%02X", body, checksum(body))
    }

    /// Sätze `!AIVDM,…` für eine Nachricht; bei mehr als 56 Zeichen Nutzlast mehrteilig (mit Folgenummer)
    public static func sentences(for bits: [UInt8], channel: Character = "A", sequence: Int = 0, talker: String = "AIVDM") -> [String] {
        let (payload, fill) = AISArmor.encode(bits)
        let chars = Array(payload)
        let maxLen = 56
        let parts = max(1, (chars.count + maxLen - 1) / maxLen)
        var out: [String] = []
        for p in 0..<parts {
            let chunk = String(chars[(p * maxLen)..<min(chars.count, (p + 1) * maxLen)])
            let seq = parts > 1 ? String(sequence % 10) : ""
            let f = p == parts - 1 ? fill : 0
            out.append(line("\(talker),\(parts),\(p + 1),\(seq),\(channel),\(chunk),\(f)"))
        }
        return out
    }

    public struct Sentence: Equatable, Sendable {
        public var talker: String
        public var count: Int
        public var number: Int
        public var sequence: String
        public var channel: String
        public var payload: String
        public var fill: Int
    }

    /// Einen !AIVDM/!AIVDO-Satz zerlegen; nil bei falscher Prüfsumme oder Form
    public static func parse(_ raw: String) -> Sentence? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("!"), let star = s.lastIndex(of: "*") else { return nil }
        let body = String(s[s.index(after: s.startIndex)..<star])
        let sum = String(s[s.index(after: star)...])
        guard sum.count >= 2, let expected = UInt8(sum.prefix(2), radix: 16), expected == checksum(body) else { return nil }
        let f = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 7, f[0].hasPrefix("AI") || f[0].hasSuffix("VDM") || f[0].hasSuffix("VDO"),
              let count = Int(f[1]), let number = Int(f[2]), let fill = Int(f[6]) else { return nil }
        return Sentence(talker: f[0], count: count, number: number, sequence: f[3], channel: f[4], payload: f[5], fill: fill)
    }

    /// Setzt mehrteilige Sätze zusammen (für Dateien und Tests)
    public struct Assembler: Sendable {
        private var pending: [String: [Int: Sentence]] = [:]

        public init() {}

        /// Liefert die vollständigen Nutzbits, sobald alle Teile da sind
        public mutating func add(_ s: Sentence) -> [UInt8]? {
            if s.count <= 1 { return AISArmor.decode(s.payload, fill: s.fill) }
            let key = s.sequence + s.channel
            var parts = pending[key] ?? [:]
            if s.number == 1 { parts = [:] }
            parts[s.number] = s
            pending[key] = parts
            guard parts.count == s.count, (1...s.count).allSatisfy({ parts[$0] != nil }) else { return nil }
            pending[key] = nil
            var payload = ""
            for n in 1...s.count { payload += parts[n]!.payload }
            return AISArmor.decode(payload, fill: parts[s.count]!.fill)
        }
    }
}

// MARK: - HDLC-Rahmenbildung

/// Setzt den entschiedenen Bitstrom (nach NRZI) zu Rahmen zusammen: Flaggen suchen, Nullen entfernen, Prüfsumme prüfen.
public struct AISDeframer: Sendable {
    /// Kürzeste und längste Nutzlänge in Bit (ohne Prüfsumme). Die längste AIS-Nachricht belegt 5 Zeitschlitze (etwa 1190 Bit).
    /// Rahmen liefern ihre Nutzbits in Nachrichtenordnung (siehe `AISBitOrder`).
    public static let minPayloadBits = 38
    public static let maxPayloadBits = 1_200

    /// Ein gültiger Rahmen
    public struct Frame: Equatable, Sendable {
        public var bits: [UInt8]
    }

    private var shift: UInt8 = 0
    private var ones = 0
    private var inFrame = false
    private var data: [UInt8] = []
    private var confs: [Float] = []
    /// Letzter Rahmen mit richtigem Aufbau (Start- und Endflagge, mögliche Länge), aber falscher Prüfsumme: Bits samt Zuverlässigkeit
    public private(set) var lastRejected: (bits: [UInt8], confidence: [Float])?
    /// Zähler für die Diagnose
    public private(set) var flags = 0
    public private(set) var crcFailures = 0
    public private(set) var frames = 0

    public init() { data.reserveCapacity(1_300); confs.reserveCapacity(1_300) }

    /// `true`, solange ein Rahmen aufgenommen wird (nach der Startflagge)
    public var isReceiving: Bool { inFrame }

    public mutating func reset() {
        shift = 0
        ones = 0
        inFrame = false
        data.removeAll(keepingCapacity: true)
        confs.removeAll(keepingCapacity: true)
        lastRejected = nil
    }

    /// Ein Bit (nach NRZI-Entscheidung) einspeisen; Rückgabe: fertiger Rahmen mit gültiger Prüfsumme.
    /// `confidence` ist die Zuverlässigkeit der Entscheidung (für die Korrektur einzelner Bitfehler).
    public mutating func push(_ bit: UInt8, confidence: Float = 1) -> Frame? {
        let b = bit & 1
        shift = (shift >> 1) | (b << 7)          // das älteste Bit liegt unten: Flagge 0x7E = Bits 0,1,1,1,1,1,1,0 in Sendereihenfolge
        if shift == 0x7E {
            flags += 1
            var result: Frame?
            if inFrame {
                // die letzten 7 Bits der Flagge (0,1,1,1,1,1,1) wurden schon in `data` abgelegt
                if data.count >= 7 { data.removeLast(7); confs.removeLast(7) }
                result = finish()
            }
            data.removeAll(keepingCapacity: true)
            confs.removeAll(keepingCapacity: true)
            inFrame = true
            ones = 0
            return result
        }
        guard inFrame else { return nil }
        if b == 1 {
            ones += 1
            if ones >= 7 {                    // Abbruch (Abort)
                inFrame = false
                data.removeAll(keepingCapacity: true)
                confs.removeAll(keepingCapacity: true)
                ones = 0
                return nil
            }
            data.append(1)
            confs.append(confidence)
        } else {
            if ones == 5 {
                ones = 0                       // gestopftes Bit: weglassen
                return nil
            }
            ones = 0
            data.append(0)
            confs.append(confidence)
        }
        if data.count > Self.maxPayloadBits + 16 + 8 {
            inFrame = false
            data.removeAll(keepingCapacity: true)
            confs.removeAll(keepingCapacity: true)
        }
        return nil
    }

    private mutating func finish() -> Frame? {
        guard data.count >= Self.minPayloadBits + 16, data.count <= Self.maxPayloadBits + 16 else { return nil }
        if AISCRC.residue(data) == AISCRC.goodResidue {
            frames += 1
            return Frame(bits: AISBitOrder.swapBytes(Array(data.dropLast(16))))
        }
        crcFailures += 1
        lastRejected = (data, confs)
        return nil
    }

    /// Versucht, einen Rahmen mit falscher Prüfsumme durch Umkehren eines oder zweier unsicherer Bits zu retten
    /// (ein Bit: alle Stellen; zwei Bits: unter den `pairs` unsichersten). Rückgabe: Nutzbits in Nachrichtenordnung.
    public static func repair(_ bits: [UInt8], confidence: [Float], singles: Int = 400, pairs: Int = 10, accept: ([UInt8]) -> Bool) -> [UInt8]? {
        var b = bits
        func check() -> [UInt8]? {
            guard AISCRC.residue(b) == AISCRC.goodResidue else { return nil }
            let payload = AISBitOrder.swapBytes(Array(b.dropLast(16)))
            return accept(payload) ? payload : nil
        }
        // nur unsichere Bits kommen als Fehler in Frage: ein Bit unter den `singles` unsichersten, zwei unter den `pairs` unsichersten
        let order = confidence.indices.sorted { confidence[$0] < confidence[$1] }
        for i in order.prefix(singles) {
            b[i] ^= 1
            if let f = check() { return f }
            b[i] ^= 1
        }
        let idx = Array(order.prefix(pairs))
        for x in 0..<idx.count {
            for y in (x + 1)..<idx.count {
                b[idx[x]] ^= 1; b[idx[y]] ^= 1
                if let f = check() { return f }
                b[idx[x]] ^= 1; b[idx[y]] ^= 1
            }
        }
        return nil
    }
}

// MARK: - Sendeseite (für Testsignale und Prüfstände)

public enum AISFraming {
    /// Nutzbits (Nachrichtenordnung) → Bitfolge auf der Leitung vor NRZI: Training (24 × 0101…), Flagge,
    /// Nutzbits + Prüfsumme mit Nullen gestopft, Flagge, Pufferbits. Die Nutzlast wird auf volle Bytes aufgefüllt.
    public static func wireBits(payload message: [UInt8], buffer: Int = 24) -> [UInt8] {
        var padded = message
        while padded.count % 8 != 0 { padded.append(0) }
        let payload = AISBitOrder.swapBytes(padded)
        var out: [UInt8] = []
        for i in 0..<24 { out.append(UInt8(i % 2)) }
        let flag: [UInt8] = [0, 1, 1, 1, 1, 1, 1, 0]
        out += flag
        var ones = 0
        for b in payload + AISCRC.checksumBits(payload) {
            out.append(b)
            if b == 1 {
                ones += 1
                if ones == 5 { out.append(0); ones = 0 }
            } else {
                ones = 0
            }
        }
        out += flag
        out += [UInt8](repeating: 0, count: buffer)
        return out
    }

    /// NRZI: eine 0 wechselt den Pegel, eine 1 behält ihn. Ergebnis: Pegel je Bit (+1/−1)
    public static func nrzi(_ bits: [UInt8], start: Float = 1) -> [Float] {
        var level = start
        var out: [Float] = []
        for b in bits {
            if b == 0 { level = -level }
            out.append(level)
        }
        return out
    }
}
