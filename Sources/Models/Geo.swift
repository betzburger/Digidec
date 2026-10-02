import Foundation

// MARK: - Koordinaten und Rechnen

/// Geografischer Punkt in Grad (WGS84)
public struct GeoPoint: Equatable, Hashable, Sendable, Codable {
    public var lat: Double
    public var lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    /// Gültiger Bereich (±90° / ±180°), keine NaN
    public var isValid: Bool {
        lat.isFinite && lon.isFinite && abs(lat) <= 90 && abs(lon) <= 180
    }
}

public enum Geo {
    public static let earthRadiusKm = 6371.0

    /// Großkreis-Entfernung in km
    public static func distanceKm(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let φ1 = a.lat * .pi / 180, φ2 = b.lat * .pi / 180
        let Δφ = φ2 - φ1, Δλ = (b.lon - a.lon) * .pi / 180
        let h = sin(Δφ / 2) * sin(Δφ / 2) + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        return 2 * earthRadiusKm * asin(min(1, sqrt(h)))
    }

    /// Anfangsrichtung von `a` nach `b` in Grad (0 = Nord, im Uhrzeigersinn)
    public static func bearing(from a: GeoPoint, to b: GeoPoint) -> Double {
        let φ1 = a.lat * .pi / 180, φ2 = b.lat * .pi / 180
        let Δλ = (b.lon - a.lon) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Punkt in `km` Entfernung und Richtung `bearing` (Grad) von `a`
    public static func destination(from a: GeoPoint, bearing: Double, km: Double) -> GeoPoint {
        let δ = km / earthRadiusKm
        let θ = bearing * .pi / 180
        let φ1 = a.lat * .pi / 180, λ1 = a.lon * .pi / 180
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        var lon = λ2 * 180 / .pi
        lon = (lon + 540).truncatingRemainder(dividingBy: 360) - 180
        return GeoPoint(lat: φ2 * 180 / .pi, lon: lon)
    }

    /// „49°30,00′ N 072°45,00′ W“ (Grad und Minuten)
    public static func format(_ p: GeoPoint) -> String {
        func part(_ v: Double, _ pos: String, _ neg: String, degWidth: Int) -> String {
            let a = abs(v)
            var d = Int(a)
            var m = (a - Double(d)) * 60
            if m >= 59.995 { d += 1; m = 0 }
            let deg = String(format: "%0\(degWidth)d", d)
            let min = String(format: "%05.2f", m).replacingOccurrences(of: ".", with: ",")
            return "\(deg)°\(min)′ \(v < 0 ? neg : pos)"
        }
        return part(p.lat, "N", "S", degWidth: 2) + " " + part(p.lon, "E", "W", degWidth: 3)
    }

    /// „1.234 km“ bzw. „87 km“ (deutsches Tausendertrennzeichen entfällt: kurze Schreibweise)
    public static func formatKm(_ km: Double) -> String {
        km < 10 ? String(format: "%.1f km", km).replacingOccurrences(of: ".", with: ",") : String(format: "%.0f km", km)
    }

    /// Himmelsrichtung 8-teilig: „NO“, „SW“ …
    public static func compass(_ bearing: Double) -> String {
        let names = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        return names[Int(((bearing.truncatingRemainder(dividingBy: 360) + 360) / 45).rounded()) % 8]
    }
}

/// Maidenhead-Locator: Mittelpunkt, Entfernung, Richtung
public enum Maidenhead {
    /// Mittelpunkt des Feldes (4 oder 6 Zeichen) in Grad
    public static func coordinate(_ locator: String) -> (lat: Double, lon: Double)? {
        let l = Array(locator.uppercased())
        guard l.count == 4 || l.count == 6,
              let a = l[0].asciiValue, let b = l[1].asciiValue, let c = l[2].wholeNumberValue, let d = l[3].wholeNumberValue,
              (65...82).contains(a), (65...82).contains(b) else { return nil }
        var lon = Double(Int(a) - 65) * 20 - 180 + Double(c) * 2
        var lat = Double(Int(b) - 65) * 10 - 90 + Double(d)
        if l.count == 6, let e = l[4].asciiValue, let f = l[5].asciiValue, (65...88).contains(e), (65...88).contains(f) {
            lon += Double(Int(e) - 65) * (2.0 / 24) + 1.0 / 24
            lat += Double(Int(f) - 65) * (1.0 / 24) + 0.5 / 24
        } else {
            lon += 1
            lat += 0.5
        }
        return (lat, lon)
    }

    /// Großkreis-Entfernung in km und Richtung in Grad (0 = Nord)
    public static func distance(from a: String, to b: String) -> (km: Double, bearing: Double)? {
        guard let p = coordinate(a), let q = coordinate(b) else { return nil }
        let r = 6371.0
        let φ1 = p.lat * .pi / 180, φ2 = q.lat * .pi / 180
        let Δφ = φ2 - φ1, Δλ = (q.lon - p.lon) * .pi / 180
        let h = sin(Δφ / 2) * sin(Δφ / 2) + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        let km = 2 * r * asin(min(1, sqrt(h)))
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let bearing = (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return (km, bearing)
    }
}

extension Maidenhead {
    /// Sechsstelliger Locator für einen Punkt („JN49WS“)
    public static func locator(_ p: GeoPoint) -> String {
        let lon = p.lon + 180, lat = p.lat + 90
        let a = Int(lon / 20), b = Int(lat / 10)
        let c = Int((lon - Double(a) * 20) / 2), d = Int(lat - Double(b) * 10)
        let e = Int((lon - Double(a) * 20 - Double(c) * 2) * 12), f = Int((lat - Double(b) * 10 - Double(d)) * 24)
        func letter(_ v: Int, _ base: Character) -> Character {
            Character(UnicodeScalar(UInt8(base.asciiValue!) + UInt8(max(0, v))))
        }
        return String([letter(a, "A"), letter(b, "A"), Character("\(c)"), Character("\(d)"), letter(e, "A"), letter(f, "A")])
    }

    /// Mittelpunkt eines Locators als `GeoPoint`
    public static func point(_ locator: String) -> GeoPoint? {
        coordinate(locator).map { GeoPoint(lat: $0.lat, lon: $0.lon) }
    }
}

// MARK: - Modell der Kartenanzeige

/// Farbton eines Kartenpunkts (die Oberfläche ordnet ihn dem RadioTheme zu)
public enum MapTone: String, Sendable {
    case normal, info, highlight, alert, dim, weather
}

/// Ein Punkt auf der Karte. Jedes Modul liefert seine Punkte als `[MapMarker]`.
public struct MapMarker: Identifiable, Equatable, Sendable {
    public var id: String
    public var coordinate: GeoPoint
    /// Beschriftung neben dem Punkt (Rufzeichen, Name)
    public var title: String
    /// Zweite Zeile in der Auswahl (z. B. „144,800 MHz · 12 Pakete“)
    public var subtitle: String?
    /// Weitere Zeilen in der Auswahl
    public var details: [String]
    /// SF-Symbol-Name; `nil` = Punkt
    public var symbol: String?
    /// Kurzes Zeichen statt Symbol (z. B. Flagge als Emoji)
    public var glyph: String?
    public var tone: MapTone
    public var heardAt: Date?
    /// Bisherige Wege (älteste zuerst), endet bei `coordinate`
    public var track: [GeoPoint]
    /// Richtung in Grad für Pfeil/Kurs (nil = keine)
    public var headingDeg: Double?
    /// Radius in km für einen Kreis um den Punkt (Reichweite, Empfangsbereich); 0 = keiner
    public var radiusKm: Double

    public init(id: String, coordinate: GeoPoint, title: String, subtitle: String? = nil, details: [String] = [],
                symbol: String? = nil, glyph: String? = nil, tone: MapTone = .normal, heardAt: Date? = nil,
                track: [GeoPoint] = [], headingDeg: Double? = nil, radiusKm: Double = 0) {
        self.id = id
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
        self.details = details
        self.symbol = symbol
        self.glyph = glyph
        self.tone = tone
        self.heardAt = heardAt
        self.track = track
        self.headingDeg = headingDeg
        self.radiusKm = radiusKm
    }
}

/// Linie auf der Karte (Großkreis zwischen zwei Punkten oder Weg)
public struct MapLine: Identifiable, Equatable, Sendable {
    public var id: String
    public var points: [GeoPoint]
    public var tone: MapTone
    /// Großkreis statt gerader Linie (nur für zwei Punkte sinnvoll)
    public var geodesic: Bool

    public init(id: String, points: [GeoPoint], tone: MapTone = .dim, geodesic: Bool = false) {
        self.id = id
        self.points = points
        self.tone = tone
        self.geodesic = geodesic
    }
}

/// Alles, was eine Karte zeigt: Punkte, Linien und der eigene Standort
public struct MapContent: Equatable, Sendable {
    public var markers: [MapMarker]
    public var lines: [MapLine]
    public var home: GeoPoint?
    /// Satz unter der Karte, wenn nichts zu zeigen ist
    public var emptyHint: String

    public init(markers: [MapMarker] = [], lines: [MapLine] = [], home: GeoPoint? = nil, emptyHint: String = "Noch keine Positionen empfangen") {
        self.markers = markers
        self.lines = lines
        self.home = home
        self.emptyHint = emptyHint
    }

    private static func span(_ pts: [GeoPoint]) -> (lat: Double, lon: Double) {
        guard let f = pts.first else { return (0, 0) }
        var a = f.lat, b = f.lat, c = f.lon, d = f.lon
        for p in pts { a = min(a, p.lat); b = max(b, p.lat); c = min(c, p.lon); d = max(d, p.lon) }
        return (b - a, d - c)
    }

    /// Umschließendes Rechteck aller Punkte samt Standort (Mitte und Spannweite in Grad), nil ohne Punkte
    public func region(includeHome: Bool = true, margin: Double = 1.3) -> (center: GeoPoint, latSpan: Double, lonSpan: Double)? {
        var pts = markers.map(\.coordinate)
        for l in lines { pts += l.points }
        // Den Standort nur einbeziehen, wenn er den Ausschnitt nicht weit über die Punkte hinaus aufspannt
        // (APRS in Kalifornien, Standort in Franken: dann nur die Punkte zeigen)
        if includeHome, let h = home {
            let without = Self.span(pts)
            let with = Self.span(pts + [h])
            if pts.isEmpty || max(with.lat, with.lon) <= max(30, max(without.lat, without.lon) * 3) { pts.append(h) }
        }
        guard let first = pts.first else { return nil }
        var minLat = first.lat, maxLat = first.lat, minLon = first.lon, maxLon = first.lon
        for p in pts {
            minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
            minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon)
        }
        let latSpan = max((maxLat - minLat) * margin, 0.02)
        let lonSpan = max((maxLon - minLon) * margin, 0.02)
        return (GeoPoint(lat: (minLat + maxLat) / 2, lon: (minLon + maxLon) / 2), min(latSpan, 170), min(lonSpan, 350))
    }
}

/// Eigener Standort für Entfernungen und Linien: ein gemeinsamer Locator für alle Module
@MainActor
public final class HomeLocation: ObservableObject {
    public static let defaultLocator = "JN49WS"
    private static let key = "homeLocator"

    /// Sechsstelliger Maidenhead-Locator
    @Published public var locator: String {
        didSet {
            let v = locator.uppercased().trimmingCharacters(in: .whitespaces)
            if Maidenhead.coordinate(v) != nil {
                UserDefaults.standard.set(v, forKey: Self.key)
            }
        }
    }

    public init() {
        let d = UserDefaults.standard
        // Vorherige Version: je Modul ein eigener Locator; der erste gespeicherte wird übernommen
        let old = ["ft8Locator", "ft4Locator", "wsprLocator", "navtexLocator"].lazy.compactMap { d.string(forKey: $0) }.first { Maidenhead.coordinate($0) != nil }
        locator = d.string(forKey: Self.key).flatMap { Maidenhead.coordinate($0) != nil ? $0 : nil } ?? old ?? Self.defaultLocator
    }

    public var point: GeoPoint? { Maidenhead.point(locator) }
}
