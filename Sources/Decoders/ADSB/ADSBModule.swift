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
    @Published public var sdrplayTuner: Int { didSet { UserDefaults.standard.set(sdrplayTuner, forKey: "adsbSdrTuner") } }
    @Published public var sdrplayIFGain: Int { didSet { UserDefaults.standard.set(sdrplayIFGain, forKey: "adsbSdrIFGain") } }
    @Published public var sdrplayAGC: Bool { didSet { UserDefaults.standard.set(sdrplayAGC, forKey: "adsbSdrAGC") } }
    @Published public var sdrplayBias: Bool { didSet { UserDefaults.standard.set(sdrplayBias, forKey: "adsbSdrBias") } }
    @Published public var sdrplayPPM: Int { didSet { UserDefaults.standard.set(sdrplayPPM, forKey: "adsbSdrPPM") } }
    @Published public var sdrplayRfNotch: Bool { didSet { UserDefaults.standard.set(sdrplayRfNotch, forKey: "adsbSdrRfNotch") } }
    @Published public var sdrplayDabNotch: Bool { didSet { UserDefaults.standard.set(sdrplayDabNotch, forKey: "adsbSdrDabNotch") } }
    /// Flugzeuge nach dieser Zeit ohne Meldung aus der Liste nehmen (Minuten)
    @Published public var expireMinutes: Int { didSet { UserDefaults.standard.set(expireMinutes, forKey: "adsbExpireMinutes") } }
    /// Nur Flugzeuge mit Position in der Liste
    @Published public var onlyWithPosition: Bool { didSet { UserDefaults.standard.set(onlyWithPosition, forKey: "adsbOnlyPosition") } }
    /// Wege auf der Karte
    @Published public var showTracks: Bool { didSet { UserDefaults.standard.set(showTracks, forKey: "adsbShowTracks") } }
    /// Flugzeugdaten (Typ, Betreiber, Strecke, Foto) im Netz suchen: nur für angeklickte Flugzeuge, sofern nicht `autoLookup`
    @Published public var webLookup: Bool { didSet { UserDefaults.standard.set(webLookup, forKey: "adsbWebLookup") } }
    /// Typ, Betreiber und Strecke aller Flugzeuge im Hintergrund abfragen (sendet deren ICAO-Adressen und Rufzeichen)
    @Published public var autoLookup: Bool { didSet { UserDefaults.standard.set(autoLookup, forKey: "adsbAutoLookup") } }
    /// Klick auf ein Flugzeug in der Karte öffnet das Fenster „Flugzeugdaten“
    @Published public var openInfoOnClick: Bool { didSet { UserDefaults.standard.set(openInfoOnClick, forKey: "adsbOpenInfoOnClick") } }

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
        sdrplayTuner = d.object(forKey: "adsbSdrTuner") as? Int ?? 0
        sdrplayIFGain = d.object(forKey: "adsbSdrIFGain") as? Int ?? 40
        sdrplayAGC = d.object(forKey: "adsbSdrAGC") as? Bool ?? false
        sdrplayBias = d.object(forKey: "adsbSdrBias") as? Bool ?? false
        sdrplayPPM = d.object(forKey: "adsbSdrPPM") as? Int ?? 0
        sdrplayRfNotch = d.object(forKey: "adsbSdrRfNotch") as? Bool ?? false
        sdrplayDabNotch = d.object(forKey: "adsbSdrDabNotch") as? Bool ?? false
        expireMinutes = d.object(forKey: "adsbExpireMinutes") as? Int ?? 5
        onlyWithPosition = d.object(forKey: "adsbOnlyPosition") as? Bool ?? false
        showTracks = d.object(forKey: "adsbShowTracks") as? Bool ?? true
        webLookup = d.object(forKey: "adsbWebLookup") as? Bool ?? true
        autoLookup = d.object(forKey: "adsbAutoLookup") as? Bool ?? false
        openInfoOnClick = d.object(forKey: "adsbOpenInfoOnClick") as? Bool ?? false
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
        g.sdrplayTuner = sdrplayTuner
        g.sdrplayIFGainReduction = sdrplayIFGain
        g.sdrplayAGC = sdrplayAGC
        g.sdrplayBias = sdrplayBias
        g.sdrplayPPM = sdrplayPPM
        g.sdrplayRfNotch = sdrplayRfNotch
        g.sdrplayDabNotch = sdrplayDabNotch
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
    @Published public var selection: UInt32? {
        didSet { if let icao = selection, icao != oldValue { selectionChanged(icao) } }
    }
    /// Flugzeugdaten aus dem Netz (Typ, Betreiber, Strecke, Foto) je ICAO-Adresse
    @Published public private(set) var details: [UInt32: AircraftWebInfo] = [:]
    /// Flugzeug im Fenster „Flugzeugdaten“
    @Published public var infoICAO: UInt32?
    @Published public private(set) var detailsLoading: Set<UInt32> = []
    @Published public var logEnabled: Bool { didSet { UserDefaults.standard.set(logEnabled, forKey: "adsbLogEnabled") } }
    /// Standort des Empfängers
    public var homePoint: GeoPoint? { didSet { applyConfiguration() } }
    /// Rückruf für Textausgabe im Web-Terminal
    public var onLogBroadcast: (@MainActor (String) -> Void)?

    public let settings: ADSBSettingsStore
    private let infoService: AircraftInfoService
    /// Wann und mit welchem Rufzeichen ein Flugzeug zuletzt abgefragt wurde
    private var lookedUp: [UInt32: (callsign: String?, at: Date)] = [:]
    private var autoInFlight = 0
    private var autoTick = 0
    private var source: ADSBIQSource?
    /// Kennung der aktuellen Quelle: eine verspätete „gestoppt“-Meldung einer alten Quelle darf die neue nicht beenden
    private var sourceToken = UUID()
    private var timer: Timer?
    private var active = false
    private var cancellables: Set<AnyCancellable> = []
    /// Aufnahme als Quelle (Entwicklung und Prüfung): gesetzt, dann statt des gewählten Geräts
    public var fileOverride: URL?
    /// Nur für Tests: liefert eine Quelle statt der Geräte
    var sourceFactory: ((ADSBSettingsStore) -> ADSBIQSource?)?
    public var fileRealtime = true

    public init(settings: ADSBSettingsStore, infoService: AircraftInfoService = .shared) {
        self.settings = settings
        self.infoService = infoService
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
            settings.$sdrplayTuner.map { _ in () }.eraseToAnyPublisher(),
            settings.$sdrplayIFGain.map { _ in () }.eraseToAnyPublisher(),
            settings.$sdrplayAGC.map { _ in () }.eraseToAnyPublisher(),
            settings.$sdrplayBias.map { _ in () }.eraseToAnyPublisher(),
            settings.$sdrplayPPM.map { _ in () }.eraseToAnyPublisher(),
            settings.$sdrplayRfNotch.map { _ in () }.eraseToAnyPublisher(), settings.$sdrplayDabNotch.map { _ in () }.eraseToAnyPublisher(),
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

    public func retry() {
        startSource()
    }

    public func startSource() {
        stopSource()
        status = .idle
        let src: ADSBIQSource
        if let made = sourceFactory?(settings) {
            src = made
        } else if let url = fileOverride {
            src = ADSBFileSource(url: url, realtime: fileRealtime, loop: false)
        } else {
            switch settings.source {
            case .hackrf: src = HackRFSource(settings: settings.gain)
            case .rtlsdr: src = RTLSDRSource(settings: settings.gain)
            case .sdrplay: src = SDRplayAPISource(settings: settings.gain)
            case .sdrconnect: src = SDRconnectSource(settings: settings.gain)
            case .file:
                status = .error("Keine Aufnahme gewählt (Knopf ÖFFNEN)")
                return
            }
        }
        applyConfiguration()
        let engine = self.engine
        let wait = fileOverride != nil && !fileRealtime
        let token = UUID()
        sourceToken = token
        do {
            try src.start(onData: { engine.feed($0, wait: wait) }, onStop: { [weak self] reason in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.sourceStopped(reason, token: token) } }
            })
            source = src
            status = .running(src.deviceDescription)
            markSession(src.deviceDescription)
        } catch {
            status = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    public func stopSource() {
        sourceToken = UUID()               // Meldungen der alten Quelle sind ab jetzt ungültig
        source?.stop()
        source = nil
        if case .running = status { status = .idle }
    }

    private func sourceStopped(_ reason: String?, token: UUID) {
        guard token == sourceToken, source != nil else { return }
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
        if let onLog = onLogBroadcast {
            for entry in s.recent.prefix(4) {
                onLog("\(APRSController.utc.string(from: entry.time))  \(entry.summary)\n")
            }
        }
        if settings.webLookup && settings.autoLookup { autoLookupStep() }
        // Entwicklungshilfe (Schnappschüsse): DIGIDEC_ADSB_SELECT=<ICAO hex> wählt dieses Flugzeug, sobald es in der Liste steht
        if selection == nil, let v = ProcessInfo.processInfo.environment["DIGIDEC_ADSB_SELECT"], let icao = UInt32(v, radix: 16), aircraft.contains(where: { $0.icao == icao && $0.hasPosition }) {
            selection = icao
        }
    }

    // MARK: Flugzeugdaten aus dem Netz

    /// Ein Flugzeug wurde gewählt: Typ, Betreiber und Strecke holen (ohne Foto), sofern erlaubt und noch nicht bekannt
    private func selectionChanged(_ icao: UInt32) {
        guard settings.webLookup, details[icao] == nil, !detailsLoading.contains(icao) else { return }
        let callsign = aircraft(icao)?.callsign
        Task { await loadDetails(icao, callsign: callsign, photo: false) }
    }

    public func showInfo(for icao: UInt32) { infoICAO = icao }

    public func aircraft(_ icao: UInt32) -> ADSBAircraft? { aircraft.first { $0.icao == icao } }

    /// Daten zu einem Flugzeug laden (Fenster: mit Foto). Ohne `force` zählt der Zwischenspeicher.
    public func loadDetails(_ icao: UInt32, callsign: String?, photo: Bool, force: Bool = false) async {
        guard settings.webLookup else { return }
        let q = AircraftQuery(icao: icao, callsign: callsign)
        detailsLoading.insert(icao)
        if force { await infoService.forget(q) }
        let info = await infoService.lookup(q, photo: photo, useCache: !force)
        detailsLoading.remove(icao)
        // Fehlgeschlagene Abfragen überschreiben keine guten Daten
        if !info.failed || details[icao] == nil { details[icao] = info }
        lookedUp[icao] = (q.callsign, Date())
    }

    /// Im Hintergrund: höchstens eine Abfrage pro Sekunde, zwei gleichzeitig; Fehler erst nach zehn Minuten wieder
    private func autoLookupStep() {
        autoTick += 1
        guard autoTick % 2 == 0, autoInFlight < 2 else { return }
        let now = Date()
        let candidate = aircraft.first { a in
            guard a.messages >= 3, a.callsign != nil || a.hasPosition else { return false }
            if let last = lookedUp[a.icao] {
                // Rufzeichen kam erst später: Strecke nachholen
                return last.callsign == nil && a.callsign != nil && now.timeIntervalSince(last.at) > 20
            }
            return true
        }
        guard let a = candidate else { return }
        let icao = a.icao, callsign = a.callsign
        lookedUp[icao] = (callsign, now)
        autoInFlight += 1
        Task { @MainActor in
            let q = AircraftQuery(icao: icao, callsign: callsign)
            var info = await infoService.cachedInfo(q)
            if info == nil || (q.callsign != nil && info?.route == nil && info?.notes.isEmpty != false) {
                info = await infoService.lookup(q, photo: false)
            }
            autoInFlight -= 1
            guard let info else { return }
            if info.failed {
                lookedUp[icao] = (callsign, Date().addingTimeInterval(600))      // zehn Minuten Ruhe
            } else {
                details[icao] = info
            }
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
        ADSBMapBuilder.content(aircraft, home: home, now: now, showTracks: settings.showTracks, selection: selection, details: details)
    }
}

// MARK: - Karte

public enum ADSBMapBuilder {
    /// Höhenfarbe: 0 ft (blau) … 40 000 ft (rot)
    public static func altitudeLevel(_ ft: Int?) -> Double? {
        ft.map { min(1, max(0, Double($0) / 40_000)) }
    }

    public static func content(_ list: [ADSBAircraft], home: GeoPoint?, now: Date, showTracks: Bool = true, selection: UInt32? = nil,
                               details: [UInt32: AircraftWebInfo] = [:]) -> MapContent {
        var markers: [MapMarker] = []
        var lines: [MapLine] = []
        for a in list {
            guard let pos = a.position, pos.isValid else { continue }
            let age = now.timeIntervalSince(a.lastSeen)
            var rows: [String] = ["ICAO \(a.icaoText)"]
            let web = details[a.icao]
            if let c = a.country { rows.append("\(c.flag) \(c.name)") }
            if let w = web {
                if let t = w.fullTypeName { rows.append(t + (w.registration.map { " (\($0))" } ?? "")) } else if let r = w.registration { rows.append(r) }
                if let o = w.owner ?? w.route.map(\.airlineName), !o.isEmpty { rows.append("Betreiber: \(o)") }
                if let r = w.route {
                    var s = "Strecke: "
                    s += r.origin.map { "\($0.city.isEmpty ? $0.name : $0.city) (\($0.shortCode))" } ?? "?"
                    s += " → " + (r.destination.map { "\($0.city.isEmpty ? $0.name : $0.city) (\($0.shortCode))" } ?? "?")
                    rows.append(s + " laut Flugplan")
                    if let p = AircraftProgress.compute(route: r, position: pos, groundSpeedKn: a.groundSpeedKn) {
                        rows.append(String(format: "Flugfortschritt %.0f %% · Rest %.0f km", p.fraction * 100, p.remainingKm) + (p.etaText.map { " · ca. \($0)" } ?? ""))
                    }
                }
            }
            let shape = AircraftClass.classify(category: a.category, typeCode: a.typeCode, icaoType: web?.icaoType, groundSpeedKn: a.groundSpeedKn,
                                               altitudeFt: a.altitudeFt, onGround: a.onGround)
            if let cat = a.categoryText { rows.append(cat) }
            rows.append("Darstellung: \(shape.label)" + (web?.icaoType.map { " (\($0))" } ?? ""))
            if let alt = a.altitudeFt {
                rows.append(a.onGround == true ? "Am Boden" : "Höhe \(alt) ft (\(a.altitudeText ?? "")) · \(Int((Double(alt) * 0.3048).rounded())) m" + (a.altitudeIsGNSS ? " (GNSS)" : ""))
            }
            if let v = a.groundSpeedKn {
                rows.append(String(format: "%.0f kn · %.0f km/h", v, v * 1.852) + (a.trackDeg.map { String(format: " · Kurs %.0f°", $0) } ?? ""))
            }
            if let vr = a.verticalRateFpm, vr != 0 { rows.append("\(vr > 0 ? "Steigen" : "Sinken") \(abs(vr)) ft/min") }
            if let sq = a.squawk { rows.append("Kennung \(sq)") }
            if let e = a.emergencyText { rows.append("⚠ \(e)") }
            if let h = home {
                let km = Geo.distanceKm(h, pos), b = Geo.bearing(from: h, to: pos)
                rows.append("\(Geo.formatKm(km)) \(Geo.compass(b)) (\(Int(b.rounded()))°)")
            }
            rows.append("\(a.messages) Meldungen, \(a.positionMessages) Positionen" + (a.levelDB.map { String(format: ", %.0f dB", $0) } ?? ""))
            var sub: [String] = []
            if let t = a.altitudeText { sub.append(t) }
            if let v = a.groundSpeedKn { sub.append(String(format: "%.0f kn", v)) }
            if let r = web?.route?.routeText { sub.append(r) }
            sub.append("vor \(Int(age)) s")
            var tone: MapTone = age > 60 ? .dim : .normal
            if a.emergencyText != nil { tone = .alert }
            else if a.id == selection { tone = .highlight }
            let track = showTracks ? a.track.map { GeoPoint(lat: $0.lat, lon: $0.lon) } : []
            markers.append(MapMarker(id: "adsb-\(a.icaoText)", coordinate: pos, title: a.callsign ?? a.icaoText, subtitle: sub.joined(separator: " · "),
                                     details: rows, symbol: "airplane", tone: tone, heardAt: a.lastSeen,
                                     track: track.count > 1 ? track : [], headingDeg: a.trackDeg, valueLevel: a.onGround == true ? nil : altitudeLevel(a.altitudeFt),
                                     silhouette: shape))
        }
        // Strecke des gewählten Flugzeugs: geflogener Teil blass, Rest hell, beide Flughäfen
        if let sel = selection, let a = list.first(where: { $0.id == sel }), let pos = a.position, let r = details[sel]?.route {
            if let o = r.origin {
                lines.append(MapLine(id: "adsb-route-done", points: [o.point, pos], tone: .dim, geodesic: true))
                markers.append(MapMarker(id: "adsb-apt-\(o.icao)", coordinate: o.point, title: o.shortCode, subtitle: "Start · \(o.name)", details: ["\(o.name), \(o.city)", "\(o.countryName)"],
                                         symbol: "airplane.departure", tone: .info))
            }
            if let d = r.destination {
                lines.append(MapLine(id: "adsb-route-rest", points: [pos, d.point], tone: .info, geodesic: true))
                markers.append(MapMarker(id: "adsb-apt-\(d.icao)", coordinate: d.point, title: d.shortCode, subtitle: "Ziel · \(d.name)", details: ["\(d.name), \(d.city)", "\(d.countryName)"],
                                         symbol: "airplane.arrival", tone: .info))
            }
        }
        var c = MapContent(markers: markers, lines: lines, home: home, emptyHint: "Noch kein Flugzeug mit Position empfangen")
        c.note = "Farbe: Flughöhe (blau tief, rot hoch)"
        return c
    }
}
