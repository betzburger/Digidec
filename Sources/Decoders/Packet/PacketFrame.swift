// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - AX.25-Steuerfeld

/// Rahmenart nach AX.25 v2.2 (Modulo 8): Information, Überwachung (S) und nummerierungslose (U) Rahmen
public enum AX25FrameType: String, Sendable {
    case information = "I"
    case receiveReady = "RR", receiveNotReady = "RNR", reject = "REJ", selectiveReject = "SREJ"
    case connect = "SABM", connectExtended = "SABME", disconnect = "DISC"
    case acknowledge = "UA", disconnectedMode = "DM"
    case unnumberedInfo = "UI", frameReject = "FRMR", exchangeID = "XID", test = "TEST"
    case unknown = "?"

    /// Kurz erklärt für Hinweistexte
    public var meaning: String {
        switch self {
        case .information: return "Information (Nutzdaten in einer Verbindung)"
        case .receiveReady: return "Empfangsbereit (Quittung)"
        case .receiveNotReady: return "Nicht empfangsbereit"
        case .reject: return "Wiederholung ab Nummer verlangt"
        case .selectiveReject: return "Wiederholung eines Rahmens verlangt"
        case .connect: return "Verbindungswunsch"
        case .connectExtended: return "Verbindungswunsch (erweitert, Modulo 128)"
        case .disconnect: return "Verbindungsabbau"
        case .acknowledge: return "Bestätigung (Verbindung steht / ist abgebaut)"
        case .disconnectedMode: return "Keine Verbindung (abgelehnt oder nicht bestehend)"
        case .unnumberedInfo: return "Ungesicherte Aussendung (Bake, APRS, Rundspruch)"
        case .frameReject: return "Rahmen abgelehnt"
        case .exchangeID: return "Austausch der Fähigkeiten"
        case .test: return "Testrahmen"
        case .unknown: return "Unbekannt"
        }
    }
}

public struct AX25Control: Equatable, Sendable {
    public var type: AX25FrameType
    /// Sendefolgenummer N(S) (nur I-Rahmen) und Empfangsfolgenummer N(R) (I- und S-Rahmen), je 0–7
    public var ns: Int?
    public var nr: Int?
    /// Poll/Final-Bit
    public var pollFinal: Bool

    /// Steuerfeld mit einem Byte (Modulo 8). Erweiterte Sitzungen (SABME, Modulo 128) haben ein zweites Byte und werden hier nicht ausgewertet.
    public init(byte c: UInt8) {
        pollFinal = c & 0x10 != 0
        ns = nil
        nr = nil
        if c & 0x01 == 0 {
            type = .information
            ns = Int((c >> 1) & 7)
            nr = Int((c >> 5) & 7)
        } else if c & 0x03 == 0x01 {
            switch (c >> 2) & 3 {
            case 0: type = .receiveReady
            case 1: type = .receiveNotReady
            case 2: type = .reject
            default: type = .selectiveReject
            }
            nr = Int((c >> 5) & 7)
        } else {
            switch c & 0xEF {
            case 0x2F: type = .connect
            case 0x6F: type = .connectExtended
            case 0x43: type = .disconnect
            case 0x63: type = .acknowledge
            case 0x0F: type = .disconnectedMode
            case 0x03: type = .unnumberedInfo
            case 0x87: type = .frameReject
            case 0xAF: type = .exchangeID
            case 0xE3: type = .test
            default: type = .unknown
            }
        }
    }
}

/// Befehl oder Antwort (aus den C-Bits der Adressen: Ziel gesetzt = Befehl, Quelle gesetzt = Antwort; beide gleich = alte Fassung v1)
public enum AX25Role: Sendable { case command, response, legacy }

public enum PacketPID {
    /// „Kein Layer 3“: gewöhnlicher Text
    public static let text: UInt8 = 0xF0
    public static let netrom: UInt8 = 0xCF

    public static func name(_ pid: UInt8) -> String {
        switch pid {
        case 0xF0: return "Text"
        case 0xCF: return "NET/ROM"
        case 0xCC: return "IP"
        case 0xCD: return "ARP"
        case 0x01: return "X.25 PLP"
        case 0x06: return "TCP/IP komprimiert"
        case 0x07: return "TCP/IP"
        case 0x08: return "Segment"
        case 0xC3: return "TEXNET"
        case 0xC4: return "LQP"
        case 0xCA: return "FlexNet"
        case 0xFF: return "Erweiterung"
        default: return String(format: "PID %02X", pid)
        }
    }
}

extension AX25Frame {
    public var ctl: AX25Control { AX25Control(byte: control) }

    public var role: AX25Role {
        if dest.repeated == source.repeated { return .legacy }
        return dest.repeated ? .command : .response
    }

    /// Der Sender, den man tatsächlich gehört hat: der letzte Digipeater mit gesetztem H-Bit, sonst die Quelle
    public var transmitter: AX25Address {
        digis.last(where: { $0.repeated }) ?? source
    }

    /// Direkt von der Quelle gehört (kein Digipeater hat den Rahmen schon weitergegeben)
    public var isDirect: Bool { !digis.contains(where: { $0.repeated }) }

    /// Alle Digipeater, die den Rahmen schon weitergegeben haben (H-Bit), in Reihenfolge
    public var repeaters: [AX25Address] { digis.filter { $0.repeated } }

    /// Information als Text: UTF-8, sonst Latin-1; Zeilenende (CR) als „⏎“, andere Steuerzeichen als „·“
    public var visibleInfo: String { PacketText.visible(info) }

    /// Monitor-Zeile wie in Packet-Programmen: „DL1ABC>DB0XYZ,DB0ABC* <I C S3 R5 P> Text“
    public var monitorLine: String {
        var s = header + " <" + controlDescription + ">"
        let text = pidSummary ?? visibleInfo
        if !text.isEmpty { s += " " + text }
        return s
    }

    /// „I C S3 R5 P“, „SABM C P“, „UA R F“, „UI C“, „RR R5“
    public var controlDescription: String {
        let c = ctl
        var parts = [c.type.rawValue]
        switch role {
        case .command: parts.append("C")
        case .response: parts.append("R")
        case .legacy: break
        }
        if let ns = c.ns { parts.append("S\(ns)") }
        if let nr = c.nr { parts.append("R\(nr)") }
        if c.pollFinal { parts.append(role == .response ? "F" : "P") }
        if let pid, pid != PacketPID.text, c.type == .information || c.type == .unnumberedInfo { parts.append("pid=" + PacketPID.name(pid)) }
        return parts.joined(separator: " ")
    }

    /// Deutung für Nicht-Text-Protokolle (IP, NET/ROM); nil bei gewöhnlichem Text
    public var pidSummary: String? {
        guard let pid, ctl.type == .information || ctl.type == .unnumberedInfo else { return nil }
        switch pid {
        case PacketPID.netrom:
            if let n = NetRom.parseNodes(info) { return "Knotenliste von \(n.sender): \(n.nodes.count) Ziele" }
            if let l3 = NetRom.parseLayer3(info) { return l3.summary }
            return nil
        case 0xCC, 0x07:
            return PacketIP.summary(info)
        default:
            return nil
        }
    }
}

public enum PacketText {
    /// Text aus Bytes: UTF-8, sonst Latin-1
    public static func decode(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes.map { Character(UnicodeScalar($0)) })
    }

    /// Wie `decode`, aber CR/LF wird „⏎“ und andere Steuerzeichen „·“
    public static func visible(_ bytes: [UInt8]) -> String {
        var out = ""
        for u in decode(bytes).unicodeScalars {
            switch u.value {
            case 0x0D: out += "⏎"
            case 0x0A: break
            case 0..<0x20, 0x7F: out += "·"
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }
}

// MARK: - NET/ROM

public struct NetRomNode: Equatable, Sendable {
    public var call: String
    public var alias: String
    public var neighbour: String
    public var quality: Int
}

public enum NetRom {
    /// Rufzeichen aus sieben „verschobenen“ AX.25-Adressbytes
    static func address(_ b: ArraySlice<UInt8>) -> String? {
        guard b.count == 7 else { return nil }
        let i = b.startIndex
        var call = ""
        for k in 0..<6 {
            let ch = b[i + k] >> 1
            guard ch == 0x20 || (0x21...0x7E).contains(ch) else { return nil }
            if ch != 0x20 { call.append(Character(UnicodeScalar(ch))) }
        }
        guard !call.isEmpty else { return nil }
        let ssid = Int((b[i + 6] >> 1) & 0x0F)
        return ssid == 0 ? call : "\(call)-\(ssid)"
    }

    /// Rundspruch der Knoten (Ziel „NODES“, PID CF, Kennbyte 0xFF): Name des Senders und je 21 Byte Ziel, Name, Nachbar, Güte
    public static func parseNodes(_ info: [UInt8]) -> (sender: String, nodes: [NetRomNode])? {
        guard info.count >= 7, info[0] == 0xFF, (info.count - 7) % 21 == 0 else { return nil }
        let sender = alias(info[1..<7])
        guard !sender.isEmpty || info.count > 7 else { return nil }
        var nodes: [NetRomNode] = []
        var i = 7
        while i + 21 <= info.count {
            guard let call = address(info[i..<(i + 7)]), let neighbour = address(info[(i + 13)..<(i + 20)]) else { return nil }
            nodes.append(NetRomNode(call: call, alias: alias(info[(i + 7)..<(i + 13)]), neighbour: neighbour, quality: Int(info[i + 20])))
            i += 21
        }
        return (sender, nodes)
    }

    private static func alias(_ b: ArraySlice<UInt8>) -> String {
        String(String(bytes: b, encoding: .isoLatin1) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
    }

    public struct Layer3: Equatable, Sendable {
        public var origin: String
        public var destination: String
        public var ttl: Int
        public var opcode: Int
        public var payload: [UInt8]

        public var opcodeName: String {
            switch opcode & 0x0F {
            case 1: return "Verbindungswunsch"
            case 2: return "Verbindung bestätigt"
            case 3: return "Abbau"
            case 4: return "Abbau bestätigt"
            case 5: return "Daten"
            case 6: return "Datenquittung"
            case 0: return "Erweiterung (IP)"
            default: return "Opcode \(opcode & 0x0F)"
            }
        }

        public var summary: String {
            var s = "NET/ROM \(origin) → \(destination) · \(opcodeName)"
            if opcode & 0x0F == 5, !payload.isEmpty { s += ": " + PacketText.visible(payload) }
            return s
        }
    }

    /// Netzwerkkopf (15 Byte: Quelle, Ziel, Lebensdauer) und Transportkopf (5 Byte) eines NET/ROM-Rahmens
    public static func parseLayer3(_ info: [UInt8]) -> Layer3? {
        guard info.count >= 20, let o = address(info[0..<7]), let d = address(info[7..<14]) else { return nil }
        return Layer3(origin: o, destination: d, ttl: Int(info[14]), opcode: Int(info[19]), payload: Array(info[20...]))
    }
}

// MARK: - IP im Packet-Radio (AX.25 PID CC / 07)

public enum PacketIP {
    /// „IP 44.130.1.5 → 44.130.7.2 · TCP · 120 Byte“
    public static func summary(_ b: [UInt8]) -> String? {
        guard b.count >= 20, b[0] >> 4 == 4 else { return nil }
        let proto: String
        switch b[9] {
        case 1: proto = "ICMP"
        case 6: proto = "TCP"
        case 17: proto = "UDP"
        case 4: proto = "IPIP"
        default: proto = "Protokoll \(b[9])"
        }
        func ip(_ o: Int) -> String { "\(b[o]).\(b[o + 1]).\(b[o + 2]).\(b[o + 3])" }
        let length = Int(b[2]) << 8 | Int(b[3])
        return "IP \(ip(12)) → \(ip(16)) · \(proto) · \(length) Byte"
    }
}
