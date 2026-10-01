import Foundation
import Combine
import SwiftUI
import os

// MARK: - Einstellungen

/// Empfindlichkeit: Mindestzahl einstimmiger Bit (von 48) für folgende Wörter bzw. das erste Wort einer Aussendung
public enum ALESensitivity: String, CaseIterable, Identifiable, Codable, Sendable {
    case strict = "streng", normal = "normal", sensitive = "empfindlich"
    public var id: String { rawValue }
    public var lockedMinimum: Int { switch self { case .strict: return 40; case .normal: return 36; case .sensitive: return 32 } }
    public var firstMinimum: Int { switch self { case .strict: return 46; case .normal: return 44; case .sensitive: return 40 } }
    public var firstMaxErrors: Int { switch self { case .strict: return 2; case .normal: return 3; case .sensitive: return 4 } }
}

@MainActor
public final class ALESettingsStore: ObservableObject {
    /// Mitte des Tonblocks 750 … 2500 Hz ohne Verstimmung
    public nonisolated static let nominalCenter = 1625.0
    public nonisolated static let offsetRange: ClosedRange<Double> = -200...200

    @Published public private(set) var offsetHz: Double
    @Published public private(set) var manualRevision = 0
    /// Verstimmung aus bekannten Wörtern nachführen (Standard an)
    @Published public var auto: Bool { didSet { UserDefaults.standard.set(auto, forKey: "aleAuto") } }
    @Published public var sensitivity: ALESensitivity { didSet { UserDefaults.standard.set(sensitivity.rawValue, forKey: "aleSensitivity") } }

    public init() {
        let d = UserDefaults.standard
        let o = d.double(forKey: "aleOffsetHz")
        offsetHz = Self.offsetRange.contains(o) ? o : 0
        auto = d.object(forKey: "aleAuto") as? Bool ?? true
        sensitivity = d.string(forKey: "aleSensitivity").flatMap(ALESensitivity.init(rawValue:)) ?? .normal
    }

    public func setOffset(_ hz: Double) {
        offsetHz = min(max(hz, Self.offsetRange.lowerBound), Self.offsetRange.upperBound).rounded()
        manualRevision += 1
        UserDefaults.standard.set(offsetHz, forKey: "aleOffsetHz")
    }

    /// Die Nachführung hat die Verstimmung geändert
    func autoMoved(to hz: Double) {
        offsetHz = hz
        UserDefaults.standard.set(offsetHz, forKey: "aleOffsetHz")
    }
}

extension ALESettingsStore: TuningTarget {
    public var centerHz: Double { Self.nominalCenter + offsetHz }
    public var tones: (mark: Double, space: Double) { (2500 + offsetHz, 750 + offsetHz) }
    public var markerBandwidth: Double { 2000 }
    /// Klick im Wasserfall: Mitte des Tonblocks dorthin (schaltet die Nachführung aus)
    public func setCenter(_ hz: Double) {
        auto = false
        setOffset(hz - Self.nominalCenter)
    }
}

// MARK: - Decoder

public final class ALEDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var messages: [ALEMessage]
        public var locked: Bool
        public var level: Double
        public var purity: Double
        public var offset: Double
        public var words: Int
    }

    private let pipeline: AudioPipeline
    private let demod = ALEDemodulator()
    private var collector = ALEWordCollector()
    private var tracker = ALEGridTracker()
    private var builder = ALEMessageBuilder()
    private var ring: [Float] = []
    private var total = 0
    private var enabled = false
    private var auto = true
    private let lock = OSAllocatedUnfairLock()
    private var pending: [ALEMessage] = []
    private var lockedNow = false
    private var levelNow = 0.0, purityNow = 0.0, offsetNow = 0.0
    private var wordsTotal = 0

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addSink { [weak self] samples in self?.consume(samples) }
    }

    public func configure(offset: Double, auto: Bool, sensitivity: ALESensitivity) {
        pipeline.perform { [self] in
            demod.offsetHz = offset
            demod.minUnanimous = sensitivity.lockedMinimum
            tracker.lockedMinimum = sensitivity.lockedMinimum
            tracker.firstMinimum = sensitivity.firstMinimum
            tracker.firstMaxErrors = sensitivity.firstMaxErrors
            self.auto = auto
            offsetNow = offset
        }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            enabled = on
            if !on {
                demod.resetHistory()
                collector = ALEWordCollector()
                tracker = ALEGridTracker()
                builder = ALEMessageBuilder()
            }
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pending.removeAll() }
            return Output(messages: pending, locked: lockedNow, level: levelNow, purity: purityNow, offset: offsetNow, words: wordsTotal)
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled else { return }
        demod.process(samples) { w, _ in collector.add(w) }
        ring.append(contentsOf: samples)
        if ring.count > 6000 { ring.removeFirst(ring.count - 6000) }
        total += samples.count
        var done: [ALEMessage] = []
        var newWords = 0
        for w in collector.take(now: total) where tracker.accept(w) {
            newWords += 1
            if auto { adjustOffset(for: w) }
            if let m = builder.add(w, offsetHz: demod.offsetHz) { done.append(m) }
        }
        tracker.idle(now: total)
        if let m = builder.flush(nowSample: total, offsetHz: demod.offsetHz) { done.append(m) }
        let locked = tracker.isLocked, level = demod.level, purity = demod.purity, offset = demod.offsetHz
        lock.withLockUnchecked {
            pending += done
            lockedNow = locked
            levelNow = level
            purityNow = purity
            offsetNow = offset
            wordsTotal += newWords
        }
    }

    /// Frequenzfehler am bekannten Wort messen (Abtastwerte des Wortes liegen noch im Ring)
    private func adjustOffset(for w: ALEWord) {
        let startFromEnd = total - w.endSample + 49 * 64            // Wortbeginn, gezählt vom Ringende zurück
        guard startFromEnd <= ring.count, startFromEnd >= 49 * 64 else { return }
        let start = ring.count - startFromEnd
        let words = ALECodec.symbols(word24: ALECodec.word24(preamble: w.preamble, chars: w.chars))
        guard let eps = ALEFrequencyError.estimate(samples: Array(ring[start..<(start + 49 * 64)]), symbols: words, offset: demod.offsetHz),
              abs(eps) >= 2 else { return }
        demod.offsetHz = min(max(demod.offsetHz + eps * 0.6, ALESettingsStore.offsetRange.lowerBound), ALESettingsStore.offsetRange.upperBound)
    }
}

// MARK: - Controller

@MainActor
public final class ALEController: ObservableObject {
    public let decoder: ALEDecoder
    public let logger = DecodeLogger(mode: "ALE")
    @Published public private(set) var messages: [ALEMessage] = []
    @Published public private(set) var locked = false
    @Published public private(set) var level = 0.0
    @Published public private(set) var purity = 0.0
    @Published public private(set) var wordCount = 0
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "aleLogEnabled") }
    }
    public var rigDescription: String? {
        didSet { if rigDescription != oldValue { markSession() } }
    }

    public static let maxMessages = 500
    private let settings: ALESettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var applied: (Double, Bool, ALESensitivity)?

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: ALESettingsStore) {
        self.settings = settings
        decoder = ALEDecoder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "aleLogEnabled") as? Bool ?? true
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
    }

    public func markSession() {
        var h = "ALE · Verstimmung \(Int(settings.offsetHz.rounded())) Hz"
        if let rig = rigDescription { h += " · \(rig)" }
        logger.markSession(h)
    }

    private func applySettings() {
        let a = (settings.offsetHz, settings.auto, settings.sensitivity)
        // Nur bei Änderung von Hand oder der Betriebsart neu einstellen (die Nachführung ändert die Verstimmung selbst)
        if applied.map({ $0.1 != a.1 || $0.2 != a.2 || ($0.0 != a.0 && !a.1) }) ?? true {
            applied = a
            decoder.configure(offset: a.0, auto: a.1, sensitivity: a.2)
        }
    }

    private func poll() {
        let out = decoder.takeOutput()
        locked = out.locked
        level = out.level
        purity = out.purity
        wordCount = out.words
        if settings.auto, abs(out.offset - settings.offsetHz) >= 1 {
            settings.autoMoved(to: out.offset.rounded())
            applied = (settings.offsetHz, settings.auto, settings.sensitivity)
        }
        for m in out.messages {
            messages.append(m)
            if messages.count > Self.maxMessages { messages.removeFirst(messages.count - Self.maxMessages) }
            if logEnabled { logger.append(Self.logLine(m) + "\n", now: m.receivedAt) }
        }
    }

    /// „08:15:02  ANRUF  Q48  TO USMANQ · TIS SHAEENQ2“
    nonisolated public static func logLine(_ m: ALEMessage) -> String {
        utc.string(from: m.receivedAt) + "  " + m.kind + "  Q\(m.quality)  " + m.summary
    }
}
