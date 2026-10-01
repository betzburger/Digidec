import Foundation
import Combine
import SwiftUI
import os

// MARK: - Kanäle

/// DSC-Kanäle für Notfälle und Anrufe auf MF/HF (ITU-R M.493). Der Rufträger liegt 1,7 kHz über dem USB-Dial.
public enum DSCChannel: String, CaseIterable, Identifiable, Codable, Sendable {
    case free = "frei"
    case f2187 = "2187", f4207 = "4207", f6312 = "6312", f8414 = "8414", f12577 = "12577", f16804 = "16804"

    public var id: String { rawValue }

    /// Zugewiesene Frequenz in Hz (nil = frei)
    public var frequencyHz: Double? {
        switch self {
        case .free: return nil
        case .f2187: return 2_187_500
        case .f4207: return 4_207_500
        case .f6312: return 6_312_000
        case .f8414: return 8_414_500
        case .f12577: return 12_577_000
        case .f16804: return 16_804_500
        }
    }

    public var label: String {
        guard let f = frequencyHz else { return "frei" }
        let khz = f / 1000
        return khz.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", khz) : String(format: "%.1f", khz).replacingOccurrences(of: ".", with: ",")
    }

    /// USB-Dial, damit der Rufträger bei `centerHz` im NF liegt
    public func dial(center: Double) -> Int64? {
        frequencyHz.map { Int64(($0 - center).rounded()) }
    }
}

// MARK: - Einstellungen

@MainActor
public final class DSCSettingsStore: ObservableObject {
    public static let centerRange: ClosedRange<Double> = 300...3500

    @Published public private(set) var centerHz: Double
    @Published public private(set) var manualCenterRevision = 0
    /// Mitte automatisch aus den beiden Tönen nachführen (Standard an)
    @Published public var autoCenter: Bool { didSet { UserDefaults.standard.set(autoCenter, forKey: "dscAuto") } }
    /// Seitenband umgekehrt (LSB)
    @Published public var reversed: Bool { didSet { UserDefaults.standard.set(reversed, forKey: "dscReversed") } }
    @Published public var channel: DSCChannel { didSet { UserDefaults.standard.set(channel.rawValue, forKey: "dscChannel") } }

    public init() {
        let d = UserDefaults.standard
        let c = d.double(forKey: "dscCenterHz")
        centerHz = Self.centerRange.contains(c) ? c : 1700
        autoCenter = d.object(forKey: "dscAuto") as? Bool ?? true
        reversed = d.bool(forKey: "dscReversed")
        channel = d.string(forKey: "dscChannel").flatMap(DSCChannel.init(rawValue:)) ?? .f8414
    }

    /// Von Hand (Klick im Wasserfall): schaltet die Automatik ab
    public func setCenter(_ hz: Double) {
        centerHz = min(max(hz, Self.centerRange.lowerBound), Self.centerRange.upperBound).rounded()
        manualCenterRevision += 1
        autoCenter = false
        UserDefaults.standard.set(centerHz, forKey: "dscCenterHz")
    }

    /// Die Automatik hat die Mitte verschoben (Anzeige folgt)
    func autoMoved(to hz: Double) {
        centerHz = hz.rounded()
    }

    public var dialHz: Int64? { channel.dial(center: centerHz) }
}

extension DSCSettingsStore: TuningTarget {
    public var tones: (mark: Double, space: Double) { (centerHz + DSCDemodulator.shift / 2, centerHz - DSCDemodulator.shift / 2) }
    public var markerBandwidth: Double { DSCDemodulator.shift + 100 }
}

// MARK: - Decoder

/// Mehrere Taktlagen, Rahmensuche, Mitte nachführen: als 8-kHz-Senke an der Pipeline
public final class DSCDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var calls: [(call: DSCCall, center: Double)]
        public var locked: Bool
        public var level: Double
        public var center: Double
        public var measuredCenter: Double?
    }

    private let pipeline: AudioPipeline
    private let demod = DSCDemodulator()
    private var framers = (0..<DSCDemodulator.phases).map { _ in DSCFramer() }
    private var enabled = false
    private var autoCenter = true
    private var recent: [Float] = []
    private var samplesSinceTune = 0
    private let lock = OSAllocatedUnfairLock()
    private var pending: [(call: DSCCall, center: Double)] = []
    private var lockedNow = false
    private var levelNow = 0.0
    private var centerNow = 1700.0
    private var measured: Double?

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addSink { [weak self] samples in self?.consume(samples) }
    }

    public func configure(center: Double, reversed: Bool, auto: Bool) {
        pipeline.perform { [self] in
            demod.centerHz = center
            demod.reversed = reversed
            autoCenter = auto
            centerNow = center
        }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            enabled = on
            if !on { framers = (0..<DSCDemodulator.phases).map { _ in DSCFramer() } }
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pending.removeAll() }
            return Output(calls: pending, locked: lockedNow, level: levelNow, center: centerNow, measuredCenter: measured)
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled else { return }
        var found: [DSCCall] = []
        demod.process(samples) { phase, bit in
            if let c = framers[phase].push(bit) { found.append(c) }
        }
        recent.append(contentsOf: samples)
        if recent.count > 4096 { recent.removeFirst(recent.count - 4096) }
        samplesSinceTune += samples.count
        if samplesSinceTune >= 8000, recent.count >= 4096 {
            samplesSinceTune = 0
            tune()
        }
        let locked = framers.contains { $0.isLocked }
        let center = demod.centerHz
        lock.withLockUnchecked {
            for c in found { pending.append((c, center)) }
            lockedNow = locked
            levelNow = demod.energy
            centerNow = center
        }
    }

    private var tuner = DSCAutoTuner()

    private func tune() {
        let r = tuner.update(recent: recent, current: demod.centerHz)
        lock.withLockUnchecked { measured = r.measured }
        if autoCenter, let c = r.newCenter { demod.centerHz = c }
    }
}

// MARK: - Controller

@MainActor
public final class DSCController: ObservableObject {
    public let decoder: DSCDecoder
    public let logger = DecodeLogger(mode: "DSC")
    @Published public private(set) var messages: [DSCMessage] = []
    @Published public private(set) var locked = false
    @Published public private(set) var level = 0.0
    @Published public private(set) var measuredCenter: Double?
    @Published public private(set) var lastDistress: DSCMessage?
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "dscLogEnabled") }
    }
    /// Funkgerät und Dial für die Log-Kopfzeile
    public var rigDescription: String? {
        didSet { if rigDescription != oldValue { markSession() } }
    }

    public static let maxMessages = 500
    private let settings: DSCSettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var applied: (Double, Bool, Bool)?
    private var collector = DSCCallCollector()
    private var seen: [(key: String, date: Date)] = []

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: DSCSettingsStore) {
        self.settings = settings
        decoder = DSCDecoder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "dscLogEnabled") as? Bool ?? true
        applySettings()
        markSession()
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
    }

    public func clear() {
        messages.removeAll()
        lastDistress = nil
    }

    public func markSession() {
        var h = "DSC · \(settings.channel.label) kHz · Mitte \(Int(settings.centerHz.rounded())) Hz"
        if settings.reversed { h += " · REV" }
        if let rig = rigDescription { h += " · \(rig)" }
        logger.markSession(h)
    }

    private func applySettings() {
        let a = (settings.centerHz, settings.reversed, settings.autoCenter)
        if applied.map({ $0 != a }) ?? true {
            applied = a
            decoder.configure(center: a.0, reversed: a.1, auto: a.2)
        }
    }

    /// Dieselbe Folge, die kurz zuvor schon kam (gleichzeitig in mehreren Taktlagen oder gleich wiederholt)
    private func isDuplicate(_ symbols: [Int], now: Date) -> Bool {
        seen.removeAll { now.timeIntervalSince($0.date) > 12 }
        let key = symbols.map(String.init).joined(separator: ",")
        if seen.contains(where: { $0.key == key }) { return true }
        seen.append((key, now))
        return false
    }

    private func poll() {
        let out = decoder.takeOutput()
        locked = out.locked
        level = out.level
        measuredCenter = out.measuredCenter
        if settings.autoCenter, abs(out.center - settings.centerHz) >= 1 { settings.autoMoved(to: out.center) }
        let now = Date()
        for (call, _) in out.calls { collector.add(call, at: now.timeIntervalSince1970) }
        for call in collector.take(now: now.timeIntervalSince1970) {
            guard !isDuplicate(call.symbols, now: now) else { continue }
            let msg = DSCMessage.parse(symbols: call.symbols, receivedAt: now, centerHz: out.center, eccOK: call.eccOK)
            messages.append(msg)
            if messages.count > Self.maxMessages { messages.removeFirst(messages.count - Self.maxMessages) }
            if msg.isDistress { lastDistress = msg }
            if logEnabled { logger.append(Self.logLine(msg, dial: settings.dialHz) + "\n", now: now) }
        }
    }

    /// „08:15:02  EINZELRUF ROUTINE  von 238230000 an 002371000  J3E … [ECC OK]“
    nonisolated public static func logLine(_ m: DSCMessage, dial: Int64?) -> String {
        var s = utc.string(from: m.receivedAt) + "  " + m.format.name
        if let c = m.category { s += " " + c }
        s += "  von \(m.from ?? "?") an \(m.to ?? "?")"
        let text = m.summary
        if !text.isEmpty { s += "  " + text }
        s += m.eccOK ? "  [ECC OK]" : "  [ECC FEHLER]"
        if m.unreadable > 0 { s += " [\(m.unreadable) unlesbar]" }
        s += "  Symbole: " + m.symbols.map { $0 < 0 ? "--" : String(format: "%03d", $0) }.joined(separator: " ")
        return s
    }
}
