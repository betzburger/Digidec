import Foundation
import Fldigi

/// Betriebsarten des PSK-Moduls (fldigi `psk.cxx`: BPSK31/63/125/250 und QPSK31/63/125/250)
public enum PSKMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case bpsk31, bpsk63, bpsk125, bpsk250, qpsk31, qpsk63, qpsk125, qpsk250

    public var id: String { rawValue }

    public var displayName: String { rawValue.uppercased() }

    public var isQPSK: Bool { rawValue.hasPrefix("q") }

    /// Symbolrate in Baud (31,25 · 2^n)
    public var baud: Double {
        switch self {
        case .bpsk31, .qpsk31: return 31.25
        case .bpsk63, .qpsk63: return 62.5
        case .bpsk125, .qpsk125: return 125
        case .bpsk250, .qpsk250: return 250
        }
    }

    var cValue: Int32 {
        switch self {
        case .bpsk31: return Int32(FLDIGI_PSK_BPSK31)
        case .bpsk63: return Int32(FLDIGI_PSK_BPSK63)
        case .bpsk125: return Int32(FLDIGI_PSK_BPSK125)
        case .bpsk250: return Int32(FLDIGI_PSK_BPSK250)
        case .qpsk31: return Int32(FLDIGI_PSK_QPSK31)
        case .qpsk63: return Int32(FLDIGI_PSK_QPSK63)
        case .qpsk125: return Int32(FLDIGI_PSK_QPSK125)
        case .qpsk250: return Int32(FLDIGI_PSK_QPSK250)
        }
    }
}

/// Swift-Hülle um den PSK-Empfänger aus fldigi 4.2.13 (`Vendor/Fldigi/src/psk`).
/// fldigi nutzt file-static-Variablen → nur **ein** Exemplar gleichzeitig. Alle Aufrufe von derselben Queue.
public final class FldigiPSKCore {
    public static let sampleRate = Double(FLDIGI_PSK_SAMPLE_RATE)

    public struct Options: Equatable, Sendable, Codable {
        public var mode: PSKMode = .bpsk31
        /// Frequenznachführung (fldigi AFC)
        public var afc = true
        public var squelchOn = true
        /// 0 … 100 gegen die Signalqualität (fldigi: Squelch-Regler, Standard 5)
        public var squelch: Double = 5
        /// QPSK: Seitenband umkehren (fldigi „Reverse“)
        public var reverse = false
        public init() {}
    }

    public struct Status: Equatable, Sendable {
        public var centerHz: Double
        public var metric: Double
        public var dcd: Bool
        public var snrDB: Double
        public var imdDB: Double
        public var phaseQuality: Int
        public var bandwidthHz: Double
    }

    private var handle: OpaquePointer?
    private let sink: Sink
    public private(set) var options: Options

    public init(options: Options = Options(), centerHz: Double, onChar: @escaping (UInt8) -> Void) {
        self.options = options
        sink = Sink(onChar)
        var cfg = Self.config(options)
        handle = fldigi_psk_create(&cfg, centerHz, { ctx, c in
            guard let ctx else { return }
            Unmanaged<Sink>.fromOpaque(ctx).takeUnretainedValue().onChar(UInt8(truncatingIfNeeded: c))
        }, Unmanaged.passUnretained(sink).toOpaque())
    }

    deinit {
        fldigi_psk_destroy(handle)
    }

    public func configure(_ options: Options) {
        self.options = options
        var cfg = Self.config(options)
        fldigi_psk_configure(handle, &cfg)
    }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        fldigi_psk_process(handle, base, Int32(samples.count))
    }

    public func setCenter(_ hz: Double) {
        fldigi_psk_set_center(handle, hz)
    }

    public var status: Status {
        var s = fldigi_psk_status()
        fldigi_psk_get_status(handle, &s)
        return Status(centerHz: s.center_hz, metric: s.metric, dcd: s.dcd != 0, snrDB: s.snr_db, imdDB: s.imd_db,
                      phaseQuality: Int(s.phase_quality), bandwidthHz: s.bandwidth_hz)
    }

    /// Letzte Symbole des Phasenvektors (Phase in rad, Betrag)
    public func scope(max: Int = 64) -> [(phase: Double, amplitude: Double)] {
        var p = [Double](repeating: 0, count: max), a = [Double](repeating: 0, count: max)
        let n = Int(fldigi_psk_get_scope(handle, &p, &a, Int32(max)))
        return (0..<n).map { (p[$0], a[$0]) }
    }

    private static func config(_ o: Options) -> fldigi_psk_config {
        var c = fldigi_psk_default_config()
        c.mode = o.mode.cValue
        c.afc = o.afc ? 1 : 0
        c.squelch_on = o.squelchOn ? 1 : 0
        c.squelch = o.squelch
        c.reverse = o.reverse ? 1 : 0
        return c
    }

    private final class Sink {
        let onChar: (UInt8) -> Void
        init(_ f: @escaping (UInt8) -> Void) { onChar = f }
    }

    /// PSK-Testsignal wie fldigi sendet (Vorspann, Varicode, Nachspann), 8 kHz, Amplitude 1 (nur für Tests)
    public static func synthesize(_ text: String, mode: PSKMode, centerHz: Double) -> [Float]? {
        var out = [Float](repeating: 0, count: 8_000 * 90)
        let n = out.withUnsafeMutableBufferPointer { fldigi_psk_synthesize(mode.cValue, text, centerHz, $0.baseAddress, Int32($0.count)) }
        return n > 0 ? Array(out.prefix(Int(n))) : nil
    }
}
