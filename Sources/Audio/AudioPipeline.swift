// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import os

/// Verbindet die Quellen (Live-Eingang oder WAV-Datei) mit den Verbrauchern (Decoder, ab M3 Wasserfall).
///
/// Quelle → `ring` (Mono, Quell-Abtastrate) → Verarbeitungs-Queue alle 20 ms:
/// Pegel messen → je benötigter Abtastrate einmal wandeln → an die Senken dieser Rate verteilen
/// (8 kHz: RTTY und Wasserfall, 11 025 Hz: NAVTEX, später 12 kHz: FT8).
/// Der Audio-Callback schreibt nur in den Ringpuffer; alles Weitere läuft auf `queue` (PLAN.md, Abschnitt 6).
public final class AudioPipeline: @unchecked Sendable {
    /// Abtastrate des RTTY-Kerns von fldigi (`RTTY_SampleRate` in rtty.h)
    public static let decoderSampleRate: Double = 8000
    public typealias Sink = @Sendable (UnsafeBufferPointer<Float>) -> Void

    /// 2 s bei 48 kHz – überbrückt Aussetzer der Verarbeitungs-Queue
    public let ring = FloatRingBuffer(capacity: 96_000)
    public let level = LevelAccumulator()

    /// Linker und rechter Kanal der Quelle einzeln (nur gefüllt, solange `wantsStereo` gesetzt ist): für Module, die zwei Kanäle zugleich hören (AIS A und B)
    public let ringLeft = FloatRingBuffer(capacity: 96_000)
    public let ringRight = FloatRingBuffer(capacity: 96_000)
    private let stereoWantedLock = OSAllocatedUnfairLock(initialState: false)
    private let channelsLock = OSAllocatedUnfairLock(initialState: 2)

    /// Sollen die Quellen beide Kanäle getrennt liefern? Beim Einschalten werden alte Reste verworfen.
    public var wantsStereo: Bool {
        get { stereoWantedLock.withLock { $0 } }
        set {
            let changed = stereoWantedLock.withLock { cur -> Bool in defer { cur = newValue }; return cur != newValue }
            if changed && newValue { ringLeft.clear(); ringRight.clear() }
        }
    }

    /// Zahl der Kanäle der Quelle (1 = mono: links und rechts sind dasselbe Signal)
    public var sourceChannels: Int {
        get { channelsLock.withLock { $0 } }
        set { channelsLock.withLock { $0 = newValue } }
    }

    /// Beide Kanäle gleichzeitig an die Quelle schreiben (Audio-Thread der Quelle)
    public func writeStereo(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        ringLeft.write(left, count: count)
        ringRight.write(right, count: count)
    }

    private let queue = DispatchQueue(label: "com.peterbetz.digidec.pipeline", qos: .userInitiated)
    private let sinkLock = NSLock()
    private var sinks: [UUID: (rate: Double, sink: Sink)] = [:]
    /// Senken für das unveränderte Eingangssignal (Quell-Abtastrate), z. B. die Aufnahme
    public typealias RawSink = @Sendable (UnsafeBufferPointer<Float>, Double) -> Void
    private var rawSinks: [UUID: RawSink] = [:]
    public typealias StereoSink = @Sendable (UnsafeBufferPointer<Float>, UnsafeBufferPointer<Float>) -> Void
    private var stereoSinks: [UUID: (rate: Double, sink: StereoSink)] = [:]
    private var stereoConverters: [Double: (SampleRateConverter, SampleRateConverter)] = [:]
    private var inputRate: Double = 0

    // Nur auf `queue` benutzt
    private var timer: DispatchSourceTimer?
    /// Ein Wandler je Zielrate; Senken derselben Rate teilen sich das Ergebnis
    private var converters: [Double: SampleRateConverter] = [:]
    private let chunk = UnsafeMutablePointer<Float>.allocate(capacity: 9_600)
    private let chunkLeft = UnsafeMutablePointer<Float>.allocate(capacity: 9_600)
    private let chunkRight = UnsafeMutablePointer<Float>.allocate(capacity: 9_600)
    private let chunkCapacity = 9_600
    private var deliveredSamples = 0

    public init() {}

    deinit {
        chunk.deallocate()
        chunkLeft.deallocate()
        chunkRight.deallocate()
    }

    /// Startet die Verarbeitung für eine Quelle mit der angegebenen Abtastrate. Ein laufender Durchgang wird ersetzt.
    public func start(inputRate: Double) {
        queue.async { [self] in
            stopInternal()
            ring.clear()
            _ = level.take()
            converters.removeAll()
            stereoConverters.removeAll()
            ringLeft.clear()
            ringRight.clear()
            self.inputRate = inputRate
            deliveredSamples = 0

            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.drain() }
            timer = t
            t.resume()
        }
    }

    public func stop() {
        queue.async { [self] in
            stopInternal()
            ring.clear()
        }
    }

    /// Senke mit 8 kHz (Decoder-Standard)
    @discardableResult
    public func addSink(_ sink: @escaping Sink) -> UUID {
        addSink(rate: Self.decoderSampleRate, sink)
    }

    /// Senke mit eigener Abtastrate (z. B. 11 025 Hz für NAVTEX)
    @discardableResult
    public func addSink(rate: Double, _ sink: @escaping Sink) -> UUID {
        let id = UUID()
        sinkLock.withLock { sinks[id] = (rate, sink) }
        return id
    }


    /// Senke für beide Kanäle der Quelle getrennt (gleiche Blocklänge links und rechts), mit eigener Abtastrate
    @discardableResult
    public func addStereoSink(rate: Double, _ sink: @escaping StereoSink) -> UUID {
        let id = UUID()
        sinkLock.withLock { stereoSinks[id] = (rate, sink) }
        return id
    }

    public func removeSink(_ id: UUID) {
        sinkLock.withLock {
            _ = sinks.removeValue(forKey: id)
            _ = rawSinks.removeValue(forKey: id)
            _ = stereoSinks.removeValue(forKey: id)
        }
    }


    @discardableResult
    public func addRawSink(_ sink: @escaping RawSink) -> UUID {
        let id = UUID()
        sinkLock.withLock { rawSinks[id] = sink }
        return id
    }

    /// Führt `work` auf der Verarbeitungs-Queue aus – dort laufen auch die Senken (Decoder-Zustand ohne Locks ändern).
    public func perform(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    /// Anzahl der seit `start` an die Senken gelieferten Samples (Decoder-Rate). Für Statusanzeige und Tests.
    public var deliveredSampleCount: Int {
        queue.sync { deliveredSamples }
    }

    private func stopInternal() {
        timer?.cancel()
        timer = nil
        converters.removeAll()
        stereoConverters.removeAll()
    }

    private func drain() {
        guard timer != nil, inputRate > 0 else { return }
        drainStereo()
        let (current, raw) = sinkLock.withLock { (Array(sinks.values), Array(rawSinks.values)) }
        // Senken nach Zielrate gruppieren; Wandler bei Bedarf anlegen (auch für später hinzugekommene Senken)
        var groups: [Double: [Sink]] = [:]
        for entry in current { groups[entry.rate, default: []].append(entry.sink) }
        for rate in groups.keys where converters[rate] == nil {
            converters[rate] = SampleRateConverter(inputRate: inputRate, outputRate: rate)
        }
        while true {
            let n = ring.read(into: chunk, maxCount: chunkCapacity)
            guard n > 0 else { break }
            let block = UnsafeBufferPointer(start: chunk, count: n)
            level.add(block)
            for r in raw { r(block, inputRate) }
            for (rate, group) in groups {
                converters[rate]?.process(block) { out in
                    if rate == Self.decoderSampleRate { deliveredSamples += out.count }
                    for sink in group { sink(out) }
                }
            }
        }
    }

    /// Linken und rechten Kanal je Zielrate wandeln und an die Stereo-Senken geben (nur wenn Senken da sind und die Quelle beide Kanäle liefert)
    private func drainStereo() {
        let current = sinkLock.withLock { Array(stereoSinks.values) }
        guard !current.isEmpty, wantsStereo else { return }
        var groups: [Double: [StereoSink]] = [:]
        for entry in current { groups[entry.rate, default: []].append(entry.sink) }
        for rate in groups.keys where stereoConverters[rate] == nil {
            if let a = SampleRateConverter(inputRate: inputRate, outputRate: rate), let b = SampleRateConverter(inputRate: inputRate, outputRate: rate) {
                stereoConverters[rate] = (a, b)
            }
        }
        while true {
            let n = min(ringLeft.available, ringRight.available, chunkCapacity)
            guard n > 0 else { break }
            _ = ringLeft.read(into: chunkLeft, maxCount: n)
            _ = ringRight.read(into: chunkRight, maxCount: n)
            let l = UnsafeBufferPointer(start: chunkLeft, count: n), r = UnsafeBufferPointer(start: chunkRight, count: n)
            for (rate, group) in groups {
                guard let pair = stereoConverters[rate] else { continue }
                var outL: [Float] = [], outR: [Float] = []
                pair.0.process(l) { outL.append(contentsOf: $0) }
                pair.1.process(r) { outR.append(contentsOf: $0) }
                let m = min(outL.count, outR.count)
                guard m > 0 else { continue }
                outL.withUnsafeBufferPointer { bl in
                    outR.withUnsafeBufferPointer { br in
                        let a = UnsafeBufferPointer(rebasing: bl[0..<m]), b = UnsafeBufferPointer(rebasing: br[0..<m])
                        for sink in group { sink(a, b) }
                    }
                }
            }
        }
    }
}
