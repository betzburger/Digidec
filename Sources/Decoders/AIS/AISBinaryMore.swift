// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// AIS: weitere binäre Nachrichten: Gebietsmeldungen (DAC 1 FI 22 und 23), Schifffahrtszeichen (FI 19), Wetterbeobachtung vom Schiff (FI 21),
// erweiterte Stamm- und Reisedaten (FI 24), Personen an Bord (1/16, 200/55) und Überwachung von Seezeichen (DAC 235/250 FI 10).
// Layouts nach der Beschreibung des gpsd-Projekts (AIVDM/AIS Dictionary, BSD) und den dortigen Testsätzen; eigene Umsetzung.

// MARK: - Gebietsmeldungen

/// Teilgebiet einer Gebietsmeldung
public enum AISAreaShape: Equatable, Sendable {
    case circle(center: GeoPoint, radiusM: Double)
    case rectangle(corners: [GeoPoint])
    case sector(center: GeoPoint, radiusM: Double, left: Double, right: Double)
    case polyline([GeoPoint])
    case polygon([GeoPoint])
    case text(String)
}

public struct AISAreaNotice: Equatable, Sendable, Identifiable {
    public var mmsi: UInt32
    public var linkage: Int
    /// Art der Meldung (0 … 127, siehe `AISAreaNotice.noticeText`)
    public var notice: Int
    public var month: Int?
    public var day: Int?
    public var hour: Int?
    public var minute: Int?
    /// Dauer in Minuten; nil = unbefristet bzw. unbekannt, 0 = Meldung aufheben
    public var durationMinutes: Int?
    public var shapes: [AISAreaShape]
    public var addressedTo: UInt32?
    public var receivedAt = Date(timeIntervalSince1970: 0)
    /// Text aus einer Textbeschreibung (FI 29/30) mit derselben Verknüpfung
    public var linkedText: String?

    public var id: String { "\(mmsi)-\(linkage)" }

    /// Text aus dem Teilgebiet „Text“ (14 Zeichen je Teilgebiet) zusammengesetzt
    public var embeddedText: String {
        shapes.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
    }

    public var displayText: String? {
        let t = [linkedText, embeddedText.isEmpty ? nil : embeddedText].compactMap { $0 }.joined(separator: " – ")
        return t.isEmpty ? nil : t
    }

    /// Beginn (UTC); das Jahr ergibt sich aus dem Empfangsdatum
    public var start: Date? {
        guard let mo = month, let d = day, let h = hour, let mi = minute else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let y = cal.component(.year, from: receivedAt)
        func date(_ year: Int) -> Date? { cal.date(from: DateComponents(year: year, month: mo, day: d, hour: h, minute: mi)) }
        guard var s = date(y) else { return nil }
        if s.timeIntervalSince(receivedAt) > 183 * 86_400, let p = date(y - 1) { s = p }
        return s
    }

    public var end: Date? {
        guard let s = start, let dur = durationMinutes else { return nil }
        return s.addingTimeInterval(Double(dur) * 60)
    }

    /// Gilt die Meldung noch? Mit Dauer bis zum Ende, sonst bis 3 Stunden nach dem letzten Empfang
    public func isActive(at now: Date) -> Bool {
        if now.timeIntervalSince(receivedAt) > 12 * 3600 { return false }
        if let e = end { return now < e }
        return now.timeIntervalSince(receivedAt) < 3 * 3600
    }

    public var title: String { Self.noticeText(notice) }

    public var isCancellation: Bool { notice == 126 || durationMinutes == 0 }

    public var points: [GeoPoint] {
        shapes.flatMap { s -> [GeoPoint] in
            switch s {
            case .circle(let c, _): return [c]
            case .sector(let c, _, _, _): return [c]
            case .rectangle(let p), .polyline(let p), .polygon(let p): return p
            case .text: return []
            }
        }
    }

    /// Farbgruppe nach Kategorie (Bereich der Kennung)
    public enum Category: Sendable { case caution, environment, restricted, anchorage, distress, instruction, information, chart, other }

    public var category: Category {
        switch notice {
        case 0...21: return .caution
        case 23...30: return .environment
        case 32...38: return .restricted
        case 40...45: return .anchorage
        case 56...58: return .restricted
        case 64...76: return .distress
        case 80...85: return .instruction
        case 88...95: return .information
        case 96...108: return .chart
        default: return .other
        }
    }

    public static func noticeText(_ n: Int) -> String {
        switch n {
        case 0: return "Vorsicht: Lebensraum von Meeressäugern"
        case 1: return "Vorsicht: Meeressäuger im Gebiet, Fahrt verringern"
        case 2: return "Vorsicht: Meeressäuger im Gebiet, Abstand halten"
        case 3: return "Vorsicht: Meeressäuger im Gebiet, Sichtungen melden"
        case 4: return "Vorsicht: Schutzgebiet, Fahrt verringern"
        case 5: return "Vorsicht: Schutzgebiet, Abstand halten"
        case 6: return "Vorsicht: Schutzgebiet, Fischen und Ankern verboten"
        case 7: return "Vorsicht: Treibende Gegenstände"
        case 8: return "Vorsicht: Verkehrsdichte"
        case 9: return "Vorsicht: Veranstaltung auf dem Wasser"
        case 10: return "Vorsicht: Taucher im Wasser"
        case 11: return "Vorsicht: Badebereich"
        case 12: return "Vorsicht: Baggerarbeiten"
        case 13: return "Vorsicht: Vermessungsarbeiten"
        case 14: return "Vorsicht: Unterwasserarbeiten"
        case 15: return "Vorsicht: Wasserflugzeuge"
        case 16: return "Vorsicht: Fischernetze im Wasser"
        case 17: return "Vorsicht: Fischereifahrzeuge in Gruppe"
        case 18: return "Fahrwasser gesperrt"
        case 19: return "Hafen gesperrt"
        case 20: return "Vorsicht: Gefahr (siehe Text)"
        case 21: return "Vorsicht: Unterwasserfahrzeug im Einsatz"
        case 23: return "Wetter: Sturmfront (Böenlinie)"
        case 24: return "Wetter: Gefährliches Meereis"
        case 25: return "Wetter: Sturmwarnung"
        case 26: return "Wetter: Starkwind"
        case 27: return "Wetter: Hohe Wellen"
        case 28: return "Wetter: Sichtbehinderung (Nebel, Regen)"
        case 29: return "Wetter: Starke Strömung"
        case 30: return "Wetter: Starke Vereisung"
        case 32: return "Sperrgebiet: Fischen verboten"
        case 33: return "Sperrgebiet: Ankern verboten"
        case 34: return "Sperrgebiet: Einfahrt nur mit Genehmigung"
        case 35: return "Sperrgebiet: Einfahrt verboten"
        case 36: return "Sperrgebiet: Militärisches Übungsgebiet"
        case 37: return "Sperrgebiet: Schießgebiet"
        case 38: return "Sperrgebiet: Treibende Minen"
        case 40: return "Ankerplatz offen"
        case 41: return "Ankerplatz gesperrt"
        case 42: return "Ankern verboten"
        case 43: return "Ankerplatz für große Tiefgänge"
        case 44: return "Ankerplatz für geringe Tiefgänge"
        case 45: return "Übergabe von Schiff zu Schiff"
        case 56: return "Sicherheitsalarm Stufe 1"
        case 57: return "Sicherheitsalarm Stufe 2"
        case 58: return "Sicherheitsalarm Stufe 3"
        case 64: return "Seenot: Fahrzeug manövrierunfähig, treibt"
        case 65: return "Seenot: Fahrzeug sinkt"
        case 66: return "Seenot: Fahrzeug wird verlassen"
        case 67: return "Seenot: Ärztliche Hilfe angefordert"
        case 68: return "Seenot: Wassereinbruch"
        case 69: return "Seenot: Feuer oder Explosion"
        case 70: return "Seenot: Grundberührung"
        case 71: return "Seenot: Kollision"
        case 72: return "Seenot: Schlagseite, Kentergefahr"
        case 73: return "Seenot: Überfall"
        case 74: return "Seenot: Person über Bord"
        case 75: return "Seenot: Such- und Rettungsgebiet"
        case 76: return "Seenot: Gebiet zur Ölbekämpfung"
        case 80: return "Anweisung: Verkehrszentrale an dieser Stelle rufen"
        case 81: return "Anweisung: Hafenbehörde an dieser Stelle rufen"
        case 82: return "Anweisung: Nicht über diese Stelle hinaus fahren"
        case 83: return "Anweisung: An dieser Stelle auf Anweisungen warten"
        case 84: return "Anweisung: Zu dieser Stelle fahren, Anweisungen abwarten"
        case 85: return "Anweisung: Freigabe, zum Liegeplatz fahren"
        case 88: return "Information: Lotsenübernahmeplatz"
        case 89: return "Information: Warteplatz der Eisbrecher"
        case 90: return "Information: Notliegeplätze"
        case 91: return "Information: Position der Eisbrecher"
        case 92: return "Information: Standort von Einsatzkräften"
        case 93: return "Aktives Ziel der Verkehrszentrale"
        case 94: return "Verdächtiges Fahrzeug"
        case 95: return "Fahrzeug bittet um Hilfe (kein Notfall)"
        case 96: return "Seekarte: Wrack"
        case 97: return "Seekarte: Untergetauchtes Hindernis"
        case 98: return "Seekarte: Halb untergetauchtes Hindernis"
        case 99: return "Seekarte: Flachstelle"
        case 100: return "Seekarte: Flachstelle im Norden"
        case 101: return "Seekarte: Flachstelle im Osten"
        case 102: return "Seekarte: Flachstelle im Süden"
        case 103: return "Seekarte: Flachstelle im Westen"
        case 104: return "Seekarte: Fahrwasserhindernis"
        case 105: return "Seekarte: Verringerte Durchfahrtshöhe"
        case 106: return "Seekarte: Brücke geschlossen"
        case 107: return "Seekarte: Brücke teilweise geöffnet"
        case 108: return "Seekarte: Brücke ganz geöffnet"
        case 112: return "Meldung vom Schiff: Vereisung"
        case 114: return "Meldung vom Schiff: Sonstiges (siehe Text)"
        case 120: return "Route: Empfohlene Route"
        case 121: return "Route: Alternative Route"
        case 122: return "Route: Empfohlene Route durch Eis"
        case 125: return "Sonstiges (siehe Text)"
        case 126: return "Meldung aufgehoben"
        case 127: return "Gebietsmeldung"
        default: return "Gebietsmeldung \(n)"
        }
    }
}

// MARK: - Weitere Telegramme

public struct AISTrafficSignal: Equatable, Sendable {
    public var linkage: Int
    public var station: String
    /// 0 unbekannt, 1 im regulären Betrieb, 2 gestört
    public var status: Int
    public var signal: Int
    public var nextSignal: Int
    public var hour: Int?
    public var minute: Int?

    public static func text(_ s: Int) -> String? {
        switch s {
        case 1: return "Signal 1: schwerer Notfall, alle Fahrzeuge anhalten"
        case 2: return "Signal 2: Einfahrt und Ausfahrt verboten"
        case 3: return "Signal 3: Fahrt frei, Einrichtungsverkehr"
        case 4: return "Signal 4: Fahrt frei, Gegenverkehr"
        case 5: return "Signal 5: Fahrt nur auf besondere Anweisung"
        case 6: return "Signal 2a: Fahrt verboten (außerhalb der Fahrrinne frei)"
        case 7: return "Signal 5a: Fahrt nur auf Anweisung (außerhalb der Fahrrinne frei)"
        case 8: return "Japan I: nur einlaufend"
        case 9: return "Japan O: nur auslaufend"
        case 10: return "Japan F: ein- und auslaufend"
        case 11: return "Japan XI: wechselt bald auf I"
        case 12: return "Japan XO: wechselt bald auf O"
        case 13: return "Japan X: Fahrt verboten"
        default: return nil
        }
    }

    public var statusText: String? {
        switch status {
        case 1: return "regulärer Betrieb"
        case 2: return "gestörter Betrieb"
        default: return nil
        }
    }

    public var lines: [String] {
        var out: [String] = []
        if let s = Self.text(signal) { out.append(s + (statusText.map { " (\($0))" } ?? "")) }
        if let s = Self.text(nextSignal), nextSignal != signal {
            var t = "Nächstes: \(s)"
            if let h = hour, let m = minute { t += String(format: " ab %02d:%02d UTC", h, m) }
            out.append(t)
        }
        return out
    }
}

public struct AISExtendedShip: Equatable, Sendable {
    public var airDraught: Double?
    public var airDraughtOver = false
    public var lastPort: String?
    public var nextPort: String?
    public var secondPort: String?
    public var iceClass: Int?
    public var horsepower: Int?
    public var vhfChannel: Int?
    public var lloydsType: String?
    public var tonnage: Int?
    /// 1 beladen, 2 Ballast
    public var lading: Int?
    public var persons: Int?
    /// Anlagen, die laut Meldung ausgefallen sind
    public var failedEquipment: [String]
    public var operationalCount: Int

    static let equipment = ["AIS Klasse A", "Automatische Zielverfolgung", "BNWAS", "ECDIS-Reserve", "Papierseekarte", "Echolot", "Plotthilfe", "Notrudereinrichtung",
                            "GNSS", "Kreiselkompass", "LRIT", "Magnetkompass", "NAVTEX", "Radar (ARPA)", "Radar (S-Band)", "Radar (X-Band)", "Funk KW", "Funk Inmarsat",
                            "Funk MF", "Funk UKW", "Log über Grund", "Log durch das Wasser", "THD", "Bahnregelung", "Fahrtschreiber (VDR)"]

    public static func iceClassText(_ c: Int) -> String? {
        switch c {
        case 0: return "nicht eisverstärkt"
        case 1...5: return "Polarklasse PC \(c)"
        case 6: return "PC 6 / FSICR IA Super"
        case 7: return "PC 7 / FSICR IA"
        case 8: return "FSICR IB"
        case 9: return "FSICR IC"
        case 10: return "Russ. Register Ice1"
        default: return nil
        }
    }

    public var lines: [String] {
        var out: [String] = []
        var a: [String] = []
        if let d = airDraught { a.append("Luftzug \(airDraughtOver ? "≥" : "")\(String(format: "%.2f", d).replacingOccurrences(of: ".", with: ",")) m") }
        if let t = tonnage { a.append("\(t) BRZ") }
        if let l = lading { a.append(l == 1 ? "beladen" : "Ballast") }
        if let p = persons { a.append("\(p) Personen") }
        if !a.isEmpty { out.append(a.joined(separator: " · ")) }
        let ports = [lastPort.map { "von \($0)" }, nextPort.map { "nach \($0)" }, secondPort.map { "dann \($0)" }].compactMap { $0 }
        if !ports.isEmpty { out.append("Häfen: " + ports.joined(separator: " · ")) }
        var b: [String] = []
        if let t = lloydsType { b.append("Lloyd's-Typ \(t)") }
        if let h = horsepower { b.append("\(h) PS") }
        if let c = iceClass, let t = Self.iceClassText(c) { b.append(t) }
        if let v = vhfChannel { b.append("UKW-Kanal \(v)") }
        if !b.isEmpty { out.append(b.joined(separator: " · ")) }
        if !failedEquipment.isEmpty { out.append("Ausgefallen: " + failedEquipment.joined(separator: ", ")) }
        return out
    }
}

public struct AISPersons: Equatable, Sendable {
    public var total: Int?
    public var crew: Int?
    public var passengers: Int?
    public var personnel: Int?

    public var text: String {
        if let t = total { return "\(t) Personen an Bord" }
        var parts: [String] = []
        if let c = crew { parts.append("\(c) Besatzung") }
        if let p = passengers { parts.append("\(p) Fahrgäste") }
        if let p = personnel { parts.append("\(p) Bordpersonal") }
        return parts.isEmpty ? "Personenzahl unbekannt" : parts.joined(separator: " · ") + " an Bord"
    }
}

/// Überwachung eines Seezeichens (GLA: Trinity House, Northern Lighthouse Board, Irish Lights)
public struct AISAtonMonitoring: Equatable, Sendable {
    public var supplyVolts: Double?
    public var externalVolts1: Double?
    public var externalVolts2: Double?
    /// 0 keins, 1 nicht überwacht, 2 in Betrieb, 3 Fehler
    public var racon: Int
    /// 0 keins, 1 an, 2 aus, 3 Fehler
    public var light: Int
    public var alarm: Bool
    public var offPosition: Bool

    public var lines: [String] {
        func v(_ x: Double) -> String { String(format: "%.2f V", x).replacingOccurrences(of: ".", with: ",") }
        var out: [String] = []
        var a: [String] = []
        if let s = supplyVolts { a.append("Versorgung \(v(s))") }
        if let s = externalVolts1 { a.append("extern 1 \(v(s))") }
        if let s = externalVolts2 { a.append("extern 2 \(v(s))") }
        if !a.isEmpty { out.append(a.joined(separator: " · ")) }
        var b: [String] = []
        switch light { case 1: b.append("Licht an"); case 2: b.append("Licht aus"); case 3: b.append("LICHT-FEHLER"); default: break }
        switch racon { case 1: b.append("RACON nicht überwacht"); case 2: b.append("RACON in Betrieb"); case 3: b.append("RACON-FEHLER"); default: break }
        b.append(alarm ? "ALARM" : "Zustand gut")
        if offPosition { b.append("AUSSER POSITION") }
        out.append(b.joined(separator: " · "))
        return out
    }
}

// MARK: - Auswertung

extension AISBinaryDecoder {
    private static func lonLat(_ lon: Double, _ lat: Double) -> GeoPoint? {
        abs(lon) <= 180 && abs(lat) <= 90 ? GeoPoint(lat: lat, lon: lon) : nil
    }

    // MARK: Gebietsmeldungen

    /// FI 22 (Typ 8, Kopf bei Bit 56) und FI 23 (Typ 6, Kopf bei Bit 88)
    static func area(_ b: AISBits, base: Int, mmsi: UInt32, addressed: UInt32?) -> AISAreaNotice? {
        let first = base + 55
        let n = b.count
        guard n >= first + 87, (n - first) % 87 < 14 else { return nil }
        let count = (n - first) / 87
        guard count >= 1, count <= 10 else { return nil }
        let month = Int(b.u(base + 17, 4)), day = Int(b.u(base + 21, 5)), hour = Int(b.u(base + 26, 5)), minute = Int(b.u(base + 31, 6))
        let dur = Int(b.u(base + 37, 18))
        var notice = AISAreaNotice(mmsi: mmsi, linkage: Int(b.u(base, 10)), notice: Int(b.u(base + 10, 7)),
                                   month: (1...12).contains(month) ? month : nil, day: (1...31).contains(day) ? day : nil,
                                   hour: hour < 24 ? hour : nil, minute: minute < 60 ? minute : nil,
                                   durationMinutes: dur == 262_143 ? nil : dur, shapes: [], addressedTo: addressed)
        var previous: GeoPoint?
        var vertices: [GeoPoint] = []
        for i in 0..<count {
            let s = first + i * 87
            let shape = Int(b.u(s, 3))
            guard shape <= 5 else { return nil }
            let scale = pow(10.0, Double(b.u(s + 3, 2)))
            func point() -> GeoPoint? { lonLat(Double(b.i(s + 5, 25)) / 60_000, Double(b.i(s + 30, 24)) / 60_000) }
            switch shape {
            case 0:
                guard let c = point() else { return nil }
                notice.shapes.append(.circle(center: c, radiusM: Double(b.u(s + 57, 12)) * scale))
                previous = c
                vertices = [c]
            case 1:
                guard let sw = point() else { return nil }
                let east = Double(b.u(s + 57, 8)) * scale, north = Double(b.u(s + 65, 8)) * scale
                let orient = Double(min(b.u(s + 73, 9), 359))
                let se = Geo.destination(from: sw, bearing: orient + 90, km: east / 1000)
                let nw = Geo.destination(from: sw, bearing: orient, km: north / 1000)
                let ne = Geo.destination(from: se, bearing: orient, km: north / 1000)
                notice.shapes.append(.rectangle(corners: [sw, se, ne, nw]))
                previous = sw
            case 2:
                guard let c = point() else { return nil }
                notice.shapes.append(.sector(center: c, radiusM: Double(b.u(s + 57, 12)) * scale, left: Double(min(b.u(s + 69, 9), 359)), right: Double(min(b.u(s + 78, 9), 359))))
                previous = c
            case 3, 4:
                // Wegpunkte (Peilung in halben Grad, Entfernung in 10^Maßstab m) ab dem Ende des vorigen Teilgebiets
                guard var cur = previous else { return nil }
                var pts: [GeoPoint] = shape == 4 ? (vertices.isEmpty ? [cur] : [vertices[0]]) : [cur]
                if shape == 4, let v0 = vertices.first { cur = v0 }
                for k in 0..<4 {
                    let bearing = Double(b.u(s + 5 + 20 * k, 10)) / 2, dist = Double(b.u(s + 15 + 20 * k, 10)) * scale
                    if dist == 0 || bearing >= 360 { break }
                    cur = Geo.destination(from: cur, bearing: bearing, km: dist / 1000)
                    pts.append(cur)
                }
                guard pts.count >= 2 else { return nil }
                if shape == 3 {
                    notice.shapes.append(.polyline(pts))
                    previous = pts.last
                } else {
                    notice.shapes.append(.polygon(pts))
                    vertices = pts
                    previous = pts.last
                }
            default:
                notice.shapes.append(.text(b.text(s + 3, chars: 14)))
            }
        }
        return notice
    }

    // MARK: Schifffahrtszeichen

    static func trafficSignal(_ b: AISBits) -> (AISTrafficSignal, GeoPoint?)? {
        guard b.count >= 258 else { return nil }
        let name = b.text(66, chars: 20)
        let hour = Int(b.u(242, 5)), minute = Int(b.u(247, 6))
        let sig = AISTrafficSignal(linkage: Int(b.u(56, 10)), station: name, status: Int(b.u(235, 2)), signal: Int(b.u(237, 5)), nextSignal: Int(b.u(253, 5)),
                                   hour: hour < 24 ? hour : nil, minute: minute < 60 ? minute : nil)
        guard sig.signal <= 13, sig.nextSignal <= 13, sig.status <= 2 else { return nil }
        let p = lonLat(Double(b.i(186, 25)) / 60_000, Double(b.i(211, 24)) / 60_000)
        return (sig, p)
    }

    // MARK: Wetterbeobachtung vom Schiff

    static let presentWeather = ["klar", "bewölkt", "Regen", "Nebel", "Schnee", "Taifun/Hurrikan", "Monsun", "Gewitter"]

    static func shipWeather(_ b: AISBits) -> AISMeteo? {
        guard b.count >= 340 else { return nil }
        var m = AISMeteo()
        m.isNewFormat = true
        m.fromShip = true
        if !b.flag(56) {
            m.locationName = b.text(57, chars: 20)
            guard let p = lonLat(Double(b.i(177, 25)) / 60_000, Double(b.i(202, 24)) / 60_000) else { return nil }
            m.latitude = p.lat; m.longitude = p.lon
            let day = Int(b.u(226, 5)), hour = Int(b.u(231, 5)), minute = Int(b.u(236, 6))
            if day >= 1 && hour < 24 && minute < 60 { m.day = day; m.hour = hour; m.minute = minute }
            let w = Int(b.u(242, 4)); if w < presentWeather.count { m.presentWeather = presentWeather[w] }
            m.visibilityGreater = b.flag(246)
            let vis = Int(b.u(247, 7)); if vis != 127 { m.visibilityNM = Double(vis) / 10 }
            let h = Int(b.u(254, 7)); if h <= 100 { m.humidity = h }
            let ws = Int(b.u(261, 7)); if ws != 127 { m.windKn = ws }
            let wd = Int(b.u(268, 9)); if wd <= 359 { m.windDir = wd }
            let p0 = Int(b.u(277, 9)); if p0 != 403 && p0 <= 402 { m.pressure = p0 == 402 ? 1201 : p0 + 799 }
            let t = b.i(290, 11); if t != -1024 && abs(t) <= 600 { m.airTemp = Double(t) / 10 }
            let wt = Int(b.u(301, 10)); if wt != 601 && wt <= 600 { m.waterTemp = (Double(wt) - 100) / 10 }
            let wp = Int(b.u(311, 6)); if wp != 63 { m.wavePeriod = wp }
            let wh = Int(b.u(317, 8)); if wh != 255 { m.waveHeight = Double(wh) / 10 }
            let wdr = Int(b.u(325, 9)); if wdr <= 359 { m.waveDir = wdr }
            let sh = Int(b.u(334, 8)); if sh != 255 { m.swellHeight = Double(sh) / 10 }
            let sd = Int(b.u(342, 9)); if sd <= 359 { m.swellDir = sd }
            let sp = Int(b.u(351, 6)); if sp != 63 { m.swellPeriod = sp }
            return m
        }
        // WMO-Fassung: Maße in m/s, Kelvin, Teilen von Grad
        let lon = Double(b.u(57, 16)) / 100 - 180, lat = Double(b.u(73, 15)) / 100 - 90
        guard b.u(57, 16) != 65_535, b.u(73, 15) != 32_767, let p = lonLat(lon, lat) else { return nil }
        m.latitude = p.lat; m.longitude = p.lon
        let day = Int(b.u(92, 6)), hour = Int(b.u(98, 5)), minute = Int(b.u(103, 3))
        if day >= 1 && day <= 31 && hour < 24 && minute <= 5 { m.day = day; m.hour = hour; m.minute = minute * 10 }
        let ms = 1.0 / 0.514444
        let tws = Int(b.u(157, 8)); if tws != 255 { m.windKn = Int((Double(tws) * 0.5 * ms).rounded()) }
        let twd = Int(b.u(150, 7)); if twd != 127 && twd <= 72 { m.windDir = twd == 0 ? nil : (twd * 5) % 360 }
        let gs = Int(b.u(180, 8)); if gs != 255 { m.gustKn = Int((Double(gs) * 0.5 * ms).rounded()) }
        let ps = Int(b.u(125, 11)); if ps <= 2000 { m.pressure = Int((Double(ps) / 10 + 900).rounded()) }
        let pt = Int(b.u(146, 4)); if pt <= 8 { m.pressureTendency = pt <= 3 ? 2 : pt == 4 ? 0 : 1 }
        let at = Int(b.u(195, 10)); if at != 1023 && at <= 1000 { m.airTemp = Double(at) / 10 + 223 - 273.15 }
        let hu = Int(b.u(205, 7)); if hu <= 100 { m.humidity = hu }
        let sst = Int(b.u(212, 9)); if sst != 511 && sst <= 500 { m.waterTemp = Double(sst) / 10 + 268 - 273.15 }
        let vis = Int(b.u(221, 6)); if vis != 63 { m.visibilityNM = Double(vis * vis) * 13.073 / 1852 }
        let wwp = Int(b.u(279, 5)); if wwp != 31 { m.wavePeriod = wwp }
        let wwh = Int(b.u(284, 6)); if wwh != 63 { m.waveHeight = Double(wwh) * 0.5 }
        let sdir = Int(b.u(290, 6)); if sdir != 63 && sdir >= 1 && sdir <= 36 { m.swellDir = (sdir * 10) % 360 }
        let sper = Int(b.u(296, 5)); if sper != 31 { m.swellPeriod = sper }
        let shh = Int(b.u(301, 6)); if shh != 63 { m.swellHeight = Double(shh) * 0.5 }
        let cog = Int(b.u(106, 7)); if cog <= 359 { m.shipCourse = cog }
        return m
    }

    // MARK: Erweiterte Reisedaten

    static func extendedShip(_ b: AISBits) -> AISExtendedShip? {
        guard b.count >= 336 else { return nil }
        func port(_ s: Int) -> String? {
            let t = b.text(s, chars: 5)
            guard t.count == 5, t.allSatisfy({ ($0.isLetter || $0.isNumber) && $0.isASCII }) else { return nil }
            return t
        }
        var e = AISExtendedShip(failedEquipment: [], operationalCount: 0)
        let ad = Int(b.u(66, 13)); if ad != 0 { e.airDraught = Double(ad) / 100; e.airDraughtOver = ad >= 8191 }
        e.lastPort = port(79); e.nextPort = port(109); e.secondPort = port(139)
        for (i, name) in AISExtendedShip.equipment.enumerated() {
            let st = Int(b.u(169 + 2 * i, 2))
            if st == 2 { e.failedEquipment.append(name) } else if st == 1 { e.operationalCount += 1 }
        }
        let ic = Int(b.u(221, 4)); if ic != 15 && ic <= 10 { e.iceClass = ic }
        let hp = Int(b.u(225, 18)); if hp != 262_143 { e.horsepower = hp }
        let vhf = Int(b.u(243, 12)); if vhf != 0 { e.vhfChannel = vhf }
        let lt = b.text(255, chars: 7); if !lt.isEmpty { e.lloydsType = lt }
        let tn = Int(b.u(297, 18)); if tn != 262_143 { e.tonnage = tn }
        let ld = Int(b.u(315, 2)); if ld == 1 || ld == 2 { e.lading = ld }
        if b.count >= 350 { let p = Int(b.u(337, 13)); if p != 0 && p < 8191 { e.persons = p } }
        // ohne irgendeine sinnvolle Angabe ist es keine solche Meldung
        guard e.airDraught != nil || e.tonnage != nil || e.lastPort != nil || e.nextPort != nil || e.persons != nil || e.operationalCount > 0 else { return nil }
        return e
    }

    // MARK: Personen, Seezeichen-Überwachung

    static func persons(_ b: AISBits, type: Int, dac: Int) -> AISPersons? {
        if dac == 200 {
            guard type == 6, b.count >= 117 else { return nil }
            let crew = Int(b.u(88, 8)), pass = Int(b.u(96, 13)), per = Int(b.u(109, 8))
            return AISPersons(total: nil, crew: crew == 255 ? nil : crew, passengers: pass == 8191 ? nil : pass, personnel: per == 255 ? nil : per)
        }
        if b.count <= 80 {
            let n = Int(b.u(56, 14)); return n == 0 ? nil : AISPersons(total: n)
        }
        guard b.count >= 101 else { return nil }
        let n = Int(b.u(88, 13))
        return n == 0 ? nil : AISPersons(total: n)
    }

    static func atonMonitoring(_ b: AISBits) -> AISAtonMonitoring? {
        guard b.count >= 132 else { return nil }
        func volts(_ s: Int) -> Double? { let v = Int(b.u(s, 10)); return v == 0 ? nil : Double(v) * 0.05 }
        return AISAtonMonitoring(supplyVolts: volts(88), externalVolts1: volts(98), externalVolts2: volts(108), racon: Int(b.u(118, 2)), light: Int(b.u(120, 2)),
                                 alarm: b.flag(122), offPosition: b.flag(131))
    }
}

extension AISPersons {
    public init(total: Int) { self.init(total: total, crew: nil, passengers: nil, personnel: nil) }
}
