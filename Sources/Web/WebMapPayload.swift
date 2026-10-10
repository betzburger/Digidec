// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Ein Decoder-Modul für die Modul-Leiste des Web-Dashboards (Reihenfolge und Gruppen wie in der App)
public struct WebModuleEntry: Equatable, Sendable {
    public var id: String
    public var name: String
    /// „HF“, „VHF/UHF“ oder „ALL“ (Mehrkanal deckt beide Bereiche ab)
    public var group: String
    /// Hat das Modul eine Kartenanzeige?
    public var hasMap: Bool

    public init(id: String, name: String, group: String, hasMap: Bool) {
        self.id = id
        self.name = name
        self.group = group
        self.hasMap = hasMap
    }
}

/// Serialisiert den Karteninhalt des aktiven Moduls (`MapContent`) als JSON für die Karte im Web-Dashboard
/// (OpenStreetMap-Kacheln, Zeichnung im Browser).
public enum WebMapPayload {
    /// Obergrenzen, damit auch ein sehr voller ADS-B- oder AIS-Himmel einen handlichen Rahmen ergibt
    public static let maxMarkers = 250
    public static let maxTrackPoints = 40
    public static let maxLines = 100

    /// SF-Symbole der App haben im Browser kein Gegenstück: dafür ein Zeichen
    static let symbolGlyphs: [String: String] = [
        "airplane": "✈", "airplane.departure": "⇗", "airplane.arrival": "⇘", "antenna.radiowaves.left.and.right": "◉",
        "chevron.forward.2": "»", "water.waves": "≈", "scope": "◎", "mappin.circle.fill": "●", "flag.checkered": "⚑",
        "exclamationmark.triangle.fill": "⚠", "exclamationmark.triangle": "⚠", "balloon.fill": "🎈"
    ]

    /// Umrisse aller Fahrzeuge (Flugzeuge und Schiffe) wie in der App: Vielecke im Quadrat −1 … +1, Bug nach oben, plus Kantenlänge in Punkten.
    /// Der Browser bekommt sie einmal je Verbindung und zeichnet die Marker damit.
    public static var shapes: [String: Any] {
        var out: [String: Any] = [:]
        for s in MapSilhouette.allCases {
            out[s.rawValue] = [
                "size": Double(s.size),
                "ship": s.isShip,
                "contours": s.contours.map { contour in contour.map { [(Double($0.x) * 1000).rounded() / 1000, (Double($0.y) * 1000).rounded() / 1000] } }
            ] as [String: Any]
        }
        return out
    }

    private static func r5(_ v: Double) -> Double { (v * 100_000).rounded() / 100_000 }
    private static func pt(_ p: GeoPoint) -> [Double] { [r5(p.lat), r5(p.lon)] }

    /// Wörterbuch für `JSONSerialization`; `module` ist die Modul-Kennung, `hasMap` false = „keine Ortsdaten“
    public static func dictionary(content: MapContent?, module: String, hasMap: Bool) -> [String: Any] {
        var out: [String: Any] = ["type": "map", "module": module, "hasMap": hasMap]
        guard let content else {
            out["markers"] = [Any]()
            out["lines"] = [Any]()
            out["hint"] = hasMap ? "" : "Dieses Modul hat keine Ortsdaten"
            return out
        }
        var markers: [[String: Any]] = []
        for m in content.markers where m.coordinate.isValid {
            if markers.count >= maxMarkers { break }
            var d: [String: Any] = [
                "id": m.id,
                "lat": r5(m.coordinate.lat),
                "lon": r5(m.coordinate.lon),
                "title": m.title,
                "tone": m.tone.rawValue
            ]
            if let s = m.subtitle, !s.isEmpty { d["sub"] = s }
            if !m.details.isEmpty { d["details"] = m.details }
            if let g = m.glyph, !g.isEmpty { d["glyph"] = g } else if let sym = m.symbol, let g = symbolGlyphs[sym] { d["glyph"] = g }
            if let h = m.headingDeg, h.isFinite { d["heading"] = (h * 10).rounded() / 10 }
            if let s = m.silhouette {
                d["shape"] = s.rawValue
                d["scale"] = (m.silhouetteScale * 100).rounded() / 100
            }
            if m.radiusKm > 0 { d["radiusKm"] = m.radiusKm }
            if let v = m.valueText, !v.isEmpty { d["value"] = v }
            if let l = m.valueLevel, l.isFinite { d["level"] = (l * 100).rounded() / 100 }
            let valid = m.track.filter(\.isValid)
            if valid.count > 1 { d["track"] = valid.suffix(maxTrackPoints).map(pt) }
            markers.append(d)
        }
        out["markers"] = markers
        out["lines"] = content.lines.prefix(maxLines).compactMap { l -> [String: Any]? in
            let p = l.points.filter(\.isValid)
            guard p.count >= 2 else { return nil }
            return ["points": p.map(pt), "tone": l.tone.rawValue, "geodesic": l.geodesic]
        }
        out["contours"] = content.contours.prefix(60).compactMap { c -> [String: Any]? in
            let p = c.points.filter(\.isValid)
            guard p.count >= 2 else { return nil }
            var d: [String: Any] = ["points": p.map(pt), "level": c.level]
            if let l = c.label, let lp = c.labelPoint, lp.isValid { d["label"] = l; d["at"] = pt(lp) }
            return d
        }
        out["patches"] = content.patches.prefix(400).compactMap { c -> [String: Any]? in
            let p = c.corners.filter(\.isValid)
            guard p.count >= 3 else { return nil }
            return ["corners": p.map(pt), "level": (c.level * 100).rounded() / 100]
        }
        if let h = content.home, h.isValid { out["home"] = pt(h) }
        out["hint"] = content.markers.isEmpty ? content.emptyHint : (content.note ?? "")
        return out
    }

    /// JSON-Text der Karte; gleiche Eingabe ergibt gleichen Text (sortierte Schlüssel), damit unveränderte Karten nicht erneut gesendet werden
    public static func json(content: MapContent?, module: String, hasMap: Bool) -> String? {
        let d = dictionary(content: content, module: module, hasMap: hasMap)
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
