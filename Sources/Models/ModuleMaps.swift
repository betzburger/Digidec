import Foundation

// MARK: - Gehörte Stationen (FT8, FT4, WSPR und Rufzeichen im Text)

/// Eine gehörte Station mit Rufzeichen und, wenn bekannt, Locator. Gemeinsame Eingabe für die Karte von FT8, FT4, WSPR,
/// CW, PSK, Olivia, MT63 und RTTY.
public struct HeardStation: Equatable, Sendable {
    public var call: String
    public var grid: String?
    public var dxcc: DXCCEntity?
    public var snr: Int?
    public var time: Date
    /// Letzte Meldung oder Zusatzzeile
    public var text: String
    public var isCQ = false
    public var mentionsMe = false
    public var count = 1
    public var rfHz: Double?
    public var powerDBm: Int?

    public init(call: String, grid: String? = nil, dxcc: DXCCEntity? = nil, snr: Int? = nil, time: Date, text: String = "",
                isCQ: Bool = false, mentionsMe: Bool = false, count: Int = 1, rfHz: Double? = nil, powerDBm: Int? = nil) {
        self.call = call
        self.grid = grid
        self.dxcc = dxcc
        self.snr = snr
        self.time = time
        self.text = text
        self.isCQ = isCQ
        self.mentionsMe = mentionsMe
        self.count = count
        self.rfHz = rfHz
        self.powerDBm = powerDBm
    }

    /// Ort: Locator, sonst Mittelpunkt des DXCC-Gebiets (ungefähr)
    public var location: (point: GeoPoint, exact: Bool)? {
        if let g = grid, let p = Maidenhead.point(g) { return (p, true) }
        if let d = dxcc { return (GeoPoint(lat: d.latitude, lon: d.longitude), false) }
        return nil
    }
}

public enum HeardMapBuilder {
    /// Karte aus gehörten Stationen. Mehrfache Meldungen einer Station werden zusammengefasst (jüngste gilt).
    /// - Parameters:
    ///   - mode: Name der Betriebsart für die Zeile unter dem Rufzeichen
    ///   - maxAge: nur Stationen, die in den letzten `maxAge` Sekunden gehört wurden (nil = alle)
    public static func content(_ list: [HeardStation], home: GeoPoint?, now: Date, mode: String, maxAge: TimeInterval? = nil,
                               maxLines: Int = 80, maxMarkers: Int = 400, emptyHint: String? = nil) -> MapContent {
        var byCall: [String: HeardStation] = [:]
        for h in list {
            let key = h.call.hasPrefix("<") ? h.call : h.call.uppercased()
            if var old = byCall[key] {
                let n = old.count + h.count
                if h.time >= old.time {
                    var new = h
                    if new.grid == nil { new.grid = old.grid }
                    if new.dxcc == nil { new.dxcc = old.dxcc }
                    new.mentionsMe = new.mentionsMe || old.mentionsMe
                    old = new
                } else if old.grid == nil { old.grid = h.grid }
                old.count = n
                byCall[key] = old
            } else {
                byCall[key] = h
            }
        }
        var markers: [MapMarker] = []
        var located: [(MapMarker, GeoPoint)] = []
        for h in byCall.values.sorted(by: { $0.time > $1.time }) {
            guard let (point, exact) = h.location, point.isValid else { continue }
            let age = now.timeIntervalSince(h.time)
            if let maxAge, age > maxAge { continue }
            var details: [String] = []
            if let d = h.dxcc { details.append("\(d.flag) \(d.name)") }
            if let g = h.grid { details.append("Locator \(g)") }
            details.append(exact ? Geo.format(point) : "Mittelpunkt des Landes (kein Locator): " + Geo.format(point))
            if let home {
                let km = Geo.distanceKm(home, point), b = Geo.bearing(from: home, to: point)
                details.append("\(Geo.formatKm(km)) \(Geo.compass(b)) (\(Int(b.rounded()))°)")
            }
            if let s = h.snr { details.append("S/N \(s) dB") }
            if let p = h.powerDBm { details.append("\(p) dBm") }
            if let f = h.rfHz { details.append(String(format: "%.6f MHz", f / 1_000_000).replacingOccurrences(of: ".", with: ",")) }
            if !h.text.isEmpty { details.append(h.text) }
            let ageText = age < 90 ? "\(Int(age)) s" : age < 5400 ? "\(Int(age / 60)) min" : "\(Int(age / 3600)) h"
            let subtitle = "\(mode) · vor \(ageText)" + (h.count > 1 ? " · \(h.count)×" : "")
            var tone: MapTone = h.mentionsMe ? .alert : h.isCQ ? .normal : .info
            if age > 900 { tone = .dim }
            let m = MapMarker(id: h.call, coordinate: point, title: h.call, subtitle: subtitle, details: details,
                              symbol: nil, glyph: h.dxcc?.flag, tone: tone, heardAt: h.time)
            markers.append(m)
            located.append((m, point))
            if markers.count >= maxMarkers { break }
        }
        var lines: [MapLine] = []
        if let home {
            for (m, p) in located.prefix(maxLines) where Geo.distanceKm(home, p) > 30 {
                lines.append(MapLine(id: "l-" + m.id, points: [home, p], tone: m.tone == .dim ? .dim : m.tone, geodesic: true))
            }
        }
        return MapContent(markers: markers, lines: lines, home: home, emptyHint: emptyHint ?? "Noch keine Station mit Ort empfangen")
    }
}

// MARK: - Rufzeichen im Text

/// Sammelt Rufzeichen aus fortlaufendem Empfangstext (CW, PSK, Olivia, MT63, RTTY). Nur Rufzeichen mit gültigem Muster,
/// die einem DXCC-Gebiet zuzuordnen sind; sicher gelten sie nach „CQ“ oder „DE“ davor oder bei mehrfachem Empfang.
public final class CallsignLog {
    public struct Entry: Equatable, Sendable {
        public var call: String
        public var first: Date
        public var last: Date
        public var count: Int
        public var announced: Bool
        public var context: String
    }

    public private(set) var entries: [String: Entry] = [:]
    private var buffer = ""
    private var previous = ""
    private var recent: [String] = []
    public static let maxEntries = 300

    public init() {}

    public func clear() {
        entries.removeAll()
        buffer = ""
        previous = ""
        recent.removeAll()
    }

    /// Text anhängen (beliebige Stücke, auch einzelne Zeichen)
    public func feed(_ s: String, at date: Date = Date()) {
        buffer += s.uppercased()
        while let idx = buffer.firstIndex(where: { !($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "/")) }) {
            let token = String(buffer[buffer.startIndex..<idx])
            buffer.removeSubrange(buffer.startIndex...idx)
            handle(token, at: date)
        }
        if buffer.count > 12 { buffer = "" }
    }

    private func handle(_ token: String, at date: Date) {
        defer { if !token.isEmpty { previous = token; recent.append(token); if recent.count > 6 { recent.removeFirst() } } }
        guard token.count >= 4, token.count <= 12, FT8Message.isCall(token) else { return }
        guard DXCCDatabase.shared.lookup(token) != nil else { return }
        let announced = previous == "DE" || previous == "CQ" || previous == "DX" || previous == "QRZ" || previous == "TNX" || previous == "TU"
        let ctx = recent.suffix(5).joined(separator: " ") + " " + token
        if var e = entries[token] {
            e.last = date
            e.count += 1
            e.announced = e.announced || announced
            if announced { e.context = ctx }
            entries[token] = e
        } else {
            entries[token] = Entry(call: token, first: date, last: date, count: 1, announced: announced, context: ctx)
            if entries.count > Self.maxEntries {
                if let oldest = entries.values.min(by: { $0.last < $1.last }) { entries.removeValue(forKey: oldest.call) }
            }
        }
    }

    /// Verlässliche Rufzeichen als gehörte Stationen
    public var heard: [HeardStation] {
        entries.values.filter { $0.announced || $0.count >= 2 }.map { e in
            HeardStation(call: e.call, dxcc: DXCCDatabase.shared.lookup(e.call), time: e.last, text: e.context, isCQ: e.context.contains("CQ"), count: e.count)
        }
    }
}

// MARK: - SYNOP-Beobachtungen

/// Eine SYNOP-, SHIP- oder BUOY-Meldung mit Ort und den wichtigsten Werten
public struct SynopObservation: Identifiable, Equatable, Sendable {
    public var id: String
    public var wmo: String
    public var name: String
    public var position: GeoPoint?
    public var kind: String
    public var temperature: String?
    public var dewpoint: String?
    public var pressure: String?
    public var wind: String?
    public var visibility: String?
    public var time: String?
    public var lines: [String]
    public var received: Date
    /// Die Kopfzeile fehlte: Zeit und Windeinheit sind angenommen
    public var headerGuessed = false
    // Zahlenwerte für die Wertansicht der Karte
    public var temperatureC: Double?
    public var pressureHPa: Double?
    public var windDirectionDeg: Double?
    /// Windgeschwindigkeit wie gemeldet und ihre Einheit („kn“, „ms“, „kmh“); fldigi kennt die Einheit nur in der ersten Meldung
    /// eines Blocks (Kopfzeile), sonst `nil` (dann gilt die zuletzt gesehene, sonst Knoten)
    public var windSpeedValue: Double?
    public var windUnit: String?
    public var visibilityKm: Double?
    /// Die Einheit stammt nicht aus der Meldung
    public var windUnitAssumed = false
    /// Frühere Orte desselben Schiffs oder derselben Boje (älteste zuerst), ohne den aktuellen
    public var track: [GeoPoint] = []

    public var windSpeedKn: Double? {
        guard let v = windSpeedValue else { return nil }
        switch windUnit ?? "kn" {
        case "ms": return v * 1.9438
        case "kmh": return v / 1.852
        default: return v
        }
    }

    /// Erste Zahl eines Klartextwerts („12.6 °C“, „-3,4 °C“, „1013 hPa“); nil, wenn keine
    static func number(_ s: String?) -> Double? {
        guard let s else { return nil }
        let t = s.replacingOccurrences(of: ",", with: ".")
        var digits = ""
        for ch in t {
            if ch.isNumber || ch == "." || (ch == "-" && digits.isEmpty) { digits.append(ch) } else if !digits.isEmpty { break }
        }
        return Double(digits)
    }

    /// Einheit aus „10 knots“, „5 m/s“, „14 km/h“; nil, wenn der Text keine nennt („No unit“)
    static func windUnit(_ s: String?) -> String? {
        guard let s else { return nil }
        let u = s.lowercased()
        if u.contains("knot") { return "kn" }          // vor „m/s“ prüfen: „Anemometer“ enthält „meter“
        if u.contains("km/h") { return "kmh" }
        if u.contains("m/s") { return "ms" }
        return nil
    }

    /// Sicht in km aus „4 km“ oder „800 m“
    static func km(_ s: String?) -> Double? {
        guard let v = number(s), let s else { return nil }
        let u = s.lowercased()
        if u.contains("km") { return v }
        if u.contains(" m") || u.hasSuffix("m") { return v / 1000 }
        return v
    }
}

/// WMO-Stationsliste (nsd_bbsss.txt aus Resources/Stations): Name und Ort je Stationsnummer
public enum SynopCatalog {
    nonisolated(unsafe) private static var table: [Int: (name: String, point: GeoPoint)]?
    private static let lock = NSLock()

    public static func lookup(wmo: Int) -> (name: String, point: GeoPoint)? {
        lock.withLock {
            if table == nil { table = load() }
            return table?[wmo]
        }
    }

    private static func load() -> [Int: (name: String, point: GeoPoint)] {
        guard let dir = SynopDecoder.stationDirectory,
              let text = try? String(contentsOf: dir.appendingPathComponent("nsd_bbsss.txt"), encoding: .isoLatin1) else { return [:] }
        var t: [Int: (name: String, point: GeoPoint)] = [:]
        for line in text.split(whereSeparator: \.isNewline) {   // Zeilenende kann „\r\n“ sein (ein Character)
            let f = line.split(separator: ";", omittingEmptySubsequences: false)
            guard f.count > 8, let b = Int(f[0]), let s = Int(f[1]),
                  let lat = coordinate(String(f[7])), let lon = coordinate(String(f[8])) else { continue }
            t[b * 1000 + s] = (String(f[3]), GeoPoint(lat: lat, lon: lon))
        }
        return t
    }

    /// „49-46N“, „009-57E“, „65-58-56N“ → Grad
    static func coordinate(_ s: String) -> Double? {
        guard let last = s.last, "NSEW".contains(last) else { return nil }
        let parts = s.dropLast().split(separator: "-").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        var v = parts[0]
        if parts.count > 1 { v += parts[1] / 60 }
        if parts.count > 2 { v += parts[2] / 3600 }
        return "SW".contains(last) ? -v : v
    }
}

/// Wertet den Klartext des SYNOP-Decoders aus (`Schlüssel=Wert`-Zeilen) und sammelt die Beobachtungen
public final class SynopLog {
    public private(set) var observations: [String: SynopObservation] = [:]
    private var pending = ""
    /// Zuletzt gemeldete Windeinheit (fldigi nennt sie nur in der ersten Meldung nach der Kopfzeile)
    private var lastWindUnit: String?
    /// Der laufende Block hat keine Kopfzeile bekommen (der Hinweis steht im Klartext), bis „Bulletin end“ kommt
    private var guessedRun = false
    /// Art der Meldung, die im angefangenen Klartext steht (Land, Schiff, Boje)
    private var pendingKind = "Land"

    public init() {}

    public func clear() {
        observations.removeAll()
        pending = ""
        lastWindUnit = nil
        guessedRun = false
        pendingKind = "Land"
    }

    /// Klartext vom Decoder (`decoded == true`) sammeln; Rohtext (`false`) löst nur eine Auswertung aus.
    /// Der Klartext einer Meldung kommt in mehreren Stücken, getrennt durch den Rohtext – er bleibt deshalb gesammelt,
    /// bis die nächste Station beginnt.
    public func feed(_ s: String, decoded: Bool, at date: Date = Date()) {
        if decoded {
            pending += s
        } else if !pending.isEmpty {
            flush(at: date)
        }
    }

    /// Gesammelten Klartext auswerten (nach jedem Rohtextstück und vor dem Zeichnen der Karte).
    /// Die laufende Meldung wird dabei jedes Mal neu zusammengesetzt und ersetzt ihren früheren, unvollständigen Stand.
    public func flush(at date: Date = Date()) {
        guard !pending.isEmpty else { return }
        let text = pending
        if text.contains("Note=Header missing") { guessedRun = true }
        let parsed = Self.parseRun(text, at: date, kind: pendingKind)
        for var obs in parsed.observations {
            if guessedRun { obs.headerGuessed = true }
            // Wandert ein Schiff, zeichnet die Karte seinen Weg
            if let old = observations[obs.id] {
                var t = old.track
                if let op = old.position, t.last != op, obs.position != op { t.append(op) }
                obs.track = Array(t.suffix(40))
            }
            if let u = obs.windUnit { lastWindUnit = u } else if obs.windSpeedValue != nil {
                obs.windUnit = lastWindUnit ?? "kn"
                obs.windUnitAssumed = true
            }
            observations[obs.id] = obs
        }
        // Nur die letzte, möglicherweise noch unvollständige Meldung bleibt stehen
        if let cut = parsed.openStart {
            pending = String(text[cut...])
            pendingKind = parsed.kind
        }
        if text.contains("Bulletin end") { guessedRun = false }
        if observations.count > 600, let oldest = observations.values.min(by: { $0.received < $1.received }) {
            observations.removeValue(forKey: oldest.id)
        }
    }

    /// Klartext in Beobachtungen zerlegen (ein „WMO Station=…“ beginnt eine neue)
    public static func parse(_ text: String, at date: Date) -> [SynopObservation] {
        parseRun(text, at: date, kind: "Land").observations
    }

    /// Wie `parse`; zusätzlich: Beginn der letzten Meldung im Text (`openStart`) und ihre Art, damit weitere Klartextstücke
    /// angehängt werden können. Eine Zeile „Land station observation“ gehört zur Meldung, die danach beginnt.
    static func parseRun(_ text: String, at date: Date, kind initialKind: String) -> (observations: [SynopObservation], openStart: String.Index?, kind: String) {
        var out: [SynopObservation] = []
        var cur: [String: String] = [:]
        var lines: [String] = []
        var kind = initialKind
        var nextKind = initialKind
        var openStart: String.Index?
        var guessedHeader = false
        func finish() {
            // Schiffe und Bojen haben keine WMO-Stationsnummer, sondern ein Rufzeichen („Ship/Buoy identifier“)
            guard let wmo = cur["WMO Station"] ?? cur["Ship/Buoy identifier"] else { cur = [:]; lines = []; return }
            var name = cur["WMO station"] ?? ""
            if name.hasPrefix("WMO_") { name = "" }
            var pos: GeoPoint?
            if let la = cur["Latitude"].flatMap({ Double($0) }), let lo = cur["Longitude"].flatMap({ Double($0) }) {
                pos = GeoPoint(lat: la, lon: lo)
            } else if let n = Int(wmo), let c = SynopCatalog.lookup(wmo: n) {
                pos = c.point
                if name.isEmpty { name = c.name }
            }
            let pressure = cur["Sea level pressure"] ?? cur["Station pressure"]
            var wind: String?
            if let s = cur["Wind speed"] { wind = (cur["Wind direction"].map { $0 + " " } ?? "") + s }
            var obs = SynopObservation(id: wmo, wmo: wmo, name: name.isEmpty ? "WMO \(wmo)" : name, position: pos, kind: kind,
                                       temperature: cur["Temperature"], dewpoint: cur["Dewpoint temperature"], pressure: pressure,
                                       wind: wind, visibility: cur["Visibility"], time: cur["observation time"] ?? cur["Observation time"],
                                       lines: lines, received: date)
            obs.headerGuessed = guessedHeader
            obs.temperatureC = SynopObservation.number(cur["Temperature"])
            obs.pressureHPa = SynopObservation.number(pressure)
            obs.windDirectionDeg = SynopObservation.number(cur["Wind direction"])
            obs.windSpeedValue = SynopObservation.number(cur["Wind speed"])
            obs.windUnit = SynopObservation.windUnit(cur["Wind speed"])
            obs.visibilityKm = SynopObservation.km(cur["Visibility"])
            out.append(obs)
            cur = [:]
            lines = []
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("Note=Header missing") { guessedHeader = true; lines.append(line); continue }
            if line.hasPrefix("WMO Station=") || line.hasPrefix("Ship/Buoy identifier=") {
                finish()
                kind = nextKind
                openStart = raw.startIndex
            }
            if line.contains("Land station observation") { nextKind = "Land" }
            else if line.hasPrefix("Ship observation") { nextKind = "Schiff" }
            else if line.hasPrefix("Buoy observation") { nextKind = "Boje" }
            if let eq = line.firstIndex(of: "=") {
                let k = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
                let v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if cur[k] == nil { cur[k] = v }
            }
            lines.append(line)
        }
        finish()
        return (out, openStart, kind)
    }

    /// Was die Karte an den SYNOP-Stationen zeigt
    public enum Layer: String, CaseIterable, Sendable, Identifiable {
        case symbol, temperature, pressure, wind, visibility, sea
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .symbol: return "SYMBOL"
            case .temperature: return "TEMP"
            case .pressure: return "DRUCK"
            case .wind: return "WIND"
            case .visibility: return "SICHT"
            case .sea: return "SEE"
            }
        }
        public var help: String {
            switch self {
            case .symbol: return "Symbol je Station (Land, Schiff, Boje); Werte in der Auswahl"
            case .temperature: return "Lufttemperatur in °C, blau (kalt) bis rot (warm)"
            case .pressure: return "Luftdruck auf Meereshöhe in hPa (sonst Stationsdruck)"
            case .wind: return "Windgeschwindigkeit in Knoten mit Pfeil in Windrichtung, Farbe nach Beaufort"
            case .visibility: return "Sichtweite in km, rot (schlecht) bis grün (gut)"
            case .sea: return "Seegebiete mit Wind aus dem Seewetterbericht, Warnungen, Hochs, Tiefs und Fronten"
            }
        }
    }

    /// Zahl mit Komma für die Anzeige
    private static func fmt(_ v: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
    }

    public func content(home: GeoPoint?, now: Date, transmitters: [TransmitterSite] = [], layer: Layer = .symbol) -> MapContent {
        flush(at: now)
        var markers: [MapMarker] = []
        var shown = 0
        for o in observations.values.sorted(by: { $0.received > $1.received }) {
            guard let p = o.position, p.isValid else { continue }
            var details: [String] = [Geo.format(p)]
            if let h = home { details.append(Geo.formatKm(Geo.distanceKm(h, p)) + " " + Geo.compass(Geo.bearing(from: h, to: p))) }
            if let t = o.temperature { details.append("Temperatur \(t)") }
            if let t = o.dewpoint { details.append("Taupunkt \(t)") }
            if let t = o.pressure { details.append("Luftdruck \(t)") }
            if let kn = o.windSpeedKn, o.windUnitAssumed || o.wind == nil || (o.wind ?? "").contains("No unit") {
                let dir = o.windDirectionDeg.map { String(format: "%.0f° ", $0) } ?? ""
                details.append("Wind \(dir)\(Self.fmt(kn)) kn (Einheit angenommen)")
            } else if let t = o.wind { details.append("Wind \(t)") }
            if let t = o.visibility { details.append("Sicht \(t)") }
            if let t = o.time { details.append("Zeit \(t)") }
            if o.headerGuessed { details.append("Kopfzeile fehlte: Zeit und Windeinheit (Knoten) angenommen") }
            let sub = "\(o.kind) · WMO \(o.wmo)" + (o.temperature.map { " · \($0)" } ?? "")
            var marker = MapMarker(id: "synop-" + o.id, coordinate: p, title: o.name, subtitle: sub, details: details,
                                   symbol: o.kind == "Schiff" ? "ferry.fill" : o.kind == "Boje" ? "circle.dotted" : "cloud.sun.fill",
                                   tone: .weather, heardAt: o.received, track: o.track + (o.track.isEmpty ? [] : [p]))
            switch layer {
            case .symbol, .sea:
                break
            case .temperature:
                guard let t = o.temperatureC else { continue }
                marker.symbol = nil
                marker.valueText = Self.fmt(t, digits: abs(t) < 10 ? 1 : 0)
                marker.valueLevel = min(max((t + 20) / 55, 0), 1)             // −20 … +35 °C
            case .pressure:
                guard let v = o.pressureHPa else { continue }
                marker.symbol = nil
                marker.valueText = Self.fmt(v)
                marker.valueLevel = min(max((v - 985) / 55, 0), 1)            // 985 … 1040 hPa
            case .wind:
                guard let kn = o.windSpeedKn else { continue }
                marker.symbol = nil
                marker.valueText = Self.fmt(kn)
                marker.valueLevel = min(max(Self.beaufort(kn) / 12, 0), 1)
                if let d = o.windDirectionDeg { marker.headingDeg = (d + 180).truncatingRemainder(dividingBy: 360) }   // Pfeil in Windrichtung
            case .visibility:
                guard let v = o.visibilityKm else { continue }
                marker.symbol = nil
                marker.valueText = v >= 10 ? Self.fmt(v) : Self.fmt(v, digits: 1)
                marker.valueLevel = 1 - min(max(v / 20, 0), 1)                // 20 km und mehr grün, nah an 0 rot
            }
            shown += 1
            markers.append(marker)
        }
        var c = TransmitterMap.content(transmitters, home: home)
        c.markers += markers
        c.emptyHint = observations.isEmpty ? "Noch keine SYNOP-Meldung mit Ort decodiert"
            : "Keine Station mit diesem Messwert (\(layer.title.capitalized))"
        _ = shown
        return c
    }

    /// Beaufort-Grad aus Knoten (Bft 1 = 1–3 kn, 2 = 4–6, 3 = 7–10, … 12 = ab 64)
    static func beaufort(_ kn: Double) -> Double {
        let limits: [Double] = [1, 4, 7, 11, 17, 22, 28, 34, 41, 48, 56, 64]
        for (i, l) in limits.enumerated() where kn < l { return Double(i) }
        return 12
    }
}

// MARK: - Sender (feste Stationen)

public struct TransmitterSite: Equatable, Sendable {
    public var id: String
    public var name: String
    public var point: GeoPoint
    public var frequency: String
    public var note: String
    /// Reichweite der Bodenwelle in km (0 = keine Anzeige)
    public var rangeKm: Double

    public init(id: String, name: String, point: GeoPoint, frequency: String, note: String = "", rangeKm: Double = 0) {
        self.id = id
        self.name = name
        self.point = point
        self.frequency = frequency
        self.note = note
        self.rangeKm = rangeKm
    }
}

public enum Transmitters {
    /// Sendeanlagen des DWD bei Pinneberg (Kurzwelle DDK, Langwelle DDH47)
    public static let pinneberg = GeoPoint(lat: 53.6667, lon: 9.7833)
    /// Mainflingen: DCF77 (77,5 kHz) und DCF49 (129,1 kHz)
    public static let mainflingen = GeoPoint(lat: 50.0156, lon: 9.0089)
    /// Burg bei Magdeburg: DCF39 (139 kHz)
    public static let burg = GeoPoint(lat: 52.2917, lon: 11.8917)
    /// Lakihegy bei Budapest: HGA22 (135,6 kHz)
    public static let lakihegy = GeoPoint(lat: 47.3500, lon: 19.0000)

    public static func dcf77() -> [TransmitterSite] {
        [TransmitterSite(id: "dcf77", name: "DCF77 Mainflingen", point: mainflingen, frequency: "77,5 kHz",
                         note: "Zeitzeichensender, 50 kW, Bodenwelle etwa 500 km, Raumwelle bis 2000 km", rangeKm: 500)]
    }

    public static func efr(_ station: EFRStation) -> [TransmitterSite] {
        switch station {
        case .dcf49:
            return [TransmitterSite(id: "dcf49", name: "DCF49 Mainflingen", point: mainflingen, frequency: "129,1 kHz", note: "Rundsteuersender (EFR)", rangeKm: 300)]
        case .dcf39:
            return [TransmitterSite(id: "dcf39", name: "DCF39 Burg", point: burg, frequency: "139,0 kHz", note: "Rundsteuersender (EFR)", rangeKm: 300)]
        case .hga22:
            return [TransmitterSite(id: "hga22", name: "HGA22 Lakihegy", point: lakihegy, frequency: "135,6 kHz", note: "Rundsteuersender (ungarisch)", rangeKm: 300)]
        case .custom:
            return []
        }
    }

    public static func dwd(_ id: String, frequency: String) -> [TransmitterSite] {
        [TransmitterSite(id: id, name: "DWD Pinneberg", point: pinneberg, frequency: frequency,
                         note: "Sendestelle des Deutschen Wetterdienstes (Hamburg-Pinneberg)")]
    }
}

public enum TransmitterMap {
    /// Sender mit Großkreislinie zum eigenen Standort, Entfernung und Richtung
    public static func content(_ sites: [TransmitterSite], home: GeoPoint?, emptyHint: String = "Dieses Modul hat keine feste Sendestelle") -> MapContent {
        var markers: [MapMarker] = []
        var lines: [MapLine] = []
        for s in sites {
            var details = [Geo.format(s.point), s.frequency]
            if let h = home {
                let km = Geo.distanceKm(h, s.point), b = Geo.bearing(from: h, to: s.point)
                details.append("\(Geo.formatKm(km)) \(Geo.compass(b)) (\(Int(b.rounded()))°)")
                lines.append(MapLine(id: "tx-" + s.id, points: [h, s.point], tone: .info, geodesic: true))
            }
            if !s.note.isEmpty { details.append(s.note) }
            markers.append(MapMarker(id: "tx-" + s.id, coordinate: s.point, title: s.name, subtitle: s.frequency, details: details,
                                     symbol: "antenna.radiowaves.left.and.right", tone: .info, radiusKm: s.rangeKm))
        }
        return MapContent(markers: markers, lines: lines, home: home, emptyHint: emptyHint)
    }
}

// MARK: - DSC

extension DSCMessage {
    /// Ort aus dem Positionsfeld „48°30′N 011°20′O“
    public var geoPosition: GeoPoint? {
        guard let p = position else { return nil }
        let nums = p.split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) }
        guard nums.count >= 4 else { return nil }
        var lat = nums[0] + nums[1] / 60, lon = nums[2] + nums[3] / 60
        if p.contains("S") { lat = -lat }
        if p.contains("W") { lon = -lon }
        let pt = GeoPoint(lat: lat, lon: lon)
        return pt.isValid ? pt : nil
    }
}

public enum DSCMapBuilder {
    public static func content(_ messages: [DSCMessage], home: GeoPoint?, now: Date) -> MapContent {
        var markers: [MapMarker] = []
        var lines: [MapLine] = []
        for m in messages.reversed() {
            guard let p = m.geoPosition else { continue }
            let id = "dsc-" + (m.from ?? m.id.uuidString)
            if markers.contains(where: { $0.id == id }) { continue }
            var details = [Geo.format(p), "\(m.format.name)" + (m.category.map { " · \($0)" } ?? "")]
            if let h = home {
                let km = Geo.distanceKm(h, p), b = Geo.bearing(from: h, to: p)
                details.append("\(Geo.formatKm(km)) \(Geo.compass(b)) (\(Int(b.rounded()))°)")
            }
            if let n = m.nature { details.append(n) }
            if let t = m.timeUTC { details.append("Zeit der Position \(t) UTC") }
            if let to = m.to { details.append("An \(to)") }
            if !m.eccOK { details.append("ECC fehlerhaft: Position unsicher") }
            let age = Int(now.timeIntervalSince(m.receivedAt))
            let tone: MapTone = m.isDistress ? .alert : !m.eccOK ? .dim : .highlight
            markers.append(MapMarker(id: id, coordinate: p, title: m.from ?? "MMSI ?", subtitle: "DSC \(m.format.name) · vor \(age < 5400 ? "\(age / 60) min" : "\(age / 3600) h")",
                                     details: details, symbol: m.isDistress ? "exclamationmark.triangle.fill" : "ferry.fill", tone: tone, heardAt: m.receivedAt,
                                     radiusKm: m.isDistress ? 20 : 0))
            if let h = home, m.isDistress { lines.append(MapLine(id: "l-" + id, points: [h, p], tone: .alert, geodesic: true)) }
        }
        return MapContent(markers: markers, lines: lines, home: home, emptyHint: "Noch kein DSC-Ruf mit Position empfangen")
    }
}

// MARK: - NAVTEX

public enum NavtexMapBuilder {
    /// Sendestationen der empfangenen Nachrichten mit Reichweitenkreis (MF etwa 250 sm)
    public static func content(_ entries: [NavtexEntry], home: GeoPoint?, now: Date) -> MapContent {
        struct Acc { var station: FldigiNavtexCore.Station; var count = 0; var last = Date.distantPast; var lastText = "" }
        var acc: [String: Acc] = [:]
        for e in entries {
            guard let st = e.station else { continue }
            let key = st.callsign + st.name
            var a = acc[key] ?? Acc(station: st)
            a.count += 1
            if e.message.receivedAt >= a.last { a.last = e.message.receivedAt; a.lastText = e.summary }
            acc[key] = a
        }
        var markers: [MapMarker] = []
        var lines: [MapLine] = []
        for a in acc.values.sorted(by: { $0.last > $1.last }) {
            let p = GeoPoint(lat: a.station.latitude, lon: a.station.longitude)
            guard p.isValid else { continue }
            var details = [Geo.format(p), a.station.country]
            if let h = home {
                let km = Geo.distanceKm(h, p), b = Geo.bearing(from: h, to: p)
                details.append("\(Geo.formatKm(km)) \(Geo.compass(b)) (\(Int(b.rounded()))°)")
                lines.append(MapLine(id: "l-" + a.station.callsign + a.station.name, points: [h, p], tone: .info, geodesic: true))
            }
            details.append("\(a.count) Nachricht\(a.count == 1 ? "" : "en")")
            if !a.lastText.isEmpty { details.append(a.lastText) }
            markers.append(MapMarker(id: "nx-" + a.station.callsign + a.station.name, coordinate: p, title: a.station.name,
                                     subtitle: "NAVTEX · \(a.station.callsign.isEmpty ? a.station.country : a.station.callsign)", details: details,
                                     symbol: "antenna.radiowaves.left.and.right", tone: .info, heardAt: a.last, radiusKm: 460))
        }
        return MapContent(markers: markers, lines: lines, home: home, emptyHint: "Noch keine NAVTEX-Station mit Ort empfangen")
    }
}
