// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os

// MARK: - Kanäle

/// APRS-Frequenzen (FM, 1200 Bd). Die Region bestimmt die Frequenz, nicht den Ort des Empfangs.
public enum APRSChannel: String, CaseIterable, Identifiable, Codable, Sendable {
    case eu, na, iss, au, jp, free

    public var id: String { rawValue }

    public var frequencyHz: Double? {
        switch self {
        case .eu:   return 144_800_000
        case .na:   return 144_390_000
        case .iss:  return 145_825_000
        case .au:   return 145_175_000
        case .jp:   return 144_640_000
        case .free: return nil
        }
    }

    public var label: String {
        switch self {
        case .eu:   return "144,800"
        case .na:   return "144,390"
        case .iss:  return "145,825"
        case .au:   return "145,175"
        case .jp:   return "144,640"
        case .free: return "frei"
        }
    }

    /// Kurzname für den Knopf
    public var name: String {
        switch self {
        case .eu:   return "EU"
        case .na:   return "NA"
        case .iss:  return "ISS"
        case .au:   return "AU"
        case .jp:   return "JP"
        case .free: return "frei"
        }
    }

    public var note: String {
        switch self {
        case .eu:   return "Europa, Afrika, Naher Osten: 144,800 MHz"
        case .na:   return "Nord- und Südamerika: 144,390 MHz"
        case .iss:  return "ISS und Satelliten (Digipeater): 145,825 MHz, Doppler ± 3 kHz beachten"
        case .au:   return "Australien, Neuseeland: 145,175 MHz"
        case .jp:   return "Japan: 144,640 MHz"
        case .free: return "Funkgerät nicht abstimmen"
        }
    }
}

// MARK: - Einstellungen

@MainActor
public final class APRSSettingsStore: ObservableObject {
    public static let offsetRange: ClosedRange<Double> = -250...250

    @Published public var channel: APRSChannel { didSet { UserDefaults.standard.set(channel.rawValue, forKey: "aprsChannel") } }
    /// Abweichung der Töne in Hz (Mitte 1700 Hz): Klick im Wasserfall setzt sie
    @Published public private(set) var offsetHz: Double
    @Published public var repairBits: Bool { didSet { UserDefaults.standard.set(repairBits, forKey: "aprsRepair") } }
    /// Vorverzerrung für de-emphasiertes Audio: automatisch (beide Wege), aus oder an
    @Published public var emphasis: AFSKReceiver.Emphasis { didSet { UserDefaults.standard.set(emphasis.rawValue, forKey: "aprsEmphasis") } }
    @Published public var slicers: Int { didSet { UserDefaults.standard.set(slicers, forKey: "aprsSlicers") } }
    /// Wie lange Stationen auf der Karte bleiben (Stunden; 0 = alle)
    @Published public var mapHours: Double { didSet { UserDefaults.standard.set(mapHours, forKey: "aprsMapHours") } }

    public init() {
        let d = UserDefaults.standard
        channel = d.string(forKey: "aprsChannel").flatMap(APRSChannel.init(rawValue:)) ?? .eu
        offsetHz = Self.offsetRange.contains(d.double(forKey: "aprsOffsetHz")) ? d.double(forKey: "aprsOffsetHz") : 0
        repairBits = d.object(forKey: "aprsRepair") as? Bool ?? true
        emphasis = d.string(forKey: "aprsEmphasis").flatMap(AFSKReceiver.Emphasis.init(rawValue:)) ?? .auto
        slicers = d.object(forKey: "aprsSlicers") as? Int ?? 7
        mapHours = d.object(forKey: "aprsMapHours") as? Double ?? 6
    }

    public var centerHz: Double { 1700 + offsetHz }

    public func setCenter(_ hz: Double) {
        offsetHz = min(max(hz - 1700, Self.offsetRange.lowerBound), Self.offsetRange.upperBound).rounded()
        UserDefaults.standard.set(offsetHz, forKey: "aprsOffsetHz")
    }

    var options: AFSKDemodulator.Options {
        var o = AFSKDemodulator.Options()
        o.slicers = slicers
        o.repairBits = repairBits
        o.centerOffsetHz = offsetHz
        return o
    }
}

extension APRSSettingsStore: TuningTarget {
    public var tones: (mark: Double, space: Double) { (centerHz - 500, centerHz + 500) }
    public var markerBandwidth: Double { 1300 }
}

// MARK: - Stationen

/// Eine Station (oder ein Objekt) in der Stationsliste
public struct APRSStation: Identifiable, Equatable, Sendable {
    public var id: String
    public var call: String
    /// Absender (bei Objekten: wer es gesendet hat)
    public var source: String
    public var isObject: Bool
    public var killed = false
    public var symbol: APRSSymbol?
    public var position: GeoPoint?
    /// Bisheriger Weg (älteste Position zuerst) und wann jede Position empfangen wurde
    public var track: [GeoPoint] = []
    public var trackTimes: [Date] = []
    public var firstHeard: Date
    public var lastHeard: Date
    public var positionTime: Date?
    public var packetCount = 0
    public var lastPath: [String] = []
    /// Zuletzt ohne Digipeater gehört (direkt vom Sender)
    public var direct = false
    public var courseDeg: Int?
    public var speedKnots: Double?
    public var altitudeM: Double?
    public var comment = ""
    public var status: String?
    public var micEStatus: String?
    public var weather: APRSWeather?
    public var device: String?
    public var ambiguity = 0
    public var phg: String?
    public var rangeKm: Double?

    public static let maxTrack = 300
    /// Kleinster Abstand (km) zur letzten Position des Wegs: darunter ist es GPS-Rauschen einer ruhenden Station
    public static let minStepKm = 0.025

    public init(id: String, call: String, source: String, isObject: Bool, firstHeard: Date) {
        self.id = id
        self.call = call
        self.source = source
        self.isObject = isObject
        self.firstHeard = firstHeard
        self.lastHeard = firstHeard
    }

    /// Paket einarbeiten: Ort, Kurs, Wetter … aktualisieren und den Weg verlängern
    public mutating func update(with p: APRSPacket, at date: Date) {
        lastHeard = date
        packetCount += 1
        lastPath = p.path
        direct = !p.path.contains { $0.hasSuffix("*") }
        if let d = p.device { device = d }
        if let s = p.symbol { symbol = s }
        if let pos = p.position, pos.isValid {
            // Weg verlängern, wenn die Station sich bewegt hat. Ungenaue Positionen (Ziffern durch Leerzeichen ersetzt) springen um
            // Kilometer und kommen nur in den Weg, wenn er noch leer ist.
            let last = track.last
            if last == nil || (p.ambiguity == 0 && Geo.distanceKm(last!, pos) > Self.minStepKm) {
                track.append(pos)
                trackTimes.append(date)
                if track.count > Self.maxTrack {
                    track.removeFirst(track.count - Self.maxTrack)
                    trackTimes.removeFirst(trackTimes.count - Self.maxTrack)
                }
            }
            position = pos
            positionTime = date
            ambiguity = p.ambiguity
            courseDeg = p.courseDeg
            speedKnots = p.speedKnots
            if let a = p.altitudeM { altitudeM = a }
        }
        if p.kind == .object || p.kind == .item { killed = p.killed }
        if !p.comment.isEmpty && p.kind != .telemetry && p.kind != .nmea { comment = p.comment }
        if let w = p.weather { weather = w }
        if let s = p.status, !s.isEmpty { status = s }
        if let m = p.micEStatus { micEStatus = m }
        if let phg = p.phg { self.phg = phg }
        if let r = p.rangeKm { rangeKm = r }
    }

    public func ageText(now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(lastHeard)))
        if s < 90 { return "\(s) s" }
        if s < 5400 { return "\(s / 60) min" }
        if s < 172_800 { return "\(s / 3600) h" }
        return "\(s / 86_400) d"
    }
}

/// Zeile im Paketprotokoll
public struct APRSLogEntry: Identifiable, Sendable {
    public let id = UUID()
    public var time: Date
    public var packet: APRSPacket
    public var tnc2: String
    public var repaired: Bool
    public var level: Double

    /// Kurzbeschreibung: „Position 49°30,00′ N 072°45,00′ W · Auto“
    public var summary: String {
        var parts: [String] = []
        switch packet.kind {
        case .micE: parts.append("Mic-E" + (packet.micEStatus.map { " (\($0))" } ?? ""))
        case .position: parts.append("Position")
        case .object: parts.append("Objekt \(packet.name ?? "")" + (packet.killed ? " gelöscht" : ""))
        case .item: parts.append("Gegenstand \(packet.name ?? "")" + (packet.killed ? " gelöscht" : ""))
        case .message:
            if let m = packet.message {
                switch m.kind {
                case .ack: parts.append("Quittung \(m.id ?? "") an \(m.addressee)")
                case .rej: parts.append("Ablehnung \(m.id ?? "") an \(m.addressee)")
                case .bulletin: parts.append("Meldung \(m.addressee): \(m.text)")
                case .text: parts.append("Nachricht an \(m.addressee): \(m.text)")
                }
            }
        case .status: parts.append("Status: \(packet.status ?? "")")
        case .weather: parts.append("Wetter " + (packet.weather?.summary ?? ""))
        case .telemetry: parts.append("Telemetrie")
        case .nmea: parts.append("NMEA")
        case .query: parts.append("Anfrage")
        case .thirdParty: parts.append("Drittverkehr")
        case .capabilities: parts.append("Fähigkeiten")
        case .other: parts.append("Paket")
        }
        if let pos = packet.position, packet.kind != .message { parts.append(Geo.format(pos)) }
        if let s = packet.symbol, packet.position != nil { parts.append(s.name) }
        return parts.joined(separator: " · ")
    }
}

public struct APRSMessageEntry: Identifiable, Sendable {
    public let id = UUID()
    public var time: Date
    public var from: String
    public var to: String
    public var text: String
    public var messageID: String?
    public var kind: APRSMessage.Kind
}

// MARK: - Karte

public enum APRSMapBuilder {
    /// Punkte für die Karte: Stationen mit Ort, nicht älter als `maxAge` Sekunden (nil = alle)
    public static func content(stations: [APRSStation], home: GeoPoint?, maxAge: TimeInterval?, now: Date) -> MapContent {
        var markers: [MapMarker] = []
        for s in stations {
            guard let pos = s.position, pos.isValid else { continue }
            let age = now.timeIntervalSince(s.lastHeard)
            if let maxAge, age > maxAge { continue }
            if s.killed && age > 600 { continue }
            // Weg: nur Positionen im gewählten Zeitraum; eine Linie nur, wenn die Station sich merklich bewegt hat (GPS-Rauschen ausgeblendet)
            let path = movedPath(s, maxAge: maxAge, now: now)
            var details: [String] = []
            details.append(Geo.format(pos) + (s.ambiguity > 0 ? " (ungenau)" : ""))
            if let h = home {
                let km = Geo.distanceKm(h, pos), b = Geo.bearing(from: h, to: pos)
                details.append("\(Geo.formatKm(km)) \(Geo.compass(b)) (\(Int(b.rounded()))°)")
            }
            if !path.isEmpty {
                let km = zip(path, path.dropFirst()).reduce(0) { $0 + Geo.distanceKm($1.0, $1.1) }
                details.append("Weg: \(path.count) Positionen, \(Geo.formatKm(km))")
            }
            if let c = s.courseDeg, let v = s.speedKnots, v >= 1 {
                details.append("Kurs \(c)° · \(Int((v * 1.852).rounded())) km/h")
            } else if let v = s.speedKnots, v >= 1 {
                details.append("\(Int((v * 1.852).rounded())) km/h")
            }
            if let a = s.altitudeM { details.append("Höhe \(Int(a.rounded())) m") }
            if let w = s.weather { details.append(w.summary) }
            if let m = s.micEStatus { details.append("Mic-E: \(m)") }
            if let st = s.status { details.append("Status: \(st)") }
            if !s.comment.isEmpty { details.append(s.comment) }
            if let p = s.phg { details.append("PHG: \(p)") }
            if !s.lastPath.isEmpty { details.append("Digipeater: " + s.lastPath.joined(separator: ",")) }
            if let d = s.device { details.append("Gerät: \(d)") }
            if s.isObject { details.append("Objekt von \(s.source)") }
            let subtitle = [s.symbol?.name, "vor " + s.ageText(now: now), "\(s.packetCount) Pakete"].compactMap { $0 }.joined(separator: " · ")
            var tone: MapTone = .normal
            if s.weather != nil { tone = .weather }
            else if s.isObject { tone = .info }
            if s.direct { tone = s.weather != nil ? .weather : .highlight }
            if s.micEStatus == "Notfall" { tone = .alert }
            if s.killed || age > 1800 { tone = .dim }
            markers.append(MapMarker(id: s.id, coordinate: pos, title: s.call, subtitle: subtitle, details: details,
                                     symbol: s.symbol?.systemImage ?? "mappin", tone: tone, heardAt: s.lastHeard,
                                     track: path,
                                     headingDeg: (s.speedKnots ?? 0) >= 1 ? s.courseDeg.map(Double.init) : nil,
                                     radiusKm: s.rangeKm ?? 0))
        }
        return MapContent(markers: markers, home: home, emptyHint: "Noch keine APRS-Position empfangen")
    }

    /// Der Weg einer Station für die Karte: Positionen der letzten `maxAge` Sekunden (nil = alle), leer, wenn die Station
    /// sich kaum bewegt hat (weniger als 100 m Wegstrecke: GPS-Rauschen)
    static func movedPath(_ s: APRSStation, maxAge: TimeInterval?, now: Date) -> [GeoPoint] {
        var path: [GeoPoint] = []
        for (i, p) in s.track.enumerated() {
            if let maxAge, i < s.trackTimes.count, now.timeIntervalSince(s.trackTimes[i]) > maxAge { continue }
            path.append(p)
        }
        if let pos = s.position, let last = path.last, last != pos { path.append(pos) }
        let km = zip(path, path.dropFirst()).reduce(0) { $0 + Geo.distanceKm($1.0, $1.1) }
        return path.count > 1 && km >= 0.1 ? path : []
    }
}

// MARK: - Decoder

/// APRS-Demodulator als 12-kHz-Senke an der Pipeline
public final class APRSDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var frames: [APRSRawFrame]
        public var synced: Bool
        public var level: Double
    }

    public static let sampleRate = 12_000.0
    /// Abtastrate für 9600 Bd (G3RUH): fünf Abtastwerte je Symbol
    public static let sampleRate9600 = 48_000.0

    /// Bitrate des Empfangs: 1200 Bd (AFSK) oder 9600 Bd (G3RUH-Basisband)
    public enum Speed: Int, Sendable { case baud1200 = 1200, baud9600 = 9600 }

    private let pipeline: AudioPipeline
    private let demod = AFSKReceiver(sampleRate: APRSDecoder.sampleRate)
    private let demod9600 = G3RUHReceiver(sampleRate: APRSDecoder.sampleRate9600)
    private var speed = Speed.baud1200
    private var enabled = false
    private let lock = OSAllocatedUnfairLock()
    private var pending: [APRSRawFrame] = []
    private var syncedNow = false
    private var levelNow = 0.0
    private var sinkID: UUID?

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        sinkID = pipeline.addSink(rate: Self.sampleRate) { [weak self] samples in self?.consume(samples) }
    }

    public func configure(_ options: AFSKDemodulator.Options, emphasis: AFSKReceiver.Emphasis) {
        pipeline.perform { [self] in
            demod.configure(options: options, emphasis: emphasis)
            var g = G3RUHDemodulator.Options()
            g.repairBits = options.repairBits
            demod9600.configure(options: g)
        }
    }

    /// Zwischen 1200 und 9600 Bd umschalten: der Eingang wird auf die passende Abtastrate gestellt
    public func setSpeed(_ new: Speed) {
        pipeline.perform { [self] in
            guard new != speed else { return }
            speed = new
            if let id = sinkID { pipeline.removeSink(id) }
            let rate = new == .baud9600 ? Self.sampleRate9600 : Self.sampleRate
            sinkID = pipeline.addSink(rate: rate) { [weak self] samples in self?.consume(samples) }
            demod.reset()
            demod9600.reset()
        }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            enabled = on
            if !on { demod.reset(); demod9600.reset() }
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pending.removeAll() }
            return Output(frames: pending, synced: syncedNow, level: levelNow)
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled else { return }
        var found: [APRSRawFrame] = []
        let synced: Bool, level: Double
        if speed == .baud9600 {
            demod9600.process(samples) { found.append($0) }
            synced = demod9600.isSynced; level = demod9600.levelPeak
        } else {
            demod.process(samples) { found.append($0) }
            synced = demod.isSynced; level = demod.levelPeak
        }
        lock.withLockUnchecked {
            pending.append(contentsOf: found)
            syncedNow = synced
            levelNow = level
        }
    }
}

// MARK: - Controller

@MainActor
public final class APRSController: ObservableObject {
    public let decoder: APRSDecoder
    public let logger = DecodeLogger(mode: "APRS")
    @Published public private(set) var stations: [APRSStation] = []
    @Published public private(set) var packets: [APRSLogEntry] = []
    @Published public private(set) var messages: [APRSMessageEntry] = []
    @Published public private(set) var synced = false
    @Published public private(set) var level = 0.0
    @Published public private(set) var frameCount = 0
    @Published public private(set) var repairedCount = 0
    @Published public private(set) var lastFrameDate: Date?
    /// Ausgewählte Station (Liste und Karte gemeinsam)
    @Published public var selection: String?
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "aprsLogEnabled") }
    }
    public var rigDescription: String? {
        didSet { if rigDescription != oldValue { markSession() } }
    }
    /// Externer Abgriff für den WebServer (TNC2-Meldungszeilen)
    public var onPacketBroadcast: (@MainActor (String) -> Void)?

    public static let maxStations = 2000
    public static let maxPackets = 600
    public static let maxMessages = 300

    private let settings: APRSSettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var index: [String: Int] = [:]

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: APRSSettingsStore) {
        self.settings = settings
        decoder = APRSDecoder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "aprsLogEnabled") as? Bool ?? true
        decoder.configure(settings.options, emphasis: settings.emphasis)
        markSession()
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.decoder.configure(self.settings.options, emphasis: self.settings.emphasis)
                self.markSession()
            }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
    }

    public func clear() {
        stations.removeAll()
        index.removeAll()
        packets.removeAll()
        messages.removeAll()
        selection = nil
    }

    public func markSession() {
        var h = "APRS · \(settings.channel.label) MHz · AFSK 1200 Bd · Mitte \(Int(settings.centerHz.rounded())) Hz"
        if !settings.repairBits { h += " · ohne Bitkorrektur" }
        if settings.emphasis != .auto { h += settings.emphasis == .on ? " · Vorverzerrung" : " · flaches Audio" }
        if let rig = rigDescription { h += " · \(rig)" }
        logger.markSession(h)
    }

    /// Ein empfangenes Paket verarbeiten (auch für Tests und Dateiwiedergabe)
    public func ingest(_ raw: APRSRawFrame, at now: Date = Date()) {
        guard let frame = AX25Frame.parse(raw.bytes) else { return }
        frameCount += 1
        if raw.repaired { repairedCount += 1 }
        lastFrameDate = now
        let line = Self.tnc2Line(frame)
        onPacketBroadcast?(Self.utc.string(from: now) + "  " + line + (raw.repaired ? "  [repariert]" : "") + "\n")
        guard let packet = APRSParser.parse(frame) else {
            append(APRSLogEntry(time: now, packet: APRSPacket(kind: .other, source: frame.source.text, dest: frame.dest.text,
                                                              path: frame.digis.map(\.text), info: frame.infoText),
                                tnc2: line, repaired: raw.repaired, level: raw.level))
            return
        }
        append(APRSLogEntry(time: now, packet: packet, tnc2: line, repaired: raw.repaired, level: raw.level))
        if logEnabled {
            logger.append(Self.utc.string(from: now) + "  " + line + (raw.repaired ? "  [repariert]" : "") + "\n", now: now)
        }
        // Reparierte Rahmen kommen nie in die Stationsliste: ein Bitfehler könnte einen falschen Ort ergeben
        guard !raw.repaired else { return }
        if let m = packet.message, m.kind != .ack, m.kind != .rej {
            messages.append(APRSMessageEntry(time: now, from: packet.source, to: m.addressee, text: m.text, messageID: m.id, kind: m.kind))
            if messages.count > Self.maxMessages { messages.removeFirst(messages.count - Self.maxMessages) }
        }
        updateStation(packet, at: now)
    }

    private func updateStation(_ p: APRSPacket, at now: Date) {
        let key = p.stationKey
        // Nachrichten, Anfragen und Quittungen sagen nichts über den Ort: Absender nur zählen, wenn schon bekannt
        let isObject = p.kind == .object || p.kind == .item
        if let i = index[key] {
            stations[i].update(with: p, at: now)
        } else {
            if p.kind == .message || p.kind == .query { return }
            var s = APRSStation(id: key, call: isObject ? (p.name ?? key) : p.source, source: p.source, isObject: isObject, firstHeard: now)
            s.update(with: p, at: now)
            stations.append(s)
            index[key] = stations.count - 1
            if stations.count > Self.maxStations { prune() }
        }
    }

    /// Älteste Stationen entfernen
    private func prune() {
        stations.sort { $0.lastHeard > $1.lastHeard }
        stations.removeLast(stations.count - Self.maxStations * 9 / 10)
        index = Dictionary(uniqueKeysWithValues: stations.enumerated().map { ($1.id, $0) })
    }

    private func append(_ e: APRSLogEntry) {
        packets.append(e)
        if packets.count > Self.maxPackets { packets.removeFirst(packets.count - Self.maxPackets) }
    }

    private func poll() {
        let out = decoder.takeOutput()
        synced = out.synced
        level = out.level
        let now = Date()
        for f in out.frames { ingest(f, at: now) }
    }

    /// Stationen nach letzter Aussendung (jüngste zuerst)
    public var sortedStations: [APRSStation] {
        stations.sorted { $0.lastHeard > $1.lastHeard }
    }

    public func mapContent(home: GeoPoint?, now: Date = Date()) -> MapContent {
        APRSMapBuilder.content(stations: stations, home: home, maxAge: settings.mapHours > 0 ? settings.mapHours * 3600 : nil, now: now)
    }

    /// „DL1ABC-9>APRS,WIDE1-1*:!4903.50N/…<0x0d>“: Steuerzeichen sichtbar wie bei direwolf
    nonisolated public static func tnc2Line(_ f: AX25Frame) -> String {
        var s = f.header + ":"
        for b in f.info {
            switch b {
            case 0x20...0x7E: s.append(Character(UnicodeScalar(b)))
            case 0x80...0xFF:
                if let t = String(bytes: f.info, encoding: .utf8) { return f.header + ":" + escapeControls(t) }
                s += String(format: "<0x%02x>", b)
            default: s += String(format: "<0x%02x>", b)
            }
        }
        return s
    }

    nonisolated private static func escapeControls(_ t: String) -> String {
        var s = ""
        for u in t.unicodeScalars {
            if u.value < 0x20 || u.value == 0x7F { s += String(format: "<0x%02x>", u.value) } else { s.unicodeScalars.append(u) }
        }
        return s
    }
}
