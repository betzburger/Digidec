// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - HFDL-Bodenstationen und Frequenzen
//
// Systemtabelle Version 52 (Stationsnummer, Ort, zugewiesene Frequenzen in kHz). Die Nummer der Frequenz in einer Meldung
// ist die Stelle in der Liste der Station. Daten aus `etc/systable.conf` von dumphfdl (Tomasz Lemiech, GPLv3), dort aus den
// Systemtabellen der Bodenstationen übernommen. Stationen können Frequenzen ändern; Digidec meldet die Tabellenversion einer
// empfangenen Meldung (Squitter) und warnt, wenn sie von dieser abweicht.

public struct HFDLStation: Identifiable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let lat: Double
    public let lon: Double
    /// Zugewiesene Frequenzen in kHz, in der Reihenfolge der Systemtabelle
    public let frequenciesKHz: [Double]

    public var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }
    /// Kurzname („Riverhead“)
    public var shortName: String { name.split(separator: ",").first.map(String.init) ?? name }
}

public enum HFDLStations {
    public static let tableVersion = 52

    public static let all: [HFDLStation] = [
        HFDLStation(id: 1, name: "San Francisco, California", lat: 38.384587, lon: -121.759647, frequenciesKHz: [21934.0, 17919.0, 13276.0, 11327.0, 10081.0, 8927.0, 6559.0, 5508.0]),
        HFDLStation(id: 2, name: "Molokai, Hawaii", lat: 21.184428, lon: -157.186846, frequenciesKHz: [21937.0, 17919.0, 13324.0, 13312.0, 13276.0, 11348.0, 11312.0, 10027.0, 8936.0, 8912.0, 6565.0, 5514.0]),
        HFDLStation(id: 3, name: "Reykjavik, Iceland", lat: 63.847168, lon: -22.455754, frequenciesKHz: [17985.0, 15025.0, 11184.0, 8977.0, 6712.0, 5720.0, 3900.0]),
        HFDLStation(id: 4, name: "Riverhead, New York", lat: 40.881922, lon: -72.63762, frequenciesKHz: [21931.0, 17919.0, 13276.0, 11387.0, 8912.0, 6661.0, 5652.0]),
        HFDLStation(id: 5, name: "Auckland, New Zealand", lat: -37.015757, lon: 174.809637, frequenciesKHz: [17916.0, 13351.0, 10084.0, 8921.0, 6535.0, 5583.0]),
        HFDLStation(id: 6, name: "Hat Yai, Thailand", lat: 6.937536, lon: 100.388451, frequenciesKHz: [21949.0, 17928.0, 13270.0, 10066.0, 8825.0, 6535.0, 5655.0]),
        HFDLStation(id: 7, name: "Shannon, Ireland", lat: 52.744089, lon: -8.926752, frequenciesKHz: [11384.0, 10081.0, 8942.0, 8843.0, 6532.0, 5547.0, 3455.0, 2998.0]),
        HFDLStation(id: 8, name: "Johannesburg, South Africa", lat: -26.129658, lon: 28.206078, frequenciesKHz: [21949.0, 17922.0, 13321.0, 11321.0, 8834.0, 5529.0, 4681.0, 3016.0]),
        HFDLStation(id: 9, name: "Barrow, Alaska", lat: 71.25849, lon: -156.577447, frequenciesKHz: [21937.0, 21928.0, 17934.0, 17919.0, 11354.0, 10093.0, 10027.0, 8936.0, 8927.0, 6646.0, 5544.0, 5538.0, 5529.0, 4687.0, 4654.0, 3497.0, 3007.0, 2992.0, 2944.0]),
        HFDLStation(id: 10, name: "Muan, South Korea", lat: 35.032377, lon: 126.238644, frequenciesKHz: [21931.0, 17958.0, 13342.0, 10060.0, 8939.0, 6619.0, 5502.0, 2941.0]),
        HFDLStation(id: 11, name: "Albrook, Panama", lat: 9.084681, lon: -79.373969, frequenciesKHz: [17901.0, 13264.0, 10063.0, 8894.0, 6589.0, 5589.0]),
        HFDLStation(id: 13, name: "Santa Cruz, Bolivia", lat: -17.671199, lon: -63.157088, frequenciesKHz: [21997.0, 17916.0, 13315.0, 11318.0, 8957.0, 6628.0, 4660.0]),
        HFDLStation(id: 14, name: "Krasnoyarsk, Russia", lat: 56.152603, lon: 92.583337, frequenciesKHz: [21990.0, 17912.0, 13321.0, 10087.0, 8886.0, 6596.0, 5622.0]),
        HFDLStation(id: 15, name: "Al Muharraq, Bahrain", lat: 26.308529, lon: 50.472318, frequenciesKHz: [21982.0, 17967.0, 13312.0, 10030.0, 8885.0, 6646.0, 5544.0, 2986.0]),
        HFDLStation(id: 16, name: "Agana, Guam", lat: 13.488833, lon: 144.828233, frequenciesKHz: [21928.0, 17919.0, 13312.0, 11306.0, 8927.0, 6652.0, 5451.0]),
        HFDLStation(id: 17, name: "Canarias, Spain", lat: 27.960945, lon: -15.405608, frequenciesKHz: [21955.0, 17928.0, 13303.0, 11348.0, 8948.0, 6529.0]),
    ]

    private static let byID: [Int: HFDLStation] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func station(_ id: Int) -> HFDLStation? { byID[id] }

    /// Alle Frequenzen (kHz) mit den Stationen, die sie nutzen, aufsteigend
    public static let channels: [(kHz: Double, stations: [HFDLStation])] = {
        var m: [Double: [HFDLStation]] = [:]
        for s in all { for f in s.frequenciesKHz { m[f, default: []].append(s) } }
        return m.keys.sorted().map { ($0, m[$0]!) }
    }()

    /// Station, die eine Frequenz (kHz) nutzt; bei mehreren die erste
    public static func stations(on kHz: Double) -> [HFDLStation] {
        all.filter { $0.frequenciesKHz.contains { abs($0 - kHz) < 0.5 } }
    }

    /// Frequenz einer Station nach der Nummer in der Systemtabelle
    public static func frequency(station: Int, index: Int) -> Double? {
        guard let s = byID[station], index >= 0, index < s.frequenciesKHz.count else { return nil }
        return s.frequenciesKHz[index]
    }

    /// Frequenzen (kHz) einer Bitmaske „in Benutzung“ einer Station
    public static func frequencies(station: Int, mask: UInt32) -> [Double] {
        (0..<20).compactMap { (mask >> UInt32($0)) & 1 == 1 ? frequency(station: station, index: $0) : nil }
    }
}
