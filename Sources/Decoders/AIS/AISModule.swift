import Foundation
import Combine
import SwiftUI
import os

// MARK: - Kanäle

/// UKW-Seefunkkanäle des AIS
public enum AISChannel: String, CaseIterable, Identifiable, Sendable {
    case a, b, free

    public var id: String { rawValue }

    /// Kanal 87B
    public static let frequencyA = 161_975_000.0
    /// Kanal 88B
    public static let frequencyB = 162_025_000.0

    public var frequencyHz: Double? {
        switch self {
        case .a: return Self.frequencyA
        case .b: return Self.frequencyB
        case .free: return nil
        }
    }

    public var label: String {
        switch self {
        case .a: return "161,975"
        case .b: return "162,025"
        case .free: return "frei"
        }
    }

    public var title: String {
        switch self {
        case .a: return "AIS 1 · 87B"
        case .b: return "AIS 2 · 88B"
        case .free: return "FREI"
        }
    }

    public var detail: String {
        switch self {
        case .a: return "161,975 MHz (Kanal 87B, „AIS 1“, NMEA-Kanal A)"
        case .b: return "162,025 MHz (Kanal 88B, „AIS 2“, NMEA-Kanal B)"
        case .free: return "Frequenz von Hand einstellen"
        }
    }

    public var nmeaChannel: Character {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .free: return "A"
        }
    }
}

// MARK: - Einstellungen

@MainActor
public final class AISSettingsStore: ObservableObject {
    @Published public var channel: AISChannel { didSet { UserDefaults.standard.set(channel.rawValue, forKey: "aisChannel") } }
    /// Wie lange ein Schiff nach der letzten Meldung in Liste und Karte bleibt (Minuten)
    @Published public var keepMinutes: Double { didSet { UserDefaults.standard.set(keepMinutes, forKey: "aisKeepMinutes") } }
    @Published public var showShips: Bool { didSet { UserDefaults.standard.set(showShips, forKey: "aisShowShips") } }
    @Published public var showAids: Bool { didSet { UserDefaults.standard.set(showAids, forKey: "aisShowAids") } }
    @Published public var showBase: Bool { didSet { UserDefaults.standard.set(showBase, forKey: "aisShowBase") } }
    /// Bei einem Klick auf ein Schiff in der Karte das Fenster mit den Schiffsdaten öffnen
    @Published public var openInfoOnClick: Bool { didSet { UserDefaults.standard.set(openInfoOnClick, forKey: "aisOpenInfoOnClick") } }
    /// Bei der Abfrage im Netz (Wikidata, Wikimedia Commons) automatisch suchen, sobald ein Schiff gewählt wird
    @Published public var webLookup: Bool { didSet { UserDefaults.standard.set(webLookup, forKey: "aisWebLookup") } }

    public init() {
        let d = UserDefaults.standard
        channel = AISChannel(rawValue: d.string(forKey: "aisChannel") ?? "") ?? .a
        let k = d.double(forKey: "aisKeepMinutes")
        keepMinutes = (5...1440).contains(k) ? k : 30
        showShips = d.object(forKey: "aisShowShips") as? Bool ?? true
        showAids = d.object(forKey: "aisShowAids") as? Bool ?? true
        showBase = d.object(forKey: "aisShowBase") as? Bool ?? true
        openInfoOnClick = d.object(forKey: "aisOpenInfoOnClick") as? Bool ?? true
        webLookup = d.object(forKey: "aisWebLookup") as? Bool ?? true
    }
}

extension AISSettingsStore: TuningTarget {
    public var centerHz: Double { 2400 }
    public var tones: (mark: Double, space: Double) { (0, 0) }
    public var markerBandwidth: Double { 4800 }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .band("AIS · Basisband (GMSK 9600 Bd, bis 4,8 kHz)") }
}

// MARK: - Decoder

/// AIS-Empfänger als 48-kHz-Senke an der Pipeline
public final class AISDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var frames: [AISReceiver.Decoded]
        public var stats: AISStats
        public var level: Double
        /// Pegel des Eingangs (Effektivwert) in dBFS
        public var inputDB: Double
    }

    public static let sampleRate = 48_000.0

    private let pipeline: AudioPipeline
    private let receiver = AISReceiver(sampleRate: AISDecoder.sampleRate)
    private var enabled = false
    private let lock = OSAllocatedUnfairLock()
    private var pending: [AISReceiver.Decoded] = []
    private var statsNow = AISStats()
    private var levelNow = 0.0
    private var meanSquare = 0.0
    private var inputDBNow = -120.0

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        receiver.onFrame = { [weak self] f in self?.lock.withLockUnchecked { self?.pending.append(f) } }
        pipeline.addSink(rate: Self.sampleRate) { [weak self] samples in self?.consume(samples) }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            enabled = on
            if !on { receiver.reset() }
        }
    }

    public func resetStats() {
        pipeline.perform { [self] in
            receiver.resetStats()
            lock.withLockUnchecked { statsNow = AISStats() }
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pending.removeAll() }
            return Output(frames: pending, stats: statsNow, level: levelNow, inputDB: inputDBNow)
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled else { return }
        receiver.process(samples)
        var sum = 0.0
        for x in samples { sum += Double(x) * Double(x) }
        let blockMS = samples.isEmpty ? 0 : sum / Double(samples.count)
        let k = min(1.0, Double(samples.count) / (0.3 * Self.sampleRate))
        meanSquare += k * (blockMS - meanSquare)
        let db = meanSquare > 1e-12 ? max(-120, 10 * log10(meanSquare)) : -120
        let stats = receiver.stats, level = receiver.level
        lock.withLockUnchecked {
            statsNow = stats
            levelNow = level
            inputDBNow = db
        }
    }
}

// MARK: - Diagnose

public enum AISDiagnosis {
    public enum Severity: Int, Sendable { case ok, waiting, problem }

    public struct Result: Equatable, Sendable {
        public var severity: Severity
        public var title: String
        public var advice: String
    }

    public static let silenceDB = -70.0

    public static func assess(inputDB: Double, stats: AISStats) -> Result {
        if inputDB < silenceDB && stats.bursts == 0 {
            return Result(severity: .problem, title: "KEIN AUDIO",
                          advice: "Am Eingang liegt kein Signal an. Richtiger Kanal (L, R oder L+R) und Eingang (VALHost) gewählt? Im SDR-Programm Ausgabe auf dieses Gerät gelegt, Rauschsperre offen?")
        }
        if stats.frames == 0 && stats.failed == 0 {
            return Result(severity: .waiting, title: "SUCHE AIS",
                          advice: "Audio kommt an, aber noch kein AIS-Burst. Im SDR-Programm: 161,975 oder 162,025 MHz, FM mit mindestens 15 kHz Bandbreite (besser 25 kHz), Audio ohne Rauschsperre, ohne De-Emphase und ohne Sprachfilter (Audio bis mindestens 6 kHz). In Gegenden mit wenig Schiffsverkehr dauert es Minuten.")
        }
        if stats.frames == 0 {
            return Result(severity: .problem, title: "BURSTS, ABER NICHTS LESBAR",
                          advice: "Der Burst-Anfang wird gefunden, aber die Daten sind nicht lesbar: Signal zu schwach oder verzerrt. FM-Bandbreite 15 … 25 kHz, Audio-Tiefpass im SDR-Programm mindestens 6 kHz, Antenne (Marine-Antenne, Sicht zum Wasser), Verstärkung.")
        }
        if stats.failed > 3 * stats.frames && stats.failed > 8 {
            return Result(severity: .waiting, title: "VIELE UNLESBARE BURSTS",
                          advice: "Neben den gelesenen Meldungen bleiben viele Bursts unlesbar: entfernte, schwache Schiffe sind normal. Treten sie auch bei starken Signalen auf, ist das Audio verfälscht (Sprachfilter, De-Emphase, Übersteuerung); Pegel um −30 … −10 dBFS.")
        }
        return Result(severity: .ok, title: "EMPFANG GUT", advice: "")
    }
}

// MARK: - Darstellung der Werte

public enum AISFormat {
    public static func decimal(_ v: Double, _ digits: Int = 1) -> String {
        String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
    }

    public static func knots(_ v: Double?) -> String { v.map { decimal($0, 1) } ?? "–" }

    public static func course(_ v: Double?) -> String { v.map { String(format: "%.0f°", $0) } ?? "–" }

    public static func age(_ s: Double) -> String {
        s < 90 ? "\(Int(s)) s" : s < 5400 ? "\(Int(s / 60)) min" : s < 172_800 ? "\(Int(s / 3600)) h" : "\(Int(s / 86_400)) d"
    }

    public static func seaMiles(km: Double) -> String { decimal(km / 1.852, km < 10 ? 2 : 1) + " sm" }

    public static func mmsiText(_ mmsi: UInt32) -> String { String(format: "%09d", mmsi) }
}

// MARK: - Karte

public enum AISMapBuilder {
    public struct Filter: Equatable, Sendable {
        public var ships = true
        public var aids = true
        public var base = true
        public init(ships: Bool = true, aids: Bool = true, base: Bool = true) { self.ships = ships; self.aids = aids; self.base = base }
    }

    public static func id(_ mmsi: UInt32) -> String { "ais-\(mmsi)" }

    public static func mmsi(fromID id: String) -> UInt32? {
        id.hasPrefix("ais-") ? UInt32(id.dropFirst(4)) : nil
    }

    static func symbol(_ v: AISVessel) -> String {
        switch v.kind {
        case .aid: return v.virtualAton ? "diamond" : "diamond.fill"
        case .base: return "antenna.radiowaves.left.and.right"
        case .aircraft: return "airplane"
        case .sart: return "exclamationmark.triangle.fill"
        case .craft: return "smallcircle.filled.circle"
        default:
            switch AISShipType.group(v.shipType ?? 0) {
            case .sailing, .pleasure: return "sailboat.fill"
            case .tug, .special: return "ferry"
            default: return "ferry.fill"
            }
        }
    }

    static func tone(_ v: AISVessel, age: Double) -> MapTone {
        if v.kind == .sart { return .alert }
        if age > 600 && v.kind != .aid && v.kind != .base { return .dim }
        switch v.kind {
        case .aid: return .dim
        case .base: return .info
        case .aircraft: return .alert
        default: break
        }
        switch AISShipType.group(v.shipType ?? 0) {
        case .passenger: return .highlight
        case .tanker: return .weather
        case .cargo: return .normal
        case .fishing, .sailing, .pleasure, .tug, .special, .highSpeed: return .info
        case .other, .unknown: return v.shipType == nil ? .dim : .normal
        }
    }

    static func details(_ v: AISVessel, home: GeoPoint?, age: Double) -> [String] {
        var d: [String] = []
        var head = AISCountry.name(ofMMSI: v.mmsi) ?? ""
        let flag = AISCountry.flag(ofMMSI: v.mmsi)
        if !flag.isEmpty { head = flag + " " + head }
        var ids = ["MMSI " + AISFormat.mmsiText(v.mmsi)]
        if let i = v.imo { ids.append("IMO \(i)") }
        if let c = v.callsign { ids.append(c) }
        d.append((head.isEmpty ? "" : head + " · ") + ids.joined(separator: " · "))
        if v.kind == .aid {
            if let t = v.atonType { d.append(AISAtonType.text(t) + (v.offPosition ? " · AUSSER POSITION" : "") + (v.virtualAton ? " · virtuell" : "")) }
        } else if v.kind == .shipA || v.kind == .shipB || v.kind == .craft {
            var t = [v.shipType.map(AISShipType.text) ?? v.kind.title]
            if let l = v.length, let b = v.beam { t.append("\(l) × \(b) m") } else if let l = v.length { t.append("\(l) m") }
            if let dr = v.draught { t.append("Tiefgang \(AISFormat.decimal(dr)) m") }
            d.append(t.joined(separator: " · "))
        }
        if let p = v.point { d.append(Geo.format(p)) }
        var move: [String] = []
        if let s = v.sog { move.append("\(AISFormat.decimal(s)) kn") }
        if let c = v.cog { move.append("Kurs \(Int(c.rounded()))°") }
        if let h = v.heading { move.append("Steven \(h)°") }
        if let n = v.navStatus, v.kind == .shipA { move.append(AISNavStatus.text(n)) }
        if !move.isEmpty { d.append(move.joined(separator: " · ")) }
        if let dest = v.destination { d.append("Ziel \(dest)" + (v.etaText.map { " · ETA \($0)" } ?? "")) }
        if let h = home, let p = v.point {
            let km = Geo.distanceKm(h, p), b = Geo.bearing(from: h, to: p)
            d.append("\(Geo.formatKm(km)) (\(AISFormat.seaMiles(km: km))) \(Geo.compass(b)) (\(Int(b.rounded()))°)")
        }
        d.append("\(v.messages) Meldungen · zuletzt vor \(AISFormat.age(age))")
        return d
    }

    public static func content(_ vessels: [AISVessel], home: GeoPoint?, now: Date, filter: Filter, selection: String?) -> MapContent {
        var markers: [MapMarker] = []
        for v in vessels {
            guard let p = v.point else { continue }
            switch v.kind {
            case .aid: if !filter.aids { continue }
            case .base: if !filter.base { continue }
            default: if !filter.ships { continue }
            }
            let age = now.timeIntervalSince(v.lastHeard)
            var sub = [v.shipType.map(AISShipType.short) ?? v.kind.title.split(separator: " ").first.map(String.init) ?? ""]
            if v.kind == .aid, let t = v.atonType { sub = [AISAtonType.text(t)] }
            if let s = v.sog, s >= 0.5 { sub.append("\(AISFormat.decimal(s)) kn") }
            if v.kind != .aid, v.kind != .base { sub.append("vor \(AISFormat.age(age))") }
            let moving = v.isMoving && v.kind != .aid && v.kind != .base
            var heading: Double?
            if moving { heading = v.heading.map(Double.init) ?? v.cog }
            // Weg: nur bewegte Schiffe, höchstens 300 Punkte
            var track: [GeoPoint] = []
            if moving, v.track.count > 1 {
                let stride = max(1, (v.track.count + 298) / 299)
                track = v.track.enumerated().filter { $0.offset % stride == 0 }.map(\.element.point)
                if let last = v.track.last?.point, track.last != last { track.append(last) }
            }
            markers.append(MapMarker(id: id(v.mmsi), coordinate: p, title: v.displayName, subtitle: sub.filter { !$0.isEmpty }.joined(separator: " · "),
                                     details: details(v, home: home, age: age), symbol: symbol(v), tone: tone(v, age: age), heardAt: v.lastHeard,
                                     track: track, headingDeg: heading))
        }
        return MapContent(markers: markers, lines: [], home: home, emptyHint: "Noch kein Schiff mit Position empfangen")
    }
}

// MARK: - Controller

@MainActor
public final class AISController: ObservableObject {
    public let decoder: AISDecoder
    public let logger = DecodeLogger(mode: "AIS")
    @Published public private(set) var ships: [AISVessel] = []
    @Published public var selection: String?
    @Published public private(set) var stats = AISStats()
    @Published public private(set) var inputDB = -120.0
    @Published public private(set) var level = 0.0
    /// Meldungen insgesamt, nach Typ und in der letzten Minute
    @Published public private(set) var messageCount = 0
    @Published public private(set) var typeCounts: [Int: Int] = [:]
    @Published public private(set) var perMinute = 0
    /// Weitestes empfangenes Schiff vom Standort
    @Published public private(set) var farthest: (mmsi: UInt32, km: Double)?
    /// Schiff, dessen Daten im Fenster „Schiffsdaten“ stehen
    @Published public var infoMMSI: UInt32?
    public let recorder: InputRecorder
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var lastRecording: URL?
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "aisLogEnabled") }
    }
    public var rigDescription: String? {
        didSet { if rigDescription != oldValue { markSession() } }
    }
    /// Standort für Entfernungen (vom Hauptfenster gesetzt)
    public var homePoint: GeoPoint?

    private let settings: AISSettingsStore
    private var vessels: [UInt32: AISVessel] = [:]
    private var dirty = false
    private var timer: Timer?
    private var recentTimes: [Date] = []
    private var cancellables: Set<AnyCancellable> = []

    public init(pipeline: AudioPipeline, settings: AISSettingsStore) {
        self.settings = settings
        decoder = AISDecoder(pipeline: pipeline)
        recorder = InputRecorder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "aisLogEnabled") as? Bool ?? true
        markSession()
        settings.$channel
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.markSession() }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
    }

    public func clear() {
        vessels.removeAll()
        ships.removeAll()
        selection = nil
        messageCount = 0
        typeCounts = [:]
        recentTimes.removeAll()
        farthest = nil
        decoder.resetStats()
        stats = AISStats()
    }

    public func toggleRecording() {
        if isRecording {
            lastRecording = recorder.stop()
            isRecording = false
            return
        }
        let hz = Int(settings.channel.frequencyHz ?? 162_000_000)
        let name = InputRecorder.fileName(frequencyHz: hz, mode: "FM", preset: "AIS", prefix: "AIS")
        recorder.start(url: InputRecorder.directory.appendingPathComponent(name))
        isRecording = true
        recordingDuration = 0
    }

    public var diagnosis: AISDiagnosis.Result { AISDiagnosis.assess(inputDB: inputDB, stats: stats) }

    public func markSession() {
        var h = "AIS · \(settings.channel.label) MHz FM · GMSK 9600 Bd"
        if let rig = rigDescription { h += " · \(rig)" }
        logger.markSession(h)
    }

    public var selectedMMSI: UInt32? { selection.flatMap(AISMapBuilder.mmsi(fromID:)) }

    public func vessel(_ mmsi: UInt32) -> AISVessel? { vessels[mmsi] }

    public var selectedVessel: AISVessel? { selectedMMSI.flatMap { vessels[$0] } }

    private func poll() {
        let out = decoder.takeOutput()
        if out.stats != stats { stats = out.stats }
        level = out.level
        if abs(out.inputDB - inputDB) >= 0.5 { inputDB = out.inputDB }
        if isRecording { recordingDuration = recorder.duration }
        let now = Date()
        for f in out.frames { ingest(bits: f.bits, at: now) }
        // alte Einträge entfernen
        let keep = settings.keepMinutes * 60
        var removed = false
        for (id, v) in vessels {
            let limit = (v.kind == .aid || v.kind == .base) ? max(keep, 6 * 3600) : keep
            if now.timeIntervalSince(v.lastHeard) > limit { vessels[id] = nil; removed = true }
        }
        recentTimes.removeAll { now.timeIntervalSince($0) > 60 }
        if perMinute != recentTimes.count { perMinute = recentTimes.count }
        if dirty || removed {
            dirty = false
            ships = vessels.values.sorted { $0.lastHeard > $1.lastHeard }
            if let s = selectedMMSI, vessels[s] == nil { selection = nil }
        }
    }

    /// Eine empfangene Nachricht aufnehmen (auch für Tests und Dateiwiedergabe)
    public func ingest(bits: [UInt8], at now: Date = Date()) {
        messageCount += 1
        recentTimes.append(now)
        let type = Int(AISBits(bits).u(0, 6))
        typeCounts[type, default: 0] += 1
        if logEnabled {
            let lines = AISNMEA.sentences(for: bits, channel: settings.channel.nmeaChannel)
            logger.append(lines.joined(separator: "\n") + "\n", now: now)
        }
        guard let m = AISMessage.decode(AISBits(bits)) else { return }
        var v = vessels[m.mmsi] ?? AISVessel(mmsi: m.mmsi, now: now)
        v.ingest(m, at: now)
        vessels[m.mmsi] = v
        dirty = true
        if let p = v.point, let h = homePoint {
            let km = Geo.distanceKm(h, p)
            // Weiteste Verbindung: Satellitenmeldungen (Typ 27) und Ausreißer über 1500 km zählen nicht
            let best = farthest?.km ?? 0
            if m.type != 27 && km <= 1_500 && km > best { farthest = (v.mmsi, km) }
        }
    }

    /// Schiffsdaten-Fenster für dieses Schiff
    public func showInfo(for mmsi: UInt32) {
        infoMMSI = mmsi
    }

    public func mapContent(home: GeoPoint?, now: Date) -> MapContent {
        AISMapBuilder.content(ships, home: home, now: now,
                              filter: .init(ships: settings.showShips, aids: settings.showAids, base: settings.showBase), selection: selection)
    }
}
