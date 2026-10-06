// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - Textfilter für den Empfangstext (RTTY)

/// Einstellung des Textfilters. Der Filter wirkt auf die Anzeige und das Log; die Karten und die SYNOP-Auswertung bekommen
/// weiterhin den ganzen Text.
public struct ReceiveTextFilter: Equatable, Codable, Sendable {
    public var enabled = false
    /// Text, ab dem ausgegeben wird (Groß-/Kleinschreibung egal, wird mit ausgegeben); leer = von Anfang an
    public var start = ""
    /// Text, nach dem die Ausgabe endet, bis wieder `start` kommt (wird mit ausgegeben). Wirkt nur zusammen mit `start`.
    public var stop = ""
    /// Füllzeichen „RYRYRY…“ weglassen
    public var hideFiller = true

    public init(enabled: Bool = false, start: String = "", stop: String = "", hideFiller: Bool = true) {
        self.enabled = enabled
        self.start = start
        self.stop = stop
        self.hideFiller = hideFiller
    }

    public var startText: String { start.trimmingCharacters(in: .whitespaces) }
    public var stopText: String { stop.trimmingCharacters(in: .whitespaces) }

    /// Beschreibung für die Anzeige am Knopf
    public var summary: String {
        guard enabled else { return "aus" }
        var parts: [String] = []
        if !startText.isEmpty { parts.append("ab „\(startText)“") }
        if !startText.isEmpty && !stopText.isEmpty { parts.append("bis „\(stopText)“") }
        if hideFiller { parts.append("ohne RYRY") }
        return parts.isEmpty ? "an" : parts.joined(separator: " ")
    }
}

/// Wendet den Filter auf den Textstrom an. Die Stücke kommen in beliebiger Größe an; Anfang und Ende der Suchtexte dürfen
/// über Stückgrenzen hinweg liegen. Ein Rest, der noch zu einem Suchtext oder Füllzeichen gehören könnte, wird zurückgehalten
/// (`flush()` gibt ihn frei, wenn eine Weile nichts mehr kommt).
public struct ReceiveTextFilterRunner: Sendable {
    public var filter: ReceiveTextFilter
    /// Gerade wird ausgegeben (zwischen Start und Stopp)
    public private(set) var isOpen: Bool
    private var carry = ""
    private var needsBreak = false

    public init(filter: ReceiveTextFilter = ReceiveTextFilter()) {
        self.filter = filter
        isOpen = filter.startText.isEmpty
    }

    /// Neue Einstellung übernehmen; der Zustand beginnt neu
    public mutating func configure(_ f: ReceiveTextFilter) {
        filter = f
        isOpen = f.startText.isEmpty
        carry = ""
        carryFiller = ""
        needsBreak = false
    }

    /// Ein Stück Rohtext durch den Filter schicken; Rückgabe: was angezeigt werden soll
    public mutating func process(_ chunk: String) -> String {
        guard filter.enabled else { return chunk }
        var buffer = carry + chunk
        carry = ""
        var out = ""
        let start = filter.startText
        let stop = filter.stopText

        while !buffer.isEmpty {
            if !isOpen {
                if let r = buffer.range(of: start, options: [.caseInsensitive]) {
                    isOpen = true
                    if needsBreak { out += "\n"; needsBreak = false }      // zwischen zwei Abschnitten eine Zeile umbrechen
                    buffer = String(buffer[r.lowerBound...])                // der Starttext gehört zur Ausgabe
                    continue
                }
                carry = Self.tail(of: buffer, length: start.count - 1)
                buffer = ""
            } else if !start.isEmpty, !stop.isEmpty, let r = buffer.range(of: stop, options: [.caseInsensitive]) {
                out += String(buffer[..<r.upperBound])
                buffer = String(buffer[r.upperBound...])
                isOpen = false
                needsBreak = true
            } else {
                let hold = (!start.isEmpty && !stop.isEmpty) ? stop.count - 1 : 0
                let keep = Self.tail(of: buffer, length: hold)
                out += String(buffer.dropLast(keep.count))
                carry = keep
                buffer = ""
            }
        }
        return filter.hideFiller ? removeFiller(out) : out
    }

    /// Klartext der SYNOP-Auswertung: nur anzeigen, solange der Filter offen ist
    public func allowsDecoded() -> Bool { !filter.enabled || isOpen }

    /// Zurückgehaltenen Rest ausgeben (kein weiterer Text in Sicht)
    public mutating func flush() -> String {
        guard filter.enabled else { return "" }
        var rest = carryFiller
        carryFiller = ""
        // Ein zurückgehaltener Anfang des Starttexts bleibt liegen: der Rest des Starttexts kann noch kommen
        if isOpen {
            rest += carry
            carry = ""
        }
        return rest
    }

    private static func tail(of s: String, length: Int) -> String {
        length > 0 ? String(s.suffix(length)) : ""
    }

    // MARK: Füllzeichen

    /// „RYRYRY…“ (mindestens drei Paare, auch ab dem Y) entfernen; ein angefangener Schwanz aus R/Y wird zurückgehalten
    private mutating func removeFiller(_ text: String) -> String {
        var t = carryFiller + text
        carryFiller = ""
        // Schwanz aus R und Y zurückhalten: er kann Anfang oder Mitte einer Füllfolge sein, auch wenn die Zeichen einzeln ankommen
        var tailCount = 0
        for ch in t.reversed() {
            guard ch == "R" || ch == "Y" || ch == "r" || ch == "y" else { break }
            tailCount += 1
        }
        if tailCount >= 1 {
            let tail = String(t.suffix(tailCount))
            t = String(t.dropLast(tailCount))
            carryFiller = tail
        }
        return t.replacingOccurrences(of: "(?:RY){3,}R?|(?:YR){3,}Y?", with: "", options: [.regularExpression, .caseInsensitive])
    }

    private var carryFiller = ""
}
