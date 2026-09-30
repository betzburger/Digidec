import Foundation

/// Verbindet die Quellen (Live-Eingang oder WAV-Datei) mit den Verbrauchern (Decoder, ab M3 Wasserfall).
///
/// Quelle → `ring` (Mono, Quell-Abtastrate) → Verarbeitungs-Queue alle 20 ms:
/// Pegel messen → auf `decoderSampleRate` wandeln → an alle Senken verteilen.
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
    private var sinks: [UUID: Sink] = [:]

    // Nur auf `queue` benutzt
    private var timer: DispatchSourceTimer?
    private var converter: SampleRateConverter?
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
            converter = SampleRateConverter(inputRate: inputRate, outputRate: Self.decoderSampleRate)
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

    @discardableResult
    public func addSink(_ sink: @escaping Sink) -> UUID {
        let id = UUID()
        sinkLock.withLock { sinks[id] = sink }
        return id
    }

    public func removeSink(_ id: UUID) {
        sinkLock.withLock { _ = sinks.removeValue(forKey: id) }
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
        converter = nil
    }

    private func drain() {
        guard let converter else { return }
        let current = sinkLock.withLock { Array(sinks.values) }
        while true {
            let n = ring.read(into: chunk, maxCount: chunkCapacity)
            guard n > 0 else { break }
            let block = UnsafeBufferPointer(start: chunk, count: n)
            level.add(block)
            converter.process(block) { out in
                deliveredSamples += out.count
                for sink in current { sink(out) }
            }
        }
    }
}
