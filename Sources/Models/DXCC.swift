// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Ein DXCC-Gebiet (Land, Insel oder Sondergebiet nach ARRL DXCC-Liste / AD1C Country Files)
public struct DXCCEntity: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { primaryPrefix }

    /// Offizieller Gebietsname (z. B. "Fed. Rep. of Germany", "United States", "Crete", "Antarctica")
    public let name: String
    /// Primäres Präfix laut AD1C cty.dat (z. B. "DL", "K", "SV9", "CE9")
    public let primaryPrefix: String
    /// Kontinentcode (EU, AS, AF, NA, SA, OC, AN)
    public let continent: String
    /// CQ-Zone (1 ... 40)
    public let cqZone: Int
    /// ITU-Zone (1 ... 90)
    public let ituZone: Int
    /// Geographische Breite (Grad, positiv = Nord, negativ = Süd)
    public let latitude: Double
    /// Geographische Länge (Grad, positiv = Ost, negativ = West nach WGS84)
    public let longitude: Double
    /// UTC-Zeitzonenabweichung in Stunden (z. B. +1.0 für MEZ)
    public let utcOffset: Double
    /// Flaggen-Emoji oder Territoriums-Symbol (z. B. "🇩🇪", "🇺🇸", "🇯🇵", "🇦🇶")
    public let flag: String

    public init(
        name: String,
        primaryPrefix: String,
        continent: String,
        cqZone: Int,
        ituZone: Int,
        latitude: Double,
        longitude: Double,
        utcOffset: Double,
        flag: String
    ) {
        self.name = name
        self.primaryPrefix = primaryPrefix
        self.continent = continent
        self.cqZone = cqZone
        self.ituZone = ituZone
        self.latitude = latitude
        self.longitude = longitude
        self.utcOffset = utcOffset
        self.flag = flag
    }

    /// Kurzbeschreibung für Tooltips und Statuszeilen: „🇩🇪 Fed. Rep. of Germany (EU) · CQ 14 · ITU 28“
    public var summary: String {
        "\(flag) \(name) (\(continent)) · CQ \(cqZone) · ITU \(ituZone)"
    }

    /// Koordinaten im Amateurfunkformat (z. B. „51.00°N, 10.00°E“)
    public var coordinateSummary: String {
        String(format: "%.2f°%@, %.2f°%@",
               abs(latitude), latitude >= 0 ? "N" : "S",
               abs(longitude), longitude >= 0 ? "E" : "W")
    }
}

/// Schnelle DXCC-Zuordnung von Rufzeichen und Präfixen auf Basis der AD1C cty.dat.
/// Vollständig thread-safe und unveränderlich nach dem Laden.
public final class DXCCDatabase: @unchecked Sendable {
    public static let shared = DXCCDatabase()

    private let exactMap: [String: DXCCEntity]
    private let prefixMap: [String: DXCCEntity]

    /// Standardpfad zu `Resources/cty.dat` (im Bundle oder Quellbaum)
    public static var defaultDatabaseURL: URL? {
        if let bundleURL = Bundle.main.url(forResource: "cty", withExtension: "dat") {
            return bundleURL
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("cty.dat"),
           FileManager.default.fileExists(atPath: res.path) {
            return res
        }
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/cty.dat")
        if FileManager.default.fileExists(atPath: projectURL.path) {
            return projectURL
        }
        return nil
    }

    public init(fileURL: URL? = defaultDatabaseURL) {
        var exacts: [String: DXCCEntity] = [:]
        var prefixes: [String: DXCCEntity] = [:]

        if let url = fileURL, let content = try? String(contentsOf: url, encoding: .utf8) {
            Self.parse(content: content, intoExacts: &exacts, intoPrefixes: &prefixes)
        }

        self.exactMap = exacts
        self.prefixMap = prefixes
    }

    /// Anzahl der erfassten Ausnahmerufzeichen
    public var exactCount: Int { exactMap.count }
    /// Anzahl der erfassten Präfixe
    public var prefixCount: Int { prefixMap.count }

    /// Ermittelt das DXCC-Gebiet für ein Rufzeichen.
    /// Berücksichtigt:
    /// - Exakte Sonderrufzeichen (z. B. `=DP0GVN` für Neumayer III / Antarktis)
    /// - Portabel-Zusätze (`/P`, `/M`, `/MM`, `/AM`, `/QRP`, `/R`, `/0`...`/9` etc.)
    /// - Gastland-Präfixe (`SV9/DL1ABC` -> Kreta)
    /// - Gastland-Suffixe (`W1AW/KH6` -> Hawaii)
    /// - Längstes passendes Präfix (Longest Prefix Match)
    /// - CQ- und ITU-Zonenüberschreibungen
    public func lookup(_ rawCallsign: String) -> DXCCEntity? {
        var c = rawCallsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if c.hasPrefix("<") && c.hasSuffix(">") {
            c = String(c.dropFirst().dropLast())
        }
        guard !c.isEmpty else { return nil }

        // Bekannte Nicht-Rufzeichen ignorieren
        if Self.ignoredTokens.contains(c) { return nil }

        // 1. Exakter Treffer auf dem vollen Rufzeichen
        if let exact = exactMap[c] { return exact }

        // 2. Zerlegung bei Schrägstrich
        let parts = c.split(separator: "/").map(String.init)
        if parts.count == 1 {
            return rawLookup(c)
        }

        // Portabel- und Betriebsarten-Zusätze herausfiltern
        let filtered = parts.filter { p in
            !Self.operatingModifiers.contains(p) && !(p.count == 1 && p.first?.isNumber == true)
        }

        if filtered.isEmpty { return rawLookup(parts[0]) }
        if filtered.count == 1 { return rawLookup(filtered[0]) }

        let p0 = filtered[0]
        let p1 = filtered[1]

        // Falls ein Teil ein exakter cty.dat-Treffer ist
        if let e0 = exactMap[p0] { return e0 }
        if let e1 = exactMap[p1] { return e1 }

        let r0 = rawLookup(p0)
        let r1 = rawLookup(p1)

        // Wenn ein Teil kürzer ist und ein gültiges DXCC-Gebiet beschreibt,
        // ist es das Gastland-Präfix oder -Suffix (z. B. SV9/DL1ABC -> SV9, W1AW/KH6 -> KH6)
        if p0.count < p1.count, let r0 { return r0 }
        if p1.count < p0.count, let r1 { return r1 }

        return r0 ?? r1
    }

    /// Längstes passendes Präfix (Longest Prefix Match)
    private func rawLookup(_ call: String) -> DXCCEntity? {
        if let exact = exactMap[call] { return exact }

        // KG4 Sonderfall: 2x3 (len 6) und 2x1 (len 4) sind US-Festland (K4), nur 2x2 (len 5) ist Guantanamo
        var effective = call
        if effective.hasPrefix("KG4") && (effective.count == 4 || effective.count == 6) {
            effective = "K" + effective.dropFirst(3)
        }

        for len in stride(from: effective.count, through: 1, by: -1) {
            let prefix = String(effective.prefix(len))
            if let match = prefixMap[prefix] {
                return match
            }
        }
        return nil
    }

    // MARK: - Parser für cty.dat

    private static func parse(
        content: String,
        intoExacts exacts: inout [String: DXCCEntity],
        intoPrefixes prefixes: inout [String: DXCCEntity]
    ) {
        for record in content.split(separator: ";") {
            let lines = record.split(whereSeparator: \.isNewline)
            guard let headerLine = lines.first else { continue }
            let headerFields = headerLine.split(separator: ":", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard headerFields.count >= 8 else { continue }

            let name = headerFields[0]
            let cq = Int(headerFields[1]) ?? 0
            let itu = Int(headerFields[2]) ?? 0
            let continent = headerFields[3]
            let lat = Double(headerFields[4]) ?? 0.0
            // cty.dat-Konvention: West ist positiv, Ost ist negativ -> für WGS84 invertieren
            let lon = -(Double(headerFields[5]) ?? 0.0)
            // cty.dat-Konvention: Offset zu GMT negiert -> für UTC invertieren
            let utc = -(Double(headerFields[6]) ?? 0.0)
            let primaryPrefix = headerFields[7]
            let flag = flagForPrefix(primaryPrefix)

            let base = DXCCEntity(
                name: name,
                primaryPrefix: primaryPrefix,
                continent: continent,
                cqZone: cq,
                ituZone: itu,
                latitude: lat,
                longitude: lon,
                utcOffset: utc,
                flag: flag
            )

            for line in lines.dropFirst() {
                for token in line.split(separator: ",") {
                    let t = token.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { continue }

                    let isExact = t.hasPrefix("=")
                    var raw = isExact ? String(t.dropFirst()) : String(t)

                    var cqOverride = cq
                    var ituOverride = itu

                    // CQ-Zonen-Überschreibung: (nn)
                    if let openP = raw.firstIndex(of: "("), let closeP = raw.firstIndex(of: ")"), openP < closeP {
                        let cqStr = raw[raw.index(after: openP)..<closeP]
                        if let v = Int(cqStr) { cqOverride = v }
                        raw.removeSubrange(openP...closeP)
                    }
                    // ITU-Zonen-Überschreibung: [nn]
                    if let openB = raw.firstIndex(of: "["), let closeB = raw.firstIndex(of: "]"), openB < closeB {
                        let ituStr = raw[raw.index(after: openB)..<closeB]
                        if let v = Int(ituStr) { ituOverride = v }
                        raw.removeSubrange(openB...closeB)
                    }

                    let entity: DXCCEntity
                    if cqOverride == cq && ituOverride == itu {
                        entity = base
                    } else {
                        entity = DXCCEntity(
                            name: name,
                            primaryPrefix: primaryPrefix,
                            continent: continent,
                            cqZone: cqOverride,
                            ituZone: ituOverride,
                            latitude: lat,
                            longitude: lon,
                            utcOffset: utc,
                            flag: flag
                        )
                    }

                    if isExact {
                        exacts[raw] = entity
                    } else {
                        prefixes[raw] = entity
                    }
                }
            }
        }
    }

    // MARK: - Konstanten & Flaggen

    private static let ignoredTokens: Set<String> = [
        "CQ", "TEST", "QRZ", "DE", "RR73", "73", "RRR", "R2", "R3", "NA", "DX", "EU", "AS", "OC", "AF", "SA"
    ]

    private static let operatingModifiers: Set<String> = [
        "P", "M", "MM", "AM", "QRP", "R", "B", "LGT", "LH", "FF", "J", "YOTA", "AVR", "A"
    ]

    /// Liefert das passende Flaggen-Emoji für ein Primärpräfix
    public static func flagForPrefix(_ pfx: String) -> String {
        if let f = prefixFlags[pfx] { return f }
        let clean = pfx.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        if let f = prefixFlags[clean] { return f }
        return "🌐"
    }

    /// Vollständiges Flaggenverzeichnis aller 346 DXCC-Gebiete
    private static let prefixFlags: [String: String] = [
        "*4U1V": "🇺🇳",
        "*GM/s": "🏴󠁧󠁢󠁳󠁣󠁴󠁿",
        "*IG9": "🇮🇹",
        "*IT9": "🇮🇹",
        "*JW/b": "🇸🇯",
        "*TA1": "🇹🇷",
        "1A": "🇲🇹",
        "1S": "🌐",
        "3A": "🇲🇨",
        "3B6": "🇲🇺",
        "3B8": "🇲🇺",
        "3B9": "🇲🇺",
        "3C": "🇬🇶",
        "3C0": "🇬🇶",
        "3D2": "🇫🇯",
        "3D2/c": "🇫🇯",
        "3D2/r": "🇫🇯",
        "3DA": "🇸🇿",
        "3V": "🇹🇳",
        "3W": "🇻🇳",
        "3X": "🇬🇳",
        "3Y/b": "🇳🇴",
        "3Y/p": "🇳🇴",
        "4J": "🇦🇿",
        "4L": "🇬🇪",
        "4O": "🇲🇪",
        "4S": "🇱🇰",
        "4U1I": "🇺🇳",
        "4U1U": "🇺🇳",
        "4W": "🇹🇱",
        "4X": "🇮🇱",
        "5A": "🇱🇾",
        "5B": "🇨🇾",
        "5H": "🇹🇿",
        "5N": "🇳🇬",
        "5R": "🇲🇬",
        "5T": "🇲🇷",
        "5U": "🇳🇪",
        "5V": "🇹🇬",
        "5W": "🇼🇸",
        "5X": "🇺🇬",
        "5Z": "🇰🇪",
        "6W": "🇸🇳",
        "6Y": "🇯🇲",
        "7O": "🇾🇪",
        "7P": "🇱🇸",
        "7Q": "🇲🇼",
        "7X": "🇩🇿",
        "8P": "🇧🇧",
        "8Q": "🇲🇻",
        "8R": "🇬🇾",
        "9A": "🇭🇷",
        "9G": "🇬🇭",
        "9H": "🇲🇹",
        "9J": "🇿🇲",
        "9K": "🇰🇼",
        "9L": "🇸🇱",
        "9M2": "🇲🇾",
        "9M6": "🇲🇾",
        "9N": "🇳🇵",
        "9Q": "🇨🇩",
        "9U": "🇧🇮",
        "9V": "🇸🇬",
        "9X": "🇷🇼",
        "9Y": "🇹🇹",
        "A2": "🇧🇼",
        "A3": "🇹🇴",
        "A4": "🇴🇲",
        "A5": "🇧🇹",
        "A6": "🇦🇪",
        "A7": "🇶🇦",
        "A9": "🇧🇭",
        "AP": "🇵🇰",
        "BS7": "🇨🇳",
        "BV": "🇹🇼",
        "BV9P": "🇹🇼",
        "BY": "🇨🇳",
        "C2": "🇳🇷",
        "C3": "🇦🇩",
        "C5": "🇬🇲",
        "C6": "🇧🇸",
        "C9": "🇲🇿",
        "CE": "🇨🇱",
        "CE0X": "🇨🇱",
        "CE0Y": "🇨🇱",
        "CE0Z": "🇨🇱",
        "CE9": "🇦🇶",
        "CM": "🇨🇺",
        "CN": "🇲🇦",
        "CP": "🇧🇴",
        "CT": "🇵🇹",
        "CT3": "🇵🇹",
        "CU": "🇵🇹",
        "CX": "🇺🇾",
        "CY0": "🇨🇦",
        "CY9": "🇨🇦",
        "D2": "🇦🇴",
        "D4": "🇨🇻",
        "D6": "🇰🇲",
        "DL": "🇩🇪",
        "DU": "🇵🇭",
        "E3": "🇪🇷",
        "E4": "🇵🇸",
        "E5/n": "🇨🇰",
        "E5/s": "🇨🇰",
        "E6": "🇳🇺",
        "E7": "🇧🇦",
        "EA": "🇪🇸",
        "EA6": "🇪🇸",
        "EA8": "🇮🇨",
        "EA9": "🇪🇦",
        "EI": "🇮🇪",
        "EK": "🇦🇲",
        "EL": "🇱🇷",
        "EP": "🇮🇷",
        "ER": "🇲🇩",
        "ES": "🇪🇪",
        "ET": "🇪🇹",
        "EU": "🇧🇾",
        "EX": "🇰🇬",
        "EY": "🇹🇯",
        "EZ": "🇹🇲",
        "F": "🇫🇷",
        "FG": "🇬🇵",
        "FH": "🇾🇹",
        "FJ": "🇧🇱",
        "FK": "🇳🇨",
        "FK/c": "🇳🇨",
        "FM": "🇲🇶",
        "FO": "🇵🇫",
        "FO/a": "🇵🇫",
        "FO/c": "🇵🇫",
        "FO/m": "🇵🇫",
        "FP": "🇵🇲",
        "FR": "🇷🇪",
        "FS": "🇲🇫",
        "FT/g": "🇹🇫",
        "FT/j": "🇹🇫",
        "FT/t": "🇹🇫",
        "FT/w": "🇹🇫",
        "FT/x": "🇹🇫",
        "FT/z": "🇹🇫",
        "FW": "🇼🇫",
        "FY": "🇬🇫",
        "G": "🏴󠁧󠁢󠁥󠁮󠁧󠁿",
        "GD": "🇮🇲",
        "GI": "🇬🇧",
        "GJ": "🇯🇪",
        "GM": "🏴󠁧󠁢󠁳󠁣󠁴󠁿",
        "GU": "🇬🇬",
        "GW": "🏴󠁧󠁢󠁷󠁬󠁳󠁿",
        "H4": "🇸🇧",
        "H40": "🇸🇧",
        "HA": "🇭🇺",
        "HB": "🇨🇭",
        "HB0": "🇱🇮",
        "HC": "🇪🇨",
        "HC8": "🇪🇨",
        "HH": "🇭🇹",
        "HI": "🇩🇴",
        "HK": "🇨🇴",
        "HK0/a": "🇨🇴",
        "HK0/m": "🇨🇴",
        "HL": "🇰🇷",
        "HP": "🇵🇦",
        "HR": "🇭🇳",
        "HS": "🇹🇭",
        "HV": "🇻🇦",
        "HZ": "🇸🇦",
        "I": "🇮🇹",
        "IS": "🇮🇹",
        "J2": "🇩🇯",
        "J3": "🇬🇩",
        "J5": "🇬🇼",
        "J6": "🇱🇨",
        "J7": "🇩🇲",
        "J8": "🇻🇨",
        "JA": "🇯🇵",
        "JD/m": "🇯🇵",
        "JD/o": "🇯🇵",
        "JT": "🇲🇳",
        "JW": "🇸🇯",
        "JX": "🇸🇯",
        "JY": "🇯🇴",
        "K": "🇺🇸",
        "KG4": "🇨🇺",
        "KH0": "🇲🇵",
        "KH1": "🇺🇸",
        "KH2": "🇬🇺",
        "KH3": "🇺🇸",
        "KH4": "🇺🇸",
        "KH5": "🇺🇸",
        "KH6": "🌺",
        "KH7K": "🇺🇸",
        "KH8": "🇦🇸",
        "KH8/s": "🇦🇸",
        "KH9": "🇺🇸",
        "KL": "🇺🇸",
        "KP1": "🇺🇸",
        "KP2": "🇻🇮",
        "KP4": "🇵🇷",
        "KP5": "🇺🇸",
        "LA": "🇳🇴",
        "LU": "🇦🇷",
        "LX": "🇱🇺",
        "LY": "🇱🇹",
        "LZ": "🇧🇬",
        "OA": "🇵🇪",
        "OD": "🇱🇧",
        "OE": "🇦🇹",
        "OH": "🇫🇮",
        "OH0": "🇦🇽",
        "OJ0": "🇫🇮",
        "OK": "🇨🇿",
        "OM": "🇸🇰",
        "ON": "🇧🇪",
        "OX": "🇬🇱",
        "OY": "🇫🇴",
        "OZ": "🇩🇰",
        "P2": "🇵🇬",
        "P4": "🇦🇼",
        "P5": "🇰🇵",
        "PA": "🇳🇱",
        "PJ2": "🇨🇼",
        "PJ4": "🇧🇶",
        "PJ5": "🇧🇶",
        "PJ7": "🇸🇽",
        "PY": "🇧🇷",
        "PY0F": "🇧🇷",
        "PY0S": "🇧🇷",
        "PY0T": "🇧🇷",
        "PZ": "🇸🇷",
        "R1FJ": "🇷🇺",
        "S0": "🇪🇭",
        "S2": "🇧🇩",
        "S5": "🇸🇮",
        "S7": "🇸🇨",
        "S9": "🇸🇹",
        "SM": "🇸🇪",
        "SP": "🇵🇱",
        "ST": "🇸🇩",
        "SU": "🇪🇬",
        "SV": "🇬🇷",
        "SV/a": "🇬🇷",
        "SV5": "🇬🇷",
        "SV9": "🇬🇷",
        "T2": "🇹🇻",
        "T30": "🇰🇮",
        "T31": "🇰🇮",
        "T32": "🇰🇮",
        "T33": "🇰🇮",
        "T5": "🇸🇴",
        "T7": "🇸🇲",
        "T8": "🇵🇼",
        "TA": "🇹🇷",
        "TF": "🇮🇸",
        "TG": "🇬🇹",
        "TI": "🇨🇷",
        "TI9": "🇨🇷",
        "TJ": "🇨🇲",
        "TK": "🇫🇷",
        "TL": "🇨🇫",
        "TN": "🇨🇬",
        "TR": "🇬🇦",
        "TT": "🇹🇩",
        "TU": "🇨🇮",
        "TY": "🇧🇯",
        "TZ": "🇲🇱",
        "UA": "🇷🇺",
        "UA2": "🇷🇺",
        "UA9": "🇷🇺",
        "UK": "🇺🇿",
        "UN": "🇰🇿",
        "UR": "🇺🇦",
        "V2": "🇦🇬",
        "V3": "🇧🇿",
        "V4": "🇰🇳",
        "V5": "🇳🇦",
        "V6": "🇫🇲",
        "V7": "🇲🇭",
        "V8": "🇧🇳",
        "VE": "🇨🇦",
        "VK": "🇦🇺",
        "VK0H": "🇦🇺",
        "VK0M": "🇦🇺",
        "VK9C": "🇨🇨",
        "VK9L": "🇦🇺",
        "VK9M": "🇦🇺",
        "VK9N": "🇳🇫",
        "VK9W": "🇦🇺",
        "VK9X": "🇨🇽",
        "VP2E": "🇦🇮",
        "VP2M": "🇲🇸",
        "VP2V": "🇻🇬",
        "VP5": "🇹🇨",
        "VP6": "🇵🇳",
        "VP6/d": "🇵🇳",
        "VP8": "🇫🇰",
        "VP8/g": "🇬🇸",
        "VP8/h": "🇦🇶",
        "VP8/o": "🇦🇶",
        "VP8/s": "🇬🇸",
        "VP9": "🇧🇲",
        "VQ9": "🇮🇴",
        "VR": "🇭🇰",
        "VU": "🇮🇳",
        "VU4": "🇮🇳",
        "VU7": "🇮🇳",
        "XE": "🇲🇽",
        "XF4": "🇲🇽",
        "XT": "🇧🇫",
        "XU": "🇰🇭",
        "XW": "🇱🇦",
        "XX9": "🇲🇴",
        "XZ": "🇲🇲",
        "YA": "🇦🇫",
        "YB": "🇮🇩",
        "YI": "🇮🇶",
        "YJ": "🇻🇺",
        "YK": "🇸🇾",
        "YL": "🇱🇻",
        "YN": "🇳🇮",
        "YO": "🇷🇴",
        "YS": "🇸🇻",
        "YU": "🇷🇸",
        "YV": "🇻🇪",
        "YV0": "🇻🇪",
        "Z2": "🇿🇼",
        "Z3": "🇲🇰",
        "Z6": "🇽🇰",
        "Z8": "🇸🇸",
        "ZA": "🇦🇱",
        "ZB": "🇬🇮",
        "ZC4": "🇨🇾",
        "ZD7": "🇸🇭",
        "ZD8": "🇦🇨",
        "ZD9": "🇹🇦",
        "ZF": "🇰🇾",
        "ZK3": "🇹🇰",
        "ZL": "🇳🇿",
        "ZL7": "🇳🇿",
        "ZL8": "🇳🇿",
        "ZL9": "🇳🇿",
        "ZP": "🇵🇾",
        "ZS": "🇿🇦",
        "ZS8": "🇿🇦"
    ]
}
