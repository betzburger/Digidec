// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// AIS: binäre Nachrichten (Typ 6 adressiert, Typ 8 Rundspruch) mit Gebietskennung (DAC) und Funktionskennung (FI/FID).
// Ausgewertet werden: Wetter und Hydrologie (DAC 1 FI 11 nach IMO SN/Circ.236 und FI 31 nach IMO SN.1/Circ.289), Textbeschreibungen (FI 29, 30),
// künstliche Ziele der Verkehrszentralen (FI 17), Binnenschiff-Daten (DAC 200 FI 10), Pegelstände (200/24) und EMMA-Warnungen (200/23).
// Bitlayouts nach der Beschreibung des gpsd-Projekts (AIVDM/AIS Dictionary, BSD) und den dortigen Testsätzen; eigene Umsetzung.

/// Wetter- und Gewässerdaten einer Messstation (nil = nicht verfügbar)
public struct AISMeteo: Equatable, Sendable {
    public var latitude: Double?
    public var longitude: Double?
    /// UTC-Zeit der Messung (Tag, Stunde, Minute), soweit angegeben
    public var day: Int?
    public var hour: Int?
    public var minute: Int?
    /// 10-Minuten-Mittel und Böen in Knoten; `windAtLeast` bei „126 kn und mehr“
    public var windKn: Int?
    public var gustKn: Int?
    public var windDir: Int?
    public var gustDir: Int?
    public var airTemp: Double?
    public var humidity: Int?
    public var dewPoint: Double?
    public var pressure: Int?
    /// 0 gleichbleibend, 1 fallend, 2 steigend
    public var pressureTendency: Int?
    /// Sicht in Seemeilen
    public var visibilityNM: Double?
    public var visibilityGreater = false
    /// Wasserstand in m (gegenüber Kartennull, mit Tide)
    public var waterLevel: Double?
    public var levelTrend: Int?
    public var currentKn: Double?
    public var currentDir: Int?
    public var waveHeight: Double?
    public var wavePeriod: Int?
    public var waveDir: Int?
    public var swellHeight: Double?
    public var swellPeriod: Int?
    public var swellDir: Int?
    public var seaState: Int?
    public var waterTemp: Double?
    public var precipitation: Int?
    public var salinity: Double?
    public var ice: Bool?
    /// Aus FI 31 (neues Format) statt FI 11
    public var isNewFormat = false
    /// Wetterbeobachtung eines Schiffs (FI 21) statt einer Messstation
    public var fromShip = false
    public var locationName: String?
    public var presentWeather: String?
    public var shipCourse: Int?

    public static func tendencyText(_ t: Int?) -> String? {
        switch t {
        case 0: return "gleichbleibend"
        case 1: return "fallend"
        case 2: return "steigend"
        default: return nil
        }
    }

    public static func precipitationText(_ p: Int?) -> String? {
        switch p {
        case 1: return "Regen"
        case 2: return "Gewitter"
        case 3: return "Eisregen"
        case 4: return "Schneeregen"
        case 5: return "Schnee"
        default: return nil
        }
    }

    public static let beaufort = ["still", "leiser Zug", "leichte Brise", "schwache Brise", "mäßige Brise", "frische Brise", "starker Wind", "steifer Wind",
                                  "stürmischer Wind", "Sturm", "schwerer Sturm", "orkanartiger Sturm", "Orkan"]

    public static func compass(_ deg: Int) -> String {
        let n = ["N", "NNO", "NO", "ONO", "O", "OSO", "SO", "SSO", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        return n[Int((Double(deg) / 22.5).rounded()) % 16]
    }

    /// Zeilen für Karte und Fenster („Wind 12 kn aus NW (310°), Böen 18 kn“)
    public var lines: [String] {
        func d(_ v: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",") }
        var out: [String] = []
        if fromShip {
            var head = "Wetterbeobachtung vom Schiff"
            if let l = locationName, !l.isEmpty { head += " bei \(l)" }
            if let p = presentWeather { head += ": \(p)" }
            out.append(head)
        }
        if let w = windKn {
            var s = "Wind \(w >= 126 ? "≥126" : String(w)) kn"
            if let dir = windDir { s += " aus \(Self.compass(dir)) (\(dir)°)" }
            if let g = gustKn { s += ", Böen \(g >= 126 ? "≥126" : String(g)) kn" }
            out.append(s)
        }
        var air: [String] = []
        if let t = airTemp { air.append("Luft \(d(t)) °C") }
        if let h = humidity { air.append("\(h) % rF") }
        if let t = dewPoint { air.append("Taupunkt \(d(t)) °C") }
        if !air.isEmpty { out.append(air.joined(separator: " · ")) }
        if let p = pressure {
            out.append("Luftdruck \(p) hPa" + (Self.tendencyText(pressureTendency).map { ", \($0)" } ?? ""))
        }
        if let v = visibilityNM { out.append("Sicht \(visibilityGreater ? ">" : "")\(d(v)) sm") }
        if let w = waterLevel { out.append("Wasserstand \(d(w, 2)) m" + (Self.tendencyText(levelTrend).map { ", \($0)" } ?? "")) }
        if let c = currentKn { out.append("Strom \(d(c)) kn" + (currentDir.map { " nach \($0)°" } ?? "")) }
        if let h = waveHeight { out.append("Wellen \(d(h)) m" + (wavePeriod.map { ", \($0) s" } ?? "") + (waveDir.map { " aus \($0)°" } ?? "")) }
        if let h = swellHeight { out.append("Dünung \(d(h)) m" + (swellPeriod.map { ", \($0) s" } ?? "") + (swellDir.map { " aus \($0)°" } ?? "")) }
        if let s = seaState, s <= 12 { out.append("Seegang \(s) Bft: \(Self.beaufort[s])") }
        var more: [String] = []
        if let t = waterTemp { more.append("Wasser \(d(t)) °C") }
        if let s = salinity { more.append("Salzgehalt \(d(s)) %") }
        if let p = Self.precipitationText(precipitation) { more.append(p) }
        if ice == true { more.append("Eis") }
        if !more.isEmpty { out.append(more.joined(separator: " · ")) }
        return out
    }

    /// Kurzform für Tabellen („NW 12 kn · 8,5 °C · 1014 hPa“)
    public var summary: String {
        var parts: [String] = []
        if let w = windKn { parts.append((windDir.map { Self.compass($0) + " " } ?? "") + "\(w) kn") }
        if let t = airTemp { parts.append(String(format: "%.1f °C", t).replacingOccurrences(of: ".", with: ",")) }
        if let p = pressure { parts.append("\(p) hPa") }
        if let w = waterLevel { parts.append(String(format: "%.2f m", w).replacingOccurrences(of: ".", with: ",")) }
        return parts.joined(separator: " · ")
    }

    public var isEmpty: Bool { lines.isEmpty }
}

/// Binnenschiff-Daten (DAC 200, FI 10): europäische Schiffsnummer, Maße, Gefahrgut
public struct AISInlandStatic: Equatable, Sendable {
    /// Einheitliche europäische Schiffsnummer (ENI, 8 Ziffern)
    public var eni: String
    public var length: Double?
    public var beam: Double?
    public var shipTypeCode: Int
    public var hazardCones: Int
    public var draught: Double?
    public var loaded: Int

    public var shipTypeText: String { AISInland.eriText(shipTypeCode) }

    public var hazardText: String? {
        switch hazardCones {
        case 0: return "kein blaues Licht"
        case 1: return "1 blaues Licht"
        case 2: return "2 blaue Lichter"
        case 3: return "3 blaue Lichter"
        case 4: return "Flagge B (Gefahrgut)"
        default: return nil
        }
    }

    public var loadedText: String? {
        switch loaded {
        case 1: return "unbeladen"
        case 2: return "beladen"
        default: return nil
        }
    }
}

public enum AISInland {
    static let eri: [Int: String] = [
        8000: "Fahrzeug, Typ unbekannt", 8010: "Motorgüterschiff", 8020: "Motortankschiff", 8021: "Motortankschiff, Flüssigladung N", 8022: "Motortankschiff, Flüssigladung C",
        8023: "Motortankschiff, Trockenladung wie Flüssigkeit", 8030: "Containerschiff", 8040: "Gastankschiff", 8050: "Motorgüterschiff, Schlepper", 8060: "Motortankschiff, Schlepper",
        8070: "Motorgüterschiff mit Fahrzeug längsseits", 8080: "Motorgüterschiff mit Tanker", 8090: "Motorgüterschiff schiebt Güterschiffe", 8100: "Motorgüterschiff schiebt Tankschiff",
        8110: "Schlepper, Güterschiff", 8120: "Schlepper, Tanker", 8130: "Schleppverband Güterschiff", 8140: "Schleppverband Güter-/Tankschiff",
        8150: "Güterschleppkahn", 8160: "Tankschleppkahn", 8161: "Tankkahn, Flüssigladung N", 8162: "Tankkahn, Flüssigladung C", 8163: "Tankkahn, Trockenladung wie Flüssigkeit",
        8170: "Güterkahn mit Containern", 8180: "Gastankkahn",
        8210: "Schubverband, 1 Güterkahn", 8220: "Schubverband, 2 Güterkähne", 8230: "Schubverband, 3 Güterkähne", 8240: "Schubverband, 4 Güterkähne",
        8250: "Schubverband, 5 Güterkähne", 8260: "Schubverband, 6 Güterkähne", 8270: "Schubverband, 7 Güterkähne", 8280: "Schubverband, 8 Güterkähne", 8290: "Schubverband, 9 und mehr Kähne",
        8310: "Schubverband, 1 Tank-/Gaskahn", 8320: "Schubverband, 2 Kähne mit Tank-/Gaskahn", 8330: "Schubverband, 3 Kähne mit Tank-/Gaskahn", 8340: "Schubverband, 4 Kähne mit Tank-/Gaskahn",
        8350: "Schubverband, 5 Kähne mit Tank-/Gaskahn", 8360: "Schubverband, 6 Kähne mit Tank-/Gaskahn", 8370: "Schubverband, 7 Kähne mit Tank-/Gaskahn"
    ]

    public static func eriText(_ code: Int) -> String {
        if let t = eri[code] { return t }
        if (1...99).contains(code) { return AISShipType.text(code) }
        return "ERI-Code \(code)"
    }
}

/// Pegelstände (DAC 200, FI 24)
public struct AISWaterLevels: Equatable, Sendable {
    public struct Gauge: Equatable, Sendable {
        public var id: Int
        /// cm gegenüber dem örtlichen Bezugswert (in Deutschland GlW)
        public var levelCM: Int
    }
    public var country: String
    public var gauges: [Gauge]

    public var summary: String { gauges.map { "Pegel \($0.id): \($0.levelCM) cm" }.joined(separator: " · ") }
}

/// Künstliches Ziel einer Verkehrszentrale (DAC 1, FI 17)
public struct AISSyntheticTarget: Equatable, Sendable {
    /// 0 MMSI, 1 IMO-Nummer, 2 Rufzeichen, 3 sonstige
    public var idType: Int
    public var idNumber: UInt64
    public var idText: String
    public var latitude: Double?
    public var longitude: Double?
    public var cog: Double?
    public var sog: Double?
    public var second: Int
}

public struct AISEmma: Equatable, Sendable {
    public var kind: Int
    public var intensity: Int
    public var windDir: Int?
    public var start: String
    public var end: String

    public var text: String {
        let kinds = ["", "Wind", "Regen", "Schnee und Eis", "Gewitter", "Nebel", "Kälte", "Hitze", "Hochwasser", "Waldbrand"]
        let ints = ["", "schwach", "mittel", "stark"]
        let winds = ["", "N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        var s = "EMMA-Warnung: " + (kind < kinds.count && kind > 0 ? kinds[kind] : "Wetter")
        if intensity > 0 && intensity < ints.count { s += " (\(ints[intensity]))" }
        if let w = windDir, w > 0 && w < winds.count { s += " aus \(winds[w])" }
        return s + " · \(start) bis \(end)"
    }
}

public enum AISBinary: Equatable, Sendable {
    case meteo(AISMeteo)
    case inland(AISInlandStatic)
    case waterLevels(AISWaterLevels)
    case text(linkage: Int, text: String)
    case targets([AISSyntheticTarget])
    case emma(AISEmma)
    case area(AISAreaNotice)
    case trafficSignal(AISTrafficSignal)
    case extended(AISExtendedShip)
    case persons(AISPersons)
    case atonMonitoring(AISAtonMonitoring)
    case other

    public var title: String {
        switch self {
        case .meteo: return "Wetter und Gewässer"
        case .inland: return "Binnenschiff"
        case .waterLevels: return "Pegelstände"
        case .text: return "Text"
        case .targets: return "Verkehrszentrale: Ziele"
        case .emma: return "EMMA-Warnung"
        case .area: return "Gebietsmeldung"
        case .trafficSignal: return "Schifffahrtszeichen"
        case .extended: return "Erweiterte Reisedaten"
        case .persons: return "Personen an Bord"
        case .atonMonitoring: return "Seezeichen-Überwachung"
        case .other: return "Binärtelegramm"
        }
    }
}

public enum AISBinaryDecoder {
    /// Kopf einer binären Nachricht: Gebietskennung, Funktionskennung und Beginn der Daten (Typ 8: Bit 56, Typ 6: Bit 88)
    public static func header(_ b: AISBits, type: Int) -> (dac: Int, fid: Int, dataStart: Int)? {
        switch type {
        case 8 where b.count >= 56: return (Int(b.u(40, 10)), Int(b.u(50, 6)), 56)
        case 6 where b.count >= 88: return (Int(b.u(72, 10)), Int(b.u(82, 6)), 88)
        default: return nil
        }
    }

    public static func decode(_ b: AISBits, type: Int, dac: Int, fid: Int) -> AISBinary {
        let n = b.count
        switch (type, dac, fid) {
        case (8, 1, 11) where (346...360).contains(n):
            if let m = meteo11(b) { return .meteo(m) }
        case (8, 1, 31) where (352...368).contains(n):
            if let m = meteo31(b) { return .meteo(m) }
        case (8, 1, 29) where n >= 72:
            return .text(linkage: Int(b.u(56, 10)), text: b.text(66, chars: (n - 66) / 6))
        case (6, 1, 30) where n >= 104:
            return .text(linkage: Int(b.u(88, 10)), text: b.text(98, chars: (n - 98) / 6))
        case (8, 1, 17) where n >= 176 && (n - 56) % 120 < 8:
            let t = targets(b)
            if !t.isEmpty { return .targets(t) }
        case (8, 200, 10) where n >= 160 && n <= 176:
            if let i = inland(b) { return .inland(i) }
        case (8, 200, 24) where n >= 168 && n <= 176:
            if let w = waterLevels(b) { return .waterLevels(w) }

        case (8, 200, 23) where n >= 250 && n <= 264:
            if let e = emma(b) { return .emma(e) }
        case (8, 1, 22):
            if let a = area(b, base: 56, mmsi: b.u(8, 30), addressed: nil) { return .area(a) }
        case (6, 1, 23):
            if let a = area(b, base: 88, mmsi: b.u(8, 30), addressed: b.u(40, 30)) { return .area(a) }
        case (8, 1, 19) where n >= 258 && n <= 368:
            if let (s, _) = trafficSignal(b) { return .trafficSignal(s) }
        case (8, 1, 21) where n >= 340 && n <= 368:
            if let w = shipWeather(b) { return .meteo(w) }
        case (8, 1, 24) where n >= 336 && n <= 368:
            if let e = extendedShip(b) { return .extended(e) }
        case (6, 1, 16) where n == 72 || n == 136, (8, 1, 16) where n == 72:
            if let p = persons(b, type: type, dac: 1) { return .persons(p) }
        case (6, 200, 55) where n == 168:
            if let p = persons(b, type: type, dac: 200) { return .persons(p) }
        case (6, 235, 10) where n == 136, (6, 250, 10) where n == 136:
            if let a = atonMonitoring(b) { return .atonMonitoring(a) }
        default: break
        }
        return .other
    }

    // MARK: Wetter

    private static func lonLat(lon: Double, lat: Double) -> (Double?, Double?) {
        (abs(lon) <= 180 ? lon : nil, abs(lat) <= 90 ? lat : nil)
    }

    private static func ok(_ v: Int, na: Int) -> Int? { v == na ? nil : v }

    private static func dir(_ v: Int) -> Int? { v <= 359 ? v : nil }

    private static func speed(_ b: AISBits, _ s: Int) -> Double? {
        let v = Int(b.u(s, 8))
        return v >= 255 ? nil : Double(v) / 10
    }

    /// DAC 1, FI 11 (IMO SN/Circ.236): Breite 24 Bit bei 56, Länge 25 Bit bei 80; Werte ohne Vorzeichen mit Offset
    static func meteo11(_ b: AISBits) -> AISMeteo? {
        // alle Messfelder null (Station ohne Messwerte, sendet Nullen): kein Wettertelegramm
        guard (121..<346).contains(where: { b.bits[$0] != 0 }) else { return nil }
        var m = AISMeteo()
        let lat = Double(b.i(56, 24)) / 60_000, lon = Double(b.i(80, 25)) / 60_000
        guard abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        m.latitude = lat
        m.longitude = lon
        let day = Int(b.u(105, 5)), hour = Int(b.u(110, 5)), minute = Int(b.u(115, 6))
        if day != 31 && day != 0 && hour < 24 && minute < 60 { m.day = day; m.hour = hour; m.minute = minute }
        m.windKn = ok(Int(b.u(121, 7)), na: 127)
        m.gustKn = ok(Int(b.u(128, 7)), na: 127)
        m.windDir = dir(Int(b.u(135, 9)))
        m.gustDir = dir(Int(b.u(144, 9)))
        let t = Int(b.u(153, 11)); if t != 2047 && t <= 1200 { m.airTemp = (Double(t) - 600) / 10 }
        let h = Int(b.u(164, 7)); if h <= 100 { m.humidity = h }
        let dp = Int(b.u(171, 10)); if dp != 1023 && dp <= 700 { m.dewPoint = (Double(dp) - 200) / 10 }
        let p = Int(b.u(181, 9)); if p != 511 { m.pressure = p + 800 }
        m.pressureTendency = ok(Int(b.u(190, 2)), na: 3)
        let vis = Int(b.u(192, 8)); if vis != 255 { m.visibilityNM = Double(vis) / 10 }
        let wl = Int(b.u(200, 9)); if wl != 511 { m.waterLevel = (Double(wl) - 100) / 10 }
        m.levelTrend = ok(Int(b.u(209, 2)), na: 3)
        m.currentKn = speed(b, 211)
        m.currentDir = m.currentKn == nil ? nil : dir(Int(b.u(219, 9)))
        let wh = Int(b.u(272, 8)); if wh != 255 { m.waveHeight = Double(wh) / 10 }
        m.wavePeriod = ok(Int(b.u(280, 6)), na: 63)
        m.waveDir = dir(Int(b.u(286, 9)))
        let sh = Int(b.u(295, 8)); if sh != 255 { m.swellHeight = Double(sh) / 10 }
        m.swellPeriod = ok(Int(b.u(303, 6)), na: 63)
        m.swellDir = dir(Int(b.u(309, 9)))
        let ss = Int(b.u(318, 4)); if ss <= 12 { m.seaState = ss }
        let wt = Int(b.u(322, 10)); if wt != 1023 && wt <= 600 { m.waterTemp = (Double(wt) - 100) / 10 }
        let pr = Int(b.u(332, 3)); if pr != 7 && pr != 0 && pr != 6 { m.precipitation = pr }
        let sal = Int(b.u(335, 9)); if sal <= 500 { m.salinity = Double(sal) / 10 }
        let ice = Int(b.u(344, 2)); if ice <= 1 { m.ice = ice == 1 }
        return m.isEmpty && m.latitude == nil ? nil : m
    }

    /// DAC 1, FI 31 (IMO SN.1/Circ.289): Länge 25 Bit bei 56, Breite 24 Bit bei 81; Temperaturen mit Vorzeichen
    static func meteo31(_ b: AISBits) -> AISMeteo? {
        var m = AISMeteo()
        m.isNewFormat = true
        let (lon, lat) = lonLat(lon: Double(b.i(56, 25)) / 60_000, lat: Double(b.i(81, 24)) / 60_000)
        guard let la = lat, let lo = lon else { return nil }
        m.latitude = la
        m.longitude = lo
        let day = Int(b.u(106, 5)), hour = Int(b.u(111, 5)), minute = Int(b.u(116, 6))
        if day >= 1 && hour < 24 && minute < 60 { m.day = day; m.hour = hour; m.minute = minute }
        m.windKn = ok(Int(b.u(122, 7)), na: 127)
        m.gustKn = ok(Int(b.u(129, 7)), na: 127)
        m.windDir = dir(Int(b.u(136, 9)))
        m.gustDir = dir(Int(b.u(145, 9)))
        let t = b.i(154, 11); if t != -1024 && abs(t) <= 600 { m.airTemp = Double(t) / 10 }
        let h = Int(b.u(165, 7)); if h <= 100 { m.humidity = h }
        let dp = b.i(172, 10); if dp != 501 && dp >= -200 && dp <= 500 { m.dewPoint = Double(dp) / 10 }
        let p = Int(b.u(182, 9)); if p != 511 { m.pressure = p >= 402 ? 1201 : p + 799 }   // 0 = höchstens 799 hPa, 402 = mindestens 1201 hPa
        m.pressureTendency = ok(Int(b.u(191, 2)), na: 3)
        m.visibilityGreater = b.flag(193)
        let vis = Int(b.u(194, 7)); if vis != 127 { m.visibilityNM = Double(vis) / 10 }
        let wl = Int(b.u(201, 12)); if wl <= 4000 { m.waterLevel = (Double(wl) - 1000) / 100 }
        m.levelTrend = ok(Int(b.u(213, 2)), na: 3)
        m.currentKn = speed(b, 215)
        m.currentDir = m.currentKn == nil ? nil : dir(Int(b.u(223, 9)))
        let wh = Int(b.u(276, 8)); if wh != 255 { m.waveHeight = Double(wh) / 10 }
        m.wavePeriod = ok(Int(b.u(284, 6)), na: 63)
        m.waveDir = dir(Int(b.u(290, 9)))
        let sh = Int(b.u(299, 8)); if sh != 255 { m.swellHeight = Double(sh) / 10 }
        m.swellPeriod = ok(Int(b.u(307, 6)), na: 63)
        m.swellDir = dir(Int(b.u(313, 9)))
        let ss = Int(b.u(322, 4)); if ss <= 12 { m.seaState = ss }
        let wt = b.i(326, 10); if wt != 501 && wt >= -100 && wt <= 500 { m.waterTemp = Double(wt) / 10 }
        let pr = Int(b.u(336, 3)); if pr != 7 && pr != 0 && pr != 6 { m.precipitation = pr }
        let sal = Int(b.u(339, 9)); if sal <= 500 { m.salinity = Double(sal) / 10 }
        let ice = Int(b.u(348, 2)); if ice <= 1 { m.ice = ice == 1 }
        return m
    }

    // MARK: Binnenschiffahrt und Verkehrszentralen

    static func inland(_ b: AISBits) -> AISInlandStatic? {
        let vin = b.text(56, chars: 8)
        // die Schiffsnummer besteht aus 8 Ziffern; andere Folgen sind Zufallstreffer (in der Praxis beobachtet)
        guard vin.count == 8, vin.allSatisfy({ $0.isNumber && $0.isASCII }) else { return nil }
        let len = Int(b.u(104, 13)), beam = Int(b.u(117, 10))
        guard len <= 8000, beam <= 1000 else { return nil }
        let code = Int(b.u(127, 14))
        guard (8000...8370).contains(code) || (1...99).contains(code) else { return nil }
        let draught = Int(b.u(144, 11))
        return AISInlandStatic(eni: vin, length: len > 0 ? Double(len) / 10 : nil, beam: beam > 0 ? Double(beam) / 10 : nil, shipTypeCode: code,
                               hazardCones: Int(b.u(141, 3)), draught: draught > 0 && draught <= 2000 ? Double(draught) / 100 : nil, loaded: Int(b.u(155, 2)))
    }

    static func waterLevels(_ b: AISBits) -> AISWaterLevels? {
        let country = b.text(56, chars: 2)
        guard country.count == 2, country.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
        var g: [AISWaterLevels.Gauge] = []
        for i in 0..<4 {
            let base = 68 + 25 * i
            guard base + 25 <= b.count else { break }
            let id = Int(b.u(base, 11)), level = b.i(base + 11, 14)
            if id != 0 && level != 0 { g.append(.init(id: id, levelCM: level)) }
        }
        return g.isEmpty ? nil : AISWaterLevels(country: country, gauges: g)
    }

    static func emma(_ b: AISBits) -> AISEmma? {
        let sy = Int(b.u(56, 8)), sm = Int(b.u(64, 4)), sd = Int(b.u(68, 5)), ey = Int(b.u(73, 8)), em = Int(b.u(81, 4)), ed = Int(b.u(85, 5))
        guard (1...55).contains(sy), (1...12).contains(sm), (1...31).contains(sd) else { return nil }
        let kind = Int(b.u(222, 4)), intensity = Int(b.u(244, 2)), wind = Int(b.u(246, 4))
        guard kind <= 9 else { return nil }
        func date(_ y: Int, _ m: Int, _ d: Int) -> String { String(format: "%02d.%02d.%04d", d, m, 2000 + y) }
        return AISEmma(kind: kind, intensity: intensity, windDir: wind > 0 && wind <= 8 ? wind : nil, start: date(sy, sm, sd), end: ey > 0 ? date(ey, em, ed) : "unbefristet")
    }

    static func targets(_ b: AISBits) -> [AISSyntheticTarget] {
        var out: [AISSyntheticTarget] = []
        var base = 56
        while base + 120 <= b.count && out.count < 4 {
            let idType = Int(b.u(base, 2))
            var idNum: UInt64 = 0
            for k in 0..<42 { idNum = (idNum << 1) | UInt64(b.u(base + 2 + k, 1)) }
            let lat = Double(b.i(base + 48, 24)) / 60_000, lon = Double(b.i(base + 72, 25)) / 60_000
            let cog = Int(b.u(base + 97, 9)), sog = Int(b.u(base + 112, 8))
            let valid = abs(lat) <= 90 && abs(lon) <= 180
            out.append(AISSyntheticTarget(idType: idType, idNumber: idNum, idText: idType >= 2 ? b.text(base + 2, chars: 7) : "",
                                          latitude: valid ? lat : nil, longitude: valid ? lon : nil, cog: cog < 360 ? Double(cog) : nil,
                                          sog: sog < 255 ? Double(sog) : nil, second: Int(b.u(base + 106, 6))))
            base += 120
        }
        return out
    }
}
