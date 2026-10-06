// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - Ergebnisse der Auswertung

/// Eine gehörte Station (wie die MHEARD-Liste eines Packet-Programms)
public struct PacketStation: Identifiable, Equatable, Sendable {
    public var id: String { call }
    public var call: String
    public var firstHeard: Date
    public var lastHeard: Date
    /// Rahmen, die diese Station als Absender gesendet hat
    public var frames = 0
    /// Zuletzt direkt gehört (kein Digipeater dazwischen)
    public var direct = true
    /// Weg des letzten Rahmens („DB0ABC*,DB0DEF“)
    public var lastPath: [String] = []
    /// NET/ROM-Name („DBOSYS“) aus den Knotenlisten
    public var alias: String?
    /// Letzter ungesicherter Text (Bake, Mailbox-Kennung)
    public var lastText: String?
    /// Kennung, mit der sich die Station in einer Verbindung vorgestellt hat (Mailbox, Winlink-Gateway)
    public var sid: MailSID?
    /// Hat als Digipeater Rahmen weitergegeben
    public var isDigipeater = false
    public var sessions = 0

    public var role: String {
        if sid?.isWinlink == true { return "Winlink" }
        if sid != nil { return "Mailbox" }
        if isDigipeater { return "Digipeater" }
        if alias != nil { return "Knoten" }
        return ""
    }
}

public struct PacketDigipeater: Identifiable, Equatable, Sendable {
    public var id: String { call }
    public var call: String
    public var firstHeard: Date
    public var lastHeard: Date
    /// Rahmen, bei denen dieser Digipeater der gehörte Sender war (letztes gesetztes H-Bit)
    public var heard = 0
    /// Rahmen, in deren Weg er bereits weitergegeben hatte
    public var inPath = 0
    /// Absender, deren Rahmen er weitergegeben hat
    public var sources: Set<String> = []
    /// Verwendete Wege-Namen vor seiner Weitergabe („WIDE1-1“)
    public var heardDirectly = false
}

/// Eine Zeile im Zeitprotokoll des Monitors
public struct PacketMonitorEntry: Identifiable, Sendable {
    public let id = UUID()
    public var time: Date
    public var frame: AX25Frame
    public var repaired: Bool
    public var level: Double

    public var line: String { frame.monitorLine + (repaired ? "  ~" : "") }
}

public struct PacketNodeEntry: Identifiable, Equatable, Sendable {
    public var id: String { call }
    public var call: String
    public var alias: String
    public var quality: Int
    public var neighbour: String
    /// Von welchem Knoten gehört (Absender der Knotenliste)
    public var heardFrom: String
    public var lastHeard: Date
}

public struct PacketSessionLine: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case text, binary, note }
    public let id = UUID()
    public var time: Date
    /// 0: Anrufer → Gegenstelle, 1: Gegenstelle → Anrufer
    public var direction: Int
    public var text: String
    public var kind: Kind = .text
}

/// Eine Verbindung (connected mode) zwischen zwei Stationen, so weit mitgehört
public struct PacketSession: Identifiable, Sendable {
    public enum State: Sendable {
        /// Verbindungswunsch gehört, Bestätigung fehlt noch
        case connecting
        case connected
        case closed
        /// Gegenstelle hat abgelehnt (DM)
        case refused
        /// Mitten in einer Verbindung eingeschaltet (Aufbau nicht gehört)
        case observed
    }

    public let id: Int
    public var caller: String
    public var callee: String
    public var via: [String]
    public var state: State
    public var started: Date
    public var lastActivity: Date
    public var ended: Date?
    /// Verbindungsabbau (DISC) gehört; die Bestätigung steht noch aus
    var closing = false
    public var frames = 0
    public var infoFrames = 0
    public var retransmissions = 0
    public var gaps = 0
    /// Nutzbytes je Richtung
    public var bytes = [0, 0]
    public private(set) var lines: [PacketSessionLine] = []
    public var mail = MailTracker()

    // Zustand der Zeilenbildung
    fileprivate var partial: [[UInt8]] = [[], []]
    fileprivate var partialTime = [Date(), Date()]
    fileprivate var binaryBytes = [0, 0]
    fileprivate var sequence = [Sequence(), Sequence()]

    fileprivate struct Sequence: Sendable {
        var recent: [(ns: Int, hash: Int)] = []
        var expected: Int?
    }

    public static let maxLines = 500

    public var key: String { PacketAnalyzer.pairKey(caller, callee) }
    public var isOpen: Bool { state == .connecting || state == .connected || state == .observed }

    public enum Kind: Sendable { case winlink, mailbox, text }
    public var kind: Kind {
        if mail.isWinlink { return .winlink }
        if mail.sids.contains(where: { $0 != nil }) { return .mailbox }
        return .text
    }

    public var title: String { "\(caller) ↔ \(callee)" + (via.isEmpty ? "" : " via " + via.joined(separator: ",")) }

    /// Alle Zeilen als Text (für Kopieren und Speichern)
    public var transcript: String {
        lines.map { l in (l.kind == .note ? "# " : l.direction == 0 ? "→ " : "← ") + l.text }.joined(separator: "\n")
    }

    mutating func addLine(_ l: PacketSessionLine) {
        lines.append(l)
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }

    /// Angefangene Zeile einer Richtung abschließen
    mutating func flush(_ d: Int) {
        if !partial[d].isEmpty {
            addLine(PacketSessionLine(time: partialTime[d], direction: d, text: PacketText.visible(partial[d])))
            partial[d].removeAll()
        }
        if binaryBytes[d] > 0 {
            addLine(PacketSessionLine(time: partialTime[d], direction: d, text: "‹Nachrichtendaten, \(binaryBytes[d]) Byte›", kind: .binary))
            binaryBytes[d] = 0
        }
    }

    /// Nutzdaten einer Richtung einarbeiten: Zeilen bilden (Zeilenende = CR), Winlink-Datenblöcke nur zählen
    mutating func append(direction d: Int, bytes: [UInt8], at time: Date) {
        self.bytes[d] += bytes.count
        mail.clock = time
        for b in bytes {
            let wasBinary = mail.isBinary(d)
            mail.feed(d, [b])
            if wasBinary || mail.isBinary(d) {
                if partial[d].isEmpty == false { flush(d) }
                binaryBytes[d] += 1
                partialTime[d] = time
                continue
            }
            if binaryBytes[d] > 0 { flush(d) }
            if partial[d].isEmpty { partialTime[d] = time }
            if b == 0x0D {
                addLine(PacketSessionLine(time: partialTime[d], direction: d, text: PacketText.visible(partial[d])))
                partial[d].removeAll(keepingCapacity: true)
            } else if b != 0x0A {
                partial[d].append(b)
                if partial[d].count >= 400 { flush(d) }
            }
        }
    }

    mutating func note(_ text: String, at time: Date) {
        flush(0)
        flush(1)
        addLine(PacketSessionLine(time: time, direction: 0, text: text, kind: .note))
    }
}

// MARK: - Auswertung

/// Was beim Einarbeiten eines Rahmens als Neuigkeit entstand (für das Protokoll)
public enum PacketEvent: Sendable {
    case message(session: Int, WinlinkMessage)
}

/// Wertet alle empfangenen AX.25-Rahmen aus: Stationen, Digipeater, Verbindungen mit Gesprächsverlauf, NET/ROM-Knoten, Winlink-Nachrichten.
/// Reine Rechenlogik ohne Oberfläche und Audio (Logiktests).
public struct PacketAnalyzer: Sendable {
    public private(set) var stations: [String: PacketStation] = [:]
    public private(set) var digipeaters: [String: PacketDigipeater] = [:]
    public private(set) var nodes: [String: PacketNodeEntry] = [:]
    public private(set) var sessions: [PacketSession] = []
    public private(set) var frameCount = 0
    public private(set) var uiCount = 0
    /// Winlink-Nachrichten entpacken und lesen (aus: nur zählen)
    public var decodeMessages = true
    /// Zähler je Rahmenart („I“, „UI“, „SABM“ …)
    public private(set) var typeCounts: [String: Int] = [:]
    /// Wie viele Winlink-Nachrichten schon gemeldet wurden (für das Protokoll)
    private var reportedMessages: [Int: Int] = [:]
    private var open: [String: Int] = [:]
    private var nextSessionID = 1

    public static let maxSessions = 200
    public static let maxStations = 2000
    /// Verbindung ohne Rahmen so lange gilt als beendet (ohne dass der Abbau zu hören war)
    public static let idleTimeout: TimeInterval = 1800

    public init() {}

    public static func pairKey(_ a: String, _ b: String) -> String { a < b ? a + "|" + b : b + "|" + a }

    /// Allgemeine Weg-Namen, die keine Stationen sind (WIDE1-1, RELAY, TCPIP …)
    public static func isGenericAlias(_ call: String) -> Bool {
        let base = call.split(separator: "-").first.map(String.init) ?? call
        if ["RELAY", "ECHO", "GATE", "TRACE", "NOGATE", "RFONLY", "TCPIP", "TCPXX", "CQ", "QST", "ID", "BEACON", "MAIL", "NODES"].contains(base) { return true }
        if base.hasPrefix("WIDE") || base.hasPrefix("TRACE") || base.hasPrefix("TCP") || base.hasPrefix("QA") { return true }
        return false
    }

    public var sortedSessions: [PacketSession] { sessions.sorted { $0.lastActivity > $1.lastActivity } }

    /// Alle bisher entpackten Winlink-Nachrichten mit der Sitzung, in der sie gehört wurden
    public var messages: [(session: PacketSession, message: WinlinkMessage)] {
        sessions.flatMap { s in s.mail.messages.map { (s, $0) } }
    }

    // MARK: Rahmen aufnehmen

    /// Einen Rahmen mit gültiger Prüfsumme einarbeiten. Reparierte Rahmen (`repaired`) kommen nur in die Zähler, nie in Sitzungen und Stationen.
    @discardableResult
    public mutating func ingest(_ frame: AX25Frame, at now: Date, repaired: Bool = false) -> [PacketEvent] {
        frameCount += 1
        let ctl = frame.ctl
        typeCounts[ctl.type.rawValue, default: 0] += 1
        guard !repaired else { return [] }
        updateStations(frame, at: now)
        var events: [PacketEvent] = []
        switch ctl.type {
        case .unnumberedInfo:
            uiCount += 1
            handleUI(frame, at: now)
        case .connect, .connectExtended, .acknowledge, .disconnect, .disconnectedMode, .information, .receiveReady, .receiveNotReady, .reject, .selectiveReject, .frameReject:
            events = handleLink(frame, at: now)
        default:
            break
        }
        return events
    }

    // MARK: Stationen und Digipeater

    private mutating func updateStations(_ f: AX25Frame, at now: Date) {
        let src = f.source.text
        var s = stations[src] ?? PacketStation(call: src, firstHeard: now, lastHeard: now)
        s.lastHeard = now
        s.frames += 1
        s.direct = f.isDirect
        s.lastPath = f.digis.map { $0.text + ($0.repeated ? "*" : "") }
        stations[src] = s
        if stations.count > Self.maxStations { pruneStations() }

        let repeaters = f.repeaters.filter { !Self.isGenericAlias($0.call) }
        for (i, r) in repeaters.enumerated() {
            var d = digipeaters[r.text] ?? PacketDigipeater(call: r.text, firstHeard: now, lastHeard: now)
            d.lastHeard = now
            d.inPath += 1
            d.sources.insert(src)
            if i == repeaters.count - 1 { d.heard += 1 }
            digipeaters[r.text] = d
            var st = stations[r.text] ?? PacketStation(call: r.text, firstHeard: now, lastHeard: now)
            st.isDigipeater = true
            st.lastHeard = now
            stations[r.text] = st
        }
        // Eine Station, die auch selbst gesendet wird, wird als „direkt gehört“ vermerkt
        if var d = digipeaters[src] { d.heardDirectly = true; digipeaters[src] = d }
    }

    private mutating func pruneStations() {
        let keep = stations.values.sorted { $0.lastHeard > $1.lastHeard }.prefix(Self.maxStations * 9 / 10)
        stations = Dictionary(uniqueKeysWithValues: keep.map { ($0.call, $0) })
    }

    // MARK: Ungesicherte Rahmen

    private mutating func handleUI(_ f: AX25Frame, at now: Date) {
        guard let pid = f.pid else { return }
        if pid == PacketPID.netrom, f.dest.call == "NODES", let list = NetRom.parseNodes(f.info) {
            let sender = f.source.text
            stations[sender]?.alias = list.sender.isEmpty ? nil : list.sender
            for n in list.nodes {
                nodes[n.call] = PacketNodeEntry(call: n.call, alias: n.alias, quality: n.quality, neighbour: n.neighbour, heardFrom: sender, lastHeard: now)
                if stations[n.call] == nil { continue }
                stations[n.call]?.alias = n.alias
            }
            return
        }
        if pid == PacketPID.text {
            let text = f.visibleInfo.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { stations[f.source.text]?.lastText = String(text.prefix(200)) }
        }
    }

    // MARK: Verbindungen

    private mutating func handleLink(_ f: AX25Frame, at now: Date) -> [PacketEvent] {
        let a = f.source.text, b = f.dest.text
        let key = Self.pairKey(a, b)
        let ctl = f.ctl
        var events: [PacketEvent] = []

        // Sitzung suchen oder anlegen
        var index = open[key]
        if let i = index, !sessions[i].isOpen { open[key] = nil; index = nil }
        switch ctl.type {
        case .connect, .connectExtended:
            if let i = index, sessions[i].state == .connecting, sessions[i].caller == a {
                // Wiederholter Verbindungswunsch
                sessions[i].frames += 1
                sessions[i].lastActivity = now
                return []
            }
            if let i = index { close(i, at: now, note: "Neuer Verbindungswunsch: alte Verbindung beendet") }
            let via = f.digis.map { $0.text }
            let s = PacketSession(id: nextSessionID, caller: a, callee: b, via: via, state: .connecting, started: now, lastActivity: now)
            nextSessionID += 1
            sessions.append(s)
            open[key] = sessions.count - 1
            sessions[sessions.count - 1].frames = 1
            stations[a]?.sessions += 1
            stations[b]?.sessions += 1
            trimSessions()
            return []
        case .receiveReady, .receiveNotReady, .reject, .selectiveReject, .frameReject:
            // Quittungen zählen nur, wenn die Verbindung schon bekannt ist
            if let i = index {
                sessions[i].frames += 1
                sessions[i].lastActivity = now
            }
            return []
        default:
            break
        }
        if index == nil {
            // Verbindung nicht von Anfang an gehört (nur Daten, UA oder Abbau mit Daten): nur Daten- und Abbaurahmen legen eine „mitgehörte“ Sitzung an
            guard ctl.type == .information else { return [] }
            var s = PacketSession(id: nextSessionID, caller: a, callee: b, via: f.digis.map { $0.text }, state: .observed, started: now, lastActivity: now)
            s.note("Verbindungsaufbau nicht gehört: Anrufer und Gegenstelle sind geraten", at: now)
            nextSessionID += 1
            sessions.append(s)
            open[key] = sessions.count - 1
            index = sessions.count - 1
            stations[a]?.sessions += 1
            stations[b]?.sessions += 1
            trimSessions()
        }
        guard let i = index, i < sessions.count else { return [] }
        sessions[i].frames += 1
        sessions[i].lastActivity = now
        sessions[i].mail.decodeContent = decodeMessages
        let direction = a == sessions[i].caller ? 0 : 1

        switch ctl.type {
        case .acknowledge:
            if sessions[i].closing {
                close(i, at: now, note: nil)
            } else if sessions[i].state == .connecting, a == sessions[i].callee {
                sessions[i].state = .connected
            }
        case .disconnectedMode:
            if sessions[i].state == .connecting {
                sessions[i].state = .refused
                sessions[i].ended = now
                open[key] = nil
            } else {
                close(i, at: now, note: nil)
            }
        case .disconnect:
            sessions[i].closing = true
        case .information:
            sessions[i].infoFrames += 1
            if sessions[i].state == .connecting { sessions[i].state = .connected }   // Bestätigung nicht gehört
            let ns = ctl.ns ?? 0
            let hash = f.info.hashValue
            if sessions[i].sequence[direction].recent.contains(where: { $0.ns == ns && $0.hash == hash }) {
                sessions[i].retransmissions += 1
            } else {
                var gap = false
                if let expected = sessions[i].sequence[direction].expected, expected != ns { gap = true }
                if gap {
                    sessions[i].gaps += 1
                    sessions[i].flush(direction)
                    sessions[i].note("‹Lücke: Rahmen verpasst›", at: now)
                    sessions[i].mail.gap(direction)
                }
                sessions[i].sequence[direction].recent.append((ns, hash))
                if sessions[i].sequence[direction].recent.count > 7 { sessions[i].sequence[direction].recent.removeFirst() }
                sessions[i].sequence[direction].expected = (ns + 1) & 7
                // Die andere Richtung abschließen, damit ein Wechsel im Gespräch als eigene Zeile erscheint
                sessions[i].flush(1 - direction)
                if f.pid == PacketPID.text || f.pid == nil {
                    sessions[i].append(direction: direction, bytes: f.info, at: now)
                } else if let pid = f.pid {
                    sessions[i].flush(direction)
                    sessions[i].addLine(PacketSessionLine(time: now, direction: direction, text: f.pidSummary ?? "‹\(PacketPID.name(pid)), \(f.info.count) Byte›"))
                    sessions[i].bytes[direction] += f.info.count
                }
                events += collectMail(i, at: now)
            }
        default:
            break
        }
        // Kennung der Gegenstelle für die Stationsliste
        for d in 0..<2 {
            if let sid = sessions[i].mail.sids[d] {
                let call = d == 0 ? sessions[i].caller : sessions[i].callee
                if stations[call]?.sid != sid { stations[call]?.sid = sid }
            }
        }
        return events
    }

    /// Neue Nachrichten dieser Sitzung als Ereignisse melden
    private mutating func collectMail(_ i: Int, at now: Date) -> [PacketEvent] {
        let id = sessions[i].id
        let reported = reportedMessages[id] ?? 0
        let all = sessions[i].mail.messages
        guard all.count > reported else { return [] }
        reportedMessages[id] = all.count
        return all[reported...].map { .message(session: id, $0) }
    }

    private mutating func close(_ i: Int, at now: Date, note: String?) {
        sessions[i].flush(0)
        sessions[i].flush(1)
        sessions[i].state = .closed
        sessions[i].ended = now
        sessions[i].closing = false
        open[sessions[i].key] = nil
        if let note { sessions[i].note(note, at: now) }
    }

    private mutating func trimSessions() {
        guard sessions.count > Self.maxSessions else { return }
        // Älteste geschlossene zuerst entfernen
        let drop = sessions.count - Self.maxSessions * 9 / 10
        var removed = 0
        sessions.removeAll { s in
            if removed < drop, !s.isOpen { removed += 1; return true }
            return false
        }
        open = [:]
        for (i, s) in sessions.enumerated() where s.isOpen { open[s.key] = i }
    }

    /// Verbindungen ohne Rahmen seit `idleTimeout` als beendet führen
    public mutating func housekeeping(now: Date) {
        for i in sessions.indices where sessions[i].isOpen && now.timeIntervalSince(sessions[i].lastActivity) > Self.idleTimeout {
            close(i, at: sessions[i].lastActivity, note: "Kein Rahmen mehr gehört: Verbindung gilt als beendet")
        }
    }

    public mutating func clear() {
        self = PacketAnalyzer()
    }
}
