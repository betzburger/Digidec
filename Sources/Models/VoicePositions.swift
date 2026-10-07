// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Positionen aus digitalen Sprachmodi (D-Star DPRS, M17 GNSS-Daten): gemeinsame Liste je Modul für die Karte.

/// Eine gehörte Station mit Position, Weg und Zusatzdaten
public struct VoicePosition: Identifiable, Equatable, Sendable {
    public var id: String { mode + "-" + callsign }
    public var mode: String
    public var callsign: String
    public var point: GeoPoint
    public var comment: String
    public var firstHeard: Date
    public var lastHeard: Date
    public var track: [GeoPoint]
    public var count = 1
    /// km/h, Meter, Grad (wenn die Aussendung sie enthält)
    public var speed: Double?
    public var altitude: Double?
    public var bearing: Double?
}

public struct VoicePositionBook: Equatable, Sendable {
    public private(set) var items: [VoicePosition] = []
    public static let maxItems = 300
    public static let maxTrack = 60

    public init() {}

    public mutating func clear() { items.removeAll() }

    /// Eine Position aufnehmen; ungültige Werte (außerhalb des Bereichs, 0/0) werden verworfen. Rückgabe: wurde aufgenommen.
    @discardableResult
    public mutating func update(mode: String, callsign: String, latitude: Double, longitude: Double, comment: String = "", speed: Double? = nil,
                                altitude: Double? = nil, bearing: Double? = nil, now: Date = Date()) -> Bool {
        let call = callsign.trimmingCharacters(in: .whitespaces).uppercased()
        let p = GeoPoint(lat: latitude, lon: longitude)
        guard !call.isEmpty, p.isValid, !(abs(latitude) < 0.0001 && abs(longitude) < 0.0001) else { return false }
        if let i = items.firstIndex(where: { $0.mode == mode && $0.callsign == call }) {
            let moved = Geo.distanceKm(items[i].point, p)
            if moved > 0.02 {
                items[i].track.append(items[i].point)
                if items[i].track.count > Self.maxTrack { items[i].track.removeFirst(items[i].track.count - Self.maxTrack) }
            }
            items[i].point = p
            items[i].lastHeard = now
            items[i].count += 1
            if !comment.isEmpty { items[i].comment = comment }
            items[i].speed = speed; items[i].altitude = altitude; items[i].bearing = bearing
        } else {
            items.append(VoicePosition(mode: mode, callsign: call, point: p, comment: comment, firstHeard: now, lastHeard: now, track: [],
                                       speed: speed, altitude: altitude, bearing: bearing))
            if items.count > Self.maxItems { items.removeFirst(items.count - Self.maxItems) }
        }
        return true
    }

    /// Karteninhalt: ein Punkt je Station, Weg als Spur, bei der Auswahl eine Linie vom Standort
    public func mapContent(home: GeoPoint?, now: Date, selection: String? = nil, hint: String) -> MapContent {
        var markers: [MapMarker] = []
        var lines: [MapLine] = []
        for v in items.sorted(by: { $0.lastHeard > $1.lastHeard }) {
            let age = now.timeIntervalSince(v.lastHeard)
            var details: [String] = []
            if !v.comment.isEmpty { details.append(v.comment) }
            if let s = v.speed, s > 0 { details.append(String(format: "%.0f km/h", s)) }
            if let a = v.altitude { details.append(String(format: "%.0f m", a)) }
            details.append(Geo.format(v.point) + " · " + Maidenhead.locator(v.point))
            if let h = home { details.append("Entfernung " + Geo.formatKm(Geo.distanceKm(h, v.point)) + ", Richtung " + String(format: "%.0f°", Geo.bearing(from: h, to: v.point))) }
            markers.append(MapMarker(id: v.id, coordinate: v.point, title: v.callsign,
                                     subtitle: "\(v.mode) · \(Self.age(age)) · \(v.count)×",
                                     details: details, tone: age < 300 ? .highlight : age < 3600 ? .normal : .dim, heardAt: v.lastHeard,
                                     track: v.track + [v.point], headingDeg: v.bearing))
            if v.id == selection, let h = home { lines.append(MapLine(id: "line-" + v.id, points: [h, v.point], tone: .info, geodesic: true)) }
        }
        return MapContent(markers: markers, lines: lines, home: home, emptyHint: hint)
    }

    static func age(_ s: TimeInterval) -> String {
        if s < 90 { return "vor \(Int(s)) s" }
        if s < 5400 { return "vor \(Int((s / 60).rounded())) min" }
        return "vor \(Int((s / 3600).rounded())) h"
    }
}
