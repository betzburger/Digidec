// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// AIS-Nachrichten (ITU-R M.1371-5): Felder der Typen 1–5, 9, 11, 12, 14, 18, 19, 21, 24, 27 und Tabellen
// (Navigationsstatus, Schiffstyp, Seezeichen, Länderkennung MID).

public enum AISNavStatus {
    public static func text(_ s: Int) -> String {
        switch s {
        case 0: return "Fährt unter Maschine"
        case 1: return "Vor Anker"
        case 2: return "Manövrierunfähig"
        case 3: return "Manövrierbehindert"
        case 4: return "Tiefgangbehindert"
        case 5: return "Festgemacht"
        case 6: return "Auf Grund"
        case 7: return "Beim Fischen"
        case 8: return "Fährt unter Segel"
        case 9: return "Gefahrgut (HSC)"
        case 10: return "Gefahrgut (WIG)"
        case 11: return "Schleppt (achtern)"
        case 12: return "Schiebt / schleppt längsseits"
        case 14: return "AIS-SART aktiv"
        case 15: return "Nicht festgelegt"
        default: return "Reserviert"
        }
    }

    /// Kurzform für Tabellen
    public static func short(_ s: Int) -> String {
        switch s {
        case 0: return "Maschine"
        case 1: return "Anker"
        case 2: return "manövrierunfähig"
        case 3: return "manövrierbehindert"
        case 4: return "tiefgangbehindert"
        case 5: return "festgemacht"
        case 6: return "auf Grund"
        case 7: return "fischt"
        case 8: return "Segel"
        case 11, 12: return "schleppt"
        case 14: return "SART"
        default: return "–"
        }
    }
}

public enum AISShipType {
    public static func text(_ t: Int) -> String {
        let kind: String
        switch t {
        case 0: return "Keine Angabe"
        case 20...29: kind = "Bodeneffektfahrzeug (WIG)"
        case 30: kind = "Fischereifahrzeug"
        case 31: kind = "Schlepper"
        case 32: kind = "Schlepper (Anhang > 200 m)"
        case 33: kind = "Baggerschiff"
        case 34: kind = "Tauchereinsatz"
        case 35: kind = "Marine / Militär"
        case 36: kind = "Segelschiff"
        case 37: kind = "Sportboot"
        case 38, 39: kind = "Reserviert"
        case 40...49: kind = "Tragflügel-/Schnellboot (HSC)"
        case 50: kind = "Lotsenboot"
        case 51: kind = "Seenotrettung"
        case 52: kind = "Schlepper (Hafen)"
        case 53: kind = "Hafentender"
        case 54: kind = "Umweltschutzschiff"
        case 55: kind = "Polizei / Küstenwache"
        case 56, 57: kind = "Örtlich zugewiesen"
        case 58: kind = "Sanitätsfahrzeug"
        case 59: kind = "Neutrales Schiff"
        case 60...69: kind = "Fahrgastschiff"
        case 70...79: kind = "Frachtschiff"
        case 80...89: kind = "Tanker"
        case 90...99: kind = "Sonstiges Schiff"
        default: kind = "Reserviert"
        }
        if (20...29).contains(t) || (40...49).contains(t) || (60...99).contains(t) {
            let d = t % 10
            switch d {
            case 1: return kind + ", Gefahrgut A"
            case 2: return kind + ", Gefahrgut B"
            case 3: return kind + ", Gefahrgut C"
            case 4: return kind + ", Gefahrgut D"
            default: return kind
            }
        }
        return kind
    }

    /// Kurzform für Tabellen
    public static func short(_ t: Int) -> String {
        switch t {
        case 0: return "–"
        case 20...29: return "WIG"
        case 30: return "Fischer"
        case 31, 32, 52: return "Schlepper"
        case 33: return "Bagger"
        case 34: return "Taucher"
        case 35: return "Militär"
        case 36: return "Segler"
        case 37: return "Sportboot"
        case 40...49: return "Schnellboot"
        case 50: return "Lotse"
        case 51: return "Seenotrettung"
        case 53: return "Tender"
        case 54: return "Umwelt"
        case 55: return "Polizei"
        case 58: return "Sanitäter"
        case 60...69: return "Fahrgast"
        case 70...79: return "Fracht"
        case 80...89: return "Tanker"
        case 90...99: return "Sonstige"
        default: return "?"
        }
    }

    /// Grobe Gruppe für Farbe und Symbol
    public enum Group: String, Sendable { case passenger, cargo, tanker, fishing, sailing, pleasure, tug, special, highSpeed, other, unknown }

    public static func group(_ t: Int) -> Group {
        switch t {
        case 0: return .unknown
        case 60...69: return .passenger
        case 70...79: return .cargo
        case 80...89: return .tanker
        case 30: return .fishing
        case 36: return .sailing
        case 37: return .pleasure
        case 31, 32, 52, 33, 53: return .tug
        case 35, 50, 51, 54, 55, 58, 34: return .special
        case 40...49, 20...29: return .highSpeed
        default: return .other
        }
    }
}

/// Seezeichen (Nachricht 21)
public enum AISAtonType {
    public static func text(_ t: Int) -> String {
        switch t {
        case 0: return "Seezeichen"
        case 1: return "Bezugspunkt"
        case 2: return "RACON"
        case 3: return "Feste Anlage auf See"
        case 5: return "Leuchtfeuer ohne Sektoren"
        case 6: return "Leuchtfeuer mit Sektoren"
        case 7: return "Unterfeuer (Richtfeuer)"
        case 8: return "Oberfeuer (Richtfeuer)"
        case 9: return "Bake, Nordkardinal"
        case 10: return "Bake, Ostkardinal"
        case 11: return "Bake, Südkardinal"
        case 12: return "Bake, Westkardinal"
        case 13: return "Bake, Backbordseite"
        case 14: return "Bake, Steuerbordseite"
        case 15: return "Bake, Abzweigung nach Backbord"
        case 16: return "Bake, Abzweigung nach Steuerbord"
        case 17: return "Bake, Einzelgefahr"
        case 18: return "Bake, Mitte Fahrwasser"
        case 19: return "Bake, Sonderzeichen"
        case 20: return "Tonne, Nordkardinal"
        case 21: return "Tonne, Ostkardinal"
        case 22: return "Tonne, Südkardinal"
        case 23: return "Tonne, Westkardinal"
        case 24: return "Tonne, Backbordseite"
        case 25: return "Tonne, Steuerbordseite"
        case 26: return "Tonne, Abzweigung nach Backbord"
        case 27: return "Tonne, Abzweigung nach Steuerbord"
        case 28: return "Tonne, Einzelgefahr"
        case 29: return "Tonne, Mitte Fahrwasser"
        case 30: return "Tonne, Sonderzeichen"
        case 31: return "Feuerschiff / Großtonne / Plattform"
        default: return "Seezeichen"
        }
    }
}

public enum AISEPFD {
    public static func text(_ t: Int) -> String {
        switch t {
        case 1: return "GPS"
        case 2: return "GLONASS"
        case 3: return "GPS/GLONASS"
        case 4: return "Loran-C"
        case 5: return "Chayka"
        case 6: return "Integriertes Navigationssystem"
        case 7: return "Vermessung"
        case 8: return "Galileo"
        default: return "–"
        }
    }
}

// MARK: - Länderkennung (MID)

public enum AISCountry {
    /// MID (erste drei Ziffern der MMSI) → ISO-Länderkennung
    static let mid: [Int: String] = {
        var d: [Int: String] = [:]
        func add(_ iso: String, _ mids: [Int]) { for m in mids { d[m] = iso } }
        add("AL", [201]); add("AD", [202]); add("AT", [203]); add("PT", [204, 255, 263]); add("BE", [205]); add("BY", [206])
        add("BG", [207]); add("VA", [208]); add("CY", [209, 210, 212]); add("DE", [211, 218]); add("GE", [213]); add("MD", [214])
        add("MT", [215, 229, 248, 249, 256]); add("AM", [216]); add("DK", [219, 220]); add("ES", [224, 225]); add("FR", [226, 227, 228])
        add("FI", [230]); add("FO", [231]); add("GB", [232, 233, 234, 235]); add("GI", [236]); add("GR", [237, 239, 240, 241])
        add("HR", [238]); add("MA", [242]); add("HU", [243]); add("NL", [244, 245, 246]); add("IT", [247]); add("IE", [250])
        add("IS", [251]); add("LI", [252]); add("LU", [253]); add("MC", [254]); add("NO", [257, 258, 259]); add("PL", [261])
        add("ME", [262]); add("RO", [264]); add("SE", [265, 266]); add("SK", [267]); add("SM", [268]); add("CH", [269])
        add("CZ", [270]); add("TR", [271]); add("UA", [272]); add("RU", [273]); add("MK", [274]); add("LV", [275]); add("EE", [276])
        add("LT", [277]); add("SI", [278]); add("RS", [279])
        add("AI", [301]); add("US", [303, 338, 366, 367, 368, 369]); add("AG", [304, 305]); add("CW", [306]); add("AW", [307])
        add("BS", [308, 309, 311]); add("BM", [310]); add("BZ", [312]); add("BB", [314]); add("CA", [316]); add("KY", [319])
        add("CR", [321]); add("CU", [323]); add("DM", [325]); add("DO", [327]); add("GP", [329]); add("GD", [330]); add("GL", [331])
        add("GT", [332]); add("HN", [334]); add("HT", [336]); add("JM", [339]); add("KN", [341]); add("LC", [343]); add("MX", [345])
        add("MQ", [347]); add("MS", [348]); add("NI", [350]); add("PA", [351, 352, 353, 354, 355, 356, 357, 370, 371, 372, 373, 374])
        add("PR", [358]); add("SV", [359]); add("PM", [361]); add("TT", [362]); add("TC", [364]); add("VC", [375, 376, 377])
        add("VG", [378]); add("VI", [379])
        add("AF", [401]); add("SA", [403]); add("BD", [405]); add("BH", [408]); add("BT", [410]); add("CN", [412, 413, 414])
        add("TW", [416]); add("LK", [417]); add("IN", [419]); add("IR", [422]); add("AZ", [423]); add("IQ", [425]); add("IL", [428])
        add("JP", [431, 432]); add("TM", [434]); add("KZ", [436]); add("UZ", [437]); add("JO", [438]); add("KR", [440, 441])
        add("PS", [443]); add("KP", [445]); add("KW", [447]); add("LB", [450]); add("KG", [451]); add("MO", [453]); add("MV", [455])
        add("MN", [457]); add("NP", [459]); add("OM", [461]); add("PK", [463]); add("QA", [466]); add("SY", [468]); add("AE", [470, 471])
        add("TJ", [472]); add("YE", [473, 475]); add("HK", [477]); add("BA", [478])
        add("AU", [503]); add("MM", [506]); add("BN", [508]); add("FM", [510]); add("PW", [511]); add("NZ", [512]); add("KH", [514, 515])
        add("CX", [516]); add("CK", [518]); add("FJ", [520]); add("CC", [523]); add("ID", [525]); add("KI", [529]); add("LA", [531])
        add("MY", [533]); add("MP", [536]); add("MH", [538]); add("NC", [540]); add("NU", [542]); add("NR", [544]); add("PF", [546])
        add("PH", [548]); add("PG", [553]); add("PN", [555]); add("SB", [557]); add("AS", [559]); add("WS", [561]); add("SG", [563, 564, 565, 566])
        add("TH", [567]); add("TO", [570]); add("TV", [572]); add("VN", [574]); add("VU", [576, 577]); add("WF", [578])
        add("ZA", [601]); add("AO", [603]); add("DZ", [605]); add("TF", [607, 618, 635]); add("SH", [608, 665]); add("BI", [609])
        add("BJ", [610]); add("BW", [611]); add("CF", [612]); add("CM", [613]); add("CG", [615]); add("KM", [616, 620]); add("CV", [617])
        add("CI", [619]); add("DJ", [621]); add("EG", [622]); add("ET", [624]); add("ER", [625]); add("GA", [626]); add("GH", [627])
        add("GM", [629]); add("GW", [630]); add("GQ", [631]); add("GN", [632]); add("BF", [633]); add("KE", [634]); add("LR", [636, 637])
        add("SS", [638]); add("LY", [642]); add("LS", [644]); add("MU", [645]); add("MG", [647]); add("ML", [649]); add("MZ", [650])
        add("MR", [654]); add("MW", [655]); add("NE", [656]); add("NG", [657]); add("NA", [659]); add("RE", [660]); add("RW", [661])
        add("SD", [662]); add("SN", [663]); add("SC", [664]); add("SO", [666]); add("SL", [667]); add("ST", [668]); add("SZ", [669])
        add("TD", [670]); add("TG", [671]); add("TN", [672]); add("TZ", [674, 677]); add("UG", [675]); add("CD", [676]); add("ZM", [678])
        add("ZW", [679])
        add("AR", [701]); add("BR", [710]); add("BO", [720]); add("CL", [725]); add("CO", [730]); add("EC", [735]); add("FK", [740])
        add("GF", [745]); add("GY", [750]); add("PY", [755]); add("PE", [760]); add("SR", [765]); add("UY", [770]); add("VE", [775])
        return d
    }()

    /// MID einer Schiffs-MMSI (9 Ziffern, MIDxxxxxx), auch Gruppen-, Küsten-, Seezeichen- und Beiboot-Formen
    public static func mid(ofMMSI mmsi: UInt32) -> Int? {
        let s = String(format: "%09d", mmsi)
        let digits = Array(s)
        func three(_ a: Int) -> Int? { Int(String(digits[a..<(a + 3)])) }
        if s.hasPrefix("111") { return three(3) }                       // Flugzeug der Rettung: 111MIDxxx
        if s.hasPrefix("00") { return three(2) }                        // Küstenfunkstelle
        if s.hasPrefix("0") { return three(1) }                         // Gruppenruf
        if s.hasPrefix("99") || s.hasPrefix("98") { return three(2) }   // Seezeichen, Beiboot
        if s.hasPrefix("8") { return three(1) }                         // Handfunkgerät mit DSC
        if s.hasPrefix("970") || s.hasPrefix("972") || s.hasPrefix("974") { return nil }
        return three(0)
    }

    /// Ist die Nummer eine mögliche MMSI? (höchstens 9 Ziffern, bekannte MID, oder Sonderformen 970/972/974, 111MID, 99MID, 98MID, 00MID, 0MID, 8MID)
    public static func isValidMMSI(_ mmsi: UInt32) -> Bool {
        guard mmsi > 0, mmsi < 1_000_000_000 else { return false }
        let s = String(format: "%09d", mmsi)
        if s.hasPrefix("970") || s.hasPrefix("972") || s.hasPrefix("974") { return true }
        if let m = mid(ofMMSI: mmsi) { return Self.mid[m] != nil }
        return false
    }

    public static func iso(ofMMSI mmsi: UInt32) -> String? {
        mid(ofMMSI: mmsi).flatMap { mid[$0] }
    }

    public static func name(ofISO iso: String) -> String {
        Locale(identifier: "de").localizedString(forRegionCode: iso) ?? iso
    }

    public static func flag(ofISO iso: String) -> String {
        var s = ""
        for u in iso.uppercased().unicodeScalars {
            guard let f = UnicodeScalar(0x1F1E6 + u.value - 65) else { return "" }
            s.unicodeScalars.append(f)
        }
        return s
    }

    public static func flag(ofMMSI mmsi: UInt32) -> String {
        iso(ofMMSI: mmsi).map(flag(ofISO:)) ?? ""
    }

    public static func name(ofMMSI mmsi: UInt32) -> String? {
        iso(ofMMSI: mmsi).map(name(ofISO:))
    }
}

// MARK: - Art der Funkstelle nach MMSI

public enum AISStationKind: String, Sendable {
    case shipA, shipB, base, aid, aircraft, sart, group, craft, other

    public var title: String {
        switch self {
        case .shipA: return "Schiff (Klasse A)"
        case .shipB: return "Schiff (Klasse B)"
        case .base: return "Küstenstation"
        case .aid: return "Seezeichen"
        case .aircraft: return "Rettungsflugzeug"
        case .sart: return "Notsender (SART/EPIRB/MOB)"
        case .group: return "Gruppenruf"
        case .craft: return "Beiboot"
        case .other: return "Sonstige"
        }
    }
}

// MARK: - Nachricht

public struct AISMessage: Equatable, Sendable {
    public var type: Int
    public var repeatCount = 0
    public var mmsi: UInt32

    // Position
    public var latitude: Double?
    public var longitude: Double?
    public var sog: Double?                 // Knoten
    public var cog: Double?                 // Grad
    public var heading: Int?
    public var rot: Double?                 // Grad/min (nach rechts positiv)
    public var navStatus: Int?
    public var accuracyHigh = false
    public var timestampSecond: Int?        // Sekunde der UTC-Minute, 60 = nicht verfügbar
    public var altitude: Int?               // Meter (Nachricht 9)
    public var classB = false
    public var maneuver: Int?

    // Statische Daten
    public var imo: UInt32?
    public var callsign: String?
    public var name: String?
    public var shipType: Int?
    public var toBow: Int?
    public var toStern: Int?
    public var toPort: Int?
    public var toStarboard: Int?
    public var epfd: Int?
    public var draught: Double?
    public var destination: String?
    public var etaMonth: Int?
    public var etaDay: Int?
    public var etaHour: Int?
    public var etaMinute: Int?
    public var aisVersion: Int?
    public var partNumber: Int?
    public var vendorID: String?
    public var motherMMSI: UInt32?

    // Seezeichen
    public var atonType: Int?
    public var offPosition = false
    public var virtualAton = false

    // Basisstation (4, 11)
    public var utc: (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int)?

    // Text (12, 14)
    public var text: String?
    public var destinationMMSI: UInt32?

    // Binäre Nachrichten (6, 8)
    public var dac: Int?
    public var fid: Int?
    public var binary: AISBinary?
    /// Position kommt von einer Verkehrszentrale (künstliches Ziel, FI 17), nicht vom Schiff selbst
    public var synthetic = false

    public static func == (a: AISMessage, b: AISMessage) -> Bool {
        a.type == b.type && a.mmsi == b.mmsi && a.latitude == b.latitude && a.longitude == b.longitude && a.name == b.name
            && a.sog == b.sog && a.cog == b.cog && a.heading == b.heading && a.imo == b.imo && a.destination == b.destination
    }

    public var hasPosition: Bool { latitude != nil && longitude != nil }

    public var length: Int? {
        guard let b = toBow, let s = toStern, b + s > 0 else { return nil }
        return b + s
    }

    public var beam: Int? {
        guard let p = toPort, let s = toStarboard, p + s > 0 else { return nil }
        return p + s
    }

    public var kind: AISStationKind { AISMessage.kind(mmsi: mmsi, type: type) }

    public static func kind(mmsi: UInt32, type: Int = 0) -> AISStationKind {
        let s = String(format: "%09d", mmsi)
        if s.hasPrefix("970") || s.hasPrefix("972") || s.hasPrefix("974") { return .sart }
        if s.hasPrefix("111") { return .aircraft }
        if s.hasPrefix("99") || type == 21 { return .aid }
        if s.hasPrefix("00") || type == 4 || type == 11 { return .base }
        if s.hasPrefix("98") { return .craft }
        if s.hasPrefix("0") { return .group }
        if type == 18 || type == 19 || type == 24 { return .shipB }
        if type == 9 { return .aircraft }
        return .shipA
    }

    // MARK: Plausibilität

    /// Länge in Bit, die der Typ nach ITU-R M.1371-5 haben darf (nach der Auffüllung auf volle Bytes auf der Leitung).
    /// Schützt vor Zufallstreffern der 16-Bit-Prüfsumme: ein Rahmen mit falscher Länge für seinen Typ wird verworfen.
    /// `strictMMSI`: die Nummer muss eine mögliche MMSI sein (bekannte MID) und die Länge ein Vielfaches von 8 Bit (Auffüllung auf volle Bytes). Gilt für Rahmen aus Wiederholungsversuchen, bei denen
    /// ein Zufallstreffer wahrscheinlicher ist; echte Sender mit Platzhalter-Nummern (222222222) kommen beim ersten Versuch durch.
    public static func isPlausible(_ bits: AISBits, strictMMSI: Bool = false) -> Bool {
        let n = bits.count
        guard n >= 38 else { return false }
        let type = Int(bits.u(0, 6))
        let mmsi = bits.u(8, 30)
        guard mmsi > 0, mmsi < 1_000_000_000, !strictMMSI || (AISCountry.isValidMMSI(mmsi) && n % 8 == 0) else { return false }
        switch type {
        case 1, 2, 3, 4, 9, 11, 18, 22: return n == 168
        case 5: return n == 424 || n == 420 || n == 422
        case 6: return n >= 72 && n <= 1008
        case 7, 13: return n >= 72 && n <= 168
        case 8: return n >= 56 && n <= 1008
        case 10: return n == 72
        case 12: return n >= 72 && n <= 1008
        case 14: return n >= 40 && n <= 1008
        case 15: return n >= 88 && n <= 168
        case 16: return n == 96 || n == 144
        case 17: return n >= 80 && n <= 816
        case 19: return n >= 304 && n <= 312
        case 20: return n >= 72 && n <= 160
        case 21: return n >= 272 && n <= 368
        case 23: return n == 160
        case 24: return n == 160 || n == 168
        case 25: return n >= 40 && n <= 168
        case 26: return n >= 60 && n <= 1004
        case 27: return n == 96
        default: return false
        }
    }

    // MARK: Decodieren

    /// Wandelt Nutzbits in eine Nachricht; nil bei unbekanntem Typ oder zu kurzer Nachricht
    public static func decode(_ bits: AISBits) -> AISMessage? {
        guard bits.count >= 38 else { return nil }
        let type = Int(bits.u(0, 6))
        var m = AISMessage(type: type, mmsi: bits.u(8, 30))
        m.repeatCount = Int(bits.u(6, 2))

        func lon(_ start: Int, _ len: Int, div: Double) -> Double? {
            let v = Double(bits.i(start, len)) / div
            return abs(v) <= 180 ? v : nil
        }
        func lat(_ start: Int, _ len: Int, div: Double) -> Double? {
            let v = Double(bits.i(start, len)) / div
            return abs(v) <= 90 ? v : nil
        }
        func sog10(_ start: Int) -> Double? {
            let v = Int(bits.u(start, 10))
            return v >= 1023 ? nil : Double(v) / 10
        }
        func cog10(_ start: Int) -> Double? {
            let v = Int(bits.u(start, 12))
            return v >= 3600 ? nil : Double(v) / 10
        }
        func heading(_ start: Int) -> Int? {
            let v = Int(bits.u(start, 9))
            return v <= 359 ? v : nil
        }

        switch type {
        case 1, 2, 3:
            guard bits.count >= 149 else { return nil }
            m.navStatus = Int(bits.u(38, 4))
            let r = bits.i(42, 8)
            if r != -128 {
                let x = Double(abs(r)) / 4.733
                m.rot = (r < 0 ? -1 : 1) * x * x
            }
            m.sog = sog10(50)
            m.accuracyHigh = bits.flag(60)
            m.longitude = lon(61, 28, div: 600_000)
            m.latitude = lat(89, 27, div: 600_000)
            m.cog = cog10(116)
            m.heading = heading(128)
            m.timestampSecond = Int(bits.u(137, 6))
            m.maneuver = Int(bits.u(143, 2))
        case 4, 11:
            guard bits.count >= 138 else { return nil }
            let y = Int(bits.u(38, 14))
            if y > 0 {
                m.utc = (y, Int(bits.u(52, 4)), Int(bits.u(56, 5)), Int(bits.u(61, 5)), Int(bits.u(66, 6)), Int(bits.u(72, 6)))
            }
            m.accuracyHigh = bits.flag(78)
            m.longitude = lon(79, 28, div: 600_000)
            m.latitude = lat(107, 27, div: 600_000)
            m.epfd = Int(bits.u(134, 4))
        case 5:
            guard bits.count >= 424 - 2 else { return nil }
            m.aisVersion = Int(bits.u(38, 2))
            let imo = bits.u(40, 30)
            m.imo = imo > 0 ? imo : nil
            m.callsign = bits.text(70, chars: 7)
            m.name = bits.text(112, chars: 20)
            m.shipType = Int(bits.u(232, 8))
            m.toBow = Int(bits.u(240, 9))
            m.toStern = Int(bits.u(249, 9))
            m.toPort = Int(bits.u(258, 6))
            m.toStarboard = Int(bits.u(264, 6))
            m.epfd = Int(bits.u(270, 4))
            let mo = Int(bits.u(274, 4)), d = Int(bits.u(278, 5)), h = Int(bits.u(283, 5)), mi = Int(bits.u(288, 6))
            if (1...12).contains(mo) && (1...31).contains(d) { m.etaMonth = mo; m.etaDay = d }
            if h < 24 { m.etaHour = h }
            if mi < 60 { m.etaMinute = mi }
            let dr = Int(bits.u(294, 8))
            m.draught = dr > 0 ? Double(dr) / 10 : nil
            m.destination = bits.text(302, chars: 20)
        case 9:
            guard bits.count >= 133 else { return nil }
            let a = Int(bits.u(38, 12))
            m.altitude = a < 4095 ? a : nil
            let s = Int(bits.u(50, 10))
            m.sog = s < 1023 ? Double(s) : nil
            m.accuracyHigh = bits.flag(60)
            m.longitude = lon(61, 28, div: 600_000)
            m.latitude = lat(89, 27, div: 600_000)
            m.cog = cog10(116)
            m.timestampSecond = Int(bits.u(128, 6))

        case 6, 8:
            guard let h = AISBinaryDecoder.header(bits, type: type) else { return nil }
            m.dac = h.dac
            m.fid = h.fid
            if type == 6 { m.destinationMMSI = bits.u(40, 30) }
            let b = AISBinaryDecoder.decode(bits, type: type, dac: h.dac, fid: h.fid)
            m.binary = b
            switch b {
            case .meteo(let w):
                m.latitude = w.latitude
                m.longitude = w.longitude
            case .text(_, let t):
                m.text = t
            case .trafficSignal(let s):
                if let (_, p) = AISBinaryDecoder.trafficSignal(bits) { m.latitude = p?.lat; m.longitude = p?.lon }
                m.name = s.station.isEmpty ? nil : s.station
            default: break
            }
        case 12:
            guard bits.count >= 72 else { return nil }

            m.destinationMMSI = bits.u(40, 30)
            m.text = bits.text(72, chars: (bits.count - 72) / 6)
        case 14:
            guard bits.count >= 40 else { return nil }
            m.text = bits.text(40, chars: (bits.count - 40) / 6)
        case 18:
            guard bits.count >= 133 else { return nil }
            m.classB = true
            m.sog = sog10(46)
            m.accuracyHigh = bits.flag(56)
            m.longitude = lon(57, 28, div: 600_000)
            m.latitude = lat(85, 27, div: 600_000)
            m.cog = cog10(112)
            m.heading = heading(124)
            m.timestampSecond = Int(bits.u(133, 6))
        case 19:
            guard bits.count >= 305 else { return nil }
            m.classB = true
            m.sog = sog10(46)
            m.accuracyHigh = bits.flag(56)
            m.longitude = lon(57, 28, div: 600_000)
            m.latitude = lat(85, 27, div: 600_000)
            m.cog = cog10(112)
            m.heading = heading(124)
            m.timestampSecond = Int(bits.u(133, 6))
            m.name = bits.text(143, chars: 20)
            m.shipType = Int(bits.u(263, 8))
            m.toBow = Int(bits.u(271, 9))
            m.toStern = Int(bits.u(280, 9))
            m.toPort = Int(bits.u(289, 6))
            m.toStarboard = Int(bits.u(295, 6))
            m.epfd = Int(bits.u(301, 4))
        case 21:
            guard bits.count >= 272 else { return nil }
            m.atonType = Int(bits.u(38, 5))
            var name = bits.text(43, chars: 20)
            if bits.count >= 272 + 6 {
                // Namenserweiterung (Zeichen 21 bis 34); nur Füllzeichen „@“ oder „?“ zählen nicht
                let ext = bits.text(272, chars: (bits.count - 272) / 6)
                if !ext.isEmpty && !ext.allSatisfy({ $0 == "?" }) { name += ext }
            }
            m.name = name
            m.accuracyHigh = bits.flag(163)
            m.longitude = lon(164, 28, div: 600_000)
            m.latitude = lat(192, 27, div: 600_000)
            m.toBow = Int(bits.u(219, 9))
            m.toStern = Int(bits.u(228, 9))
            m.toPort = Int(bits.u(237, 6))
            m.toStarboard = Int(bits.u(243, 6))
            m.epfd = Int(bits.u(249, 4))
            m.timestampSecond = Int(bits.u(253, 6))
            m.offPosition = bits.flag(259)
            m.virtualAton = bits.flag(269)
        case 24:
            guard bits.count >= 160 else { return nil }
            let part = Int(bits.u(38, 2))
            m.classB = true
            m.partNumber = part
            if part == 0 {
                m.name = bits.text(40, chars: 20)
            } else if bits.count >= 162 {
                m.shipType = Int(bits.u(40, 8))
                m.vendorID = bits.text(48, chars: 3)
                m.callsign = bits.text(90, chars: 7)
                if String(format: "%09d", m.mmsi).hasPrefix("98") {
                    m.motherMMSI = bits.u(132, 30)
                } else {
                    m.toBow = Int(bits.u(132, 9))
                    m.toStern = Int(bits.u(141, 9))
                    m.toPort = Int(bits.u(150, 6))
                    m.toStarboard = Int(bits.u(156, 6))
                }
            } else {
                return nil
            }
        case 27:
            guard bits.count >= 94 else { return nil }
            m.accuracyHigh = bits.flag(38)
            m.navStatus = Int(bits.u(40, 4))
            m.longitude = lon(44, 18, div: 600)
            m.latitude = lat(62, 17, div: 600)
            let s = Int(bits.u(79, 6))
            m.sog = s < 63 ? Double(s) : nil
            let c = Int(bits.u(85, 9))
            m.cog = c < 360 ? Double(c) : nil
        default:
            return nil
        }
        return m
    }

    public static func decode(sentence: String) -> AISMessage? {
        guard let s = AISNMEA.parse(sentence), let b = AISArmor.decode(s.payload, fill: s.fill) else { return nil }
        return decode(AISBits(b))
    }
}

// MARK: - Zusammenführen (eine Funkstelle)

/// Eine Position mit Zeit
public struct AISFix: Equatable, Sendable {
    public var time: Date
    public var latitude: Double
    public var longitude: Double

    public var point: GeoPoint { GeoPoint(lat: latitude, lon: longitude) }
}

/// Alles, was über eine Funkstelle (MMSI) empfangen wurde
public struct AISVessel: Identifiable, Equatable, Sendable {
    public var mmsi: UInt32
    public var id: UInt32 { mmsi }
    public var firstHeard: Date
    public var lastHeard: Date
    public var lastPositionDate: Date?
    public var messages = 0
    public var positions = 0
    public var isClassB = false
    public var isBase = false
    public var isAid = false
    public var isAircraft = false

    public var latitude: Double?
    public var longitude: Double?
    public var sog: Double?
    public var cog: Double?
    public var heading: Int?
    public var rot: Double?
    public var navStatus: Int?
    public var accuracyHigh = false
    public var altitude: Int?
    public var offPosition = false
    public var virtualAton = false

    public var name: String?
    public var callsign: String?
    public var imo: UInt32?
    public var shipType: Int?
    public var toBow: Int?
    public var toStern: Int?
    public var toPort: Int?
    public var toStarboard: Int?
    public var draught: Double?
    public var destination: String?
    public var etaMonth: Int?
    public var etaDay: Int?
    public var etaHour: Int?
    public var etaMinute: Int?
    public var atonType: Int?
    public var motherMMSI: UInt32?
    public var lastText: String?
    /// Letztes Wetter-/Gewässertelegramm (Messstationen) und sein Empfang
    public var meteo: AISMeteo?
    public var meteoDate: Date?
    public var inland: AISInlandStatic?
    public var waterLevels: AISWaterLevels?
    public var emma: AISEmma?
    public var trafficSignal: AISTrafficSignal?
    public var extended: AISExtendedShip?
    public var persons: AISPersons?
    public var monitoring: AISAtonMonitoring?
    /// Zuletzt gehörtes unbekanntes Binärtelegramm („DAC 366 · FI 56“)
    public var otherBinary: String?
    /// Position nur aus künstlichen Zielen einer Verkehrszentrale
    public var isSynthetic = false
    /// Auf welchen Kanälen gehört (A = 161,975, B = 162,025 MHz)
    public var heardOnA = false
    public var heardOnB = false

    public var track: [AISFix] = []
    public static let maxTrack = 2_000

    public init(mmsi: UInt32, now: Date) {
        self.mmsi = mmsi
        firstHeard = now
        lastHeard = now
    }

    public var kind: AISStationKind {
        if isAid { return .aid }
        if isBase { return .base }
        if isAircraft { return .aircraft }
        let base = AISMessage.kind(mmsi: mmsi)
        if base != .shipA { return base }
        return isClassB ? .shipB : .shipA
    }

    public var point: GeoPoint? { latitude.flatMap { la in longitude.map { GeoPoint(lat: la, lon: $0) } } }

    public var length: Int? {
        guard let b = toBow, let s = toStern, b + s > 0 else { return nil }
        return b + s
    }

    public var beam: Int? {
        guard let p = toPort, let s = toStarboard, p + s > 0 else { return nil }
        return p + s
    }

    /// Name oder, wenn unbekannt, die MMSI
    public var displayName: String {
        if let n = name, !n.isEmpty { return n }
        return String(format: "%09d", mmsi)
    }

    public var iso: String? { AISCountry.iso(ofMMSI: mmsi) }

    /// Fährt das Schiff (Geschwindigkeit über 0,5 Knoten)?
    public var isMoving: Bool { (sog ?? 0) > 0.5 }

    public var etaText: String? {
        guard let mo = etaMonth, let d = etaDay else { return nil }
        var s = String(format: "%02d.%02d.", d, mo)
        if let h = etaHour, let mi = etaMinute { s += String(format: " %02d:%02d UTC", h, mi) }
        return s
    }

    /// Eine Nachricht einarbeiten. Rückgabe: `true`, wenn sich eine Position ergeben hat.
    @discardableResult
    public mutating func ingest(_ m: AISMessage, at now: Date) -> Bool {
        lastHeard = now
        messages += 1
        if m.classB { isClassB = true }
        if m.type == 4 { isBase = true }
        if m.type == 21 { isAid = true; virtualAton = m.virtualAton }
        if m.type == 9 { isAircraft = true }
        if let n = m.name, !n.isEmpty { name = n }
        if let c = m.callsign, !c.isEmpty { callsign = c }
        if let i = m.imo { imo = i }
        if let t = m.shipType { shipType = t }
        if let v = m.toBow { toBow = v }
        if let v = m.toStern { toStern = v }
        if let v = m.toPort { toPort = v }
        if let v = m.toStarboard { toStarboard = v }
        if let v = m.draught { draught = v }
        if let d = m.destination, !d.isEmpty { destination = d }
        if m.etaMonth != nil { etaMonth = m.etaMonth; etaDay = m.etaDay; etaHour = m.etaHour; etaMinute = m.etaMinute }
        if let a = m.atonType { atonType = a }
        if let mm = m.motherMMSI { motherMMSI = mm }

        if let t = m.text, !t.isEmpty { lastText = t }
        if let b = m.binary {
            switch b {
            case .meteo(let w): meteo = w; meteoDate = now
            case .inland(let i): inland = i
            case .waterLevels(let w): waterLevels = w
            case .emma(let e): emma = e
            case .trafficSignal(let s): trafficSignal = s
            case .extended(let e): extended = e
            case .persons(let p): persons = p
            case .atonMonitoring(let a): monitoring = a
            case .other: if let d = m.dac, let f = m.fid { otherBinary = "DAC \(d) · FI \(f)" }
            default: break
            }
        }
        if m.synthetic { isSynthetic = true } else if m.hasPosition { isSynthetic = false }
        guard m.hasPosition, let la = m.latitude, let lo = m.longitude else { return false }
        // Nachricht 27 (Satelliten, grobe Position) nicht über eine genaue Position legen
        if m.type == 27, let last = lastPositionDate, now.timeIntervalSince(last) < 600 { return false }
        if let s = m.sog { sog = s } else if m.type != 27 { sog = nil }
        if let c = m.cog { cog = c } else if m.type != 27 { cog = nil }
        heading = m.heading
        if m.rot != nil || m.type <= 3 { rot = m.rot }
        if let n = m.navStatus { navStatus = n }
        accuracyHigh = m.accuracyHigh
        if let a = m.altitude { altitude = a }
        if m.type == 21 { offPosition = m.offPosition }
        latitude = la
        longitude = lo
        lastPositionDate = now
        positions += 1
        if let last = track.last, abs(last.latitude - la) < 1e-5, abs(last.longitude - lo) < 1e-5 {
            track[track.count - 1].time = now
        } else if isAid || isBase {
            track = [AISFix(time: now, latitude: la, longitude: lo)]
        } else {
            track.append(AISFix(time: now, latitude: la, longitude: lo))
            if track.count > Self.maxTrack { track.removeFirst(track.count - Self.maxTrack) }
        }
        return true
    }
}
