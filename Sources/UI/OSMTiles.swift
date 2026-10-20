// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Linux: Kartenkacheln von OpenStreetMap (und Esri/CARTO für Satellit und Nachtdarstellung) laden und zwischenspeichern.
#if !canImport(MapKit)
import SwiftUI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Kachelquelle mit Namensschild für die Quellenangabe
enum TileLayer: String, CaseIterable, Sendable {
    /// `osmNight`: dieselben Kacheln wie `osm`, beim Laden zur Nachtdarstellung umgefärbt (CARTO verlangt inzwischen einen Schlüssel)
    case osm, osmNight, esriImagery, esriLabels

    func url(z: Int, x: Int, y: Int) -> URL {
        switch self {
        case .osm, .osmNight: return URL(string: "https://tile.openstreetmap.org/\(z)/\(x)/\(y).png")!
        case .esriImagery: return URL(string: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/\(z)/\(y)/\(x)")!
        case .esriLabels: return URL(string: "https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/\(z)/\(y)/\(x)")!
        }
    }

    /// Verzeichnis des Plattenzwischenspeichers (Tag und Nacht teilen sich die Originalkacheln)
    var cacheName: String { self == .osmNight ? TileLayer.osm.rawValue : rawValue }
    var style: RasterTile.Style { self == .osmNight ? .night : .plain }

    var maxZoom: Int { self == .esriImagery || self == .esriLabels ? 18 : 19 }

    var attribution: String {
        switch self {
        case .osm, .osmNight: return "© OpenStreetMap-Mitwirkende"
        case .esriImagery, .esriLabels: return "Bilder © Esri, Maxar, Earthstar Geographics"
        }
    }
}

struct TileKey: Hashable, Sendable {
    var layer: TileLayer
    var z: Int, x: Int, y: Int
}

/// Briefkasten zwischen den Ladefäden und dem Hauptfaden
final class TileMailbox: @unchecked Sendable {
    static let shared = TileMailbox()
    private let lock = NSLock()
    private var items: [(key: TileKey, tile: RasterTile?, network: Bool)] = []
    func put(_ key: TileKey, _ tile: RasterTile?, _ network: Bool) { lock.lock(); items.append((key, tile, network)); lock.unlock() }
    func take() -> [(key: TileKey, tile: RasterTile?, network: Bool)] { lock.lock(); defer { lock.unlock() }; let r = items; items = []; return r }
}

/// Lädt Kacheln nach Bedarf (höchstens sechs gleichzeitig, zuletzt Verlangtes zuerst), hält sie im Speicher und auf der Platte
@MainActor
final class TileStore: ObservableObject {
    static let shared = TileStore()

    private var memory: [TileKey: RasterTile] = [:]
    private var used: [TileKey: UInt64] = [:]
    private var counter: UInt64 = 0
    private var inflight = Set<TileKey>()
    private var failed: [TileKey: Date] = [:]
    private var pending: [(key: TileKey, wanted: Date)] = []
    private var drainInstalled = false
    private var running = 0
    private let limit = 6
    private let capacity = 600
    /// Kacheln, die zuletzt nicht aus dem Netz kamen (Hinweis „Keine Verbindung“)
    private(set) var networkFailures = 0

    private let cacheRoot: URL = {
        let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return base.appendingPathComponent("digidec/tiles")
    }()

    private func file(_ k: TileKey) -> URL { cacheRoot.appendingPathComponent("\(k.layer.cacheName)/\(k.z)/\(k.x)/\(k.y).img") }

    /// Kachel, falls geladen; sonst wird sie angefordert (Aufruf beim Zeichnen)
    func tile(_ key: TileKey) -> RasterTile? {
        if let t = memory[key] { counter &+= 1; used[key] = counter; return t }
        request(key)
        return nil
    }

    /// Nur nachsehen, nichts anfordern (für Ersatzkacheln einer niedrigeren Stufe)
    func cached(_ key: TileKey) -> RasterTile? {
        if let t = memory[key] { counter &+= 1; used[key] = counter; return t }
        return nil
    }

    /// Übernimmt fertige Kacheln der Hintergrundfäden (läuft im Takt der Oberfläche)
    private func drain() {
        let taken = TileMailbox.shared.take()
        if ProcessInfo.processInfo.environment["DIGIDEC_TRACE_MAP"] != nil, !taken.isEmpty { FileHandle.standardError.write(Data("drain \(taken.count)\n".utf8)) }
        for item in taken { finish(item.key, data: item.tile, network: item.network) }
    }

    private func request(_ key: TileKey) {
        if !drainInstalled {
            let root = cacheRoot
            Task.detached(priority: .background) { TileStore.pruneDiskCache(root: root) }
        }
        if !drainInstalled { drainInstalled = true; tickHooks.append { [weak self] in MainActor.assumeIsolated { self?.drain() } }; if ProcessInfo.processInfo.environment["DIGIDEC_TRACE_MAP"] != nil { FileHandle.standardError.write(Data("hook installed \(tickHooks.count)\n".utf8)) } }
        if ProcessInfo.processInfo.environment["DIGIDEC_TRACE_MAP"] != nil { FileHandle.standardError.write(Data("request \(key) inflight=\(inflight.count) running=\(running)\n".utf8)) }
        guard !inflight.contains(key) else {
            if let i = pending.firstIndex(where: { $0.key == key }) { pending[i].wanted = Date() }
            return
        }
        if let when = failed[key], Date().timeIntervalSince(when) < 30 { return }
        inflight.insert(key)
        pending.append((key, Date()))
        pump()
    }

    private func pump() {
        while running < limit, let next = pending.popLast() {
            // Verlangte Kacheln, die nicht mehr sichtbar sind, gar nicht erst laden
            if Date().timeIntervalSince(next.wanted) > 3 { inflight.remove(next.key); continue }
            running += 1
            let key = next.key, path = file(key)
            Task.detached(priority: .userInitiated) { [weak self] in
                if ProcessInfo.processInfo.environment["DIGIDEC_TRACE_MAP"] != nil { FileHandle.standardError.write(Data("fetch start \(key.x)\n".utf8)) }
                let result = await Self.fetch(key: key, path: path)
                if ProcessInfo.processInfo.environment["DIGIDEC_TRACE_MAP"] != nil { FileHandle.standardError.write(Data("fetch end \(key.x) \(result.tile != nil)\n".utf8)) }
                TileMailbox.shared.put(key, result.tile, result.network)
            }
        }
    }

    func finish(_ key: TileKey, data: RasterTile?, network: Bool) {
        if ProcessInfo.processInfo.environment["DIGIDEC_TRACE_MAP"] != nil { FileHandle.standardError.write(Data("finish \(key) ok=\(data != nil) net=\(network)\n".utf8)) }
        running -= 1
        inflight.remove(key)
        if let data {
            memory[key] = data
            counter &+= 1; used[key] = counter
            networkFailures = 0
            if memory.count > capacity {
                for (k, _) in used.sorted(by: { $0.value < $1.value }).prefix(memory.count - capacity * 3 / 4) { memory[k] = nil; used[k] = nil }
            }
            objectWillChange.send()
            // Das Zeichnen läuft auf dem Hauptfaden im Ticker; ein Neuzeichnen genügt
        } else {
            failed[key] = Date()
            if network { networkFailures += 1 }
        }
        pump()
    }

    /// Kacheln auf der Platte gelten 30 Tage; danach wird neu geladen (ohne Netz bleibt die alte Kachel in Gebrauch)
    nonisolated static let maxTileAge: TimeInterval = 30 * 24 * 3600
    /// Größe des Plattenzwischenspeichers; darüber werden die am längsten nicht benutzten Kacheln gelöscht
    nonisolated static let maxCacheBytes = 512 * 1024 * 1024
    nonisolated static let userAgent = "Digidec/\(AppVersion.short) (Linux; amateur radio decoder; +https://github.com/betzburger/Digidec)"

    nonisolated private static func fetch(key: TileKey, path: URL) async -> (tile: RasterTile?, network: Bool) {
        let cached = (try? Data(contentsOf: path)).flatMap { RasterTile(data: $0, style: key.layer.style) }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
        if let cached, let modified, Date().timeIntervalSince(modified) < maxTileAge {
            // Zugriff vermerken: so löscht das Aufräumen die zuletzt benutzten Kacheln zuletzt
            touchAccess(path)
            return (cached, false)
        }
        var request = URLRequest(url: key.layer.url(z: key.z, x: key.x, y: key.y), timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let tile = RasterTile(data: data, style: key.layer.style) else { return (cached, false) }
            try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: path, options: .atomic)
            return (tile, false)
        } catch {
            return (cached, cached == nil)
        }
    }

    /// Setzt die Zugriffszeit (atime) der Kachel auf jetzt, die Änderungszeit (Alter für die Erneuerung) bleibt
    nonisolated private static func touchAccess(_ path: URL) {
        // UTIME_NOW und UTIME_OMIT aus <sys/stat.h> (Makros, die Swift nicht übernimmt)
        let utimeNow = (1 << 30) - 1, utimeOmit = (1 << 30) - 2
        var times = [timespec(tv_sec: 0, tv_nsec: utimeNow), timespec(tv_sec: 0, tv_nsec: utimeOmit)]
        _ = utimensat(AT_FDCWD, path.path, &times, 0)
    }

    /// Hält den Plattenzwischenspeicher unter `maxCacheBytes` (einmal je Programmstart, im Hintergrund)
    nonisolated static func pruneDiskCache(root: URL, limit: Int = maxCacheBytes) {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey, .isRegularFileKey]) else { return }
        var files: [(url: URL, size: Int, used: Date)] = []
        var total = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            total += size
            files.append((url, size, values.contentAccessDate ?? .distantPast))
        }
        guard total > limit else { return }
        // Auf drei Viertel der Grenze herunter, damit nicht bei jeder neuen Kachel aufgeräumt werden muss
        for file in files.sorted(by: { $0.used < $1.used }) where total > limit * 3 / 4 {
            if (try? FileManager.default.removeItem(at: file.url)) != nil { total -= file.size }
        }
    }
}
#endif
