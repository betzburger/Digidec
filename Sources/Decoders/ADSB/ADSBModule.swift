// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI

// MARK: - Einstellungen

@MainActor
public final class ADSBSettingsStore: ObservableObject {
    @Published public var source: ADSBSourceKind { didSet { UserDefaults.standard.set(source.rawValue, forKey: "adsbSource") } }
    @Published public var hackrfLNA: Int { didSet { UserDefaults.standard.set(hackrfLNA, forKey: "adsbHackrfLNA") } }
    @Published public var hackrfVGA: Int { didSet { UserDefaults.standard.set(hackrfVGA, forKey: "adsbHackrfVGA") } }
    @Published public var hackrfAmp: Bool { didSet { UserDefaults.standard.set(hackrfAmp, forKey: "adsbHackrfAmp") } }
    @Published public var hackrfBias: Bool { didSet { UserDefaults.standard.set(hackrfBias, forKey: "adsbHackrfBias") } }
    /// RTL-SDR: Verstärkung in dB (0 = Tuner-AGC)
    @Published public var rtlGain: Double { didSet { UserDefaults.standard.set(rtlGain, forKey: "adsbRtlGain") } }
    @Published public var rtlBias: Bool { didSet { UserDefaults.standard.set(rtlBias, forKey: "adsbRtlBias") } }
    @Published public var rtlPPM: Int { didSet { UserDefaults.standard.set(rtlPPM, forKey: "adsbRtlPPM") } }
    @Published public var sdrconnectHost: String { didSet { UserDefaults.standard.set(sdrconnectHost, forKey: "adsbSdrHost") } }
    @Published public var sdrconnectPort: Int { didSet { UserDefaults.standard.set(sdrconnectPort, forKey: "adsbSdrPort") } }
    @Published public var sdrplayLNAState: Int { didSet { UserDefaults.standard.set(sdrplayLNAState, forKey: "adsbSdrLNA") } }
    /// Flugzeuge nach dieser Zeit ohne Meldung aus der Liste nehmen (Minuten)
    @Published public var expireMinutes: Int { didSet { UserDefaults.standard.set(expireMinutes, forKey: "adsbExpireMinutes") } }
    /// Nur Flugzeuge mit Position in der Liste
    @Published public var onlyWithPosition: Bool { didSet { UserDefaults.standard.set(onlyWithPosition, forKey: "adsbOnlyPosition") } }
    /// Wege auf der Karte
    @Published public var showTracks: Bool { didSet { UserDefaults.standard.set(showTracks, forKey: "adsbShowTracks") } }

    public init() {
        let d = UserDefaults.standard
        source = d.string(forKey: "adsbSource").flatMap(ADSBSourceKind.init(rawValue:)) ?? .hackrf
        hackrfLNA = d.object(forKey: "adsbHackrfLNA") as? Int ?? 32
        hackrfVGA = d.object(forKey: "adsbHackrfVGA") as? Int ?? 20
        hackrfAmp = d.object(forKey: "adsbHackrfAmp") as? Bool ?? true
        hackrfBias = d.object(forKey: "adsbHackrfBias") as? Bool ?? false
        rtlGain = d.object(forKey: "adsbRtlGain") as? Double ?? 49.6
        rtlBias = d.object(forKey: "adsbRtlBias") as? Bool ?? false
        rtlPPM = d.object(forKey: "adsbRtlPPM") as? Int ?? 0
        sdrconnectHost = d.string(forKey: "adsbSdrHost") ?? "127.0.0.1"
        sdrconnectPort = d.object(forKey: "adsbSdrPort") as? Int ?? 5454
        sdrplayLNAState = d.object(forKey: "adsbSdrLNA") as? Int ?? 0
        expireMinutes = d.object(forKey: "adsbExpireMinutes") as? Int ?? 5
        onlyWithPosition = d.object(forKey: "adsbOnlyPosition") as? Bool ?? false
        showTracks = d.object(forKey: "adsbShowTracks") as? Bool ?? true
    }

    public var gain: ADSBGainSettings {
        var g = ADSBGainSettings()
        g.hackrfLNA = hackrfLNA
        g.hackrfVGA = hackrfVGA
        g.hackrfAmp = hackrfAmp
        g.hackrfBias = hackrfBias
        g.rtlGainDB = rtlGain > 0 ? rtlGain : nil
        g.rtlBias = rtlBias
        g.rtlPPM = rtlPPM
        g.sdrconnectHost = sdrconnectHost
        g.sdrconnectPort = sdrconnectPort
        g.sdrplayLNAState = sdrplayLNAState
        return g
    }
}

// MARK: - Zusammenfassung einer Meldung (Protokoll)

public struct ADSBLogEntry: Identifiable, Sendable {
    public let id = UUID()
    public var time: Date
    public var message: ModeSMessage
    public var summary: String
}

extension ModeSMessage {
    /// „4D2023 DF17 Position, FL 224“ für das Protokoll
    public var summary: String {
        var parts = [icaoText, "DF\(df)"]
        switch df {
        case 17, 18:
            switch typeCode ?? 0 {
            case 1...4: parts.append("Kennung \(callsign ?? "")")
            case 5...8: parts.append("Bodenposition")
            case 9...18, 20...22: parts.append("Position" + (altitudeFt.map { ", \($0) ft" } ?? ""))
            case 19: parts.append("Geschwindigkeit" + (velocity?.groundSpeedKn.map { String(format: ", %.0f kn", $0) } ?? "") + (velocity?.trackDeg.map { String(format: " %.0f°", $0) } ?? ""))
            case 28: parts.append("Status" + (squawk.map { ", Kennung \($0)" } ?? ""))
            default: parts.append("Typ \(typeCode ?? 0)")
            }
        case 4, 20: parts.append("Höhe" + (altitudeFt.map { " \($0) ft" } ?? ""))
        case 5, 21: parts.append("Kennung" + (squawk.map { " \($0)" } ?? ""))
        case 0, 16: parts.append("Luft-Luft" + (altitudeFt.map { ", \($0) ft" } ?? ""))
        case 11: parts.append("Sammelantwort")
        default: break
        }
        if confidence == .corrected { parts.append("(1 Bit korrigiert)") }
        if let c = callsign, df != 17 && df != 18 { parts.append(c) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Engine

/// Verarbeitet die I/Q-Daten auf einem eigenen Faden: Demodulator → Prüfung → Flugzeugliste. Die Oberfläche liest nur Abzüge (`snapshot`).
public final class ADSBEngine: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var aircraft: [ADSBAircraft] = []
        public var messageCount = 0
        public var positionCount = 0
        public var rejectedPositions = 0
        public var messagesPerSecond = 0.0
        public var dfCounts: [Int: Int] = [:]
        public var rangeBySector = [Double](repeating: 0, count: 36)
        /// Mittlere Auslenkung (0 … 127) und Anteil übersteuerter Abtastwerte
        public var activity = 0.0
        public var clippedFraction = 0.0
        public var preambles = 0
        public var phaseRetries = 0
        public var recent: [ADSBLogEntry] = []
        public var expired: [ADSBAircraft] = []
        public var droppedBlocks = 0
    }

    private let queue = DispatchQueue(label: "com.peterbetz.digidec.adsb", qos: .userInitiated)
    private let demod = ModeSDemodulator()
    private let decoder = ModeSDecoder()
    private var tracker = ADSBTracker()
    private let lock = NSLock()
    private var pendingBytes = 0
    private var droppedBlocks = 0
    private var rateWindow: [(Date, Int)] = []
    private var recent: [ADSBLogEntry] = []
    private var expiredPending: [ADSBAircraft] = []
    private var activity = 0.0
    private var lastCleanup = Date()
    private var enabledLog = true
    /// Zeit aus der Lage im Datenstrom statt der Uhr (Dateien ohne Echtzeit)
    private var sampleClockBase: Date?
    private var expireAfter: TimeInterval = 300
    public static let maxRecent = 300
    /// Obergrenze für den Rückstau (≈ 2 s I/Q-Daten); darüber werden Blöcke verworfen
    static let maxPending = 8 * 1024 * 1024

    public init() {}

    public func configure(receiver: GeoPoint?, expireAfter: TimeInterval, sampleClock: Bool = false) {
        queue.async { [self] in
            tracker.receiver = receiver
            self.expireAfter = expireAfter
            sampleClockBase = sampleClock ? Date() : nil
        }
    }

    public func reset() {
        queue.async { [self] in
            demod.reset()
            decoder.reset()
            tracker.clear()
            lock.withLock { recent.removeAll(); expiredPending.removeAll(); rateWindow.removeAll(); droppedBlocks = 0 }
        }
    }

    /// Neue I/Q-Daten (vom Faden der Quelle): kopieren und weitergeben, bei Rückstau verwerfen
    public func feed(_ buffer: UnsafeBufferPointer<UInt8>, wait: Bool = false) {
        let n = buffer.count
        // Aufnahmen schneller als in Echtzeit: warten, bis Platz ist, statt zu verwerfen
        if wait { while lock.withLock({ pendingBytes + n > Self.maxPending }) { Thread.sleep(forTimeInterval: 0.002) } }
        let over = lock.withLock { () -> Bool in
            if pendingBytes + n > Self.maxPending { droppedBlocks += 1; return true }
            pendingBytes += n
            return false
        }
        if over { return }
        let copy = Data(buffer: buffer)
        queue.async { [self] in
            process(copy)
            lock.withLock { pendingBytes -= n }
        }
    }

    private func process(_ data: Data) {
        let wall = Date()
        data.withUnsafeBytes { raw in
            let buf = raw.bindMemory(to: UInt8.self)
            demod.process(buf, accept: { [decoder] bytes in decoder.decode(bytes, at: wall) != nil }, emit: { [self] f in
                let t = sampleClockBase.map { $0.addingTimeInterval(Double(f.sampleIndex) / ModeSDemodulator.sampleRate) } ?? wall
                guard var m = decoder.decode(f.bytes, at: t) else { return }
                m.levelDB = f.levelDB
                tracker.ingest(m, at: t)
                lock.withLock {
                    rateWindow.append((wall, 1))
                    recent.append(ADSBLogEntry(time: t, message: m, summary: m.summary))
                    if recent.count > Self.maxRecent { recent.removeFirst(recent.count - Self.maxRecent) }
                }
            })
        }
        activity = demod.blockActivity
        if wall.timeIntervalSince(lastCleanup) > 2 {
            lastCleanup = wall
            let now = sampleClockBase.map { _ in tracker.aircraft.values.map(\.lastSeen).max() ?? wall } ?? wall
            let before = tracker.aircraft
            tracker.expire(now: now, maxAge: expireAfter)
            let gone = before.filter { tracker.aircraft[$0.key] == nil }.map(\.value)
            if !gone.isEmpty { lock.withLock { expiredPending += gone } }
        }
    }

    public func snapshot() -> Snapshot {
        var s = Snapshot()
        queue.sync { [self] in
            s.aircraft = Array(tracker.aircraft.values)
            s.messageCount = tracker.messageCount
            s.positionCount = tracker.positionCount
            s.rejectedPositions = tracker.rejectedPositions
            s.dfCounts = tracker.dfCounts
            s.rangeBySector = tracker.rangeBySector
            s.activity = activity
            s.clippedFraction = demod.totalSamples > 0 ? Double(demod.clippedSamples) / Double(demod.totalSamples) : 0
            s.preambles = demod.preambles
            s.phaseRetries = demod.phaseRetries
        }
        lock.withLock {
            s.recent = recent
            s.expired = expiredPending
            expiredPending.removeAll()
            s.droppedBlocks = droppedBlocks
            let now = Date()
            rateWindow.removeAll { now.timeIntervalSince($0.0) > 5 }
            s.messagesPerSecond = Double(rateWindow.count) / 5
        }
        return s
    }
}

// MARK: - Controller

public enum ADSBStatus: Equatable, Sendable {
    case idle
    case running(String)
    case error(String)
}

@MainActor
public final class ADSBController: ObservableObject {
    public let engine = ADSBEngine()
    public let logger = DecodeLogger(mode: "ADSB")
    @Published public private(set) var aircraft: [ADSBAircraft] = []
    @Published public private(set) var status = ADSBStatus.idle
    @Published public private(set) var stats = ADSBEngine.Snapshot()
    @Published public private(set) var recent: [ADSBLogEntry] = []
    /// Meldungen je Sekunde der letzten zwei Minuten (alle 0,5 s ein Wert)
    @Published public private(set) var rateHistory: [Double] = []
    @Published public var selection: UInt32?
    @Published public var logEnabled: Bool { didSet { UserDefaults.standard.set(logEnabled, forKey: "adsbLogEnabled") } }
    /// Standort des Empfängers
    public var homePoint: GeoPoint? { didSet { applyConfiguration() } }

    private let settings: ADSBSettingsStore
    private var source: ADSBIQSource?
    private var timer: Timer?
    private var active = false
    private var cancellables: Set<AnyCancellable> = []
    /// Aufnahme als Quelle (Entwicklung und Prüfung): gesetzt, dann statt des gewählten Geräts
    public var fileOverride: URL?
    public var fileRealtime = true

    public init(settings: ADSBSettingsStore) {
        self.settings = settings
        logEnabled = UserDefaults.standard.object(forKey: "adsbLogEnabled") as? Bool ?? true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Gerät oder Verstärkung geändert: neu starten (nur im aktiven Modul)
        let restartTriggers: [AnyPublisher<Void, Never>] = [
            settings.$source.map { _ in () }.eraseToAnyPublisher(),
            settings.$hackrfLNA.map { _ in () }.eraseToAnyPublisher(),
            settings.$hackrfVGA.map { _ in () }.eraseToAnyPublisher(),
            settings.$hackrfAmp.map { _ in () }.eraseToAnyPublisher(),
            settings.$hackrfBias.map { _ in () }.eraseToAnyPublisher(),
            settings.$rtlGain.map { _ in () }.eraseToAnyPublisher(),
            settings.$rtlBias.map { _ in () }.eraseToAnyPublisher(),
            settings.$rtlPPM.map { _ in () }.eraseToAnyPublisher(),
            settings.$sdrplayLNAState.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(restartTriggers)
            .dropFirst(restartTriggers.count)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self, self.active else { return }
                self.stopSource()
                self.startSource()
            }
            .store(in: &cancellables)
        settings.$expireMinutes.sink { [weak self] _ in self?.applyConfiguration() }.store(in: &cancellables)
        applyConfiguration()
    }

    private func applyConfiguration() {
        engine.configure(receiver: homePoint, expireAfter: Double(settings.expireMinutes) * 60, sampleClock: fileOverride != nil && !fileRealtime)
    }

    /// Modul betreten oder verlassen: nur im aktiven Modul belegt Digidec das Funkgerät
    public func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on { startSource() } else { stopSource() }
    }

    public func clear() {
        engine.reset()
        aircraft.removeAll()
        recent.removeAll()
        stats = ADSBEngine.Snapshot()
        rateHistory.removeAll()
        selection = nil
    }

    public func startSource() {
        stopSource()
        let src: ADSBIQSource
        if let url = fileOverride {
            src = ADSBFileSource(url: url, realtime: fileRealtime, loop: false)
        } else {
            switch settings.source {
            case .hackrf: src = HackRFSource(settings: settings.gain)
            case .rtlsdr: src = RTLSDRSource(settings: settings.gain)
            case .sdrplay: src = SDRconnectSource(settings: settings.gain)
            case .file:
                status = .error("Keine Aufnahme gewählt (Knopf ÖFFNEN)")
                return
            }
        }
        applyConfiguration()
        let engine = self.engine
        let wait = fileOverride != nil && !fileRealtime
        do {
            try src.start(onData: { engine.feed($0, wait: wait) }, onStop: { [weak self] reason in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.sourceStopped(reason) } }
            })
            source = src
            status = .running(src.deviceDescription)
            markSession(src.deviceDescription)
        } catch {
            status = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    public func stopSource() {
        source?.stop()
        source = nil
        if case .running = status { status = .idle }
    }

    private func sourceStopped(_ reason: String?) {
        guard source != nil else { return }
        source = nil
        status = reason.map { .error($0) } ?? .idle
    }

    private func markSession(_ device: String) {
        var h = "ADS-B · 1090 MHz · 2 MS/s · \(device)"
        if let p = homePoint { h += " · Standort \(Geo.format(p))" }
        logger.markSession(h)
    }

    private func poll() {
        guard active || fileOverride != nil else { return }
        let s = engine.snapshot()
        stats = s
        aircraft = s.aircraft.sorted { ($0.lastSeen, $0.icao) > ($1.lastSeen, $1.icao) }
        recent = s.recent
        rateHistory.append(s.messagesPerSecond)
        if rateHistory.count > 240 { rateHistory.removeFirst(rateHistory.count - 240) }
        if logEnabled {
            for a in s.expired { logger.append(Self.logLine(a), now: a.lastSeen) }
        }
    }

    /// Eine Zeile für das Tagesprotokoll, wenn ein Flugzeug aus der Liste fällt
    nonisolated public static func logLine(_ a: ADSBAircraft) -> String {
        var s = APRSController.utc.string(from: a.firstSeen) + "–" + APRSController.utc.string(from: a.lastSeen) + "  " + a.icaoText
        s += "  " + (a.callsign ?? "-").padding(toLength: 8, withPad: " ", startingAt: 0)
        s += "  " + (a.country.map { "\($0.flag) \($0.name)" } ?? "-")
        if let alt = a.altitudeFt { s += "  \(alt) ft" }
        if let r = a.maxRangeKm { s += String(format: "  max %.0f km", r) }
        if let sq = a.squawk { s += "  Kennung \(sq)" }
        s += "  \(a.messages) Meldungen"
        if let e = a.emergencyText { s += "  !! \(e)" }
        return s + "\n"
    }

    /// Flugzeuge für Liste und Karte (nach Einstellung gefiltert)
    public var visibleAircraft: [ADSBAircraft] {
        settings.onlyWithPosition ? aircraft.filter(\.hasPosition) : aircraft
    }

    public func mapContent(home: GeoPoint?, now: Date = Date()) -> MapContent {
        ADSBMapBuilder.content(aircraft, home: home, now: now, showTracks: settings.showTracks, selection: selection)
    }
}

// MARK: - Karte

public enum ADSBMapBuilder {
    /// Höhenfarbe: 0 ft (blau) … 40 000 ft (rot)
    public static func altitudeLevel(_ ft: Int?) -> Double? {
        ft.map { min(1, max(0, Double($0) / 40_000)) }
    }

    public static func content(_ list: [ADSBAircraft], home: GeoPoint?, now: Date, showTracks: Bool = true, selection: UInt32? = nil) -> MapContent {
        var markers: [MapMarker] = []
        for a in list {
            guard let pos = a.position, pos.isValid else { continue }
            let age = now.timeIntervalSince(a.lastSeen)
            var details: [String] = ["ICAO \(a.icaoText)"]
            if let c = a.country { details.append("\(c.flag) \(c.name)") }
            if let cat = a.categoryText { details.append(cat) }
            if let alt = a.altitudeFt {
                details.append(a.onGround == true ? "Am Boden" : "Höhe \(alt) ft (\(a.altitudeText ?? "")) · \(Int((Double(alt) * 0.3048).rounded())) m" + (a.altitudeIsGNSS ? " (GNSS)" : ""))
            }
            if let v = a.groundSpeedKn {
                details.append(String(format: "%.0f kn · %.0f km/h", v, v * 1.852) + (a.trackDeg.map { String(format: " · Kurs %.0f°", $0) } ?? ""))
            }
            if let vr = a.verticalRateFpm, vr != 0 { details.append("\(vr > 0 ? "Steigen" : "Sinken") \(abs(vr)) ft/min") }
            if let sq = a.squawk { details.append("Kennung \(sq)") }
            if let e = a.emergencyText { details.append("⚠ \(e)") }
            if let h = home {
                let km = Geo.distanceKm(h, pos), b = Geo.bearing(from: h, to: pos)
                details.append("\(Geo.formatKm(km)) \(Geo.compass(b)) (\(Int(b.rounded()))°)")
            }
            details.append("\(a.messages) Meldungen, \(a.positionMessages) Positionen" + (a.levelDB.map { String(format: ", %.0f dB", $0) } ?? ""))
            var sub: [String] = []
            if let t = a.altitudeText { sub.append(t) }
            if let v = a.groundSpeedKn { sub.append(String(format: "%.0f kn", v)) }
            sub.append("vor \(Int(age)) s")
            var tone: MapTone = age > 60 ? .dim : .normal
            if a.emergencyText != nil { tone = .alert }
            else if a.id == selection { tone = .highlight }
            let track = showTracks ? a.track.map { GeoPoint(lat: $0.lat, lon: $0.lon) } : []
            markers.append(MapMarker(id: "adsb-\(a.icaoText)", coordinate: pos, title: a.callsign ?? a.icaoText, subtitle: sub.joined(separator: " · "),
                                     details: details, symbol: "airplane", tone: tone, heardAt: a.lastSeen,
                                     track: track.count > 1 ? track : [], headingDeg: a.trackDeg, valueLevel: a.onGround == true ? nil : altitudeLevel(a.altitudeFt)))
        }
        var c = MapContent(markers: markers, home: home, emptyHint: "Noch kein Flugzeug mit Position empfangen")
        c.note = "Farbe: Flughöhe (blau tief, rot hoch)"
        return c
    }
}
