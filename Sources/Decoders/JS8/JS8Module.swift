// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os

// MARK: - Bänder

/// JS8-Standardfrequenzen (Dial, USB) wie in JS8Call
public enum JS8Band: String, CaseIterable, Identifiable, Codable, Sendable {
    case m160 = "160m", m80 = "80m", m40 = "40m", m30 = "30m", m20 = "20m"
    case m17 = "17m", m15 = "15m", m12 = "12m", m10 = "10m", m6 = "6m", m2 = "2m"

    public var id: String { rawValue }

    public var dialHz: Int {
        switch self {
        case .m160: return 1_842_000
        case .m80: return 3_578_000
        case .m40: return 7_078_000
        case .m30: return 10_130_000
        case .m20: return 14_078_000
        case .m17: return 18_104_000
        case .m15: return 21_078_000
        case .m12: return 24_922_000
        case .m10: return 28_078_000
        case .m6: return 50_318_000
        case .m2: return 144_178_000
        }
    }

    /// „14,078“
    public var dialLabel: String {
        String(format: "%.3f", Double(dialHz) / 1_000_000).replacingOccurrences(of: ".", with: ",")
    }

    /// Band zu einer Dial-Frequenz (± 3 kHz)
    public static func band(forDial hz: Int) -> JS8Band? {
        allCases.first { abs($0.dialHz - hz) <= 3_000 }
    }
}

// MARK: - Einstellungen

@MainActor
public final class JS8SettingsStore: ObservableObject {
    @Published public var band: JS8Band { didSet { save() } }
    /// Betriebsarten, die zugleich decodiert werden (mindestens eine)
    @Published public var modes: Set<JS8Submode> { didSet { save() } }
    /// Eigenes Rufzeichen (nur zum Hervorheben; Digidec sendet nie)
    @Published public var myCall: String { didSet { save() } }
    @Published public var locator: String { didSet { save() } }
    @Published public var core: JS8Core.Settings { didSet { save() } }
    /// Korrektur der Zeitbasis in Sekunden (Laufzeit Soundkarte → Decoder); positiv = Audio kommt später an
    @Published public var timeOffset: Double { didSet { save() } }
    /// Empfangsfrequenz im NF (Klick im Wasserfall) – Nachrichten dort erscheinen hervorgehoben
    @Published public private(set) var rxHz: Double
    /// Heartbeats und CQ-Rufe in der Liste zeigen
    @Published public var showHeartbeats: Bool { didSet { save() } }
    /// Rahmen mit geringer Güte zeigen (in Klammern)
    @Published public var showUncertain: Bool { didSet { save() } }
    /// Dial laut Funkgerät (rigctld), sonst nil
    @Published public var rigDialHz: Int?

    public init() {
        let d = UserDefaults.standard
        band = d.string(forKey: "js8Band").flatMap(JS8Band.init(rawValue:)) ?? .m20
        let raw = (d.array(forKey: "js8Modes") as? [Int]) ?? [JS8Submode.normal.rawValue]
        let set = Set(raw.compactMap(JS8Submode.init(rawValue:)))
        modes = set.isEmpty ? [.normal] : set
        myCall = d.string(forKey: "js8MyCall") ?? ""
        locator = d.string(forKey: "js8Locator") ?? "JN49WS"
        core = d.data(forKey: "js8Core").flatMap { try? JSONDecoder().decode(JS8Core.Settings.self, from: $0) } ?? JS8Core.Settings()
        timeOffset = d.object(forKey: "js8TimeOffset") as? Double ?? 0.0
        let rx = d.double(forKey: "js8RxHz")
        rxHz = (200...3500).contains(rx) ? rx : 1000
        showHeartbeats = d.object(forKey: "js8ShowHeartbeats") as? Bool ?? true
        showUncertain = d.object(forKey: "js8ShowUncertain") as? Bool ?? true
    }

    /// Wirksame Dial-Frequenz: Funkgerät, sonst gewähltes Band
    public var dialHz: Int { rigDialHz ?? band.dialHz }

    /// Betriebsart, nach der sich Marke und Bandbreite im Wasserfall richten: die langsamste gewählte
    public var markerMode: JS8Submode { modes.max() ?? .normal }

    public func setRx(_ hz: Double) {
        rxHz = min(max(hz, 200), 3500 - markerMode.bandwidth).rounded()
        UserDefaults.standard.set(rxHz, forKey: "js8RxHz")
    }

    /// Betriebsart zu- oder abschalten; die letzte bleibt immer an
    public func toggle(_ mode: JS8Submode) {
        if modes.contains(mode) {
            if modes.count > 1 { modes.remove(mode) }
        } else {
            modes.insert(mode)
        }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(band.rawValue, forKey: "js8Band")
        d.set(modes.map(\.rawValue).sorted(), forKey: "js8Modes")
        d.set(myCall, forKey: "js8MyCall")
        d.set(locator, forKey: "js8Locator")
        if let data = try? JSONEncoder().encode(core) { d.set(data, forKey: "js8Core") }
        d.set(timeOffset, forKey: "js8TimeOffset")
        d.set(showHeartbeats, forKey: "js8ShowHeartbeats")
        d.set(showUncertain, forKey: "js8ShowUncertain")
    }
}

extension JS8SettingsStore: TuningTarget {
    public var centerHz: Double { rxHz + markerMode.bandwidth / 2 }
    /// 8 Töne ab der Empfangsfrequenz; der oberste liegt 7 Tonabstände höher
    public var tones: (mark: Double, space: Double) { (rxHz + 7 * markerMode.toneSpacing, rxHz) }
    public var markerBandwidth: Double { markerMode.bandwidth }
    public func setCenter(_ hz: Double) { setRx(hz - markerMode.bandwidth / 2) }
}

// MARK: - Decoder

/// Sammelt 12-kHz-Audio mit Zeitstempel und decodiert jeden Zyklus jeder gewählten Betriebsart nach UTC im Hintergrund.
public final class JS8Decoder: @unchecked Sendable {
    public struct CycleResult: Sendable {
        public var cycleStart: Date
        public var submode: JS8Submode
        public var decodes: [JS8Decode]
        /// Rechenzeit in Sekunden
        public var duration: Double
        /// Anteil der Aussendung, für den Audio vorlag (0…1)
        public var coverage: Double
    }

    public static let rate = 12_000
    /// Längster Zyklus (SLOW) plus Reserve
    static let ringSeconds = 40

    private struct Job {
        var mode: JS8Submode
        var samples: [Float]
        var start: Date
        var coverage: Double
    }

    private let pipeline: AudioPipeline
    private let decodeQueue = DispatchQueue(label: "digidec.js8.decode", qos: .userInitiated)

    // Nur auf der Verarbeitungs-Queue
    private var enabled = false
    private var ring = [Float](repeating: 0, count: JS8Decoder.ringSeconds * JS8Decoder.rate)
    private var written: Int64 = 0
    private var offset: Double?
    private var lastCycle: [JS8Submode: Double] = [:]
    private var modes: Set<JS8Submode> = [.normal]
    private var settings = JS8Core.Settings()
    private var preferHz = 1_000.0
    private var timeOffset = 0.0

    private let lock = OSAllocatedUnfairLock()
    private var pending: [CycleResult] = []
    private var jobs = 0

    /// Uhr (für Tests ersetzbar)
    public var clock: @Sendable () -> Double = { Date().timeIntervalSince1970 }

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addSink(rate: Double(Self.rate)) { [weak self] samples in self?.consume(samples) }
    }

    public func configure(modes: Set<JS8Submode>, settings: JS8Core.Settings, preferHz: Double, timeOffset: Double) {
        pipeline.perform { [self] in
            self.modes = modes.isEmpty ? [.normal] : modes
            self.settings = settings
            self.preferHz = preferHz
            self.timeOffset = timeOffset
        }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            enabled = on
            if !on { offset = nil }
        }
    }

    public var isBusy: Bool { lock.withLockUnchecked { jobs > 0 } }

    public func takeResults() -> [CycleResult] {
        lock.withLockUnchecked {
            defer { pending.removeAll() }
            return pending
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled else { return }
        for v in samples {
            ring[Int(written % Int64(ring.count))] = v
            written += 1
        }
        let now = clock()
        let measured = now - timeOffset - Double(written) / Double(Self.rate)
        if let o = offset, abs(o - measured) < 0.5 {
            offset = o + (measured - o) * 0.02
        } else {
            offset = measured
        }
        guard let offset else { return }
        for mode in modes {
            let period = mode.periodSeconds
            let cycle = (now / period).rounded(.down) * period
            guard now - cycle >= mode.decodeAt, cycle != lastCycle[mode] else { continue }
            lastCycle[mode] = cycle
            // Samples ab Zyklusbeginn bis jetzt
            let first = Int64(((cycle - offset) * Double(Self.rate)).rounded())
            let oldest = max(0, written - Int64(ring.count))
            let from = max(first, oldest)
            let have = Double(written - from) / Double(Self.rate)
            let need = mode.startDelay + mode.txDuration
            guard have > 0.7 * need, written > first else { continue }   // zu wenig Audio: nicht decodierbar
            var buf = [Float](repeating: 0, count: Int(written - first))
            for i in from..<written { buf[Int(i - first)] = ring[Int(i % Int64(ring.count))] }
            let coverage = min(1, have / need)
            let busy = lock.withLockUnchecked { () -> Bool in
                if jobs >= 4 { return true }   // Rückstand: diesen Zyklus auslassen
                jobs += 1
                return false
            }
            guard !busy else { continue }
            let job = Job(mode: mode, samples: buf, start: Date(timeIntervalSince1970: cycle), coverage: coverage)
            let s = settings
            let prefer = preferHz
            decodeQueue.async { [weak self] in
                let t0 = Date()
                let list = JS8Core.decode(job.samples, submode: job.mode, cycleStart: job.start, settings: s, preferHz: prefer)
                let result = CycleResult(cycleStart: job.start, submode: job.mode, decodes: list,
                                         duration: Date().timeIntervalSince(t0), coverage: job.coverage)
                self?.lock.withLockUnchecked {
                    self?.pending.append(result)
                    self?.jobs -= 1
                }
            }
        }
    }
}

// MARK: - Controller

@MainActor
public final class JS8Controller: ObservableObject {
    public let decoder: JS8Decoder
    public let logger = DecodeLogger(mode: "JS8")
    @Published public private(set) var lines: [JS8Line] = []
    @Published public private(set) var stations: [JS8Station] = []
    @Published public private(set) var lastCycle: JS8Decoder.CycleResult?
    @Published public private(set) var cycleCount = 0
    @Published public private(set) var frameCount = 0
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "js8LogEnabled") }
    }

    public static let maxStations = 500
    private var aggregator = JS8Aggregator()
    private let settings: JS8SettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var applied: (Set<JS8Submode>, JS8Core.Settings, Double, Double)?

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    nonisolated static let clockUTC: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: JS8SettingsStore) {
        self.settings = settings
        decoder = JS8Decoder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "js8LogEnabled") as? Bool ?? true
        applySettings()
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
    }

    public func clear() {
        aggregator.clear()
        lines = []
        stations.removeAll()
    }

    /// Nachrichten, die gezeigt werden (Filter Heartbeats, unsichere)
    public var visible: [JS8Line] {
        lines.filter { l in
            (settings.showHeartbeats || !(l.isHeartbeat || l.isCQ))
                && (settings.showUncertain || !l.isUncertain)
        }
    }

    /// Nachrichten nahe der Empfangsfrequenz (innerhalb der Bandbreite) oder an das eigene Rufzeichen
    public var rxLines: [JS8Line] {
        let me = settings.myCall.uppercased()
        return lines.filter { l in
            (l.freqHz >= settings.rxHz - 10 && l.freqHz <= settings.rxHz + l.submode.bandwidth + 10)
                || (!me.isEmpty && (l.to == me || l.from == me))
        }
    }

    private func applySettings() {
        let a = (settings.modes, settings.core, settings.timeOffset, settings.rxHz)
        if applied.map({ $0.0 != a.0 || $0.1 != a.1 || $0.2 != a.2 || $0.3 != a.3 }) ?? true {
            applied = a
            decoder.configure(modes: a.0, settings: a.1, preferHz: a.3, timeOffset: a.2)
        }
    }

    private func poll() {
        for result in decoder.takeResults() {
            lastCycle = result
            cycleCount += 1
            frameCount += result.decodes.count
            for d in result.decodes {
                let i = aggregator.add(d)
                noteStation(d, line: aggregator.lines[i])
            }
            lines = aggregator.lines
            if logEnabled { log(result) }
        }
    }

    /// Station aus dem Rahmen vermerken: Absender des Rahmens, bei Freitext das Rufzeichen vor dem Doppelpunkt
    private func noteStation(_ d: JS8Decode, line: JS8Line) {
        guard !d.isUncertain else { return }
        var call = d.unpacked?.from
        if call == nil, d.bits.contains(.first) { call = JS8Calls.leadingCall(d.text) }
        guard let call, JS8Calls.isCall(call) else { return }
        let me = settings.myCall.uppercased()
        let involvesMe = !me.isEmpty && (call == me || d.unpacked?.to == me)
        var s = stations.first(where: { $0.call == call })
            ?? JS8Station(call: call, grid: nil, snrDB: d.snrDB, freqHz: d.freqHz, submode: d.submode, lastHeard: d.cycleStart,
                          count: 0, lastText: "", dxcc: DXCCDatabase.shared.lookup(call))
        s.snrDB = d.snrDB
        s.freqHz = d.freqHz
        s.submode = d.submode
        s.lastHeard = d.cycleStart
        s.count += 1
        s.lastText = d.text
        s.mentionsMe = s.mentionsMe || involvesMe
        if let grid = d.unpacked?.grid {
            s.grid = grid
            if let dist = Maidenhead.distance(from: settings.locator, to: grid) {
                s.km = dist.km
                s.bearing = dist.bearing
            }
        }
        if let i = stations.firstIndex(where: { $0.call == call }) {
            stations[i] = s
        } else {
            stations.append(s)
            if stations.count > Self.maxStations { stations.removeFirst(stations.count - Self.maxStations) }
        }
    }

    /// Zeile wie ALL.TXT von JS8Call: „12:34:56  -12  0.3  1234  A  KN4CRD: TEST  3“
    nonisolated public static func allTxtLine(_ d: JS8Decode) -> String {
        let t = clockUTC.string(from: d.cycleStart)
        return t + String(format: " %4d %5.1f %5d  %@         %@   %d", d.snrDB, d.dt, Int(d.freqHz.rounded()), d.submode.letter, d.frame, d.bits.rawValue)
    }

    private func log(_ r: JS8Decoder.CycleResult) {
        let text = r.decodes.map { Self.allTxtLine($0) + "\n" }.joined()
        logger.append(text, now: r.cycleStart)
    }
}
