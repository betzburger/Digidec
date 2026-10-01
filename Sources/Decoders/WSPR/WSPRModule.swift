import Foundation
import Combine
import SwiftUI
import os

// MARK: - Bänder

/// WSPR-Standardfrequenzen (Dial, USB) wie in WSJT-X. Das Signal liegt 1400 … 1600 Hz über dem Dial (Mitte 1500 Hz).
public enum WSPRBand: String, CaseIterable, Identifiable, Codable, Sendable {
    case m2200 = "2200m", m630 = "630m", m160 = "160m", m80 = "80m", m60 = "60m", m40 = "40m"
    case m30 = "30m", m20 = "20m", m17 = "17m", m15 = "15m", m12 = "12m", m10 = "10m"
    case m6 = "6m", m4 = "4m", m2 = "2m", m70 = "70cm"

    public var id: String { rawValue }

    public var dialHz: Int {
        switch self {
        case .m2200: return 136_000
        case .m630:  return 474_200
        case .m160:  return 1_836_600
        case .m80:   return 3_568_600
        case .m60:   return 5_287_200
        case .m40:   return 7_038_600
        case .m30:   return 10_138_700
        case .m20:   return 14_095_600
        case .m17:   return 18_104_600
        case .m15:   return 21_094_600
        case .m12:   return 24_924_600
        case .m10:   return 28_124_600
        case .m6:    return 50_293_000
        case .m4:    return 70_091_000
        case .m2:    return 144_489_000
        case .m70:   return 432_300_000
        }
    }

    /// „14,0956“
    public var dialLabel: String {
        String(format: "%.4f", Double(dialHz) / 1_000_000).replacingOccurrences(of: ".", with: ",")
    }

    /// Band zu einer Dial-Frequenz (± 3 kHz)
    public static func band(forDial hz: Int) -> WSPRBand? {
        allCases.first { abs($0.dialHz - hz) <= 3_000 }
    }
}

// MARK: - Einstellungen

@MainActor
public final class WSPRSettingsStore: ObservableObject {
    @Published public var band: WSPRBand { didSet { save() } }
    /// Eigenes Rufzeichen (nur zum Hervorheben; Digidec sendet nie)
    @Published public var myCall: String { didSet { save() } }
    @Published public var locator: String { didSet { save() } }
    @Published public var core: WSPRCore.Settings { didSet { save() } }
    /// Korrektur der Zeitbasis in Sekunden (Laufzeit Soundkarte → Decoder)
    @Published public var timeOffset: Double { didSet { save() } }
    /// Dial laut Funkgerät (rigctld), sonst nil
    @Published public var rigDialHz: Int?

    public init() {
        let d = UserDefaults.standard
        band = d.string(forKey: "wsprBand").flatMap(WSPRBand.init(rawValue:)) ?? .m20
        myCall = d.string(forKey: "wsprMyCall") ?? ""
        locator = d.string(forKey: "wsprLocator") ?? "JN49WS"
        core = d.data(forKey: "wsprCore").flatMap { try? JSONDecoder().decode(WSPRCore.Settings.self, from: $0) } ?? WSPRCore.Settings()
        timeOffset = d.object(forKey: "wsprTimeOffset") as? Double ?? 0.0
    }

    /// Wirksame Dial-Frequenz: Funkgerät, sonst gewähltes Band
    public var dialHz: Int { rigDialHz ?? band.dialHz }

    private func save() {
        let d = UserDefaults.standard
        d.set(band.rawValue, forKey: "wsprBand")
        d.set(myCall, forKey: "wsprMyCall")
        d.set(locator, forKey: "wsprLocator")
        if let data = try? JSONEncoder().encode(core) { d.set(data, forKey: "wsprCore") }
        d.set(timeOffset, forKey: "wsprTimeOffset")
    }
}

extension WSPRSettingsStore: TuningTarget {
    /// WSPR liegt fest bei 1500 Hz ± 100 Hz im NF (Klick im Wasserfall ändert nichts)
    public var centerHz: Double { 1500 }
    public var tones: (mark: Double, space: Double) { (1500 + 100, 1500 - 100) }
    public var markerBandwidth: Double { 200 }
    public func setCenter(_ hz: Double) {}
}

// MARK: - Decoder

/// Sammelt 12-kHz-Audio mit Zeitstempel und decodiert jeden 2-Minuten-Zyklus nach UTC im Hintergrund.
public final class WSPRDecoder: @unchecked Sendable {
    public struct SlotResult: Sendable {
        public var slotStart: Date
        public var decodes: [WSPRDecode]
        /// Rechenzeit in Sekunden
        public var duration: Double
        /// Anteil der 114 s, für die Audio vorlag (0…1)
        public var coverage: Double
    }

    public static let rate = 12_000
    /// Sekunden nach Zyklusbeginn, zu denen decodiert wird (Aussendung endet bei ≈ 111,6 s)
    public var decodeAt = 114.0

    private let pipeline: AudioPipeline
    private let decodeQueue = DispatchQueue(label: "digidec.wspr.decode", qos: .userInitiated)

    // Nur auf der Verarbeitungs-Queue
    private var enabled = false
    private var ring = [Float](repeating: 0, count: 130 * 12_000)
    private var written: Int64 = 0
    private var offset: Double?
    private var lastSlot: Double = 0
    private var settings = WSPRCore.Settings()
    private var timeOffset = 0.0

    private let lock = OSAllocatedUnfairLock()
    private var pending: [SlotResult] = []
    private var busy = false

    /// Uhr (für Tests ersetzbar)
    public var clock: @Sendable () -> Double = { Date().timeIntervalSince1970 }
    /// Datei der Hashtabelle (Typ-3-Meldungen), nil = keine
    public var hashFile: URL?

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addSink(rate: Double(Self.rate)) { [weak self] samples in self?.consume(samples) }
    }

    public func configure(settings: WSPRCore.Settings, timeOffset: Double) {
        pipeline.perform { [self] in
            self.settings = settings
            self.timeOffset = timeOffset
        }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            enabled = on
            if !on { offset = nil }
        }
    }

    public var isBusy: Bool { lock.withLockUnchecked { busy } }

    public func takeResults() -> [SlotResult] {
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
        let slot = (now / WSPRCore.slotSeconds).rounded(.down) * WSPRCore.slotSeconds
        guard now - slot >= decodeAt, slot != lastSlot else { return }
        lastSlot = slot
        // Samples ab Zyklusbeginn bis jetzt (höchstens 120 s)
        let first = Int64(((slot - offset) * Double(Self.rate)).rounded())
        let oldest = max(0, written - Int64(ring.count))
        let from = max(first, oldest)
        let have = Double(written - from) / Double(Self.rate)
        guard have > 60 else { return }       // weniger als eine Minute: nicht decodierbar
        let end = min(written, first + Int64(120 * Self.rate))
        var buf = [Float](repeating: 0, count: Int(end - first))
        for i in from..<end { buf[Int(i - first)] = ring[Int(i % Int64(ring.count))] }
        let coverage = min(1, have / WSPRCore.usedSeconds)
        let s = settings
        let start = Date(timeIntervalSince1970: slot)
        let skip = lock.withLockUnchecked { () -> Bool in
            if busy { return true }
            busy = true
            return false
        }
        guard !skip else { return }
        let decodeBuf = buf
        let hashFile = hashFile
        decodeQueue.async { [weak self] in
            let t0 = Date()
            let list = WSPRCore.decode(decodeBuf, slotStart: start, settings: s)
            if let hashFile, !list.isEmpty { WSPRCore.saveHashes(to: hashFile) }
            let result = SlotResult(slotStart: start, decodes: list, duration: Date().timeIntervalSince(t0), coverage: coverage)
            self?.lock.withLockUnchecked {
                self?.pending.append(result)
                self?.busy = false
            }
        }
    }
}

// MARK: - Controller

/// Eine Zeile der Spotliste mit Entfernung und DXCC
public struct WSPREntry: Identifiable, Sendable, Equatable {
    public var decode: WSPRDecode
    public var dxcc: DXCCEntity?
    public var km: Double?
    public var bearing: Double?
    /// Funkfrequenz in Hz (Dial + NF)
    public var rfHz: Double
    public var mentionsMe: Bool
    public var id: UUID { decode.id }
}

@MainActor
public final class WSPRController: ObservableObject {
    public let decoder: WSPRDecoder
    public let logger = DecodeLogger(mode: "WSPR")
    @Published public private(set) var entries: [WSPREntry] = []
    @Published public private(set) var lastSlot: WSPRDecoder.SlotResult?
    @Published public private(set) var slotCount = 0
    /// Weitester Empfang dieser Sitzung
    @Published public private(set) var best: WSPREntry?
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "wsprLogEnabled") }
    }

    public static let maxEntries = 1500
    private let settings: WSPRSettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var applied: (WSPRCore.Settings, Double)?

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmm"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    nonisolated static let allWspr: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyMMdd HHmm"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Ordner für die Hashtabelle (`~/Library/Application Support/Digidec/WSPR/hashtable.txt`)
    public static var hashFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Digidec/WSPR/hashtable.txt")
    }

    public init(pipeline: AudioPipeline, settings: WSPRSettingsStore) {
        self.settings = settings
        decoder = WSPRDecoder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "wsprLogEnabled") as? Bool ?? true
        let hashURL = Self.hashFileURL
        try? FileManager.default.createDirectory(at: hashURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        WSPRCore.loadHashes(from: hashURL)
        decoder.hashFile = hashURL
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
        entries.removeAll()
        best = nil
    }

    /// Verschiedene Stationen in der Liste
    public var stationCount: Int { Set(entries.map { $0.decode.message.plainCall }).count }

    private func applySettings() {
        let a = (settings.core, settings.timeOffset)
        if applied.map({ $0.0 != a.0 || $0.1 != a.1 }) ?? true {
            applied = a
            decoder.configure(settings: a.0, timeOffset: a.1)
        }
    }

    private func poll() {
        for result in decoder.takeResults() {
            lastSlot = result
            slotCount += 1
            let me = settings.myCall.uppercased()
            let dial = Double(settings.dialHz)
            let rows = result.decodes.map { d -> WSPREntry in
                let m = d.message
                let dist = m.grid.flatMap { Maidenhead.distance(from: settings.locator, to: $0) }
                let dx = m.isHashed ? nil : DXCCDatabase.shared.lookup(m.plainCall)
                return WSPREntry(decode: d, dxcc: dx, km: dist?.km, bearing: dist?.bearing, rfHz: dial + d.freqHz,
                                 mentionsMe: !me.isEmpty && m.plainCall == me)
            }
            entries.append(contentsOf: rows)
            if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
            for r in rows { if let km = r.km, km > (best?.km ?? 0) { best = r } }
            if logEnabled { log(result) }
        }
    }

    /// Zeile wie wsprd ALL_WSPR.TXT: „261001 0918  -9  1.1   14.0970460  ND6P DM04 30   0“
    nonisolated public static func allLine(_ d: WSPRDecode, dialHz: Int) -> String {
        let mhz = (Double(dialHz) + d.freqHz) / 1_000_000
        return allWspr.string(from: d.slotStart)
            + String(format: " %3d %5.2f %11.7f  ", d.snrDB, d.dt, mhz)
            + d.text.padding(toLength: 22, withPad: " ", startingAt: 0)
            + String(format: " %2d", d.drift)
    }

    private func log(_ r: WSPRDecoder.SlotResult) {
        let dial = settings.dialHz
        let text = r.decodes.map { Self.allLine($0, dialHz: dial) + "\n" }.joined()
        logger.append(text, now: r.slotStart)
    }
}
