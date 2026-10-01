import Foundation

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

    private let queue = DispatchQueue(label: "com.peterbetz.digidec.pipeline", qos: .userInitiated)
    private let sinkLock = NSLock()
    private var sinks: [UUID: (rate: Double, sink: Sink)] = [:]
    /// Senken für das unveränderte Eingangssignal (Quell-Abtastrate), z. B. die Aufnahme
    public typealias RawSink = @Sendable (UnsafeBufferPointer<Float>, Double) -> Void
    private var rawSinks: [UUID: RawSink] = [:]
    private var inputRate: Double = 0

    // Nur auf `queue` benutzt
    private var timer: DispatchSourceTimer?
    /// Ein Wandler je Zielrate; Senken derselben Rate teilen sich das Ergebnis
    private var converters: [Double: SampleRateConverter] = [:]
    private let chunk = UnsafeMutablePointer<Float>.allocate(capacity: 9_600)
    private let chunkCapacity = 9_600
    private var deliveredSamples = 0

    public init() {}

    deinit {
        chunk.deallocate()
    }

    /// Startet die Verarbeitung für eine Quelle mit der angegebenen Abtastrate. Ein laufender Durchgang wird ersetzt.
    public func start(inputRate: Double) {
        queue.async { [self] in
            stopInternal()
            ring.clear()
            _ = level.take()
            converters.removeAll()
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

    public func removeSink(_ id: UUID) {
        sinkLock.withLock {
            _ = sinks.removeValue(forKey: id)
            _ = rawSinks.removeValue(forKey: id)
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
    }

    private func drain() {
        guard timer != nil, inputRate > 0 else { return }
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
}
