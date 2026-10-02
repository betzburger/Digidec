import Foundation

// MARK: - AX.25

/// Adresse im AX.25-Kopf: Rufzeichen (bis 6 Zeichen) und SSID 0–15
public struct AX25Address: Equatable, Hashable, Sendable {
    public var call: String
    public var ssid: Int
    /// H-Bit: der Digipeater hat das Paket schon weitergegeben („*“ im TNC2-Format)
    public var repeated: Bool

    public init(call: String, ssid: Int = 0, repeated: Bool = false) {
        self.call = call
        self.ssid = ssid
        self.repeated = repeated
    }

    /// „DL1ABC-9“, ohne „-0“
    public var text: String { ssid == 0 ? call : "\(call)-\(ssid)" }

    /// „DL1ABC-9“ → Rufzeichen und SSID (nil bei ungültiger Schreibweise)
    public init?(text: String) {
        let parts = text.uppercased().split(separator: "-", maxSplits: 1).map(String.init)
        guard let c = parts.first, (1...6).contains(c.count),
              c.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        var s = 0
        if parts.count == 2 {
            guard let v = Int(parts[1]), (0...15).contains(v) else { return nil }
            s = v
        }
        self.init(call: c, ssid: s)
    }

    /// Strenge Prüfung für Quell- und Zieladresse: Buchstaben und Ziffern, mindestens ein Zeichen, SSID im Bereich
    public var isPlausible: Bool {
        !call.isEmpty && call.count <= 6 && call.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) } && (0...15).contains(ssid)
    }
}

/// AX.25-UI-Rahmen (ohne Flags und FCS): Ziel, Quelle, bis zu 8 Digipeater, Control, PID, Info
public struct AX25Frame: Equatable, Sendable {
    public var dest: AX25Address
    public var source: AX25Address
    public var digis: [AX25Address]
    public var control: UInt8
    public var pid: UInt8?
    public var info: [UInt8]

    public init(dest: AX25Address, source: AX25Address, digis: [AX25Address] = [], control: UInt8 = 0x03,
                pid: UInt8? = 0xF0, info: [UInt8]) {
        self.dest = dest
        self.source = source
        self.digis = digis
        self.control = control
        self.pid = pid
        self.info = info
    }

    /// Rahmen aus den Bytes (Adressen, Control, PID, Info), ohne FCS
    public static func parse(_ b: [UInt8]) -> AX25Frame? {
        guard b.count >= 15 else { return nil }
        var addrs: [AX25Address] = []
        var i = 0
        while true {
            guard i + 7 <= b.count, addrs.count < 10 else { return nil }
            var call = ""
            for k in 0..<6 {
                let c = b[i + k]
                guard c & 1 == 0 else { return nil }          // Adressbyte mit Endebit mitten im Rufzeichen
                let ch = c >> 1
                guard ch == 0x20 || (0x21...0x7E).contains(ch) else { return nil }
                if ch != 0x20 { call.append(Character(UnicodeScalar(ch))) }
            }
            let s = b[i + 6]
            addrs.append(AX25Address(call: call, ssid: Int((s >> 1) & 0x0F), repeated: s & 0x80 != 0))
            i += 7
            if s & 1 == 1 { break }
        }
        guard addrs.count >= 2, addrs.count <= 10, i < b.count else { return nil }
        let control = b[i]
        i += 1
        var pid: UInt8?
        // Information gibt es bei UI- (0x03) und I-Rahmen; U-Rahmen mit PID: UI, XID, TEST, I
        if control & 0x01 == 0 || control & 0xEF == 0x03 {
            guard i < b.count else { return nil }
            pid = b[i]
            i += 1
        }
        return AX25Frame(dest: addrs[0], source: addrs[1], digis: Array(addrs.dropFirst(2)), control: control, pid: pid,
                         info: Array(b[i...]))
    }

    /// Bytes (Adressen, Control, PID, Info), ohne FCS
    public func encode() -> [UInt8] {
        let all = [dest, source] + digis
        var out: [UInt8] = []
        for (n, a) in all.enumerated() {
            var chars = Array(a.call.utf8.prefix(6))
            while chars.count < 6 { chars.append(0x20) }
            out += chars.map { $0 << 1 }
            var s: UInt8 = 0x60 | UInt8(a.ssid & 0x0F) << 1
            if a.repeated { s |= 0x80 }
            if n == all.count - 1 { s |= 1 }
            out.append(s)
        }
        out.append(control)
        if let pid { out.append(pid) }
        out += info
        return out
    }

    /// Weg: „DL1ABC>APRS,WIDE1-1*,WIDE2-1“ ohne Info
    public var header: String {
        var s = source.text + ">" + dest.text
        for d in digis { s += "," + d.text + (d.repeated ? "*" : "") }
        return s
    }

    /// Info als Text (UTF-8, sonst Latin-1; Steuerzeichen bleiben erhalten)
    public var infoText: String {
        String(bytes: info, encoding: .utf8) ?? String(info.map { Character(UnicodeScalar($0)) })
    }

    /// TNC2-Zeile wie bei direwolf und APRS-IS: „SRC>DST,VIA*:info“
    public var tnc2: String { header + ":" + infoText }

    /// Beide Adressen sind echte Rufzeichen (schützt vor Zufallsrahmen nach Bitkorrektur)
    public var hasPlausibleAddresses: Bool {
        source.isPlausible && dest.isPlausible && digis.allSatisfy { $0.call.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) } && !$0.call.isEmpty }
    }
}

public enum HDLC {
    /// CRC-16/X.25 (CCITT, reflektiert) wie die FCS bei AX.25
    public static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0x8408 : crc >> 1 }
        }
        return ~crc
    }

    /// Daten samt FCS (niederwertiges Byte zuerst)
    public static func withFCS(_ data: [UInt8]) -> [UInt8] {
        let c = crc16(data)
        return data + [UInt8(c & 0xFF), UInt8(c >> 8)]
    }

    /// Stimmt die FCS am Ende von `frame`?
    public static func fcsValid(_ frame: [UInt8]) -> Bool {
        guard frame.count >= 3 else { return false }
        let c = crc16(Array(frame.dropLast(2)))
        return frame[frame.count - 2] == UInt8(c & 0xFF) && frame[frame.count - 1] == UInt8(c >> 8)
    }
}

// MARK: - APRS

public struct APRSSymbol: Equatable, Hashable, Sendable {
    /// „/“ (Haupttabelle), „\“ (Zusatztabelle) oder Überlagerungszeichen A–Z, 0–9
    public var table: Character
    public var code: Character

    public init(table: Character, code: Character) {
        self.table = table
        self.code = code
    }

    /// Zusatztabelle (auch mit Überlagerung)
    public var isAlternate: Bool { table != "/" }

    /// Name des Symbols auf Deutsch
    public var name: String {
        let key = String([table == "/" ? "/" : "\\", code])
        return Self.names[key] ?? Self.names["/" + String(code)] ?? "Symbol \(table)\(code)"
    }

    /// SF-Symbol für die Karte
    public var systemImage: String {
        let key = String([table == "/" ? "/" : "\\", code])
        return Self.images[key] ?? Self.images["/" + String(code)] ?? "mappin"
    }

    private static let names: [String: String] = [
        "/>": "Auto", "/<": "Motorrad", "/k": "Lkw", "/u": "Lastwagen", "/j": "Jeep", "/v": "Transporter", "/b": "Fahrrad",
        "/[": "Person", "/-": "Haus", "/y": "Haus mit Yagi", "/#": "Digipeater", "/r": "Antenne", "/&": "Gateway",
        "/_": "Wetterstation", "/a": "Krankenwagen", "/f": "Feuerwehr", "/U": "Bus", "/Y": "Segelboot", "/s": "Schiff",
        "/O": "Ballon", "/'": "Flugzeug", "/^": "Flugzeug", "/X": "Hubschrauber", "/I": "TCP/IP", "/$": "Telefon",
        "/S": "Raumfahrzeug", "/p": "Hundestaffel", "/R": "Wohnmobil", "/h": "Krankenhaus", "/P": "Polizei", "/e": "Pferd",
        "/;": "Zeltlager", "/K": "Schule", "/W": "Wetterdienst", "/N": "NTS-Station", "/T": "Fernmeldeturm", "/n": "Netzknoten",
        "/!": "Polizei", "/B": "Bake", "/C": "Kanu", "/G": "Gitternetz", "/H": "Hotel", "/M": "MacAPRS", "/Q": "Erdbeben",
        "/d": "Funkpeilstation", "/g": "Segelflugzeug", "/i": "Insel", "/l": "Laptop", "/m": "Mic-E-Relais", "/o": "Notfallzentrale",
        "/q": "Gitterfeld", "/t": "Truck-Stop", "/w": "Wasser", "/x": "XAPRS", "/z": "Haus", "/.": "Markierung", "/,": "Pfadfinder",
        "/(": "Wolke", "/)": "Rollstuhl", "/*": "Schneemobil", "/+": "Rotes Kreuz", "//": "Punkt", "/0": "Kreis", "/:": "Feuer",
        "/=": "Bahn", "/?": "Serverdienst", "/@": "Wirbelsturm", "/A": "Hilfspunkt", "/D": "Information", "/E": "Rauch", "/F": "Traktor",
        "/J": "Funkgerät", "/L": "Leuchtturm", "/V": "VORTAC", "/Z": "Blinklicht", "/\\": "Dreieck", "/]": "Postamt",
        "/`": "Schüssel", "/c": "CAP-Station", "/{": "Nebel", "/|": "TNC", "/}": "Hubschrauber", "/~": "TNC",
        "\\#": "Digipeater", "\\&": "Gateway", "\\_": "Wetterstation", "\\>": "Auto", "\\-": "Haus", "\\n": "Netzknoten",
        "\\k": "Lkw", "\\s": "Schiff", "\\Y": "Segelboot", "\\^": "Flugzeug", "\\a": "Notruf", "\\I": "Gateway", "\\r": "Relais",
        "\\W": "Wetterdienst", "\\0": "Kreis", "\\j": "Jeep", "\\u": "Lastwagen", "\\v": "Transporter", "\\b": "Fahrrad",
        "\\[": "Wanderer", "\\<": "Motorrad", "\\'": "Flugzeug", "\\f": "Feuerwehr", "\\p": "Hundestaffel", "\\y": "Haus",
        "\\h": "Geschäft", "\\w": "Überschwemmung", "\\:": "Hagel", "\\@": "Wirbelsturm", "\\{": "Nebel", "\\,": "Pfadfinder",
        "\\d": "Notrufsäule", "\\e": "Notfallsirene", "\\i": "Insel", "\\l": "Leuchtturm", "\\m": "Meilenstein", "\\o": "Feuerwehr",
        "\\q": "Notruf", "\\x": "Gefahrenstelle", "\\z": "Haus"
    ]

    private static let images: [String: String] = [
        "/>": "car.fill", "\\>": "car.fill", "/<": "bicycle", "\\<": "bicycle", "/b": "bicycle", "\\b": "bicycle",
        "/k": "box.truck.fill", "/u": "box.truck.fill", "\\k": "box.truck.fill", "\\u": "box.truck.fill",
        "/j": "car.fill", "\\j": "car.fill", "/v": "bus.fill", "\\v": "bus.fill", "/U": "bus.fill", "/R": "bus.fill",
        "/[": "figure.walk", "\\[": "figure.walk", "/-": "house.fill", "\\-": "house.fill", "/y": "house.fill", "\\y": "house.fill",
        "/z": "house.fill", "\\z": "house.fill", "/#": "antenna.radiowaves.left.and.right.circle.fill", "\\#": "antenna.radiowaves.left.and.right.circle.fill",
        "/r": "antenna.radiowaves.left.and.right", "\\r": "antenna.radiowaves.left.and.right", "/&": "network", "\\&": "network", "\\I": "network", "/I": "network",
        "/_": "cloud.sun.fill", "\\_": "cloud.sun.fill", "/W": "cloud.sun.fill", "\\W": "cloud.sun.fill",
        "/a": "cross.case.fill", "\\a": "cross.case.fill", "/f": "flame.fill", "\\f": "flame.fill", "/o": "cross.circle.fill",
        "/Y": "sailboat.fill", "\\Y": "sailboat.fill", "/s": "ferry.fill", "\\s": "ferry.fill", "/C": "sailboat.fill",
        "/O": "balloon.fill", "/'": "airplane", "\\'": "airplane", "/^": "airplane", "\\^": "airplane", "/g": "airplane",
        "/X": "airplane", "/}": "airplane", "/S": "moon.stars.fill", "/$": "phone.fill", "/p": "pawprint.fill", "\\p": "pawprint.fill",
        "/e": "pawprint.fill", "/;": "tent.fill", "/h": "cross.fill", "/P": "shield.fill", "/!": "shield.fill", "/M": "desktopcomputer",
        "/l": "laptopcomputer", "/T": "antenna.radiowaves.left.and.right", "/n": "point.3.connected.trianglepath.dotted",
        "\\n": "point.3.connected.trianglepath.dotted", "/m": "antenna.radiowaves.left.and.right.circle", "/d": "scope",
        "/L": "lightbulb.fill", "\\l": "lightbulb.fill", "/B": "light.beacon.max.fill", "/@": "tornado", "\\@": "tornado"
    ]
}

/// Wetterwerte aus einer APRS-Meldung (Einheiten umgerechnet)
public struct APRSWeather: Equatable, Sendable {
    public var windDirDeg: Int?
    public var windSpeedKmh: Double?
    public var gustKmh: Double?
    public var temperatureC: Double?
    public var rainLastHourMM: Double?
    public var rain24hMM: Double?
    public var rainSinceMidnightMM: Double?
    public var humidityPercent: Int?
    public var pressureHPa: Double?
    public var luminosityWm2: Int?

    public var isEmpty: Bool {
        windDirDeg == nil && windSpeedKmh == nil && gustKmh == nil && temperatureC == nil && rainLastHourMM == nil
            && rain24hMM == nil && rainSinceMidnightMM == nil && humidityPercent == nil && pressureHPa == nil && luminosityWm2 == nil
    }

    /// Eine Zeile für Liste und Karte: „12,3 °C · 65 % · 1013 hPa · Wind 230° 14 km/h“
    public var summary: String {
        func d(_ v: Double, _ f: String = "%.1f") -> String { String(format: f, v).replacingOccurrences(of: ".", with: ",") }
        var parts: [String] = []
        if let t = temperatureC { parts.append(d(t) + " °C") }
        if let h = humidityPercent { parts.append("\(h) %") }
        if let p = pressureHPa { parts.append(d(p) + " hPa") }
        if let s = windSpeedKmh {
            var w = "Wind " + (windDirDeg.map { "\($0)° " } ?? "") + d(s, "%.0f") + " km/h"
            if let g = gustKmh { w += ", Böen " + d(g, "%.0f") }
            parts.append(w)
        }
        if let r = rainLastHourMM { parts.append("Regen " + d(r) + " mm/h") }
        if let l = luminosityWm2 { parts.append("\(l) W/m²") }
        return parts.joined(separator: " · ")
    }

    /// Wetterfelder `c220s004g005t077r000p000P000h50b09900` aus `text`, ab dessen Anfang (nach Wind „CCC/SSS“)
    static func parse(_ text: String) -> APRSWeather {
        var w = APRSWeather()
        let c = Array(text.utf8)
        var i = 0
        // Wind „CCC/SSS“ am Anfang (Werte oder „...“)
        if c.count >= 7, c[3] == UInt8(ascii: "/") {
            w.windDirDeg = int(c, 0, 3).flatMap { $0 == 0 ? nil : $0 }
            w.windSpeedKmh = int(c, 4, 3).map { Double($0) * 1.609344 }
            i = 7
        }
        while i < c.count {
            let key = c[i]
            let len: Int
            switch key {
            case UInt8(ascii: "c"), UInt8(ascii: "s"), UInt8(ascii: "g"), UInt8(ascii: "t"), UInt8(ascii: "r"), UInt8(ascii: "p"),
                 UInt8(ascii: "P"), UInt8(ascii: "L"), UInt8(ascii: "l"):
                len = 3
            case UInt8(ascii: "h"): len = 2
            case UInt8(ascii: "b"): len = 5
            default: i = c.count; continue       // Rest ist Software-/Gerätekennung
            }
            guard i + 1 + len <= c.count else { break }
            let v = int(c, i + 1, len)
            switch key {
            case UInt8(ascii: "c"): if let v { w.windDirDeg = v == 0 ? nil : v }
            case UInt8(ascii: "s"): if w.windSpeedKmh == nil, let v { w.windSpeedKmh = Double(v) * 1.609344 }
            case UInt8(ascii: "g"): if let v { w.gustKmh = Double(v) * 1.609344 }
            case UInt8(ascii: "t"): if let v { w.temperatureC = (Double(v) - 32) * 5 / 9 }
            case UInt8(ascii: "r"): if let v { w.rainLastHourMM = Double(v) * 0.254 }
            case UInt8(ascii: "p"): if let v { w.rain24hMM = Double(v) * 0.254 }
            case UInt8(ascii: "P"): if let v { w.rainSinceMidnightMM = Double(v) * 0.254 }
            case UInt8(ascii: "h"): if let v { w.humidityPercent = v == 0 ? 100 : v }
            case UInt8(ascii: "b"): if let v { w.pressureHPa = Double(v) / 10 }
            case UInt8(ascii: "L"): if let v { w.luminosityWm2 = v }
            case UInt8(ascii: "l"): if let v { w.luminosityWm2 = v + 1000 }
            default: break
            }
            i += 1 + len
        }
        return w
    }

    /// Ganze Zahl aus `n` Zeichen (auch „-05“ für Temperatur); Leerzeichen und Punkte = unbekannt
    private static func int(_ c: [UInt8], _ at: Int, _ n: Int) -> Int? {
        guard at + n <= c.count else { return nil }
        let s = String(decoding: c[at..<(at + n)], as: UTF8.self)
        return Int(s.trimmingCharacters(in: .whitespaces))
    }
}

/// Nachricht an eine Station („:DL1ABC   :Hallo{123“)
public struct APRSMessage: Equatable, Sendable {
    public enum Kind: String, Sendable { case text, ack, rej, bulletin }
    public var addressee: String
    public var text: String
    public var id: String?
    public var kind: Kind
}

/// Entschlüsseltes APRS-Paket (Spezifikation APRS101 und Ergänzungen)
public struct APRSPacket: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case position, micE, object, item, message, status, weather, telemetry, nmea, query, thirdParty, capabilities, other
    }

    public var kind: Kind
    public var source: String
    public var dest: String
    public var path: [String]
    public var info: String
    public var position: GeoPoint?
    /// 0 = genau, 1…4 = Leerzeichen statt Ziffern (Genauigkeit 0,1′ … 10′)
    public var ambiguity: Int = 0
    public var symbol: APRSSymbol?
    /// Name bei Objekt oder Gegenstand
    public var name: String?
    /// Objekt wurde gelöscht („_“)
    public var killed = false
    public var courseDeg: Int?
    public var speedKnots: Double?
    public var altitudeM: Double?
    public var comment = ""
    public var weather: APRSWeather?
    public var message: APRSMessage?
    public var status: String?
    public var micEStatus: String?
    public var timestamp: String?
    public var telemetry: [Int] = []
    public var phg: String?
    public var rangeKm: Double?
    /// Gerät laut Zieladresse („Dire Wolf“, „APRSdroid“ …)
    public var device: String?

    /// Ortsangabe vorhanden und gültig
    public var hasPosition: Bool { position?.isValid ?? false }

    /// Schlüssel der Station in der Stationsliste (Objekte unter ihrem Namen)
    public var stationKey: String {
        if let n = name, kind == .object || kind == .item { return n }
        return source
    }
}

public enum APRSParser {
    /// Paket aus einem AX.25-Rahmen; nil, wenn er keine UI-Info enthält
    public static func parse(_ frame: AX25Frame) -> APRSPacket? {
        guard frame.control & 0xEF == 0x03, frame.pid == 0xF0, !frame.info.isEmpty else { return nil }
        let info = frame.info
        var p = APRSPacket(kind: .other, source: frame.source.text, dest: frame.dest.text,
                           path: frame.digis.map { $0.text + ($0.repeated ? "*" : "") }, info: frame.infoText)
        p.device = deviceName(dest: frame.dest.call)
        let dti = info[0]
        let rest = Array(info.dropFirst())
        switch dti {
        case UInt8(ascii: "!"), UInt8(ascii: "="):
            parsePosition(&p, rest, withTimestamp: false)
        case UInt8(ascii: "/"), UInt8(ascii: "@"):
            parsePosition(&p, rest, withTimestamp: true)
        case UInt8(ascii: "`"), UInt8(ascii: "'"), 0x1C, 0x1D:
            parseMicE(&p, info, dest: frame.dest.call)
        case UInt8(ascii: ":"):
            parseMessage(&p, rest)
        case UInt8(ascii: ";"):
            parseObject(&p, rest)
        case UInt8(ascii: ")"):
            parseItem(&p, rest)
        case UInt8(ascii: ">"):
            p.kind = .status
            var text = latin(rest)
            // Zeitstempel DDHHMMz am Anfang
            if text.count >= 7, text.prefix(6).allSatisfy(\.isNumber), text[text.index(text.startIndex, offsetBy: 6)] == "z" {
                p.timestamp = String(text.prefix(7))
                text = String(text.dropFirst(7))
            }
            p.status = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case UInt8(ascii: "_"):
            // Wetter ohne Ort: _MMDDHHMM + Felder
            p.kind = .weather
            if rest.count >= 8 {
                p.timestamp = latin(Array(rest.prefix(8)))
                p.weather = APRSWeather.parse(latin(Array(rest.dropFirst(8))))
                p.symbol = APRSSymbol(table: "/", code: "_")
            }
        case UInt8(ascii: "T"):
            parseTelemetry(&p, rest)
        case UInt8(ascii: "$"):
            parseNMEA(&p, info)
        case UInt8(ascii: "?"):
            p.kind = .query
            p.comment = latin(rest)
        case UInt8(ascii: "}"):
            p.kind = .thirdParty
            p.comment = latin(rest)
        case UInt8(ascii: "<"):
            p.kind = .capabilities
            p.comment = latin(rest)
        default:
            p.comment = latin(info)
        }
        return p
    }

    // MARK: Position

    private static func parsePosition(_ p: inout APRSPacket, _ rest: [UInt8], withTimestamp: Bool) {
        var b = rest
        if withTimestamp {
            guard b.count >= 7 else { p.comment = latin(b); return }
            p.timestamp = latin(Array(b.prefix(7)))
            b.removeFirst(7)
        }
        p.kind = .position
        guard let first = b.first else { return }
        if first.isDigitASCII || first == UInt8(ascii: " ") {
            guard let (pos, amb, sym) = uncompressed(b) else { p.comment = latin(b); return }
            p.position = pos
            p.ambiguity = amb
            p.symbol = sym
            let tail = Array(b.dropFirst(19))
            applyExtensions(&p, tail, weatherAfterWind: sym.code == "_")
        } else if let (pos, sym, cs, type) = compressed(b) {
            p.position = pos
            p.symbol = sym
            let tail = Array(b.dropFirst(13))
            if let (c, s) = cs {
                if type & 0x18 == 0x10 {
                    // GGA: Höhe aus cs
                    p.altitudeM = pow(1.002, Double(Int(c) * 91 + Int(s))) * 0.3048
                } else if c <= 89 {
                    let course = Int(c) * 4
                    p.courseDeg = course == 0 ? nil : course
                    p.speedKnots = pow(1.08, Double(s)) - 1
                } else if c == 90 {
                    p.rangeKm = 2 * pow(1.08, Double(s)) * 1.609344
                }
            }
            applyExtensions(&p, tail, weatherAfterWind: sym.code == "_", hasWindExtension: false)
        } else {
            p.comment = latin(b)
        }
        if sym(p) == "_" && p.weather == nil { p.weather = APRSWeather.parse(p.comment) }
        if let w = p.weather, w.isEmpty { p.weather = nil }
        if p.weather != nil { p.kind = .weather }
    }

    private static func sym(_ p: APRSPacket) -> Character? { p.symbol?.code }

    /// `DDMM.mmN/DDDMM.mmW$` (19 Zeichen): Ort, Mehrdeutigkeit, Symbol
    static func uncompressed(_ b: [UInt8]) -> (GeoPoint, Int, APRSSymbol)? {
        guard b.count >= 19 else { return nil }
        func field(_ r: Range<Int>) -> String { String(decoding: b[r], as: UTF8.self) }
        let latS = field(0..<8), lonS = field(9..<18)
        guard b[4] == UInt8(ascii: "."), b[14] == UInt8(ascii: ".") else { return nil }
        let ns = latS.last!, ew = lonS.last!
        guard "NSns".contains(ns), "EWew".contains(ew) else { return nil }
        let amb = latS.dropLast().filter { $0 == " " }.count
        func digits(_ s: String) -> String? {
            let t = s.map { $0 == " " ? "0" : String($0) }.joined()
            return t.allSatisfy({ $0.isNumber || $0 == "." }) ? t : nil
        }
        guard let ld = digits(String(latS.dropLast())), let od = digits(String(lonS.dropLast())),
              let latDeg = Double(ld.prefix(2)), let latMin = Double(ld.dropFirst(2)),
              let lonDeg = Double(od.prefix(3)), let lonMin = Double(od.dropFirst(3)),
              latMin < 60, lonMin < 60 else { return nil }
        var lat = latDeg + latMin / 60, lon = lonDeg + lonMin / 60
        if amb > 0 {      // Mitte des unscharfen Feldes
            let step = [0, 0.1, 1, 10, 60][min(amb, 4)] / 60 / 2
            lat += step
            lon += step
        }
        if "Ss".contains(ns) { lat = -lat }
        if "Ww".contains(ew) { lon = -lon }
        let pt = GeoPoint(lat: lat, lon: lon)
        guard pt.isValid else { return nil }
        return (pt, amb, APRSSymbol(table: Character(UnicodeScalar(b[8])), code: Character(UnicodeScalar(b[18]))))
    }

    /// Komprimiertes Format: Tabelle, 4 Zeichen Breite, 4 Länge, Symbol, cs (2), Typ
    static func compressed(_ b: [UInt8]) -> (GeoPoint, APRSSymbol, (UInt8, UInt8)?, UInt8)? {
        guard b.count >= 13 else { return nil }
        func b91(_ r: Range<Int>) -> Double? {
            var v = 0.0
            for i in r {
                guard (33...124).contains(b[i]) else { return nil }
                v = v * 91 + Double(b[i] - 33)
            }
            return v
        }
        guard let la = b91(1..<5), let lo = b91(5..<9) else { return nil }
        let table = Character(UnicodeScalar(b[0]))
        guard table == "/" || table == "\\" || table.isUppercase || ("a"..."j").contains(table) else { return nil }
        let pt = GeoPoint(lat: 90 - la / 380_926, lon: -180 + lo / 190_463)
        guard pt.isValid else { return nil }
        let c = b[10], s = b[11], t = b[12] &- 33
        var cs: (UInt8, UInt8)?
        if c != UInt8(ascii: " "), c >= 33, c <= 123, s >= 33 { cs = (c - 33, s - 33) }
        // Überlagerung a–j = Ziffer 0–9
        var sym = APRSSymbol(table: table, code: Character(UnicodeScalar(b[9])))
        if ("a"..."j").contains(table) { sym.table = Character(String(Int(table.asciiValue! - 97))) }
        return (pt, sym, cs, t)
    }

    /// Nach dem Ort: Kurs/Geschwindigkeit, PHG, RNG, Höhe, DAO, Wetter und Kommentar
    private static func applyExtensions(_ p: inout APRSPacket, _ tail: [UInt8], weatherAfterWind: Bool, hasWindExtension: Bool = true) {
        var text = latin(tail)
        let t = Array(tail)
        if hasWindExtension, t.count >= 7, t[3] == UInt8(ascii: "/"),
           t[0..<3].allSatisfy({ $0.isDigitASCII || $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: ".") }),
           t[4..<7].allSatisfy({ $0.isDigitASCII || $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: ".") }) {
            if weatherAfterWind {
                p.weather = APRSWeather.parse(text)
                text = ""
            } else {
                if let c = Int(latin(Array(t[0..<3]))), c > 0 { p.courseDeg = c == 360 ? 0 : c }
                if let s = Int(latin(Array(t[4..<7]))) { p.speedKnots = Double(s) }
                text = latin(Array(t.dropFirst(7)))
            }
        } else if t.count >= 7, t.starts(with: Array("PHG".utf8)), t[3..<7].allSatisfy(\.isDigitASCII) {
            let pw = Int(t[3] - 48), h = Int(t[4] - 48), g = Int(t[5] - 48), d = Int(t[6] - 48)
            let dir = d == 0 ? "ungerichtet" : "\(d * 45)°"
            p.phg = "\(pw * pw) W, \(10 * (1 << h) * 3048 / 10000) m Höhe, \(g) dB, \(dir)"
            text = latin(Array(t.dropFirst(7)))
        } else if t.count >= 7, t.starts(with: Array("RNG".utf8)), t[3..<7].allSatisfy(\.isDigitASCII) {
            p.rangeKm = (Double(latin(Array(t[3..<7]))) ?? 0) * 1.609344
            text = latin(Array(t.dropFirst(7)))
        }
        // Höhe „/A=001234“ (Fuß)
        if let r = text.range(of: "/A=") {
            let digits = text[r.upperBound...].prefix(6)
            if digits.count == 6, let ft = Int(digits) {
                p.altitudeM = Double(ft) * 0.3048
                text.removeSubrange(r.lowerBound..<text.index(r.upperBound, offsetBy: 6))
            }
        }
        // DAO „!wXY!“: zusätzliche Stellen
        if let pos = p.position, let r = text.range(of: "!w", options: [.literal]) ?? text.range(of: "!W") {
            let after = text[r.upperBound...]
            if after.count >= 3, after[after.index(after.startIndex, offsetBy: 2)] == "!" {
                let x = after[after.startIndex].asciiValue ?? 0, y = after[after.index(after.startIndex, offsetBy: 1)].asciiValue ?? 0
                let lowercase = text[r.lowerBound...].hasPrefix("!w")
                var dLat = 0.0, dLon = 0.0
                if lowercase, x >= 33, y >= 33 { dLat = Double(x - 33) / 91 * 0.01 / 60; dLon = Double(y - 33) / 91 * 0.01 / 60 }
                else if !lowercase, x >= 48, x <= 57, y >= 48, y <= 57 { dLat = Double(x - 48) * 0.001 / 60; dLon = Double(y - 48) * 0.001 / 60 }
                if dLat != 0 || dLon != 0 {
                    p.position = GeoPoint(lat: pos.lat + (pos.lat < 0 ? -dLat : dLat), lon: pos.lon + (pos.lon < 0 ? -dLon : dLon))
                }
                text.removeSubrange(r.lowerBound..<text.index(r.upperBound, offsetBy: 3))
            }
        }
        p.comment = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Mic-E

    private static func micEDigit(_ c: UInt8, mask: Int, std: inout Int, cust: inout Int) -> Int {
        switch c {
        case 48...57: return Int(c - 48)
        case 65...74: cust |= mask; return Int(c - 65)
        case 80...89: std |= mask; return Int(c - 80)
        case UInt8(ascii: "K"): cust |= mask; return 0
        case UInt8(ascii: "Z"): std |= mask; return 0
        default: return 0
        }
    }

    private static func parseMicE(_ p: inout APRSPacket, _ info: [UInt8], dest: String) {
        let d = Array(dest.utf8)
        guard info.count >= 9, d.count >= 6 else { p.comment = latin(info); return }
        var std = 0, cust = 0
        var lat = Double(micEDigit(d[0], mask: 4, std: &std, cust: &cust) * 10 + micEDigit(d[1], mask: 2, std: &std, cust: &cust))
        lat += Double(micEDigit(d[2], mask: 1, std: &std, cust: &cust) * 1000 + micEDigit(d[3], mask: 0, std: &std, cust: &cust) * 100
                      + micEDigit(d[4], mask: 0, std: &std, cust: &cust) * 10 + micEDigit(d[5], mask: 0, std: &std, cust: &cust)) / 6000
        func isNumOrL(_ c: UInt8) -> Bool { (48...57).contains(c) || c == UInt8(ascii: "L") }
        func isPZ(_ c: UInt8) -> Bool { (80...90).contains(c) }
        if isNumOrL(d[3]) { lat = -lat } else if !isPZ(d[3]) { p.comment = latin(info); return }
        let offset: Bool
        if isNumOrL(d[4]) { offset = false } else if isPZ(d[4]) { offset = true } else { p.comment = latin(info); return }
        var lon: Double
        let ch = Int(info[1])
        if offset && (118...127).contains(ch) { lon = Double(ch - 118) }
        else if !offset && (38...127).contains(ch) { lon = Double(ch - 38 + 10) }
        else if offset && (108...117).contains(ch) { lon = Double(ch - 108 + 100) }
        else if offset && (38...107).contains(ch) { lon = Double(ch - 38 + 110) }
        else { p.comment = latin(info); return }
        let m = Int(info[2])
        if (88...97).contains(m) { lon += Double(m - 88) / 60 }
        else if (38...87).contains(m) { lon += Double(m - 38 + 10) / 60 }
        else { p.comment = latin(info); return }
        let h = Int(info[3])
        guard (28...127).contains(h) else { p.comment = latin(info); return }
        lon += Double(h - 28) / 6000
        if isPZ(d[5]) { lon = -lon } else if !isNumOrL(d[5]) { p.comment = latin(info); return }
        let pt = GeoPoint(lat: lat, lon: lon)
        guard pt.isValid else { p.comment = latin(info); return }
        p.kind = .micE
        p.position = pt
        var table = Character(UnicodeScalar(info[8]))
        if !(table == "/" || table == "\\" || table.isUppercase || table.isNumber) { table = "/" }
        p.symbol = APRSSymbol(table: table, code: Character(UnicodeScalar(info[7])))
        var speed = (Int(info[4]) - 28) * 10 + (Int(info[5]) - 28) / 10
        if speed >= 800 { speed -= 800 }
        var course = ((Int(info[5]) - 28) % 10) * 100 + (Int(info[6]) - 28)
        if course >= 400 { course -= 400 }
        p.speedKnots = Double(max(0, speed))
        p.courseDeg = course == 0 ? nil : (course == 360 ? 0 : course)
        let stdText = ["Notfall", "Priorität", "Besonders", "Beauftragt", "Zurück", "Im Dienst", "Unterwegs", "Außer Dienst"]
        let custText = ["Notfall", "Custom-6", "Custom-5", "Custom-4", "Custom-3", "Custom-2", "Custom-1", "Custom-0"]
        if std == 0 && cust == 0 { p.micEStatus = "Notfall" }
        else if std == 0 { p.micEStatus = custText[cust] }
        else if cust == 0 { p.micEStatus = stdText[std] }
        // Rest: Kommentar, ggf. Höhe „xxx}“
        var tail = Array(info.dropFirst(9))
        while let last = tail.last, last == 0x0D || last == 0x0A { tail.removeLast() }
        // Gerätekennung: erstes Zeichen des Kommentars (Kenwood „>“ und „]“, Yaesu „_x“), Kenwood auch „=“ / „^“ am Ende
        if let first = tail.first {
            switch first {
            case UInt8(ascii: ">"):
                var name = "Kenwood TH-D7"
                if tail.last == UInt8(ascii: "="), tail.count > 1 { name = "Kenwood TH-D72"; tail.removeLast() }
                else if tail.last == UInt8(ascii: "^"), tail.count > 1 { name = "Kenwood TH-D74"; tail.removeLast() }
                p.device = name
                tail.removeFirst()
            case UInt8(ascii: "]"):
                var name = "Kenwood TM-D700"
                if tail.last == UInt8(ascii: "="), tail.count > 1 { name = "Kenwood TM-D710"; tail.removeLast() }
                p.device = name
                tail.removeFirst()
            case UInt8(ascii: "_") where tail.count >= 2:
                let yaesu: [UInt8: String] = [0x20: "Yaesu VX-8", 0x22: "Yaesu FTM-350", 0x23: "Yaesu VX-8G", 0x24: "Yaesu FT1D",
                                              0x25: "Yaesu FTM-400DR", 0x29: "Yaesu FTM-100D", 0x28: "Yaesu FT2D", 0x30: "Yaesu FT3D"]
                p.device = yaesu[tail[1]] ?? "Yaesu"
                tail.removeFirst(2)
            default: break
            }
        }
        if tail.count >= 4, tail[3] == UInt8(ascii: "}"), tail[0..<3].allSatisfy({ (33...123).contains($0) }) {
            p.altitudeM = Double((Int(tail[0]) - 33) * 91 * 91 + (Int(tail[1]) - 33) * 91 + (Int(tail[2]) - 33) - 10000)
            tail.removeFirst(4)
        }
        p.comment = latin(tail).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Nachrichten, Objekte, Sonstiges

    private static func parseMessage(_ p: inout APRSPacket, _ rest: [UInt8]) {
        p.kind = .message
        guard rest.count >= 10, rest[9] == UInt8(ascii: ":") else { p.comment = latin(rest); return }
        let to = latin(Array(rest[0..<9])).trimmingCharacters(in: .whitespaces)
        var text = latin(Array(rest.dropFirst(10)))
        var id: String?
        if let r = text.range(of: "{", options: .backwards) {
            let candidate = String(text[r.upperBound...])
            if !candidate.isEmpty, candidate.count <= 5 { id = candidate; text = String(text[..<r.lowerBound]) }
        }
        var kind = APRSMessage.Kind.text
        if text.hasPrefix("ack"), text.count <= 8 { kind = .ack; id = String(text.dropFirst(3)); text = "" }
        else if text.hasPrefix("rej"), text.count <= 8 { kind = .rej; id = String(text.dropFirst(3)); text = "" }
        else if to.hasPrefix("BLN") || to.hasPrefix("NWS") { kind = .bulletin }
        p.message = APRSMessage(addressee: to, text: text.trimmingCharacters(in: .newlines), id: id, kind: kind)
    }

    private static func parseObject(_ p: inout APRSPacket, _ rest: [UInt8]) {
        p.kind = .object
        guard rest.count >= 17 else { p.comment = latin(rest); return }
        p.name = latin(Array(rest[0..<9])).trimmingCharacters(in: .whitespaces)
        p.killed = rest[9] == UInt8(ascii: "_")
        guard rest[9] == UInt8(ascii: "*") || rest[9] == UInt8(ascii: "_") else { p.comment = latin(rest); return }
        p.timestamp = latin(Array(rest[10..<17]))
        let b = Array(rest.dropFirst(17))
        guard let first = b.first else { return }
        if first.isDigitASCII || first == UInt8(ascii: " "), let (pos, amb, sym) = uncompressed(b) {
            p.position = pos; p.ambiguity = amb; p.symbol = sym
            applyExtensions(&p, Array(b.dropFirst(19)), weatherAfterWind: false)
        } else if let (pos, sym, cs, _) = compressed(b) {
            p.position = pos; p.symbol = sym
            if let (c, s) = cs, c <= 89 {
                p.courseDeg = c == 0 ? nil : Int(c) * 4
                p.speedKnots = pow(1.08, Double(s)) - 1
            }
            applyExtensions(&p, Array(b.dropFirst(13)), weatherAfterWind: false, hasWindExtension: false)
        } else {
            p.comment = latin(b)
        }
    }

    private static func parseItem(_ p: inout APRSPacket, _ rest: [UInt8]) {
        p.kind = .item
        guard let end = rest.prefix(10).firstIndex(where: { $0 == UInt8(ascii: "!") || $0 == UInt8(ascii: "_") }), end >= 3 else {
            p.comment = latin(rest); return
        }
        p.name = latin(Array(rest[0..<end])).trimmingCharacters(in: .whitespaces)
        p.killed = rest[end] == UInt8(ascii: "_")
        let b = Array(rest.dropFirst(end + 1))
        guard let first = b.first else { return }
        if first.isDigitASCII || first == UInt8(ascii: " "), let (pos, amb, sym) = uncompressed(b) {
            p.position = pos; p.ambiguity = amb; p.symbol = sym
            applyExtensions(&p, Array(b.dropFirst(19)), weatherAfterWind: false)
        } else if let (pos, sym, _, _) = compressed(b) {
            p.position = pos; p.symbol = sym
            applyExtensions(&p, Array(b.dropFirst(13)), weatherAfterWind: false, hasWindExtension: false)
        } else {
            p.comment = latin(b)
        }
    }

    private static func parseTelemetry(_ p: inout APRSPacket, _ rest: [UInt8]) {
        p.kind = .telemetry
        let text = latin(rest)
        guard text.hasPrefix("#") else { p.comment = text; return }
        let fields = text.dropFirst().split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        p.telemetry = fields.dropFirst().prefix(5).compactMap { Int($0) }
        p.comment = "Folge " + (fields.first ?? "?") + ": " + p.telemetry.map(String.init).joined(separator: " ")
    }

    /// NMEA-Zeilen von Trackern: $GPRMC und $GPGGA
    private static func parseNMEA(_ p: inout APRSPacket, _ info: [UInt8]) {
        p.kind = .nmea
        let line = latin(info).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = line.split(separator: "*").first.map(String.init) ?? line
        let f = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        func coord(_ v: String, _ hemi: String, deg: Int) -> Double? {
            guard v.count > deg + 2, let d = Double(v.prefix(deg)), let m = Double(v.dropFirst(deg)), m < 60 else { return nil }
            let x = d + m / 60
            return hemi == "S" || hemi == "W" ? -x : x
        }
        if f.count >= 10, f[0].hasSuffix("RMC"), f[2] == "A",
           let lat = coord(f[3], f[4], deg: 2), let lon = coord(f[5], f[6], deg: 3) {
            p.position = GeoPoint(lat: lat, lon: lon)
            p.speedKnots = Double(f[7])
            p.courseDeg = Double(f[8]).map { Int($0.rounded()) }
            p.symbol = APRSSymbol(table: "/", code: "\\")
        } else if f.count >= 10, f[0].hasSuffix("GGA"), (Int(f[6]) ?? 0) > 0,
                  let lat = coord(f[2], f[3], deg: 2), let lon = coord(f[4], f[5], deg: 3) {
            p.position = GeoPoint(lat: lat, lon: lon)
            p.altitudeM = Double(f[9])
            p.symbol = APRSSymbol(table: "/", code: "\\")
        }
        if let pos = p.position, !pos.isValid { p.position = nil }
        p.comment = line
    }

    // MARK: Hilfen

    private static func latin(_ b: [UInt8]) -> String {
        String(bytes: b, encoding: .utf8) ?? String(b.map { Character(UnicodeScalar($0)) })
    }

    /// Gerät oder Programm aus der Zieladresse (nur häufige)
    static func deviceName(dest: String) -> String? {
        let table: [(String, String)] = [
            ("APDW", "Dire Wolf"), ("APAND", "APRSdroid"), ("APAT", "Kenwood TH-D7"), ("APK0", "Kenwood TH-D7"), ("APK1", "Kenwood TH-D72"),
            ("APD", "Kenwood TM-D710"), ("APRX", "aprx"), ("APOT", "Argent OpenTracker"), ("APTT", "TinyTrak"), ("APWW", "UI-View"),
            ("APNU", "UIdigi"), ("APZ", "Experimentell"), ("APY", "Yaesu"), ("APMI", "Microsat"), ("APN", "Kantronics"),
            ("APRG", "Aprsd"), ("APLG", "LoRa iGate"), ("APLT", "LoRa Tracker"), ("APWM", "APRS Messenger"), ("APBK", "PRS3 Tracker"),
            ("APFII", "APRS.fi"), ("API", "ICOM"), ("APH", "Hamgate"), ("APOA", "OpenAPRS"), ("APDR", "APRSdroid"), ("APLM", "WXSVR"),
            ("APGO", "APRS-Go"), ("APBL", "BlueStar"), ("APSK", "APRSkit"), ("APTR", "Tracker"), ("APTW", "WXTrak"), ("APT", "Tracker")
        ]
        let d = dest.uppercased()
        if d == "APRS" { return nil }
        return table.first { d.hasPrefix($0.0) }?.1
    }
}

private extension UInt8 {
    var isDigitASCII: Bool { (48...57).contains(self) }
}
