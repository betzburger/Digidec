// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Erzeugt Packet-Radio-Rahmen für Tests und den Demo-Prüfstand (`Tools/MakeSignal`): Bake, Knotenliste, Digipeater,
/// eine Mailbox-Verbindung und eine Winlink-Sitzung mit Nachricht und Anhang. Alle Rufzeichen sind frei erfunden.
public enum PacketSignalGenerator {
    /// AX.25-Rahmen; `command` setzt die C-Bits (Befehl: Ziel gesetzt, Antwort: Quelle gesetzt, nil: beide frei)
    public static func frame(_ src: String, _ dst: String, control: UInt8, command: Bool? = true, pid: UInt8? = nil,
                             info: [UInt8] = [], via: [String] = []) -> AX25Frame {
        var d = AX25Address(text: dst)!, s = AX25Address(text: src)!
        if let command { d.repeated = command; s.repeated = !command }
        let digis = via.map { v -> AX25Address in
            var a = AX25Address(text: v.replacingOccurrences(of: "*", with: ""))!
            a.repeated = v.hasSuffix("*")
            return a
        }
        return AX25Frame(dest: d, source: s, digis: digis, control: control, pid: pid, info: info)
    }

    public static func iControl(ns: Int, nr: Int, poll: Bool = false) -> UInt8 { UInt8((nr & 7) << 5 | (poll ? 0x10 : 0) | (ns & 7) << 1) }
    public static func rrControl(nr: Int) -> UInt8 { UInt8((nr & 7) << 5 | 0x01) }
    public static let sabm: UInt8 = 0x3F, ua: UInt8 = 0x73, disc: UInt8 = 0x53, dm: UInt8 = 0x1F, ui: UInt8 = 0x03

    // MARK: Winlink

    /// Nachricht im Winlink-Format (Kopfzeilen, Leerzeile, Text, Anhänge)
    public static func winlinkMessage(mid: String, from: String, to: [String], subject: String, body: String, date: String,
                                      attachments: [(name: String, data: [UInt8])] = [], mbo: String = "") -> [UInt8] {
        var head = "Mid: \(mid)\r\nBody: \(body.utf8.count)\r\nContent-Transfer-Encoding: 8bit\r\nContent-Type: text/plain; charset=UTF-8\r\nDate: \(date)\r\n"
        for a in attachments { head += "File: \(a.data.count) \(a.name)\r\n" }
        head += "From: \(from)\r\n"
        if !mbo.isEmpty { head += "Mbo: \(mbo)\r\n" }
        head += "Subject: \(subject)\r\n"
        for t in to { head += "To: \(t)\r\n" }
        head += "Type: Private\r\n\r\n"
        var raw = Array(head.utf8) + Array(body.utf8) + [0x0D, 0x0A]
        for a in attachments { raw += a.data + [0x0D, 0x0A] }
        return raw
    }

    /// Prüfsumme hinter `F>`: negierte Summe aller Vorschlagszeilen samt CR, zwei Hexziffern
    public static func proposalChecksum(_ lines: [String]) -> String {
        var sum = 0
        for l in lines { sum += l.utf8.reduce(0) { $0 + Int($1) } + 0x0D }
        return String(format: "%02X", (-sum) & 0xFF)
    }

    /// Datenblöcke einer Nachricht: SOH, Kopf (Titel, Versatz), STX-Blöcke zu höchstens 250 Byte, EOT mit Prüfbyte
    public static func dataBlocks(title: String, compressed: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x01, UInt8(title.utf8.count + 3)] + Array(title.utf8) + [0] + Array("0".utf8) + [0]
        var sum = 0
        var i = 0
        while i < compressed.count {
            let n = min(250, compressed.count - i)
            out += [0x02, UInt8(n)] + compressed[i..<(i + n)]
            for b in compressed[i..<(i + n)] { sum += Int(b) }
            i += n
        }
        return out + [0x04, UInt8((-sum) & 0xFF)]
    }

    /// Eine Winlink-Verbindung (Kunde ruft Gateway, Gateway liefert eine Nachricht): Aufbau, Kennungen, Vorschlag, Antwort, Datenblöcke, Abbau
    public static func winlinkSession(client: String, gateway: String, via: [String] = [], raw: [UInt8], mid: String, title: String,
                                      frameSize: Int = 128) -> [AX25Frame] {
        let packed = LZHUF.encodeLiterals(raw)
        var frames: [AX25Frame] = []
        var nsG = 0, nsC = 0
        func g(_ bytes: [UInt8]) {
            frames.append(frame(gateway, client, control: iControl(ns: nsG, nr: nsC), command: true, pid: 0xF0, info: bytes, via: via.reversed().map { $0 + "*" }))
            nsG += 1
        }
        func c(_ text: String) {
            frames.append(frame(client, gateway, control: iControl(ns: nsC, nr: nsG), command: true, pid: 0xF0, info: Array(text.utf8), via: via))
            nsC += 1
        }
        func ack(from: String, to: String, nr: Int) { frames.append(frame(from, to, control: rrControl(nr: nr), command: false)) }
        frames.append(frame(client, gateway, control: sabm, via: via))
        frames.append(frame(gateway, client, control: ua, command: false, via: via.reversed().map { $0 + "*" }))
        g(Array("[WL2K-5.0-B2FWIHJM$]\r;PQ: 12345678\rCMS via \(gateway) >\r".utf8))
        c("[Pat-0.15-B2FHM$]\r;PR: 98765432\r; \(gateway) DE \(client) (JN49WS)\r")
        let fc = "FC EM \(mid) \(raw.count) \(packed.count) 0"
        g(Array((fc + "\rF> " + proposalChecksum([fc]) + "\r").utf8))
        c("FS +\r")
        let stream = dataBlocks(title: title, compressed: packed)
        var i = 0
        while i < stream.count {
            let n = min(frameSize, stream.count - i)
            g(Array(stream[i..<(i + n)]))
            i += n
            if (i / frameSize) % 4 == 0 { ack(from: client, to: gateway, nr: nsG) }
        }
        c("FF\r")
        g(Array("FQ\r".utf8))
        frames.append(frame(client, gateway, control: disc, via: via))
        frames.append(frame(gateway, client, control: ua, command: false, via: via.reversed().map { $0 + "*" }))
        return frames
    }

    // MARK: NET/ROM

    /// Sieben „verschobene“ Adressbytes
    static func shifted(_ call: String, _ ssid: Int) -> [UInt8] {
        var b = Array(call.utf8.prefix(6)).map { $0 << 1 }
        while b.count < 6 { b.append(0x40) }
        return b + [UInt8(0x60 | ssid << 1)]
    }

    public static func nodesBroadcast(from: String, alias: String, entries: [(call: String, ssid: Int, alias: String, neighbour: String, quality: Int)]) -> AX25Frame {
        func pad(_ a: String) -> [UInt8] { Array(a.utf8.prefix(6)) + [UInt8](repeating: 0x20, count: max(0, 6 - a.utf8.count)) }
        var body: [UInt8] = [0xFF] + pad(alias)
        for e in entries { body += shifted(e.call, e.ssid) + pad(e.alias) + shifted(e.neighbour, 0) + [UInt8(e.quality)] }
        return frame(from, "NODES", control: ui, command: true, pid: 0xCF, info: body)
    }

    // MARK: Demo

    /// Ein Ausschnitt aus einem belebten Kanal: Baken, Knotenliste, Digipeater, Mailbox-Verbindung und Winlink-Sitzung
    public static func demoFrames() -> [AX25Frame] {
        var frames: [AX25Frame] = []
        func text(_ s: String) -> [UInt8] { Array(s.utf8) }
        frames.append(frame("DB0MAI", "BEACON", control: ui, pid: 0xF0, info: text("DB0MAI-1 Mailbox Wuerzburg JN49WS - C DB0MAI-1")))
        frames.append(nodesBroadcast(from: "DB0NOD", alias: "WUE", entries: [
            ("DB0MAI", 1, "MAIL", "DB0NOD", 200), ("DB0FRA", 0, "FRA", "DB0NOD", 150), ("DB0HEI", 0, "HEI", "DB0FRA", 90)]))
        frames.append(frame("DL2XYZ", "CQ", control: ui, pid: 0xF0, info: text("CQ CQ de DL2XYZ Packet-Test"), via: ["DB0ABC*", "DB0DEF*", "WIDE2-1"]))
        frames.append(frame("DL4QRP", "CQ", control: ui, pid: 0xF0, info: text("QRV 144.8125 - 73"), via: ["DB0DEF*"]))
        // Mailbox: Anmeldung, Befehl, Weiterleitungsvorschlag
        frames.append(frame("DL3ZZZ", "DB0MAI-1", control: sabm))
        frames.append(frame("DB0MAI-1", "DL3ZZZ", control: ua, command: false))
        frames.append(frame("DB0MAI-1", "DL3ZZZ", control: iControl(ns: 0, nr: 0), pid: 0xF0, info: text("[LinFBB-7.0.11-AB1FHMRX$]\rWillkommen bei DB0MAI, Wuerzburg\rDL3ZZZ de DB0MAI-1 >\r")))
        frames.append(frame("DL3ZZZ", "DB0MAI-1", control: iControl(ns: 0, nr: 1), pid: 0xF0, info: text("L\r")))
        frames.append(frame("DB0MAI-1", "DL3ZZZ", control: iControl(ns: 1, nr: 1), pid: 0xF0, info: text("12 DL1ABC  06.10. Treffen Freitag\r11 DL5XYZ  05.10. Relais gestoert\r>\r")))
        frames.append(frame("DL3ZZZ", "DB0MAI-1", control: iControl(ns: 1, nr: 2), pid: 0xF0, info: text("B\r")))
        frames.append(frame("DL3ZZZ", "DB0MAI-1", control: disc))
        frames.append(frame("DB0MAI-1", "DL3ZZZ", control: ua, command: false))
        // Winlink über einen Digipeater
        let attachment = (0..<600).map { UInt8(($0 * 13 + 5) & 0xFF) }
        let raw = winlinkMessage(mid: "DEMO5H2K9XQ7", from: "DL1ABC", to: ["DL9OFC"], subject: "Lagemeldung Hochwasser", body:
            "Pegel Main Wuerzburg 4,10 m, steigend.\r\nSandsaecke an der Bruecke werden verteilt.\r\n\r\n73 de DL1ABC", date: "2026/10/06 08:15",
            attachments: [("pegel.bin", attachment)], mbo: "DB0XYZ")
        frames += winlinkSession(client: "DL1ABC", gateway: "DB0XYZ-10", via: ["DB0REL"], raw: raw, mid: "DEMO5H2K9XQ7", title: "Lagemeldung Hochwasser")
        return frames
    }
}
