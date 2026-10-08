// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine

// Kurzwellen-Ausbreitung für die Lineal-Anzeige am rechten Fensterrand (0 bis 30 MHz, rot = schlecht, weiß = mittel, grün = gut).
// Quelle: die berechneten Bandbedingungen von HamQSL (N0NBH, https://www.hamqsl.com/solarxml.php): je Bandgruppe 80–40 m, 30–20 m, 17–15 m und 12–10 m
// getrennt für Tag und Nacht, aus Sonnenflussindex, A- und K-Index. Sie gelten weltweit. Der Ort kommt hier dazu: Aus Standort, Datum und Uhrzeit wird
// der Sonnenstand gerechnet (Jahreszeit steckt in der Deklination der Sonne), und zwischen Tag- und Nachtwert wird nach der Sonnenhöhe überblendet
// (Dämmerung von −6° bis +6°). Zwischen den Bandgruppen wird in der Frequenz interpoliert, unterhalb von 3,5 MHz nach Tag und Nacht und im Sommer
// (Gewitterrauschen) geschätzt. Das ist eine grobe Orientierung, keine Vorhersage für eine bestimmte Strecke.

// MARK: - Daten

public enum PropagationRating: String, Sendable, Equatable {
    case poor = "Poor", fair = "Fair", good = "Good"

    /// 0 = schlecht, 0,5 = mittel, 1 = gut
    public var score: Double {
        switch self {
        case .poor: return 0
        case .fair: return 0.5
        case .good: return 1
        }
    }
}

public struct PropagationBandGroup: Sendable, Equatable {
    public var name: String            // „80m-40m“
    public var centerMHz: Double
    public var day: PropagationRating
    public var night: PropagationRating
}

public struct PropagationData: Sendable, Equatable {
    public var groups: [PropagationBandGroup]
    public var solarFlux: Int?
    public var aIndex: Int?
    public var kIndex: Int?
    public var sunspots: Int?
    /// Zeitpunkt der Meldung (UTC), nil wenn nicht lesbar
    public var updated: Date?
    public var source: String

    public init(groups: [PropagationBandGroup], solarFlux: Int? = nil, aIndex: Int? = nil, kIndex: Int? = nil, sunspots: Int? = nil, updated: Date? = nil, source: String = "HamQSL") {
        self.groups = groups
        self.solarFlux = solarFlux
        self.aIndex = aIndex
        self.kIndex = kIndex
        self.sunspots = sunspots
        self.updated = updated
        self.source = source
    }
}

public enum PropagationParser {
    /// Mittelfrequenzen der Bandgruppen von HamQSL in MHz (80–40 m: 3,5 bis 7,3 / 30–20 m: 10,1 bis 14,35 / 17–15 m: 18,07 bis 21,45 / 12–10 m: 24,89 bis 29,7)
    static let centers: [String: Double] = ["80m-40m": 5.0, "30m-20m": 12.0, "17m-15m": 19.7, "12m-10m": 27.3]

    /// XML von `solarxml.php` lesen; nil, wenn keine Bandwerte darin stehen
    public static func parse(xml: Data) -> PropagationData? {
        final class Delegate: NSObject, XMLParserDelegate {
            var text = ""
            var bandName: String?
            var bandTime: String?
            var day: [String: PropagationRating] = [:]
            var night: [String: PropagationRating] = [:]
            var values: [String: String] = [:]

            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
                text = ""
                if name == "band" { bandName = attributes["name"]; bandTime = attributes["time"] }
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if name == "band", let b = bandName, let tm = bandTime, let r = PropagationRating(rawValue: t) {
                    if tm == "day" { day[b] = r } else if tm == "night" { night[b] = r }
                } else if ["solarflux", "aindex", "kindex", "sunspots", "updated"].contains(name) {
                    values[name] = t
                }
            }
        }
        let d = Delegate()
        let p = XMLParser(data: xml)
        p.delegate = d
        guard p.parse() else { return nil }
        let groups = centers.keys.sorted { centers[$0]! < centers[$1]! }.compactMap { name -> PropagationBandGroup? in
            guard let dy = d.day[name], let ni = d.night[name] else { return nil }
            return PropagationBandGroup(name: name, centerMHz: centers[name]!, day: dy, night: ni)
        }
        guard groups.count == centers.count else { return nil }
        return PropagationData(groups: groups, solarFlux: d.values["solarflux"].flatMap { Int($0) }, aIndex: d.values["aindex"].flatMap { Int($0) },
                               kIndex: d.values["kindex"].flatMap { Int($0) }, sunspots: d.values["sunspots"].flatMap { Int($0) }, updated: d.values["updated"].flatMap(parseDate))
    }

    /// „08 Oct 2026 1049 GMT“
    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "dd MMM yyyy HHmm 'GMT'"
        return f.date(from: s.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Sonnenstand

public enum SunPosition {
    /// Höhe der Sonne über dem Horizont in Grad (ohne Refraktion; auf etwa 0,3° genau, genug für Tag und Nacht)
    public static func elevationDegrees(latitude: Double, longitude: Double, date: Date) -> Double {
        let rad = Double.pi / 180
        let jd = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let n = jd - 2_451_545.0
        let L = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let g = ((357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360)) * rad
        let lambda = (L + 1.915 * sin(g) + 0.020 * sin(2 * g)) * rad
        let epsilon = (23.439 - 0.0000004 * n) * rad
        let ra = atan2(cos(epsilon) * sin(lambda), cos(lambda))
        let dec = asin(sin(epsilon) * sin(lambda))
        let gmst = (18.697374558 + 24.06570982441908 * n).truncatingRemainder(dividingBy: 24) * 15      // Grad
        let h = (gmst + longitude) * rad - ra
        let lat = latitude * rad
        return asin(sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(h)) / rad
    }

    /// Deklination der Sonne in Grad (Jahreszeit)
    public static func declinationDegrees(date: Date) -> Double {
        let rad = Double.pi / 180
        let n = date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545.0
        let L = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let g = ((357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360)) * rad
        let lambda = (L + 1.915 * sin(g) + 0.020 * sin(2 * g)) * rad
        return asin(sin((23.439 - 0.0000004 * n) * rad) * sin(lambda)) / rad
    }
}

// MARK: - Modell

public enum PropagationModel {
    /// Anteil „Tag“ (0 … 1) nach der Sonnenhöhe: Nacht unter −6°, Tag über +6°, dazwischen Dämmerung
    public static func dayWeight(elevation: Double) -> Double {
        let t = max(0, min(1, (elevation + 6) / 12))
        return t * t * (3 - 2 * t)
    }

    /// Güte (0 schlecht … 1 gut) bei einer Frequenz in MHz
    /// - Parameters:
    ///   - elevation: Sonnenhöhe am Standort in Grad
    ///   - declination: Deklination der Sonne in Grad (positiv = Sommer im Norden)
    ///   - latitude: Breite des Standorts (Vorzeichen bestimmt, welche Halbkugel Sommer hat)
    public static func score(frequencyMHz f: Double, data: PropagationData, elevation: Double, declination: Double = 0, latitude: Double = 50) -> Double {
        guard let first = data.groups.first, let last = data.groups.last else { return 0.5 }
        let w = dayWeight(elevation: elevation)
        func at(_ day: Bool) -> Double {
            func s(_ g: PropagationBandGroup) -> Double { (day ? g.day : g.night).score }
            if f <= first.centerMHz {
                // unterhalb der ersten Gruppe: nachts besser, am Tag schlechter (Absorption), im Sommer mehr Rauschen
                let t = max(0, min(1, (first.centerMHz - f) / 4))
                var v = s(first) + t * (day ? -0.5 : 0.15)
                let summer = latitude >= 0 ? declination > 12 : declination < -12
                if summer && f < 8 { v -= 0.1 * max(0, min(1, (8 - f) / 5)) }
                return v
            }
            if f >= last.centerMHz { return s(last) }
            for (a, b) in zip(data.groups, data.groups.dropFirst()) where f >= a.centerMHz && f <= b.centerMHz {
                let u = (f - a.centerMHz) / (b.centerMHz - a.centerMHz)
                return s(a) * (1 - u) + s(b) * u
            }
            return 0.5
        }
        return max(0, min(1, w * at(true) + (1 - w) * at(false)))
    }

    /// Farbe zur Güte: 0 rot, 0,5 weiß, 1 grün (RGB 0 … 1)
    public static func color(score: Double) -> (r: Double, g: Double, b: Double) {
        let red = (r: 0.93, g: 0.22, b: 0.22), white = (r: 0.96, g: 0.96, b: 0.96), green = (r: 0.10, g: 0.85, b: 0.40)
        let s = max(0, min(1, score))
        func mix(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double), _ u: Double) -> (r: Double, g: Double, b: Double) {
            (a.r + (b.r - a.r) * u, a.g + (b.g - a.g) * u, a.b + (b.b - a.b) * u)
        }
        return s < 0.5 ? mix(red, white, s * 2) : mix(white, green, (s - 0.5) * 2)
    }
}

// MARK: - Abruf

/// Holt die Bandbedingungen von HamQSL (höchstens alle 45 Minuten; die Seite aktualisiert sich selbst nur etwa stündlich) und merkt sich den letzten Stand
@MainActor
public final class PropagationService: ObservableObject {
    public static let url = URL(string: "https://www.hamqsl.com/solarxml.php")!
    private static let cacheKey = "propagationXML"
    private static let fetchedKey = "propagationFetched"

    @Published public private(set) var data: PropagationData?
    @Published public private(set) var fetchedAt: Date?
    @Published public private(set) var lastError: String?
    @Published public private(set) var loading = false

    private var timer: Timer?
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
        if let file = ProcessInfo.processInfo.environment["DIGIDEC_PROPAGATION_FILE"], let xml = FileManager.default.contents(atPath: file) {
            data = PropagationParser.parse(xml: xml)
            fetchedAt = Date()
            return
        }
        if let xml = UserDefaults.standard.data(forKey: Self.cacheKey) {
            data = PropagationParser.parse(xml: xml)
            fetchedAt = UserDefaults.standard.object(forKey: Self.fetchedKey) as? Date
        }
    }

    /// Abrufen und alle zehn Minuten prüfen, ob der Stand zu alt ist
    public func start() {
        guard timer == nil, ProcessInfo.processInfo.environment["DIGIDEC_PROPAGATION_FILE"] == nil else { return }
        refresh(force: false)
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: false) }
        }
    }

    public func refresh(force: Bool) {
        if loading { return }
        if !force, let t = fetchedAt, Date().timeIntervalSince(t) < 45 * 60, data != nil { return }
        loading = true
        var request = URLRequest(url: Self.url, timeoutInterval: 20)
        request.setValue("Digidec (Amateurfunk-Decoder; ruft höchstens alle 45 Minuten ab)", forHTTPHeaderField: "User-Agent")
        let session = self.session
        Task { [weak self] in
            do {
                let (body, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                self?.finish(code == 200 ? body : nil, error: code == 200 ? nil : "HamQSL antwortet nicht (HTTP \(code))")
            } catch {
                self?.finish(nil, error: error.localizedDescription)
            }
        }
    }

    private func finish(_ body: Data?, error: String?) {
        loading = false
        guard let body else { lastError = error; return }
        guard let parsed = PropagationParser.parse(xml: body) else { lastError = "Antwort von HamQSL nicht lesbar"; return }
        data = parsed
        fetchedAt = Date()
        lastError = nil
        UserDefaults.standard.set(body, forKey: Self.cacheKey)
        UserDefaults.standard.set(fetchedAt, forKey: Self.fetchedKey)
    }
}
