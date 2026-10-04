import Foundation

// Startorte der Wettersonden aus der SondeHub-Datenbank (https://api.v2.sondehub.org/sites, CC BY-SA 2.0).
// Die Liste ist von Nutzern gepflegt: Zeiten, Frequenz und Sondentyp sind nicht für jede Station eingetragen und
// verschieden alt. Digidec zeigt deshalb nur, was im Eintrag steht, und rät nichts.

/// Nominale Startzeit einer Station (UTC)
public struct SondeLaunchTime: Equatable, Hashable, Sendable {
    /// 1 = Montag … 7 = Sonntag; nil = täglich
    public let weekday: Int?
    /// Minuten seit 00:00 UTC
    public let minute: Int

    public init(weekday: Int?, minute: Int) {
        self.weekday = weekday
        self.minute = minute
    }

    /// „12:00“
    public var timeText: String { String(format: "%02d:%02d", minute / 60, minute % 60) }

    public static let weekdayNames = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]

    /// „12:00“ (täglich) bzw. „Mo 12:00“
    public var text: String {
        guard let w = weekday, (1...7).contains(w) else { return timeText }
        return Self.weekdayNames[w - 1] + " " + timeText
    }

    /// Kurzform einer Zeitenliste für die Anzeige: „00:00 · 12:00“, „03:00 · 09:00 · 15:00 (Mo–Fr)“, „06:00 Mo,Mi,Fr“
    public static func summary(_ launches: [SondeLaunchTime]) -> String {
        func dayText(_ days: [Int]) -> String {
            if days.isEmpty || days == Array(1...7) { return "" }
            if days == Array(1...5) { return "Mo–Fr" }
            return days.map { weekdayNames[$0 - 1] }.joined(separator: ",")
        }
        var minutes: [Int] = []
        for l in launches where !minutes.contains(l.minute) { minutes.append(l.minute) }
        minutes.sort()
        let groups: [(text: String, days: String)] = minutes.map { m in
            let same = launches.filter { $0.minute == m }
            let days = same.contains { $0.weekday == nil } ? [] : same.compactMap(\.weekday).sorted()
            return (String(format: "%02d:%02d", m / 60, m % 60), dayText(days))
        }
        guard let first = groups.first else { return "" }
        if groups.allSatisfy({ $0.days == first.days }) {
            let times = groups.map(\.text).joined(separator: " · ")
            return first.days.isEmpty ? times : times + " (" + first.days + ")"
        }
        return groups.map { $0.days.isEmpty ? $0.text : $0.text + " " + $0.days }.joined(separator: " · ")
    }

    /// Eintrag der SondeHub-Liste: „0:12:00“ (täglich 12:00), „3:06:00“ (Mittwoch 06:00); Wochentag 0 = täglich, 1 = Montag … 7 = Sonntag.
    /// Ohne Wochentag („12:00“) gilt täglich. Alles andere (Freitext wie „Irregular“) ergibt nil.
    public static func parse(_ s: String) -> SondeLaunchTime? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let nums = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == parts.count else { return nil }
        let day = parts.count == 3 ? nums[0] : 0
        let hour = nums[parts.count - 2], minute = nums[parts.count - 1]
        guard (0...7).contains(day), (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return SondeLaunchTime(weekday: day == 0 ? nil : day, minute: hour * 60 + minute)
    }
}

/// Ein Startort
public struct SondeSite: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let point: GeoPoint
    /// Höhe in m
    public let altitude: Int?
    /// Sondentypen als WMO-Kennung („41“ = Vaisala RS41), wie im Eintrag
    public let types: [String]
    /// Frequenz der RS41 in kHz, falls im Eintrag
    public let frequencyKHz: Int?
    public let launches: [SondeLaunchTime]
    /// Freitext statt fester Zeiten („Irregular“, „Monthly“ …)
    public let timeNotes: [String]
    public let notes: String?
    /// Datum der letzten Änderung des Eintrags („2023-07-06“)
    public let updated: String?
    public let ascentRate: Double?
    public let burstAltitude: Double?

    public init(id: String, name: String, point: GeoPoint, altitude: Int? = nil, types: [String] = [], frequencyKHz: Int? = nil,
                launches: [SondeLaunchTime] = [], timeNotes: [String] = [], notes: String? = nil, updated: String? = nil,
                ascentRate: Double? = nil, burstAltitude: Double? = nil) {
        self.id = id
        self.name = name
        self.point = point
        self.altitude = altitude
        self.types = types
        self.frequencyKHz = frequencyKHz
        self.launches = launches
        self.timeNotes = timeNotes
        self.notes = notes
        self.updated = updated
        self.ascentRate = ascentRate
        self.burstAltitude = burstAltitude
    }

    /// Startet dort eine RS41? (Nur diese kann Digidec decodieren.)
    public var isRS41: Bool { types.contains("41") }

    /// Ort ohne Länderzusatz: „Stuttgart / Schnarrenberg (Germany)“ → Land „Germany“
    public var country: String? {
        guard let open = name.lastIndex(of: "("), name.hasSuffix(")") else { return nil }
        let c = name[name.index(after: open)..<name.index(before: name.endIndex)]
        return String(c)
    }

    /// Name ohne den Zusatz in Klammern am Ende
    public var shortName: String {
        guard let open = name.lastIndex(of: "("), name.hasSuffix(")") else { return name }
        return name[..<open].trimmingCharacters(in: .whitespaces)
    }

    /// Sendefenster für die Zeitrechnung: Beginn `leadMinutes` vor der nominalen Startzeit (der Start ist bei den Wetterdiensten
    /// etwa eine Stunde vor dem Termin), Dauer `windowMinutes`. Kennung: „<Station>|<Wochentag oder 0>|<HHMM der nominalen Zeit>“.
    public func items(leadMinutes: Int, windowMinutes: Int) -> [ScheduledItem] {
        launches.map { l -> ScheduledItem in
            var start = l.minute - leadMinutes
            var weekday = l.weekday
            if start < 0 {
                start += 1440
                if let w = weekday { weekday = w == 1 ? 7 : w - 1 }
            }
            return ScheduledItem(service: .sonde, id: Self.itemID(site: id, launch: l), startMinute: start, durationMinutes: windowMinutes,
                                 title: "\(shortName) · \(l.text) UTC", weekday: weekday, joinLate: Double(windowMinutes) * 60)
        }
    }

    public static func itemID(site: String, launch l: SondeLaunchTime) -> String {
        site + "|" + String(l.weekday ?? 0) + "|" + String(format: "%02d%02d", l.minute / 60, l.minute % 60)
    }

    /// Stationskennung aus einer Kennung von `items`
    public static func siteID(fromItemID s: String) -> String {
        s.firstIndex(of: "|").map { String(s[..<$0]) } ?? s
    }
}

// MARK: - Lesen der Liste

public enum SondePlanParser {
    /// Liest die Antwort von `/sites` (Objekt „Kennung → Station“, notfalls auch eine Liste von Stationen). nil, wenn das Format nicht passt.
    public static func parse(_ data: Data) -> [SondeSite]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var entries: [(key: String, object: [String: Any])] = []
        if let dict = root as? [String: Any] {
            for (key, value) in dict {
                if let object = value as? [String: Any] { entries.append((key: key, object: object)) }
            }
        } else if let array = root as? [[String: Any]] {
            for object in array {
                entries.append((key: stringValue(object["station"]) ?? "", object: object))
            }
        } else {
            return nil
        }
        var sites: [SondeSite] = []
        for entry in entries {
            if let site = site(key: entry.key, object: entry.object) { sites.append(site) }
        }
        return sites.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    static func stringValue(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Frequenz im Eintrag: Text oder Zahl in MHz („404.5“, 403.0); nil außerhalb des Sondenbandes
    static func frequencyKHz(_ v: Any?) -> Int? {
        if let s = v as? String { return SondeSettingsStore.parse(s) }
        if let n = v as? NSNumber { return SondeSettingsStore.parse(String(n.doubleValue)) }
        return nil
    }

    static func site(key: String, object o: [String: Any]) -> SondeSite? {
        guard let position = o["position"] as? [Any], position.count >= 2,
              let lon = number(position[0]), let lat = number(position[1]) else { return nil }
        let point = GeoPoint(lat: lat, lon: lon)
        guard point.isValid else { return nil }

        // Typen: „41“ oder [„41“, „404.5“] (Typ, Frequenz in MHz)
        var types: [String] = []
        var frequency: Int?
        for element in (o["rs_types"] as? [Any]) ?? [] {
            if let t = element as? String {
                types.append(t)
            } else if let pair = element as? [Any], let t = pair.first as? String {
                types.append(t)
                if t == "41", pair.count > 1, frequency == nil { frequency = frequencyKHz(pair[1]) }
            }
        }

        var launches: [SondeLaunchTime] = []
        var timeNotes: [String] = []
        for element in (o["times"] as? [Any]) ?? [] {
            guard let s = element as? String else { continue }
            if let l = SondeLaunchTime.parse(s) {
                if !launches.contains(l) { launches.append(l) }
            } else if !s.trimmingCharacters(in: .whitespaces).isEmpty {
                timeNotes.append(s)
            }
        }
        launches.sort { ($0.minute, $0.weekday ?? 0) < ($1.minute, $1.weekday ?? 0) }

        let id = stringValue(o["station"]) ?? key
        let notes = (o["notes"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return SondeSite(id: id, name: (o["station_name"] as? String) ?? id, point: point,
                         altitude: number(o["alt"]).map { Int($0.rounded()) }, types: types, frequencyKHz: frequency,
                         launches: launches, timeNotes: timeNotes, notes: notes,
                         updated: (o["datetime"] as? String).map { String($0.prefix(10)) },
                         ascentRate: number(o["ascent_rate"]), burstAltitude: number(o["burst_altitude"]))
    }
}

// MARK: - Auswahl nach Entfernung

public enum SondePlan {
    public struct Ranked: Identifiable, Equatable, Sendable {
        public let site: SondeSite
        public let km: Double
        public let bearing: Double
        public var id: String { site.id }
    }

    /// RS41-Startorte bis `radiusKm` vom Standort, nach Entfernung sortiert
    public static func nearby(_ sites: [SondeSite], home: GeoPoint, radiusKm: Double) -> [Ranked] {
        sites.filter(\.isRS41)
            .map { Ranked(site: $0, km: Geo.distanceKm(home, $0.point), bearing: Geo.bearing(from: home, to: $0.point)) }
            .filter { $0.km <= radiusKm }
            .sorted { ($0.km, $0.site.id) < ($1.km, $1.site.id) }
    }
}

// MARK: - Startorte auf der Karte

/// Startorte für die Karte: alle RS41-Stationen (zum Zuordnen), die davon angezeigten und die eigenen Frequenzen
public struct SondeSiteLayer: Equatable, Sendable {
    public var sites: [SondeSite]
    /// Kennungen der Stationen, die auf der Karte stehen (Umkreis um den Standort)
    public var shown: Set<String>
    /// Eigene Frequenz je Station (kHz), übersteuert den Eintrag der Liste
    public var frequencies: [String: Int]

    public init(sites: [SondeSite], shown: Set<String>, frequencies: [String: Int] = [:]) {
        self.sites = sites
        self.shown = shown
        self.frequencies = frequencies
    }

    public func frequency(_ site: SondeSite) -> Int? { frequencies[site.id] ?? site.frequencyKHz }
}

extension SondePlan {
    /// Wo eine Sonde vermutlich gestartet ist, aus der ersten empfangenen Position.
    /// Annahmen (keine Messung): Der Ballon driftet je Kilometer Höhe höchstens etwa 10 km waagerecht, dazu 30 km Spielraum
    /// (bei einer Sonde am Boden also 30 km). Stationen, deren eingetragene Frequenz von der der Sonde abweicht (mehr als 10 kHz), scheiden aus;
    /// Stationen mit passender Frequenz gehen vor, dann die ohne eingetragene Frequenz. Innerhalb der Gruppe gewinnt die nächste.
    public static func launchSite(firstFix: GeoPoint, altitude: Double, sondeKHz: Int?, layer: SondeSiteLayer) -> (site: SondeSite, km: Double)? {
        var matching: [(site: SondeSite, km: Double)] = []
        var open: [(site: SondeSite, km: Double)] = []
        for s in layer.sites where s.isRS41 {
            let km = Geo.distanceKm(firstFix, s.point)
            let heightKm = max(0, altitude - Double(s.altitude ?? 0)) / 1000
            guard km <= 30 + 10 * heightKm else { continue }
            if let sondeKHz, let f = layer.frequency(s) {
                if abs(f - sondeKHz) <= 10 { matching.append((site: s, km: km)) }
            } else {
                open.append((site: s, km: km))
            }
        }
        return matching.min { $0.km < $1.km } ?? open.min { $0.km < $1.km }
    }
}
