import Foundation
import Fldigi

/// Betriebsarten des Hell-Moduls (fldigi `feld.cxx`)
public enum HellMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case feld, slow, x5, x9, fskh245, fskh105, hell80

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .feld: return "Feld Hell"
        case .slow: return "Slow Hell"
        case .x5: return "Hell X5"
        case .x9: return "Hell X9"
        case .fskh245: return "FSK Hell 245"
        case .fskh105: return "FSK Hell 105"
        case .hell80: return "Hell 80"
        }
    }

    /// Kurzform für Schaltflächen
    public var shortName: String {
        switch self {
        case .feld: return "FELD"
        case .slow: return "SLOW"
        case .x5: return "X5"
        case .x9: return "X9"
        case .fskh245: return "FSK245"
        case .fskh105: return "FSK105"
        case .hell80: return "H80"
        }
    }

    /// Breite des Signals in Hz (fldigi `hell_bandwidth`)
    public var bandwidthHz: Double {
        switch self {
        case .feld: return 245
        case .slow: return 30.6
        case .x5: return 1225
        case .x9: return 2205
        case .fskh245: return 122.5
        case .fskh105: return 55
        case .hell80: return 300
        }
    }

    public var note: String {
        switch self {
        case .feld: return "Feld Hell: Amplitudentastung, 17,5 Spalten je Sekunde (2,5 Baud), das klassische Hellschreiber-Verfahren"
        case .slow: return "Slow Hell: Feld Hell mit einem Achtel der Geschwindigkeit, schmaler und für schwache Signale"
        case .x5: return "Hell X5: fünffache Geschwindigkeit"
        case .x9: return "Hell X9: neunfache Geschwindigkeit"
        case .fskh245: return "FSK Hell: Frequenzumtastung, 245 Baud (17,5 Spalten je Sekunde)"
        case .fskh105: return "FSK Hell: Frequenzumtastung, 105 Baud"
        case .hell80: return "Hell 80: schnelles FSK-Hell, 35 Spalten je Sekunde"
        }
    }

    public var isFSK: Bool { self == .fskh245 || self == .fskh105 || self == .hell80 }

    var cValue: Int32 {
        switch self {
        case .feld: return Int32(FLDIGI_HELL_FELD)
        case .slow: return Int32(FLDIGI_HELL_SLOW)
        case .x5: return Int32(FLDIGI_HELL_X5)
        case .x9: return Int32(FLDIGI_HELL_X9)
        case .fskh245: return Int32(FLDIGI_HELL_FSKH245)
        case .fskh105: return Int32(FLDIGI_HELL_FSKH105)
        case .hell80: return Int32(FLDIGI_HELL_80)
        }
    }
}

/// Swift-Hülle um den Feld-Hell-Empfänger aus fldigi 4.2.13 (`Vendor/Fldigi/src/mfsk/feld_rx.cpp`).
/// Liefert Rasterspalten statt Zeichen. Alle Aufrufe eines Exemplars von derselben Queue.
public final class FldigiHellCore {
    public static let sampleRate = Double(FLDIGI_HELL_SAMPLE_RATE)

    public struct Options: Equatable, Sendable, Codable {
        public var mode: HellMode = .feld
        public var squelchOn = true
        /// 0 … 100 gegen die Signalstärke (fldigi: Regler, Standard 5)
        public var squelch: Double = 5
        /// FSK-Hell: Töne vertauschen
        public var reverse = false
        /// Umkehrdarstellung (weiße Schrift auf Schwarz)
        public var blackboard = false
        /// Spaltenlänge in Pixeln (fldigi „Hell Rcv Height“, 4 … 42)
        public var columnHeight = 20
        /// Jede Spalte so oft ausgeben (fldigi „Hell Rcv Width“, 1 … 4)
        public var columnRepeat = 2
        /// 1 langsam, 2 mittel, 3 schnell
        public var agc = 2
        public init() {}
    }

    public struct Status: Equatable, Sendable {
        public var centerHz: Double
        public var metric: Double
        public var bandwidthHz: Double
        public var filterHz: Double
        public var columnHeight: Int
    }

    private var handle: OpaquePointer?
    private let sink: Sink
    public private(set) var options: Options

    /// `onColumn` bekommt 2 · Spaltenlänge Werte (0 = schwarz … 255 = weiß): zuerst die vorherige, dann die aktuelle Spalte
    public init(options: Options = Options(), centerHz: Double, onColumn: @escaping ([UInt8]) -> Void) {
        self.options = options
        sink = Sink(onColumn)
        var cfg = Self.config(options)
        handle = fldigi_hell_create(&cfg, centerHz, { ctx, data, length in
            guard let ctx, let data else { return }
            let values = UnsafeBufferPointer(start: data, count: Int(length)).map { UInt8(clamping: $0) }
            Unmanaged<Sink>.fromOpaque(ctx).takeUnretainedValue().onColumn(values)
        }, Unmanaged.passUnretained(sink).toOpaque())
    }

    deinit {
        fldigi_hell_destroy(handle)
    }

    public func configure(_ options: Options) {
        self.options = options
        var cfg = Self.config(options)
        fldigi_hell_configure(handle, &cfg)
    }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        fldigi_hell_process(handle, base, Int32(samples.count))
    }

    public func setCenter(_ hz: Double) {
        fldigi_hell_set_center(handle, hz)
    }

    public var status: Status {
        var s = fldigi_hell_status()
        fldigi_hell_get_status(handle, &s)
        return Status(centerHz: s.center_hz, metric: s.metric, bandwidthHz: s.bandwidth_hz, filterHz: s.filter_hz, columnHeight: Int(s.column_height))
    }

    private static func config(_ o: Options) -> fldigi_hell_config {
        var c = fldigi_hell_default_config()
        c.mode = o.mode.cValue
        c.squelch_on = o.squelchOn ? 1 : 0
        c.squelch = o.squelch
        c.reverse = o.reverse ? 1 : 0
        c.blackboard = o.blackboard ? 1 : 0
        c.column_height = Int32(o.columnHeight)
        c.column_repeat = Int32(o.columnRepeat)
        c.agc = Int32(o.agc)
        return c
    }

    private final class Sink {
        let onColumn: ([UInt8]) -> Void
        init(_ f: @escaping ([UInt8]) -> Void) { onColumn = f }
    }

    /// Testsignal wie fldigi sendet (Punkte, Text, Punkte), 8 kHz, Amplitude 1 (nur für Tests)
    public static func synthesize(_ text: String, mode: HellMode, centerHz: Double) -> [Float]? {
        var out = [Float](repeating: 0, count: 8_000 * 300)
        let n = out.withUnsafeMutableBufferPointer { fldigi_hell_synthesize(mode.cValue, text, centerHz, $0.baseAddress, Int32($0.count)) }
        return n > 0 ? Array(out.prefix(Int(n))) : nil
    }
}
