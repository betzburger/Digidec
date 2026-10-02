import Foundation
import Combine
import SwiftUI
import os

// MARK: - Kanäle

/// Frequenzen für Funkruf (FM). Funkrufdienste sind sonst frei gewählt; hier die bekannte Amateurfunk-Frequenz.
public enum PagerChannel: String, CaseIterable, Identifiable, Codable, Sendable {
    case dapnet, free

    public var id: String { rawValue }

    public var frequencyHz: Double? {
        switch self {
        case .dapnet: return 439_987_500
        case .free: return nil
        }
    }

    public var name: String {
        switch self {
        case .dapnet: return "DAPNET"
        case .free: return "frei"
        }
    }

    public var label: String {
        frequencyHz.map { String(format: "%.4f", $0 / 1_000_000).replacingOccurrences(of: ".", with: ",") } ?? "frei"
    }

    public var note: String {
        switch self {
        case .dapnet: return "DAPNET, Amateurfunk-Funkruf, 439,9875 MHz, POCSAG 1200 Baud"
        case .free: return "Funkgerät nicht abstimmen"
        }
    }
}

// MARK: - Einstellungen

@MainActor
public final class PagerSettingsStore: ObservableObject {
    @Published public var channel: PagerChannel { didSet { UserDefaults.standard.set(channel.rawValue, forKey: "pagerChannel") } }
    /// Eingeschaltete POCSAG-Baudraten (512, 1200, 2400)
    @Published public var rates: Set<Int> { didSet { UserDefaults.standard.set(Array(rates), forKey: "pagerRates") } }
    @Published public var flex: Bool { didSet { UserDefaults.standard.set(flex, forKey: "pagerFlex") } }
    /// Rufnummern, die hervorgehoben werden (durch Komma getrennt)
    @Published public var watch: String { didSet { UserDefaults.standard.set(watch, forKey: "pagerWatch") } }

    public init() {
        let d = UserDefaults.standard
        channel = d.string(forKey: "pagerChannel").flatMap(PagerChannel.init(rawValue:)) ?? .dapnet
        let r = (d.array(forKey: "pagerRates") as? [Int]) ?? POCSAG.rates
        rates = Set(r).intersection(POCSAG.rates)
        flex = d.object(forKey: "pagerFlex") as? Bool ?? true
        watch = d.string(forKey: "pagerWatch") ?? ""
    }

    /// Hervorgehobene Rufnummern als Zahlen
    public var watched: Set<Int> {
        Set(watch.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) })
    }
}

extension PagerSettingsStore: TuningTarget {
    public var centerHz: Double { 1200 }
    public var tones: (mark: Double, space: Double) { (0, 0) }
    public var markerBandwidth: Double { 2400 }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .band("FUNKRUF · Basisband (POCSAG bis 2,4 kHz, FLEX bis 3,2 kHz)") }
}

// MARK: - Decoder

/// POCSAG und FLEX als 24-kHz-Senke an der Pipeline
public final class PagerDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var messages: [PagerMessage]
        public var synced: [Bool]     // POCSAG 512, 1200, 2400, FLEX
        public var level: Double
    }

    public static let sampleRate = 24_000.0

    private let pipeline: AudioPipeline
    private let pocsag = POCSAGReceiver(sampleRate: PagerDecoder.sampleRate)
    private let flexRx = FLEXReceiver(sampleRate: PagerDecoder.sampleRate)
    private var flexOn = true
    private var enabled = false
    private let lock = OSAllocatedUnfairLock()
    private var pending: [PagerMessage] = []
    private var syncedNow = [false, false, false, false]
    private var levelNow = 0.0

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addSink(rate: Self.sampleRate) { [weak self] samples in self?.consume(samples) }
    }

    public func configure(rates: Set<Int>, flex: Bool) {
        pipeline.perform { [self] in
            pocsag.enabled = Set(rates.compactMap { POCSAG.rates.firstIndex(of: $0) })
            flexOn = flex
            if !flex { flexRx.reset() }
        }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            enabled = on
            if !on { pocsag.reset(); flexRx.reset() }
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pending.removeAll() }
            return Output(messages: pending, synced: syncedNow, level: levelNow)
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled else { return }
        var found: [PagerMessage] = []
        let now = Date()
        pocsag.process(samples, now: now) { found.append($0) }
        if flexOn { flexRx.process(samples, now: now) { found.append($0) } }
        let level = pocsag.level
        let synced = pocsag.synced + [flexOn && flexRx.isSynced]
        lock.withLockUnchecked {
            pending.append(contentsOf: found)
            syncedNow = synced
            levelNow = level
        }
    }
}

// MARK: - Controller

@MainActor
public final class PagerController: ObservableObject {
    public let decoder: PagerDecoder
    public let logger = DecodeLogger(mode: "PAGER")
    @Published public private(set) var messages: [PagerMessage] = []
    @Published public private(set) var synced = [false, false, false, false]
    @Published public private(set) var level = 0.0
    @Published public private(set) var count = 0
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "pagerLogEnabled") }
    }
    public var rigDescription: String? {
        didSet { if rigDescription != oldValue { markSession() } }
    }

    public static let maxMessages = 1000
    private let settings: PagerSettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: PagerSettingsStore) {
        self.settings = settings
        decoder = PagerDecoder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "pagerLogEnabled") as? Bool ?? true
        decoder.configure(rates: settings.rates, flex: settings.flex)
        markSession()
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.decoder.configure(rates: self.settings.rates, flex: self.settings.flex)
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
        messages.removeAll()
    }

    public func markSession() {
        var h = "PAGER · \(settings.channel.label) MHz · POCSAG " + POCSAG.rates.filter(settings.rates.contains).map(String.init).joined(separator: "/")
        if settings.flex { h += " · FLEX" }
        if let rig = rigDescription { h += " · \(rig)" }
        logger.markSession(h)
    }

    /// Eine Meldung aufnehmen (auch für Tests und Dateiwiedergabe)
    public func ingest(_ m: PagerMessage, at now: Date = Date()) {
        count += 1
        messages.append(m)
        if messages.count > Self.maxMessages { messages.removeFirst(messages.count - Self.maxMessages) }
        if logEnabled { logger.append(Self.logLine(m) + "\n", now: now) }
    }

    private func poll() {
        let out = decoder.takeOutput()
        synced = out.synced
        level = out.level
        for m in out.messages { ingest(m) }
    }

    /// „08:15:02  POCSAG 1200  RIC 1234567 F3  Hallo Welt“
    nonisolated public static func logLine(_ m: PagerMessage) -> String {
        var s = utc.string(from: m.time) + "  " + m.protocolName + "  RIC " + String(m.address) + " F\(m.function)"
        if let d = m.detail { s += " " + d }
        s += "  " + m.text.replacingOccurrences(of: "\n", with: " ⏎ ")
        if m.corrected > 0 { s += "  [\(m.corrected) Bit korrigiert]" }
        if m.damaged > 0 { s += "  [\(m.damaged) Wörter fehlerhaft]" }
        return s
    }

    public var isWatched: (PagerMessage) -> Bool {
        let w = settings.watched
        return { w.contains($0.address) }
    }
}
