// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - Kennung der Gegenstelle („[WL2K-5.0-B2FWIHJM$]“)

/// Die Kennung (SID), mit der sich Mailboxen und Winlink-Gateways nach dem Verbinden vorstellen: Programm, Version, Fähigkeiten
public struct MailSID: Equatable, Sendable {
    public var software: String
    public var version: String
    /// Fähigkeitsbuchstaben („B2FWIHJM“): B2 = komprimierte Übertragung Fassung 2, F = Weiterleitung, … (nur zur Anzeige)
    public var flags: String

    /// Ist die Zeile eine Kennung? „[Programm-Version-Flags$]“
    public static func isSID(_ line: String) -> Bool {
        line.hasPrefix("[") && line.hasSuffix("$]") && line.dropFirst().dropLast(2).contains("-")
    }

    public init?(line: String) {
        guard Self.isSID(line) else { return nil }
        let inner = String(line.dropFirst().dropLast(2))
        let parts = inner.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let last = parts.last else { return nil }
        flags = last
        software = parts[0]
        version = parts.dropFirst().dropLast().joined(separator: "-")
    }

    /// Winlink-System (CMS/RMS) oder ein Programm mit Winlink-Erweiterung (B2F)
    public var isWinlink: Bool {
        software.uppercased().contains("WL2K") || software.uppercased().contains("WINLINK") || software.uppercased().contains("RMS") || flags.contains("B2F")
    }

    public var text: String {
        "\(software) \(version)" + (flags.isEmpty ? "" : " [\(flags)]")
    }
}

// MARK: - Vorschläge und Nachrichten

/// Ein Vorschlag aus der Weiterleitung („FC EM TJKYEIMMHSRB 527 123 0“ bei Winlink; „FB P DL1ABC …“ bei Mailboxen)
public struct MailProposal: Identifiable, Equatable, Sendable {
    public var id: String { mid }
    /// Kennbuchstabe: C = Winlink (komprimiert, Fassung 2), D = gzip, A und B = ältere FBB-Weiterleitung
    public var code: Character
    /// Art: EM (E-Mail), CM (Kontrollnachricht) bei Winlink; P, B, T … bei Mailboxen
    public var type: String
    public var mid: String
    public var size: Int
    public var compressedSize: Int
    /// Ursprüngliche Zeile (bei Mailbox-Weiterleitung mit Absender, Ziel und Kennung)
    public var line: String
    /// Antwort der Gegenstelle: + angenommen, − abgelehnt, = zurückgestellt; nil = nicht gehört
    public var answer: Character?
    public var delivered = false
}

/// Eine entpackte Winlink-Nachricht
public struct WinlinkMessage: Identifiable, Equatable, Sendable {
    public var id: String { mid.isEmpty ? "\(from)-\(date)-\(subject)" : mid }
    public var mid: String
    public var date: String
    public var type: String
    public var from: String
    public var to: [String]
    public var cc: [String]
    public var subject: String
    public var mbo: String
    public var body: String
    public var attachments: [Attachment]
    public var headers: [(String, String)]
    /// Größe der entpackten Nachricht in Byte
    public var size: Int
    public var compressedSize: Int
    /// Wann die Nachricht fertig empfangen war
    public var received = Date.distantPast

    public struct Attachment: Equatable, Sendable {
        public var name: String
        public var size: Int
        public var data: [UInt8]
    }

    public static func == (a: WinlinkMessage, b: WinlinkMessage) -> Bool {
        a.id == b.id && a.body == b.body && a.attachments == b.attachments && a.subject == b.subject
    }
}

public enum WinlinkParser {
    /// Nachricht aus den entpackten Bytes: Kopfzeilen (CR LF), Leerzeile, Text (Länge laut „Body:“), danach die Anhänge (Länge laut „File:“)
    public static func parseMessage(_ data: [UInt8], compressedSize: Int = 0) -> WinlinkMessage? {
        var pos = 0
        var headers: [(String, String)] = []
        var found = false
        while pos < data.count {
            guard let end = lineEnd(data, from: pos) else { return nil }
            let line = String(decoding: data[pos..<end], as: UTF8.self)
            pos = min(end + 2, data.count)
            if line.isEmpty { found = true; break }
            guard let colon = line.firstIndex(of: ":") else { return nil }
            headers.append((String(line[..<colon]), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
        }
        guard found, !headers.isEmpty else { return nil }
        func values(_ key: String) -> [String] { headers.filter { $0.0.lowercased() == key }.map(\.1) }
        let bodyLength = Int(values("body").first ?? "") ?? max(0, data.count - pos)
        let charset = (values("content-type").first ?? "").lowercased()
        let bodyEnd = min(pos + max(0, bodyLength), data.count)
        let bodyBytes = Array(data[pos..<bodyEnd])
        let body: String
        if charset.contains("utf-8") {
            body = String(bytes: bodyBytes, encoding: .utf8) ?? PacketText.decode(bodyBytes)
        } else if charset.contains("8859-15") {
            body = String(bytes: bodyBytes, encoding: .isoLatin2) ?? PacketText.decode(bodyBytes)   // nur Näherung
        } else {
            body = String(bytes: bodyBytes, encoding: .isoLatin1) ?? PacketText.decode(bodyBytes)
        }
        var attachments: [WinlinkMessage.Attachment] = []
        var p = bodyEnd
        for file in values("file") {
            if data[safe: p] == 0x0D, data[safe: p + 1] == 0x0A { p += 2 }
            let parts = file.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let size = Int(parts[0]), size >= 0 else { break }
            let e = min(p + size, data.count)
            attachments.append(.init(name: parts[1], size: size, data: Array(data[min(p, data.count)..<e])))
            p = e
        }
        func addresses(_ key: String) -> [String] {
            values(key).flatMap { $0.split(separator: ",").map { decodeWords(String($0)).trimmingCharacters(in: .whitespaces) } }
        }
        return WinlinkMessage(mid: values("mid").first ?? "", date: values("date").first ?? "", type: values("type").first ?? "",
                              from: decodeWords(values("from").first ?? ""), to: addresses("to"), cc: addresses("cc"),
                              subject: decodeWords(values("subject").first ?? ""), mbo: values("mbo").first ?? "", body: body,
                              attachments: attachments, headers: headers, size: data.count, compressedSize: compressedSize)
    }

    private static func lineEnd(_ d: [UInt8], from: Int) -> Int? {
        var i = from
        while i + 1 < d.count {
            if d[i] == 0x0D && d[i + 1] == 0x0A { return i }
            i += 1
        }
        return nil
    }

    /// Kopfzeilen können Wörter nach RFC 2047 enthalten: „=?utf-8?Q?F=C3=BCr?=“ und „=?iso-8859-1?B?…?=“
    public static func decodeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        var out = ""
        var rest = Substring(s)
        while let start = rest.range(of: "=?") {
            out += rest[..<start.lowerBound]
            let after = rest[start.upperBound...]
            let fields = after.split(separator: "?", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, fields[3].hasPrefix("="), fields[1].count == 1 else {
                out += "=?"
                rest = after
                continue
            }
            let charset = fields[0].lowercased()
            let encoded = String(fields[2])
            var bytes: [UInt8] = []
            if fields[1].uppercased() == "B" {
                bytes = Data(base64Encoded: encoded).map { [UInt8]($0) } ?? []
            } else {
                var i = encoded.utf8.startIndex
                let u = encoded.utf8
                while i < u.endIndex {
                    let c = u[i]
                    if c == UInt8(ascii: "_") {
                        bytes.append(0x20)
                        i = u.index(after: i)
                    } else if c == UInt8(ascii: "="), let a = u.index(i, offsetBy: 1, limitedBy: u.endIndex), let b = u.index(i, offsetBy: 3, limitedBy: u.endIndex),
                              let v = UInt8(String(encoded[a..<b]), radix: 16) {
                        bytes.append(v)
                        i = b
                    } else {
                        bytes.append(c)
                        i = u.index(after: i)
                    }
                }
            }
            out += charset.contains("utf") ? (String(bytes: bytes, encoding: .utf8) ?? "") : (String(bytes: bytes, encoding: .isoLatin1) ?? "")
            // Wort endet mit „?=“; die „=“ gehört schon zu fields[3]
            rest = fields[3].dropFirst()
            // Leerraum zwischen zwei Wörtern entfällt
            if rest.hasPrefix(" =?") { rest = rest.dropFirst() }
        }
        return out + rest
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Ablauf der Weiterleitung (B2F)

/// Verfolgt die Weiterleitung einer Sitzung in beide Richtungen: Kennungen, Vorschläge („FC …“, „F> prüfsumme“), Antworten („FS +-“) und die Datenblöcke
/// (SOH-Kopf, STX-Blöcke, EOT mit Prüfsumme), und entpackt die Nachrichten mit LZHUF. Es sendet nichts; es liest nur mit.
public struct MailTracker: Sendable {
    public private(set) var sids: [MailSID?] = [nil, nil]
    /// Vorschläge je Richtung (0: Anrufer → Gegenstelle, 1: Gegenstelle → Anrufer)
    public private(set) var proposals: [[MailProposal]] = [[], []]
    public private(set) var messages: [WinlinkMessage] = []
    /// Fehler und Hinweise der Auswertung, für die Anzeige
    public private(set) var notes: [String] = []
    /// Einer der Vorschlagsblöcke hatte eine falsche Prüfsumme (falsche oder fehlende Bytes)
    public private(set) var checksumErrors = 0
    /// Challenge der Gegenstelle („;PQ: 12345678“): nur zur Anzeige, ob eine gesicherte Anmeldung stattfand
    public private(set) var secureChallenge = false
    /// Weiterleitung hat begonnen (Vorschläge oder Datenblöcke gesehen)
    public var sawProposals: Bool { !(proposals[0].isEmpty && proposals[1].isEmpty) }
    public var isWinlink: Bool { sids.contains { $0?.isWinlink == true } || proposals.joined().contains { $0.code == "C" } }

    private enum Mode: Sendable { case lines, header, blocks, lost }
    private struct Direction: Sendable {
        var mode: Mode = .lines
        var line: [UInt8] = []
        var blockChecksum = 0
        // Datenblöcke
        var headerNeed = -1
        var header: [UInt8] = []
        var data: [UInt8] = []
        var blockLeft = 0
        var blockLengthPending = false
        var eotPending = false
        var title = ""
    }
    private var dirs = [Direction(), Direction()]
    /// Zeit der Daten, die gerade hereinkommen (für den Empfangszeitpunkt fertiger Nachrichten)
    public var clock = Date()
    /// Nachrichten entpacken und lesen (aus: nur zählen)
    public var decodeContent = true

    public init() {}

    /// Läuft in dieser Richtung gerade ein Datenblock (Nachricht), der kein Text ist?
    public func isBinary(_ direction: Int) -> Bool {
        switch dirs[direction].mode {
        case .lines: return false
        case .header, .blocks, .lost: return true
        }
    }

    /// Daten einer Richtung (in der Reihenfolge der Folgenummern), 0 = Anrufer → Gegenstelle
    public mutating func feed(_ direction: Int, _ bytes: [UInt8]) {
        for b in bytes { step(direction, b) }
    }

    /// Ein Rahmen fehlt in dieser Richtung: mitten in einem Datenblock ist der Rest dieser Richtung nicht mehr auswertbar
    public mutating func gap(_ direction: Int) {
        switch dirs[direction].mode {
        case .lines:
            dirs[direction].line.removeAll()
        case .header, .blocks:
            dirs[direction].mode = .lost
            notes.append("Ein Rahmen fehlte mitten in einer Nachricht: der Rest dieser Richtung ist nicht auswertbar")
        case .lost:
            break
        }
    }

    private mutating func step(_ d: Int, _ b: UInt8) {
        switch dirs[d].mode {
        case .lines:
            // Beginn einer Nachricht: SOH, wenn ein Vorschlag dieser Richtung auf Daten wartet
            if b == 0x01, dirs[d].line.isEmpty, proposals[d].contains(where: { !$0.delivered && $0.answer != "-" && $0.code == "C" }) {
                dirs[d].mode = .header
                dirs[d].headerNeed = -1
                dirs[d].header = []
                dirs[d].data = []
                dirs[d].blockLeft = 0
                dirs[d].blockLengthPending = false
                dirs[d].eotPending = false
                return
            }
            if b == 0x0D {
                let line = PacketText.decode(dirs[d].line)
                let raw = dirs[d].line
                dirs[d].line.removeAll(keepingCapacity: true)
                handle(line: line, raw: raw, direction: d)
            } else if b != 0x0A {
                dirs[d].line.append(b)
                if dirs[d].line.count > 512 { dirs[d].line.removeFirst(256) }
            }
        case .header:
            if dirs[d].headerNeed < 0 {
                dirs[d].headerNeed = Int(b)         // Länge von Titel und Versatz samt zwei Nullbytes
            } else {
                dirs[d].header.append(b)
                if dirs[d].header.count >= dirs[d].headerNeed {
                    let parts = dirs[d].header.split(separator: 0, omittingEmptySubsequences: false)
                    dirs[d].title = PacketText.decode(Array(parts.first ?? []))
                    dirs[d].mode = .blocks
                }
            }
            if dirs[d].headerNeed == 0 { dirs[d].mode = .blocks }
        case .blocks:
            if dirs[d].blockLeft > 0 {
                dirs[d].data.append(b)
                dirs[d].blockLeft -= 1
            } else if dirs[d].blockLengthPending {
                dirs[d].blockLeft = b == 0 ? 256 : Int(b)
                dirs[d].blockLengthPending = false
            } else if dirs[d].eotPending {
                dirs[d].eotPending = false
                finish(direction: d, checksum: b)
            } else if b == 0x02 {
                dirs[d].blockLengthPending = true
            } else if b == 0x04 {
                dirs[d].eotPending = true
            } else {
                notes.append("Unerwartetes Byte \(b) in den Nachrichtendaten: Rest dieser Richtung nicht auswertbar")
                dirs[d].mode = .lost
            }
        case .lost:
            break
        }
    }

    /// EOT: Summe aller Datenbytes plus Prüfbyte muss 0 (Modulo 256) ergeben; dann entpacken
    private mutating func finish(direction d: Int, checksum: UInt8) {
        let sum = dirs[d].data.reduce(0) { ($0 + Int($1)) & 0xFF } + Int(checksum)
        let compressed = dirs[d].data
        dirs[d].data = []
        dirs[d].mode = .lines
        dirs[d].line.removeAll()
        let checksumOK = sum & 0xFF == 0
        guard decodeContent else {
            notes.append("Nachricht „\(dirs[d].title)“ (\(compressed.count) Byte) nicht gelesen: Entpacken ist abgeschaltet")
            return
        }
        guard let result = LZHUF.decode(compressed), result.complete else {
            notes.append("Nachricht „\(dirs[d].title)“ nicht entpackbar (\(compressed.count) Byte)")
            return
        }
        guard var message = WinlinkParser.parseMessage(result.data, compressedSize: compressed.count) else {
            notes.append("Nachricht „\(dirs[d].title)“ entpackt, aber das Format ist unbekannt")
            return
        }
        if !checksumOK || !result.checksumOK { notes.append("Prüfsumme der Nachricht „\(message.subject)“ stimmt nicht: Inhalt kann fehlerhaft sein") }
        message.received = clock
        messages.append(message)
        // Dem Vorschlag mit gleicher Kennung zuordnen, sonst dem ersten wartenden
        let i = proposals[d].firstIndex(where: { $0.mid == message.mid && !$0.delivered })
            ?? proposals[d].firstIndex(where: { !$0.delivered && $0.answer != "-" && $0.code == "C" })
        if let i { proposals[d][i].delivered = true }
    }

    private mutating func handle(line: String, raw: [UInt8], direction d: Int) {
        if let sid = MailSID(line: line) {
            sids[d] = sid
            return
        }
        if line.hasPrefix(";PQ") { secureChallenge = true; return }
        if line.hasPrefix(";") || line.isEmpty { return }
        guard line.first == "F", line.count >= 2 else { return }
        let command = line.prefix(2)
        switch command {
        case "FA", "FB", "FC", "FD":
            dirs[d].blockChecksum += raw.reduce(0) { $0 + Int($1) } + 0x0D
            let code = line[line.index(line.startIndex, offsetBy: 1)]
            let fields = line.dropFirst(3).split(separator: " ").map(String.init)
            var p = MailProposal(code: code, type: fields.first ?? "", mid: "", size: 0, compressedSize: 0, line: line)
            if code == "C" || code == "D" {
                // FC EM <MID> <Größe> <gepackt> 0
                if fields.count >= 4 {
                    p.mid = fields[1]
                    p.size = Int(fields[2]) ?? 0
                    p.compressedSize = Int(fields[3]) ?? 0
                }
            } else {
                // FB P <von> <über> <Ziel@> <Ziel> <Kennung> <Größe>
                p.mid = fields.count >= 6 ? fields[5] : "\(proposals[d].count + 1)"
                p.size = fields.last.flatMap { Int($0) } ?? 0
            }
            if p.mid.isEmpty { p.mid = "\(proposals[d].count + 1)" }
            proposals[d].append(p)
        case "F>":
            let sum = (-dirs[d].blockChecksum) & 0xFF
            if let their = Int(line.dropFirst(2).trimmingCharacters(in: .whitespaces), radix: 16), their != sum {
                checksumErrors += 1
                notes.append("Prüfsumme der Vorschläge falsch (soll \(String(format: "%02X", sum)), gehört \(String(format: "%02X", their)))")
            }
            dirs[d].blockChecksum = 0
        case "FS":
            // Antworten der Gegenstelle auf deren Vorschläge in der anderen Richtung: je Zeichen einer
            let other = 1 - d
            var chars = Array(line.dropFirst(2).trimmingCharacters(in: .whitespaces))
            var open = proposals[other].indices.filter { proposals[other][$0].answer == nil }
            // Antwort mit Versatz („!“ oder „A“ vor dem Zeichen) ignorieren wir: nur die Zeichen + − = Y N L zählen
            chars = chars.filter { "+-=YNLyynl".contains($0) }
            for c in chars {
                guard !open.isEmpty else { break }
                let i = open.removeFirst()
                switch c {
                case "+", "Y", "y": proposals[other][i].answer = "+"
                case "-", "N", "n": proposals[other][i].answer = "-"
                default: proposals[other][i].answer = "="
                }
            }
        default:
            break
        }
    }
}
