// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Fldigi

/// Swift-Hülle um den MT63-Empfänger (fldigi 4.2.13, Pawel Jalocha SP9VRC, `Vendor/Fldigi/src/mt63`).
/// Mehrere Exemplare gleichzeitig sind möglich. Alle Aufrufe eines Exemplars von derselben Queue.
public final class FldigiMT63Core {
    public static let sampleRate = Double(FLDIGI_MT63_SAMPLE_RATE)

    public struct Options: Equatable, Sendable, Codable {
        /// 500, 1000 oder 2000 Hz
        public var bandwidthHz = 1000
        /// lange Verschachtelung (64 statt 32): robuster, 6,4 s Verzögerung
        public var longInterleave = false
        /// lange Empfangsintegration (fldigi „Long receive integration“)
        public var longIntegration = false
        public var eightBit = true
        public var squelchOn = true
        public var squelch: Double = 5
        public init() {}

        /// „1000L“
        public var label: String { "\(bandwidthHz)\(longInterleave ? "L" : "S")" }
        public var presetID: String { "\(bandwidthHz)" + (longInterleave ? "l" : "s") }

        /// „500s“, „1000l“ (S = kurz, L = lang)
        public init?(presetID id: String) {
            let s = id.lowercased()
            guard let last = s.last, last == "s" || last == "l", let bw = Int(s.dropLast()), [500, 1000, 2000].contains(bw) else { return nil }
            bandwidthHz = bw
            longInterleave = last == "l"
        }
    }

    public struct Status: Equatable, Sendable {
        public var centerHz: Double
        public var snr: Double
        public var freqOffsetHz: Double
        public var locked: Bool
        public var confidence: Double
        public var bandwidthHz: Double
    }

    private var handle: OpaquePointer?
    private let sink: Sink
    public private(set) var options: Options

    public init(options: Options = Options(), centerHz: Double, onChar: @escaping (UInt8) -> Void) {
        self.options = options
        sink = Sink(onChar)
        var cfg = Self.config(options)
        handle = fldigi_mt63_create(&cfg, centerHz, { ctx, c in
            guard let ctx else { return }
            Unmanaged<Sink>.fromOpaque(ctx).takeUnretainedValue().onChar(UInt8(truncatingIfNeeded: c))
        }, Unmanaged.passUnretained(sink).toOpaque())
    }

    deinit {
        fldigi_mt63_destroy(handle)
    }

    public func configure(_ options: Options) {
        self.options = options
        var cfg = Self.config(options)
        fldigi_mt63_configure(handle, &cfg)
    }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        fldigi_mt63_process(handle, base, Int32(samples.count))
    }

    public func setCenter(_ hz: Double) {
        fldigi_mt63_set_center(handle, hz)
    }

    /// Am Ende einer Aufnahme: restliche Zeichen ausgeben
    public func flush() {
        fldigi_mt63_flush(handle)
    }

    public var status: Status {
        var s = fldigi_mt63_status()
        fldigi_mt63_get_status(handle, &s)
        return Status(centerHz: s.center_hz, snr: s.snr, freqOffsetHz: s.freq_offset_hz, locked: s.locked != 0,
                      confidence: s.confidence, bandwidthHz: s.bandwidth_hz)
    }

    private static func config(_ o: Options) -> fldigi_mt63_config {
        var c = fldigi_mt63_default_config()
        c.bandwidth_hz = Int32(o.bandwidthHz)
        c.long_interleave = o.longInterleave ? 1 : 0
        c.long_integration = o.longIntegration ? 1 : 0
        c.eight_bit = o.eightBit ? 1 : 0
        c.squelch_on = o.squelchOn ? 1 : 0
        c.squelch = o.squelch
        return c
    }

    private final class Sink {
        let onChar: (UInt8) -> Void
        init(_ f: @escaping (UInt8) -> Void) { onChar = f }
    }

    /// MT63-Testsignal (8 kHz, Amplitude ≈ 1; nur für Tests)
    public static func synthesize(_ text: String, options: Options, centerHz: Double) -> [Float]? {
        var cfg = config(options)
        var out = [Float](repeating: 0, count: 8_000 * 300)
        let n = out.withUnsafeMutableBufferPointer { fldigi_mt63_synthesize(&cfg, text, centerHz, $0.baseAddress, Int32($0.count)) }
        return n > 0 ? Array(out.prefix(Int(n))) : nil
    }
}
