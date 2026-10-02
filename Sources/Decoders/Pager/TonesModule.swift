import Foundation
import Combine
import SwiftUI
import os

// MARK: - Einstellungen

@MainActor
public final class TonesSettingsStore: ObservableObject {
    /// Eingeschaltete Normen (Standard: DTMF und ZVEI 1)
    @Published public var standards: Set<ToneStandard> {
        didSet { UserDefaults.standard.set(standards.map(\.rawValue), forKey: "toneStandards") }
    }

    public init() {
        let d = UserDefaults.standard
        let raw = d.stringArray(forKey: "toneStandards") ?? ["dtmf", "zvei1"]
        let set = Set(raw.compactMap(ToneStandard.init(rawValue:)))
        standards = set.isEmpty ? [.dtmf, .zvei1] : set
    }

    public func toggle(_ s: ToneStandard) {
        if standards.contains(s) { if standards.count > 1 { standards.remove(s) } } else { standards.insert(s) }
    }
}

extension TonesSettingsStore: TuningTarget {
    public var centerHz: Double { 1500 }
    public var tones: (mark: Double, space: Double) { (0, 0) }
    public var markerBandwidth: Double { 0 }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .none("TÖNE · Tonfolgen überall im Spektrum (SELCAL 313–1479 Hz, DTMF 697–1633 Hz, Selektivruf 450–2800 Hz)") }
}

// MARK: - Decoder

/// Alle eingeschalteten Normen gleichzeitig auf 8-kHz-Audio
public final class TonesDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var changes: [ToneSequence]
        public var level: Double
    }

    private let pipeline: AudioPipeline
    private var decoders: [ToneDecoder] = []
    private var enabled = false
    private let lock = OSAllocatedUnfairLock()
    private var pending: [ToneSequence] = []
    private var levelNow = 0.0

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addSink { [weak self] samples in self?.consume(samples) }
    }

    public func configure(standards: Set<ToneStandard>) {
        pipeline.perform { [self] in
            decoders = ToneStandard.allCases.filter(standards.contains).map { ToneDecoder(standard: $0) }
        }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            enabled = on
            if !on { decoders.forEach { $0.reset() } }
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pending.removeAll() }
            return Output(changes: pending, level: levelNow)
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled else { return }
        var found: [ToneSequence] = []
        for d in decoders { d.process(samples, now: Date()) { found.append($0) } }
        var e: Float = 0
        for v in samples { e += v * v }
        let rms = Double((e / Float(max(1, samples.count))).squareRoot())
        lock.withLockUnchecked {
            pending.append(contentsOf: found)
            levelNow = levelNow * 0.8 + rms * 0.2
        }
    }
}

// MARK: - Controller

@MainActor
public final class TonesController: ObservableObject {
    public let decoder: TonesDecoder
    public let logger = DecodeLogger(mode: "TOENE")
    @Published public private(set) var sequences: [ToneSequence] = []
    @Published public private(set) var level = 0.0
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "toneLogEnabled") }
    }
    public var rigDescription: String? {
        didSet { if rigDescription != oldValue { markSession() } }
    }

    public static let maxSequences = 500
    private let settings: TonesSettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: TonesSettingsStore) {
        self.settings = settings
        decoder = TonesDecoder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "toneLogEnabled") as? Bool ?? true
        decoder.configure(standards: settings.standards)
        markSession()
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.decoder.configure(standards: self.settings.standards)
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

    public func clear() { sequences.removeAll() }

    public func markSession() {
        var h = "TÖNE · " + ToneStandard.allCases.filter(settings.standards.contains).map(\.name).joined(separator: ", ")
        if let rig = rigDescription { h += " · \(rig)" }
        logger.markSession(h)
    }

    /// Änderung einer Folge einarbeiten: laufende Folgen werden fortgeschrieben, abgeschlossene ins Log geschrieben
    public func ingest(_ s: ToneSequence) {
        defer { dropWeaker(than: s) }
        if let i = sequences.lastIndex(where: { $0.standard == s.standard && $0.start == s.start }) {
            let wasComplete = sequences[i].isComplete
            sequences[i].text = s.text
            sequences[i].isComplete = s.isComplete
            if s.isComplete && !wasComplete { log(sequences[i]) }
        } else {
            sequences.append(s)
            if s.isComplete { log(s) }
            if sequences.count > Self.maxSequences { sequences.removeFirst(sequences.count - Self.maxSequences) }
        }
    }

    /// Dieselbe Aussendung lesen mehrere Normen oft zugleich, weil sich Tonreihen überlappen (ZVEI und CCIR):
    /// die Norm mit der längeren Folge gewinnt, die kürzere aus anderer Norm im selben Zeitraum entfällt
    private func dropWeaker(than s: ToneSequence) {
        let longer = sequences.first { $0.standard == s.standard && $0.start == s.start } ?? s
        sequences.removeAll { o in
            o.standard != longer.standard && abs(o.start.timeIntervalSince(longer.start)) < 1.0 && o.text.count < longer.text.count
        }
        if let w = sequences.first(where: { o in
            o.standard != longer.standard && abs(o.start.timeIntervalSince(longer.start)) < 1.0 && o.text.count > longer.text.count
        }) {
            _ = w
            sequences.removeAll { $0.standard == longer.standard && $0.start == longer.start }
        }
    }

    private func log(_ s: ToneSequence) {
        guard logEnabled else { return }
        logger.append(Self.utc.string(from: s.start) + "  " + s.standard.name + "  " + s.text + "\n", now: s.start)
    }

    private func poll() {
        let out = decoder.takeOutput()
        level = out.level
        for c in out.changes { ingest(c) }
    }
}
