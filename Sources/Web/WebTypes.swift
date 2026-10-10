// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - Wasserfall

/// Beschreibung des Wasserfalls für den Browser: welcher Frequenzbereich zu den Spalten einer Zeile gehört,
/// was davon sichtbar ist (Zoom) und welche Marken gezeichnet werden. Eine Zeile selbst sind nur Farbindizes (0 … 255).
public struct WebWaterfallInfo: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// NF-Wasserfall des Audio-Eingangs (0 … Nyquist)
        case af
        /// HF-Wasserfall des SDR-Empfängers (gesamtes I/Q-Fenster)
        case rf
        /// Modul ohne Wasserfall (liest das Gerät selbst)
        case none
    }

    public struct Channel: Equatable, Sendable {
        public var frequency: Double
        public var label: String
        public var selected: Bool
        public var active: Bool
        public init(frequency: Double, label: String, selected: Bool = false, active: Bool = true) {
            self.frequency = frequency; self.label = label; self.selected = selected; self.active = active
        }
    }

    public struct ZoomChoice: Equatable, Sendable {
        public var label: String
        public var value: Double
        public init(label: String, value: Double) { self.label = label; self.value = value }
    }

    public var kind: Kind = .none
    /// Kopfzeile über dem Wasserfall („AUDIO-WASSERFALL (NF)“, „HF-WASSERFALL · HackRF“)
    public var title = ""
    /// Hinweis mitten im Bild (kein Signal, Gerät startet, Fehler)
    public var note = ""
    /// Frequenzbereich der gesamten Zeile in Hz (NF: 0 … Nyquist; HF: das I/Q-Fenster)
    public var fullLo = 0.0
    public var fullHi = 0.0
    /// Sichtbarer Ausschnitt (Zoom)
    public var visLo = 0.0
    public var visHi = 0.0
    /// NF: Mittenfrequenz des Decoders; HF: gehörte Frequenz
    public var centerHz = 0.0
    public var markHz: Double?
    public var spaceHz: Double?
    /// Belegte Bandbreite um die Mitte (Schattierung)
    public var bandwidthHz = 0.0
    /// HF: tatsächlicher Durchlassbereich (USB nur oberhalb, LSB nur unterhalb der Frequenz); sonst um die Mitte
    public var bandLo: Double?
    public var bandHi: Double?
    /// „tones“, „band“, „none“ oder „channels“
    public var markerStyle = "none"
    public var markerText = ""
    public var channels: [Channel] = []
    /// Zoomstufen mit der aktuellen (`zoom`) und ob die Marke abstimmbar ist
    public var zoomChoices: [ZoomChoice] = []
    public var zoom = 1.0
    public var rangeDB = 50
    public var tunable = false

    public init() {}

    public var dictionary: [String: Any] {
        var d: [String: Any] = [
            "type": "wf", "kind": kind.rawValue, "title": title, "note": note,
            "fullLo": fullLo, "fullHi": fullHi, "visLo": visLo, "visHi": visHi,
            "center": centerHz, "bw": bandwidthHz, "style": markerStyle, "markerText": markerText,
            "zoom": zoom, "range": rangeDB, "tunable": tunable,
            "zoomChoices": zoomChoices.map { ["label": $0.label, "value": $0.value] as [String: Any] }
        ]
        if let bandLo, let bandHi { d["bandLo"] = bandLo; d["bandHi"] = bandHi }
        if let markHz { d["mark"] = markHz }
        if let spaceHz { d["space"] = spaceHz }
        if !channels.isEmpty {
            d["channels"] = channels.map { ["f": $0.frequency, "label": $0.label, "sel": $0.selected, "act": $0.active] as [String: Any] }
        }
        return d
    }

    /// JSON-Text mit sortierten Schlüsseln (gleiche Eingabe = gleicher Text, damit Unverändertes nicht erneut gesendet wird)
    public var json: String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Text

/// Textansicht des aktiven Moduls für den Browser: Protokoll (`log`: neue Zeilen unten, Ansicht bleibt unten)
/// oder Liste (`list`: aktueller Stand, z. B. Flugzeuge oder Stationen; Ansicht bleibt oben)
public struct WebTranscript: Equatable, Sendable {
    public enum Kind: String, Sendable { case log, list }
    public var kind: Kind
    public var title: String
    public var lines: [String]

    public init(kind: Kind, title: String, lines: [String]) {
        self.kind = kind
        self.title = title
        self.lines = lines
    }

    public static let maxLines = 400
    public static let maxLineLength = 600

    /// Auf eine handliche Größe begrenzen: die letzten `maxLines` Zeilen (Protokoll) bzw. die ersten (Liste), lange Zeilen kürzen
    public static func limited(kind: Kind, title: String, lines: [String]) -> WebTranscript {
        var l = kind == .log ? Array(lines.suffix(maxLines)) : Array(lines.prefix(maxLines))
        for i in l.indices where l[i].count > maxLineLength { l[i] = String(l[i].prefix(maxLineLength)) + "…" }
        return WebTranscript(kind: kind, title: title, lines: l)
    }
}

/// Wie viele Zeilen am Anfang übereinstimmen: ab dort muss der Browser ersetzen
public func webCommonPrefix(_ a: [String], _ b: [String]) -> Int {
    var i = 0
    let n = min(a.count, b.count)
    while i < n && a[i] == b[i] { i += 1 }
    return i
}

// MARK: - Audio

/// Audio für den Browser: verschachtelte Abtastwerte, Rate in Hz, Kanäle (1 oder 2)
public typealias WebAudioSink = @Sendable (UnsafeBufferPointer<Float>, Int, Int) -> Void

// MARK: - Voreinstellungen

/// Eine Auswahlliste für den Browser (Kanal, Band, Betriebsart, Sender …): als Auswahlmenü in der Leiste des Dashboards
public struct WebPresetGroup: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public var id: String
        public var label: String
        public init(id: String, label: String) { self.id = id; self.label = label }
    }

    /// Kennung der Liste im Modul („channel“, „mode“, „band“ …), kommt beim Wählen zurück
    public var key: String
    public var label: String
    public var options: [Option]
    /// Kennung der gewählten Option; steht sie nicht in `options`, zeigt das Menü nichts an
    public var selected: String

    public init(key: String, label: String, options: [Option], selected: String) {
        self.key = key; self.label = label; self.options = options; self.selected = selected
    }

    /// JSON-Text der Listen eines Moduls (sortierte Schlüssel, damit Unverändertes nicht erneut gesendet wird)
    public static func json(_ groups: [WebPresetGroup]) -> String? {
        let list: [[String: Any]] = groups.map { g in
            ["key": g.key, "label": g.label, "selected": g.selected,
             "options": g.options.map { ["id": $0.id, "label": $0.label] }]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "presets", "groups": list], options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
