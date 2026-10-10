// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI

// MARK: - Kanäle

/// Packet-Radio-Kanäle (FM, 1200 Bd). Das Bandplan-Raster für digitale Betriebsarten liegt auf 25 kHz:
/// 144,8125 bis 144,9875 MHz und 433,625 bis 433,775 MHz (dort stehen auch die Winlink-Zugangsserver).
public enum PacketChannel: String, CaseIterable, Identifiable, Codable, Sendable {
    case v8125, v8375, v8625, v8875, v9125, v9375, v9625, v9875
    case u625, u650, u675, u700, u725, u750, u775
    case free

    public var id: String { rawValue }

    public var frequencyHz: Double? {
        switch self {
        case .v8125: return 144_812_500
        case .v8375: return 144_837_500
        case .v8625: return 144_862_500
        case .v8875: return 144_887_500
        case .v9125: return 144_912_500
        case .v9375: return 144_937_500
        case .v9625: return 144_962_500
        case .v9875: return 144_987_500
        case .u625: return 433_625_000
        case .u650: return 433_650_000
        case .u675: return 433_675_000
        case .u700: return 433_700_000
        case .u725: return 433_725_000
        case .u750: return 433_750_000
        case .u775: return 433_775_000
        case .free: return nil
        }
    }

    /// „144,8125“ (MHz)
    public var label: String {
        guard let f = frequencyHz else { return "frei" }
        let hz = Int64(f.rounded())
        let text = hz % 1000 == 0 ? String(format: "%.3f", f / 1_000_000) : String(format: "%.4f", f / 1_000_000)
        return text.replacingOccurrences(of: ".", with: ",")
    }

    /// Kurzname für den Knopf
    public var name: String { label }

    public var isUHF: Bool { (frequencyHz ?? 0) > 400_000_000 }

    public var note: String {
        guard frequencyHz != nil else { return "Funkgerät nicht abstimmen" }
        return "\(isUHF ? "70 cm" : "2 m"): \(label) MHz, FM, 1200 Bd (Raster 25 kHz; Winlink-Zugangsserver und Digipeater)"
    }
}

/// Frei konfigurierbarer Packet-Radio-Kanal
public struct PacketChannelItem: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    public var frequencyHz: Double?
    public var note: String

    public init(id: String = UUID().uuidString, name: String, frequencyHz: Double?, note: String = "") {
        self.id = id
        self.name = name
        self.frequencyHz = frequencyHz
        self.note = note
    }

    public var label: String {
        guard let f = frequencyHz else { return "frei" }
        let hz = Int64(f.rounded())
        let text = hz % 1000 == 0 ? String(format: "%.3f", f / 1_000_000) : String(format: "%.4f", f / 1_000_000)
        return text.replacingOccurrences(of: ".", with: ",")
    }

    public var isUHF: Bool { (frequencyHz ?? 0) > 400_000_000 }

    public static let standardChannels: [PacketChannelItem] = [
        // 2m EU
        PacketChannelItem(id: "v8125", name: "144,8125", frequencyHz: 144_812_500, note: "2 m EU Winlink / AX.25"),
        PacketChannelItem(id: "v8375", name: "144,8375", frequencyHz: 144_837_500, note: "2 m EU Winlink / AX.25"),
        PacketChannelItem(id: "v8625", name: "144,8625", frequencyHz: 144_862_500, note: "2 m EU Winlink / AX.25"),
        PacketChannelItem(id: "v8875", name: "144,8875", frequencyHz: 144_887_500, note: "2 m EU Winlink / AX.25"),
        PacketChannelItem(id: "v9125", name: "144,9125", frequencyHz: 144_912_500, note: "2 m EU Winlink / AX.25"),
        PacketChannelItem(id: "v9375", name: "144,9375", frequencyHz: 144_937_500, note: "2 m EU Winlink / AX.25"),
        PacketChannelItem(id: "v9625", name: "144,9625", frequencyHz: 144_962_500, note: "2 m EU Winlink / AX.25"),
        PacketChannelItem(id: "v9875", name: "144,9875", frequencyHz: 144_987_500, note: "2 m EU Winlink / AX.25"),
        // 2m US Winlink / Packet
        PacketChannelItem(id: "us14501", name: "145,010", frequencyHz: 145_010_000, note: "2 m US Packet / Winlink"),
        PacketChannelItem(id: "us14503", name: "145,030", frequencyHz: 145_030_000, note: "2 m US Packet / Winlink"),
        PacketChannelItem(id: "us14505", name: "145,050", frequencyHz: 145_050_000, note: "2 m US Packet / Winlink"),
        PacketChannelItem(id: "us14507", name: "145,070", frequencyHz: 145_070_000, note: "2 m US Packet / Winlink"),
        // 70cm EU
        PacketChannelItem(id: "u625", name: "433,625", frequencyHz: 433_625_000, note: "70 cm EU Winlink / AX.25"),
        PacketChannelItem(id: "u650", name: "433,650", frequencyHz: 433_650_000, note: "70 cm EU Winlink / AX.25"),
        PacketChannelItem(id: "u675", name: "433,675", frequencyHz: 433_675_000, note: "70 cm EU Winlink / AX.25"),
        PacketChannelItem(id: "u700", name: "433,700", frequencyHz: 433_700_000, note: "70 cm EU Winlink / AX.25"),
        PacketChannelItem(id: "u725", name: "433,725", frequencyHz: 433_725_000, note: "70 cm EU Winlink / AX.25"),
        PacketChannelItem(id: "u750", name: "433,750", frequencyHz: 433_750_000, note: "70 cm EU Winlink / AX.25"),
        PacketChannelItem(id: "u775", name: "433,775", frequencyHz: 433_775_000, note: "70 cm EU Winlink / AX.25"),
        PacketChannelItem(id: "free", name: "frei", frequencyHz: nil, note: "Funkgerät nicht abstimmen")
    ]
}

/// Bitrate des Packet-Radios
public enum PacketBaud: Int, CaseIterable, Sendable {
    case baud1200 = 1200, baud9600 = 9600

    public var label: String { "\(rawValue) Bd" }
    var speed: APRSDecoder.Speed { self == .baud9600 ? .baud9600 : .baud1200 }
}

// MARK: - Einstellungen

@MainActor
public final class PacketSettingsStore: ObservableObject {
    public static let offsetRange: ClosedRange<Double> = -250...250

    @Published public private(set) var channels: [PacketChannelItem]
    @Published public var selectedChannelID: String { didSet { applySelectedChannel(); save() } }
    @Published public var channel: PacketChannel { didSet { save() } }
    /// 1200 Bd (AFSK, 2 m und 70 cm) oder 9600 Bd (G3RUH-Basisband, meist 70 cm und Satelliten)
    @Published public var baud: PacketBaud { didSet { save() } }
    /// Abweichung der Töne in Hz (Mitte 1700 Hz): Klick im Wasserfall setzt sie
    @Published public private(set) var offsetHz: Double
    @Published public var repairBits: Bool { didSet { save() } }
    @Published public var emphasis: AFSKReceiver.Emphasis { didSet { save() } }
    @Published public var slicers: Int { didSet { save() } }
    /// Nachrichten (Winlink) entpacken und anzeigen
    @Published public var decodeMail: Bool { didSet { save() } }

    public init() {
        let d = UserDefaults.standard
        let loadedChannels: [PacketChannelItem]
        if let data = d.data(forKey: "packetCustomChannels"),
           let list = try? JSONDecoder().decode([PacketChannelItem].self, from: data), !list.isEmpty {
            loadedChannels = list
        } else {
            loadedChannels = PacketChannelItem.standardChannels
        }
        let savedID = d.string(forKey: "packetSelectedChannelID")
        let initialID = loadedChannels.first(where: { $0.id == savedID })?.id ?? loadedChannels.first?.id ?? "v8125"
        channels = loadedChannels
        selectedChannelID = initialID
        channel = PacketChannel(rawValue: initialID) ?? .v8125
        baud = PacketBaud(rawValue: d.integer(forKey: "packetBaud")) ?? .baud1200
        offsetHz = Self.offsetRange.contains(d.double(forKey: "packetOffsetHz")) ? d.double(forKey: "packetOffsetHz") : 0
        repairBits = d.object(forKey: "packetRepair") as? Bool ?? true
        emphasis = d.string(forKey: "packetEmphasis").flatMap(AFSKReceiver.Emphasis.init(rawValue:)) ?? .auto
        slicers = d.object(forKey: "packetSlicers") as? Int ?? 7
        decodeMail = d.object(forKey: "packetDecodeMail") as? Bool ?? true
    }

    public var activeChannelItem: PacketChannelItem {
        channels.first { $0.id == selectedChannelID } ?? channels[0]
    }

    public var activeFrequencyHz: Double? { activeChannelItem.frequencyHz }

    public func selectChannel(id: String) {
        guard channels.contains(where: { $0.id == id }) else { return }
        selectedChannelID = id
    }

    public func addChannel(_ item: PacketChannelItem) {
        channels.append(item)
        selectedChannelID = item.id
        save()
    }

    public func updateChannel(_ item: PacketChannelItem) {
        if let idx = channels.firstIndex(where: { $0.id == item.id }) {
            channels[idx] = item
            if selectedChannelID == item.id {
                applySelectedChannel()
            }
            save()
        }
    }

    public func removeChannel(id: String) {
        guard channels.count > 1 else { return }
        channels.removeAll { $0.id == id }
        if selectedChannelID == id {
            selectedChannelID = channels.first?.id ?? "free"
        }
        save()
    }

    public func resetChannelsToDefault() {
        channels = PacketChannelItem.standardChannels
        if !channels.contains(where: { $0.id == selectedChannelID }) {
            selectedChannelID = "v8125"
        }
        save()
    }

    private func applySelectedChannel() {
        channel = PacketChannel(rawValue: activeChannelItem.id) ?? .free
    }

    private func save() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(channels) {
            d.set(data, forKey: "packetCustomChannels")
        }
        d.set(selectedChannelID, forKey: "packetSelectedChannelID")
        d.set(channel.rawValue, forKey: "packetChannel")
        d.set(baud.rawValue, forKey: "packetBaud")
        d.set(offsetHz, forKey: "packetOffsetHz")
        d.set(repairBits, forKey: "packetRepair")
        d.set(emphasis.rawValue, forKey: "packetEmphasis")
        d.set(slicers, forKey: "packetSlicers")
        d.set(decodeMail, forKey: "packetDecodeMail")
    }

    public var centerHz: Double { baud == .baud9600 ? 2400 : 1700 + offsetHz }

    public func setCenter(_ hz: Double) {
        offsetHz = min(max(hz - 1700, Self.offsetRange.lowerBound), Self.offsetRange.upperBound).rounded()
        save()
    }

    var options: AFSKDemodulator.Options {
        var o = AFSKDemodulator.Options()
        o.slicers = slicers
        o.repairBits = repairBits
        o.centerOffsetHz = offsetHz
        return o
    }
}

extension PacketSettingsStore: TuningTarget {
    public var tones: (mark: Double, space: Double) { baud == .baud9600 ? (0, 4800) : (centerHz - 500, centerHz + 500) }
    public var markerBandwidth: Double { baud == .baud9600 ? 9600 : 1300 }
    public var markerStyle: WaterfallMarkerStyle { baud == .baud9600 ? .band("PACKET · Basisband (G3RUH 9600 Bd, bis 4,8 kHz)") : .tones }
}

// MARK: - Controller

/// Eine entpackte Nachricht mit der Verbindung, in der sie gehört wurde
public struct PacketMailItem: Identifiable, Equatable, Sendable {
    public var id: String { "\(sessionID)-\(message.id)" }
    public var sessionID: Int
    public var caller: String
    public var callee: String
    public var message: WinlinkMessage
}

@MainActor
public final class PacketController: ObservableObject {
    public let decoder: APRSDecoder
    public let logger = DecodeLogger(mode: "PACKET")
    @Published public private(set) var monitor: [PacketMonitorEntry] = []
    @Published public private(set) var stations: [PacketStation] = []
    @Published public private(set) var digipeaters: [PacketDigipeater] = []
    @Published public private(set) var sessions: [PacketSession] = []
    @Published public private(set) var nodes: [PacketNodeEntry] = []
    @Published public private(set) var mail: [PacketMailItem] = []
    @Published public private(set) var synced = false
    @Published public private(set) var level = 0.0
    @Published public private(set) var frameCount = 0
    @Published public private(set) var repairedCount = 0
    @Published public private(set) var lastFrameDate: Date?
    @Published public var selectedSession: Int?
    @Published public var selectedMail: String?
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "packetLogEnabled") }
    }
    public var rigDescription: String? {
        didSet { if rigDescription != oldValue { markSession() } }
    }

    public static let maxMonitor = 800

    private let settings: PacketSettingsStore
    private var analyzer = PacketAnalyzer()
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    public init(pipeline: AudioPipeline, settings: PacketSettingsStore) {
        self.settings = settings
        decoder = APRSDecoder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "packetLogEnabled") as? Bool ?? true
        decoder.configure(settings.options, emphasis: settings.emphasis)
        decoder.setSpeed(settings.baud.speed)
        markSession()
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.decoder.configure(self.settings.options, emphasis: self.settings.emphasis)
                self.decoder.setSpeed(self.settings.baud.speed)
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
        analyzer.clear()
        monitor.removeAll()
        mail.removeAll()
        selectedSession = nil
        selectedMail = nil
        publish()
    }

    public func markSession() {
        var h = "PACKET · \(settings.channel.label) MHz · " + (settings.baud == .baud9600 ? "G3RUH 9600 Bd" : "AFSK 1200 Bd · Mitte \(Int(settings.centerHz.rounded())) Hz")
        if !settings.repairBits { h += " · ohne Bitkorrektur" }
        if settings.emphasis != .auto { h += settings.emphasis == .on ? " · Vorverzerrung" : " · flaches Audio" }
        if let rig = rigDescription { h += " · \(rig)" }
        logger.markSession(h)
    }

    /// Ein empfangenes Paket verarbeiten (auch für Tests und Dateiwiedergabe). Die Listen werden erst in `publish()` neu gebildet.
    public func ingest(_ raw: APRSRawFrame, at now: Date = Date(), publishNow: Bool = true) {
        guard let frame = AX25Frame.parse(raw.bytes) else { return }
        lastFrameDate = now
        frameCount += 1
        if raw.repaired { repairedCount += 1 }
        let entry = PacketMonitorEntry(time: now, frame: frame, repaired: raw.repaired, level: raw.level)
        monitor.append(entry)
        if monitor.count > Self.maxMonitor { monitor.removeFirst(monitor.count - Self.maxMonitor) }
        if logEnabled {
            logger.append(APRSController.utc.string(from: now) + "  " + entry.line + "\n", now: now)
        }
        analyzer.decodeMessages = settings.decodeMail
        let events = analyzer.ingest(frame, at: now, repaired: raw.repaired)
        for case .message(let sessionID, let message) in events {
            guard let s = analyzer.sessions.first(where: { $0.id == sessionID }) else { continue }
            if logEnabled { logger.append(Self.logText(message, caller: s.caller, callee: s.callee, at: now), now: now) }
        }
        if publishNow { publish() }
    }

    /// Listen für die Oberfläche aus der Auswertung bilden
    func publish() {
        stations = analyzer.stations.values.sorted { $0.lastHeard > $1.lastHeard }
        digipeaters = analyzer.digipeaters.values.sorted { $0.heard + $0.inPath > $1.heard + $1.inPath || ($0.heard + $0.inPath == $1.heard + $1.inPath && $0.lastHeard > $1.lastHeard) }
        nodes = analyzer.nodes.values.sorted { $0.quality > $1.quality || ($0.quality == $1.quality && $0.call < $1.call) }
        sessions = analyzer.sortedSessions
        mail = analyzer.messages.map { PacketMailItem(sessionID: $0.session.id, caller: $0.session.caller, callee: $0.session.callee, message: $0.message) }
            .sorted { $0.message.received > $1.message.received }
    }

    private func poll() {
        let out = decoder.takeOutput()
        synced = out.synced
        level = out.level
        let now = Date()
        for f in out.frames { ingest(f, at: now, publishNow: false) }
        analyzer.housekeeping(now: now)
        if !out.frames.isEmpty || analyzer.sessions.contains(where: { $0.isOpen }) { publish() }
        // Entwicklungshilfe (Schnappschüsse): DIGIDEC_PACKET_SELECT=1 wählt die Winlink-Verbindung und ihre Nachricht
        if ProcessInfo.processInfo.environment["DIGIDEC_PACKET_SELECT"] == "1" {
            if selectedSession == nil, let s = sessions.first(where: { $0.kind == .winlink }) { selectedSession = s.id }
            if selectedMail == nil, let m = mail.first { selectedMail = m.id }
        }
    }

    /// Zählwerte für die Anzeige
    public var openSessions: Int { sessions.filter(\.isOpen).count }

    /// Nachricht für die Tagesdatei
    nonisolated static func logText(_ m: WinlinkMessage, caller: String, callee: String, at now: Date) -> String {
        var s = APRSController.utc.string(from: now) + "  ── Nachricht (\(caller) ↔ \(callee)) ──\n"
        s += "Von: \(m.from)\nAn: \(m.to.joined(separator: ", "))\n"
        if !m.cc.isEmpty { s += "Cc: \(m.cc.joined(separator: ", "))\n" }
        s += "Betreff: \(m.subject)\nDatum: \(m.date)  MID: \(m.mid)  Art: \(m.type)\n\n"
        s += m.body.replacingOccurrences(of: "\r\n", with: "\n")
        if !m.body.hasSuffix("\n") { s += "\n" }
        for a in m.attachments { s += "[Anhang: \(a.name), \(a.size) Byte]\n" }
        return s + "──\n"
    }
}
