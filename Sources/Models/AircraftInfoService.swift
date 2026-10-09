// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Flugzeugdaten aus dem Netz für das Fenster „Flugzeugdaten“ und die Liste der ADS-B-Flugzeuge.
//
// Quellen (frei zugänglich, ohne Schlüssel):
//  • adsbdb.com (Gemeinschaftsdatenbank): ICAO-Adresse → Registrierung, Typ, Hersteller, Betreiber; Rufzeichen → planmäßige Flugstrecke
//    (Fluggesellschaft, Flugnummer, Start- und Zielflughafen mit Koordinaten)
//  • planespotters.net: Foto zur ICAO-Adresse (mit Fotograf und Verweis auf die Fotoseite, wie in den Nutzungsbedingungen verlangt)
// Übermittelt werden nur die ICAO-Adresse und das Rufzeichen eines Flugzeugs, beides wird ohnehin öffentlich ausgesendet.
// Die Strecke gilt für das Rufzeichen laut Flugplan; sie wird nicht live gemeldet und kann bei Umleitungen, Charter- und Privatflügen fehlen oder abweichen.

public struct AircraftQuery: Hashable, Sendable {
    public var icao: UInt32
    public var callsign: String?

    public init(icao: UInt32, callsign: String?) {
        self.icao = icao
        let c = callsign?.trimmingCharacters(in: .whitespaces).uppercased()
        self.callsign = (c?.count ?? 0) >= 3 ? c : nil
    }

    var hex: String { String(format: "%06X", icao) }
}

public struct AircraftPlace: Codable, Equatable, Sendable {
    public var icao: String
    public var iata: String
    public var name: String
    public var city: String
    public var countryISO: String
    public var countryName: String
    public var latitude: Double
    public var longitude: Double
    public var elevationFt: Int?

    public var point: GeoPoint { GeoPoint(lat: latitude, lon: longitude) }
    /// „FRA“ (sonst „EDDF“)
    public var shortCode: String { iata.isEmpty ? icao : iata }
}

public struct AircraftRoute: Codable, Equatable, Sendable {
    public var callsign: String
    public var flightNumber: String
    public var airlineName: String
    public var airlineICAO: String
    public var airlineIATA: String
    public var origin: AircraftPlace?
    public var destination: AircraftPlace?

    /// „FRA → JFK“
    public var routeText: String? {
        guard let o = origin, let d = destination else { return nil }
        return "\(o.shortCode)→\(d.shortCode)"
    }

    /// Luftlinie zwischen Start und Ziel (km)
    public var distanceKm: Double? {
        guard let o = origin, let d = destination else { return nil }
        return Geo.distanceKm(o.point, d.point)
    }
}

public struct AircraftPhoto: Codable, Equatable, Sendable {
    public var imageURL: String
    public var thumbnailURL: String?
    public var pageURL: String?
    public var photographer: String?
    /// „planespotters.net“ oder „airport-data.com“
    public var source: String
}

public struct AircraftWebInfo: Codable, Equatable, Sendable {
    public var queriedAt = Date()
    public var registration: String?
    /// „A319 112“
    public var typeName: String?
    public var icaoType: String?
    public var manufacturer: String?
    public var owner: String?
    public var ownerCountryISO: String?
    public var ownerCountryName: String?
    /// Kennung der Fluggesellschaft (DLH)
    public var operatorCode: String?
    public var route: AircraftRoute?
    public var photo: AircraftPhoto?
    public var notes: [String] = []
    /// Abfrage nicht möglich (kein Netz, zu viele Anfragen): nicht zwischenspeichern
    public var failed = false

    public init() {}

    public var hasAircraft: Bool { registration != nil || typeName != nil }
    public var isEmpty: Bool { !hasAircraft && route == nil && photo == nil }

    /// „A319 · Lufthansa“ für Liste und Karte
    public var shortDescription: String? {
        var parts: [String] = []
        if let t = icaoType ?? typeName { parts.append(t) }
        if let o = owner, !o.isEmpty { parts.append(o) } else if let a = route?.airlineName, !a.isEmpty { parts.append(a) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// „Airbus A319-112“
    public var fullTypeName: String? {
        guard let t = typeName ?? icaoType else { return nil }
        if let m = manufacturer, !m.isEmpty, !t.lowercased().hasPrefix(m.lowercased()) { return "\(m) \(t)" }
        return t
    }
}

/// Fortschritt eines Flugs auf der planmäßigen Strecke (Luftlinie)
public struct AircraftProgress: Equatable, Sendable {
    public var flownKm: Double
    public var remainingKm: Double
    public var fraction: Double
    /// Restflugzeit in Minuten bei der gehörten Geschwindigkeit (nil bei Geschwindigkeit unter 100 kn)
    public var etaMinutes: Int?

    public static func compute(route: AircraftRoute?, position: GeoPoint?, groundSpeedKn: Double?) -> AircraftProgress? {
        guard let route, let o = route.origin, let d = route.destination, let p = position else { return nil }
        let flown = Geo.distanceKm(o.point, p), remaining = Geo.distanceKm(p, d.point)
        guard flown + remaining > 1 else { return nil }
        var eta: Int?
        if let v = groundSpeedKn, v >= 100 { eta = Int((remaining / (v * 1.852) * 60).rounded()) }
        return AircraftProgress(flownKm: flown, remainingKm: remaining, fraction: min(1, max(0, flown / (flown + remaining))), etaMinutes: eta)
    }

    /// „2 h 10 min“
    public var etaText: String? {
        guard let m = etaMinutes else { return nil }
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }
}

// MARK: - Auswertung der Antworten

public enum AircraftInfoParsing {
    private static func dict(_ d: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }
    private static func str(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// adsbdb `/v0/aircraft/<hex>`: nil bei „unknown aircraft“
    public static func aircraft(_ data: Data, into info: inout AircraftWebInfo) -> Bool {
        guard let root = dict(data), let resp = root["response"] as? [String: Any], let a = resp["aircraft"] as? [String: Any] else { return false }
        info.registration = str(a["registration"])
        info.typeName = str(a["type"])
        info.icaoType = str(a["icao_type"])
        info.manufacturer = str(a["manufacturer"])
        info.owner = str(a["registered_owner"])
        info.ownerCountryISO = str(a["registered_owner_country_iso_name"])
        info.ownerCountryName = str(a["registered_owner_country_name"])
        info.operatorCode = str(a["registered_owner_operator_flag_code"])
        if let url = str(a["url_photo"]), info.photo == nil {
            info.photo = AircraftPhoto(imageURL: url, thumbnailURL: str(a["url_photo_thumbnail"]), pageURL: nil, photographer: nil, source: "airport-data.com")
        }
        return true
    }

    private static func place(_ v: Any?) -> AircraftPlace? {
        guard let p = v as? [String: Any], let lat = (p["latitude"] as? NSNumber)?.doubleValue, let lon = (p["longitude"] as? NSNumber)?.doubleValue else { return nil }
        return AircraftPlace(icao: str(p["icao_code"]) ?? "", iata: str(p["iata_code"]) ?? "", name: str(p["name"]) ?? "", city: str(p["municipality"]) ?? "",
                             countryISO: str(p["country_iso_name"]) ?? "", countryName: str(p["country_name"]) ?? "", latitude: lat, longitude: lon,
                             elevationFt: (p["elevation"] as? NSNumber)?.intValue)
    }

    /// adsbdb `/v0/callsign/<rufzeichen>`: nil bei „unknown callsign“
    public static func route(_ data: Data) -> AircraftRoute? {
        guard let root = dict(data), let resp = root["response"] as? [String: Any], let r = resp["flightroute"] as? [String: Any] else { return nil }
        let airline = r["airline"] as? [String: Any]
        let route = AircraftRoute(callsign: str(r["callsign"]) ?? "", flightNumber: str(r["callsign_iata"]) ?? "", airlineName: str(airline?["name"]) ?? "",
                                  airlineICAO: str(airline?["icao"]) ?? "", airlineIATA: str(airline?["iata"]) ?? "",
                                  origin: place(r["origin"]), destination: place(r["destination"]))
        return route.origin == nil && route.destination == nil ? nil : route
    }

    /// planespotters `/pub/photos/hex/<hex>`: erstes Foto
    public static func photo(_ data: Data) -> AircraftPhoto? {
        guard let root = dict(data), let photos = root["photos"] as? [[String: Any]], let p = photos.first else { return nil }
        let large = (p["thumbnail_large"] as? [String: Any])?["src"] as? String
        let small = (p["thumbnail"] as? [String: Any])?["src"] as? String
        guard let img = large ?? small else { return nil }
        return AircraftPhoto(imageURL: img, thumbnailURL: small, pageURL: str(p["link"]), photographer: str(p["photographer"]), source: "planespotters.net")
    }
}

// MARK: - Dienst

public actor AircraftInfoService {
    public static let shared = AircraftInfoService()

    /// (Daten, HTTP-Status) für eine Adresse; austauschbar für Tests
    public typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    private let fetch: Fetch
    private let directory: URL
    static let userAgent = "Digidec/0.61 (+https://github.com/betzburger/Digidec)"

    public init(directory: URL? = nil, fetch: Fetch? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.peterbetz.digidec/AircraftInfo", isDirectory: true)
        if let fetch {
            self.fetch = fetch
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 12
            cfg.timeoutIntervalForResource = 30
            let session = URLSession(configuration: cfg)
            self.fetch = { url in
                var req = URLRequest(url: url)
                req.setValue(AircraftInfoService.userAgent, forHTTPHeaderField: "User-Agent")
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, resp) = try await session.data(for: req)
                return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
            }
        }
    }

    // MARK: Zwischenspeicher (getrennt für Flugzeug und Strecke)

    private struct AircraftPart: Codable {
        var queriedAt = Date()
        var info = AircraftWebInfo()
        var photoChecked = false
    }

    private struct RoutePart: Codable {
        var queriedAt = Date()
        var route: AircraftRoute?
    }

    private func read<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let d = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        let dec = JSONDecoder()
        return try? dec.decode(T.self, from: d)
    }

    private func write<T: Encodable>(_ value: T, _ name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(value) { try? d.write(to: directory.appendingPathComponent(name)) }
    }

    public func forget(_ q: AircraftQuery) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("hex-\(q.hex).json"))
        if let c = q.callsign { try? FileManager.default.removeItem(at: directory.appendingPathComponent("route-\(c).json")) }
    }

    /// Nur aus dem Zwischenspeicher (kein Netzzugriff), für die Liste
    public func cachedInfo(_ q: AircraftQuery) -> AircraftWebInfo? {
        guard let a = read("hex-\(q.hex).json", as: AircraftPart.self), Date().timeIntervalSince(a.queriedAt) < Self.aircraftTTL(a.info) else { return nil }
        var info = a.info
        if let c = q.callsign, let r = read("route-\(c).json", as: RoutePart.self), Date().timeIntervalSince(r.queriedAt) < Self.routeTTL(r.route) { info.route = r.route }
        return info
    }

    static func aircraftTTL(_ i: AircraftWebInfo) -> TimeInterval { i.hasAircraft ? 30 * 86_400 : 86_400 }
    static func routeTTL(_ r: AircraftRoute?) -> TimeInterval { r == nil ? 3 * 3600 : 12 * 3600 }

    // MARK: Abfrage

    /// Flugzeug, Strecke und (auf Wunsch) Foto abfragen. Antworten werden zwischengespeichert; Fehler nicht.
    public func lookup(_ q: AircraftQuery, photo wantPhoto: Bool = true, useCache: Bool = true) async -> AircraftWebInfo {
        var failed = false
        var notes: [String] = []

        // Flugzeug (adsbdb)
        var part = (useCache ? read("hex-\(q.hex).json", as: AircraftPart.self) : nil).flatMap { Date().timeIntervalSince($0.queriedAt) < Self.aircraftTTL($0.info) ? $0 : nil }
        if part == nil {
            var p = AircraftPart()
            if let (data, status) = await get("https://api.adsbdb.com/v0/aircraft/\(q.hex)") {
                if status == 429 { failed = true; notes.append("adsbdb: zu viele Anfragen, bitte später noch einmal.") }
                else if !AircraftInfoParsing.aircraft(data, into: &p.info) { notes.append("adsbdb kennt die Adresse \(q.hex) nicht.") }
            } else {
                failed = true
                notes.append("adsbdb nicht erreichbar.")
            }
            part = p
            if !failed { write(p, "hex-\(q.hex).json") }
        }
        var info = part!.info
        var cachedPart = part!

        // Foto (planespotters), nur auf Wunsch und einmal je Flugzeug
        if wantPhoto, !cachedPart.photoChecked {
            if let (data, status) = await get("https://api.planespotters.net/pub/photos/hex/\(q.hex)") {
                if status == 200, let ph = AircraftInfoParsing.photo(data) {
                    info.photo = ph
                    cachedPart.info.photo = ph
                }
                if status == 200 || status == 404 {
                    cachedPart.photoChecked = true
                    cachedPart.queriedAt = part!.queriedAt
                    if !failed { write(cachedPart, "hex-\(q.hex).json") }
                } else if status == 429 {
                    notes.append("planespotters: zu viele Anfragen.")
                }
            } else {
                notes.append("planespotters nicht erreichbar.")
            }
        }

        // Strecke (adsbdb, nach Rufzeichen)
        if let c = q.callsign {
            var rp = useCache ? read("route-\(c).json", as: RoutePart.self) : nil
            if let r = rp, Date().timeIntervalSince(r.queriedAt) >= Self.routeTTL(r.route) { rp = nil }
            if rp == nil {
                var fresh = RoutePart()
                if let (data, status) = await get("https://api.adsbdb.com/v0/callsign/\(c)") {
                    if status == 429 { failed = true; notes.append("adsbdb: zu viele Anfragen, bitte später noch einmal.") }
                    else {
                        fresh.route = AircraftInfoParsing.route(data)
                        if fresh.route == nil { notes.append("Keine planmäßige Strecke zum Rufzeichen \(c) bekannt.") }
                        write(fresh, "route-\(c).json")
                    }
                } else {
                    failed = true
                    notes.append("adsbdb nicht erreichbar (Strecke).")
                }
                rp = fresh
            }
            info.route = rp?.route
        } else {
            notes.append("Ohne Rufzeichen keine Strecke.")
        }
        info.notes = notes
        info.failed = failed
        info.queriedAt = Date()
        return info
    }

    private func get(_ s: String) async -> (Data, Int)? {
        guard let url = URL(string: s) else { return nil }
        return try? await fetch(url)
    }
}

// MARK: - Verweise (im Browser)

public enum AircraftLinks {
    public struct Link: Identifiable, Sendable {
        public var title: String
        public var detail: String
        public var url: URL
        public var id: String { title }
    }

    public static func links(for q: AircraftQuery, info: AircraftWebInfo?) -> [Link] {
        var out: [Link] = []
        func add(_ title: String, _ detail: String, _ s: String) { if let u = URL(string: s) { out.append(Link(title: title, detail: detail, url: u)) } }
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }
        if let p = info?.photo?.pageURL { add("Foto-Seite", "Das Foto beim Fotografen (planespotters.net)", p) }
        add("planespotters", "Fotos und Daten zur ICAO-Adresse", "https://www.planespotters.net/hex/\(q.hex)")
        if let reg = info?.registration { add("Flightradar24", "Aktuelle Position und Verlauf", "https://www.flightradar24.com/data/aircraft/\(enc(reg.lowercased()))") }
        if let c = q.callsign { add("FlightAware", "Flug und Strecke zum Rufzeichen", "https://www.flightaware.com/live/flight/\(enc(c))") }
        add("ADS-B Exchange", "Offene Flugverfolgung zur ICAO-Adresse", "https://globe.adsbexchange.com/?icao=\(q.hex.lowercased())")
        return out
    }
}
