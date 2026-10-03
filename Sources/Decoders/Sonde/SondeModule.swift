import Foundation
import Combine
import SwiftUI
import os

// MARK: - Flug einer Sonde

public enum SondePhase: String, Sendable {
    case ground, ascent, descent, landed, unknown

    public var label: String {
        switch self {
        case .ground:  return "AM BODEN"
        case .ascent:  return "AUFSTIEG"
        case .descent: return "ABSTIEG"
        case .landed:  return "GELANDET"
        case .unknown: return "?"
        }
    }
}

/// Ein Wegpunkt des Fluges
public struct SondeFix: Equatable, Sendable {
    public var time: Date
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double

    public var point: GeoPoint { GeoPoint(lat: latitude, lon: longitude) }
}

/// Eine empfangene Radiosonde mit ihrem bisherigen Flug
public struct SondeFlight: Identifiable, Equatable, Sendable {
    public var serial: String
    public var id: String { serial }
    public var model: String?
    /// Sendefrequenz laut Sonde (kHz)
    public var frequencyKHz: Int?
    public var firstHeard: Date
    public var lastHeard: Date
    public var frames = 0
    /// Letzter Rahmen mit Position (die übrigen Messwerte sind die zuletzt bekannten)
    public var latest: RS41Telemetry
    public var track: [SondeFix] = []
    public var maxAltitude = -1000.0
    public var launchAltitude: Double?

    public static let maxTrack = 20_000

    public init(first t: RS41Telemetry, at now: Date) {
        serial = t.serial
        firstHeard = now
        lastHeard = now
        latest = t
        model = t.model
        frequencyKHz = t.frequencyKHz
    }

    /// Einen Rahmen aufnehmen. Rückgabe `false`, wenn er schon bekannt war (gleiche Rahmennummer wie der letzte).
    @discardableResult
    public mutating func ingest(_ t: RS41Telemetry, at now: Date) -> Bool {
        if frames > 0, t.frame == latest.frame, t.hasPosition == latest.hasPosition, now.timeIntervalSince(lastHeard) < 2 { return false }
        frames += 1
        lastHeard = now
        if let m = t.model { model = m }
        if let f = t.frequencyKHz { frequencyKHz = f }
        var merged = t
        // Werte, die nicht in jedem Rahmen stehen, behalten den letzten bekannten Stand
        merged.temperature = t.temperature ?? latest.temperature
        merged.humidity = t.humidity ?? latest.humidity
        merged.pressure = t.pressure ?? latest.pressure
        merged.frequencyKHz = frequencyKHz
        merged.model = model
        merged.killCountdown = t.killCountdown ?? latest.killCountdown
        if t.hasPosition {
            latest = merged
            let fix = SondeFix(time: t.time ?? now, latitude: t.latitude ?? 0, longitude: t.longitude ?? 0, altitude: t.altitude ?? 0)
            if launchAltitude == nil { launchAltitude = fix.altitude }
            maxAltitude = max(maxAltitude, fix.altitude)
            // ruhende Sonde (GPS-Rauschen): nur gelegentlich einen Punkt
            if let last = track.last, Geo.distanceKm(last.point, fix.point) < 0.005, fix.time.timeIntervalSince(last.time) < 30 {
                track[track.count - 1].altitude = fix.altitude
            } else {
                track.append(fix)
                if track.count > Self.maxTrack { track.removeFirst(track.count - Self.maxTrack) }
            }
        } else {
            // ohne Position nur die Messwerte nachführen
            latest.temperature = merged.temperature
            latest.humidity = merged.humidity
            latest.pressure = merged.pressure
            latest.battery = t.battery ?? latest.battery
            latest.killCountdown = merged.killCountdown
        }
        return true
    }

    public var hasPosition: Bool { latest.hasPosition }
    public var point: GeoPoint? { latest.latitude.flatMap { lat in latest.longitude.map { GeoPoint(lat: lat, lon: $0) } } }

    /// Der Ballon ist geplatzt: deutlich unter der größten Höhe und im Sinkflug
    public var hasBurst: Bool {
        guard let alt = latest.altitude else { return false }
        return maxAltitude - alt > 400 && maxAltitude - (launchAltitude ?? 0) > 2000 && (latest.climb ?? 0) < -1
    }

    public func phase(now: Date) -> SondePhase {
        guard let alt = latest.altitude else { return .unknown }
        let climb = latest.climb ?? 0
        let age = now.timeIntervalSince(lastHeard)
        let height = alt - (launchAltitude ?? alt)
        if hasBurst {
            return age > 90 && height < 2500 ? .landed : .descent
        }
        if maxAltitude - alt > 400 && maxAltitude - (launchAltitude ?? 0) > 2000 && age > 90 && height < 2500 { return .landed }
        if climb > 1 { return .ascent }
        if height < 50, (latest.speed ?? 0) < 3 { return .ground }
        return .unknown
    }
}

// MARK: - Landeprognose

public enum SondeLanding {
    /// Grobe Prognose der Landestelle für eine sinkende Sonde: die Sinkgeschwindigkeit wächst mit der Höhe wie 1/√Luftdichte
    /// (Skalenhöhe 8,4 km), die waagerechte Geschwindigkeit bleibt wie zuletzt gemessen. Der Wind in tieferen Schichten ist unbekannt, deshalb nur eine Schätzung.
    public static func predict(_ flight: SondeFlight, now: Date) -> (point: GeoPoint, seconds: Double)? {
        guard flight.phase(now: now) == .descent, now.timeIntervalSince(flight.lastHeard) < 180,
              let alt = flight.latest.altitude, let p = flight.point, let climb = flight.latest.climb, climb < -1 else { return nil }
        let ground = flight.launchAltitude ?? 0
        guard alt > ground + 30 else { return nil }
        let h = 16_800.0
        let vNow = -climb
        let vGround = vNow * exp(-alt / h)
        guard vGround > 0.5 else { return nil }
        let seconds = h / vGround * (exp(-ground / h) - exp(-alt / h))
        guard seconds.isFinite, seconds > 0, seconds < 6 * 3600 else { return nil }
        let km = (flight.latest.speed ?? 0) * seconds / 1000
        let point = km > 0.01 ? Geo.destination(from: p, bearing: flight.latest.heading ?? 0, km: km) : p
        return (point, seconds)
    }
}

// MARK: - Einstellungen

@MainActor
public final class SondeSettingsStore: ObservableObject {
    /// Empfangsfrequenz in kHz (400000 … 406000, Raster der RS41: 10 kHz)
    @Published public var frequencyKHz: Int { didSet { UserDefaults.standard.set(frequencyKHz, forKey: "sondeFrequencyKHz") } }
    /// ZF-Filter des Empfängers in kHz (15 oder 50)
    @Published public var filterKHz: Int { didSet { UserDefaults.standard.set(filterKHz, forKey: "sondeFilterKHz") } }
    /// Wie lange eine Sonde nach dem letzten Rahmen in der Liste bleibt (Stunden)
    @Published public var keepHours: Double { didSet { UserDefaults.standard.set(keepHours, forKey: "sondeKeepHours") } }
    /// Ob das Funkgerät beim Moduswechsel auf diese Frequenz abgestimmt wird, regelt der Schalter QSY AUTO; hier nur Wert und Filter
    nonisolated public static let frequencyRange = 400_000...406_000

    public init() {
        let d = UserDefaults.standard
        let f = d.integer(forKey: "sondeFrequencyKHz")
        frequencyKHz = Self.frequencyRange.contains(f) ? f : 403_000
        let w = d.integer(forKey: "sondeFilterKHz")
        filterKHz = [15, 50].contains(w) ? w : 15
        let k = d.double(forKey: "sondeKeepHours")
        keepHours = (1...48).contains(k) ? k : 6
    }

    public var frequencyText: String { Self.text(frequencyKHz) }

    /// „403,500 MHz“
    nonisolated public static func text(_ kHz: Int) -> String {
        String(format: "%.3f MHz", Double(kHz) / 1000).replacingOccurrences(of: ".", with: ",")
    }

    /// Frequenz aus Text wie „403,5“, „403.500“ oder „403500“ (MHz oder kHz); nil außerhalb des Sondenbandes
    nonisolated public static func parse(_ s: String) -> Int? {
        let t = s.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "MHz", with: "").replacingOccurrences(of: "kHz", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let v = Double(t) else { return nil }
        let kHz = v < 1000 ? Int((v * 1000).rounded()) : Int(v.rounded())
        return frequencyRange.contains(kHz) ? kHz : nil
    }
}

extension SondeSettingsStore: TuningTarget {
    public var centerHz: Double { 2400 }
    public var tones: (mark: Double, space: Double) { (0, 0) }
    public var markerBandwidth: Double { 4800 }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .band("SONDE · Basisband (RS41: 4800 Bd, bis 4,8 kHz)") }
}

// MARK: - Decoder

/// RS41-Empfänger als 48-kHz-Senke an der Pipeline
public final class SondeDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var telemetry: [RS41Telemetry]
        public var stats: RS41Stats
        public var level: Double
        /// Pegel des Eingangs (Effektivwert) in dBFS
        public var inputDB: Double
    }

    public static let sampleRate = 48_000.0

    private let pipeline: AudioPipeline
    private let receiver = RS41Receiver(sampleRate: SondeDecoder.sampleRate)
    private var enabled = false
    private let lock = OSAllocatedUnfairLock()
    private var pending: [RS41Telemetry] = []
    private var statsNow = RS41Stats()
    private var levelNow = 0.0
    private var meanSquare = 0.0
    private var inputDBNow = -120.0

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        receiver.onTelemetry = { [weak self] t in self?.lock.withLockUnchecked { self?.pending.append(t) } }
        pipeline.addSink(rate: Self.sampleRate) { [weak self] samples in self?.consume(samples) }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            enabled = on
            if !on { receiver.reset() }
        }
    }

    /// Zähler der Diagnose auf null (z. B. beim Leeren der Liste)
    public func resetStats() {
        pipeline.perform { [self] in
            receiver.resetStats()
            lock.withLockUnchecked { statsNow = RS41Stats() }
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pending.removeAll() }
            return Output(telemetry: pending, stats: statsNow, level: levelNow, inputDB: inputDBNow)
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

/// Beurteilt anhand der Zähler, was im Empfang schiefgeht
public enum SondeDiagnosis {
    public enum Severity: Int, Sendable { case ok, waiting, problem }

    public struct Result: Equatable, Sendable {
        public var severity: Severity
        public var title: String
        public var advice: String
    }

    public static let silenceDB = -70.0

    public static func assess(inputDB: Double, stats: RS41Stats) -> Result {
        if inputDB < silenceDB && stats.headers == 0 {
            return Result(severity: .problem, title: "KEIN AUDIO",
                          advice: "Am Eingang liegt kein Signal an. Richtiger Kanal (L, R oder L+R) und Eingang gewählt? Rauschsperre offen?")
        }
        if stats.headers == 0 {
            return Result(severity: .waiting, title: "SUCHE SONDE",
                          advice: "Audio kommt an, aber noch kein RS41-Signal. Frequenz (400 … 406 MHz, Raster 10 kHz), Betriebsart FM mit 15-kHz- oder 50-kHz-Filter und offene Rauschsperre prüfen. Sonden senden jede Sekunde.")
        }
        if stats.frames == 0 && stats.partial == 0 {
            return Result(severity: .problem, title: "SIGNAL, ABER NICHTS LESBAR",
                          advice: "Der Rahmenkopf wird gefunden, aber die Daten sind nicht lesbar: Signal zu schwach (Antenne, Standort), übersteuert (Pegel senken) oder keine RS41 (andere Sondenart).")
        }
        if stats.frames == 0 {
            return Result(severity: .problem, title: "NUR TEILE LESBAR",
                          advice: "Die Fehlerkorrektur scheitert, einzelne Datenblöcke sind aber gültig: schwaches oder gestörtes Signal.")
        }
        if stats.failed > stats.frames {
            return Result(severity: .problem, title: "VIELE FEHLER",
                          advice: "Mehr verlorene als gute Rahmen: schwaches Signal oder Störungen; Antenne und Abstimmung prüfen.")
        }
        return Result(severity: .ok, title: "EMPFANG GUT", advice: "")
    }
}

// MARK: - Karte

public enum SondeMapBuilder {
    /// Elevationswinkel (Grad) der Sonde über dem Horizont vom Standort, grob (Erdkrümmung mit Brechung 4/3, Standorthöhe wie die Starthöhe)
    public static func elevation(from home: GeoPoint, to p: GeoPoint, altitude: Double, homeAltitude: Double) -> Double {
        let d = Geo.distanceKm(home, p) * 1000
        guard d > 1 else { return 90 }
        let curvature = d * d / (2 * 6_371_000 * 4 / 3)
        return atan2(altitude - homeAltitude - curvature, d) * 180 / .pi
    }

    static func ageText(_ s: Double) -> String {
        s < 90 ? "\(Int(s)) s" : s < 5400 ? "\(Int(s / 60)) min" : "\(Int(s / 3600)) h"
    }

    public static func content(_ flights: [SondeFlight], home: GeoPoint?, now: Date, selection: String?) -> MapContent {
        var markers: [MapMarker] = []
        var lines: [MapLine] = []
        for f in flights.sorted(by: { $0.lastHeard > $1.lastHeard }) {
            guard let p = f.point, let alt = f.latest.altitude else { continue }
            let phase = f.phase(now: now)
            let age = now.timeIntervalSince(f.lastHeard)
            var details = [Geo.format(p), String(format: "Höhe %.0f m", alt)]
            if let c = f.latest.climb { details.append(String(format: "%@ %.1f m/s", c >= 0 ? "Steigen" : "Sinken", abs(c)).replacingOccurrences(of: ".", with: ",")) }
            if let v = f.latest.speed, let h = f.latest.heading {
                details.append(String(format: "Wind: %.0f km/h aus Richtung %.0f°", v * 3.6, (h + 180).truncatingRemainder(dividingBy: 360)))
            }
            if let h = home {
                let km = Geo.distanceKm(h, p), b = Geo.bearing(from: h, to: p)
                details.append("\(Geo.formatKm(km)) \(Geo.compass(b)) (\(Int(b.rounded()))°)")
                if phase == .ascent || phase == .descent {
                    details.append(String(format: "Elevation etwa %.1f°", elevation(from: h, to: p, altitude: alt, homeAltitude: f.launchAltitude ?? 0)).replacingOccurrences(of: ".", with: ","))
                }
            }
            var values: [String] = []
            if let t = f.latest.temperature { values.append(String(format: "%.1f °C", t).replacingOccurrences(of: ".", with: ",")) }
            if let r = f.latest.humidity { values.append(String(format: "%.0f %% rF", r)) }
            if let pr = f.latest.pressure { values.append(String(format: "%.1f hPa", pr).replacingOccurrences(of: ".", with: ",")) }
            if !values.isEmpty { details.append(values.joined(separator: " · ")) }
            if f.hasBurst { details.append(String(format: "Ballon geplatzt in %.0f m Höhe", f.maxAltitude)) }
            if let bat = f.latest.battery { details.append(String(format: "Batterie %.1f V", bat).replacingOccurrences(of: ".", with: ",")) }
            if let kc = f.latest.killCountdown { details.append("Abschaltzähler \(kc / 60) min") }
            details.append("\(f.frames) Rahmen · \(f.track.count) Wegpunkte")
            // Weg: höchstens 800 Punkte
            let stride = max(1, (f.track.count + 798) / 799)
            var pts = f.track.enumerated().filter { $0.offset % stride == 0 }.map(\.element.point)
            if let last = f.track.last?.point, pts.last != last { pts.append(last) }
            var sub = (f.model ?? "RS41") + " · " + phase.label.capitalized
            if let khz = f.frequencyKHz { sub += " · " + SondeSettingsStore.text(khz) }
            sub += " · vor " + ageText(age)
            let tone: MapTone = age > 600 ? .dim : phase == .descent ? .highlight : phase == .landed ? .info : .normal
            markers.append(MapMarker(id: "sonde-" + f.serial, coordinate: p, title: f.serial, subtitle: sub, details: details, symbol: "balloon.fill",
                                     tone: tone, heardAt: f.lastHeard, track: pts.count > 1 ? pts : []))
            if let land = SondeLanding.predict(f, now: now) {
                var d = ["Geschätzt in etwa \(Int((land.seconds / 60).rounded())) min", "Annahme: Sinkgeschwindigkeit nimmt mit der Luftdichte ab, Wind bleibt wie gemessen"]
                if let h = home {
                    let km = Geo.distanceKm(h, land.point), b = Geo.bearing(from: h, to: land.point)
                    d.append("\(Geo.formatKm(km)) \(Geo.compass(b)) (\(Int(b.rounded()))°)")
                }
                markers.append(MapMarker(id: "sonde-land-" + f.serial, coordinate: land.point, title: "Landung ~", subtitle: f.serial, details: d,
                                         symbol: "flag.checkered", tone: .alert, heardAt: f.lastHeard))
                lines.append(MapLine(id: "sonde-fall-" + f.serial, points: [p, land.point], tone: .alert))
            }
            if let h = home, age < 300, Geo.distanceKm(h, p) > 5, f.serial == selection || selection == nil {
                lines.append(MapLine(id: "sonde-home-" + f.serial, points: [h, p], tone: .dim, geodesic: true))
            }
        }
        return MapContent(markers: markers, lines: lines, home: home, emptyHint: "Noch keine Sonde mit Position empfangen")
    }
}

// MARK: - Controller

@MainActor
public final class SondeController: ObservableObject {
    public let decoder: SondeDecoder
    public let logger = DecodeLogger(mode: "SONDE")
    @Published public private(set) var flights: [SondeFlight] = []
    @Published public var selection: String?
    @Published public private(set) var stats = RS41Stats()
    @Published public private(set) var inputDB = -120.0
    @Published public private(set) var level = 0.0
    /// Aufnahme des Eingangs (zur Fehlersuche und zum Nachdecodieren mit `decode_file.sh --sonde`)
    public let recorder: InputRecorder
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var lastRecording: URL?
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "sondeLogEnabled") }
    }
    public var rigDescription: String? {
        didSet { if rigDescription != oldValue { markSession() } }
    }

    private let settings: SondeSettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: SondeSettingsStore) {
        self.settings = settings
        decoder = SondeDecoder(pipeline: pipeline)
        recorder = InputRecorder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "sondeLogEnabled") as? Bool ?? true
        markSession()
        settings.$frequencyKHz.combineLatest(settings.$filterKHz)
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
        flights.removeAll()
        selection = nil
        decoder.resetStats()
        stats = RS41Stats()
    }

    /// Eingang aufnehmen (WAV in Quell-Abtastrate unter ~/Documents/Digidec/Recordings)
    public func toggleRecording() {
        if isRecording {
            lastRecording = recorder.stop()
            isRecording = false
            return
        }
        let name = InputRecorder.fileName(frequencyHz: settings.frequencyKHz * 1000, mode: "FM", preset: "RS41", prefix: "SONDE")
        recorder.start(url: InputRecorder.directory.appendingPathComponent(name))
        isRecording = true
        recordingDuration = 0
    }

    public var diagnosis: SondeDiagnosis.Result { SondeDiagnosis.assess(inputDB: inputDB, stats: stats) }

    public func markSession() {
        var h = "SONDE · \(settings.frequencyText) FM \(settings.filterKHz) kHz · RS41"
        if let rig = rigDescription { h += " · \(rig)" }
        logger.markSession(h)
    }

    private func poll() {
        let out = decoder.takeOutput()
        if out.stats != stats { stats = out.stats }
        level = out.level
        if abs(out.inputDB - inputDB) >= 0.5 { inputDB = out.inputDB }
        if isRecording { recordingDuration = recorder.duration }
        let now = Date()
        for t in out.telemetry { ingest(t, at: now) }
        // alte Sonden aus der Liste nehmen
        let keep = settings.keepHours * 3600
        let before = flights.count
        flights.removeAll { now.timeIntervalSince($0.lastHeard) > keep }
        if flights.count != before, let s = selection, !flights.contains(where: { $0.serial == s }) { selection = nil }
    }

    /// Einen Rahmen aufnehmen (auch für Tests und Dateiwiedergabe)
    public func ingest(_ t: RS41Telemetry, at now: Date = Date()) {
        if let i = flights.firstIndex(where: { $0.serial == t.serial }) {
            guard flights[i].ingest(t, at: now) else { return }
        } else {
            var f = SondeFlight(first: t, at: now)
            f.frames = 0
            f.ingest(t, at: now)
            flights.append(f)
            if selection == nil { selection = t.serial }
        }
        flights.sort { $0.lastHeard > $1.lastHeard }
        if logEnabled, t.hasPosition { logger.append(Self.logLine(t) + "\n", now: now) }
    }

    /// Kartenpunkte aller Sonden
    public func mapContent(home: GeoPoint?, now: Date) -> MapContent {
        SondeMapBuilder.content(flights, home: home, now: now, selection: selection)
    }

    /// Frequenzen, auf denen Sonden gehört wurden (kHz)
    public var heardFrequencies: [Int] {
        Array(Set(flights.compactMap(\.frequencyKHz))).sorted()
    }

    /// „2026-10-03 20:45:12;N3920808;112;48.76543;9.12345;1234.5;5.1;123.4;4.8;-12.3;45;650.2;9;3.0;403500“
    nonisolated public static func logLine(_ t: RS41Telemetry) -> String {
        func f(_ v: Double?, _ digits: Int) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "" }
        let time: String
        if let d = t.time {
            let fm = DateFormatter()
            fm.dateFormat = "yyyy-MM-dd HH:mm:ss"
            fm.timeZone = TimeZone(identifier: "UTC")
            fm.locale = Locale(identifier: "en_US_POSIX")
            time = fm.string(from: d)
        } else { time = "" }
        return [time + "Z", t.serial, String(t.frame), f(t.latitude, 5), f(t.longitude, 5), f(t.altitude, 1), f(t.speed, 1), f(t.heading, 1), f(t.climb, 1),
                f(t.temperature, 1), f(t.humidity, 0), f(t.pressure, 1), t.satellites.map(String.init) ?? "", f(t.battery, 1), t.frequencyKHz.map(String.init) ?? ""]
            .joined(separator: ";")
    }
}
