import Foundation

/// Eine NAVTEX-Sendestation (Kennbuchstabe B1, Frequenz, NAVAREA)
public struct NavtexStation: Identifiable, Equatable, Sendable {
    public let country: String
    public let countryCode: String
    /// 518,0 (international, Englisch), 490,0 (national), 4209,5 (Tropen)
    public let frequencyKHz: Double
    /// B1-Kennung A…X
    public let letter: Character
    public let callsign: String
    public let name: String
    public let navarea: String
    public let language: String

    /// eindeutig, z. B. „DEU-518-S-Pinneberg“
    public var id: String { "\(countryCode)-\(frequencyKHz == frequencyKHz.rounded() ? String(Int(frequencyKHz)) : String(frequencyKHz))-\(letter)-\(name)" }

    public var frequency: NavtexFrequency? {
        switch frequencyKHz {
        case 518.0: return .f518
        case 490.0: return .f490
        case 4209.5: return .f4209
        default: return nil
        }
    }

    public var frequencyLabel: String {
        (frequencyKHz == frequencyKHz.rounded() ? String(Int(frequencyKHz)) : String(frequencyKHz)).replacingOccurrences(of: ".", with: ",") + " kHz"
    }

    /// Versatz des Sendefensters im Vierstundenblock in Minuten: A = 0, B = 10 … X = 230
    public var slotOffsetMinutes: Int { min(23, max(0, Int(letter.asciiValue ?? 65) - 65)) * 10 }

    /// Beginn der sechs täglichen Sendefenster (Minuten seit 00:00 UTC)
    public var startMinutes: [Int] { (0..<6).map { $0 * 240 + slotOffsetMinutes } }

    public static let slotDurationMinutes = 10
}

/// NAVTEX-Plan: Jede Station sendet nach dem IMO-Raster in ihrem 10-Minuten-Fenster alle vier Stunden
/// (Blöcke 00, 04, 08, 12, 16, 20 UTC mit je 24 Fenstern A…X). Berechnet aus der Stationsliste; einzelne Stationen
/// weichen davon ab (z. B. Serapeum auf 4209,5 kHz). Eine Station sendet nur, wenn Meldungen vorliegen.
public struct NavtexPlan: Equatable, Sendable {
    public var stations: [NavtexStation]

    public init(stations: [NavtexStation]) { self.stations = stations }

    /// Liest `NAVTEX_Stations.csv` (fldigi): `Land;Code;kHz;B1;Rufzeichen;Station;Breite;Länge;NAVAREA;Sprache`
    public static func parse(csv: String) -> NavtexPlan {
        var list: [NavtexStation] = []
        for line in csv.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: ";", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard f.count >= 9, let khz = Double(f[2]), [490.0, 518.0, 4209.5].contains(khz),
                  f[3].count == 1, let letter = f[3].first, ("A"..."X").contains(letter), !f[5].isEmpty else { continue }
            list.append(NavtexStation(country: f[0], countryCode: f[1], frequencyKHz: khz, letter: letter, callsign: f[4],
                                      name: f[5], navarea: f[8], language: f.count > 9 ? f[9] : ""))
        }
        return NavtexPlan(stations: list)
    }

    /// Stationen, die nach der Entscheidung des DWD für deutsche Gewässer zuständig sind (Voreinstellung)
    public static let defaultStationIDs: Set<String> = ["DEU-518-S-Pinneberg", "DEU-490-L-Pinneberg"]

    /// Sendefenster der Stationen in einheitlicher Form
    public func items(forStationIDs ids: Set<String>) -> [ScheduledItem] {
        stations.filter { ids.contains($0.id) }.flatMap { s in
            s.startMinutes.map { start in
                ScheduledItem(service: .navtex, id: Self.itemID(station: s, startMinute: start), startMinute: start,
                              durationMinutes: NavtexStation.slotDurationMinutes,
                              title: "\(s.name) (\(s.letter)) \(s.frequencyLabel)")
            }
        }
    }

    public static func itemID(station: NavtexStation, startMinute: Int) -> String {
        station.id + String(format: "@%02d%02d", startMinute / 60, startMinute % 60)
    }

    /// Alle Fenster-IDs der Stationen (für die Auswahl der automatischen Aufnahme)
    public func itemIDs(forStationIDs ids: Set<String>) -> Set<String> { Set(items(forStationIDs: ids).map(\.id)) }

    public func station(forItemID id: String) -> NavtexStation? {
        guard let at = id.firstIndex(of: "@") else { return nil }
        let sid = String(id[id.startIndex..<at])
        return stations.first { $0.id == sid }
    }
}
