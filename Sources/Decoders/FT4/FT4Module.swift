// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os

// MARK: - Bänder

/// FT4-Standardfrequenzen (Dial, USB) wie in WSJT-X; für FT2 die in der Frühphase genannten Frequenzen
public enum FT4Band: String, CaseIterable, Identifiable, Codable, Sendable {
    case m80 = "80m", m40 = "40m", m30 = "30m", m20 = "20m"
    case m17 = "17m", m15 = "15m", m12 = "12m", m10 = "10m"
    case m6 = "6m", m2 = "2m", m70 = "70cm"
    /// nur FT2 (FT4 hat auf 160 m keine Standardfrequenz)
    case m160 = "160m"

    public var id: String { rawValue }

    /// Bänder, die es in der Betriebsart gibt (FT4: 80 m bis 70 cm; FT2: 160 m bis 10 m)
    public static func available(for mode: FT4Mode) -> [FT4Band] {
        allCases.filter { $0.dialHz(for: mode) != nil }
    }

    /// FT2: 1,843 / 3,578 / 7,052 / 10,144 / 14,084 / 18,108 / 21,144 / 24,923 / 28,184 MHz (frühe Testfrequenzen, keine amtliche Liste)
    public func dialHz(for mode: FT4Mode) -> Int? {
        if mode == .ft4 { return self == .m160 ? nil : dialHz }
        switch self {
        case .m160: return 1_843_000
        case .m80: return 3_578_000
        case .m40: return 7_052_000
        case .m30: return 10_144_000
        case .m20: return 14_084_000
        case .m17: return 18_108_000
        case .m15: return 21_144_000
        case .m12: return 24_923_000
        case .m10: return 28_184_000
        case .m6, .m2, .m70: return nil
        }
    }

    /// Dial-Frequenz von FT4
    public var dialHz: Int {
        switch self {
        case .m160: return 1_843_000
        case .m80: return 3_575_000
        case .m40: return 7_047_500
        case .m30: return 10_140_000
        case .m20: return 14_080_000
        case .m17: return 18_104_000
        case .m15: return 21_140_000
        case .m12: return 24_919_000
        case .m10: return 28_180_000
        case .m6:  return 50_318_000
        case .m2:  return 144_170_000
        case .m70: return 432_170_000
        }
    }

    /// „14,080“
    public var dialLabel: String { dialLabel(for: .ft4) }

    public func dialLabel(for mode: FT4Mode) -> String {
        String(format: "%.3f", Double(dialHz(for: mode) ?? dialHz) / 1_000_000).replacingOccurrences(of: ".", with: ",")
    }

    /// Band zu einer Dial-Frequenz (± 3 kHz)
    public static func band(forDial hz: Int, mode: FT4Mode = .ft4) -> FT4Band? {
        available(for: mode).first { abs(($0.dialHz(for: mode) ?? 0) - hz) <= 3_000 }
    }
}

// MARK: - Einstellungen

@MainActor
public final class FT4SettingsStore: ObservableObject {
    @Published public var band: FT4Band { didSet { save() } }
    /// FT4 oder das inoffizielle FT2 (dasselbe Verfahren bei halber Symboldauer)
    @Published public var mode: FT4Mode {
        didSet {
            if band.dialHz(for: mode) == nil { band = .m20 }
            save()
        }
    }
    /// Eigenes Rufzeichen (nur zum Hervorheben; Digidec sendet nie)
    @Published public var myCall: String { didSet { save() } }
    @Published public var locator: String { didSet { save() } }
    @Published public var core: FT4Core.Settings { didSet { save() } }
    /// Korrektur der Zeitbasis in Sekunden (Laufzeit Soundkarte → Decoder)
    @Published public var timeOffset: Double { didSet { save() } }
    /// Empfangsfrequenz im NF (Klick im Wasserfall) – Meldungen dort erscheinen zusätzlich rechts
    @Published public private(set) var rxHz: Double
    @Published public var cqOnly: Bool { didSet { save() } }
    @Published public var showUncertain: Bool { didSet { save() } }
    /// Dial laut Funkgerät (rigctld), sonst nil
    @Published public var rigDialHz: Int?

    public init() {
        let d = UserDefaults.standard
        let savedMode = d.string(forKey: "ft4Mode").flatMap(FT4Mode.init(rawValue:)) ?? .ft4
        mode = savedMode
        band = d.string(forKey: "ft4Band").flatMap(FT4Band.init(rawValue:)).flatMap { $0.dialHz(for: savedMode) != nil ? $0 : nil } ?? .m20
        myCall = d.string(forKey: "ft4MyCall") ?? ""
        locator = d.string(forKey: "ft4Locator") ?? "JN49WS"
        core = d.data(forKey: "ft4Core").flatMap { try? JSONDecoder().decode(FT4Core.Settings.self, from: $0) } ?? FT4Core.Settings()
        timeOffset = d.object(forKey: "ft4TimeOffset") as? Double ?? 0.1
        let rx = d.double(forKey: "ft4RxHz")
        rxHz = (200...3500).contains(rx) ? rx : 1500
        cqOnly = d.bool(forKey: "ft4CQOnly")
        showUncertain = d.object(forKey: "ft4ShowUncertain") as? Bool ?? true
    }

    /// Wirksame Dial-Frequenz: Funkgerät, sonst gewähltes Band
    public var dialHz: Int { rigDialHz ?? band.dialHz(for: mode) ?? band.dialHz }

    public func setRx(_ hz: Double) {
        rxHz = min(max(hz, 200), 3500).rounded()
        UserDefaults.standard.set(rxHz, forKey: "ft4RxHz")
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(band.rawValue, forKey: "ft4Band")
        d.set(mode.rawValue, forKey: "ft4Mode")
        d.set(myCall, forKey: "ft4MyCall")
        d.set(locator, forKey: "ft4Locator")
        if let data = try? JSONEncoder().encode(core) { d.set(data, forKey: "ft4Core") }
        d.set(timeOffset, forKey: "ft4TimeOffset")
        d.set(cqOnly, forKey: "ft4CQOnly")
        d.set(showUncertain, forKey: "ft4ShowUncertain")
    }
}

extension FT4SettingsStore: TuningTarget {
    public var centerHz: Double { rxHz + mode.bandwidth / 2 }
    /// FT4 belegt 4 Töne × 20,8333 Hz ≈ 83,33 Hz ab der Empfangsfrequenz, FT2 4 × 41,6667 Hz ≈ 166,67 Hz
    public var tones: (mark: Double, space: Double) { (rxHz + mode.bandwidth, rxHz) }
    public var markerBandwidth: Double { mode.bandwidth }
    public func setCenter(_ hz: Double) { setRx(hz - mode.bandwidth / 2) }
}

// MARK: - Decoder

/// Sammelt 12-kHz-Audio mit Zeitstempel und decodiert jeden Zyklus (FT4 7,5 s, FT2 3,75 s) nach UTC im Hintergrund.
public final class FT4Decoder: @unchecked Sendable {
    public struct CycleResult: Sendable {
        public var cycleStart: Date
        public var decodes: [FT4Decode]
        /// Rechenzeit in Sekunden
        public var duration: Double
        /// Anteil des Zyklus, für den Audio vorlag (0…1)
        public var coverage: Double
    }

    public static let rate = 12_000
    /// Sekunden nach Zyklusbeginn, zu denen decodiert wird (FT4: Sendung endet bei ~5,5 s, 7,1 s lässt Zeit; FT2: 3,3 s). Nil = Standard der Betriebsart.
    public var decodeAt: Double?

    private let pipeline: AudioPipeline
    private let decodeQueue = DispatchQueue(label: "digidec.ft4.decode", qos: .userInitiated)

    // Nur auf der Verarbeitungs-Queue
    private var enabled = false
    private var ring = [Float](repeating: 0, count: 10 * 12_000)
    private var written: Int64 = 0          // Samples seit Start
    private var offset: Double?             // Unix-Zeit des Samples 0 (geglättet)
    private var lastCycle: Double = 0
    private var settings = FT4Core.Settings()
    private var timeOffset = 0.0
    private var mode = FT4Mode.ft4

    private let lock = OSAllocatedUnfairLock()
    private var pending: [CycleResult] = []
    private var busy = false

    /// Uhr (für Tests ersetzbar)
    public var clock: @Sendable () -> Double = { Date().timeIntervalSince1970 }

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addSink(rate: Double(Self.rate)) { [weak self] samples in self?.consume(samples) }
    }

    public func configure(settings: FT4Core.Settings, timeOffset: Double, mode: FT4Mode = .ft4) {
        pipeline.perform { [self] in
            self.settings = settings
            self.timeOffset = timeOffset
            if self.mode != mode { lastCycle = 0 }
            self.mode = mode
        }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            enabled = on
            if !on { offset = nil }
        }
    }

    public var isBusy: Bool { lock.withLockUnchecked { busy } }

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
        let mode = self.mode
        let cycleSeconds = mode.cycleSeconds
        let cycle = (now / cycleSeconds).rounded(.down) * cycleSeconds
        guard now - cycle >= (decodeAt ?? mode.decodeAt), cycle != lastCycle else { return }
        lastCycle = cycle
        // Samples ab Zyklusbeginn bis jetzt
        let first = Int64(((cycle - offset) * Double(Self.rate)).rounded())
        let oldest = max(0, written - Int64(ring.count))
        let from = max(first, oldest)
        guard written - from > Int64(mode.minimumSeconds * Double(Self.rate)) else { return }   // FT4: weniger als 5 s, FT2: 2,5 s: nicht decodierbar
        var buf = [Float](repeating: 0, count: Int(written - first))
        for i in from..<written { buf[Int(i - first)] = ring[Int(i % Int64(ring.count))] }
        let coverage = Double(written - from) / (cycleSeconds * Double(Self.rate))
        let s = settings
        let start = Date(timeIntervalSince1970: cycle)
        let skip = lock.withLockUnchecked { () -> Bool in
            if busy { return true }
            busy = true
            return false
        }
        guard !skip else { return }
        let decodeBuf = buf
        decodeQueue.async { [weak self] in
            let t0 = Date()
            let list = FT4Core.decode(decodeBuf, rate: Self.rate, cycleStart: start, settings: s, mode: mode)
            let result = CycleResult(cycleStart: start, decodes: list, duration: Date().timeIntervalSince(t0),
                                     coverage: min(1, coverage))
            self?.lock.withLockUnchecked {
                self?.pending.append(result)
                self?.busy = false
            }
        }
    }
}

// MARK: - Controller

/// Eine Zeile der Bandaktivität mit Entfernung und DXCC
public struct FT4Entry: Identifiable, Sendable, Equatable {
    public var decode: FT4Decode
    public var dxcc: DXCCEntity?
    public var km: Double?
    public var bearing: Double?
    public var mentionsMe: Bool
    public var id: UUID { decode.id }
}

@MainActor
public final class FT4Controller: ObservableObject {
    public let decoder: FT4Decoder
    public let logger = DecodeLogger(mode: "FT4")
    @Published public private(set) var entries: [FT4Entry] = []
    @Published public private(set) var lastCycle: FT4Decoder.CycleResult?
    @Published public private(set) var cycleCount = 0
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "ft4LogEnabled") }
    }

    public static let maxEntries = 1500
    private let settings: FT4SettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var applied: (FT4Core.Settings, Double, FT4Mode)?

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    nonisolated static let allTxt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyMMdd_HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: FT4SettingsStore) {
        self.settings = settings
        decoder = FT4Decoder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "ft4LogEnabled") as? Bool ?? true
        applySettings()
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
    }

    public func clear() {
        entries.removeAll()
    }

    /// Meldungen, die gezeigt werden (Filter CQ, unsichere)
    public var visible: [FT4Entry] {
        entries.filter { e in
            (!settings.cqOnly || e.decode.message.isCQ || e.mentionsMe)
                && (settings.showUncertain || !e.decode.isUncertain)
        }
    }

    /// Meldungen nahe der Empfangsfrequenz (± 90 Hz) oder an das eigene Rufzeichen
    public var rxEntries: [FT4Entry] {
        entries.filter { abs($0.decode.freqHz - settings.rxHz) <= 90 || $0.mentionsMe }
    }

    private func applySettings() {
        let a = (settings.core, settings.timeOffset, settings.mode)
        if applied.map({ $0.0 != a.0 || $0.1 != a.1 || $0.2 != a.2 }) ?? true {
            applied = a
            decoder.configure(settings: a.0, timeOffset: a.1, mode: a.2)
        }
    }

    private func poll() {
        for result in decoder.takeResults() {
            lastCycle = result
            cycleCount += 1
            let me = settings.myCall.uppercased()
            let rows = result.decodes.map { d -> FT4Entry in
                let m = d.message
                let dist = m.grid.flatMap { Maidenhead.distance(from: settings.locator, to: $0) }
                let dx = m.sender.flatMap { DXCCDatabase.shared.lookup($0) }
                return FT4Entry(decode: d, dxcc: dx, km: dist?.km, bearing: dist?.bearing,
                                mentionsMe: !me.isEmpty && m.calls.contains { $0 == me || $0 == "<\(me)>" })
            }
            entries.append(contentsOf: rows)
            if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
            if logEnabled { log(result) }
        }
    }

    /// Zeile wie WSJT-X ALL.TXT: „261001_081500    14.080 Rx FT4    -12  0.3 1234 CQ DL1ABC JN49“
    nonisolated public static func allTxtLine(_ d: FT4Decode, dialHz: Int) -> String {
        let mhz = String(format: "%.3f", Double(dialHz) / 1_000_000)
        let pad = String(repeating: " ", count: max(0, 10 - mhz.count)) + mhz
        let nums = String(format: " Rx %@ %6d %4.1f %4d ", d.mode.rawValue, d.snrDB, d.dt, Int(d.freqHz.rounded()))
        return allTxt.string(from: d.cycleStart) + pad + nums + d.text + (d.isUncertain ? " ?" : "")
    }

    private func log(_ r: FT4Decoder.CycleResult) {
        let dial = settings.dialHz
        let text = r.decodes.map { Self.allTxtLine($0, dialHz: dial) + "\n" }.joined()
        logger.append(text, now: r.cycleStart)
    }
}
