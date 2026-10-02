import Foundation
import Combine
import SwiftUI
import os

// MARK: - Kanäle

/// ACARS-Frequenzen im Flugfunkband (AM). Die Erdfunkstellen wechseln je nach Region und Anbieter.
public enum ACARSChannel: String, CaseIterable, Identifiable, Codable, Sendable {
    case f131550, f131725, f131525, f130025, f136900, free

    public var id: String { rawValue }

    public var frequencyHz: Double? {
        switch self {
        case .f131550: return 131_550_000
        case .f131725: return 131_725_000
        case .f131525: return 131_525_000
        case .f130025: return 130_025_000
        case .f136900: return 136_900_000
        case .free: return nil
        }
    }

    public var label: String {
        frequencyHz.map { String(format: "%.3f", $0 / 1_000_000).replacingOccurrences(of: ".", with: ",") } ?? "frei"
    }

    public var note: String {
        switch self {
        case .f131550: return "131,550 MHz: weltweiter Hauptkanal (ARINC), in Europa viel Verkehr"
        case .f131725: return "131,725 MHz: Europa (SITA)"
        case .f131525: return "131,525 MHz: Europa"
        case .f130025: return "130,025 MHz: Europa"
        case .f136900: return "136,900 MHz: Europa, Datenfunk"
        case .free: return "Funkgerät nicht abstimmen"
        }
    }
}

// MARK: - Label und OOOI

public enum ACARSLabels {
    /// Bedeutung häufiger Labels (ARINC 618/620), deutsch
    public static func describe(_ label: String) -> String? {
        switch label {
        case "_d": return "Quittung ohne Inhalt"
        case "Q0": return "Verbindungstest"
        case "SA": return "Meldung der Erdfunkstelle (Funkstrecke)"
        case "SQ": return "Kennung der Erdfunkstelle (Squitter)"
        case "H1": return "Bordcomputer-Daten (Flugplan, Wetter, Text)"
        case "5Z": return "Daten der Fluggesellschaft"
        case "Q1": return "Flugbericht: Ausgeladen, Abgehoben, Gelandet, Eingeladen (OOOI)"
        case "Q2": return "Voraussichtliche Ankunft (ETA)"
        case "QA": return "OOOI: Abfahrt vom Gate (OUT)"
        case "QB": return "OOOI: Abheben (OFF)"
        case "QC": return "OOOI: Landung (ON)"
        case "QD": return "OOOI: Ankunft am Gate (IN)"
        default: return nil
        }
    }

    /// Start- und Zielflughafen (ICAO) aus den OOOI-Labels, Uhrzeiten hhmm
    public struct OOOI: Equatable, Sendable {
        public var from: String?
        public var to: String?
        public var out: String?
        public var off: String?
        public var on: String?
        public var `in`: String?
        public var eta: String?
    }

    public static func oooi(label: String, text: String) -> OOOI? {
        let t = Array(text.utf8)
        func s(_ a: Int, _ n: Int) -> String? {
            guard a + n <= t.count else { return nil }
            let v = String(decoding: t[a..<(a + n)], as: UTF8.self)
            return v.trimmingCharacters(in: .whitespaces).isEmpty ? nil : v
        }
        func airport(_ a: Int) -> String? { s(a, 4).flatMap { $0.allSatisfy(\.isLetter) ? $0 : nil } }
        func time(_ a: Int) -> String? { s(a, 4).flatMap { $0.allSatisfy(\.isNumber) ? $0 : nil } }
        var o = OOOI()
        switch label {
        case "Q1": o.from = airport(0); o.out = time(4); o.off = time(8); o.on = time(12); o.in = time(16); o.to = airport(24)
        case "Q2": o.from = airport(0); o.eta = time(4)
        case "QA": o.from = airport(0); o.out = time(4)
        case "QB": o.from = airport(0); o.off = time(4)
        case "QC": o.from = airport(0); o.on = time(4)
        case "QD": o.from = airport(0); o.in = time(4)
        default: return nil
        }
        return o.from == nil && o.to == nil ? nil : o
    }
}

// MARK: - Flughäfen

public struct Airport: Sendable, Equatable {
    public var icao: String
    public var iata: String
    public var name: String
    public var city: String
    public var country: String
    public var point: GeoPoint
}

/// Flughäfen aus `Resources/Airports/airports.txt` (OurAirports, gemeinfrei)
public final class AirportCatalog: @unchecked Sendable {
    public static let shared = AirportCatalog()
    private var table: [String: Airport]?
    private let lock = NSLock()

    public func lookup(_ icao: String) -> Airport? {
        lock.withLock {
            if table == nil { table = Self.load() }
            return table?[icao.uppercased()]
        }
    }

    public var count: Int { lock.withLock { if table == nil { table = Self.load() }; return table?.count ?? 0 } }

    static var directory: URL? {
        if let res = Bundle.main.resourceURL?.appendingPathComponent("Airports"),
           FileManager.default.fileExists(atPath: res.appendingPathComponent("airports.txt").path) { return res }
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Airports")
        return FileManager.default.fileExists(atPath: project.appendingPathComponent("airports.txt").path) ? project : nil
    }

    private static func load() -> [String: Airport] {
        guard let dir = directory, let text = try? String(contentsOf: dir.appendingPathComponent("airports.txt"), encoding: .utf8) else { return [:] }
        var t: [String: Airport] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let f = line.split(separator: ";", omittingEmptySubsequences: false)
            guard f.count >= 7, let lat = Double(f[5]), let lon = Double(f[6]) else { continue }
            t[String(f[0])] = Airport(icao: String(f[0]), iata: String(f[1]), name: String(f[2]), city: String(f[3]), country: String(f[4]),
                                      point: GeoPoint(lat: lat, lon: lon))
        }
        return t
    }
}

// MARK: - Einstellungen

@MainActor
public final class ACARSSettingsStore: ObservableObject {
    @Published public var channel: ACARSChannel { didSet { UserDefaults.standard.set(channel.rawValue, forKey: "acarsChannel") } }
    /// Meldungen vom Boden zum Flugzeug zeigen
    @Published public var showUplink: Bool { didSet { UserDefaults.standard.set(showUplink, forKey: "acarsUplink") } }
    /// Meldungen ohne Text (Quittungen, Verbindungstests) ausblenden
    @Published public var hideEmpty: Bool { didSet { UserDefaults.standard.set(hideEmpty, forKey: "acarsHideEmpty") } }

    public init() {
        let d = UserDefaults.standard
        channel = d.string(forKey: "acarsChannel").flatMap { ACARSChannel(rawValue: $0) } ?? .f131550
        showUplink = d.object(forKey: "acarsUplink") as? Bool ?? true
        hideEmpty = d.object(forKey: "acarsHideEmpty") as? Bool ?? true
    }
}

extension ACARSSettingsStore: TuningTarget {
    public var centerHz: Double { 1800 }
    public var tones: (mark: Double, space: Double) { (1200, 2400) }
    public var markerBandwidth: Double { 1400 }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .band("ACARS · MSK 2400 Bd, 1200 und 2400 Hz im AM-Audio") }
}

// MARK: - Flugzeuge und Karte

/// Was über ein Flugzeug (Kennzeichen) aus den Meldungen bekannt ist
public struct ACARSAircraft: Identifiable, Equatable, Sendable {
    public var id: String { registration }
    public var registration: String
    public var flight: String?
    public var from: String?
    public var to: String?
    public var eta: String?
    public var firstHeard: Date
    public var lastHeard: Date
    public var messages = 0
    public var lastText = ""
}

public enum ACARSMapBuilder {
    /// Flugstrecken: Start- und Zielflughafen mit Großkreislinie, Beschriftung mit Flugnummer und Kennzeichen
    public static func content(_ aircraft: [ACARSAircraft], home: GeoPoint?, now: Date, maxAge: TimeInterval = 6 * 3600) -> MapContent {
        var markers: [MapMarker] = []
        var lines: [MapLine] = []
        var airports: [String: (Airport, [String])] = [:]
        for a in aircraft.sorted(by: { $0.lastHeard > $1.lastHeard }) where now.timeIntervalSince(a.lastHeard) <= maxAge {
            let dep = a.from.flatMap { AirportCatalog.shared.lookup($0) }
            let dest = a.to.flatMap { AirportCatalog.shared.lookup($0) }
            let title = a.flight.flatMap { $0.isEmpty ? nil : $0 } ?? a.registration
            if let d = dep { airports[d.icao, default: (d, [])].1.append("Start: \(title)") }
            if let d = dest { airports[d.icao, default: (d, [])].1.append("Ziel: \(title)") }
            if let d = dep, let z = dest, d.icao != z.icao {
                lines.append(MapLine(id: "acars-" + a.registration, points: [d.point, z.point], tone: .highlight, geodesic: true))
            }
        }
        for (icao, entry) in airports.sorted(by: { $0.key < $1.key }) {
            let (ap, uses) = entry
            var details = [Geo.format(ap.point), "\(ap.city) · \(ap.country)"]
            if let h = home {
                let km = Geo.distanceKm(h, ap.point), b = Geo.bearing(from: h, to: ap.point)
                details.append("\(Geo.formatKm(km)) \(Geo.compass(b)) (\(Int(b.rounded()))°)")
            }
            details += uses.prefix(6)
            markers.append(MapMarker(id: "ap-" + icao, coordinate: ap.point, title: ap.iata.isEmpty ? icao : ap.iata,
                                     subtitle: "\(icao) · \(ap.name)", details: details, symbol: "airplane", tone: .info))
        }
        return MapContent(markers: markers, lines: lines, home: home, emptyHint: "Noch kein Flughafen aus ACARS-Meldungen (OOOI-Berichte, Labels Q1 bis QD)")
    }
}

// MARK: - Decoder

public final class ACARSDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var messages: [ACARSMessage]
        public var inFrame: Bool
    }

    public static let sampleRate = 12_000.0

    private let pipeline: AudioPipeline
    private let receiver = ACARSReceiver(sampleRate: ACARSDecoder.sampleRate)
    private var enabled = false
    private let lock = OSAllocatedUnfairLock()
    private var pending: [ACARSMessage] = []
    private var frameNow = false

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addSink(rate: Self.sampleRate) { [weak self] samples in self?.consume(samples) }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            enabled = on
            if !on { receiver.reset() }
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pending.removeAll() }
            return Output(messages: pending, inFrame: frameNow)
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled else { return }
        var found: [ACARSMessage] = []
        receiver.process(samples, now: Date()) { found.append($0) }
        let active = receiver.inFrame
        lock.withLockUnchecked {
            pending.append(contentsOf: found)
            frameNow = active
        }
    }
}

// MARK: - Controller

@MainActor
public final class ACARSController: ObservableObject {
    public let decoder: ACARSDecoder
    public let logger = DecodeLogger(mode: "ACARS")
    @Published public private(set) var messages: [ACARSMessage] = []
    @Published public private(set) var aircraft: [String: ACARSAircraft] = [:]
    @Published public private(set) var inFrame = false
    @Published public private(set) var count = 0
    @Published public private(set) var correctedCount = 0
    @Published public private(set) var lastDate: Date?
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "acarsLogEnabled") }
    }
    public var rigDescription: String? {
        didSet { if rigDescription != oldValue { markSession() } }
    }

    public static let maxMessages = 1000
    private let settings: ACARSSettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: ACARSSettingsStore) {
        self.settings = settings
        decoder = ACARSDecoder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "acarsLogEnabled") as? Bool ?? true
        markSession()
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.markSession() }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func setActive(_ active: Bool) { decoder.setEnabled(active) }

    public func clear() {
        messages.removeAll()
        aircraft.removeAll()
    }

    public func markSession() {
        var h = "ACARS · \(settings.channel.label) MHz AM · MSK 2400 Bd"
        if let rig = rigDescription { h += " · \(rig)" }
        logger.markSession(h)
    }

    /// Meldung aufnehmen: Liste, Flugzeugtabelle (Start/Ziel aus OOOI-Labels), Log
    public func ingest(_ m: ACARSMessage, at now: Date = Date()) {
        count += 1
        if m.corrected > 0 { correctedCount += 1 }
        lastDate = now
        messages.append(m)
        if messages.count > Self.maxMessages { messages.removeFirst(messages.count - Self.maxMessages) }
        if !m.registration.isEmpty {
            var a = aircraft[m.registration] ?? ACARSAircraft(registration: m.registration, firstHeard: now, lastHeard: now)
            a.lastHeard = now
            a.messages += 1
            if let f = m.flightID, !f.isEmpty { a.flight = f }
            if !m.isEmpty { a.lastText = m.text }
            if let o = ACARSLabels.oooi(label: m.label, text: m.text) {
                if let v = o.from { a.from = v }
                if let v = o.to { a.to = v }
                if let v = o.eta { a.eta = v }
            }
            aircraft[m.registration] = a
        }
        if logEnabled { logger.append(Self.logLine(m) + "\n", now: now) }
    }

    private func poll() {
        let out = decoder.takeOutput()
        inFrame = out.inFrame
        for m in out.messages { ingest(m) }
    }

    /// Meldungen nach den Filtern der Einstellungen
    public var visible: [ACARSMessage] {
        messages.filter { m in
            (settings.showUplink || m.isDownlink) && !(settings.hideEmpty && m.isEmpty)
        }
    }

    public func mapContent(home: GeoPoint?, now: Date = Date()) -> MapContent {
        ACARSMapBuilder.content(Array(aircraft.values), home: home, now: now)
    }

    /// „08:15:02  D-AIXC  LH1234  ↓ H1  3  Text“
    nonisolated public static func logLine(_ m: ACARSMessage) -> String {
        var s = utc.string(from: m.time) + "  " + (m.registration.isEmpty ? "-" : m.registration)
        s += "  " + (m.flightID ?? "-") + "  " + (m.isDownlink ? "↓" : "↑") + " " + m.label + "  " + String(m.blockID)
        if m.ack == "NAK" { s += " NAK" } else if !m.ack.isEmpty { s += " ack=" + m.ack }
        if !m.text.isEmpty { s += "  " + m.text.replacingOccurrences(of: "\n", with: " ⏎ ") }
        if m.corrected > 0 { s += "  [\(m.corrected) Bit korrigiert]" }
        if m.continues { s += "  [wird fortgesetzt]" }
        return s
    }
}
