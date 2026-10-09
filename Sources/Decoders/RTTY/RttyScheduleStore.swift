// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine

/// Sendeplan der DWD-Funkfernschreiben (Programm 1 und 2) samt Auswahl der automatisch aufzunehmenden Sendungen.
/// Wie beim Wetterfax: eingebauter Stand, „Aktualisieren“ holt beide PDFs von dwd.de und merkt sie sich.
@MainActor
public final class RttyScheduleStore: ObservableObject {
    @Published public private(set) var schedule: RttySchedule
    /// z. B. „sendeplan_rtty_01_092023.pdf + sendeplan_rtty_02_092023.pdf“
    @Published public private(set) var sourceName: String
    @Published public private(set) var updatedAt: Date?
    @Published public private(set) var isUpdating = false
    @Published public private(set) var message: String?

    @Published public var selected: Set<String> { didSet { UserDefaults.standard.set(Array(selected).sorted(), forKey: "rttySchedSelected") } }
    @Published public var autoEnabled: Bool { didSet { UserDefaults.standard.set(autoEnabled, forKey: "rttySchedAuto") } }
    @Published public var returnToPreviousModule: Bool { didSet { UserDefaults.standard.set(returnToPreviousModule, forKey: "rttySchedReturn") } }
    /// Standardfrequenz je Programm in Hz; 0 = automatisch
    @Published public private(set) var defaultFrequencyHz: [Int: Double]
    /// Frequenz je Sendung (Sendungs-ID → Hz), übersteuert die Standardfrequenz
    @Published public private(set) var frequencyOverrides: [String: Double]

    private let directory: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Digidec/RttySchedule", isDirectory: true)
        self.directory = dir
        let d = UserDefaults.standard
        selected = Set(d.stringArray(forKey: "rttySchedSelected") ?? [])
        autoEnabled = d.bool(forKey: "rttySchedAuto")
        returnToPreviousModule = d.object(forKey: "rttySchedReturn") as? Bool ?? true
        defaultFrequencyHz = Self.decode(d.dictionary(forKey: "rttySchedDefaultFreq"))
        frequencyOverrides = (d.dictionary(forKey: "rttySchedOverrides") as? [String: Double]) ?? [:]

        if let cached = Self.loadCache(in: dir) {
            schedule = cached.schedule
            sourceName = cached.name
            updatedAt = cached.date
        } else if let bundled = Self.loadBundled() {
            schedule = bundled
            sourceName = "sendeplan_rtty_01/02_092023.pdf (eingebaut)"
        } else {
            schedule = .empty
            sourceName = "kein Plan"
        }
    }

    // MARK: - Frequenz

    /// Voreinstellung nach Programm und Tageszeit: Programm 2 auf Langwelle (147,3 kHz, tagsüber wie nachts brauchbar),
    /// Programm 1 nachts/abends 4583 kHz (18–07 UTC), sonst 7646 kHz.
    public func automaticFrequency(program: Int, at date: Date) -> RttyFrequency? {
        let list = schedule.frequencies(forProgram: program)
        if program == 2 { return list.first(where: \.isLongwave) ?? list.first }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let night = !(7..<18).contains(cal.component(.hour, from: date))
        return list.min { abs($0.hz - (night ? 4_583_000 : 7_646_000)) < abs($1.hz - (night ? 4_583_000 : 7_646_000)) }
    }

    /// Wirksame Frequenz einer Sendung: Wahl für diese Sendung, sonst Standard des Programms, sonst Automatik
    public func frequency(for b: RttyBroadcast, at start: Date) -> RttyFrequency? {
        let list = schedule.frequencies(forProgram: b.program)
        if let hz = frequencyOverrides[b.id], let f = list.first(where: { $0.hz == hz }) { return f }
        if let hz = defaultFrequencyHz[b.program], hz > 0, let f = list.first(where: { $0.hz == hz }) { return f }
        return automaticFrequency(program: b.program, at: start)
    }

    public func setDefaultFrequency(_ hz: Double?, program: Int) {
        defaultFrequencyHz[program] = hz ?? 0
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: defaultFrequencyHz.map { (String($0.key), $0.value) }), forKey: "rttySchedDefaultFreq")
    }

    public func setOverride(_ hz: Double?, for b: RttyBroadcast) {
        frequencyOverrides[b.id] = hz
        UserDefaults.standard.set(frequencyOverrides, forKey: "rttySchedOverrides")
    }

    private static func decode(_ raw: [String: Any]?) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for (k, v) in raw ?? [:] { if let p = Int(k), let hz = v as? Double { out[p] = hz } }
        return out
    }

    // MARK: - Auswahl

    public func toggle(_ b: RttyBroadcast) {
        if selected.contains(b.id) { selected.remove(b.id) } else { selected.insert(b.id) }
    }
    public func selectAll() { selected = Set(schedule.broadcasts.map(\.id)) }
    public func selectNone() { selected = [] }

    // MARK: - Aktualisieren

    public func update() async {
        guard !isUpdating else { return }
        isUpdating = true
        message = "Lade DWD-Seite …"
        defer { isUpdating = false }
        do {
            let html = try await DWDPlanFetcher.html(from: WefaxScheduleSource.pageURL)
            var texts: [Int: String] = [:]
            var parts: [RttySchedule] = []
            var names: [String] = []
            for program in 1...2 {
                guard let url = RttyScheduleSource.pdfURL(program: program, inHTML: html) else {
                    message = "Link zum Plan Programm \(program) nicht gefunden (Seite des DWD geändert?) – Plan unverändert"
                    return
                }
                message = "Lade \(url.lastPathComponent) …"
                let text = try await DWDPlanFetcher.pdfText(from: url)
                guard let part = RttySchedule.parse(text: text, program: program) else {
                    message = "Plan Programm \(program) konnte nicht gelesen werden (Format geändert?) – Plan unverändert"
                    return
                }
                texts[program] = text
                parts.append(part)
                names.append(url.lastPathComponent)
            }
            let new = RttySchedule.merged(parts)
            let name = names.joined(separator: " + ")
            let changed = new != schedule
            schedule = new
            sourceName = name
            updatedAt = Date()
            let before = selected.count
            selected = selected.intersection(Set(new.broadcasts.map(\.id)))
            Self.saveCache(texts: texts, name: name, in: directory)
            var msg = changed ? "Aktualisiert: \(name), \(new.broadcasts.count) Sendungen" : "Plan unverändert (\(name))"
            if selected.count < before { msg += " – \(before - selected.count) gewählte Sendung(en) gibt es nicht mehr" }
            message = msg
        } catch {
            message = "Abruf fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    // MARK: - Ablage

    private struct CacheMeta: Codable { var name: String; var date: Date }

    private static func parseBoth(_ t1: String, _ t2: String) -> RttySchedule? {
        guard let a = RttySchedule.parse(text: t1, program: 1), let b = RttySchedule.parse(text: t2, program: 2) else { return nil }
        return RttySchedule.merged([a, b])
    }

    private static func loadCache(in dir: URL) -> (schedule: RttySchedule, name: String, date: Date)? {
        guard let t1 = try? String(contentsOf: dir.appendingPathComponent("program1.txt"), encoding: .utf8),
              let t2 = try? String(contentsOf: dir.appendingPathComponent("program2.txt"), encoding: .utf8),
              let meta = try? JSONDecoder().decode(CacheMeta.self, from: Data(contentsOf: dir.appendingPathComponent("meta.json"))),
              let schedule = parseBoth(t1, t2) else { return nil }
        return (schedule, meta.name, meta.date)
    }

    private static func saveCache(texts: [Int: String], name: String, in dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (p, t) in texts { try? t.write(to: dir.appendingPathComponent("program\(p).txt"), atomically: true, encoding: .utf8) }
        if let data = try? JSONEncoder().encode(CacheMeta(name: name, date: Date())) {
            try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
    }

    private static func loadBundled() -> RttySchedule? {
        func text(_ n: Int) -> String? {
            let file = "sendeplan_rtty_0\(n)_092023"
            let urls = [Bundle.main.url(forResource: file, withExtension: "txt", subdirectory: "Rtty"),
                        Bundle.main.url(forResource: file, withExtension: "txt"),
                        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Rtty/\(file).txt")]
            for u in urls.compactMap({ $0 }) { if let t = try? String(contentsOf: u, encoding: .utf8) { return t } }
            return nil
        }
        guard let t1 = text(1), let t2 = text(2) else { return nil }
        return parseBoth(t1, t2)
    }
}
