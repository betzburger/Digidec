// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os

// NDB (ungerichtete Funkfeuer, Langwelle und unteres Mittelwellenband): Modul. Digidec liest das Audio des Empfängers, findet den Ton der
// getasteten Kennung, liest die Morse-Kennung und gleicht sie mit einer Liste der Funkfeuer ab (Name, Ort, Entfernung). Die Frequenz
// kommt vom Funkgerät (rigctld) oder von Hand. Ein Suchlauf stellt das Funkgerät der Reihe nach auf die Funkfeuer in der Nähe.

// MARK: - Einstellungen

@MainActor
public final class NDBSettingsStore: ObservableObject {
    /// Frequenz von Hand (kHz); 0 = vom Funkgerät lesen
    @Published public var manualKHz: Double { didSet { UserDefaults.standard.set(manualKHz, forKey: "ndbManualKHz") } }
    /// Ton von Hand (Hz); 0 = suchen
    @Published public var fixedToneHz: Double { didSet { UserDefaults.standard.set(fixedToneHz, forKey: "ndbFixedTone") } }
    /// Umkreis für Liste, Karte und Suchlauf (km)
    @Published public var radiusKm: Double { didSet { UserDefaults.standard.set(radiusKm, forKey: "ndbRadiusKm") } }
    /// Verweildauer je Frequenz im Suchlauf (s)
    @Published public var dwellSeconds: Double { didSet { UserDefaults.standard.set(dwellSeconds, forKey: "ndbDwell") } }
    /// Vom Empfänger gefundener Ton (nicht gespeichert)
    @Published public var detectedToneHz: Double = 0

    public init() {
        let d = UserDefaults.standard
        manualKHz = d.object(forKey: "ndbManualKHz") != nil ? d.double(forKey: "ndbManualKHz") : 0
        fixedToneHz = d.object(forKey: "ndbFixedTone") != nil ? d.double(forKey: "ndbFixedTone") : 0
        radiusKm = d.object(forKey: "ndbRadiusKm") as? Double ?? 400
        dwellSeconds = d.object(forKey: "ndbDwell") as? Double ?? 45
    }
}

extension NDBSettingsStore: TuningTarget {
    public var centerHz: Double { fixedToneHz > 0 ? fixedToneHz : (detectedToneHz > 0 ? detectedToneHz : 1020) }
    public var tones: (mark: Double, space: Double) { (centerHz, centerHz) }
    public var markerBandwidth: Double { 60 }
    public func setCenter(_ hz: Double) { fixedToneHz = max(250, min(2400, hz)) }
}

// MARK: - Empfänger an der Pipeline

public final class NDBDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var reading: NDBReading
        public var idents: [String]
        public var inputDB: Double
    }

    private let pipeline: AudioPipeline
    private let receiver = NDBReceiver()
    private var enabled = false
    private let lock = OSAllocatedUnfairLock()
    private var pendingIdents: [String] = []
    private var latest = Output(reading: NDBReading(), idents: [], inputDB: -120)

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        receiver.onIdent = { [weak self] text in self?.lock.withLockUnchecked { self?.pendingIdents.append(text) } }
        pipeline.addSink(rate: NDBAudio.sampleRate) { [weak self] samples in self?.consume(samples) }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            if on != enabled { receiver.reset() }
            enabled = on
            if !on { lock.withLockUnchecked { pendingIdents.removeAll(); latest = Output(reading: NDBReading(), idents: [], inputDB: -120) } }
        }
    }

    public func reset() {
        pipeline.perform { [self] in
            receiver.reset()
            lock.withLockUnchecked { pendingIdents.removeAll() }
        }
    }

    public func setFixedTone(_ hz: Double) {
        pipeline.perform { [self] in receiver.fixedToneHz = hz > 0 ? hz : nil }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pendingIdents.removeAll() }
            var o = latest
            o.idents = pendingIdents
            return o
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled, !samples.isEmpty else { return }
        receiver.process(samples)
        let o = Output(reading: receiver.reading, idents: [], inputDB: receiver.inputDB)
        lock.withLockUnchecked { latest = o }
    }
}

// MARK: - Auswertung

public enum NDBFormat {
    /// Zweimal oder öfter gelesene Gruppe („ABCABC“) zur Kennung zusammenfassen
    public static func collapse(_ text: String) -> String {
        let chars = Array(text)
        let n = chars.count
        guard n >= 4 else { return text }
        for p in 2...(n / 2) where n % p == 0 && Array(chars[0..<p]) * (n / p) == chars { return String(chars[0..<p]) }
        return text
    }

    /// Träger in kHz aus der Dial-Frequenz des Funkgeräts: bei AM gleich der Dial-Frequenz; bei USB/LSB/CW ist ein Ton von 400 oder 1020 Hz die
    /// Modulation (Träger = Dial), jeder andere ein Überlagerungston (Träger = Dial ± Ton)
    public static func carrierKHz(dialHz: Int, mode: String?, toneHz: Double) -> Double {
        let dial = Double(dialHz) / 1000
        guard let m = mode?.uppercased(), m != "AM", m != "AMS", toneHz > 0 else { return dial }
        if abs(toneHz - 400) < 30 || abs(toneHz - 1020) < 30 { return dial }
        switch m {
        case "LSB", "CWR", "PKTLSB": return dial - toneHz / 1000
        default: return dial + toneHz / 1000
        }
    }

    public static func toneKind(_ toneHz: Double) -> String {
        if abs(toneHz - 400) < 30 { return "A2A 400 Hz" }
        if abs(toneHz - 1020) < 30 { return "A2A 1020 Hz" }
        return "Ton \(Int(toneHz.rounded())) Hz"
    }

    public static func khzText(_ f: Double) -> String { String(format: f.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f kHz" : "%.1f kHz", f).replacingOccurrences(of: ".", with: ",") }
}

private func * (lhs: [Character], rhs: Int) -> [Character] { Array([[Character]](repeating: lhs, count: rhs).joined()) }

public struct NDBHeard: Identifiable, Equatable, Sendable {
    public var id: String { ident + "@" + String(Int((frequencyKHz * 2).rounded())) }
    public var ident: String
    public var frequencyKHz: Double
    public var station: NDBStation?
    public var confirmedByList: Bool
    public var first: Date
    public var last: Date
    public var count: Int
    public var snrDB: Double
    public var km: Double?
}

public enum NDBScanStatus: Equatable, Sendable {
    case off
    case running(index: Int, total: Int, khz: Double)
}

// MARK: - Controller

@MainActor
public final class NDBController: ObservableObject {
    public let decoder: NDBDecoder
    public let logger = DecodeLogger(mode: "NDB")
    public let recorder: InputRecorder
    public let database: NDBDatabase
    @Published public private(set) var reading = NDBReading()
    @Published public private(set) var inputDB = -120.0
    @Published public private(set) var ident = ""
    @Published public private(set) var identConfirmed = false
    @Published public private(set) var match = NDBMatch.unknown
    @Published public private(set) var carrierKHz: Double?
    @Published public private(set) var rigMode: String?
    @Published public private(set) var reads: [NDBIdentTracker.Read] = []
    @Published public private(set) var heard: [NDBHeard] = []
    @Published public private(set) var scan = NDBScanStatus.off
    @Published public private(set) var scanLog: [String] = []
    @Published public private(set) var downloadMessage: String?
    @Published public private(set) var isDownloading = false
    @Published public private(set) var toneHistory: [Double] = []
    @Published public var selection: String?
    @Published public var logEnabled: Bool { didSet { UserDefaults.standard.set(logEnabled, forKey: "ndbLogEnabled") } }
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var lastRecording: URL?

    /// Dial-Frequenz (Hz) und Mode des Funkgeräts, solange es verbunden ist (gesetzt vom Hauptprogramm)
    public var rigState: () -> (hz: Int?, mode: String?) = { (nil, nil) }
    /// Funkgerät abstimmen (gesetzt vom Hauptprogramm)
    public var tuneRig: (RigTuneTarget) -> Void = { _ in }
    public var rigAvailable: () -> Bool = { false }
    public var home: () -> GeoPoint? = { nil }

    private let settings: NDBSettingsStore
    private var tracker = NDBIdentTracker()
    private var timer: Timer?
    private var active = false
    private var lastCarrier: Double?
    private var lastLog = Date.distantPast
    private var cancellables: Set<AnyCancellable> = []
    // Suchlauf
    private var scanList: [Double] = []
    private var scanStart = Date()
    private var scanIndex = 0
    private var scanFoundHere = false

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: NDBSettingsStore, database: NDBDatabase = .shared) {
        self.settings = settings
        self.database = database
        decoder = NDBDecoder(pipeline: pipeline)
        recorder = InputRecorder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "ndbLogEnabled") as? Bool ?? true
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        settings.$fixedToneHz
            .sink { [weak self] hz in self?.decoder.setFixedTone(hz) }
            .store(in: &cancellables)
    }

    public func setActive(_ on: Bool) {
        active = on
        decoder.setEnabled(on)
        if !on {
            stopScan()
            reading = NDBReading()
        }
    }

    public func clear() {
        decoder.reset()
        tracker.reset()
        ident = ""; identConfirmed = false; match = .unknown
        reads.removeAll(); heard.removeAll(); toneHistory.removeAll(); scanLog.removeAll()
    }

    public func toggleRecording() {
        if isRecording {
            lastRecording = recorder.stop()
            isRecording = false
            return
        }
        let name = InputRecorder.fileName(frequencyHz: carrierKHz.map { Int($0 * 1000) }, mode: nil, preset: "ndb", prefix: "NDB")
        recorder.start(url: InputRecorder.directory.appendingPathComponent(name))
        isRecording = true
        recordingDuration = 0
    }

    // MARK: Frequenz

    /// Aktuelle Dial-Frequenz in kHz (Funkgerät oder von Hand)
    private func currentFrequency() -> (carrier: Double?, mode: String?) {
        if settings.manualKHz > 0 { return (settings.manualKHz, nil) }
        let r = rigState()
        guard let hz = r.hz else { return (nil, nil) }
        return (NDBFormat.carrierKHz(dialHz: hz, mode: r.mode, toneHz: reading.present ? reading.toneHz : 0), r.mode)
    }

    // MARK: Verarbeitung

    private func poll() {
        guard active else { return }
        let out = decoder.takeOutput()
        let now = Date()
        if abs(out.inputDB - inputDB) >= 0.5 { inputDB = out.inputDB }
        reading = out.reading
        if out.reading.toneHz != settings.detectedToneHz, abs(out.reading.toneHz - settings.detectedToneHz) > 2 { settings.detectedToneHz = out.reading.toneHz }
        let f = currentFrequency()
        rigMode = f.mode
        // Frequenzwechsel: Ablauf von vorn
        if let new = f.carrier {
            if let old = lastCarrier, abs(new - old) > 0.9 {
                tracker.reset(); ident = ""; identConfirmed = false; match = .unknown; reads.removeAll()
                decoder.reset()
            }
            lastCarrier = new
        }
        carrierKHz = f.carrier
        for text in out.idents { ingest(text, now: now) }
        if scan != .off { scanTick(now: now) }
        if isRecording { recordingDuration = recorder.duration }
        if Int(now.timeIntervalSince1970 * 4) % 2 == 0 {
            toneHistory.append(reading.snrDB)
            if toneHistory.count > 240 { toneHistory.removeFirst(toneHistory.count - 240) }
        }
    }

    /// Eine gelesene Kennung aufnehmen (auch für Tests)
    public func ingest(_ raw: String, now: Date = Date()) {
        let text = NDBFormat.collapse(raw)
        let newlyConfirmed = tracker.add(text, at: now)
        ident = tracker.ident
        identConfirmed = tracker.confirmed
        reads = tracker.reads
        if logEnabled { logger.append(Self.utc.string(from: now) + "  \(carrierKHz.map { NDBFormat.khzText($0) } ?? "? kHz")  Kennung \(text)" + (tracker.confirmed ? " (bestätigt)" : "") + "\n", now: now) }
        guard tracker.confirmed else { return }
        if carrierKHz == nil { carrierKHz = currentFrequency().carrier }
        match = NDBMatch.evaluate(ident: ident, frequencyKHz: carrierKHz, database: database)
        var station: NDBStation?
        var listConfirmed = false
        switch match {
        case .confirmed(let s): station = s; listConfirmed = true
        case .identOnly(let s, _): station = s
        default: break
        }
        let f = carrierKHz ?? station?.frequencyKHz ?? 0
        let km = station.flatMap { s in home().map { Geo.distanceKm($0, s.point) } }
        let key = ident + "@" + String(Int((f * 2).rounded()))
        if let i = heard.firstIndex(where: { $0.id == key }) {
            heard[i].last = now
            heard[i].count += newlyConfirmed ? 1 : 0
            heard[i].snrDB = reading.snrDB
            heard[i].station = station ?? heard[i].station
            heard[i].confirmedByList = heard[i].confirmedByList || listConfirmed
        } else {
            heard.append(NDBHeard(ident: ident, frequencyKHz: f, station: station, confirmedByList: listConfirmed, first: now, last: now, count: 1, snrDB: reading.snrDB, km: km))
            if logEnabled, let s = station {
                logger.append(Self.utc.string(from: now) + "  NDB \(ident) \(NDBFormat.khzText(f))  \(s.name) (\(s.country))" + (km.map { "  \(Geo.formatKm($0))" } ?? "") + (listConfirmed ? "  Liste bestätigt" : "  Frequenz weicht ab") + "\n", now: now)
            }
        }
        heard.sort { $0.last > $1.last }
        scanFoundHere = true
    }

    // MARK: Liste

    public func downloadList() {
        guard !isDownloading else { return }
        isDownloading = true
        downloadMessage = "lade …"
        let db = database
        Task { [weak self] in
            do {
                let n = try await db.download()
                self?.downloadMessage = "\(n) Funkfeuer geladen"
            } catch {
                self?.downloadMessage = "Laden fehlgeschlagen: \(error.localizedDescription)"
            }
            self?.isDownloading = false
            self?.objectWillChange.send()
        }
    }

    /// Funkfeuer im Umkreis (für Liste und Suchlauf)
    public func nearby() -> [(station: NDBStation, km: Double)] {
        guard let h = home() else { return [] }
        return database.within(km: settings.radiusKm, of: h)
    }

    /// Das Funkgerät auf ein Funkfeuer stellen (AM, schmal)
    public func tune(to station: NDBStation) {
        settings.manualKHz = 0
        tuneRig(RigTuneTarget(dialHz: Int64((station.frequencyKHz * 1000).rounded()), mode: "AM", passbandHz: 2400))
    }

    // MARK: Suchlauf

    public func startScan() {
        guard rigAvailable() else { scanLog.insert("Kein Funkgerät verbunden (Suchlauf braucht die Abstimmung über rigctld)", at: 0); return }
        var seen = Set<Int>()
        scanList = nearby().compactMap { item in
            let k = Int((item.station.frequencyKHz * 2).rounded())
            return seen.insert(k).inserted ? item.station.frequencyKHz : nil
        }
        guard !scanList.isEmpty else { scanLog.insert("Keine Funkfeuer im Umkreis (Liste laden, Standort prüfen)", at: 0); return }
        scanIndex = 0
        scanLog.removeAll()
        beginScanStep()
    }

    public func stopScan() {
        if scan != .off { scanLog.insert("Suchlauf beendet", at: 0) }
        scan = .off
    }

    private func beginScanStep() {
        guard scanIndex < scanList.count else { stopScan(); return }
        let f = scanList[scanIndex]
        settings.manualKHz = 0
        tuneRig(RigTuneTarget(dialHz: Int64((f * 1000).rounded()), mode: "AM", passbandHz: 2400))
        scanStart = Date()
        scanFoundHere = false
        scan = .running(index: scanIndex + 1, total: scanList.count, khz: f)
    }

    private func scanTick(now: Date) {
        let elapsed = now.timeIntervalSince(scanStart)
        let dwell = max(15, settings.dwellSeconds)
        let done = (scanFoundHere && elapsed >= 12 && identConfirmed) || elapsed >= dwell
        guard done else { return }
        if case .running(_, _, let khz) = scan {
            let text = scanFoundHere && identConfirmed ? "\(NDBFormat.khzText(khz)): \(ident)" : "\(NDBFormat.khzText(khz)): nichts gelesen"
            scanLog.insert(text, at: 0)
        }
        scanIndex += 1
        beginScanStep()
    }

    // MARK: Karte

    public func mapContent(now: Date) -> MapContent {
        let h = home()
        var markers: [MapMarker] = []
        var lines: [MapLine] = []
        let heardKeys = Dictionary(heard.compactMap { e in e.station.map { ($0.id, e) } }, uniquingKeysWith: { a, _ in a })
        for item in nearby().prefix(400) {
            let s = item.station
            var tone = MapTone.dim
            var details = ["\(NDBFormat.khzText(s.frequencyKHz))", "\(s.country)"]
            details.append("\(Geo.formatKm(item.km)) \(Geo.compass(h.map { Geo.bearing(from: $0, to: s.point) } ?? 0))")
            var subtitle = "\(NDBFormat.khzText(s.frequencyKHz))"
            var glyph: String?
            if let e = heardKeys[s.id] {
                let age = now.timeIntervalSince(e.last)
                tone = e.confirmedByList ? (age < 900 ? .alert : .normal) : .info
                subtitle += " · gehört vor \(age < 90 ? "\(Int(age)) s" : age < 5400 ? "\(Int(age / 60)) min" : "\(Int(age / 3600)) h")"
                details.append("S/N \(Int(e.snrDB.rounded())) dB · \(e.count)× bestätigt")
                glyph = "✓"
                if let h { lines.append(MapLine(id: "l-" + s.id, points: [h, s.point], tone: tone, geodesic: true)) }
            } else if tone == .dim, s.frequencyKHz == carrierKHz || (carrierKHz.map { abs($0 - s.frequencyKHz) < 1.1 } ?? false) {
                tone = .highlight
                subtitle += " · auf der eingestellten Frequenz"
            }
            markers.append(MapMarker(id: s.id, coordinate: s.point, title: s.ident, subtitle: subtitle + " · \(s.name)", details: details, symbol: nil, glyph: glyph, tone: tone, heardAt: heardKeys[s.id]?.last))
        }
        return MapContent(markers: markers, lines: lines, home: h, emptyHint: h == nil ? "Standort (Locator) fehlt" : "Keine Funkfeuer im Umkreis")
    }

    // MARK: Anzeige

    public var diagnosis: (ok: Bool, title: String, advice: String) {
        if inputDB < -70 { return (false, "Kein Audio", "Am Eingang kommt kein Signal an. Das Funkgerät auf die Frequenz eines Funkfeuers (AM, 2 bis 3 kHz Bandbreite) stellen und das Audio an Digidec geben.") }
        if !reading.present { return (false, "Warten auf einen Ton", "Kein Kennungston gefunden. Ein Funkfeuer sendet den Ton (meist 400 oder 1020 Hz) nur zur Kennung, alle 10 bis 60 s. AM oder CW/USB wählen, genau auf die Frequenz abstimmen; nahe Funkfeuer im Abstand von 1 kHz mit schmalem Filter trennen.") }
        if identConfirmed { return (true, "Kennung bestätigt", "") }
        return (true, ident.isEmpty ? "Ton gefunden, warte auf die Kennung" : "Kennung gelesen, noch nicht bestätigt", "")
    }

    nonisolated public static func time(_ d: Date) -> String { utc.string(from: d) + " UTC" }
}
