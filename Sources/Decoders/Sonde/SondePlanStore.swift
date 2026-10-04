import Foundation
import Combine

/// Holt die Startortliste von SondeHub – nur auf Knopfdruck, mit Zeitlimit und Größenbegrenzung
public enum SondePlanFetcher {
    public static let maxBytes = 8_000_000

    public static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Digidec", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw PlanFetchError.network("Server antwortet nicht mit „OK“")
            }
            guard data.count <= maxBytes else { throw PlanFetchError.network("Antwort zu groß") }
            return data
        } catch let e as PlanFetchError {
            throw e
        } catch {
            throw PlanFetchError.network(error.localizedDescription)
        }
    }
}

/// Startorte der Wettersonden (SondeHub) samt Auswahl der Stationen, deren Starts Digidec automatisch empfangen soll.
/// Wie bei den anderen Plänen: eingebauter Stand, „Aktualisieren“ holt die Liste aus dem Netz und merkt sie sich.
@MainActor
public final class SondePlanStore: ObservableObject {
    public static let sitesURL = URL(string: "https://api.v2.sondehub.org/sites")!
    public static let radiusOptions = [200, 300, 500, 800, 1200]
    public static let leadOptions = [30, 45, 60, 75, 90]
    public static let windowOptions = [90, 120, 150, 180, 240]

    @Published public private(set) var sites: [SondeSite]
    /// z. B. „api.v2.sondehub.org/sites“
    @Published public private(set) var sourceName: String
    /// Zeitpunkt des letzten Abrufs; nil = in der App eingebauter Stand
    @Published public private(set) var updatedAt: Date?
    @Published public private(set) var isUpdating = false
    @Published public private(set) var message: String?

    @Published public var selectedSiteIDs: Set<String> { didSet { UserDefaults.standard.set(Array(selectedSiteIDs).sorted(), forKey: "sondePlanSelected") } }
    @Published public var autoEnabled: Bool { didSet { UserDefaults.standard.set(autoEnabled, forKey: "sondePlanAuto") } }
    @Published public var returnToPreviousModule: Bool { didSet { UserDefaults.standard.set(returnToPreviousModule, forKey: "sondePlanReturn") } }
    /// Nur Startorte bis zu dieser Entfernung vom Standort (km) werden gelistet
    @Published public var radiusKm: Int { didSet { UserDefaults.standard.set(radiusKm, forKey: "sondePlanRadius") } }
    /// Der Empfang beginnt so viele Minuten vor der nominalen Startzeit (die Sonde steigt etwa eine Stunde vor dem Termin auf)
    @Published public var leadMinutes: Int { didSet { UserDefaults.standard.set(leadMinutes, forKey: "sondePlanLead") } }
    /// So lange bleibt Digidec im Modul SONDE (ab Beginn des Empfangs)
    @Published public var windowMinutes: Int { didSet { UserDefaults.standard.set(windowMinutes, forKey: "sondePlanWindow") } }
    /// Eigene Frequenz je Station (Kennung → kHz), übersteuert den Eintrag der Liste
    @Published public private(set) var frequencyOverridesKHz: [String: Int]

    private let directory: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Digidec/SondePlan", isDirectory: true)
        self.directory = dir
        let d = UserDefaults.standard
        selectedSiteIDs = Set(d.stringArray(forKey: "sondePlanSelected") ?? [])
        autoEnabled = d.bool(forKey: "sondePlanAuto")
        returnToPreviousModule = d.object(forKey: "sondePlanReturn") as? Bool ?? true
        let radius = d.integer(forKey: "sondePlanRadius")
        radiusKm = Self.radiusOptions.contains(radius) ? radius : 500
        let lead = d.integer(forKey: "sondePlanLead")
        leadMinutes = Self.leadOptions.contains(lead) ? lead : 60
        let window = d.integer(forKey: "sondePlanWindow")
        windowMinutes = Self.windowOptions.contains(window) ? window : 150
        frequencyOverridesKHz = (d.dictionary(forKey: "sondePlanFrequencies") as? [String: Int]) ?? [:]

        if let cached = Self.loadCache(in: dir) {
            sites = cached.sites
            sourceName = cached.name
            updatedAt = cached.date
        } else if let bundled = Self.loadBundled() {
            sites = bundled
            sourceName = "sondehub_sites.json (eingebaut, Stand 04.10.2026)"
        } else {
            sites = []
            sourceName = "keine Liste"
        }
    }

    // MARK: - Frequenz

    /// Wirksame Frequenz einer Station (kHz): eigene Wahl, sonst Eintrag der Liste, sonst keine
    public func frequencyKHz(for site: SondeSite) -> Int? {
        frequencyOverridesKHz[site.id] ?? site.frequencyKHz
    }

    public func setFrequency(_ kHz: Int?, for site: SondeSite) {
        if let kHz, SondeSettingsStore.frequencyRange.contains(kHz) {
            frequencyOverridesKHz[site.id] = kHz
        } else {
            frequencyOverridesKHz[site.id] = nil
        }
        UserDefaults.standard.set(frequencyOverridesKHz, forKey: "sondePlanFrequencies")
    }

    // MARK: - Auswahl und Sendefenster

    public func site(forID id: String) -> SondeSite? { sites.first { $0.id == id } }

    public func site(forItemID id: String) -> SondeSite? { site(forID: SondeSite.siteID(fromItemID: id)) }

    /// Empfangsfenster der gewählten Stationen
    public var items: [ScheduledItem] {
        sites.filter { selectedSiteIDs.contains($0.id) }.flatMap { $0.items(leadMinutes: leadMinutes, windowMinutes: windowMinutes) }
    }
    public var selectedItemIDs: Set<String> { Set(items.map(\.id)) }

    /// Empfangsfenster einer Station
    public func items(for site: SondeSite) -> [ScheduledItem] {
        site.items(leadMinutes: leadMinutes, windowMinutes: windowMinutes)
    }

    /// Nominale Startzeiten einer Station als Plan ohne Vorlauf (für die Anzeige des nächsten Starts)
    public func nominalItems(for site: SondeSite) -> [ScheduledItem] {
        site.items(leadMinutes: 0, windowMinutes: 1)
    }

    public func toggle(_ site: SondeSite) {
        if selectedSiteIDs.contains(site.id) { selectedSiteIDs.remove(site.id) } else { selectedSiteIDs.insert(site.id) }
    }

    // MARK: - Aktualisieren

    public func update() async {
        guard !isUpdating else { return }
        isUpdating = true
        message = "Lade SondeHub-Liste …"
        defer { isUpdating = false }
        do {
            let data = try await SondePlanFetcher.download(Self.sitesURL)
            guard let parsed = SondePlanParser.parse(data), !parsed.isEmpty else {
                message = "Liste konnte nicht gelesen werden (Format geändert?) – Plan unverändert"
                return
            }
            let changed = parsed != sites
            sites = parsed
            sourceName = Self.sitesURL.host.map { $0 + Self.sitesURL.path } ?? "SondeHub"
            updatedAt = Date()
            let before = selectedSiteIDs.count
            selectedSiteIDs = selectedSiteIDs.intersection(Set(parsed.map(\.id)))
            Self.saveCache(data, name: sourceName, in: directory)
            var msg = changed ? "Aktualisiert: \(parsed.count) Startorte (\(parsed.filter(\.isRS41).count) mit RS41)" : "Plan unverändert (\(parsed.count) Startorte)"
            if selectedSiteIDs.count < before { msg += " – \(before - selectedSiteIDs.count) gewählte Station(en) gibt es nicht mehr" }
            message = msg
        } catch {
            message = "Abruf fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    // MARK: - Ablage

    private struct CacheMeta: Codable { var name: String; var date: Date }

    private static func loadCache(in dir: URL) -> (sites: [SondeSite], name: String, date: Date)? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("sites.json")),
              let meta = try? JSONDecoder().decode(CacheMeta.self, from: Data(contentsOf: dir.appendingPathComponent("meta.json"))),
              let sites = SondePlanParser.parse(data), !sites.isEmpty else { return nil }
        return (sites, meta.name, meta.date)
    }

    private static func saveCache(_ data: Data, name: String, in dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("sites.json"), options: .atomic)
        if let meta = try? JSONEncoder().encode(CacheMeta(name: name, date: Date())) {
            try? meta.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
    }

    private static func loadBundled() -> [SondeSite]? {
        let urls = [Bundle.main.url(forResource: "sondehub_sites", withExtension: "json", subdirectory: "Sonde"),
                    Bundle.main.url(forResource: "sondehub_sites", withExtension: "json"),
                    URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Sonde/sondehub_sites.json")]
        for u in urls.compactMap({ $0 }) {
            if let data = try? Data(contentsOf: u), let sites = SondePlanParser.parse(data), !sites.isEmpty { return sites }
        }
        return nil
    }
}
