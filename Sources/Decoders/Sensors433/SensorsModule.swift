// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI

// Funksensoren (433,92 MHz und 868,3 MHz): Modul. Digidec liest die I/Q-Daten (2 MS/s) selbst vom Gerät, wie bei ADS-B, und
// zeigt alle gehörten Sensoren mit ihren letzten Werten: Thermometer, Wetterstationen, Regenmesser u. a.

// MARK: - Einstellungen

@MainActor
public final class SensorsSettingsStore: ObservableObject {
    @Published public var source: ADSBSourceKind { didSet { UserDefaults.standard.set(source.rawValue, forKey: "sensSource") } }
    @Published public var band: SensorBand { didSet { UserDefaults.standard.set(band.rawValue, forKey: "sensBand") } }
    @Published public var hackrfLNA: Int { didSet { UserDefaults.standard.set(hackrfLNA, forKey: "sensHackrfLNA") } }
    @Published public var hackrfVGA: Int { didSet { UserDefaults.standard.set(hackrfVGA, forKey: "sensHackrfVGA") } }
    @Published public var hackrfAmp: Bool { didSet { UserDefaults.standard.set(hackrfAmp, forKey: "sensHackrfAmp") } }
    @Published public var hackrfBias: Bool { didSet { UserDefaults.standard.set(hackrfBias, forKey: "sensHackrfBias") } }
    @Published public var rtlGain: Double { didSet { UserDefaults.standard.set(rtlGain, forKey: "sensRtlGain") } }
    @Published public var rtlBias: Bool { didSet { UserDefaults.standard.set(rtlBias, forKey: "sensRtlBias") } }
    @Published public var rtlPPM: Int { didSet { UserDefaults.standard.set(rtlPPM, forKey: "sensRtlPPM") } }
    @Published public var sdrconnectHost: String { didSet { UserDefaults.standard.set(sdrconnectHost, forKey: "sensSdrHost") } }
    @Published public var sdrconnectPort: Int { didSet { UserDefaults.standard.set(sdrconnectPort, forKey: "sensSdrPort") } }
    @Published public var sdrplayLNAState: Int { didSet { UserDefaults.standard.set(sdrplayLNAState, forKey: "sensSdrLNA") } }
    @Published public var sdrplayTuner: Int { didSet { UserDefaults.standard.set(sdrplayTuner, forKey: "sensSdrTuner") } }
    @Published public var sdrplayIFGain: Int { didSet { UserDefaults.standard.set(sdrplayIFGain, forKey: "sensSdrIFGain") } }
    @Published public var sdrplayAGC: Bool { didSet { UserDefaults.standard.set(sdrplayAGC, forKey: "sensSdrAGC") } }
    @Published public var sdrplayBias: Bool { didSet { UserDefaults.standard.set(sdrplayBias, forKey: "sensSdrBias") } }
    @Published public var sdrplayPPM: Int { didSet { UserDefaults.standard.set(sdrplayPPM, forKey: "sensSdrPPM") } }
    /// Sensoren nach dieser Zeit ohne Meldung aus der Liste nehmen (Minuten, 0 = nie)
    @Published public var expireMinutes: Int { didSet { UserDefaults.standard.set(expireMinutes, forKey: "sensExpireMinutes") } }

    public init() {
        let d = UserDefaults.standard
        source = d.string(forKey: "sensSource").flatMap(ADSBSourceKind.init(rawValue:)) ?? .rtlsdr
        band = d.string(forKey: "sensBand").flatMap(SensorBand.init(rawValue:)) ?? .mhz433
        // Der 8-Bit-Wandler des HackRF braucht für schwache Sensoren viel Verstärkung: mit LNA 32/VGA 28 liegt das Rauschen unter 1 Stufe und die Telegramme gehen unter.
        // Frühere Fassungen speicherten diese zu niedrigen Werte; einmalig auf 40/40 setzen (danach gilt wieder, was der Nutzer einstellt).
        if d.object(forKey: "sensHackrfGainV2") == nil {
            d.set(40, forKey: "sensHackrfLNA")
            d.set(40, forKey: "sensHackrfVGA")
            d.set(true, forKey: "sensHackrfGainV2")
        }
        hackrfLNA = d.object(forKey: "sensHackrfLNA") as? Int ?? 40
        hackrfVGA = d.object(forKey: "sensHackrfVGA") as? Int ?? 40
        hackrfAmp = d.object(forKey: "sensHackrfAmp") as? Bool ?? false
        hackrfBias = d.object(forKey: "sensHackrfBias") as? Bool ?? false
        rtlGain = d.object(forKey: "sensRtlGain") as? Double ?? 0
        rtlBias = d.object(forKey: "sensRtlBias") as? Bool ?? false
        rtlPPM = d.object(forKey: "sensRtlPPM") as? Int ?? 0
        sdrconnectHost = d.string(forKey: "sensSdrHost") ?? "127.0.0.1"
        sdrconnectPort = d.object(forKey: "sensSdrPort") as? Int ?? 5454
        sdrplayLNAState = d.object(forKey: "sensSdrLNA") as? Int ?? 0
        sdrplayTuner = d.object(forKey: "sensSdrTuner") as? Int ?? 0
        sdrplayIFGain = d.object(forKey: "sensSdrIFGain") as? Int ?? 40
        sdrplayAGC = d.object(forKey: "sensSdrAGC") as? Bool ?? true
        sdrplayBias = d.object(forKey: "sensSdrBias") as? Bool ?? false
        sdrplayPPM = d.object(forKey: "sensSdrPPM") as? Int ?? 0
        expireMinutes = d.object(forKey: "sensExpireMinutes") as? Int ?? 60
    }

    public var gain: ADSBGainSettings {
        var g = ADSBGainSettings()
        g.centerFrequencyHz = band.frequencyHz
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
        return g
    }
}

// MARK: - Darstellung der Werte

public enum SensorFormat {
    /// Anzeigename und Einheit je Messgröße; nicht aufgeführte Schlüssel (Prüfart, Kennungen …) erscheinen nicht in der Zusammenfassung
    static let items: [(key: String, label: String, unit: String, digits: Int)] = [
        ("temperature_C", "Temperatur", "°C", 1), ("temperature_1_C", "Temperatur 2", "°C", 1), ("humidity", "Feuchte", "%", 0), ("moisture", "Bodenfeuchte", "%", 0),
        ("pressure_hPa", "Luftdruck", "hPa", 1),
        ("wind_avg_m_s", "Wind", "m/s", 1), ("wind_max_m_s", "Böe", "m/s", 1), ("wind_avg_km_h", "Wind", "km/h", 1), ("wind_max_km_h", "Böe", "km/h", 1),
        ("wind_avg_mi_h", "Wind", "mi/h", 1), ("wind_max_mi_h", "Böe", "mi/h", 1), ("wind_dir_deg", "Richtung", "°", 0),
        ("rain_mm", "Regen", "mm", 1), ("rain_rate_mm_h", "Regenrate", "mm/h", 1), ("rain_in", "Regen", "in", 2), ("rain_rate_in_h", "Regenrate", "in/h", 1),
        ("uvi", "UV-Index", "", 1), ("uv", "UV", "", 0), ("light_lux", "Licht", "lx", 0),
        ("co2_ppm", "CO₂", "ppm", 0), ("pm2_5_ug_m3", "PM2,5", "µg/m³", 0), ("pm10_0_ug_m3", "PM10", "µg/m³", 0), ("hcho_ppb", "HCHO", "ppb", 0), ("voc_level", "VOC", "", 0),
        ("power_W", "Leistung", "W", 0), ("energy_kWh", "Energie", "kWh", 2), ("battery_V", "Batterie", "V", 2), ("radio_clock", "Funkuhr", "", 0),
    ]

    /// „19,0 °C · 71 % · Batterie schwach“
    public static func summary(_ r: SensorReading) -> String {
        var parts: [String] = []
        for item in items where item.key != "temperature_F" {
            guard let v = r[item.key] else { continue }
            if case .string(let s) = v { parts.append(s); continue }
            guard let n = v.number else { continue }
            let text = String(format: "%.\(item.digits)f", n).replacingOccurrences(of: ".", with: ",")
            parts.append(item.unit.isEmpty ? "\(item.label) \(text)" : (item.key == "temperature_C" || item.key == "humidity" ? "\(text) \(item.unit)" : "\(item.label) \(text) \(item.unit)"))
        }
        if r["temperature_C"] == nil, let f = r["temperature_F"]?.number { parts.insert(String(format: "%.1f °F", f).replacingOccurrences(of: ".", with: ","), at: 0) }
        if let ok = r.batteryOK, !ok { parts.append("Batterie schwach") }
        return parts.joined(separator: " · ")
    }

    /// Ein Wert, der sich für den Verlauf eignet (Temperatur, sonst erster Messwert)
    public static func trendValue(_ r: SensorReading) -> Double? {
        if let t = r.temperatureC { return t }
        for item in items { if let n = r[item.key]?.number { return n } }
        return nil
    }
}

// MARK: - Sensor in der Liste

public struct SensorStation: Identifiable, Equatable, Sendable {
    public var id: String
    public var model: String
    public var idText: String
    public var channelText: String
    public var firstSeen: Date
    public var lastSeen: Date
    /// Anzahl der Aussendungen (Wiederholungen eines Telegramms zählen einmal)
    public var transmissions = 1
    public var latest: SensorReading
    public var rssiDB: Double
    public var snrDB: Double
    public var frequencyOffsetHz: Double
    public var isFSK: Bool
    /// Verlauf der Messgröße (Zeit, Wert), höchstens 240 Punkte
    public var trend: [(Date, Double)] = []

    public static func == (a: SensorStation, b: SensorStation) -> Bool {
        a.id == b.id && a.lastSeen == b.lastSeen && a.transmissions == b.transmissions && a.latest == b.latest
    }

    public var summary: String { SensorFormat.summary(latest) }
}

/// Gleichartige unbekannte Pakete (gleiche Modulationsart, Breiten und Länge) = vermutlich dieselbe Quelle
public struct UnknownGroup: Identifiable, Sendable {
    public var id: String { signature }
    public var signature: String
    public var count = 1
    public var first: Date
    public var last: Date
    public var latest: UnknownPackage
    /// Zeitpunkte der Pakete (die letzten 60)
    public var times: [Date] = []
    public var maxRepeats = 0
    public var strongestDB: Double

    /// Mittlerer Abstand zwischen getrennten Aussendungen (Pausen über 3 s); `nil` bei weniger als drei
    public var intervalSeconds: Double? {
        let sorted = times.sorted()
        var gaps: [Double] = []
        for i in 1..<max(1, sorted.count) { let d = sorted[i].timeIntervalSince(sorted[i - 1]); if d > 3 { gaps.append(d) } }
        guard gaps.count >= 2 else { return nil }
        gaps.sort()
        return gaps[gaps.count / 2]
    }

    /// Eine Quelle, die sich regelmäßig meldet (Abstand zwischen 5 s und 30 min, streut höchstens ±20 %), ist ein guter Kandidat für einen Sensor
    public var isPeriodic: Bool {
        guard let median = intervalSeconds, median >= 5, median <= 1800 else { return false }
        let sorted = times.sorted()
        var gaps: [Double] = []
        for i in 1..<max(1, sorted.count) { let d = sorted[i].timeIntervalSince(sorted[i - 1]); if d > 3 { gaps.append(d) } }
        let close = gaps.filter { abs($0 - median) <= median * 0.2 }.count
        return close >= max(2, gaps.count * 6 / 10)
    }
}

public struct SensorLogEntry: Identifiable, Sendable {
    public let id = UUID()
    public var time: Date
    public var event: SensorEvent
    public var summary: String
}

// MARK: - Engine

/// Verarbeitet die I/Q-Daten auf einem eigenen Faden: Abwärtsumsetzung → Pulserkennung → Gerätedecoder
public final class SensorsEngine: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var events: [SensorEvent] = []
        public var packages = 0
        public var ookPackages = 0
        public var fskPackages = 0
        public var decoded = 0
        /// Pakete ohne Treffer (nur die mit genug Pulsen) und ihre Analyse seit dem letzten Abruf
        public var unknownPackages = 0
        public var unknown: [UnknownPackage] = []
        /// Mittlere Auslenkung der I/Q-Werte (0 … 127) und Anteil übersteuerter Abtastwerte
        public var activity = 0.0
        public var clippedFraction = 0.0
        public var noiseDB = -60.0
        public var droppedBlocks = 0
        public var processRate = 0
    }

    private let queue = DispatchQueue(label: "com.peterbetz.digidec.sensors", qos: .userInitiated)
    private let lock = NSLock()
    private var receiver: SensorReceiver?
    private var decimator = IQDecimator(factor: 1)
    private var scratch: [UInt8] = []
    private var pendingBytes = 0
    private var droppedBlocks = 0
    private var events: [SensorEvent] = []
    private var unknownBuffer: [UnknownPackage] = []
    private var activity = 0.0
    private var clipped = 0, total = 0
    private var noiseDB = -60.0
    private var processRate = 0
    private var sourceRate = 2_000_000
    private var band = SensorBand.mhz433
    private var removeDC = true
    private var dcI = 127.5, dcQ = 127.5
    static let maxPending = 8 * 1024 * 1024

    public init() {}

    /// - Parameters:
    ///   - sourceRate: Abtastrate der Quelle (Geräte 2 MS/s; Aufnahmen meist 250 kS/s oder 1 MS/s)
    ///   - removeDC: Gleichanteil (Mittenspitze der Geräte) entfernen; bei Aufnahmen aus (sie sind schon fertig aufbereitet)
    public func configure(sourceRate: Int, band: SensorBand, removeDC: Bool) {
        queue.async { [self] in
            self.sourceRate = sourceRate
            self.band = band
            self.removeDC = removeDC
            let target = band.processingRate
            let factor = max(1, sourceRate / target)
            processRate = sourceRate / factor
            decimator = IQDecimator(factor: factor)
            let devices = SensorCatalog.all.filter { $0.bands.contains(band) }
            let rx = SensorReceiver(sampleRate: processRate, devices: devices, centerFrequency: band.frequencyHz)
            rx.onEvent = { [weak self] e in self?.lock.withLock { self?.events.append(e) } }
            rx.onPackage = { [weak self] _, d in self?.lock.withLock { self?.noiseDB = d.noiseDB } }
            rx.onUnknown = { [weak self] u in self?.lock.withLock { self?.unknownBuffer.append(u) } }
            receiver = rx
            dcI = 127.5; dcQ = 127.5
        }
    }

    public func reset() {
        queue.async { [self] in
            receiver?.reset()
            decimator.reset()
            lock.withLock { events.removeAll(); unknownBuffer.removeAll(); droppedBlocks = 0 }
        }
    }

    /// Neue I/Q-Daten (vom Faden der Quelle): kopieren und weitergeben, bei Rückstau verwerfen
    public func feed(_ buffer: UnsafeBufferPointer<UInt8>, wait: Bool = false) {
        let n = buffer.count
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
        guard let receiver else { return }
        data.withUnsafeBytes { raw in
            let buf = raw.bindMemory(to: UInt8.self)
            // Aussteuerung
            var sum = 0, clip = 0
            var i = 0
            while i < buf.count {
                let a = Int(buf[i]) - 128
                sum += abs(a)
                if buf[i] == 0 || buf[i] == 255 { clip += 1 }
                i += 8                                                      // jeder vierte Abtastwert genügt
            }
            let counted = max(1, (buf.count + 7) / 8)
            lock.withLock {
                activity += (Double(sum) / Double(counted) - activity) * 0.2
                if removeDC { clipped += clip; total += counted }          // nur bei Geräten: Aufnahmen sind schon aufbereitet
            }
            decimator.process(buf, into: &scratch)
            if removeDC { removeCenterSpike(&scratch) }
            scratch.withUnsafeBufferPointer { receiver.process($0) }
        }
    }

    /// Gleichanteil abziehen (langsames Mittel über die Ausgabe): die Mittenspitze der Geräte würde sonst als Träger gelten
    private func removeCenterSpike(_ x: inout [UInt8]) {
        let alpha = 1.0 / 4096
        var k = 0
        while k + 1 < x.count {
            dcI += (Double(x[k]) - dcI) * alpha
            dcQ += (Double(x[k + 1]) - dcQ) * alpha
            x[k] = UInt8(max(0, min(255, Double(x[k]) - dcI + 127.5 + 0.5)))
            x[k + 1] = UInt8(max(0, min(255, Double(x[k + 1]) - dcQ + 127.5 + 0.5)))
            k += 2
        }
    }

    public func snapshot() -> Snapshot {
        var s = Snapshot()
        queue.sync { [self] in
            s.packages = receiver?.packages ?? 0
            s.ookPackages = receiver?.ookPackages ?? 0
            s.fskPackages = receiver?.fskPackages ?? 0
            s.decoded = receiver?.decoded ?? 0
            s.unknownPackages = receiver?.unknown ?? 0
            s.processRate = processRate
        }
        lock.withLock {
            s.events = events
            events.removeAll()
            s.unknown = unknownBuffer
            unknownBuffer.removeAll()
            s.activity = activity
            s.clippedFraction = total > 0 ? Double(clipped) / Double(total) : 0
            s.noiseDB = noiseDB
            s.droppedBlocks = droppedBlocks
        }
        return s
    }
}

// MARK: - Controller

@MainActor
public final class SensorsController: ObservableObject {
    public let engine = SensorsEngine()
    public let logger = DecodeLogger(mode: "SENSOR")
    @Published public private(set) var stations: [SensorStation] = []
    @Published public private(set) var recent: [SensorLogEntry] = []
    @Published public private(set) var unknownGroups: [UnknownGroup] = []
    public let unknownLogger = DecodeLogger(mode: "SENSOR-UNBEKANNT")
    @Published public private(set) var status = ADSBStatus.idle
    @Published public private(set) var stats = SensorsEngine.Snapshot()
    @Published public private(set) var activityHistory: [Double] = []
    @Published public var selection: String?
    @Published public var logEnabled: Bool { didSet { UserDefaults.standard.set(logEnabled, forKey: "sensLogEnabled") } }
    /// Aufnahme als Quelle (Entwicklung, Prüfung und „Datei“): gesetzt, dann statt des Geräts
    public var fileOverride: URL?
    public var fileRealtime = true
    /// Abtastrate der Aufnahme
    public var fileSampleRate = 250_000
    var sourceFactory: ((SensorsSettingsStore) -> ADSBIQSource?)?

    private let settings: SensorsSettingsStore
    private var source: ADSBIQSource?
    private var sourceToken = UUID()
    private var timer: Timer?
    private var active = false
    private var recentKeys: [String: (Date, String)] = [:]
    private var cancellables: Set<AnyCancellable> = []
    public static let maxRecent = 300
    public static let maxUnknownGroups = 200

    public init(settings: SensorsSettingsStore) {
        self.settings = settings
        logEnabled = UserDefaults.standard.object(forKey: "sensLogEnabled") as? Bool ?? true
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        let triggers: [AnyPublisher<Void, Never>] = [
            settings.$source.map { _ in () }.eraseToAnyPublisher(), settings.$band.map { _ in () }.eraseToAnyPublisher(),
            settings.$hackrfLNA.map { _ in () }.eraseToAnyPublisher(), settings.$hackrfVGA.map { _ in () }.eraseToAnyPublisher(),
            settings.$hackrfAmp.map { _ in () }.eraseToAnyPublisher(), settings.$hackrfBias.map { _ in () }.eraseToAnyPublisher(),
            settings.$rtlGain.map { _ in () }.eraseToAnyPublisher(), settings.$rtlBias.map { _ in () }.eraseToAnyPublisher(),
            settings.$rtlPPM.map { _ in () }.eraseToAnyPublisher(), settings.$sdrplayLNAState.map { _ in () }.eraseToAnyPublisher(),
            settings.$sdrplayTuner.map { _ in () }.eraseToAnyPublisher(), settings.$sdrplayIFGain.map { _ in () }.eraseToAnyPublisher(),
            settings.$sdrplayAGC.map { _ in () }.eraseToAnyPublisher(), settings.$sdrplayBias.map { _ in () }.eraseToAnyPublisher(),
            settings.$sdrplayPPM.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .dropFirst(triggers.count)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self, self.active else { return }
                self.stopSource()
                self.startSource()
            }
            .store(in: &cancellables)
    }

    public func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on { startSource() } else { stopSource() }
    }

    public func clear() {
        engine.reset()
        stations.removeAll()
        recent.removeAll()
        unknownGroups.removeAll()
        recentKeys.removeAll()
        activityHistory.removeAll()
        selection = nil
    }

    public func startSource() {
        stopSource()
        let src: ADSBIQSource
        var sourceRate = 2_000_000
        if let made = sourceFactory?(settings) {
            src = made
        } else if let url = fileOverride {
            sourceRate = fileSampleRate
            src = ADSBFileSource(url: url, realtime: fileRealtime, loop: false, sampleRate: sourceRate)
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
        engine.configure(sourceRate: sourceRate, band: settings.band, removeDC: fileOverride == nil)
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
            logger.markSession("Funksensoren · \(settings.band.title) · \(src.deviceDescription)")
        } catch {
            status = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    public func stopSource() {
        sourceToken = UUID()
        source?.stop()
        source = nil
        if case .running = status { status = .idle }
    }

    private func sourceStopped(_ reason: String?, token: UUID) {
        guard token == sourceToken, source != nil else { return }
        source = nil
        status = reason.map { .error($0) } ?? .idle
    }

    private func poll() {
        guard active || fileOverride != nil else { return }
        let s = engine.snapshot()
        stats = s
        activityHistory.append(s.activity)
        if activityHistory.count > 240 { activityHistory.removeFirst(activityHistory.count - 240) }
        let now = Date()
        for e in s.events { ingest(e, now: now) }
        for u in s.unknown { ingestUnknown(u, now: now) }
        if settings.expireMinutes > 0 {
            let limit = Double(settings.expireMinutes) * 60
            stations.removeAll { now.timeIntervalSince($0.lastSeen) > limit }
        }
    }

    /// Ein Telegramm aufnehmen (auch für Tests); Wiederholungen innerhalb von drei Sekunden zählen nicht neu
    public func ingest(_ e: SensorEvent, now: Date = Date()) {
        let key = e.reading.deviceKey
        let summary = SensorFormat.summary(e.reading)
        let signature = e.reading.fields.map { "\($0.key)=\($0.value.text)" }.joined(separator: ";")
        if let last = recentKeys[key], now.timeIntervalSince(last.0) < 3, last.1 == signature {
            if let i = stations.firstIndex(where: { $0.id == key }) {
                stations[i].lastSeen = now
                stations[i].rssiDB = max(stations[i].rssiDB, e.rssiDB)
            }
            return
        }
        recentKeys[key] = (now, signature)
        if recentKeys.count > 500 { recentKeys = recentKeys.filter { now.timeIntervalSince($0.value.0) < 60 } }
        if let i = stations.firstIndex(where: { $0.id == key }) {
            stations[i].latest = e.reading
            stations[i].lastSeen = now
            stations[i].transmissions += 1
            stations[i].rssiDB = e.rssiDB; stations[i].snrDB = e.snrDB; stations[i].frequencyOffsetHz = e.frequencyOffsetHz
            if let v = SensorFormat.trendValue(e.reading) {
                stations[i].trend.append((now, v))
                if stations[i].trend.count > 240 { stations[i].trend.removeFirst(stations[i].trend.count - 240) }
            }
        } else {
            var st = SensorStation(id: key, model: e.reading.model, idText: e.reading["id"]?.text ?? "", channelText: e.reading["channel"]?.text ?? "",
                                   firstSeen: now, lastSeen: now, latest: e.reading, rssiDB: e.rssiDB, snrDB: e.snrDB,
                                   frequencyOffsetHz: e.frequencyOffsetHz, isFSK: e.isFSK)
            if let v = SensorFormat.trendValue(e.reading) { st.trend = [(now, v)] }
            stations.append(st)
        }
        stations.sort { ($0.lastSeen, $0.id) > ($1.lastSeen, $1.id) }
        recent.append(SensorLogEntry(time: now, event: e, summary: summary))
        if recent.count > Self.maxRecent { recent.removeFirst(recent.count - Self.maxRecent) }
        if logEnabled { logger.append(Self.logLine(e, summary: summary, time: now), now: now) }
    }

    /// Ein unbekanntes Paket einer Gruppe zuordnen und (auf Wunsch) mit allen Breiten ins Protokoll schreiben
    public func ingestUnknown(_ u: UnknownPackage, now: Date = Date()) {
        let key = u.signature
        if let i = unknownGroups.firstIndex(where: { $0.signature == key }) {
            unknownGroups[i].count += 1
            unknownGroups[i].last = now
            unknownGroups[i].latest = u
            unknownGroups[i].times.append(now)
            if unknownGroups[i].times.count > 60 { unknownGroups[i].times.removeFirst() }
            unknownGroups[i].maxRepeats = max(unknownGroups[i].maxRepeats, u.repeats)
            unknownGroups[i].strongestDB = max(unknownGroups[i].strongestDB, u.rssiDB)
        } else {
            var g = UnknownGroup(signature: key, first: now, last: now, latest: u, strongestDB: u.rssiDB)
            g.times = [now]
            g.maxRepeats = u.repeats
            unknownGroups.append(g)
            if unknownGroups.count > Self.maxUnknownGroups {
                if let oldest = unknownGroups.indices.min(by: { unknownGroups[$0].last < unknownGroups[$1].last }) { unknownGroups.remove(at: oldest) }
            }
        }
        unknownGroups.sort { ($0.last, $0.signature) > ($1.last, $1.signature) }
        if logEnabled { unknownLogger.append(Self.unknownLogLine(u, time: now), now: now) }
    }

    /// „08:15:02  OOK PPM P500/L1000 40 Bit  −18 dB  Ablage 25 kHz  62 Pulse  Breiten µs: 500/1000 500/2000 …  Zeilen: {40} 1a2b…“
    nonisolated static func unknownLogLine(_ u: UnknownPackage, time: Date) -> String {
        var s = timeFormatter.string(from: time) + "  " + u.signature + String(format: "  %.0f dB  Ablage %.0f Hz  %d Pulse  Dauer %d µs", u.rssiDB, u.frequencyOffsetHz, u.numPulses, u.durationMicroseconds)
        s += "\n    Breiten (Puls/Lücke, µs): " + stride(from: 0, to: min(u.widths.count, 120), by: 2).map { "\(u.widths[$0])/\(u.widths[$0 + 1])" }.joined(separator: " ")
        for r in u.rows { s += "\n    " + r }
        return s + "\n"
    }

    nonisolated static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    nonisolated public static func time(_ d: Date) -> String { timeFormatter.string(from: d) + " UTC" }

    /// Abtastrate aus dem Dateinamen (`…_250k.cu8`, `…_1000k.cu8`, `…_2M.cu8`); sonst 250 kS/s wie bei rtl_433
    nonisolated public static func sampleRate(inFileName name: String) -> Int {
        if let r = name.range(of: #"_(\d+)k\."#, options: .regularExpression), let k = Int(name[r].dropFirst().dropLast(2)) { return k * 1000 }
        if let r = name.range(of: #"_(\d+)M\."#, options: .regularExpression), let m = Int(name[r].dropFirst().dropLast(2)) { return m * 1_000_000 }
        return 250_000
    }

    /// „08:15:02  Nexus-TH  id 181 Kanal 2  19,0 °C · 71 %“
    nonisolated public static func logLine(_ e: SensorEvent, summary: String, time: Date) -> String {
        var s = SensorsController.timeFormatter.string(from: time) + "  " + e.reading.model
        if let id = e.reading["id"] { s += "  id " + id.text }
        if let ch = e.reading["channel"] { s += " Kanal " + ch.text }
        return s + "  " + summary + "\n"
    }
}
