// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - Standortberichte in ACARS-Meldungen

/// Ein Standortbericht aus dem Text einer ACARS-Meldung (die Funkstrecke selbst nennt keinen Ort)
public struct ACARSPositionReport: Equatable, Sendable {
    public var point: GeoPoint
    /// Flughöhe in Fuß, wenn die Meldung sie nennt
    public var altitudeFt: Double?
    /// Uhrzeit der Position laut Meldung (UTC), „21:57:54“ oder „21:57“
    public var timeUTC: String?
    /// Kurs in Grad, wenn die Meldung ihn nennt
    public var headingDeg: Double?
    /// Start- und Zielflughafen (ICAO), wenn die Meldung sie mitliefert
    public var from: String?
    public var to: String?
    /// Name des Formats, z. B. „H1 POS“ (für die Anzeige)
    public var format: String

    public init(point: GeoPoint, altitudeFt: Double? = nil, timeUTC: String? = nil, headingDeg: Double? = nil,
                from: String? = nil, to: String? = nil, format: String) {
        self.point = point
        self.altitudeFt = altitudeFt
        self.timeUTC = timeUTC
        self.headingDeg = headingDeg
        self.from = from
        self.to = to
        self.format = format
    }
}

/// Liest Positionen aus den Meldungen der Flugzeuge. Die Formate sind „Airline Defined“ (je nach Fluggesellschaft und Bordrechner
/// verschieden); umgesetzt sind die verbreiteten nach den Regeln der Referenz „acars-decoder-typescript“ (airframes.io, MIT),
/// deren Testmeldungen als Logiktests dienen. Meldungen ohne erkennbare Position ergeben nil.
public enum ACARSPositionParser {

    // MARK: Hilfen

    private struct Rx: Sendable {
        let re: NSRegularExpression
        init(_ pattern: String) { re = try! NSRegularExpression(pattern: pattern) }
        /// Gruppen 0…n (nicht beteiligte Gruppen leer), nil ohne Treffer
        func match(_ s: String) -> [String]? {
            let ns = s as NSString
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }

    private static func number(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces))
    }

    private static func sign(_ hemisphere: String) -> Double {
        (hemisphere == "S" || hemisphere == "W") ? -1 : 1
    }

    /// Grad und Minuten mit einer Nachkommastelle in einer Zahl: 43312 → 43° 31,2′ (Breite), 123174 → 123° 17,4′ (Länge)
    static func degreesMinutesTenths(_ digits: String) -> Double? {
        guard let raw = Int(digits.trimmingCharacters(in: .whitespaces)) else { return nil }
        let minutes = Double(raw % 1000) / 10
        guard minutes < 60 else { return nil }
        return Double(raw / 1000) + minutes / 60
    }

    /// Grad, Minuten und Sekunden in einer Zahl: 390104 → 39° 01′ 04″; 754601 → 75° 46′ 01″ (auch mit führender Null)
    static func degreesMinutesSeconds(_ digits: String) -> Double? {
        guard let raw = Int(digits.trimmingCharacters(in: .whitespaces)) else { return nil }
        let seconds = raw % 100, minutes = (raw / 100) % 100, degrees = raw / 10_000
        guard minutes < 60, seconds < 60 else { return nil }
        return Double(degrees) + Double(minutes) / 60 + Double(seconds) / 3600
    }

    /// „3539.2“ oder „07937.2“: ddmm.m bzw. dddmm.m
    static func degreesDecimalMinutes(_ s: String) -> Double? {
        guard let dot = s.firstIndex(of: "."), let whole = Int(s[s.startIndex..<dot].trimmingCharacters(in: .whitespaces)),
              let frac = Double("0" + s[dot...]) else { return nil }
        let minutes = Double(whole % 100) + frac
        guard minutes < 60 else { return nil }
        return Double(whole / 100) + minutes / 60
    }

    private static func point(_ lat: Double?, _ lon: Double?) -> GeoPoint? {
        guard let lat, let lon else { return nil }
        let p = GeoPoint(lat: lat, lon: lon)
        // Platzhalter (0/0) und ungültige Werte verwerfen
        guard p.isValid, !(lat == 0 && lon == 0) else { return nil }
        return p
    }

    private static func clock(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.allSatisfy(\.isNumber), t.count == 4 || t.count == 6 else { return nil }
        let h = Int(t.prefix(2))!, m = Int(t.dropFirst(2).prefix(2))!, sec = t.count == 6 ? Int(t.suffix(2))! : 0
        guard h < 24, m < 60, sec < 60 else { return nil }
        return t.count == 6 ? "\(t.prefix(2)):\(t.dropFirst(2).prefix(2)):\(t.suffix(2))" : "\(t.prefix(2)):\(t.suffix(2))"
    }

    /// Flugfläche („370“) → Fuß
    private static func flightLevel(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard (2...3).contains(t.count), t.allSatisfy(\.isNumber), let v = Double(t) else { return nil }
        return v * 100
    }

    private static func altitude(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.allSatisfy(\.isNumber), let v = Double(t), v <= 60_000 else { return nil }
        return v
    }

    private static func airport(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count == 4 && t.allSatisfy({ $0.isLetter && $0.isUppercase }) ? t : nil
    }

    /// Ziffernfolgen aus Breite und Länge: Minuten über 59 gibt es nicht; dann sind es Dezimalgrad (z. B. N38843 = 38,843°)
    private static func tenthsOrThousandths(lat: String, lon: String, preferDecimal: Bool) -> (Double, Double)? {
        guard let la = Int(lat.trimmingCharacters(in: .whitespaces)), let lo = Int(lon.trimmingCharacters(in: .whitespaces)) else { return nil }
        let minutesLooksValid = (la % 1000) / 10 < 60 && (lo % 1000) / 10 < 60
        if preferDecimal || !minutesLooksValid { return (Double(la) / 1000, Double(lo) / 1000) }
        guard let a = degreesMinutesTenths(lat), let b = degreesMinutesTenths(lon) else { return nil }
        return (a, b)
    }

    // MARK: Einstieg

    public static func parse(label: String, text rawText: String) -> ACARSPositionReport? {
        let text = rawText.replacingOccurrences(of: "\r", with: "")
        guard text.count >= 8 else { return nil }
        var parsers: [(String) -> ACARSPositionReport?] = []
        switch label {
        case "10": parsers = [label10Pos, label10LDR, label10Slash]
        case "12": parsers = [label12NSpace, label12Pos]
        case "15": parsers = [label15]
        case "16": parsers = [label15, label16NSpace, label16POSA1, label16AUTPOS, label16TOD]
        case "1L": parsers = [label1L070, label1L660, label1LSlash, label1L3Line]
        case "20": parsers = [label20]
        case "21": parsers = [label21]
        case "22": parsers = [label22]
        case "24": parsers = [label24]
        case "2P": parsers = [label2PFM]
        case "44": parsers = [label44]
        case "58": parsers = [label58]
        case "80": parsers = [label80]
        case "83": parsers = [label83]
        case "HX": parsers = [labelHX]
        case "4T": parsers = [label4TAGFSR]
        default: break
        }
        for p in parsers {
            if let r = p(text) { return r }
        }
        // Bordrechner-Meldungen nach ARINC 702 kommen in H1, 4J, 5Z, B6 und anderen Labels vor
        return arinc702(text) ?? starPOS(text) ?? mSeries(text) ?? parenthesizedPOS(text)
    }

    // MARK: ARINC 702 (Label H1 und andere)

    private static let arincPOS = Rx(#"POS([NS])(\d{5})([EW])(\d{6})((?:,[^,/\n]*){0,14})"#)
    private static let arincPS = Rx(#"/PS([NS])(\d{5})([EW])(\d{6})((?:,[^,/\n]*){0,14})"#)
    private static let arincTS = Rx(#"/TS(\d{6}),(\d{6})([NS])(\d{5})([EW])(\d{6})((?:,[^,/\n]*){0,10})"#)

    /// `POSN43312W123174,EASON,215754,370,EBINY,…` und `/PSN39277W077359,142800,240,…` (Grad, Minuten mit Zehntel)
    static func arinc702(_ text: String) -> ACARSPositionReport? {
        func report(_ g: [String], from i: Int, format: String) -> ACARSPositionReport? {
            guard let lat = degreesMinutesTenths(g[i + 1]), let lon = degreesMinutesTenths(g[i + 3]),
                  let p = point(lat * sign(g[i]), lon * sign(g[i + 2])) else { return nil }
            let fields = g[i + 4].split(separator: ",", omittingEmptySubsequences: false).dropFirst().map(String.init)
            var r = ACARSPositionReport(point: p, format: format)
            // Zwei Anordnungen: [Ort, Wegpunkt, Zeit, FL, …] und [Ort, Zeit, FL, …]
            if fields.count >= 3, fields[0].count == 6, fields[0].allSatisfy(\.isNumber), flightLevel(fields[1]) != nil {
                r.timeUTC = clock(fields[0])
                r.altitudeFt = flightLevel(fields[1])
            } else if fields.count >= 3 {
                r.timeUTC = clock(fields[1])
                r.altitudeFt = flightLevel(fields[2])
            }
            return r
        }
        if let g = arincPOS.match(text), let r = report(g, from: 1, format: "POS") { return r }
        if let g = arincPS.match(text), let r = report(g, from: 1, format: "PS") { return r }
        if let g = arincTS.match(text) {
            // /TS140122,141124N38321W078003,,140122,450,… : Zeit, Datum, Ort, danach Zeit und FL
            if var r = report(g, from: 3, format: "TS") { r.timeUTC = clock(g[1]) ?? r.timeUTC; return r }
        }
        return nil
    }

    private static let starPOSRx = Rx(#"^\*POS(\d{2})(\d{2})(\d{4})([NS])(\d{2})(\d{2})([EW])(\d{3})(\d{2})(\d{5})"#)

    /// `*POS10300950N3954W07759363312045802M5230175`: Monat, Tag, hhmm, Breite ddmm, Länge dddmm, Höhe in Fuß
    static func starPOS(_ text: String) -> ACARSPositionReport? {
        guard let t = text.range(of: "*POS").map({ String(text[$0.lowerBound...]) }), let g = starPOSRx.match(t),
              let la = Double(g[5]), let lam = Double(g[6]), let lo = Double(g[8]), let lom = Double(g[9]),
              lam < 60, lom < 60,
              let p = point((la + lam / 60) * sign(g[4]), (lo + lom / 60) * sign(g[7])) else { return nil }
        return ACARSPositionReport(point: p, altitudeFt: altitude(g[10]), timeUTC: clock(g[3]), format: "*POS")
    }

    private static let mSeriesRx = Rx(#"M\d{2}A[A-Z]{2}\d{4}([A-Z]{4}),([A-Z]{4}),(\d{6}),\s*(-?\s*\d+\.\d+),\s*(-?\s*\d+\.\d+),\s*(\d+),\s*(\d+)"#)

    /// `M85AQF0073YSSY,KSFO,101621,- 4.9985,-169.9820,35003,290,…`: Start, Ziel, TTHHMM, Breite, Länge (Dezimalgrad), Höhe, Kurs
    static func mSeries(_ text: String) -> ACARSPositionReport? {
        guard let g = mSeriesRx.match(text),
              let lat = number(g[4].replacingOccurrences(of: " ", with: "")), let lon = number(g[5].replacingOccurrences(of: " ", with: "")),
              let p = point(lat, lon) else { return nil }
        return ACARSPositionReport(point: p, altitudeFt: altitude(g[6]), timeUTC: clock(String(g[3].suffix(4))),
                                   headingDeg: number(g[7]).flatMap { $0 <= 360 ? $0 : nil },
                                   from: airport(g[1]), to: airport(g[2]), format: "M-Serie")
    }

    private static let parenRx = Rx(#"\(POS-[^-\n]*-(\d{2})(\d{2})([NS])(\d{3})(\d{2})([EW])/(\d{4,6})(?:\s+F(\d{3}))?"#)

    /// `(POS-KLM296  -3911N07600W/234212 F250` (ICAO-Flugplanformat): Breite ddmm, Länge dddmm, Zeit, Flugfläche
    static func parenthesizedPOS(_ text: String) -> ACARSPositionReport? {
        guard let g = parenRx.match(text), let la = Double(g[1]), let lam = Double(g[2]), let lo = Double(g[4]), let lom = Double(g[5]),
              lam < 60, lom < 60, let p = point((la + lam / 60) * sign(g[3]), (lo + lom / 60) * sign(g[6])) else { return nil }
        return ACARSPositionReport(point: p, altitudeFt: flightLevel(g[8]), timeUTC: clock(g[7]), format: "(POS")
    }

    // MARK: Label 10

    private static let l10PosRx = Rx(#"^POS(\d{6}),\s*([NS])\s*(\d{3,5}),\s*([EW])\s*(\d{3,5}),([^,]*),([^,]*),"#)

    /// `POS082150, N 3885,W 7841,---,308,…`: Breite und Länge in Hundertstelgrad
    static func label10Pos(_ text: String) -> ACARSPositionReport? {
        guard let g = l10PosRx.match(text), let lat = number(g[3]), let lon = number(g[5]),
              let p = point(lat / 100 * sign(g[2]), lon / 100 * sign(g[4])) else { return nil }
        return ACARSPositionReport(point: p, altitudeFt: flightLevel(g[7]), timeUTC: clock(String(g[1].suffix(4))), format: "10 POS")
    }

    private static let l10LDRRx = Rx(#"^LDR\d+,[^,]*,[^,]*,[^,]*,[^,]*,\s*([NS])\s*(\d+\.\d+),\s*([EW])\s*(\d+\.\d+),\s*(\d+)"#)

    /// `LDR01,189,C,SWA-2600-016,0,N 38.151,W 76.623,37003, …`
    static func label10LDR(_ text: String) -> ACARSPositionReport? {
        guard let g = l10LDRRx.match(text), let lat = number(g[2]), let lon = number(g[4]),
              let p = point(lat * sign(g[1]), lon * sign(g[3])) else { return nil }
        return ACARSPositionReport(point: p, altitudeFt: altitude(g[5]), format: "10 LDR")
    }

    private static let l10SlashRx = Rx(#"^/([NS])(\d+\.\d+)/([EW])(\d+\.\d+)/"#)

    /// `/N39.182/W077.217/10/0.42/180/055/KIAD/…`
    static func label10Slash(_ text: String) -> ACARSPositionReport? {
        guard let g = l10SlashRx.match(text), let lat = number(g[2]), let lon = number(g[4]),
              let p = point(lat * sign(g[1]), lon * sign(g[3])) else { return nil }
        return ACARSPositionReport(point: p, format: "10 /")
    }

    // MARK: Label 12

    private static let l12NRx = Rx(#"^([NS])\s(\d+\.\d+),([EW])\s*(\d+\.\d+),(GRD|\*\*\*|\d+),(\d{4,6})?"#)

    /// `N 42.150,W121.187,39000,161859, 109,.C-GWSO,1742`
    static func label12NSpace(_ text: String) -> ACARSPositionReport? {
        guard let g = l12NRx.match(text), let lat = number(g[2]), let lon = number(g[4]),
              let p = point(lat * sign(g[1]), lon * sign(g[3])) else { return nil }
        return ACARSPositionReport(point: p, altitudeFt: g[5] == "GRD" || g[5] == "***" ? 0 : altitude(g[5]), timeUTC: clock(g[6]), format: "12 N")
    }

    private static let l12PosRx = Rx(#"^POS([NS])\s*(\d{6})([EW])\s*(\d{6,7}),"#)

    /// `POSN 390104W 754601,…`: Grad, Minuten, Sekunden
    static func label12Pos(_ text: String) -> ACARSPositionReport? {
        guard let g = l12PosRx.match(text), let lat = degreesMinutesSeconds(g[2]), let lon = degreesMinutesSeconds(g[4]),
              let p = point(lat * sign(g[1]), lon * sign(g[3])) else { return nil }
        return ACARSPositionReport(point: p, format: "12 POS")
    }

    // MARK: Label 15 und 16 (Klammerformat)

    private static let l15Rx = Rx(#"^\(2(?:[A-Z]{4})?([NS])(\d{5})([EW])([ 0-9]\d{5})"#)

    /// `(2N38448W 77216--- 28 20  7(Z`: Grad und Minuten mit Zehntel
    static func label15(_ text: String) -> ACARSPositionReport? {
        guard let g = l15Rx.match(text), let lat = degreesMinutesTenths(g[2]), let lon = degreesMinutesTenths(g[4]),
              let p = point(lat * sign(g[1]), lon * sign(g[3])) else { return nil }
        return ACARSPositionReport(point: p, format: "15")
    }

    // MARK: Label 16

    private static let l16NRx = Rx(#"^([NS])\s(\d+\.\d+),([EW])\s*(\d+\.\d+),(\d+|GRD|\*\*\*)?"#)
    private static let l16NSlashRx = Rx(#"^([NS])\s(\d+\.\d+)/([EW])\s*(\d+\.\d+)$"#)

    /// `N 44.203,W 86.546,31965,6, 290` und `N 28.177/W 96.055`
    static func label16NSpace(_ text: String) -> ACARSPositionReport? {
        if let g = l16NRx.match(text), let lat = number(g[2]), let lon = number(g[4]), let p = point(lat * sign(g[1]), lon * sign(g[3])) {
            return ACARSPositionReport(point: p, altitudeFt: g[5] == "GRD" || g[5] == "***" ? 0 : altitude(g[5]), format: "16 N")
        }
        if let g = l16NSlashRx.match(text.trimmingCharacters(in: .whitespacesAndNewlines)), let lat = number(g[2]), let lon = number(g[4]),
           let p = point(lat * sign(g[1]), lon * sign(g[3])) {
            return ACARSPositionReport(point: p, format: "16 N")
        }
        return nil
    }

    private static let l16PosA1Rx = Rx(#"^POSA1([NS])(\d{5})([EW])([ 0-9]\d{5}),([^,]*),(\d{6}),(\d{2,3})"#)

    /// `POSA1N37358W 77279,GEARS  ,221626,370,BBOBO  ,222053,…`: Dezimalgrad (Tausendstel)
    static func label16POSA1(_ text: String) -> ACARSPositionReport? {
        guard let g = l16PosA1Rx.match(text), let lat = number(g[2]), let lon = number(g[4]),
              let p = point(lat / 1000 * sign(g[1]), lon / 1000 * sign(g[3])) else { return nil }
        return ACARSPositionReport(point: p, altitudeFt: flightLevel(g[7]), timeUTC: clock(g[6]), format: "16 POSA1")
    }

    private static let l16AutPosRx = Rx(#"^\d{6}/AUTPOS/LLD ([NS])(\d{2})(\d{2})(\d{2}) ([EW])(\d{3})(\d{2})(\d{2})\s*\n/ALT (\d+)"#)

    /// `283806/AUTPOS/LLD N400547 W0774954` mit Zeilenumbruch und `/ALT 12932`
    static func label16AUTPOS(_ text: String) -> ACARSPositionReport? {
        guard let g = l16AutPosRx.match(text), let la = Double(g[2]), let lam = Double(g[3]), let las = Double(g[4]),
              let lo = Double(g[6]), let lom = Double(g[7]), let los = Double(g[8]),
              let p = point((la + lam / 60 + las / 3600) * sign(g[1]), (lo + lom / 60 + los / 3600) * sign(g[5])) else { return nil }
        return ACARSPositionReport(point: p, altitudeFt: altitude(g[9]), format: "16 AUTPOS")
    }

    private static let l16TodRx = Rx(#"^(\d{6}),(\d*),(\d{4,6})?,\s*\d*,([NS])\s*(\d+\.\d+)\s+([EW])\s*(\d+\.\d+)"#)
    private static let l16TodDMRx = Rx(#"^(\d{6}),(\d*),(\d{4,6})?,\s*\d*,([NS])(\d{4}\.\d+)\s+([EW])(\d{5}\.\d+)"#)

    /// `005236,36787,0135,  97,N 38.364 W 75.226` (Dezimalgrad) und `…,N3835.95 W07858.88` (Grad und Dezimalminuten)
    static func label16TOD(_ text: String) -> ACARSPositionReport? {
        if let g = l16TodRx.match(text), let lat = number(g[5]), let lon = number(g[7]), let p = point(lat * sign(g[4]), lon * sign(g[6])) {
            return ACARSPositionReport(point: p, altitudeFt: altitude(g[2]), timeUTC: clock(g[1]), format: "16 TOD")
        }
        if let g = l16TodDMRx.match(text), let lat = degreesDecimalMinutes(g[5]), let lon = degreesDecimalMinutes(g[7]),
           let p = point(lat * sign(g[4]), lon * sign(g[6])) {
            return ACARSPositionReport(point: p, altitudeFt: altitude(g[2]), timeUTC: clock(g[1]), format: "16 TOD")
        }
        return nil
    }

    // MARK: Label 20, 21, 22, 24

    private static let l20Rx = Rx(#"^POS([NS])(\d{5})([EW])(\d{6})((?:,[^,]*){0,12})"#)

    /// `POSN38160W077075,,211733,360,OTT,212041,…`: nach der Referenz Dezimalgrad (Tausendstel), anders als in H1
    static func label20(_ text: String) -> ACARSPositionReport? {
        guard let g = l20Rx.match(text), let (lat, lon) = tenthsOrThousandths(lat: g[2], lon: g[4], preferDecimal: true),
              let p = point(lat * sign(g[1]), lon * sign(g[3])) else { return nil }
        let f = g[5].split(separator: ",", omittingEmptySubsequences: false).dropFirst().map(String.init)
        return ACARSPositionReport(point: p, altitudeFt: f.count > 2 ? flightLevel(f[2]) : nil, timeUTC: f.count > 1 ? clock(f[1]) : nil, format: "20 POS")
    }

    private static let l21Rx = Rx(#"^POS([NS])\s*(\d+\.\d+)([EW])\s*(\d+\.\d+),\s*\d*,(\d{6}),(\d+)"#)

    /// `POSN 39.841W 75.790, 220,184218,17222,…`
    static func label21(_ text: String) -> ACARSPositionReport? {
        guard let g = l21Rx.match(text), let lat = number(g[2]), let lon = number(g[4]), let p = point(lat * sign(g[1]), lon * sign(g[3])) else { return nil }
        return ACARSPositionReport(point: p, altitudeFt: altitude(g[6]), timeUTC: clock(g[5]), format: "21 POS")
    }

    private static let l22Rx = Rx(#"^([NS])\s*(\d{6})([EW])\s*(\d{6,7}),[^,]*,(\d{6}),(\d+)"#)

    /// `N 370824W 760010,-------,194936,30418, …`: Dezimalgrad in Zehntausendstel
    static func label22(_ text: String) -> ACARSPositionReport? {
        guard let g = l22Rx.match(text), let lat = number(g[2]), let lon = number(g[4]),
              let p = point(lat / 10_000 * sign(g[1]), lon / 10_000 * sign(g[3])) else { return nil }
        return ACARSPositionReport(point: p, altitudeFt: altitude(g[6]), timeUTC: clock(g[5]), format: "22")
    }

    private static let l24Rx = Rx(#"^/\d{6}/\d{4}/[^/]*/(\d+)/([NS])(\d+\.\d+)/([EW])(\d+\.\d+)/"#)

    /// `/241710/1021/04WM/34962/N53.13/E001.33/3374/1056/`
    static func label24(_ text: String) -> ACARSPositionReport? {
        guard let g = l24Rx.match(text), let lat = number(g[3]), let lon = number(g[5]), let p = point(lat * sign(g[2]), lon * sign(g[4])) else { return nil }
        return ACARSPositionReport(point: p, altitudeFt: altitude(g[1]), format: "24 /")
    }

    // MARK: Label 44, 58, 2P

    private static let l44Rx = Rx(#"^(?:00)?POS0[123],([NS])(\d{5})([EW])(\d{6}),(GRD|\*\*\*|\d+),([A-Z]{4}),([A-Z]{4}),(\d{4}),(\d{4})"#)

    /// `POS02,N38171W077507,319,KJFK,KUZA,0926,0245,0327,004.6`: Grad und Minuten mit Zehntel, Flugfläche, Start, Ziel
    static func label44(_ text: String) -> ACARSPositionReport? {
        guard let g = l44Rx.match(text), let lat = degreesMinutesTenths(g[2]), let lon = degreesMinutesTenths(g[4]),
              let p = point(lat * sign(g[1]), lon * sign(g[3])) else { return nil }
        return ACARSPositionReport(point: p, altitudeFt: g[5] == "GRD" || g[5] == "***" ? 0 : flightLevel(g[5]), timeUTC: clock(g[9]),
                                   from: airport(g[6]), to: airport(g[7]), format: "44 POS")
    }

    private static let l58Rx = Rx(#"^OG\d{4}/\d{2}/(\d{6})/([NS])(\d+\.\d+)/([EW])(\d+\.\d+)/(\d+)/"#)

    /// `OG0704/06/230942/N39.214/W76.106/22683/N/`
    static func label58(_ text: String) -> ACARSPositionReport? {
        guard let g = l58Rx.match(text), let lat = number(g[3]), let lon = number(g[5]), let p = point(lat * sign(g[2]), lon * sign(g[4])) else { return nil }
        return ACARSPositionReport(point: p, altitudeFt: altitude(g[6]), timeUTC: clock(g[1]), format: "58")
    }

    private static let l2PRx = Rx(#"FM[345] (\d{4,6}),(\d{4,6}),\s*([^,]+),\s*([^,]+),\s*(\d+)"#)

    /// `FM3 1217,1312,+ 43.77,- 70.18, 39981, 426, 25` und `FM3 133818,1607,N 45.206,E 17.726,34030, …` (auch nach `M40AEY093C`);
    /// Positionsmeldungen `M80AMC4086POS/ID…/PSN56012W013273,…` laufen über ARINC 702
    static func label2PFM(_ text: String) -> ACARSPositionReport? {
        guard let g = l2PRx.match(text) else { return nil }
        let a = g[3].replacingOccurrences(of: " ", with: ""), b = g[4].replacingOccurrences(of: " ", with: "")
        var lat: Double?, lon: Double?
        if let h = a.first, h == "N" || h == "S", let k = b.first, k == "E" || k == "W" {
            lat = number(String(a.dropFirst())).map { $0 * sign(String(h)) }
            lon = number(String(b.dropFirst())).map { $0 * sign(String(k)) }
        } else {
            lat = number(a)
            lon = number(b)
        }
        guard let p = point(lat, lon) else { return nil }
        return ACARSPositionReport(point: p, altitudeFt: altitude(g[5]), timeUTC: clock(g[1]), format: "2P FM")
    }

    // MARK: Label 80 und 83 (Fluggesellschaften)

    private static let l80PosRx = Rx(#"POS\s+([NS])\s*([0-9.]+)\s*,?\s*([EW])\s*([0-9.]+)"#)
    private static let l80PosHeadRx = Rx(#"/([NS])\s*([0-9.]+)\s*,\s*([EW])\s*([0-9.]+),"#)

    /// `3N01 POSRPT …\n/POS N29395W095133/ALT +15608/…`, `/POS N3950.1 W07548.3/ALT 38007`, `/POS N3539.2W07937.2/FL 360`
    static func label80(_ text: String) -> ACARSPositionReport? {
        let g = l80PosRx.match(text) ?? (text.contains("POSRPT") ? l80PosHeadRx.match(text) : nil)
        guard let g else { return nil }
        let la = g[2], lo = g[4]
        var lat: Double?, lon: Double?
        if la.contains(".") || lo.contains(".") {
            // N3950.1 W07548.3: Grad und Dezimalminuten
            lat = degreesDecimalMinutes(la)
            lon = degreesDecimalMinutes(lo)
        } else if let (a, b) = tenthsOrThousandths(lat: la, lon: lo, preferDecimal: true) {
            lat = a
            lon = b
        }
        guard let p = point(lat.map { $0 * sign(g[1]) }, lon.map { $0 * sign(g[3]) }) else { return nil }
        var r = ACARSPositionReport(point: p, format: "80 POS")
        if let m = Rx(#"/ALT\s+\+?(\d+)"#).match(text) { r.altitudeFt = altitude(m[1]) }
        else if let m = Rx(#"/FL\s+(\d+)"#).match(text) { r.altitudeFt = flightLevel(m[1]) }
        if let m = Rx(#"/UTC\s+(\d{6})"#).match(text) { r.timeUTC = clock(m[1]) }
        if let m = Rx(#"/HDG\s+(\d{1,3})"#).match(text), let h = number(m[1]), h <= 360 { r.headingDeg = h }
        if let m = Rx(#"POSRPT\s+\d+/\d+\s+([A-Z]{4})/([A-Z]{4})"#).match(text) { r.from = m[1]; r.to = m[2] }
        return r
    }

    private static let l83V1Rx = Rx(#"^([A-Z]{4}),([A-Z]{4}),(\d{6}),\s*(-?\s*\d+\.\d+),\s*(-?\s*\d+\.\d+),\s*(\d+),\s*(\d+),\s*(\d+\.?\d*)"#)
    private static let l83V3Rx = Rx(#"^001PR(\d{2})(\d{6})([NS])(\d{4}\.\d)([EW])(\d{5}\.\d)(\d{5})"#)

    /// `KLAX,KEWR,220103, 40.53,- 74.47, 3836,212, 140.0, 19700` und `001PR22035539N4038.6W07427.80292500008`
    static func label83(_ text: String) -> ACARSPositionReport? {
        let t = text.replacingOccurrences(of: "\n", with: "")
        if let g = l83V1Rx.match(t), let lat = number(g[4].replacingOccurrences(of: " ", with: "")),
           let lon = number(g[5].replacingOccurrences(of: " ", with: "")), let p = point(lat, lon) {
            return ACARSPositionReport(point: p, altitudeFt: altitude(g[6]), timeUTC: clock(String(g[3].suffix(4))),
                                       headingDeg: number(g[8]).flatMap { $0 <= 360 ? $0 : nil }, from: airport(g[1]), to: airport(g[2]), format: "83")
        }
        if let g = l83V3Rx.match(t), let lat = degreesDecimalMinutes(g[4]), let lon = degreesDecimalMinutes(g[6]),
           let p = point(lat * sign(g[3]), lon * sign(g[5])) {
            return ACARSPositionReport(point: p, altitudeFt: altitude(g[7]), timeUTC: clock(g[2]), format: "83 PR")
        }
        return nil
    }

    // MARK: Label 1L, HX, 4T

    private static let l1L070Rx = Rx(#"^000000070([A-Z]{4}),([A-Z]{4}),(\d{4}),(\d{4}),([NS])\s*(\d+\.\d+),([EW])\s*(\d+\.\d+)"#)

    /// `000000070LOWW,KEWR,0932,1744,N 49.223,E 12.038,0659`
    static func label1L070(_ text: String) -> ACARSPositionReport? {
        guard let g = l1L070Rx.match(text), let lat = number(g[6]), let lon = number(g[8]), let p = point(lat * sign(g[5]), lon * sign(g[7])) else { return nil }
        return ACARSPositionReport(point: p, timeUTC: clock(g[3]), from: airport(g[1]), to: airport(g[2]), format: "1L 070")
    }

    private static let l1L660Rx = Rx(#"^000000660([NS])(\d{5})([EW])(\d{6}),(\d{6})(\d{3})"#)

    /// `000000660N50442E005566,100444359SOG-06 ,…`: Grad und Minuten mit Zehntel, Zeit, Flugfläche
    static func label1L660(_ text: String) -> ACARSPositionReport? {
        guard let g = l1L660Rx.match(text), let lat = degreesMinutesTenths(g[2]), let lon = degreesMinutesTenths(g[4]),
              let p = point(lat * sign(g[1]), lon * sign(g[3])) else { return nil }
        return ACARSPositionReport(point: p, altitudeFt: flightLevel(g[6]), timeUTC: clock(g[5]), format: "1L 660")
    }

    private static let l1LSlashRx = Rx(#"^([+-])\s*(\d+\.\d+)/([+-])\s*(\d+\.\d+)/(?:UTC (\d{6}))?"#)

    /// `+ 39.126/- 77.358/UTC 085208/FOB 8.2/ALT 3997/CAS 239/ETA 0903`
    static func label1LSlash(_ text: String) -> ACARSPositionReport? {
        guard let g = l1LSlashRx.match(text), let lat = number(g[2]), let lon = number(g[4]),
              let p = point(g[1] == "-" ? -lat : lat, g[3] == "-" ? -lon : lon) else { return nil }
        var r = ACARSPositionReport(point: p, timeUTC: clock(g[5]), format: "1L /")
        if let m = Rx(#"/ALT\s+(\d+)"#).match(text) { r.altitudeFt = altitude(m[1]) }
        return r
    }

    private static let l1L3LineRx = Rx(#"LON ([EW]) (\d+\.\d+)/LAT ([NS]) (\d+\.\d+)"#)

    /// `00018213200/GS 411500/DEP MDPC/DES CYYZ/…\nLON W 78.289/LAT N 39.556/WD  20/WS  13`
    static func label1L3Line(_ text: String) -> ACARSPositionReport? {
        guard let g = l1L3LineRx.match(text), let lon = number(g[2]), let lat = number(g[4]), let p = point(lat * sign(g[3]), lon * sign(g[1])) else { return nil }
        var r = ACARSPositionReport(point: p, format: "1L 3")
        if let m = Rx(#"/ALT (\d+)"#).match(text) { r.altitudeFt = altitude(m[1]) }
        if let m = Rx(#"/UTC (\d{6})"#).match(text) { r.timeUTC = clock(m[1]) }
        if let m = Rx(#"/DEP ([A-Z]{4})/DES ([A-Z]{4})"#).match(text) { r.from = m[1]; r.to = m[2] }
        return r
    }

    private static let hxRx = Rx(#"^RA FMT LOCATION ([NS])(\d{4}\.\d) ([EW])(\d{5}\.\d)"#)

    /// `RA FMT LOCATION N4009.6 W07540.8`
    static func labelHX(_ text: String) -> ACARSPositionReport? {
        guard let g = hxRx.match(text), let lat = degreesDecimalMinutes(g[2]), let lon = degreesDecimalMinutes(g[4]),
              let p = point(lat * sign(g[1]), lon * sign(g[3])) else { return nil }
        return ACARSPositionReport(point: p, format: "HX")
    }

    private static let l4TRx = Rx(#"^AGFSR [^/]*/\d+/\d+/[A-Z]{6}/(\d{4})Z/[^/]*/(\d{4}\.\d)([NS])(\d{5}\.\d)([EW])/(\d+)"#)

    /// `AGFSR AC0620/07/08/YYZYHZ/0340Z/453/4435.1N07143.4W/350/ …`
    static func label4TAGFSR(_ text: String) -> ACARSPositionReport? {
        guard let g = l4TRx.match(text), let lat = degreesDecimalMinutes(g[2]), let lon = degreesDecimalMinutes(g[4]),
              let p = point(lat * sign(g[3]), lon * sign(g[5])) else { return nil }
        return ACARSPositionReport(point: p, altitudeFt: flightLevel(g[6]), timeUTC: clock(g[1]), format: "4T AGFSR")
    }
}
