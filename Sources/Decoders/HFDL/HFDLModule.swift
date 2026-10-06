// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os

// MARK: - Kanäle

/// KW-Bänder, in die die Kanalliste gegliedert wird
public enum HFDLBand: Int, CaseIterable, Identifiable, Sendable {
    case b2, b3, b4, b5, b6, b8, b10, b11, b13, b15, b17, b21

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .b2: return "2 MHz"
        case .b3: return "3 MHz"
        case .b4: return "4 MHz"
        case .b5: return "5 MHz"
        case .b6: return "6 MHz"
        case .b8: return "8 MHz"
        case .b10: return "10 MHz"
        case .b11: return "11 MHz"
        case .b13: return "13 MHz"
        case .b15: return "15 MHz"
        case .b17: return "17 MHz"
        case .b21: return "21 MHz"
        }
    }

    public static func of(kHz: Double) -> HFDLBand {
        switch kHz {
        case ..<3_000: return .b2
        case ..<4_000: return .b3
        case ..<5_000: return .b4
        case ..<6_000: return .b5
        case ..<8_000: return .b6
        case ..<10_000: return .b8
        case ..<11_000: return .b10
        case ..<13_000: return .b11
        case ..<15_000: return .b13
        case ..<17_000: return .b15
        case ..<20_000: return .b17
        default: return .b21
        }
    }
}

public enum HFDLChannels {
    /// Voreinstellung: 8942 kHz (Shannon) wird in Europa meist gut gehört
    public static let defaultKHz = 8942.0

    public static func presetID(_ kHz: Double) -> String { "f\(Int(kHz.rounded()))" }

    public static func kHz(presetID: String) -> Double? {
        guard presetID.hasPrefix("f"), let v = Double(presetID.dropFirst()), HFDLStations.channels.contains(where: { abs($0.kHz - v) < 0.5 }) else { return nil }
        return v
    }

    public static var allPresetIDs: [String] {
        let all = HFDLStations.channels.map { presetID($0.kHz) }
        return [presetID(defaultKHz)] + all.filter { $0 != presetID(defaultKHz) }
    }

    public static func label(_ kHz: Double) -> String {
        kHz == kHz.rounded() ? String(Int(kHz)) : String(format: "%.1f", kHz).replacingOccurrences(of: ".", with: ",")
    }

    /// Kanäle eines Bandes mit den Stationen, die sie nutzen
    public static func channels(in band: HFDLBand) -> [(kHz: Double, stations: [HFDLStation])] {
        HFDLStations.channels.filter { HFDLBand.of(kHz: $0.kHz) == band }
    }

    public static var usedBands: [HFDLBand] { HFDLBand.allCases.filter { !channels(in: $0).isEmpty } }
}

// MARK: - Einstellungen

@MainActor
public final class HFDLSettingsStore: ObservableObject {
    /// Zugewiesene Frequenz des Kanals in kHz (Dial im USB; das Signal liegt bei 1440 Hz im NF)
    @Published public var frequencyKHz: Double { didSet { UserDefaults.standard.set(frequencyKHz, forKey: "hfdlFrequencyKHz") } }
    /// Meldungen vom Boden zum Flugzeug zeigen
    @Published public var showUplink: Bool { didSet { UserDefaults.standard.set(showUplink, forKey: "hfdlUplink") } }
    /// Squitter (Kennung der Bodenstationen, alle 32 s) in der Liste zeigen
    @Published public var showSquitters: Bool { didSet { UserDefaults.standard.set(showSquitters, forKey: "hfdlSquitters") } }
    /// Nur Meldungen mit Inhalt (ACARS, Ort) zeigen, keine Anmeldungen und Quittungen
    @Published public var onlyContent: Bool { didSet { UserDefaults.standard.set(onlyContent, forKey: "hfdlOnlyContent") } }

    public init() {
        let d = UserDefaults.standard
        let f = d.double(forKey: "hfdlFrequencyKHz")
        frequencyKHz = f > 0 && HFDLStations.channels.contains(where: { abs($0.kHz - f) < 0.5 }) ? f : HFDLChannels.defaultKHz
        showUplink = d.object(forKey: "hfdlUplink") as? Bool ?? true
        showSquitters = d.object(forKey: "hfdlSquitters") as? Bool ?? false
        onlyContent = d.object(forKey: "hfdlOnlyContent") as? Bool ?? false
    }

    public var stationsOnChannel: [HFDLStation] { HFDLStations.stations(on: frequencyKHz) }
}

extension HFDLSettingsStore: TuningTarget {
    public var centerHz: Double { HFDLPHY.subcarrierHz }
    public var tones: (mark: Double, space: Double) { (HFDLPHY.subcarrierHz - 1000, HFDLPHY.subcarrierHz + 1000) }
    public var markerBandwidth: Double { 2100 }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .band("HFDL · PSK 1800 Bd, Träger bei 1440 Hz") }
}

// MARK: - Flugzeuge, Bodenstationen

/// Ein Punkt auf dem Weg eines Flugzeugs
public struct HFDLTrackPoint: Equatable, Sendable {
    public var point: GeoPoint
    public var date: Date
}

/// Was über ein Flugzeug aus den Rahmen bekannt ist
public struct HFDLAircraft: Identifiable, Equatable, Sendable {
    public var id: String
    public var icao: UInt32?
    public var registration: String?
    public var flight: String?
    public var firstHeard: Date
    public var lastHeard: Date
    public var frames = 0
    public var lastTitle = ""
    public var lastText = ""
    public var lastStation: Int?
    public var lastFreqKHz: Double?
    public var position: GeoPoint?
    public var positionDate: Date?
    public var positionTime: String?
    public var track: [HFDLTrackPoint] = []
    public var rejectedPositions = 0
    private var suspect: GeoPoint?

    public static let maxTrack = 300
    static let maxSpeedKmh = 1500.0
    static let slackKm = 60.0

    public init(id: String, firstHeard: Date, lastHeard: Date) {
        self.id = id
        self.firstHeard = firstHeard
        self.lastHeard = lastHeard
    }

    public var icaoHex: String? { icao.map { String(format: "%06X", $0) } }

    public var displayName: String {
        if let f = flight, !f.isEmpty { return f }
        if let r = registration, !r.isEmpty { return r }
        return icaoHex ?? id
    }

    /// Ort einarbeiten; ein Sprung, den kein Flugzeug schafft, wird erst beim zweiten Bericht an derselben Stelle geglaubt
    @discardableResult
    public mutating func addPosition(_ p: GeoPoint, time: String?, at date: Date) -> Bool {
        if let last = track.last {
            let km = Geo.distanceKm(last.point, p)
            let hours = max(0, date.timeIntervalSince(last.date)) / 3600
            if km > Self.slackKm + Self.maxSpeedKmh * hours {
                if let s = suspect, Geo.distanceKm(s, p) < 50 {
                    track.removeAll()
                    suspect = nil
                } else {
                    suspect = p
                    rejectedPositions += 1
                    return false
                }
            }
        }
        suspect = nil
        position = p
        positionDate = date
        positionTime = time
        if let last = track.last, Geo.distanceKm(last.point, p) < 0.3 {
            track[track.count - 1].date = date
        } else {
            track.append(HFDLTrackPoint(point: p, date: date))
            if track.count > Self.maxTrack { track.removeFirst(track.count - Self.maxTrack) }
        }
        return true
    }

    public var headingDeg: Double? {
        guard track.count >= 2 else { return nil }
        let end = track[track.count - 1].point
        for p in track.dropLast().reversed() where Geo.distanceKm(p.point, end) >= 5 { return Geo.bearing(from: p.point, to: end) }
        return nil
    }
}

/// Letzter Stand einer Bodenstation aus ihren Squittern
public struct HFDLStationStatus: Equatable, Sendable {
    public var lastHeard: Date
    public var utcSync: Bool
    public var frequenciesInUseKHz: [Double]
    /// Auf welchem Kanal der Squitter gehört wurde
    public var heardOnKHz: Double
    public var tableVersion: Int
    public var count = 1
}

// MARK: - Kartenaufbereitung

public enum HFDLMapBuilder {
    public static func content(aircraft: [HFDLAircraft], stations: [Int: HFDLStationStatus], home: GeoPoint?, now: Date,
                               maxAge: TimeInterval = 3 * 3600) -> MapContent {
        var markers: [MapMarker] = []
        var lines: [MapLine] = []
        for s in HFDLStations.all {
            let st = stations[s.id]
            var details = [Geo.format(s.point), "Frequenzen: " + s.frequenciesKHz.map { HFDLChannels.label($0) }.joined(separator: ", ") + " kHz"]
            if let h = home {
                let km = Geo.distanceKm(h, s.point), b = Geo.bearing(from: h, to: s.point)
                details.append("\(Geo.formatKm(km)) \(Geo.compass(b)) (\(Int(b.rounded()))°)")
            }
            var subtitle = "HFDL-Bodenstation \(s.id)"
            var tone: MapTone = .dim
            if let st {
                let age = now.timeIntervalSince(st.lastHeard)
                subtitle += " · Squitter vor \(age < 90 ? "\(Int(age)) s" : "\(Int(age / 60)) min") auf \(HFDLChannels.label(st.heardOnKHz)) kHz"
                if !st.frequenciesInUseKHz.isEmpty { details.append("In Benutzung: " + st.frequenciesInUseKHz.map { HFDLChannels.label($0) }.joined(separator: ", ") + " kHz") }
                if age < 600 { tone = .info }
            }
            markers.append(MapMarker(id: "gs-\(s.id)", coordinate: s.point, title: s.shortName, subtitle: subtitle, details: details,
                                     symbol: "antenna.radiowaves.left.and.right", tone: tone, heardAt: st?.lastHeard))
        }
        for a in aircraft.sorted(by: { $0.lastHeard > $1.lastHeard }) {
            guard let pos = a.position, let at = a.positionDate, now.timeIntervalSince(at) <= maxAge else { continue }
            let age = now.timeIntervalSince(at)
            var details = [Geo.format(pos)]
            if let h = home {
                let km = Geo.distanceKm(h, pos), b = Geo.bearing(from: h, to: pos)
                details.append("\(Geo.formatKm(km)) \(Geo.compass(b)) (\(Int(b.rounded()))°)")
            }
            if let h = a.headingDeg { details.append("Kurs \(Int(h.rounded()))°") }
            if let t = a.positionTime { details.append("Position von \(t) UTC") }
            if let r = a.registration { details.append("Kennzeichen \(r)") }
            if let x = a.icaoHex { details.append("ICAO-Adresse \(x)") }
            if let s = a.lastStation.flatMap({ HFDLStations.station($0) }) {
                details.append("Verbindung zu \(s.name)" + (a.lastFreqKHz.map { " auf \(HFDLChannels.label($0)) kHz" } ?? ""))
                if age < 1800 { lines.append(MapLine(id: "link-" + a.id, points: [pos, s.point], tone: .dim, geodesic: true)) }
            }
            if !a.lastText.isEmpty { details.append(String(a.lastText.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(120))) }
            let points = a.track.filter { now.timeIntervalSince($0.date) <= maxAge }.map(\.point)
            let ageText = age < 90 ? "\(Int(age)) s" : age < 5400 ? "\(Int(age / 60)) min" : "\(Int(age / 3600)) h"
            markers.append(MapMarker(id: "ac-" + a.id, coordinate: pos, title: a.displayName,
                                     subtitle: "vor \(ageText) · \(a.frames) Rahmen", details: details, symbol: "airplane",
                                     tone: age > 1800 ? .dim : .normal, heardAt: at, track: points.count > 1 ? points : [], headingDeg: a.headingDeg))
        }
        return MapContent(markers: markers, lines: lines, home: home,
                          emptyHint: "Noch keine Flugzeugposition: Frequenzdaten, Leistungsdaten und Positionsmeldungen der Flugzeuge erscheinen hier")
    }
}

// MARK: - Decoder

public final class HFDLDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var frames: [(frame: HFDLRawFrame, time: Date)]
        public var inBurst: Bool
        public var stats: HFDLReceiver.Statistics
    }

    public static let sampleRate = HFDLPHY.sampleRate

    private let pipeline: AudioPipeline
    private let receiver = HFDLReceiver(sampleRate: HFDLDecoder.sampleRate)
    private var enabled = false
    private let lock = OSAllocatedUnfairLock()
    private var pending: [(frame: HFDLRawFrame, time: Date)] = []
    private var burst = false
    private var stats = HFDLReceiver.Statistics()

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
            return Output(frames: pending, inBurst: burst, stats: stats)
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled else { return }
        var found: [(HFDLRawFrame, Date)] = []
        let now = Date()
        receiver.process(samples) { found.append(($0, now)) }
        let active = receiver.inBurst
        let st = receiver.stats
        lock.withLockUnchecked {
            pending.append(contentsOf: found.map { (frame: $0.0, time: $0.1) })
            burst = active
            stats = st
        }
    }
}

// MARK: - Controller

@MainActor
public final class HFDLController: ObservableObject {
    public let decoder: HFDLDecoder
    public let logger = DecodeLogger(mode: "HFDL")
    @Published public private(set) var events: [HFDLEvent] = []
    @Published public private(set) var aircraft: [String: HFDLAircraft] = [:]
    @Published public private(set) var stations: [Int: HFDLStationStatus] = [:]
    @Published public private(set) var inBurst = false
    @Published public private(set) var frameCount = 0
    @Published public private(set) var burstCount = 0
    @Published public private(set) var lastDate: Date?
    @Published public private(set) var lastSNR: Double?
    @Published public private(set) var lastFreqErrorHz: Double?
    @Published public private(set) var rateCounts: [Int: Int] = [:]
    @Published public private(set) var parseStats = HFDLParseStats()
    @Published public var logEnabled: Bool { didSet { UserDefaults.standard.set(logEnabled, forKey: "hfdlLogEnabled") } }
    public var rigDescription: String? { didSet { if rigDescription != oldValue { markSession() } } }

    public static let maxEvents = 1500
    private let settings: HFDLSettingsStore
    private var cache = HFDLAircraftCache()
    private var icaoByRegistration: [String: UInt32] = [:]
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: HFDLSettingsStore) {
        self.settings = settings
        decoder = HFDLDecoder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "hfdlLogEnabled") as? Bool ?? true
        markSession()
        settings.$frequencyKHz
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.markSession() }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func setActive(_ active: Bool) { decoder.setEnabled(active) }

    public func clear() {
        events.removeAll()
        aircraft.removeAll()
        stations.removeAll()
        cache = HFDLAircraftCache()
        icaoByRegistration.removeAll()
    }

    public func markSession() {
        var h = "HFDL · \(HFDLChannels.label(settings.frequencyKHz)) kHz USB · PSK 1800 Bd"
        if let rig = rigDescription { h += " · \(rig)" }
        logger.markSession(h)
    }

    private func poll() {
        let out = decoder.takeOutput()
        inBurst = out.inBurst
        burstCount = out.stats.bursts
        for item in out.frames { ingest(frame: item.frame, at: item.time) }
    }

    /// Rahmen aufnehmen (Frequenz des Kanals aus den Einstellungen)
    public func ingest(frame: HFDLRawFrame, at now: Date = Date(), freqKHz: Double? = nil) {
        let f = freqKHz ?? settings.frequencyKHz
        let result = HFDLProtocol.parse(frame, freqKHz: f, time: now, cache: &cache, stats: &parseStats)
        frameCount += 1
        lastDate = now
        lastSNR = frame.snrDB
        lastFreqErrorHz = frame.freqErrorHz
        rateCounts[frame.bitRate, default: 0] += 1
        for e in result { ingest(event: e) }
    }

    /// Ereignis aufnehmen: Liste, Flugzeugtabelle, Bodenstationen, Log
    public func ingest(event e: HFDLEvent) {
        events.append(e)
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        if e.kind == .squitter { noteSquitter(e) }
        updateAircraft(e)
        if logEnabled { logger.append(Self.logLine(e) + "\n", now: e.time) }
    }

    private func noteSquitter(_ e: HFDLEvent) {
        guard let q = e.squitter else { return }
        for (i, s) in q.stations.enumerated() {
            // Von der ersten Station kommt der Squitter selbst, die beiden anderen sind Angaben über Nachbarn (zweiter Hand)
            var st = stations[s.id] ?? HFDLStationStatus(lastHeard: e.time, utcSync: s.utcSync, frequenciesInUseKHz: s.frequenciesKHz,
                                                          heardOnKHz: e.freqKHz, tableVersion: q.tableVersion, count: 0)
            st.lastHeard = e.time
            st.utcSync = s.utcSync
            st.frequenciesInUseKHz = s.frequenciesKHz
            st.tableVersion = q.tableVersion
            if i == 0 { st.heardOnKHz = e.freqKHz; st.count += 1 }
            stations[s.id] = st
        }
    }

    private func updateAircraft(_ e: HFDLEvent) {
        guard e.kind != .squitter else { return }
        let reg = e.registration
        var icao = e.icao
        if icao == nil, let r = reg { icao = icaoByRegistration[r] }
        if let ic = icao, let r = reg { icaoByRegistration[r] = ic }
        let hasIdentity = icao != nil || reg != nil || (e.flightID?.isEmpty == false)
        guard hasIdentity else { return }
        let key = icao.map { String(format: "%06X", $0) } ?? reg ?? e.flightID ?? ""
        // Eintrag unter Kennzeichen oder Flugnummer zusammenführen, wenn jetzt die ICAO-Adresse bekannt ist
        var a = aircraft[key] ?? {
            var merged: HFDLAircraft?
            if icao != nil {
                for alt in [reg, e.flightID].compactMap({ $0 }) {
                    if let old = aircraft[alt] { merged = old; aircraft[alt] = nil; break }
                }
            }
            var n = merged ?? HFDLAircraft(id: key, firstHeard: e.time, lastHeard: e.time)
            n.id = key
            return n
        }()
        a.lastHeard = e.time
        a.frames += 1
        if let ic = icao { a.icao = ic }
        if let r = reg, !r.isEmpty { a.registration = r }
        if let f = e.flightID, !f.isEmpty { a.flight = f }
        a.lastTitle = e.title
        a.lastFreqKHz = e.freqKHz
        if let gs = e.station { a.lastStation = gs }
        if let m = e.acars, !m.isEmpty { a.lastText = m.text }
        if let p = e.position { a.addPosition(p, time: e.positionTime, at: e.time) }
        aircraft[key] = a
    }

    // MARK: Anzeige

    /// Ereignisse nach den Filtern der Einstellungen
    public var visible: [HFDLEvent] {
        events.filter { e in
            if e.kind == .squitter { return settings.showSquitters }
            if !settings.showUplink && e.uplink { return false }
            if settings.onlyContent {
                let hasContent = (e.acars.map { !$0.isEmpty } ?? false) || e.position != nil
                if !hasContent { return false }
            }
            return true
        }
    }

    public func mapContent(home: GeoPoint?, now: Date = Date()) -> MapContent {
        HFDLMapBuilder.content(aircraft: Array(aircraft.values), stations: stations, home: home, now: now)
    }

    /// Anzeigename des Flugzeugs eines Ereignisses
    public func label(for e: HFDLEvent) -> String {
        if let f = e.flightID, !f.isEmpty { return f }
        if let r = e.registration, !r.isEmpty { return r }
        if let x = e.icaoHex { return x }
        if let id = e.aircraftID { return id == 255 ? "alle" : "AC \(id)" }
        return "–"
    }

    /// „08:15:02  8942,0  300 S  ↓  Riverhead  AV4820 N724AV  Daten  Label Q0  Text“
    nonisolated public static func logLine(_ e: HFDLEvent) -> String {
        var s = utc.string(from: e.time) + "  " + HFDLChannels.label(e.freqKHz) + "  " + String(e.bitRate) + (e.doubleSlot ? "D" : "S")
        s += "  " + (e.uplink ? "↑" : "↓")
        if let gs = e.station { s += "  " + (HFDLStations.station(gs)?.shortName ?? "GS\(gs)") }
        if e.kind != .squitter {
            s += "  " + (e.flightID ?? "-") + " " + (e.registration ?? "-") + " " + (e.icaoHex ?? "-")
        }
        s += "  " + e.title
        if let m = e.acars {
            s += "  Label " + m.label
            if !m.text.isEmpty { s += "  " + m.text.replacingOccurrences(of: "\n", with: " ⏎ ") }
        }
        if let p = e.position { s += "  " + Geo.format(p) + (e.positionTime.map { " (\($0) UTC)" } ?? "") }
        return s
    }
}
