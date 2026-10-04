import Foundation

// Schiffsdaten aus dem Netz für das Fenster „Schiffsdaten“ der AIS-Karte.
//
// Quellen (frei zugänglich, ohne Schlüssel):
//  • Wikidata: Schiffe mit IMO-Nummer (P458), MMSI (P587) oder Rufzeichen (P2317): Baujahr, Werft, Eigner, Maße, Tonnage, Geschwindigkeit …
//  • Wikimedia Commons: Foto (Bild der Wikidata-Seite, sonst Kategorie „IMO nnnnnnn“, sonst Volltextsuche nach der IMO-Nummer)
//  • Wikipedia: Kurzbeschreibung des Artikels (deutsch, sonst englisch)
// Die großen Schiffsdatenbanken (MarineTraffic, VesselFinder, Equasis …) bieten keine freie Schnittstelle; für sie gibt es im Fenster
// Verweise, die im Browser geöffnet werden. Nicht jedes Schiff steht in Wikidata: vor allem große Handelsschiffe, Fähren,
// Kreuzfahrt- und Museumsschiffe; kleine Boote fehlen meist.

public struct ShipQuery: Hashable, Sendable {
    public var mmsi: UInt32
    public var imo: UInt32?
    public var callsign: String?
    public var name: String?

    public init(mmsi: UInt32, imo: UInt32? = nil, callsign: String? = nil, name: String? = nil) {
        self.mmsi = mmsi
        self.imo = imo
        self.callsign = callsign
        self.name = name
    }

    var cacheKey: String { "\(mmsi)-\(imo ?? 0)" }
}

public struct ShipWebInfo: Codable, Equatable, Sendable {
    public struct Fact: Codable, Equatable, Sendable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }
    }

    public var queriedAt = Date()
    /// Womit das Schiff gefunden wurde: „IMO“, „MMSI“, „Rufzeichen“ oder „Name (unsicher)“
    public var matchedBy: String?
    public var entityID: String?
    public var title: String?
    public var summary: String?
    public var extract: String?
    public var extractSource: String?
    public var wikipediaURL: String?
    public var wikidataURL: String?
    public var imageURL: String?
    public var imagePageURL: String?
    public var imageCredit: String?
    public var imageSource: String?
    public var facts: [Fact] = []
    public var notes: [String] = []
    /// Fehler bei der Abfrage (kein Netz o. ä.); dann nicht zwischenspeichern
    public var failed = false

    public init() {}

    public var isEmpty: Bool { entityID == nil && imageURL == nil }
}

public actor ShipInfoService {
    public static let shared = ShipInfoService()

    private let session: URLSession
    private let userAgent = "Digidec/0.54 (macOS; AIS ship info; Wikimedia API client)"

    public init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 40
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: cfg)
    }

    // MARK: Zwischenspeicher

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.peterbetz.digidec/ShipInfo", isDirectory: true)
    }

    private func cached(_ q: ShipQuery) -> ShipWebInfo? {
        let url = Self.cacheDirectory.appendingPathComponent(q.cacheKey + ".json")
        guard let data = try? Data(contentsOf: url), let info = try? JSONDecoder().decode(ShipWebInfo.self, from: data) else { return nil }
        let age = Date().timeIntervalSince(info.queriedAt)
        // gefundene Schiffe 30 Tage, leere Antworten 1 Tag
        return age < (info.isEmpty ? 86_400 : 30 * 86_400) ? info : nil
    }

    private func store(_ info: ShipWebInfo, for q: ShipQuery) {
        guard !info.failed else { return }
        try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(info) {
            try? data.write(to: Self.cacheDirectory.appendingPathComponent(q.cacheKey + ".json"))
        }
    }

    public func forget(_ q: ShipQuery) {
        try? FileManager.default.removeItem(at: Self.cacheDirectory.appendingPathComponent(q.cacheKey + ".json"))
    }

    // MARK: Abfrage

    public func lookup(_ q: ShipQuery, useCache: Bool = true) async -> ShipWebInfo {
        if useCache, let c = cached(q) { return c }
        var info = ShipWebInfo()
        do {
            if let (qid, how) = try await findEntity(q) {
                info.matchedBy = how
                try await fillFromEntity(qid, query: q, into: &info)
            } else {
                info.notes.append("Kein Eintrag in Wikidata für " + identifiers(q) + ".")
            }
            if info.imageURL == nil, let imo = q.imo {
                if let img = try await commonsImage(imo: imo) {
                    info.imageURL = img.url
                    info.imagePageURL = img.page
                    info.imageCredit = img.credit
                    info.imageSource = "Wikimedia Commons (Suche nach IMO \(imo))"
                } else {
                    info.notes.append("Kein Foto in Wikimedia Commons zur IMO-Nummer \(imo).")
                }
            } else if info.imageURL == nil, q.imo == nil {
                info.notes.append("Ohne IMO-Nummer (kommt im AIS-Stammdatentelegramm, Typ 5, alle 6 Minuten) ist die Fotosuche nicht möglich.")
            }
        } catch {
            info.failed = true
            info.notes.append("Abfrage fehlgeschlagen: \((error as NSError).localizedDescription)")
        }
        store(info, for: q)
        return info
    }

    private func identifiers(_ q: ShipQuery) -> String {
        var parts = ["MMSI \(String(format: "%09d", q.mmsi))"]
        if let i = q.imo { parts.append("IMO \(i)") }
        if let c = q.callsign, !c.isEmpty { parts.append("Rufzeichen \(c)") }
        return parts.joined(separator: ", ")
    }

    // MARK: HTTP

    private func json(_ url: URL) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 404 { return [:] }
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Server antwortet mit \(http.statusCode)"])
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func url(_ base: String, _ items: [(String, String)]) -> URL {
        var c = URLComponents(string: base)!
        c.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return c.url!
    }

    // MARK: Wikidata: Schiff finden

    private func findEntity(_ q: ShipQuery) async throws -> (String, String)? {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "") }
        var unions: [String] = []
        if let imo = q.imo { unions.append("{ ?s wdt:P458 \"\(imo)\" . BIND(\"IMO\" AS ?k) }") }
        unions.append("{ ?s wdt:P587 \"\(String(format: "%09d", q.mmsi))\" . BIND(\"MMSI\" AS ?k) }")
        if let c = q.callsign, c.count >= 3 { unions.append("{ ?s wdt:P2317 \"\(esc(c))\" . BIND(\"Rufzeichen\" AS ?k) }") }
        let query = "SELECT ?s ?k WHERE { " + unions.joined(separator: " UNION ") + " } LIMIT 10"
        let r = try await json(url("https://query.wikidata.org/sparql", [("format", "json"), ("query", query)]))
        var best: (String, String, Int)?
        if let results = r["results"] as? [String: Any], let rows = results["bindings"] as? [[String: Any]] {
            for row in rows {
                guard let s = (row["s"] as? [String: Any])?["value"] as? String, let k = (row["k"] as? [String: Any])?["value"] as? String else { continue }
                let qid = String(s.split(separator: "/").last ?? "")
                let rank = k == "IMO" ? 0 : k == "MMSI" ? 1 : 2
                if best == nil || rank < best!.2 { best = (qid, k, rank) }
            }
        }
        if let b = best { return (b.0, b.1) }
        // über den Namen suchen: nur wenn genau ein Treffer wie ein Schiff aussieht und keine Kennung widerspricht
        guard let name = q.name, name.count >= 3 else { return nil }
        let words = name.lowercased().split(separator: " ").map(String.init)
        guard !(words.count == 1 && words[0].count < 4) else { return nil }
        let s = try await json(url("https://www.wikidata.org/w/api.php", [("action", "wbsearchentities"), ("search", name.capitalized), ("language", "de"),
                                                                       ("uselang", "de"), ("type", "item"), ("limit", "10"), ("format", "json")]))
        let shipWords = ["schiff", "ship", "vessel", "fähre", "ferry", "tanker", "liner", "yacht", "boot", "boat", "kreuzfahrt", "cruise", "frachter", "containerschiff",
                         "schlepper", "tug", "segel", "bark", "eisbrecher", "icebreaker", "trawler", "fischereifahrzeug", "forschungsschiff", "bulk", "dampfer", "raddampfer",
                         "ro-ro", "kümo", "küstenmotorschiff", "lotsenschiff", "feuerschiff", "museumsschiff", "passagierschiff", "frachtschiff", "motorschiff", "traditionssegler"]
        var candidates: [String] = []
        for item in (s["search"] as? [[String: Any]]) ?? [] {
            let desc = ((item["description"] as? String) ?? "").lowercased()
            let label = ((item["label"] as? String) ?? "").lowercased()
            guard let id = item["id"] as? String, label == name.lowercased() || label.hasPrefix(name.lowercased()), shipWords.contains(where: { desc.contains($0) }) else { continue }
            candidates.append(id)
        }
        var accepted: [String] = []
        for id in candidates.prefix(5) {
            let e = try await entity(id)
            // widerspricht eine Kennung?
            if let imo = q.imo, let v = stringClaims(e, "P458").first, v != String(imo) { continue }
            if let v = stringClaims(e, "P587").first, v != String(format: "%09d", q.mmsi) { continue }
            if let c = q.callsign, let v = stringClaims(e, "P2317").first, v != c { continue }
            accepted.append(id)
        }
        return accepted.count == 1 ? (accepted[0], "Name (unsicher)") : nil
    }

    private func entity(_ id: String) async throws -> [String: Any] {
        let r = try await json(URL(string: "https://www.wikidata.org/wiki/Special:EntityData/\(id).json")!)
        return ((r["entities"] as? [String: Any])?[id] as? [String: Any]) ?? [:]
    }

    private func stringClaims(_ e: [String: Any], _ p: String) -> [String] {
        claimValues(e, p).compactMap { $0 as? String }
    }

    private func claimValues(_ e: [String: Any], _ p: String) -> [Any] {
        guard let claims = (e["claims"] as? [String: Any])?[p] as? [[String: Any]] else { return [] }
        return claims.compactMap { c in
            // beendete Aussagen (mit „Endzeitpunkt“) nach hinten; hier nur die Werte
            ((c["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"]
        }
    }

    // MARK: Wikidata: Eigenschaften lesen

    private enum Kind { case item, time, quantity, text }

    private static let properties: [(id: String, label: String, kind: Kind)] = [
        ("P31", "Schiffstyp", .item), ("P289", "Schiffsklasse", .item),
        ("P571", "Baujahr", .time), ("P729", "In Dienst seit", .time), ("P730", "Außer Dienst", .time), ("P576", "Aufgelöst", .time),
        ("P176", "Werft / Hersteller", .item), ("P1071", "Bauort", .item), ("P617", "Baunummer", .text),
        ("P127", "Eigner", .item), ("P137", "Betreiber", .item), ("P8047", "Registerland", .item), ("P504", "Heimathafen", .item),
        ("P2043", "Länge", .quantity), ("P2049", "Breite", .quantity), ("P2261", "Breite", .quantity), ("P2262", "Tiefgang", .quantity), ("P2048", "Höhe", .quantity),
        ("P1093", "Bruttoraumzahl", .quantity), ("P2067", "Masse", .quantity), ("P2052", "Geschwindigkeit", .quantity), ("P2217", "Reisegeschwindigkeit", .quantity),
        ("P1083", "Kapazität", .quantity), ("P516", "Antrieb", .item), ("P2130", "Baukosten", .quantity),
        ("P2317", "Rufzeichen", .text), ("P458", "IMO-Nummer", .text), ("P587", "MMSI", .text)
    ]

    private func fillFromEntity(_ qid: String, query q: ShipQuery, into info: inout ShipWebInfo) async throws {
        let e = try await entity(qid)
        info.entityID = qid
        info.wikidataURL = "https://www.wikidata.org/wiki/\(qid)"
        let labels = e["labels"] as? [String: Any]
        info.title = ((labels?["de"] as? [String: Any])?["value"] as? String) ?? ((labels?["en"] as? [String: Any])?["value"] as? String)
        let desc = e["descriptions"] as? [String: Any]
        info.summary = ((desc?["de"] as? [String: Any])?["value"] as? String) ?? ((desc?["en"] as? [String: Any])?["value"] as? String)

        // Beschriftungen aller verwendeten Gegenstände und Einheiten
        var ids = Set<String>()
        for p in Self.properties where p.kind == .item || p.kind == .quantity {
            for v in claimValues(e, p.id).prefix(4) {
                if let d = v as? [String: Any] {
                    if let id = d["id"] as? String { ids.insert(id) }
                    if let u = d["unit"] as? String, let id = u.split(separator: "/").last.map(String.init), id.hasPrefix("Q") { ids.insert(id) }
                }
            }
        }
        let names = try await entityLabels(Array(ids))

        func timeText(_ d: [String: Any]) -> String? {
            guard let t = d["time"] as? String else { return nil }
            let precision = d["precision"] as? Int ?? 9
            let digits = t.dropFirst().prefix(10).split(separator: "-").map(String.init)
            guard digits.count == 3 else { return nil }
            let y = digits[0].trimmingCharacters(in: CharacterSet(charactersIn: "0")), m = digits[1], day = digits[2]
            let year = y.isEmpty ? "0" : y
            if precision >= 11, m != "00", day != "00" { return "\(day).\(m).\(year)" }
            if precision == 10, m != "00" { return "\(m).\(year)" }
            return year
        }

        func number(_ s: String) -> Double? { Double(s.replacingOccurrences(of: "+", with: "")) }

        func quantityText(_ d: [String: Any]) -> String? {
            guard let amountS = d["amount"] as? String, var v = number(amountS) else { return nil }
            let unitID = (d["unit"] as? String).flatMap { $0.split(separator: "/").last.map(String.init) } ?? "1"
            var unit: String
            switch unitID {
            case "Q11573": unit = "m"
            case "Q174728": unit = "cm"
            case "Q828224": unit = "km"
            case "Q128822": unit = "kn"
            case "Q180154": unit = "km/h"
            case "Q11570": unit = "kg"
            case "Q191118": unit = "t"
            case "Q11574": unit = "s"
            case "Q25236": unit = "kW"
            case "Q4916": unit = "€"
            case "Q4917": unit = "US-$"
            case "Q25269": unit = "MW"
            case "1": unit = ""
            default: unit = names[unitID] ?? ""
            }
            if unit == "kg", v >= 1000 { v /= 1000; unit = "t" }
            let digits = v == v.rounded() ? 0 : (abs(v) < 100 ? 2 : 1)
            var text = String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
            if v == v.rounded(), abs(v) >= 10_000 {
                // Tausendertrennung für große ganze Zahlen
                let f = NumberFormatter()
                f.numberStyle = .decimal
                f.locale = Locale(identifier: "de_DE")
                text = f.string(from: NSNumber(value: v)) ?? text
            }
            if unit == "€" || unit == "US-$" { text += " " + unit; return text }
            return unit.isEmpty ? text : text + " " + unit
        }

        var seen = Set<String>()
        for p in Self.properties {
            let values = claimValues(e, p.id)
            guard !values.isEmpty else { continue }
            if p.id == "P2261", seen.contains("Breite") { continue }
            var parts: [String] = []
            for v in values.prefix(4) {
                switch p.kind {
                case .item:
                    if let id = (v as? [String: Any])?["id"] as? String, let n = names[id] { parts.append(n) }
                case .time:
                    if let d = v as? [String: Any], let t = timeText(d) { parts.append(t) }
                case .quantity:
                    if let d = v as? [String: Any], let t = quantityText(d) { parts.append(t) }
                case .text:
                    if let s = v as? String { parts.append(s) }
                }
            }
            // Bruttoraumzahl u. ä.: mehrere Werte nur bei Abweichung zeigen
            var uniq: [String] = []
            for x in parts where !uniq.contains(x) { uniq.append(x) }
            guard !uniq.isEmpty else { continue }
            seen.insert(p.label)
            info.facts.append(.init(label: p.label, value: uniq.joined(separator: " · ")))
        }

        // Bauort gleich der Werft: nicht doppelt zeigen
        if let yard = info.facts.first(where: { $0.label == "Werft / Hersteller" })?.value {
            info.facts.removeAll { $0.label == "Bauort" && $0.value == yard }
        }

        // Foto der Wikidata-Seite
        if let file = stringClaims(e, "P18").first, let img = try await commonsFile(file) {
            info.imageURL = img.url
            info.imagePageURL = img.page
            info.imageCredit = img.credit
            info.imageSource = "Wikidata / Wikimedia Commons"
        }

        // Wikipedia
        let links = e["sitelinks"] as? [String: Any]
        for (lang, key) in [("de", "dewiki"), ("en", "enwiki")] {
            guard let title = (links?[key] as? [String: Any])?["title"] as? String else { continue }
            let enc = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
            info.wikipediaURL = "https://\(lang).wikipedia.org/wiki/\(enc)"
            if let r = try? await json(URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(enc)")!),
               let extract = r["extract"] as? String, !extract.isEmpty {
                info.extract = extract
                info.extractSource = "Wikipedia (\(lang == "de" ? "deutsch" : "englisch"))"
            }
            break
        }
    }

    private func entityLabels(_ ids: [String]) async throws -> [String: String] {
        var out: [String: String] = [:]
        var rest = ids
        while !rest.isEmpty {
            let chunk = Array(rest.prefix(50))
            rest.removeFirst(chunk.count)
            let r = try await json(url("https://www.wikidata.org/w/api.php", [("action", "wbgetentities"), ("ids", chunk.joined(separator: "|")),
                                                                           ("props", "labels"), ("languages", "de|en"), ("format", "json")]))
            for (id, v) in (r["entities"] as? [String: Any]) ?? [:] {
                let labels = (v as? [String: Any])?["labels"] as? [String: Any]
                if let n = ((labels?["de"] as? [String: Any])?["value"] as? String) ?? ((labels?["en"] as? [String: Any])?["value"] as? String) { out[id] = n }
            }
        }
        return out
    }

    // MARK: Wikimedia Commons

    private struct CommonsImage { var url: String; var page: String; var credit: String? }

    private func stripTags(_ s: String) -> String {
        var t = s
        while let a = t.range(of: "<"), let b = t.range(of: ">", range: a.upperBound..<t.endIndex) { t.removeSubrange(a.lowerBound..<b.upperBound) }
        return t.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#039;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func credit(from page: [String: Any]) -> String? {
        guard let ii = (page["imageinfo"] as? [[String: Any]])?.first, let meta = ii["extmetadata"] as? [String: Any] else { return nil }
        func v(_ k: String) -> String? { ((meta[k] as? [String: Any])?["value"] as? String).map(stripTags) }
        var parts: [String] = []
        if let a = v("Artist"), !a.isEmpty { parts.append(a) }
        if let l = v("LicenseShortName"), !l.isEmpty { parts.append(l) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func image(from page: [String: Any]) -> CommonsImage? {
        guard let ii = (page["imageinfo"] as? [[String: Any]])?.first else { return nil }
        let mime = ii["mime"] as? String ?? ""
        guard mime.hasPrefix("image/"), mime != "image/svg+xml", mime != "image/tiff",
              let u = (ii["thumburl"] as? String) ?? (ii["url"] as? String) else { return nil }
        let pageURL = (ii["descriptionurl"] as? String) ?? "https://commons.wikimedia.org"
        return CommonsImage(url: u, page: pageURL, credit: credit(from: page))
    }

    private func commonsFile(_ file: String) async throws -> CommonsImage? {
        let r = try await json(url("https://commons.wikimedia.org/w/api.php", [("action", "query"), ("format", "json"), ("titles", "File:" + file),
                                                                              ("prop", "imageinfo"), ("iiprop", "url|mime|extmetadata"), ("iiurlwidth", "900")]))
        guard let pages = (r["query"] as? [String: Any])?["pages"] as? [String: Any] else { return nil }
        for (_, p) in pages { if let page = p as? [String: Any], let img = image(from: page) { return img } }
        return nil
    }

    /// Foto zu einer IMO-Nummer: Kategorie „IMO n“ (Dateien, sonst die erste Unterkategorie), sonst Volltextsuche im Dateibereich
    private func commonsImage(imo: UInt32) async throws -> CommonsImage? {
        func firstImage(_ r: [String: Any]) -> CommonsImage? {
            guard let pages = (r["query"] as? [String: Any])?["pages"] as? [String: Any] else { return nil }
            // stabile Reihenfolge: nach Seitenkennung
            for key in pages.keys.sorted() { if let page = pages[key] as? [String: Any], let img = image(from: page) { return img } }
            return nil
        }
        let base = "https://commons.wikimedia.org/w/api.php"
        func files(inCategory cat: String) async throws -> CommonsImage? {
            let r = try await json(url(base, [("action", "query"), ("format", "json"), ("generator", "categorymembers"), ("gcmtitle", cat), ("gcmtype", "file"),
                                              ("gcmlimit", "12"), ("prop", "imageinfo"), ("iiprop", "url|mime|extmetadata"), ("iiurlwidth", "900")]))
            return firstImage(r)
        }
        let category = "Category:IMO \(imo)"
        if let i = try await files(inCategory: category) { return i }
        let sub = try await json(url(base, [("action", "query"), ("format", "json"), ("list", "categorymembers"), ("cmtitle", category), ("cmtype", "subcat"), ("cmlimit", "3")]))
        if let members = (sub["query"] as? [String: Any])?["categorymembers"] as? [[String: Any]] {
            for m in members { if let t = m["title"] as? String, let i = try await files(inCategory: t) { return i } }
        }
        let r = try await json(url(base, [("action", "query"), ("format", "json"), ("generator", "search"), ("gsrsearch", "\"IMO \(imo)\" ship"), ("gsrnamespace", "6"),
                                          ("gsrlimit", "6"), ("prop", "imageinfo"), ("iiprop", "url|mime|extmetadata"), ("iiurlwidth", "900")]))
        return firstImage(r)
    }
}

// MARK: - Weitere Quellen (Verweise für den Browser)

public enum ShipLinks {
    public struct Link: Identifiable, Sendable {
        public var title: String
        public var detail: String
        public var url: URL
        public var id: String { title }
    }

    private static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }

    public static func links(for q: ShipQuery) -> [Link] {
        let mmsi = String(format: "%09d", q.mmsi)
        var out: [Link] = []
        func add(_ title: String, _ detail: String, _ s: String) { if let u = URL(string: s) { out.append(Link(title: title, detail: detail, url: u)) } }
        add("MarineTraffic", "Position, Fotos, Fahrten, technische Daten", "https://www.marinetraffic.com/en/ais/details/ships/mmsi:\(mmsi)")
        if let imo = q.imo {
            add("VesselFinder", "Schiffsdaten und Fotos zur IMO-Nummer", "https://www.vesselfinder.com/vessels/details/\(imo)")
            add("ShipSpotting", "Fotos von Schiffsfotografen", "https://www.shipspotting.com/photos/gallery?imo=\(imo)")
            add("BalticShipping", "Daten und Geschichte des Schiffs", "https://www.balticshipping.com/vessel/imo/\(imo)")
        } else {
            add("VesselFinder", "Suche nach der MMSI", "https://www.vesselfinder.com/vessels?name=\(mmsi)")
            if let n = q.name, !n.isEmpty { add("ShipSpotting", "Fotos nach Schiffsnamen", "https://www.shipspotting.com/photos/gallery?shipName=\(enc(n))") }
        }
        if let n = q.name, !n.isEmpty { add("Bildersuche", "Webbilder zum Schiffsnamen", "https://duckduckgo.com/?q=\(enc(n + " ship " + (q.imo.map { "IMO \($0)" } ?? "")))&iax=images&ia=images") }
        return out
    }
}
