import Foundation
import Fldigi

/// Swift-Hülle um Olivia und Contestia (fldigi 4.2.13, Bibliothek von Pawel Jalocha SP9VRC, `Vendor/Fldigi/src/olivia`).
/// Mehrere Exemplare gleichzeitig sind möglich. Alle Aufrufe eines Exemplars von derselben Queue.
public final class FldigiOliviaCore {
    public static let sampleRate = Double(FLDIGI_OLIVIA_SAMPLE_RATE)

    public struct Options: Equatable, Sendable, Codable {
        /// false = Olivia, true = Contestia
        public var contestia = false
        /// Töne = 2 · 2^n: 1 → 4, 2 → 8, 3 → 16, 4 → 32, 5 → 64
        public var tonesExp = 2
        /// Bandbreite = 125 · 2^n: 0 → 125 … 4 → 2000 Hz
        public var bandwidthExp = 2
        public var syncMargin = 8
        public var syncInteg = 4
        /// 8-Bit-Zeichen (127 als Fluchtzeichen)
        public var eightBit = true
        public var squelchOn = true
        public var squelch: Double = 5
        public var reverse = false
        public init() {}

        public var tones: Int { 2 * (1 << tonesExp) }
        public var bandwidthHz: Int { 125 * (1 << bandwidthExp) }
        /// „8/500“
        public var label: String { "\(tones)/\(bandwidthHz)" }
        public var familyName: String { contestia ? "Contestia" : "Olivia" }
        public var presetID: String { (contestia ? "contestia-" : "olivia-") + "\(tones)-\(bandwidthHz)" }

        /// „olivia-8-500“, „contestia-16-1000“ oder nur „8-500“ (Olivia)
        public init?(presetID id: String) {
            var parts = id.lowercased().split(separator: "-").map(String.init)
            if let first = parts.first, first == "olivia" || first == "contestia" {
                contestia = first == "contestia"
                parts.removeFirst()
            }
            guard parts.count == 2, let t = Int(parts[0]), let b = Int(parts[1]),
                  let te = [4: 1, 8: 2, 16: 3, 32: 4, 64: 5][t], let be = [125: 0, 250: 1, 500: 2, 1000: 3, 2000: 4][b] else { return nil }
            tonesExp = te
            bandwidthExp = be
        }
    }

    public struct Status: Equatable, Sendable {
        public var centerHz: Double
        public var metric: Double
        public var snr: Double
        public var freqOffsetHz: Double
        public var bandwidthHz: Double
        public var tones: Int
    }

    private var handle: OpaquePointer?
    private let sink: Sink
    public private(set) var options: Options

    public init(options: Options = Options(), centerHz: Double, onChar: @escaping (UInt8) -> Void) {
        self.options = options
        sink = Sink(onChar)
        var cfg = Self.config(options)
        handle = fldigi_olivia_create(&cfg, centerHz, { ctx, c in
            guard let ctx else { return }
            Unmanaged<Sink>.fromOpaque(ctx).takeUnretainedValue().onChar(UInt8(truncatingIfNeeded: c))
        }, Unmanaged.passUnretained(sink).toOpaque())
    }

    deinit {
        fldigi_olivia_destroy(handle)
    }

    public func configure(_ options: Options) {
        self.options = options
        var cfg = Self.config(options)
        fldigi_olivia_configure(handle, &cfg)
    }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        fldigi_olivia_process(handle, base, Int32(samples.count))
    }

    public func setCenter(_ hz: Double) {
        fldigi_olivia_set_center(handle, hz)
    }

    /// Am Ende einer Aufnahme: restliche Zeichen ausgeben
    public func flush() {
        fldigi_olivia_flush(handle)
    }

    public var status: Status {
        var s = fldigi_olivia_status()
        fldigi_olivia_get_status(handle, &s)
        return Status(centerHz: s.center_hz, metric: s.metric, snr: s.snr, freqOffsetHz: s.freq_offset_hz,
                      bandwidthHz: s.bandwidth_hz, tones: Int(s.tones))
    }

    private static func config(_ o: Options) -> fldigi_olivia_config {
        var c = fldigi_olivia_default_config()
        c.contestia = o.contestia ? 1 : 0
        c.tones_exp = Int32(o.tonesExp)
        c.bandwidth_exp = Int32(o.bandwidthExp)
        c.sync_margin = Int32(o.syncMargin)
        c.sync_integ = Int32(o.syncInteg)
        c.eight_bit = o.eightBit ? 1 : 0
        c.squelch_on = o.squelchOn ? 1 : 0
        c.squelch = o.squelch
        c.reverse = o.reverse ? 1 : 0
        return c
    }

    private final class Sink {
        let onChar: (UInt8) -> Void
        init(_ f: @escaping (UInt8) -> Void) { onChar = f }
    }

    /// Olivia-/Contestia-Testsignal (8 kHz, Amplitude ≈ 1; nur für Tests)
    public static func synthesize(_ text: String, options: Options, centerHz: Double) -> [Float]? {
        var cfg = config(options)
        var out = [Float](repeating: 0, count: 8_000 * 300)
        let n = out.withUnsafeMutableBufferPointer { fldigi_olivia_synthesize(&cfg, text, centerHz, $0.baseAddress, Int32($0.count)) }
        return n > 0 ? Array(out.prefix(Int(n))) : nil
    }
}
