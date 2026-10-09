// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Funkfeuer-Datenbank: eingebaute Liste (Europa) und die aktuelle Liste von OurAirports (gemeinfrei), die auf Knopfdruck geladen
// und unter ~/Library/Application Support/Digidec/NDB/navaids.csv abgelegt wird.

public struct NDBStation: Identifiable, Equatable, Sendable {
    public var ident: String
    public var frequencyKHz: Double
    public var name: String
    public var point: GeoPoint
    public var country: String

    public var id: String { "\(ident)-\(Int(frequencyKHz))-\(country)" }
    public var frequencyText: String { String(format: "%.1f kHz", frequencyKHz).replacingOccurrences(of: ".", with: ",") }
}

public final class NDBDatabase: @unchecked Sendable {
    public static let shared = NDBDatabase()
    public static let sourceURL = URL(string: "https://davidmegginson.github.io/ourairports-data/navaids.csv")!

    private let lock = NSLock()
    private var stations: [NDBStation] = []
    public private(set) var isDownloaded = false
    public private(set) var updated: Date?

    public init(loadCache: Bool = true) {
        let builtin = NDBDatabase.parseBuiltin(NDBBuiltinData.text)
        stations = builtin
        if loadCache, let text = try? String(contentsOf: NDBDatabase.cacheURL, encoding: .utf8) {
            let list = NDBDatabase.parseCSV(text)
            if list.count > 500 {
                stations = list
                isDownloaded = true
                updated = (try? FileManager.default.attributesOfItem(atPath: NDBDatabase.cacheURL.path)[.modificationDate]) as? Date
            }
        }
    }

    public static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Digidec/NDB/navaids.csv")
    }

    public var all: [NDBStation] { lock.withLock { stations } }
    public var count: Int { lock.withLock { stations.count } }

    // MARK: Lesen

    static func parseBuiltin(_ text: String) -> [NDBStation] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false)
            guard f.count >= 6, let khz = Double(f[1]), let lat = Double(f[2]), let lon = Double(f[3]) else { return nil }
            return NDBStation(ident: String(f[0]), frequencyKHz: khz, name: String(f[4]), point: GeoPoint(lat: lat, lon: lon), country: String(f[5]))
        }
    }

    /// OurAirports navaids.csv: Kopfzeile mit Spaltennamen; nur NDB und NDB-DME
    public static func parseCSV(_ text: String) -> [NDBStation] {
        var lines = text.split(whereSeparator: \.isNewline).makeIterator()
        guard let head = lines.next() else { return [] }
        let names = splitCSV(String(head))
        func col(_ n: String) -> Int? { names.firstIndex(of: n) }
        guard let cIdent = col("ident"), let cName = col("name"), let cType = col("type"), let cFreq = col("frequency_khz"),
              let cLat = col("latitude_deg"), let cLon = col("longitude_deg"), let cCountry = col("iso_country") else { return [] }
        var out: [NDBStation] = []
        while let line = lines.next() {
            let f = splitCSV(String(line))
            guard f.count > max(cIdent, cName, cType, cFreq, cLat, cLon, cCountry), f[cType] == "NDB" || f[cType] == "NDB-DME",
                  let khz = Double(f[cFreq]), let lat = Double(f[cLat]), let lon = Double(f[cLon]) else { continue }
            out.append(NDBStation(ident: f[cIdent].trimmingCharacters(in: .whitespaces), frequencyKHz: khz, name: f[cName], point: GeoPoint(lat: lat, lon: lon), country: f[cCountry]))
        }
        return out
    }

    static func splitCSV(_ line: String) -> [String] {
        var out: [String] = []
        var field = ""
        var quoted = false
        for ch in line {
            if ch == "\"" { quoted.toggle() }
            else if ch == "," && !quoted { out.append(field); field = "" }
            else { field.append(ch) }
        }
        out.append(field)
        return out
    }

    // MARK: Laden

    /// Aktuelle Liste von OurAirports holen und ablegen; Rückgabe: Zahl der Funkfeuer
    @discardableResult
    public func download() async throws -> Int {
        var request = URLRequest(url: Self.sourceURL)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else { throw URLError(.badServerResponse) }
        let list = Self.parseCSV(text)
        guard list.count > 500 else { throw URLError(.cannotParseResponse) }
        try FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Self.cacheURL)
        lock.withLock { stations = list; isDownloaded = true; updated = Date() }
        return list.count
    }

    // MARK: Suchen

    /// Funkfeuer mit dieser Kennung, die Frequenz nah der gemessenen zuerst
    public func lookup(ident: String, frequencyKHz: Double?) -> [NDBStation] {
        let id = ident.uppercased()
        let found = all.filter { $0.ident.uppercased() == id }
        guard let f = frequencyKHz else { return found }
        return found.sorted { abs($0.frequencyKHz - f) < abs($1.frequencyKHz - f) }
    }

    /// Funkfeuer nahe dieser Frequenz (±`tolerance` kHz), nach Abstand zur Frequenz
    public func near(frequencyKHz f: Double, tolerance: Double = 1.0) -> [NDBStation] {
        all.filter { abs($0.frequencyKHz - f) <= tolerance }.sorted { abs($0.frequencyKHz - f) < abs($1.frequencyKHz - f) }
    }

    /// Funkfeuer im Umkreis, nach Abstand
    public func within(km: Double, of home: GeoPoint) -> [(station: NDBStation, km: Double)] {
        all.map { ($0, Geo.distanceKm(home, $0.point)) }.filter { $0.1 <= km }.sorted { $0.1 < $1.1 }
    }
}

public enum NDBMatch: Equatable, Sendable {
    /// Kennung und Frequenz stimmen mit einem Eintrag überein
    case confirmed(NDBStation)
    /// Kennung stimmt mit einem Eintrag überein, die Frequenz weicht ab (kHz)
    case identOnly(NDBStation, deltaKHz: Double)
    /// Auf der Frequenz gibt es einen Eintrag, die Kennung lautet anders
    case frequencyOnly([NDBStation])
    case unknown

    /// Abgleich einer gelesenen Kennung mit der Datenbank
    public static func evaluate(ident: String, frequencyKHz: Double?, database: NDBDatabase, tolerance: Double = 1.1) -> NDBMatch {
        let byIdent = database.lookup(ident: ident, frequencyKHz: frequencyKHz)
        if let f = frequencyKHz {
            if let hit = byIdent.first(where: { abs($0.frequencyKHz - f) <= tolerance }) { return .confirmed(hit) }
            if let hit = byIdent.first, abs(hit.frequencyKHz - f) <= 30 { return .identOnly(hit, deltaKHz: f - hit.frequencyKHz) }
            let there = database.near(frequencyKHz: f, tolerance: tolerance)
            if !there.isEmpty { return .frequencyOnly(there) }
        }
        if let hit = byIdent.first, frequencyKHz == nil { return .identOnly(hit, deltaKHz: 0) }
        return .unknown
    }
}
