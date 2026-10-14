// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Gemeinsame Karte des Mehrkanalbetriebs: die Positionen aller Kanäle auf einer Karte.
// Reine Logik (prüfbar): jeder Kanal liefert seinen `MapContent`, hier werden sie zusammengeführt.

/// Karteninhalt eines Kanals
public struct ChannelMapPart: Sendable {
    public var slotID: Int
    /// Anzeigename des Kanals („AIS A 161,975 MHz“)
    public var title: String
    public var content: MapContent

    public init(slotID: Int, title: String, content: MapContent) {
        self.slotID = slotID
        self.title = title
        self.content = content
    }
}

public enum ChannelMapBuilder {
    /// Kennung eines Kartenelements im Kanal: so bleiben gleiche Kennungen aus zwei Kanälen (z. B. zwei ACARS-Frequenzen) getrennt
    public static func id(slotID: Int, _ original: String) -> String { "ch\(slotID)/\(original)" }

    /// Kanal und ursprüngliche Kennung zurück
    public static func split(_ id: String) -> (slotID: Int, original: String)? {
        guard id.hasPrefix("ch"), let slash = id.firstIndex(of: "/"), let slot = Int(id[id.index(id.startIndex, offsetBy: 2)..<slash]) else { return nil }
        return (slot, String(id[id.index(after: slash)...]))
    }

    /// Alle Kanäle auf einer Karte. Punkte und Linien tragen den Kanalnamen in der zweiten Zeile; Karten ohne Inhalt bleiben stumm.
    public static func merge(_ parts: [ChannelMapPart], home: GeoPoint?, emptyHint: String = "Noch keine Positionen in den Kanälen empfangen") -> MapContent {
        var out = MapContent(home: home, emptyHint: emptyHint)
        var notes: [String] = []
        for part in parts {
            let c = part.content
            for var m in c.markers {
                m.id = id(slotID: part.slotID, m.id)
                m.subtitle = [part.title, m.subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                out.markers.append(m)
            }
            for var l in c.lines {
                l.id = id(slotID: part.slotID, l.id)
                out.lines.append(l)
            }
            for var k in c.contours {
                k.id = id(slotID: part.slotID, k.id)
                out.contours.append(k)
            }
            for var p in c.patches {
                p.id = id(slotID: part.slotID, p.id)
                out.patches.append(p)
            }
            if let n = c.note, !n.isEmpty { notes.append(n) }
        }
        if !notes.isEmpty { out.note = notes.joined(separator: " · ") }
        return out
    }
}
