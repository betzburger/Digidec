import Foundation
import Combine
import PDFKit

/// Welche der drei DWD-Frequenzen für geplante Aufnahmen benutzt wird
public enum WefaxFrequencyChoice: String, CaseIterable, Identifiable, Sendable {
    case auto, f3855, f7880, f13882

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto:   return "Automatisch (nachts 3855, tags 7880 kHz)"
        case .f3855:  return "3855 kHz"
        case .f7880:  return "7880 kHz"
        case .f13882: return "13882,5 kHz"
        }
    }

    public func station(at date: Date) -> WefaxStation {
        switch self {
        case .f3855:  return .dwd3855
        case .f7880:  return .dwd7880
        case .f13882: return .dwd13882
        case .auto:
            return WefaxSchedule.recommendedFrequencyHz(at: date) == 3_855_000 ? .dwd3855 : .dwd7880
        }
    }
}

/// Sendeplan der DWD-Wetterfax-Ausstrahlung samt Auswahl der automatisch aufzunehmenden Sendungen.
/// Der Plan kommt zunächst aus der App (Stand der Auslieferung), „Aktualisieren“ holt den aktuellen Plan von dwd.de
/// (PDF, nur auf Knopfdruck) und merkt ihn sich.
@MainActor
public final class WefaxScheduleStore: ObservableObject {
    @Published public private(set) var schedule: WefaxSchedule
    /// z. B. „sendeplan_fax_092023.pdf“
    @Published public private(set) var sourceName: String
    /// Zeitpunkt des letzten Abrufs; nil = in der App eingebauter Plan
    @Published public private(set) var updatedAt: Date?
    @Published public private(set) var isUpdating = false
    @Published public private(set) var message: String?

    @Published public var selected: Set<String> { didSet { UserDefaults.standard.set(Array(selected).sorted(), forKey: "wefaxSchedSelected") } }
    /// Hauptschalter: ausgewählte Sendungen werden automatisch aufgenommen
    @Published public var autoEnabled: Bool { didSet { UserDefaults.standard.set(autoEnabled, forKey: "wefaxSchedAuto") } }
    @Published public var frequencyChoice: WefaxFrequencyChoice { didSet { UserDefaults.standard.set(frequencyChoice.rawValue, forKey: "wefaxSchedFreq") } }
    /// Zusätzlich das Eingangssignal als WAV mitschneiden (große Dateien: ≈ 100 MB je Sendung bei 48 kHz)
    @Published public var recordAudio: Bool { didSet { UserDefaults.standard.set(recordAudio, forKey: "wefaxSchedAudio") } }
    /// Frequenz je Sendung („1236“ → f3855 …), die die Standardwahl übersteuert; entsteht auch durch Umstellen von Hand
    @Published public private(set) var frequencyOverrides: [String: WefaxFrequencyChoice]
    /// Nach der Aufnahme zum vorher gewählten Modul zurückschalten
    @Published public var returnToPreviousModule: Bool { didSet { UserDefaults.standard.set(returnToPreviousModule, forKey: "wefaxSchedReturn") } }

    private let directory: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Digidec/WefaxSchedule", isDirectory: true)
        self.directory = dir
        let d = UserDefaults.standard
        selected = Set(d.stringArray(forKey: "wefaxSchedSelected") ?? [])
        autoEnabled = d.bool(forKey: "wefaxSchedAuto")
        frequencyChoice = d.string(forKey: "wefaxSchedFreq").flatMap(WefaxFrequencyChoice.init(rawValue:)) ?? .auto
        recordAudio = d.bool(forKey: "wefaxSchedAudio")
        frequencyOverrides = (d.dictionary(forKey: "wefaxSchedFreqOverrides") as? [String: String] ?? [:])
            .compactMapValues { WefaxFrequencyChoice(rawValue: $0) }
        returnToPreviousModule = d.object(forKey: "wefaxSchedReturn") as? Bool ?? true

        // 1. zuletzt abgerufener Plan, 2. eingebauter Plan
        if let cached = Self.loadCache(in: dir) {
            schedule = cached.schedule
            sourceName = cached.name
            updatedAt = cached.date
        } else if let bundled = Self.loadBundled() {
            schedule = bundled
            sourceName = "sendeplan_fax_092023.pdf (eingebaut)"
        } else {
            schedule = WefaxSchedule(frequenciesHz: [], broadcasts: [], pauses: [])
            sourceName = "kein Plan"
        }
    }

    // MARK: - Frequenz je Sendung

    /// Wirksame Wahl für eine Sendung: Eintrag für diese Sendung, sonst die Standardwahl
    public func choice(for b: WefaxBroadcast) -> WefaxFrequencyChoice { frequencyOverrides[b.id] ?? frequencyChoice }

    /// `nil` (oder `.auto`) entfernt die Sonderwahl und verwendet wieder die Standardwahl
    public func setOverride(_ choice: WefaxFrequencyChoice?, for b: WefaxBroadcast) {
        if let choice, choice != .auto { frequencyOverrides[b.id] = choice } else { frequencyOverrides[b.id] = nil }
        UserDefaults.standard.set(frequencyOverrides.mapValues(\.rawValue), forKey: "wefaxSchedFreqOverrides")
    }

    // MARK: - Auswahl

    public func toggle(_ b: WefaxBroadcast) {
        if selected.contains(b.id) { selected.remove(b.id) } else { selected.insert(b.id) }
    }

    public func selectAll() { selected = Set(schedule.broadcasts.map(\.id)) }
    public func selectNone() { selected = [] }

    // MARK: - Aktualisieren (DWD-Seite → PDF → Plan)

    public func update() async {
        guard !isUpdating else { return }
        isUpdating = true
        message = "Lade DWD-Seite …"
        defer { isUpdating = false }
        do {
            let html = try await DWDPlanFetcher.html(from: WefaxScheduleSource.pageURL)
            guard let pdfURL = WefaxScheduleSource.faxPDFURL(inHTML: html) else {
                message = "Link zum Sendeplan nicht gefunden (Seite des DWD geändert?) – Plan unverändert"
                return
            }
            message = "Lade \(pdfURL.lastPathComponent) …"
            let text = try await DWDPlanFetcher.pdfText(from: pdfURL)
            guard let new = WefaxSchedule.parse(text: text) else {
                message = "Sendeplan konnte nicht gelesen werden (Format geändert?) – Plan unverändert"
                return
            }
            let name = pdfURL.lastPathComponent
            let changed = new != schedule
            schedule = new
            sourceName = name
            updatedAt = Date()
            let before = selected.count
            selected = selected.intersection(Set(new.broadcasts.map(\.id)))
            Self.saveCache(text: text, name: name, in: directory)
            var msg = changed ? "Aktualisiert: \(name), \(new.broadcasts.count) Ausstrahlungen" : "Plan unverändert (\(name))"
            if selected.count < before { msg += " – \(before - selected.count) gewählte Sendung(en) gibt es nicht mehr" }
            message = msg
        } catch {
            message = "Abruf fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    // MARK: - Ablage

    private static func loadCache(in dir: URL) -> (schedule: WefaxSchedule, name: String, date: Date)? {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("schedule.txt"), encoding: .utf8),
              let meta = try? JSONDecoder().decode(CacheMeta.self, from: Data(contentsOf: dir.appendingPathComponent("meta.json"))),
              let schedule = WefaxSchedule.parse(text: text) else { return nil }
        return (schedule, meta.name, meta.date)
    }

    private static func saveCache(text: String, name: String, in dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: dir.appendingPathComponent("schedule.txt"), atomically: true, encoding: .utf8)
        if let data = try? JSONEncoder().encode(CacheMeta(name: name, date: Date())) {
            try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
    }

    private struct CacheMeta: Codable { var name: String; var date: Date }

    private static func loadBundled() -> WefaxSchedule? {
        let candidates = [
            Bundle.main.url(forResource: "sendeplan_fax_092023", withExtension: "txt", subdirectory: "Wefax"),
            Bundle.main.url(forResource: "sendeplan_fax_092023", withExtension: "txt"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Wefax/sendeplan_fax_092023.txt"),
        ].compactMap { $0 }
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8), let s = WefaxSchedule.parse(text: text) { return s }
        }
        return nil
    }
}
