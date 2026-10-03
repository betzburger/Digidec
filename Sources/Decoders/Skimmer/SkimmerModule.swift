import Foundation
import Combine
import SwiftUI
import os

// MARK: - Bänder (CW)

/// Dial-Frequenzen für den CW-Skimmer: Das Funkgerät steht in USB, die Signale liegen 0,3 … 2,7 kHz über dem Dial.
/// Gewählt sind die Anfänge der CW-Bereiche; frei = Funkgerät wird nicht abgestimmt.
public enum SkimBand: String, CaseIterable, Identifiable, Codable, Sendable {
    case free = "frei"
    case m160 = "160m", m80 = "80m", m40 = "40m", m30 = "30m", m20 = "20m", m17 = "17m", m15 = "15m", m12 = "12m", m10 = "10m", m6 = "6m"

    public var id: String { rawValue }

    public var dialHz: Int? {
        switch self {
        case .free: return nil
        case .m160: return 1_810_000
        case .m80:  return 3_520_000
        case .m40:  return 7_020_000
        case .m30:  return 10_110_000
        case .m20:  return 14_020_000
        case .m17:  return 18_075_000
        case .m15:  return 21_020_000
        case .m12:  return 24_895_000
        case .m10:  return 28_020_000
        case .m6:   return 50_090_000
        }
    }
}

// MARK: - Stationen und Spots

/// Ein gehörtes Signal in der Liste des Skimmers
public struct SkimStation: Identifiable, Equatable, Sendable {
    public var id: Int
    public var mode: SkimMode
    /// NF-Frequenz in Hz
    public var audioHz: Double
    public var snrDB: Double
    /// WpM (CW) bzw. Baud (PSK)
    public var speed: Double
    public var firstHeard: Date
    public var lastHeard: Date
    /// Das Signal ist noch da (sonst nur Erinnerung für `hold` Minuten)
    public var isLive = true
    /// Letzte gelesene Zeichen
    public var text = ""
    /// Wahrscheinlichstes Rufzeichen der Station und sein Gebiet
    public var call: String?
    public var dxcc: DXCCEntity?
    /// Hat zuletzt „CQ“ gesendet
    public var isCQ = false
    public var characters = 0

    /// HF-Frequenz in Hz bei bekanntem Dial (USB: Dial + NF, LSB: Dial − NF)
    public func rfHz(dialHz: Int?, lsb: Bool) -> Double? {
        guard let d = dialHz else { return nil }
        return Double(d) + (lsb ? -audioHz : audioHz)
    }
}

/// Eine Meldung wie im Reverse Beacon Network: wer, wo, wann, wie stark, wie schnell
public struct SkimSpot: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var time: Date
    public var call: String
    public var audioHz: Double
    public var rfHz: Double?
    public var snrDB: Double
    public var speed: Double
    public var mode: SkimMode
    /// „CQ“ oder „DE“ (nur im Gespräch gehört)
    public var kind: String
    public var dxcc: DXCCEntity?

    public static func == (a: SkimSpot, b: SkimSpot) -> Bool { a.id == b.id }
}

// MARK: - Einstellungen

@MainActor
public final class SkimmerSettingsStore: ObservableObject {
    @Published public var mode: SkimMode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "skimMode") } }
    @Published public var cwBand: SkimBand { didSet { UserDefaults.standard.set(cwBand.rawValue, forKey: "skimCWBand") } }
    @Published public var pskBand: PSKBand { didSet { UserDefaults.standard.set(pskBand.rawValue, forKey: "skimPSKBand") } }
    /// Abstand eines Trägers zum Rauschen (dB je Bin), ab dem ein Signal gesucht wird: kleiner = empfindlicher, mehr falsche Treffer
    @Published public var thresholdDB: Double { didSet { UserDefaults.standard.set(thresholdDB, forKey: "skimThreshold") } }
    /// Mindest-Rauschabstand in 500 Hz für die Liste
    @Published public var minSNR: Double { didSet { UserDefaults.standard.set(minSNR, forKey: "skimMinSNR") } }
    /// Nur Signale mit erkanntem Rufzeichen zeigen
    @Published public var onlyCalls: Bool { didSet { UserDefaults.standard.set(onlyCalls, forKey: "skimOnlyCalls") } }
    /// Wie lange Signale nach ihrem Ende in der Liste bleiben (Minuten)
    @Published public var holdMinutes: Double { didSet { UserDefaults.standard.set(holdMinutes, forKey: "skimHold") } }
    /// Dial des Funkgeräts (rigctld) und Seitenband, für die HF-Frequenz der Signale
    @Published public var rigDialHz: Int?
    @Published public var rigIsLSB: Bool?
    /// Markierungen der Signale im Wasserfall
    @Published public var marks: [WaterfallChannelMark] = []
    /// Von Hand gewählte NF-Frequenz (Klick im Wasserfall) und Zähler, damit die Liste die nächste Station wählt
    @Published public private(set) var focusHz: Double = 1000
    @Published public private(set) var focusRevision = 0

    public init() {
        let d = UserDefaults.standard
        mode = d.string(forKey: "skimMode").flatMap(SkimMode.init(rawValue:)) ?? .cw
        cwBand = d.string(forKey: "skimCWBand").flatMap(SkimBand.init(rawValue:)) ?? .free
        pskBand = d.string(forKey: "skimPSKBand").flatMap(PSKBand.init(rawValue:)) ?? .free
        let t = d.double(forKey: "skimThreshold")
        thresholdDB = (4...16).contains(t) ? t : 8
        minSNR = d.object(forKey: "skimMinSNR") as? Double ?? 3
        onlyCalls = d.object(forKey: "skimOnlyCalls") as? Bool ?? false
        holdMinutes = d.object(forKey: "skimHold") as? Double ?? 10
    }

    /// Dial des gewählten Bandes (nil = frei)
    public var bandDialHz: Int? { mode == .cw ? cwBand.dialHz : pskBand.dialHz }

    /// Dial für die HF-Frequenz: das Funkgerät, sonst das gewählte Band
    public var dialHz: Int? { rigDialHz ?? bandDialHz }
}

extension SkimmerSettingsStore: TuningTarget {
    public var centerHz: Double { focusHz }
    public var tones: (mark: Double, space: Double) { (focusHz, focusHz) }
    public var markerBandwidth: Double { mode == .cw ? 100 : mode.baud }
    public func setCenter(_ hz: Double) {
        focusHz = min(max(hz, 150), 3500).rounded()
        focusRevision += 1
    }
    public var markerStyle: WaterfallMarkerStyle { .channels(marks) }
}

// MARK: - Decoder

/// Skimmer-Engine als 8-kHz-Senke an der Pipeline
public final class SkimmerDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var texts: [(id: Int, text: String)]
        public var activated: [Int]
        public var closed: [Int]
        public var channels: [SkimChannelInfo]
        /// Audiozeit der Engine in Sekunden
        public var time: Double
        public var trackCount: Int
        public var inputDB: Double
    }

    private let pipeline: AudioPipeline
    private var engine = SkimmerEngine(mode: .cw)
    private var mode = SkimMode.cw
    private var enabled = false
    private let lock = OSAllocatedUnfairLock()
    private var texts: [(id: Int, text: String)] = []
    private var activated: [Int] = []
    private var closed: [Int] = []
    private var channelsNow: [SkimChannelInfo] = []
    private var timeNow = 0.0
    private var tracksNow = 0
    private var inputDBNow = -120.0
    private var meanSquare = 0.0
    private var samplesSinceSnapshot = 0
    private var thresholdDB = 8.0

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        wire(engine)
        pipeline.addSink { [weak self] samples in self?.consume(samples) }
    }

    private func wire(_ e: SkimmerEngine) {
        e.onText = { [weak self] id, text, _ in self?.lock.withLockUnchecked { self?.texts.append((id, text)) } }
        e.onActivated = { [weak self] id in self?.lock.withLockUnchecked { self?.activated.append(id) } }
        e.onClosed = { [weak self] id in self?.lock.withLockUnchecked { self?.closed.append(id) } }
    }

    /// Betriebsart oder Empfindlichkeit ändern (neue Betriebsart: neue Engine)
    public func configure(mode: SkimMode, thresholdDB: Double) {
        pipeline.perform { [self] in
            self.thresholdDB = thresholdDB
            if mode != self.mode {
                self.mode = mode
                engine = SkimmerEngine(mode: mode)
                wire(engine)
                lock.withLockUnchecked { texts.removeAll(); activated.removeAll(); closed.removeAll(); channelsNow.removeAll(); tracksNow = 0 }
            }
            var c = engine.config
            c.thresholdDB = thresholdDB
            engine.config = c
        }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            enabled = on
            if !on {
                engine.reset()
                lock.withLockUnchecked { channelsNow.removeAll(); tracksNow = 0 }
            }
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { texts.removeAll(); activated.removeAll(); closed.removeAll() }
            return Output(texts: texts, activated: activated, closed: closed, channels: channelsNow, time: timeNow, trackCount: tracksNow, inputDB: inputDBNow)
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled else { return }
        engine.process(samples)
        var sum = 0.0
        for x in samples { sum += Double(x) * Double(x) }
        let k = min(1.0, Double(samples.count) / (0.3 * 8000))
        if !samples.isEmpty { meanSquare += k * (sum / Double(samples.count) - meanSquare) }
        samplesSinceSnapshot += samples.count
        guard samplesSinceSnapshot >= 2000 else { return }          // 4 × je Sekunde
        samplesSinceSnapshot = 0
        let channels = engine.channels()
        let time = engine.time, tracks = engine.trackCount
        let db = meanSquare > 1e-12 ? max(-120, 10 * log10(meanSquare)) : -120
        lock.withLockUnchecked {
            channelsNow = channels
            timeNow = time
            tracksNow = tracks
            inputDBNow = db
        }
    }
}

// MARK: - Controller

@MainActor
public final class SkimmerController: ObservableObject {
    public let decoder: SkimmerDecoder
    public let logger = DecodeLogger(mode: "SKIMMER")
    @Published public private(set) var stations: [SkimStation] = []
    @Published public private(set) var spots: [SkimSpot] = []
    @Published public private(set) var trackCount = 0
    @Published public private(set) var inputDB = -120.0
    @Published public var selection: Int?
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "skimLogEnabled") }
    }
    public var rigDescription: String? {
        didSet { if rigDescription != oldValue { markSession() } }
    }

    public static let maxSpots = 500
    private let settings: SkimmerSettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var calls: [Int: CallsignLog] = [:]
    private var lastSpot: [String: (date: Date, hz: Double)] = [:]
    /// Abbildung der Audiozeit der Engine auf Uhrzeiten
    private var anchor: (engine: Double, date: Date)?

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: SkimmerSettingsStore) {
        self.settings = settings
        decoder = SkimmerDecoder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "skimLogEnabled") as? Bool ?? true
        decoder.configure(mode: settings.mode, thresholdDB: settings.thresholdDB)
        markSession()
        // Betriebsart und Schwelle gehen an die Engine; bei neuer Betriebsart beginnt die Liste von vorn
        settings.$mode.combineLatest(settings.$thresholdDB)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] mode, threshold in
                guard let self else { return }
                if mode != self.appliedMode {
                    self.stations.removeAll()
                    self.calls.removeAll()
                    self.selection = nil
                    self.appliedMode = mode
                }
                self.decoder.configure(mode: mode, thresholdDB: threshold)
            }
            .store(in: &cancellables)
        // Kopfzeile des Logs: Betriebsart, Band, Dial
        settings.$mode.combineLatest(settings.$cwBand, settings.$pskBand, settings.$thresholdDB)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.markSession() }
            .store(in: &cancellables)
        appliedMode = settings.mode
        // Klick im Wasserfall: die nächste Station wählen
        settings.$focusRevision
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.selectNearest(to: self.settings.centerHz)
            }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private var appliedMode: SkimMode = .cw

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
    }

    public func clear() {
        stations.removeAll()
        spots.removeAll()
        calls.removeAll()
        lastSpot.removeAll()
        selection = nil
    }

    public func markSession() {
        var h = "SKIMMER · \(settings.mode.name) · Schwelle \(Int(settings.thresholdDB)) dB"
        if let d = settings.dialHz { h += String(format: " · Dial %.3f MHz", Double(d) / 1_000_000).replacingOccurrences(of: ".", with: ",") }
        if let rig = rigDescription { h += " · \(rig)" }
        logger.markSession(h)
    }

    private func poll() {
        let out = decoder.takeOutput()
        inputDB = out.inputDB
        trackCount = out.trackCount
        ingest(texts: out.texts, activated: out.activated, closed: out.closed, channels: out.channels, engineTime: out.time, now: Date())
    }

    // MARK: Auswertung (auch für Tests)

    /// Ergebnisse der Engine einarbeiten: neue Stationen, Text, Rufzeichen, Spots, Aufräumen
    public func ingest(texts: [(id: Int, text: String)], activated: [Int], closed: [Int], channels: [SkimChannelInfo], engineTime: Double, now: Date) {
        anchor = (engineTime, now)
        func date(_ engine: Double) -> Date { now.addingTimeInterval(-(engineTime - engine)) }
        let info = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) })
        for id in activated {
            guard let c = info[id], !stations.contains(where: { $0.id == id }) else { continue }
            stations.append(SkimStation(id: id, mode: c.mode, audioHz: c.frequencyHz, snrDB: c.snrDB, speed: c.speed, firstHeard: date(c.born), lastHeard: date(c.lastActive)))
            calls[id] = CallsignLog()
        }
        for (id, text) in texts {
            guard let i = stations.firstIndex(where: { $0.id == id }) else { continue }
            stations[i].text += text
            if stations[i].text.count > 240 { stations[i].text.removeFirst(stations[i].text.count - 240) }
            stations[i].characters += text.count
            calls[id, default: CallsignLog()].feed(text, at: now)
            let tail = stations[i].text.suffix(60).uppercased()
            stations[i].isCQ = tail.contains("CQ")
            updateCall(at: i, now: now)
        }
        for i in stations.indices {
            if let c = info[stations[i].id] {
                stations[i].audioHz = c.frequencyHz
                stations[i].snrDB = c.snrDB
                stations[i].speed = c.speed
                stations[i].lastHeard = max(stations[i].lastHeard, date(c.lastActive))
                stations[i].isLive = true
            }
        }
        for id in closed {
            if let i = stations.firstIndex(where: { $0.id == id }) { stations[i].isLive = false }
        }
        // Stationen, die die Engine nicht mehr kennt (neue Betriebsart, Engine zurückgesetzt), und zu alte Erinnerungen
        let hold = settings.holdMinutes * 60
        stations.removeAll { s in
            let gone = !channels.contains(where: { $0.id == s.id })
            return (gone && !s.isLive && now.timeIntervalSince(s.lastHeard) > hold) || (gone && s.isLive && channels.isEmpty && engineTime == 0)
        }
        for id in Array(calls.keys) where !stations.contains(where: { $0.id == id }) { calls.removeValue(forKey: id) }
        if let sel = selection, !stations.contains(where: { $0.id == sel }) { selection = nil }
        stations.sort { $0.audioHz < $1.audioHz }
        publishMarks(now: now)
    }

    /// Verlässliches Rufzeichen des Kanals: nach CQ oder DE gehört oder mehrfach; bei mehreren das häufigste, dann das letzte.
    /// Jedes verlässliche Rufzeichen, das mit diesem Text wieder kam, ergibt einen Spot (je Station höchstens alle 10 Minuten).
    private func updateCall(at i: Int, now: Date) {
        guard let log = calls[stations[i].id] else { return }
        let reliable = log.entries.values.filter { $0.announced || $0.count >= 2 }
        guard let best = reliable.max(by: { ($0.count, $0.last) < ($1.count, $1.last) }) else { return }
        if stations[i].call != best.call {
            stations[i].call = best.call
            stations[i].dxcc = DXCCDatabase.shared.lookup(best.call)
        }
        for entry in reliable.sorted(by: { $0.call < $1.call }) where entry.last == now {
            addSpot(for: stations[i], entry: entry, now: now)
        }
    }

    private func addSpot(for s: SkimStation, entry: CallsignLog.Entry, now: Date) {
        let key = s.mode.rawValue + entry.call
        // dieselbe Station auf ungefähr derselben Frequenz höchstens alle 10 Minuten (nach einem QSY sofort wieder)
        if let last = lastSpot[key], now.timeIntervalSince(last.date) < 600, abs(last.hz - s.audioHz) < 300 { return }
        lastSpot[key] = (now, s.audioHz)
        let spot = SkimSpot(time: now, call: entry.call, audioHz: s.audioHz, rfHz: s.rfHz(dialHz: settings.dialHz, lsb: settings.rigIsLSB ?? false),
                            snrDB: s.snrDB, speed: s.speed, mode: s.mode, kind: entry.context.contains("CQ") ? "CQ" : "DE", dxcc: s.dxcc)
        spots.append(spot)
        if spots.count > Self.maxSpots { spots.removeFirst(spots.count - Self.maxSpots) }
        if logEnabled { logger.append(Self.logLine(spot) + "\n", now: now) }
    }

    /// „14020.3 DL1ABC CW 18 WPM 24 dB CQ 15:24:31Z“ (wie die Zeilen des Reverse Beacon Network)
    nonisolated public static func logLine(_ s: SkimSpot) -> String {
        let freq = s.rfHz.map { String(format: "%.1f", $0 / 1000) } ?? String(format: "NF %.0f Hz", s.audioHz)
        let speed = s.mode == .cw ? String(format: "%.0f WPM", s.speed) : String(format: "%.0f BD", s.speed)
        return "\(freq)  \(s.call)  \(s.mode.name)  \(speed)  \(Int(s.snrDB.rounded())) dB  \(s.kind)  \(utc.string(from: s.time))Z"
    }

    /// Markierungen im Wasserfall: je lebendem Signal eine Linie, abgedunkelt wenn es seit 5 s nichts gesendet hat
    private func publishMarks(now: Date) {
        let marks = stations.filter(\.isLive).map { s in
            WaterfallChannelMark(frequency: s.audioHz, label: s.call ?? "", selected: s.id == selection, active: now.timeIntervalSince(s.lastHeard) < 5)
        }
        if marks != settings.marks { settings.marks = marks }
    }

    // MARK: Sichten

    /// Stationen nach den Filtern der Einstellungen
    public var visibleStations: [SkimStation] {
        stations.filter { $0.snrDB >= settings.minSNR && (!settings.onlyCalls || $0.call != nil) }
    }

    /// Gehörte Stationen mit Rufzeichen für die Karte
    public var heard: [HeardStation] {
        stations.compactMap { s in
            guard let call = s.call else { return nil }
            return HeardStation(call: call, dxcc: s.dxcc, snr: Int(s.snrDB.rounded()), time: s.lastHeard, text: String(s.text.suffix(80)), isCQ: s.isCQ,
                                count: 1, rfHz: s.rfHz(dialHz: settings.dialHz, lsb: settings.rigIsLSB ?? false))
        }
    }

    /// Wählt die Station, die der NF-Frequenz am nächsten liegt (Klick im Wasserfall)
    public func selectNearest(to hz: Double) {
        guard let s = stations.min(by: { abs($0.audioHz - hz) < abs($1.audioHz - hz) }), abs(s.audioHz - hz) < 60 else { return }
        selection = s.id
    }
}
