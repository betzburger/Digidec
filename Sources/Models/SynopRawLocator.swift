// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - Rohmeldung einer Station im Empfangstext finden

/// Sucht zu einer Station (WMO-Nummer bzw. Schiffs-/Bojenkennung) die Rohmeldung im Empfangstext, damit man von der Karte aus
/// zu den empfangenen Zahlengruppen springen kann. Gesucht wird das letzte Vorkommen, das wie der Anfang einer Meldung aussieht:
/// am Zeilenanfang, nach einem „=“ (Ende der vorigen Meldung) oder hinter „BBXX“/„ZZYY“. Zeilen des Klartexts („WMO Station=10655“)
/// und Zahlen mitten in einer Meldung zählen nicht; gibt es keinen solchen Anfang, gilt notfalls das letzte freistehende Vorkommen.
public enum SynopRawLocator {
    /// Bereich in UTF-16-Einheiten (wie `NSRange` der Textansicht); nil, wenn die Station im Text nicht vorkommt
    public static func find(id: String, in text: String) -> NSRange? {
        let key = id.trimmingCharacters(in: .whitespaces)
        let ns = text as NSString
        guard !key.isEmpty, ns.length > 0 else { return nil }

        var searchEnd = ns.length
        var fallback: Int?
        while searchEnd > 0 {
            let r = ns.range(of: key, options: [.backwards, .caseInsensitive], range: NSRange(location: 0, length: searchEnd))
            if r.location == NSNotFound { break }
            searchEnd = r.location
            let before: unichar? = r.location > 0 ? ns.character(at: r.location - 1) : nil
            let afterIndex = r.location + r.length
            let after: unichar? = afterIndex < ns.length ? ns.character(at: afterIndex) : nil
            if isWordCharacter(before) || isWordCharacter(after) { continue }
            if before == unichar(UInt8(ascii: "=")) { continue }                  // Klartext: „WMO Station=10655“
            if startsMessage(ns, at: r.location) { return messageRange(ns, from: r.location) }
            if fallback == nil { fallback = r.location }
        }
        return fallback.map { messageRange(ns, from: $0) }
    }

    private static func isWordCharacter(_ ch: unichar?) -> Bool {
        guard let ch, let scalar = UnicodeScalar(UInt32(ch)) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// Steht die Kennung am Anfang einer Meldung?
    private static func startsMessage(_ ns: NSString, at location: Int) -> Bool {
        var i = location
        while i > 0, ns.character(at: i - 1) == 0x20 || ns.character(at: i - 1) == 0x09 { i -= 1 }
        if i == 0 { return true }
        let ch = ns.character(at: i - 1)
        if ch == 0x0A || ch == 0x0D || ch == unichar(UInt8(ascii: "=")) { return true }
        // „BBXX DBCR …“ / „ZZYY 44776 …“: der Kopf steht vor der Kennung (genau durch Leerzeichen getrennt)
        if i >= 4 && i == location - 1 {
            let head = ns.substring(with: NSRange(location: i - 4, length: 4)).uppercased()
            if head == "BBXX" || head == "ZZYY" { return true }
        }
        return false
    }

    /// Von der Kennung bis zum „=“ (Ende der Meldung); fehlt es, höchstens 200 Zeichen
    private static func messageRange(_ ns: NSString, from location: Int) -> NSRange {
        let limit = min(location + 800, ns.length)
        let eq = ns.range(of: "=", options: [], range: NSRange(location: location, length: limit - location))
        if eq.location != NSNotFound {
            return NSRange(location: location, length: eq.location + 1 - location)
        }
        return NSRange(location: location, length: min(200, ns.length - location))
    }
}
