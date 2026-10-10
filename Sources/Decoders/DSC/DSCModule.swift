// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os

// MARK: - Kanäle

/// DSC-Kanäle für Notfälle und Anrufe auf MF/HF und UKW (ITU-R M.493). Auf MF/HF liegt der Rufträger 1,7 kHz über dem USB-Dial;
/// UKW-Kanal 70 (156,525 MHz) ist FM mit 1200 Bd (1300/2100 Hz).
public enum DSCChannel: String, CaseIterable, Identifiable, Codable, Sendable {
    case free = "frei"
    case f2187 = "2187", f4207 = "4207", f6312 = "6312", f8414 = "8414", f12577 = "12577", f16804 = "16804"
    case vhf70 = "70"

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
        case .vhf70: return 156_525_000
        }
    }

    /// UKW-DSC (Kanal 70): FM, 1200 Bd
    public var isVHF: Bool { self == .vhf70 }

    public var label: String {
        guard let f = frequencyHz else { return "frei" }
        if isVHF { return "K70" }
        let khz = f / 1000
        return khz.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", khz) : String(format: "%.1f", khz).replacingOccurrences(of: ".", with: ",")
    }

    /// USB-Dial, damit der Rufträger bei `centerHz` im NF liegt (UKW: Kanalfrequenz, FM)
    public func dial(center: Double) -> Int64? {
        if isVHF { return frequencyHz.map { Int64($0.rounded()) } }
        return frequencyHz.map { Int64(($0 - center).rounded()) }
    }
}

/// Frei konfigurierbarer DSC-Kanal
public struct DSCChannelItem: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var label: String
    public var frequencyHz: Double?
    public var isVHF: Bool
    public var note: String

    public init(id: String = UUID().uuidString, label: String, frequencyHz: Double?, isVHF: Bool = false, note: String = "") {
        self.id = id
        self.label = label
        self.frequencyHz = frequencyHz
        self.isVHF = isVHF
        self.note = note
    }

    public func dial(center: Double) -> Int64? {
        if isVHF { return frequencyHz.map { Int64($0.rounded()) } }
        return frequencyHz.map { Int64(($0 - center).rounded()) }
    }

    public static let standardChannels: [DSCChannelItem] = [
        DSCChannelItem(id: "70", label: "K70", frequencyHz: 156_525_000, isVHF: true, note: "UKW-DSC Kanal 70 (156,525 MHz FM)"),
        DSCChannelItem(id: "2187", label: "2187,5", frequencyHz: 2_187_500, isVHF: false, note: "MF Grenzwelle Seenot/Anruf"),
        DSCChannelItem(id: "4207", label: "4207,5", frequencyHz: 4_207_500, isVHF: false, note: "4 MHz KW Seenot/Anruf"),
        DSCChannelItem(id: "6312", label: "6312", frequencyHz: 6_312_000, isVHF: false, note: "6 MHz KW Seenot/Anruf"),
        DSCChannelItem(id: "8414", label: "8414,5", frequencyHz: 8_414_500, isVHF: false, note: "8 MHz KW Seenot/Anruf"),
        DSCChannelItem(id: "12577", label: "12577", frequencyHz: 12_577_000, isVHF: false, note: "12 MHz KW Seenot/Anruf"),
        DSCChannelItem(id: "16804", label: "16804,5", frequencyHz: 16_804_500, isVHF: false, note: "16 MHz KW Seenot/Anruf"),
        DSCChannelItem(id: "free", label: "frei", frequencyHz: nil, isVHF: false, note: "Funkgerät nicht abstimmen")
    ]
}

// MARK: - Einstellungen

@MainActor
public final class DSCSettingsStore: ObservableObject {
    public static let centerRange: ClosedRange<Double> = 300...3500

    @Published public private(set) var centerHz: Double
    @Published public private(set) var manualCenterRevision = 0
    @Published public private(set) var channels: [DSCChannelItem]
    @Published public var selectedChannelID: String { didSet { applySelectedChannel(); save() } }
    /// Mitte automatisch aus den beiden Tönen nachführen (Standard an)
    @Published public var autoCenter: Bool { didSet { save() } }
    /// Seitenband umgekehrt (LSB)
    @Published public var reversed: Bool { didSet { save() } }
    @Published public var channel: DSCChannel { didSet { save() } }

    /// Einstellungen; `defaults` ist beim Mehrkanalbetrieb ein eigener Speicher je Kanal, damit ein Kanal die Einstellungen des Moduls nicht verändert
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        let c = d.double(forKey: "dscCenterHz")
        centerHz = Self.centerRange.contains(c) ? c : 1700
        autoCenter = d.object(forKey: "dscAuto") as? Bool ?? true
        reversed = d.bool(forKey: "dscReversed")
        let loadedChannels: [DSCChannelItem]
        if let data = d.data(forKey: "dscCustomChannels"),
           let list = try? JSONDecoder().decode([DSCChannelItem].self, from: data), !list.isEmpty {
            loadedChannels = list
        } else {
            loadedChannels = DSCChannelItem.standardChannels
        }
        let savedID = d.string(forKey: "dscSelectedChannelID")
        let initialID = loadedChannels.first(where: { $0.id == savedID })?.id ?? loadedChannels.first?.id ?? "8414"
        channels = loadedChannels
        selectedChannelID = initialID
        channel = DSCChannel(rawValue: initialID) ?? .f8414
    }

    public var activeChannelItem: DSCChannelItem {
        channels.first { $0.id == selectedChannelID } ?? channels[0]
    }

    public var activeFrequencyHz: Double? { activeChannelItem.frequencyHz }

    public func selectChannel(id: String) {
        guard channels.contains(where: { $0.id == id }) else { return }
        selectedChannelID = id
    }

    public func addChannel(_ item: DSCChannelItem) {
        channels.append(item)
        selectedChannelID = item.id
        save()
    }

    public func updateChannel(_ item: DSCChannelItem) {
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
        channels = DSCChannelItem.standardChannels
        if !channels.contains(where: { $0.id == selectedChannelID }) {
            selectedChannelID = "8414"
        }
        save()
    }

    private func applySelectedChannel() {
        channel = DSCChannel(rawValue: activeChannelItem.id) ?? (activeChannelItem.isVHF ? .vhf70 : .free)
    }

    /// Von Hand (Klick im Wasserfall): schaltet die Automatik ab
    public func setCenter(_ hz: Double) {
        if activeChannelItem.isVHF { return }          // UKW: feste Töne 1300/2100 Hz
        centerHz = min(max(hz, Self.centerRange.lowerBound), Self.centerRange.upperBound).rounded()
        manualCenterRevision += 1
        autoCenter = false
        save()
    }

    /// Die Automatik hat die Mitte verschoben (Anzeige folgt)
    func autoMoved(to hz: Double) {
        centerHz = hz.rounded()
    }

    public var dialHz: Int64? { activeChannelItem.dial(center: centerHz) }

    private func save() {
        let d = defaults
        d.set(selectedChannelID, forKey: "dscSelectedChannelID")
        d.set(channel.rawValue, forKey: "dscChannel")
        if let data = try? JSONEncoder().encode(channels) {
            d.set(data, forKey: "dscCustomChannels")
        }
        d.set(autoCenter, forKey: "dscAuto")
        d.set(reversed, forKey: "dscReversed")
        d.set(centerHz, forKey: "dscCenterHz")
    }
}

extension DSCSettingsStore: TuningTarget {
    public var tones: (mark: Double, space: Double) {
        channel.isVHF ? (DSCVHFReceiver.bHz, DSCVHFReceiver.yHz) : (centerHz + DSCDemodulator.shift / 2, centerHz - DSCDemodulator.shift / 2)
    }
    public var markerBandwidth: Double { channel.isVHF ? 500 : DSCDemodulator.shift + 100 }
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
    private let vhfRx = DSCVHFReceiver()
    private var vhf = false
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
        pipeline.addSink(rate: DSCVHFReceiver.sampleRate) { [weak self] samples in self?.consumeVHF(samples) }
    }

    public func configure(center: Double, reversed: Bool, auto: Bool, vhf: Bool = false) {
        pipeline.perform { [self] in
            if self.vhf != vhf {
                self.vhf = vhf
                vhfRx.reset()
                framers = (0..<DSCDemodulator.phases).map { _ in DSCFramer() }
            }
            demod.centerHz = center
            demod.reversed = reversed
            autoCenter = auto
            centerNow = center
        }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            enabled = on
            if !on {
                framers = (0..<DSCDemodulator.phases).map { _ in DSCFramer() }
                vhfRx.reset()
            }
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pending.removeAll() }
            return Output(calls: pending, locked: lockedNow, level: levelNow, center: centerNow, measuredCenter: measured)
        }
    }

    /// UKW-Kanal 70: 1200 Bd, 12-kHz-Senke
    private func consumeVHF(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled, vhf else { return }
        var found: [DSCCall] = []
        vhfRx.process(samples) { found.append($0) }
        let locked = vhfRx.isLocked
        let level = vhfRx.level
        lock.withLockUnchecked {
            for c in found { pending.append((c, 0)) }
            lockedNow = locked
            levelNow = level
            centerNow = 0
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled, !vhf else { return }
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
    private var applied: (Double, Bool, Bool, Bool)?
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
        var h = settings.channel.isVHF ? "DSC · UKW Kanal 70 · 156,525 MHz · 1200 Bd" : "DSC · \(settings.channel.label) kHz · Mitte \(Int(settings.centerHz.rounded())) Hz"
        if settings.reversed, !settings.channel.isVHF { h += " · REV" }
        if let rig = rigDescription { h += " · \(rig)" }
        logger.markSession(h)
    }

    private func applySettings() {
        let a = (settings.centerHz, settings.reversed, settings.autoCenter, settings.channel.isVHF)
        if applied.map({ $0 != a }) ?? true {
            let bandChanged = applied.map { $0.3 != a.3 } ?? false
            applied = a
            decoder.configure(center: a.0, reversed: a.1, auto: a.2, vhf: a.3)
            if bandChanged { markSession() }
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
        if settings.autoCenter, !settings.channel.isVHF, abs(out.center - settings.centerHz) >= 1 { settings.autoMoved(to: out.center) }
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
