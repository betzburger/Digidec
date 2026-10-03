import Foundation

// MARK: - Seegebiete und Küstenabschnitte des DWD

/// Ein Gebiet, das die Seewetterberichte und Sturmwarnungen des DWD nennen. Lage und Größe sind **Näherungen** (Mittelpunkt und
/// Radius eines Kreises), keine amtlichen Grenzen.
public struct SeaArea: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case sea, coast }

    public let id: String
    public let kind: Kind
    /// Name in den englischen Berichten (FQEN70/71, WODL45)
    public let english: String
    /// Name in den deutschen Berichten und für die Anzeige
    public let german: String
    public let center: GeoPoint
    public let radiusKm: Double

    /// Alle Gebiete, in der Reihenfolge der Berichte
    public static let all: [SeaArea] = [
        SeaArea(id: "germanbight", kind: .sea, english: "German Bight", german: "Deutsche Bucht", center: GeoPoint(lat: 54.3, lon: 7.2), radiusKm: 110),
        SeaArea(id: "swnorthsea", kind: .sea, english: "Southwestern North Sea", german: "Südwestliche Nordsee", center: GeoPoint(lat: 53.0, lon: 3.2), radiusKm: 160),
        SeaArea(id: "fischer", kind: .sea, english: "Fischer", german: "Fischer", center: GeoPoint(lat: 56.0, lon: 5.0), radiusKm: 150),
        SeaArea(id: "skagerrak", kind: .sea, english: "Skagerrak", german: "Skagerrak", center: GeoPoint(lat: 57.9, lon: 9.0), radiusKm: 130),
        SeaArea(id: "kattegat", kind: .sea, english: "Kattegat", german: "Kattegat", center: GeoPoint(lat: 56.8, lon: 11.5), radiusKm: 90),
        SeaArea(id: "belts", kind: .sea, english: "Belts and Sound", german: "Belte und Sund", center: GeoPoint(lat: 55.3, lon: 11.2), radiusKm: 90),
        SeaArea(id: "westbaltic", kind: .sea, english: "Western Baltic", german: "Westliche Ostsee", center: GeoPoint(lat: 54.6, lon: 11.0), radiusKm: 100),
        SeaArea(id: "southbaltic", kind: .sea, english: "Southern Baltic", german: "Südliche Ostsee", center: GeoPoint(lat: 55.1, lon: 15.0), radiusKm: 170),
        SeaArea(id: "sebaltic", kind: .sea, english: "Southeastern Baltic", german: "Südöstliche Ostsee", center: GeoPoint(lat: 55.6, lon: 19.0), radiusKm: 170),
        SeaArea(id: "eastfrisian", kind: .coast, english: "East Frisian coast", german: "Ostfriesische Küste", center: GeoPoint(lat: 53.65, lon: 7.2), radiusKm: 45),
        SeaArea(id: "elbeestuary", kind: .coast, english: "Elbe estuary", german: "Elbmündung", center: GeoPoint(lat: 53.95, lon: 8.6), radiusKm: 35),
        SeaArea(id: "helgoland", kind: .coast, english: "Helgoland", german: "Helgoland", center: GeoPoint(lat: 54.18, lon: 7.89), radiusKm: 25),
        SeaArea(id: "northfrisian", kind: .coast, english: "North Frisian coast", german: "Nordfriesische Küste", center: GeoPoint(lat: 54.6, lon: 8.7), radiusKm: 45),
        SeaArea(id: "elbehamburg", kind: .coast, english: "Elbe from Hamburg to Cuxhaven", german: "Elbe von Hamburg bis Cuxhaven", center: GeoPoint(lat: 53.72, lon: 9.3), radiusKm: 40),
        SeaArea(id: "flensburgfehmarn", kind: .coast, english: "Flensburg to Fehmarn", german: "Flensburg bis Fehmarn", center: GeoPoint(lat: 54.65, lon: 10.3), radiusKm: 55),
        SeaArea(id: "fehmarnruegen", kind: .coast, english: "East of Fehmarn to Ruegen", german: "Östlich Fehmarn bis Rügen", center: GeoPoint(lat: 54.3, lon: 12.0), radiusKm: 55),
        SeaArea(id: "bodden", kind: .coast, english: "Boddengewaesser east and east of Ruegen", german: "Boddengewässer und östlich Rügen", center: GeoPoint(lat: 54.4, lon: 13.6), radiusKm: 45)
    ]

    public static func area(id: String) -> SeaArea? { all.first { $0.id == id } }

    /// Vergleichsform eines Namens: nur Buchstaben, klein
    static func key(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.lowercaseLetters.contains($0) }.map(Character.init))
    }

    /// Das Gebiet zu einem Namen aus einem Bericht (englisch oder deutsch, Groß-/Kleinschreibung egal). Ein Zeichenfehler bei
    /// längeren Namen wird toleriert (Funkfernschreiben ist fehlerhaft). Mehrere Gebiete mit nahe liegenden Namen
    /// („Southern Baltic“ / „Southeastern Baltic“) werden nur bei exakter Übereinstimmung getrennt.
    public static func match(_ name: String) -> SeaArea? {
        let k = key(name)
        guard k.count >= 4 else { return nil }
        var best: (SeaArea, Int)?
        for a in all {
            for candidate in [a.english, a.german, a.german.folding(options: .diacriticInsensitive, locale: nil)] {
                let c = key(candidate)
                let d = editDistance(Array(k), Array(c))
                if d == 0 { return a }
                if d == 1, c.count >= 7, best == nil || d < best!.1 { best = (a, d) }
            }
        }
        // Mehrdeutig: ein Fehler könnte auch zum anderen Gebiet passen
        return best?.0
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}

// MARK: - Ortsnamen der Wetterlage

/// Länder, Meere und Regionen aus der „general synoptic situation“ („A high 1037 Belarus moves to Romania“)
public enum Gazetteer {
    struct Place { let key: String; let lat: Double; let lon: Double; let dLat: Double; let dLon: Double }

    /// Schlüssel (kleingeschrieben, Leerzeichen getrennt) → Mitte und halbe Ausdehnung in Grad. Näherungen.
    static let places: [Place] = [
        // Meere und Gewässer
        Place(key: "north sea", lat: 56.0, lon: 3.0, dLat: 4, dLon: 5), Place(key: "baltic sea", lat: 58.5, lon: 20.0, dLat: 4, dLon: 6),
        Place(key: "norwegian sea", lat: 67.0, lon: 3.0, dLat: 4, dLon: 10), Place(key: "irminger sea", lat: 61.5, lon: -35.0, dLat: 4, dLon: 8),
        Place(key: "labrador sea", lat: 58.0, lon: -53.0, dLat: 5, dLon: 8), Place(key: "barents sea", lat: 74.0, lon: 38.0, dLat: 4, dLon: 12),
        Place(key: "greenland sea", lat: 75.0, lon: -8.0, dLat: 4, dLon: 12), Place(key: "bay of biscay", lat: 45.0, lon: -5.0, dLat: 3, dLon: 4),
        Place(key: "biscay", lat: 45.0, lon: -5.0, dLat: 3, dLon: 4), Place(key: "english channel", lat: 50.0, lon: -2.0, dLat: 1, dLon: 4),
        Place(key: "mediterranean", lat: 36.0, lon: 15.0, dLat: 4, dLon: 15), Place(key: "black sea", lat: 43.5, lon: 34.0, dLat: 2.5, dLon: 6),
        Place(key: "atlantic", lat: 45.0, lon: -30.0, dLat: 10, dLon: 15), Place(key: "gulf of bothnia", lat: 63.0, lon: 21.0, dLat: 3, dLon: 3),
        Place(key: "gulf of finland", lat: 59.8, lon: 25.0, dLat: 1, dLon: 3), Place(key: "skagerrak", lat: 57.9, lon: 9.0, dLat: 1, dLon: 2),
        Place(key: "kattegat", lat: 56.8, lon: 11.5, dLat: 1, dLon: 1), Place(key: "german bight", lat: 54.3, lon: 7.2, dLat: 1, dLon: 1.5),
        Place(key: "denmark strait", lat: 66.0, lon: -27.0, dLat: 2, dLon: 5), Place(key: "davis strait", lat: 66.0, lon: -58.0, dLat: 4, dLon: 4),
        // Länder und Regionen Europas
        Place(key: "iceland", lat: 64.9, lon: -18.5, dLat: 1.5, dLon: 4), Place(key: "ireland", lat: 53.3, lon: -8.0, dLat: 1.8, dLon: 2.5),
        Place(key: "scotland", lat: 56.8, lon: -4.2, dLat: 1.8, dLon: 2.5), Place(key: "england", lat: 52.8, lon: -1.5, dLat: 2, dLon: 2),
        Place(key: "wales", lat: 52.3, lon: -3.7, dLat: 1, dLon: 1), Place(key: "great britain", lat: 54.0, lon: -2.5, dLat: 4, dLon: 3),
        Place(key: "britain", lat: 54.0, lon: -2.5, dLat: 4, dLon: 3), Place(key: "united kingdom", lat: 54.0, lon: -2.5, dLat: 4, dLon: 3),
        Place(key: "shetland", lat: 60.4, lon: -1.2, dLat: 0.6, dLon: 1), Place(key: "faroe", lat: 62.0, lon: -6.9, dLat: 0.6, dLon: 1),
        Place(key: "hebrides", lat: 57.5, lon: -7.0, dLat: 1, dLon: 1.5), Place(key: "rockall", lat: 57.5, lon: -13.7, dLat: 1, dLon: 1.5),
        Place(key: "norway", lat: 63.0, lon: 10.0, dLat: 6, dLon: 6), Place(key: "sweden", lat: 62.0, lon: 15.0, dLat: 5.5, dLon: 4),
        Place(key: "finland", lat: 63.5, lon: 26.0, dLat: 4, dLon: 4), Place(key: "denmark", lat: 56.0, lon: 9.5, dLat: 1, dLon: 2),
        Place(key: "germany", lat: 51.0, lon: 10.3, dLat: 3, dLon: 3.5), Place(key: "poland", lat: 52.0, lon: 19.3, dLat: 2.5, dLon: 4),
        Place(key: "netherlands", lat: 52.2, lon: 5.5, dLat: 1, dLon: 1), Place(key: "belgium", lat: 50.6, lon: 4.6, dLat: 0.7, dLon: 1.3),
        Place(key: "france", lat: 46.6, lon: 2.4, dLat: 4, dLon: 5), Place(key: "spain", lat: 40.0, lon: -3.7, dLat: 3.5, dLon: 5),
        Place(key: "portugal", lat: 39.5, lon: -8.0, dLat: 2.5, dLon: 1.5), Place(key: "italy", lat: 42.5, lon: 12.5, dLat: 4, dLon: 3),
        Place(key: "switzerland", lat: 46.8, lon: 8.2, dLat: 0.7, dLon: 1.3), Place(key: "austria", lat: 47.5, lon: 14.5, dLat: 0.8, dLon: 3),
        Place(key: "czech", lat: 49.8, lon: 15.5, dLat: 1, dLon: 2), Place(key: "slovakia", lat: 48.7, lon: 19.5, dLat: 0.7, dLon: 2),
        Place(key: "hungary", lat: 47.2, lon: 19.5, dLat: 1.3, dLon: 2.5), Place(key: "romania", lat: 45.9, lon: 25.0, dLat: 2, dLon: 3.5),
        Place(key: "bulgaria", lat: 42.7, lon: 25.5, dLat: 1.3, dLon: 3), Place(key: "balkans", lat: 43.0, lon: 21.0, dLat: 3, dLon: 5),
        Place(key: "greece", lat: 39.0, lon: 22.0, dLat: 2.5, dLon: 3), Place(key: "turkey", lat: 39.0, lon: 35.0, dLat: 2, dLon: 8),
        Place(key: "ukraine", lat: 49.0, lon: 32.0, dLat: 2.5, dLon: 8), Place(key: "belarus", lat: 53.7, lon: 28.0, dLat: 1.5, dLon: 4),
        Place(key: "baltic states", lat: 57.0, lon: 24.5, dLat: 1.8, dLon: 3.5), Place(key: "lithuania", lat: 55.3, lon: 23.9, dLat: 0.9, dLon: 1.7),
        Place(key: "latvia", lat: 56.9, lon: 24.8, dLat: 0.9, dLon: 2), Place(key: "estonia", lat: 58.7, lon: 25.5, dLat: 0.9, dLon: 2),
        Place(key: "russia", lat: 58.0, lon: 45.0, dLat: 8, dLon: 20), Place(key: "st petersburg", lat: 59.9, lon: 30.3, dLat: 1.5, dLon: 3),
        Place(key: "st. petersburg", lat: 59.9, lon: 30.3, dLat: 1.5, dLon: 3), Place(key: "moscow", lat: 55.8, lon: 37.6, dLat: 1.5, dLon: 3),
        Place(key: "gotland", lat: 57.5, lon: 18.5, dLat: 0.7, dLon: 1), Place(key: "bornholm", lat: 55.1, lon: 14.9, dLat: 0.3, dLon: 0.5),
        Place(key: "azores", lat: 38.5, lon: -28.0, dLat: 2, dLon: 4), Place(key: "greenland", lat: 72.0, lon: -40.0, dLat: 8, dLon: 15),
        Place(key: "svalbard", lat: 78.0, lon: 16.0, dLat: 2, dLon: 6), Place(key: "spitsbergen", lat: 78.0, lon: 16.0, dLat: 2, dLon: 6),
        Place(key: "jan mayen", lat: 71.0, lon: -8.5, dLat: 0.5, dLon: 1), Place(key: "bear island", lat: 74.4, lon: 19.0, dLat: 0.4, dLon: 1),
        Place(key: "alps", lat: 46.8, lon: 10.0, dLat: 1, dLon: 4), Place(key: "scandinavia", lat: 63.0, lon: 14.0, dLat: 6, dLon: 8),
        Place(key: "newfoundland", lat: 48.5, lon: -56.0, dLat: 3, dLon: 4), Place(key: "bristol channel", lat: 51.3, lon: -3.8, dLat: 0.4, dLon: 1.5),
        Place(key: "irish sea", lat: 53.8, lon: -5.0, dLat: 1.5, dLon: 1.5), Place(key: "biscay", lat: 45.0, lon: -5.0, dLat: 3, dLon: 4)
    ]

    private static let compass: [(word: String, dLat: Double, dLon: Double)] = [
        ("northeastern", 1, 1), ("northwestern", 1, -1), ("southeastern", -1, 1), ("southwestern", -1, -1),
        ("northeast", 1, 1), ("northwest", 1, -1), ("southeast", -1, 1), ("southwest", -1, -1),
        ("northern", 1, 0), ("southern", -1, 0), ("eastern", 0, 1), ("western", 0, -1),
        ("north", 1, 0), ("south", -1, 0), ("east", 0, 1), ("west", 0, -1)
    ]

    /// Ort einer Beschreibung wie „the northeastern part of the Irminger Sea“, „east of the St Petersburg area“,
    /// „close to the southwest of Iceland“, „southern Sweden“. nil, wenn kein bekannter Name vorkommt.
    public static func locate(_ phrase: String) -> GeoPoint? {
        let p = " " + phrase.lowercased().replacingOccurrences(of: "st. ", with: "st ").replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: ".", with: " . ")
            .split(separator: " ").joined(separator: " ") + " "
        var best: Place?
        for pl in places where p.contains(" " + pl.key + " ") || p.contains(" " + pl.key + "s ") {
            if best == nil || pl.key.count > best!.key.count { best = pl }
        }
        guard let place = best else { return nil }
        // Richtungswörter vor dem Namen
        let before = String(p[p.startIndex..<p.range(of: " " + place.key)!.lowerBound])
        var dLat = 0.0, dLon = 0.0
        var outside = false
        var words = before.split(separator: " ").map(String.init)
        // „… of the X“: Richtung außerhalb (east of Iceland) oder im Gebiet (the northern part of X)
        if let i = words.lastIndex(of: "of") {
            let head = words[..<i]
            let isPart = head.suffix(2).contains("part") || head.last == "part"
            outside = !isPart
            words = Array(head)
        }
        for w in words.reversed() {
            if let c = compass.first(where: { $0.word == w }) {
                dLat += c.dLat
                dLon += c.dLon
                break
            }
        }
        if dLat == 0 && dLon == 0 { return GeoPoint(lat: place.lat, lon: place.lon) }
        let scale = outside ? 1.5 : 0.55
        let norm = (dLat != 0 && dLon != 0) ? 0.75 : 1.0
        return GeoPoint(lat: place.lat + dLat * place.dLat * scale * norm, lon: place.lon + dLon * place.dLon * scale * norm)
    }
}

// MARK: - Berichte

/// Eine Vorhersage für ein Gebiet und einen Tag
public struct SeaForecast: Equatable, Sendable {
    public var areaID: String
    /// „friday“, „saturday“ …
    public var day: String
    public var wind: String
    public var weather: String
    public var sea: String

    /// Höchste Windstärke (Beaufort) aus dem Windtext: größte Zahl 1 … 12
    public var maxBeaufort: Int? {
        let nums = wind.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (1...12).contains($0) }
        return nums.max()
    }

    /// Windrichtung, aus der der Wind weht (Grad), nach dem ersten Richtungswort im Windtext; nil bei „light and variable“ o. Ä.
    public var windFromDeg: Double? {
        let words = wind.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let dirs: [(String, Double)] = [("northeast", 45), ("southeast", 135), ("southwest", 225), ("northwest", 315),
                                         ("north", 0), ("east", 90), ("south", 180), ("west", 270)]
        for w in words {
            for (name, deg) in dirs where w == name || w == name + "erly" || w == name + "ly" { return deg }
        }
        return nil
    }
}

/// Ein Hoch oder Tief aus der Wetterlage
public struct PressureSystem: Equatable, Sendable {
    public enum Kind: String, Sendable { case high, low }
    public var kind: Kind
    /// „high“, „deep low“, „secondary low“, „severe gale“ …
    public var name: String
    public var pressure: Int?
    public var position: GeoPoint?
    public var destination: GeoPoint?
    /// Der Satz aus dem Bericht
    public var sentence: String
}

/// Eine Front oder ein Trog aus der Wetterlage
public struct WeatherFront: Equatable, Sendable {
    public enum Kind: String, Sendable { case cold, warm, occluded, trough }
    public var kind: Kind
    public var points: [GeoPoint]
    public var sentence: String
}

/// Warnung für ein Gebiet (WODL45)
public struct SeaWarning: Equatable, Sendable {
    public var areaID: String
    /// 0 = keine Warnung, 6 = Starkwind, 8 = Sturm, 10 = schwerer Sturm, 12 = Orkan
    public var level: Int
    public var text: String
}

/// Eine Vorhersageperiode einer DWD-Punktvorhersage (z. B. "SU  4. 00Z")
public struct SeaPointPeriod: Equatable, Sendable {
    public var timeText: String
    public var windText: String
    public var gustsText: String?
    public var waveM: Double?
    public var windFromDeg: Double?
    public var maxBeaufort: Int?

    public init(timeText: String, windText: String, gustsText: String? = nil, waveM: Double? = nil, windFromDeg: Double? = nil, maxBeaufort: Int? = nil) {
        self.timeText = timeText
        self.windText = windText
        self.gustsText = gustsText
        self.waveM = waveM
        self.windFromDeg = windFromDeg
        self.maxBeaufort = maxBeaufort
    }
}

/// 5-Tage-Punktvorhersage für Seegebiete/Küstenstationen (FQEN75–79) mit Wassertemperatur (SST)
public struct SeaPointForecast: Identifiable, Equatable, Sendable {
    public var id: String { "point-" + name }
    public var name: String
    public var coordinate: GeoPoint
    public var sstC: Double?
    public var periods: [SeaPointPeriod]

    public init(name: String, coordinate: GeoPoint, sstC: Double? = nil, periods: [SeaPointPeriod] = []) {
        self.name = name
        self.coordinate = coordinate
        self.sstC = sstC
        self.periods = periods
    }

    /// Windrichtung (Grad, aus der der Wind weht)
    public static func windDeg(from dir: String) -> Double? {
        let d = dir.uppercased().trimmingCharacters(in: .whitespaces)
        let mapping: [String: Double] = [
            "N": 0, "N-NE": 22.5, "NNE": 22.5, "NE": 45, "E-NE": 67.5, "ENE": 67.5,
            "E": 90, "E-SE": 112.5, "ESE": 112.5, "SE": 135, "S-SE": 157.5, "SSE": 157.5,
            "S": 180, "S-SW": 202.5, "SSW": 202.5, "SW": 225, "W-SW": 247.5, "WSW": 247.5,
            "W": 270, "W-NW": 292.5, "WNW": 292.5, "NW": 315, "NW-N": 337.5, "NNW": 337.5,
            "SW-W": 236, "NW-W": 304, "SW-S": 214, "SE-S": 146, "SE-E": 124, "NE-E": 56,
            "NE-N": 34, "N-NW": 349
        ]
        return mapping[d]
    }

    /// Höchste Windstärke (Beaufort) aus dem Text
    public static func beaufort(from speed: String) -> Int? {
        let nums = speed.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (1...12).contains($0) }
        return nums.max()
    }
}

/// Was aus dem Text der Seewetterberichte und Sturmwarnungen gelesen wurde
public struct SeaReport: Equatable, Sendable {
    public var issued: String?
    public var synopsis: String = ""
    public var systems: [PressureSystem] = []
    public var fronts: [WeatherFront] = []
    public var forecasts: [SeaForecast] = []
    public var warnings: [SeaWarning] = []
    /// Positionen aus Nautischen Warnnachrichten und anderem Text („54-12N 007-30E“)
    public var positions: [NauticalPosition] = []
    /// 5-Tage-Punktvorhersagen für Seegebiete/Küstenstationen mit SST (FQEN75–79)
    public var points: [SeaPointForecast] = []
    public var isEmpty: Bool { forecasts.isEmpty && systems.isEmpty && fronts.isEmpty && warnings.isEmpty && positions.isEmpty && points.isEmpty }

    /// Tage in der Reihenfolge ihres Auftretens
    public var days: [String] {
        var out: [String] = []
        for f in forecasts where !out.contains(f.day) { out.append(f.day) }
        return out
    }
}

/// Liest die englischen Seewetterberichte (FQEN70 „weather and sea bulletin for north- and baltic sea“, FQEN71 „weatherreport for
/// German coast“) und die Sturmwarnungen (WODL45). Der Text kommt per Funkfernschreiben: nur Großbuchstaben, Fehler möglich,
/// Anfang oder Ende können fehlen. Gelesen wird deshalb stichwortartig: Gebietsname mit Doppelpunkt, darunter `wind:`,
/// `visibility/weather:`, `sea:` (jeweils über mehrere Zeilen).
public enum SeaBulletinParser {
    static let dayNames = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tonight", "tomorrow"]

    public static func parse(_ rawText: String) -> SeaReport {
        var report = SeaReport()
        // Steuerzeichen des Fernschreibers (SOH, STX, ETX, EOT …) stören die Zeilenanfänge
        let cleanedText = String(String.UnicodeScalarView(rawText.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\r" || $0 == "\t" }))
        let lines = cleanedText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        var i = 0
        var day = "forecast"      // ohne Tagesüberschrift (Empfang mitten im Bericht): „Vorhersage“
        var area: SeaArea?
        var field: String?
        var values: [String: String] = [:]
        var inSynopsis = false
        var synopsis: [String] = []
        var warningArea: SeaArea?
        var warningLines: [String] = []
        var inWarnings = false

        // 5-Tage-Punktvorhersagen mit SST (z. B. „WN.O.IRELAND (54.0N  13.9W) SST: 14 C“)
        let pointHeaderRE = try? NSRegularExpression(
            pattern: #"^([A-Z0-9.\-]+(?:\s+[A-Z0-9.\-]+)*)\s*\(\s*(\d{1,2}(?:[.,]\d+)?)\s*([NS])\s+(\d{1,3}(?:[.,]\d+)?)\s*([EW])\s*\)\s*SST:?\s*(-?\d+(?:[.,]\d+)?)\s*C"#,
            options: [.caseInsensitive]
        )
        let periodLineRE = try? NSRegularExpression(
            pattern: #"^(?:([A-Z]{1,2})\s+)?(\d{1,2})[.:\s\d]*?(\d{2})Z:\s*(.*)$"#,
            options: [.caseInsensitive]
        )
        let dirRE = try? NSRegularExpression(
            pattern: #"\b(N-NE|N-NW|S-SW|S-SE|W-NW|W-SW|E-NE|E-SE|NW-N|NE-N|SW-S|SE-S|SW-W|NW-W|SE-E|NE-E|NNE|NNW|SSE|SSW|ENE|ESE|WNW|WSW|N|NE|E|SE|S|SW|W|NW|VAR)\b"#,
            options: [.caseInsensitive]
        )
        let waveRE = try? NSRegularExpression(pattern: #"(\d+(?:[.,]\d+)?)\s*M\b"#, options: [.caseInsensitive])
        let speedRE = try? NSRegularExpression(pattern: #"\b(\d{1,2}(?:-\d{1,2})?)\b"#)
        var currentPoint: SeaPointForecast?

        func finishPoint() {
            if let p = currentPoint {
                report.points.removeAll { $0.name == p.name }
                report.points.append(p)
            }
            currentPoint = nil
        }
        func finishForecast() {
            if let a = area, !day.isEmpty, !values.isEmpty {
                report.forecasts.removeAll { $0.areaID == a.id && $0.day == day }
                report.forecasts.append(SeaForecast(areaID: a.id, day: day, wind: values["wind"] ?? "", weather: values["visibility/weather"] ?? values["weather"] ?? "",
                                                    sea: values["sea"] ?? ""))
            }
            values = [:]
            field = nil
        }
        func finishWarning() {
            if let a = warningArea {
                let text = warningLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                report.warnings.removeAll { $0.areaID == a.id }
                report.warnings.append(SeaWarning(areaID: a.id, level: warningLevel(text), text: text))
            }
            warningArea = nil
            warningLines = []
        }

        while i < lines.count {
            let line = lines[i]
            i += 1
            let low = line.lowercased()
            if low.isEmpty { continue }

            // Punktvorhersage-Kopf: z. B. „WN.O.IRELAND (54.0N  13.9W) SST: 14 C“
            if let phRE = pointHeaderRE,
               let m = phRE.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                finishForecast()
                finishWarning()
                finishPoint()
                inSynopsis = false
                func g(_ idx: Int) -> String { Range(m.range(at: idx), in: line).map { String(line[$0]) } ?? "" }
                let name = g(1).trimmingCharacters(in: .whitespaces)
                var lat = Double(g(2).replacingOccurrences(of: ",", with: ".")) ?? 0
                if g(3).uppercased() == "S" { lat = -lat }
                var lon = Double(g(4).replacingOccurrences(of: ",", with: ".")) ?? 0
                if g(5).uppercased() == "W" { lon = -lon }
                let sst = Double(g(6).replacingOccurrences(of: ",", with: "."))
                currentPoint = SeaPointForecast(name: name, coordinate: GeoPoint(lat: lat, lon: lon), sstC: sst, periods: [])
                continue
            }
            if currentPoint != nil, let plRE = periodLineRE,
               let m = plRE.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                func g(_ idx: Int) -> String { Range(m.range(at: idx), in: line).map { String(line[$0]) } ?? "" }
                let day = g(1).trimmingCharacters(in: .whitespaces)
                let dateNum = g(2)
                let hour = g(3)
                let rest = g(4)
                var dir = ""
                var wave: Double?
                let rns = rest as NSString
                let rrng = NSRange(location: 0, length: rns.length)
                if let dRE = dirRE, let dm = dRE.firstMatch(in: rest, range: rrng), let dr = Range(dm.range, in: rest) {
                    dir = String(rest[dr]).uppercased()
                }
                if let wRE = waveRE, let wm = wRE.firstMatch(in: rest, range: rrng), let wr = Range(wm.range(at: 1), in: rest) {
                    wave = Double(rest[wr].replacingOccurrences(of: ",", with: "."))
                }
                var cut = rest
                if let sl = cut.range(of: "//") { cut = String(cut[..<sl.lowerBound]) }
                if let wRE = waveRE, let wm = wRE.firstMatch(in: cut, range: NSRange(location: 0, length: (cut as NSString).length)) {
                    cut = (cut as NSString).substring(to: wm.range.location)
                }
                if !dir.isEmpty, let dr = cut.range(of: dir, options: .caseInsensitive) {
                    cut = String(cut[dr.upperBound...])
                }
                let speeds = speedRE?.matches(in: cut, range: NSRange(location: 0, length: (cut as NSString).length)).map {
                    (cut as NSString).substring(with: $0.range(at: 1))
                } ?? []
                let speed = speeds.first ?? ""
                let gusts = speeds.count > 1 ? speeds[1] : nil
                let timeStr = (day.isEmpty ? "" : day + " ") + "\(dateNum). \(hour)Z"
                let windFrom = SeaPointForecast.windDeg(from: dir)
                let bft = SeaPointForecast.beaufort(from: speed)
                currentPoint?.periods.append(SeaPointPeriod(timeText: timeStr, windText: (dir.isEmpty ? "" : dir + " ") + speed, gustsText: gusts, waveM: wave, windFromDeg: windFrom, maxBeaufort: bft))
                continue
            }
            // Ausgabezeit „02.10.2026, 1700 UTC:“
            if let r = low.range(of: #"\d{2}\.\d{2}\.\d{4},?\s*\d{2,4}\s*(utc|z)"#, options: .regularExpression) {
                report.issued = String(line[r])
            }
            if low.hasPrefix("strong wind, gale and storm warnings") { inWarnings = true; inSynopsis = false; finishForecast(); finishPoint(); continue }
            if inWarnings {
                if low.hasPrefix("coastal area warnings") || low.hasPrefix("starkwind") { finishWarning(); inWarnings = false; continue }
                if low.hasSuffix(":"), let a = SeaArea.match(String(low.dropLast())) {
                    finishWarning()
                    warningArea = a
                } else if warningArea != nil {
                    warningLines.append(line)
                }
                continue
            }
            if low.hasPrefix("general synoptic situation") || low.hasPrefix("wetterlage") {
                finishForecast()
                finishPoint()
                inSynopsis = true
                synopsis = []                       // der zuletzt gesendete Bericht zählt
                let rest = line.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { synopsis.append(rest) }
                continue
            }
            // Tagesüberschrift: „Forecast Friday:“, „Forecast for Friday“
            if low.hasPrefix("forecast") || low.hasPrefix("outlook") {
                let words = low.split(whereSeparator: { !$0.isLetter }).map(String.init)
                if let d = words.first(where: { dayNames.contains($0) }) {
                    finishForecast()
                    finishPoint()
                    inSynopsis = false
                    day = d
                    area = nil
                    continue
                }
            }
            // Feldzeile: „wind: …“
            if let colon = low.firstIndex(of: ":"), ["wind", "visibility/weather", "weather", "sea"].contains(String(low[low.startIndex..<colon]).trimmingCharacters(in: .whitespaces)),
               area != nil {
                let name = String(low[low.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                field = name
                values[name] = rest
                inSynopsis = false
                continue
            }
            // Gebietsüberschrift: „German Bight:“
            if low.hasSuffix(":"), let a = SeaArea.match(String(low.dropLast())) {
                finishForecast()
                finishPoint()
                inSynopsis = false
                area = a
                continue
            }
            if inSynopsis {
                synopsis.append(line)
                continue
            }
            // Fortsetzungszeile eines Feldes
            if let f = field, area != nil, !low.hasPrefix("windforce") {
                values[f] = (values[f] ?? "") + " " + line
            }
        }
        finishForecast()
        finishWarning()
        finishPoint()
        report.synopsis = synopsis.joined(separator: " ").replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        (report.systems, report.fronts) = SynopsisParser.parse(report.synopsis)
        report.positions = NauticalPositions.extract(cleanedText)
        return report
    }

    /// Warnstufe aus dem Warntext: „no warning“ = 0; sonst die genannte Stärke, sonst nach dem Wort
    static func warningLevel(_ text: String) -> Int {
        let t = text.lowercased()
        if t.isEmpty || t.contains("no warning") || t.contains("keine warnung") { return 0 }
        let nums = t.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (6...12).contains($0) }
        if let m = nums.max() { return m }
        if t.contains("hurricane") || t.contains("orkan") { return 12 }
        if t.contains("storm") || t.contains("sturm") { return 10 }
        if t.contains("gale") { return 8 }
        if t.contains("strong wind") || t.contains("starkwind") { return 6 }
        return 8
    }
}

/// Zerlegt die Wetterlage in Hochs, Tiefs und Fronten
enum SynopsisParser {
    static func parse(_ text: String) -> (systems: [PressureSystem], fronts: [WeatherFront]) {
        var systems: [PressureSystem] = []
        var fronts: [WeatherFront] = []
        // Sätze: Punkt, Leerzeichen, Großbuchstabe (Zahlen wie „1,5“ und „St.“ bleiben heil)
        let flat = text.replacingOccurrences(of: "St. ", with: "St ").replacingOccurrences(of: "St.", with: "St ")
        var sentences: [String] = []
        var cur = ""
        let chars = Array(flat)
        for (i, c) in chars.enumerated() {
            cur.append(c)
            if c == ".", i + 1 >= chars.count || chars[i + 1] == " " || chars[i + 1].isNewline {
                sentences.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
            }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(cur.trimmingCharacters(in: .whitespaces)) }
        for s in sentences {
            let low = s.lowercased()
            if let f = front(in: low, sentence: s) { fronts.append(f); continue }
            if let sys = system(in: low, sentence: s) { systems.append(sys) }
        }
        return (systems, fronts)
    }

    private static let stop = ["moves", "move", "weakens", "weaken", "weakening", "will", "extends", "extending", "hardly", "remains", "slowly", "is ", "merges",
                               "intensifies", "intensify", "shifts", "expands", "deepens", "fills", "disappears", "reaches", "reach", "while", "and ", "drifts", "stays",
                               "strengthens", "strengthening", "moving", "becoming", "stationary", "persists"]

    /// „A deep low 965 close to the southwest of Iceland, moves to …“
    static func system(in low: String, sentence: String) -> PressureSystem? {
        let kinds: [(String, PressureSystem.Kind)] = [("severe gale", .low), ("deep storm", .low), ("deep low", .low), ("secondary low", .low), ("shallow low", .low),
                                                      ("low", .low), ("depression", .low), ("storm", .low), ("gale", .low), ("high", .high)]
        var found: (String, PressureSystem.Kind, Range<String.Index>)?
        for (name, kind) in kinds {
            if let r = low.range(of: #"\b"# + name + #"\b"#, options: .regularExpression) {
                if found == nil || r.lowerBound < found!.2.lowerBound || (r.lowerBound == found!.2.lowerBound && name.count > found!.0.count) { found = (name, kind, r) }
            }
        }
        guard let (name, kind, r) = found else { return nil }
        var rest = String(low[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        var pressure: Int?
        if let pr = rest.range(of: #"^\(?\d{3,4}\)?"#, options: .regularExpression) {
            pressure = Int(rest[pr].filter(\.isNumber))
            rest = String(rest[pr.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        // Ort: bis zum ersten Verb
        var locationEnd = rest.endIndex
        for w in stop {
            if let rr = rest.range(of: #"(^|[\s,])"# + NSRegularExpression.escapedPattern(for: w), options: .regularExpression), rr.lowerBound < locationEnd { locationEnd = rr.lowerBound }
        }
        let locationText = String(rest[rest.startIndex..<locationEnd]).trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        let afterLocation = String(rest[locationEnd...])
        // Ziele: je Teilsatz „moves to X“, „will reach X“ („… will reach Scotland on Friday evening and move to the Norwegian Sea“)
        var targets: [GeoPoint] = []
        for clause in afterLocation.components(separatedBy: " and ") {
            guard let m = clause.range(of: #"(moves?|shifts?|drifts?|reach(es)?|moving)\s+(slowly\s+|quickly\s+|further\s+)?(to|towards|over|across)?\s*"#, options: .regularExpression) else { continue }
            var cut = String(clause[m.upperBound...])
            for w in [" while", " on ", " until", ",", ".", " intensif", " weaken", " deepen"] {
                if let rr = cut.range(of: w) { cut = String(cut[cut.startIndex..<rr.lowerBound]) }
            }
            if let p = Gazetteer.locate(cut.trimmingCharacters(in: .whitespaces)) { targets.append(p) }
        }
        let here = Gazetteer.locate(locationText) ?? (locationText.isEmpty ? targets.first : nil)
        let destination = targets.count > (locationText.isEmpty ? 1 : 0) ? targets.last : nil
        return PressureSystem(kind: kind, name: name, pressure: pressure, position: here, destination: destination, sentence: sentence)
    }

    /// „The associated cold front extends from southern Sweden to eastern Germany and moves to the Baltic States.“
    static func front(in low: String, sentence: String) -> WeatherFront? {
        let kinds: [(String, WeatherFront.Kind)] = [("cold front", .cold), ("warm front", .warm), ("occlusion", .occluded), ("occluded front", .occluded), ("trough", .trough)]
        guard let (_, kind) = kinds.first(where: { low.contains($0.0) }) else { return nil }
        var points: [GeoPoint] = []
        if let r = low.range(of: #"from\s+(.+?)\s+to\s+(.+?)(\s+and\s|\s+on\s|,|\.|$)"#, options: .regularExpression) {
            let seg = String(low[r])
            let parts = seg.replacingOccurrences(of: "from ", with: "").components(separatedBy: " to ")
            if parts.count >= 2 {
                var a = parts[0]
                var b = parts[1]
                for w in [" and ", " on ", ",", "."] { if let rr = b.range(of: w) { b = String(b[b.startIndex..<rr.lowerBound]) } }
                a = a.trimmingCharacters(in: .whitespaces)
                if let pa = Gazetteer.locate(a), let pb = Gazetteer.locate(b.trimmingCharacters(in: .whitespaces)) { points = [pa, pb] }
            }
        }
        if points.isEmpty, let r = low.range(of: #"(over|across)\s+the\s+(.+?)(\s+and\s|\s+southwards|\s+northwards|,|\.|$)"#, options: .regularExpression),
           let p = Gazetteer.locate(String(low[r])) {
            points = [p]
        }
        return WeatherFront(kind: kind, points: points, sentence: sentence)
    }
}


// MARK: - Übersetzung der Berichtssprache

/// Die DWD-Berichte sind formelhaft (rund 150 Wörter): Wind, Sicht/Wetter und Seegang lassen sich Wort für Wort ins Deutsche bringen.
/// Unbekanntes bleibt englisch.
public enum SeaPhrase {
    private static let phrases: [(String, String)] = [
        ("light and variable winds", "schwache umlaufende Winde"), ("coastal fog patches", "Küstennebelfelder"), ("fog patches", "Nebelfelder"),
        ("good visibility", "gute Sicht"), ("poor visibility", "schlechte Sicht"), ("moderate visibility", "mäßige Sicht"),
        ("for a time", "zeitweise"), ("at times", "zeitweise"), ("northeastern part", "Nordostteil"), ("northwestern part", "Nordwestteil"),
        ("southeastern part", "Südostteil"), ("southwestern part", "Südwestteil"), ("northern part", "Nordteil"), ("southern part", "Südteil"),
        ("eastern part", "Ostteil"), ("western part", "Westteil"), ("southwesterly winds", "südwestliche Winde"), ("northwesterly winds", "nordwestliche Winde"),
        ("southeasterly winds", "südöstliche Winde"), ("northeasterly winds", "nordöstliche Winde"), ("westerly winds", "westliche Winde"),
        ("easterly winds", "östliche Winde"), ("southerly winds", "südliche Winde"), ("northerly winds", "nördliche Winde"), ("variable winds", "umlaufende Winde"),
        ("shifting slowly", "langsam drehend"), ("slowly shifting", "langsam drehend"), ("with rain", "mit Regen"), ("with showers", "mit Schauern")
    ]
    private static let words: [String: String] = [
        "to": "bis", "about": "um", "later": "später", "first": "zunächst", "locally": "örtlich", "otherwise": "sonst", "and": "und", "with": "mit",
        "shifting": "drehend", "veering": "rechtsdrehend", "backing": "linksdrehend", "increasing": "zunehmend", "decreasing": "abnehmend", "abating": "abflauend",
        "slowly": "langsam", "below": "unter", "meter": "Meter", "rain": "Regen", "shower": "Schauer", "showers": "Schauer", "fog": "Nebel", "poor": "schlechte",
        "good": "gute", "moderate": "mäßige", "visibility": "Sicht", "south": "Süd", "north": "Nord", "east": "Ost", "west": "West",
        "southwest": "Südwest", "southeast": "Südost", "northwest": "Nordwest", "northeast": "Nordost", "southerly": "südliche", "northerly": "nördliche",
        "westerly": "westliche", "easterly": "östliche", "southwesterly": "südwestliche", "northwesterly": "nordwestliche", "southeasterly": "südöstliche",
        "northeasterly": "nordöstliche", "part": "Teil", "coastal": "Küsten", "winds": "Winde", "wind": "Wind", "light": "schwach", "variable": "umlaufend",
        "for": "für", "time": "Zeit", "at": "bei", "a": "ein", "the": "", "of": "von", "in": "in", "on": "am", "humber": "Humber", "thames": "Themse",
        "northern": "nördlich", "southern": "südlich", "eastern": "östlich", "western": "westlich", "abating.": "abflauend."
    ]

    /// Englischer Text eines Berichtsfelds ins Deutsche (Wort für Wort, mit festen Wendungen); der erste Buchstabe wird groß
    public static func german(_ text: String) -> String {
        var t = " " + text.lowercased() + " "
        for (en, de) in phrases {
            t = t.replacingOccurrences(of: " " + en + " ", with: " " + de + " ")
            t = t.replacingOccurrences(of: " " + en + ",", with: " " + de + ",")
            t = t.replacingOccurrences(of: " " + en + ".", with: " " + de + ".")
        }
        var out: [String] = []
        for token in t.split(separator: " ") {
            var w = String(token)
            var tail = ""
            while let last = w.last, ",.;".contains(last) { tail = String(last) + tail; w.removeLast() }
            if let de = words[w] {
                if de.isEmpty { continue }
                out.append(de + tail)
            } else {
                out.append(w + tail)
            }
        }
        let joined = out.joined(separator: " ")
        guard let first = joined.first else { return joined }
        return first.uppercased() + joined.dropFirst()
    }

    /// „friday“ → „Freitag“
    public static func germanDay(_ day: String) -> String {
        ["monday": "Montag", "tuesday": "Dienstag", "wednesday": "Mittwoch", "thursday": "Donnerstag", "friday": "Freitag", "saturday": "Samstag",
         "sunday": "Sonntag", "forecast": "Vorhersage", "today": "Heute", "tonight": "Heute Nacht", "tomorrow": "Morgen"][day] ?? day.capitalized
    }
}

// MARK: - Aufgezeichneter Text und Karte

/// Sammelt den empfangenen Rohtext und liefert daraus die Karte der Seegebiete, Hochs, Tiefs, Fronten und Warnungen.
public final class SeaLog {
    public static let maxCharacters = 40_000
    private var buffer = ""
    private var dirty = false
    private var cached = SeaReport()
    public private(set) var lastUpdate: Date?

    public init() {}

    public func clear() {
        buffer = ""
        cached = SeaReport()
        dirty = false
        lastUpdate = nil
    }

    /// Rohtext aufnehmen (Klartext der SYNOP-Decodierung zählt nicht)
    public func feed(_ s: String, decoded: Bool, at date: Date = Date()) {
        guard !decoded, !s.isEmpty else { return }
        buffer += s
        if buffer.count > Self.maxCharacters { buffer = String(buffer.suffix(Self.maxCharacters * 3 / 4)) }
        dirty = true
        lastUpdate = date
    }

    public var report: SeaReport {
        if dirty {
            cached = SeaBulletinParser.parse(buffer)
            dirty = false
        }
        return cached
    }

    private static func tone(forBeaufort b: Int) -> MapTone {
        switch b {
        case ..<4: return .info
        case 4..<6: return .normal
        case 6..<8: return .highlight
        default: return .alert
        }
    }

    public func content(home: GeoPoint?, now: Date, transmitters: [TransmitterSite] = []) -> MapContent {
        let r = report
        var markers: [MapMarker] = []
        var lines: [MapLine] = []
        let days = r.days
        let firstDay = days.first ?? ""
        let stand = r.issued.map { "Stand \($0)" }

        // Vorhersage je Gebiet (erster Tag auf der Karte, alle Tage im Popup)
        var areaIDs: [String] = []
        for f in r.forecasts where !areaIDs.contains(f.areaID) { areaIDs.append(f.areaID) }
        for id in areaIDs {
            guard let area = SeaArea.area(id: id) else { continue }
            let fs = r.forecasts.filter { $0.areaID == id }
            let primary = fs.first { $0.day == firstDay } ?? fs[0]
            var details: [String] = []
            for f in fs {
                details.append("\(SeaPhrase.germanDay(f.day)): Wind \(SeaPhrase.german(f.wind))")
                if !f.weather.isEmpty { details.append("   Sicht/Wetter: \(SeaPhrase.german(f.weather))") }
                if !f.sea.isEmpty { details.append("   Seegang: \(SeaPhrase.german(f.sea))") }
            }
            if let s = stand { details.append(s) }
            let bft = primary.maxBeaufort
            var m = MapMarker(id: "sea-" + id, coordinate: area.center, title: area.german,
                              subtitle: "\(SeaPhrase.germanDay(primary.day)) · " + (bft.map { "Wind bis Bft \($0)" } ?? "Wind"), details: details,
                              symbol: bft == nil ? "wind" : nil, tone: bft.map { Self.tone(forBeaufort: $0) } ?? .info,
                              radiusKm: area.kind == .sea ? area.radiusKm : 0)
            if let b = bft {
                m.valueText = "\(b)"
                m.valueLevel = min(max(Double(b) / 10, 0), 1)
                if let from = primary.windFromDeg { m.headingDeg = (from + 180).truncatingRemainder(dividingBy: 360) }
            }
            markers.append(m)
        }
        // Warnungen: auffällig über der Vorhersage
        for w in r.warnings where w.level > 0 {
            guard let area = SeaArea.area(id: w.areaID) else { continue }
            markers.append(MapMarker(id: "warn-" + w.areaID, coordinate: GeoPoint(lat: area.center.lat + 0.35, lon: area.center.lon), title: "Warnung \(area.german)",
                                     subtitle: "Windstärke \(w.level)", details: [w.text], symbol: "exclamationmark.triangle.fill", tone: .alert, radiusKm: area.radiusKm))
        }
        // Hochs und Tiefs
        for (i, sys) in r.systems.enumerated() {
            guard let p = sys.position else { continue }
            let high = sys.kind == .high
            var details = [sys.sentence]
            if let d = sys.destination { details.append("Zugrichtung: \(Geo.compass(Geo.bearing(from: p, to: d))), \(Geo.formatKm(Geo.distanceKm(p, d)))") }
            markers.append(MapMarker(id: "system-\(i)", coordinate: p, title: (high ? "Hoch " : "Tief ") + (sys.pressure.map { "\($0) hPa" } ?? ""),
                                     subtitle: high ? "Hochdruckgebiet" : "Tiefdruckgebiet", details: details,
                                     tone: high ? .info : .alert, valueText: (high ? "H " : "T ") + (sys.pressure.map(String.init) ?? ""),
                                     valueLevel: high ? 0.02 : 0.97))
            if let d = sys.destination { lines.append(MapLine(id: "system-move-\(i)", points: [p, d], tone: high ? .info : .alert)) }
        }
        // Positionen aus Nautischen Warnnachrichten
        for (i, n) in r.positions.enumerated() {
            markers.append(MapMarker(id: "nav-\(i)", coordinate: n.point, title: "Warnung bei " + Geo.format(n.point), subtitle: "Position im Text (Nautische Warnung)",
                                     details: [n.context], symbol: "exclamationmark.triangle", tone: .highlight))
        }
        // Fronten
        for (i, f) in r.fronts.enumerated() {
            let tone: MapTone = f.kind == .cold ? .info : f.kind == .warm ? .alert : f.kind == .occluded ? .highlight : .dim
            if f.points.count >= 2 {
                lines.append(MapLine(id: "front-\(i)", points: f.points, tone: tone))
                let mid = GeoPoint(lat: (f.points[0].lat + f.points[1].lat) / 2, lon: (f.points[0].lon + f.points[1].lon) / 2)
                markers.append(MapMarker(id: "front-\(i)", coordinate: mid, title: Self.frontName(f.kind), subtitle: "Front laut Wetterlage", details: [f.sentence],
                                         symbol: "chevron.forward.2", tone: tone))
            } else if let p = f.points.first {
                markers.append(MapMarker(id: "front-\(i)", coordinate: p, title: Self.frontName(f.kind), subtitle: "Front laut Wetterlage", details: [f.sentence],
                                         symbol: "chevron.forward.2", tone: tone))
            }
        }
        // 5-Tage-Punktvorhersagen (Offshore) mit Wassertemperatur (SST)
        markers += pointMarkers(home: home, layer: .sea)

        var c = TransmitterMap.content(transmitters, home: home)
        c.markers += markers
        c.lines += lines
        c.emptyHint = "Noch kein Seewetterbericht (FQEN70/71) und keine Sturmwarnung empfangen"
        return c
    }

    private static func fmt(_ v: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
    }

    private static func formatPeriodTime(_ s: String) -> String {
        var t = s
        let days: [(String, String)] = [
            ("SU", "So"), ("MO", "Mo"), ("TU", "Di"), ("WE", "Mi"), ("TH", "Do"), ("FR", "Fr"), ("SA", "Sa")
        ]
        for (en, de) in days {
            if t.hasPrefix(en + " ") {
                t = de + t.dropFirst(en.count)
                break
            }
        }
        return t
    }

    /// Karten-Marker für die Punktvorhersagen (SST, Wind, Symbol)
    public func pointMarkers(home: GeoPoint?, layer: SynopLog.Layer) -> [MapMarker] {
        var markers: [MapMarker] = []
        for p in report.points {
            guard p.coordinate.isValid else { continue }
            var details: [String] = [Geo.format(p.coordinate)]
            if let h = home {
                details.append(Geo.formatKm(Geo.distanceKm(h, p.coordinate)) + " " + Geo.compass(Geo.bearing(from: h, to: p.coordinate)))
            }
            if let sst = p.sstC {
                details.append("Wassertemperatur (SST): \(Self.fmt(sst, digits: sst == sst.rounded() ? 0 : 1)) °C")
            }
            for per in p.periods {
                var line = "\(Self.formatPeriodTime(per.timeText)): "
                if !per.windText.isEmpty {
                    line += "Wind \(per.windText) Bft"
                    if let g = per.gustsText { line += " (Böen \(g))" }
                }
                if let w = per.waveM {
                    line += (line.hasSuffix(": ") ? "" : ", ") + "Seegang \(Self.fmt(w, digits: 1)) m"
                }
                details.append(line)
            }
            details.append("Quelle: DWD Seewetter-Punktvorhersage")

            let sstStr = p.sstC.map { " · SST \(Self.fmt($0, digits: 0)) °C" } ?? ""
            var m = MapMarker(id: "point-" + p.name, coordinate: p.coordinate, title: p.name,
                              subtitle: "Punktvorhersage" + sstStr, details: details,
                              symbol: "water.waves", tone: .weather)

            switch layer {
            case .symbol:
                m.symbol = "water.waves"
            case .temperature:
                guard let sst = p.sstC else { continue }
                m.symbol = nil
                m.valueText = Self.fmt(sst, digits: abs(sst) < 10 && sst != sst.rounded() ? 1 : 0)
                m.valueLevel = min(max((sst + 20) / 55, 0), 1)
                m.subtitle = "Wassertemperatur \(Self.fmt(sst, digits: 0)) °C (SST)"
            case .wind:
                if let first = p.periods.first(where: { $0.maxBeaufort != nil || $0.windFromDeg != nil }) {
                    m.symbol = nil
                    m.valueText = first.windText
                    if let b = first.maxBeaufort { m.valueLevel = min(max(Double(b) / 10, 0), 1) }
                    if let deg = first.windFromDeg {
                        m.headingDeg = (deg + 180).truncatingRemainder(dividingBy: 360)
                    }
                    m.subtitle = "Wind \(first.windText) Bft"
                } else {
                    continue
                }
            case .pressure, .visibility:
                continue
            case .sea:
                m.symbol = "water.waves"
                m.valueText = p.sstC.map { Self.fmt($0, digits: 0) + "°" }
            }
            markers.append(m)
        }
        return markers
    }

    static func frontName(_ k: WeatherFront.Kind) -> String {
        switch k {
        case .cold: return "Kaltfront"
        case .warm: return "Warmfront"
        case .occluded: return "Okklusion"
        case .trough: return "Trog"
        }
    }
}


// MARK: - Positionen in Warnnachrichten

/// Eine Position im Text mit dem Absatz, in dem sie steht
public struct NauticalPosition: Equatable, Sendable {
    public var point: GeoPoint
    public var context: String
}

/// Findet Positionen wie „54-12.5N 007-30.2E“, „54 12N 007 30E“, „54°12′N 007°30′E“ und „5412N 00730E“ im Text
public enum NauticalPositions {
    private static let spaced = try! NSRegularExpression(
        pattern: #"(\d{1,2})\s?[-°]\s?(\d{2}(?:[.,]\d+)?)\s?['′]?\s*([NS])[\s,;/]*(\d{1,3})\s?[-°]\s?(\d{2}(?:[.,]\d+)?)\s?['′]?\s*([EW])"#)
    private static let compact = try! NSRegularExpression(pattern: #"\b(\d{2})(\d{2})([NS])[\s,;/]*(\d{3})(\d{2})([EW])\b"#)

    public static func extract(_ text: String, limit: Int = 60) -> [NauticalPosition] {
        var out: [NauticalPosition] = []
        // Absätze: durch Leerzeilen getrennt; lange Absätze werden auf die Umgebung der Position gekürzt
        let paragraphs = text.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n\n")
        for para in paragraphs {
            let ns = para as NSString
            let range = NSRange(location: 0, length: ns.length)
            var found: [(Int, GeoPoint)] = []
            for re in [spaced, compact] {
                for m in re.matches(in: para, range: range) {
                    func num(_ i: Int) -> Double { Double(ns.substring(with: m.range(at: i)).replacingOccurrences(of: ",", with: ".")) ?? 0 }
                    let latD = num(1), latM = num(2), lonD = num(4), lonM = num(5)
                    guard latM < 60, lonM < 60, latD <= 90, lonD <= 180 else { continue }
                    var lat = latD + latM / 60, lon = lonD + lonM / 60
                    if ns.substring(with: m.range(at: 3)) == "S" { lat = -lat }
                    if ns.substring(with: m.range(at: 6)) == "W" { lon = -lon }
                    let p = GeoPoint(lat: lat, lon: lon)
                    if p.isValid { found.append((m.range.location, p)) }
                }
            }
            for (loc, p) in found {
                if out.contains(where: { abs($0.point.lat - p.lat) < 0.01 && abs($0.point.lon - p.lon) < 0.01 }) { continue }
                var context = para.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
                while context.contains("  ") { context = context.replacingOccurrences(of: "  ", with: " ") }
                if context.count > 300 {
                    let start = max(0, loc - 120)
                    let flat = (para.replacingOccurrences(of: "\n", with: " ") as NSString)
                    context = flat.substring(with: NSRange(location: min(start, max(0, flat.length - 1)), length: min(300, flat.length - min(start, max(0, flat.length - 1)))))
                }
                out.append(NauticalPosition(point: p, context: context))
                if out.count >= limit { return out }
            }
        }
        return out
    }
}
