// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Eine Nachricht (Zeile in der Bandaktivität): Rahmen derselben Aussendung, die auf derselben NF-Frequenz in
/// aufeinanderfolgenden Zyklen ankamen, vom ersten bis zum letzten (Übertragungsart „first“ … „last“).
public struct JS8Line: Identifiable, Sendable, Equatable {
    public let id = UUID()
    /// Zyklusbeginn des ersten Rahmens
    public var start: Date
    /// Zyklusbeginn des letzten bisher empfangenen Rahmens
    public var lastCycle: Date
    public var submode: JS8Submode
    /// NF-Frequenz (Mittel der Rahmen)
    public var freqHz: Double
    /// Bester S/N der Rahmen
    public var snrDB: Int
    public var text: String
    public var frameCount: Int
    /// Der letzte Rahmen („last“) ist da
    public var isComplete: Bool
    /// Art des ersten Rahmens
    public var kind: JS8FrameKind?
    public var from: String?
    public var to: String?
    public var command: String?
    public var grid: String?
    public var isCQ = false
    /// Alle Rahmen mit geringer Güte (JS8Call zeigt sie in Klammern)
    public var isUncertain: Bool
    /// Rahmen fehlten dazwischen (Zyklus nicht decodiert)
    public var hasGap = false

    public var isHeartbeat: Bool { kind == .heartbeat }
}

/// Fasst Rahmen zu Nachrichten zusammen (Wert, ohne Zeitgeber, damit prüfbar).
public struct JS8Aggregator: Sendable {
    public private(set) var lines: [JS8Line] = []
    public var maxLines = 800

    public init() {}

    /// Frequenzabstand, bis zu dem ein Rahmen zur selben Aussendung gehört
    public static func tolerance(_ mode: JS8Submode) -> Double { max(5, 1.2 * mode.toneSpacing) }

    /// Nimmt einen Rahmen auf; liefert den Index der geänderten Zeile
    @discardableResult
    public mutating func add(_ d: JS8Decode) -> Int {
        let tol = Self.tolerance(d.submode)
        let period = d.submode.periodSeconds
        // Offene Nachricht auf dieser Frequenz in dieser Betriebsart, nicht älter als drei Zyklen
        let open = lines.indices.last { i in
            let l = lines[i]
            return !l.isComplete && l.submode == d.submode && abs(l.freqHz - d.freqHz) <= tol
                && d.cycleStart.timeIntervalSince(l.lastCycle) <= 3 * period + 1 && d.cycleStart >= l.lastCycle
        }
        let text = d.unpacked == nil ? "[\(d.frame)]" : d.text
        if let i = open, !d.bits.contains(.first) {
            var l = lines[i]
            if d.cycleStart.timeIntervalSince(l.lastCycle) > 1.5 * period {
                l.text += " … "
                l.hasGap = true
            }
            // Nach einem Rahmen mit Befehl hängt sich der Text unmittelbar an
            l.text += text
            l.frameCount += 1
            l.lastCycle = d.cycleStart
            l.freqHz = (l.freqHz * Double(l.frameCount - 1) + d.freqHz) / Double(l.frameCount)
            l.snrDB = max(l.snrDB, d.snrDB)
            l.isUncertain = l.isUncertain && d.isUncertain
            if d.bits.contains(.last) { l.isComplete = true }
            lines[i] = l
            return i
        }
        // Neue Nachricht; eine noch offene auf dieser Frequenz bleibt unvollständig stehen
        if let i = open { lines[i].isComplete = true }
        let u = d.unpacked
        let line = JS8Line(start: d.cycleStart, lastCycle: d.cycleStart, submode: d.submode, freqHz: d.freqHz, snrDB: d.snrDB,
                           text: d.bits.contains(.first) || (u != nil && u?.kind != .data) ? text : "… " + text, frameCount: 1,
                           isComplete: d.bits.contains(.last), kind: u?.kind, from: u?.from, to: u?.to, command: u?.command,
                           grid: u?.grid, isCQ: u?.isCQ ?? false, isUncertain: d.isUncertain)
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        return lines.count - 1
    }

    public mutating func clear() { lines.removeAll() }
}

/// Eine gehörte Station
public struct JS8Station: Identifiable, Sendable, Equatable {
    public var call: String
    public var grid: String?
    public var snrDB: Int
    public var freqHz: Double
    public var submode: JS8Submode
    public var lastHeard: Date
    public var count: Int
    /// Letzte Aussage der Station (Heartbeat, Befehl …)
    public var lastText: String
    public var dxcc: DXCCEntity?
    public var km: Double?
    public var bearing: Double?
    /// Die Station hat mit dem eigenen Rufzeichen zu tun (Absender oder Empfänger)
    public var mentionsMe = false
    public var id: String { call }
}

public enum JS8Calls {
    /// Rufzeichen mit Ziffer und Buchstaben, optional mit Zusatz; keine Gruppen („@ALLCALL“) und keine Platzhalter („<....>“)
    public static func isCall(_ s: String) -> Bool {
        guard s.count >= 3, s.count <= 14, !s.hasPrefix("@"), !s.hasPrefix("<") else { return false }
        var letters = 0
        var digits = 0
        for c in s.unicodeScalars {
            switch c {
            case "A"..."Z": letters += 1
            case "0"..."9": digits += 1
            case "/": break
            default: return false
            }
        }
        return letters >= 1 && digits >= 1
    }

    /// „KN4CRD“ am Anfang eines Freitextes „KN4CRD: HALLO“
    public static func leadingCall(_ text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let call = String(text[..<colon])
        return isCall(call) ? call : nil
    }
}
