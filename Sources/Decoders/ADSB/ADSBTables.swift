// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Staat nach dem ICAO-24-Bit-Adressblock eines Flugzeugs
public struct ICAOCountry: Equatable, Sendable {
    /// ISO-3166-Kennung („DE“)
    public var code: String
    public var name: String
    /// Flagge als Emoji
    public var flag: String
}

/// Zuordnung der ICAO-24-Bit-Adresse zu einem Staat nach `Resources/ADSB/icao_ranges.csv`
public final class ICAORanges: @unchecked Sendable {
    public static let shared = ICAORanges()

    private struct Range { var start: UInt32; var end: UInt32; var code: String; var english: String }
    private var ranges: [Range]?
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    static var directory: URL? {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("ADSB"),
           FileManager.default.fileExists(atPath: res.appendingPathComponent("icao_ranges.csv").path) { return res }
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ADSB")
        return FileManager.default.fileExists(atPath: project.appendingPathComponent("icao_ranges.csv").path) ? project : nil
    }

    private static func load() -> [Range] {
        guard let dir = directory, let text = try? String(contentsOf: dir.appendingPathComponent("icao_ranges.csv"), encoding: .utf8) else { return [] }
        var out: [Range] = []
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let f = line.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
            guard f.count == 4, let s = UInt32(f[0], radix: 16), let e = UInt32(f[1], radix: 16) else { continue }
            out.append(Range(start: s, end: e, code: String(f[2]), english: String(f[3])))
        }
        return out
    }

    public var count: Int { lock.withLock { if ranges == nil { ranges = Self.load() }; return ranges?.count ?? 0 } }

    /// Staat zu einer Adresse; nil bei nicht vergebenen Blöcken und Sonderblöcken ohne Staat
    public func country(_ icao: UInt32) -> ICAOCountry? {
        lock.withLock {
            if ranges == nil { ranges = Self.load() }
            guard let r = ranges?.first(where: { icao >= $0.start && icao <= $0.end }), r.code.count == 2 else { return nil }
            let name = Locale(identifier: "de_DE").localizedString(forRegionCode: r.code) ?? r.english
            return ICAOCountry(code: r.code, name: name, flag: Self.flag(r.code))
        }
    }

    /// Flaggen-Emoji aus der Länderkennung
    public static func flag(_ code: String) -> String {
        var s = ""
        for u in code.uppercased().unicodeScalars where u.value >= 65 && u.value <= 90 {
            if let f = UnicodeScalar(0x1F1E6 + u.value - 65) { s.unicodeScalars.append(f) }
        }
        return s
    }
}

public enum ADSBNames {
    /// Flugzeugart nach Typkennung (1–4) und Kategorie (0–7) der Kennungsmeldung
    public static func category(typeCode: Int?, category: Int?) -> String? {
        guard let tc = typeCode, let c = category, c != 0 else { return nil }
        switch (tc, c) {
        case (4, 1): return "Leicht (< 7 t)"
        case (4, 2): return "Klein (7–34 t)"
        case (4, 3): return "Groß (34–136 t)"
        case (4, 4): return "Groß mit starkem Wirbel (B757)"
        case (4, 5): return "Schwer (> 136 t)"
        case (4, 6): return "Hohe Leistung (> 5 g, > 400 kn)"
        case (4, 7): return "Drehflügler"
        case (3, 1): return "Segelflugzeug"
        case (3, 2): return "Leichter als Luft"
        case (3, 3): return "Fallschirmspringer"
        case (3, 4): return "Ultraleicht, Gleitschirm"
        case (3, 6): return "Drohne"
        case (3, 7): return "Raumfahrzeug"
        case (2, 1): return "Rettungsfahrzeug am Boden"
        case (2, 2): return "Servicefahrzeug am Boden"
        case (2, 3): return "Hindernis (Punkt)"
        case (2, 4): return "Hindernis (Gruppe)"
        case (2, 5): return "Hindernis (Linie)"
        default: return nil
        }
    }

    /// Notlage nach Statusmeldung (Typ 28) oder Kennung
    public static func emergency(_ code: Int?, squawk: String?) -> String? {
        switch code ?? 0 {
        case 1: return "Allgemeiner Notfall"
        case 2: return "Medizinischer Notfall"
        case 3: return "Wenig Kraftstoff"
        case 4: return "Funkausfall"
        case 5: return "Widerrechtlicher Eingriff"
        case 6: return "Abgestürzt"
        default: break
        }
        switch squawk {
        case "7700": return "Notfall (Kennung 7700)"
        case "7600": return "Funkausfall (Kennung 7600)"
        case "7500": return "Widerrechtlicher Eingriff (Kennung 7500)"
        default: return nil
        }
    }
}
