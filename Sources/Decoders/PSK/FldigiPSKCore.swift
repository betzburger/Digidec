// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Fldigi

/// Betriebsarten des PSK-Moduls (fldigi `psk.cxx`: BPSK31/63/125/250, QPSK31/63/125/250, PSKR 125/250/500/1000 und 8PSK 125 … 1200)
public enum PSKMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case bpsk31, bpsk63, bpsk125, bpsk250, qpsk31, qpsk63, qpsk125, qpsk250
    case psk125r, psk250r, psk500r, psk1000r
    case psk8_125 = "8psk125", psk8_125fl = "8psk125fl", psk8_125f = "8psk125f", psk8_250 = "8psk250", psk8_250fl = "8psk250fl", psk8_250f = "8psk250f"
    case psk8_500 = "8psk500", psk8_500f = "8psk500f", psk8_1000 = "8psk1000", psk8_1000f = "8psk1000f", psk8_1200f = "8psk1200f"

    public var id: String { rawValue }

    public var displayName: String { rawValue.uppercased() }

    public var isQPSK: Bool { rawValue.hasPrefix("q") }

    public enum Family: String, CaseIterable, Sendable { case bpsk, qpsk, pskr, psk8 }

    public var family: Family {
        if rawValue.hasPrefix("8") { return .psk8 }
        if rawValue.hasSuffix("r") { return .pskr }
        return rawValue.hasPrefix("q") ? .qpsk : .bpsk
    }

    /// Abtastrate des Empfängers: 8PSK 16000 Hz, alle anderen 8000 Hz
    public var sampleRate: Double { fldigi_psk_sample_rate(cValue) }

    /// Mit Vorwärtsfehlerkorrektur (PSKR und 8PSK mit „F“ oder „FL“)
    public var hasFEC: Bool { family == .pskr || rawValue.hasSuffix("f") || rawValue.hasSuffix("fl") }

    /// Beschriftung auf der Schaltfläche („125R“, „8-125“, „8-125F“)
    public var shortName: String {
        switch family {
        case .bpsk, .qpsk: return displayName
        case .pskr: return String(rawValue.dropFirst(3)).uppercased()
        case .psk8: return "8-" + String(rawValue.dropFirst(4)).uppercased()
        }
    }

    /// Symbolrate in Baud (31,25 · 2^n)
    public var baud: Double {
        switch self {
        case .bpsk31, .qpsk31: return 31.25
        case .bpsk63, .qpsk63: return 62.5
        case .bpsk125, .qpsk125: return 125
        case .bpsk250, .qpsk250: return 250
        case .psk125r, .psk8_125, .psk8_125fl, .psk8_125f: return 125
        case .psk250r, .psk8_250, .psk8_250fl, .psk8_250f: return 250
        case .psk500r, .psk8_500, .psk8_500f: return 500
        case .psk1000r, .psk8_1000, .psk8_1000f: return 1000
        case .psk8_1200f: return 16000.0 / 13.0
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
        case .psk125r: return Int32(FLDIGI_PSK_PSK125R)
        case .psk250r: return Int32(FLDIGI_PSK_PSK250R)
        case .psk500r: return Int32(FLDIGI_PSK_PSK500R)
        case .psk1000r: return Int32(FLDIGI_PSK_PSK1000R)
        case .psk8_125: return Int32(FLDIGI_PSK_8PSK125)
        case .psk8_125fl: return Int32(FLDIGI_PSK_8PSK125FL)
        case .psk8_125f: return Int32(FLDIGI_PSK_8PSK125F)
        case .psk8_250: return Int32(FLDIGI_PSK_8PSK250)
        case .psk8_250fl: return Int32(FLDIGI_PSK_8PSK250FL)
        case .psk8_250f: return Int32(FLDIGI_PSK_8PSK250F)
        case .psk8_500: return Int32(FLDIGI_PSK_8PSK500)
        case .psk8_500f: return Int32(FLDIGI_PSK_8PSK500F)
        case .psk8_1000: return Int32(FLDIGI_PSK_8PSK1000)
        case .psk8_1000f: return Int32(FLDIGI_PSK_8PSK1000F)
        case .psk8_1200f: return Int32(FLDIGI_PSK_8PSK1200F)
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

    /// PSK-Testsignal wie fldigi sendet (Vorspann, Varicode, Nachspann) in der Abtastrate der Betriebsart, Amplitude 1 (nur für Tests)
    public static func synthesize(_ text: String, mode: PSKMode, centerHz: Double) -> [Float]? {
        var out = [Float](repeating: 0, count: 16_000 * 90)
        let n = out.withUnsafeMutableBufferPointer { fldigi_psk_synthesize(mode.cValue, text, centerHz, $0.baseAddress, Int32($0.count)) }
        return n > 0 ? Array(out.prefix(Int(n))) : nil
    }
}
