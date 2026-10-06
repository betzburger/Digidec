// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine

/// Zuordnung der DMR-Funkgeräte-Kennungen zu Rufzeichen (Datenbank von radioid.net). Die Liste (rund 17 MB) wird nur auf ausdrücklichen
/// Wunsch geladen (Knopf in den DMR-Einstellungen) und liegt danach lokal unter ~/Library/Application Support/Digidec/DMR.
@MainActor
public final class DMRIDDatabase: ObservableObject {
    public static let shared = DMRIDDatabase()

    public struct Entry: Equatable, Sendable {
        public var callsign: String
        public var name: String
        public var city: String
        public var country: String

        /// „Peter Betz, Würzburg, Germany“ (leere Teile entfallen)
        public var description: String { [name, city, country].filter { !$0.isEmpty }.joined(separator: ", ") }
    }

    public static let sourceURL = URL(string: "https://radioid.net/static/user.csv")!

    @Published public private(set) var count = 0
    @Published public private(set) var updated: Date?
    @Published public private(set) var status = "nicht geladen"
    @Published public private(set) var isLoading = false

    private var entries: [Int: Entry] = [:]
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Digidec", isDirectory: true).appendingPathComponent("DMR", isDirectory: true)
        fileURL = base.appendingPathComponent("user.csv")
        if FileManager.default.fileExists(atPath: fileURL.path) { Task { await loadFromDisk() } }
    }

    public func lookup(_ id: Int) -> Entry? { entries[id] }

    // MARK: Lesen

    /// Eine Zeile `RADIO_ID,CALLSIGN,FIRST_NAME,LAST_NAME,CITY,STATE,COUNTRY`; `nil` bei Kopfzeile oder fehlerhafter Zeile
    nonisolated public static func parse(line: Substring) -> (id: Int, entry: Entry)? {
        let f = line.split(separator: ",", maxSplits: 6, omittingEmptySubsequences: false)
        guard f.count >= 7, let id = Int(f[0]), id > 0 else { return nil }
        let first = f[2].trimmingCharacters(in: .whitespaces), last = f[3].trimmingCharacters(in: .whitespaces)
        let name = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        let call = f[1].trimmingCharacters(in: .whitespaces)
        guard !call.isEmpty else { return nil }
        return (id, Entry(callsign: call, name: name, city: f[4].trimmingCharacters(in: .whitespaces), country: f[6].trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    nonisolated public static func parse(csv: String) -> [Int: Entry] {
        var out: [Int: Entry] = [:]
        csv.enumerateLines { line, _ in
            if let r = parse(line: Substring(line)) { out[r.id] = r.entry }
        }
        return out
    }

    public func loadFromDisk() async {
        let url = fileURL
        status = "wird gelesen …"
        let parsed: [Int: Entry]? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let text = String(data: data, encoding: .utf8) else { return nil }
            return Self.parse(csv: text)
        }.value
        guard let parsed, !parsed.isEmpty else { status = "Liste nicht lesbar"; return }
        entries = parsed
        count = parsed.count
        updated = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        status = Self.describe(count: count, updated: updated)
    }

    nonisolated static func describe(count: Int, updated: Date?) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        f.locale = Locale(identifier: "de_DE")
        let n = NumberFormatter()
        n.numberStyle = .decimal
        n.locale = Locale(identifier: "de_DE")
        return "\(n.string(from: NSNumber(value: count)) ?? String(count)) Einträge" + (updated.map { ", Stand \(f.string(from: $0))" } ?? "")
    }

    // MARK: Laden (nur auf Wunsch)

    public func download() async {
        guard !isLoading else { return }
        isLoading = true
        status = "wird geladen …"
        defer { isLoading = false }
        do {
            let (temp, response) = try await URLSession.shared.download(from: Self.sourceURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { status = "Abruf fehlgeschlagen"; return }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
            try FileManager.default.moveItem(at: temp, to: fileURL)
            await loadFromDisk()
        } catch {
            status = "Abruf fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}
