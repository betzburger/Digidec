// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Fldigi

/// Betriebsarten des MFSK-Moduls: MFSK, DominoEX, Thor, Throb, IFKP und FSQ (fldigi 4.2.13)
public enum MFSKMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case mfsk16, mfsk32, mfsk8, mfsk4, mfsk11, mfsk22, mfsk31, mfsk64, mfsk128, mfsk64l, mfsk128l
    case dominoex11, dominoex16, dominoex22, dominoex8, dominoex5, dominoex4, dominoexmicro, dominoex44, dominoex88
    case thor16, thor8, thor11, thor22, thor32, thor25, thor44, thor56, thor100, thor5, thor4, thormicro, thor25x4, thor50x1, thor50x2
    case throb1, throb2, throb4, throbx1, throbx2, throbx4
    case ifkp10, ifkp05, ifkp20
    case fsq45, fsq3, fsq6, fsq2, fsq15

    public var id: String { rawValue }

    public enum Family: String, CaseIterable, Sendable {
        case mfsk, dominoex, thor, throb, ifkp, fsq

        public var title: String {
            switch self {
            case .mfsk: return "MFSK"
            case .dominoex: return "DominoEX"
            case .thor: return "Thor"
            case .throb: return "Throb"
            case .ifkp: return "IFKP"
            case .fsq: return "FSQ"
            }
        }
    }

    public var family: Family {
        if rawValue.hasPrefix("dominoex") { return .dominoex }
        if rawValue.hasPrefix("thor") { return .thor }
        if rawValue.hasPrefix("throb") { return .throb }
        if rawValue.hasPrefix("ifkp") { return .ifkp }
        if rawValue.hasPrefix("fsq") { return .fsq }
        return .mfsk
    }

    /// „MFSK16“, „DominoEX 11“, „Thor 16“, „DominoEX Micro“
    public var displayName: String {
        switch family {
        case .mfsk: return rawValue.uppercased()
        case .dominoex:
            let rest = String(rawValue.dropFirst("dominoex".count))
            return "DominoEX " + (rest == "micro" ? "Micro" : rest)
        case .thor:
            let rest = String(rawValue.dropFirst("thor".count))
            return "Thor " + (rest == "micro" ? "Micro" : rest)
        case .throb:
            let rest = String(rawValue.dropFirst("throb".count))
            return rest.hasPrefix("x") ? "ThrobX " + rest.dropFirst() : "Throb " + rest
        case .ifkp: return "IFKP " + Self.ifkpSpeeds[rawValue]!
        case .fsq: return "FSQ " + Self.fsqSpeeds[rawValue]!
        }
    }

    private static let ifkpSpeeds = ["ifkp05": "0,5", "ifkp10": "1,0", "ifkp20": "2,0"]
    private static let fsqSpeeds = ["fsq15": "1,5", "fsq2": "2", "fsq3": "3", "fsq45": "4,5", "fsq6": "6"]

    /// Kurzform für Schaltflächen: „16“, „EX11“, „T16“
    public var shortName: String {
        switch family {
        case .mfsk: return String(rawValue.dropFirst("mfsk".count)).uppercased()
        case .dominoex: return "EX" + String(rawValue.dropFirst("dominoex".count)).replacingOccurrences(of: "micro", with: "µ")
        case .thor: return "T" + String(rawValue.dropFirst("thor".count)).replacingOccurrences(of: "micro", with: "µ")
        case .throb: return String(rawValue.dropFirst("throb".count)).uppercased()
        case .ifkp: return Self.ifkpSpeeds[rawValue]!
        case .fsq: return Self.fsqSpeeds[rawValue]!
        }
    }

    var cValue: Int32 {
        switch self {
        case .mfsk4: return Int32(FLDIGI_MFSK4)
        case .mfsk8: return Int32(FLDIGI_MFSK8)
        case .mfsk11: return Int32(FLDIGI_MFSK11)
        case .mfsk16: return Int32(FLDIGI_MFSK16)
        case .mfsk22: return Int32(FLDIGI_MFSK22)
        case .mfsk31: return Int32(FLDIGI_MFSK31)
        case .mfsk32: return Int32(FLDIGI_MFSK32)
        case .mfsk64: return Int32(FLDIGI_MFSK64)
        case .mfsk128: return Int32(FLDIGI_MFSK128)
        case .mfsk64l: return Int32(FLDIGI_MFSK64L)
        case .mfsk128l: return Int32(FLDIGI_MFSK128L)
        case .dominoexmicro: return Int32(FLDIGI_DOMINOEXMICRO)
        case .dominoex4: return Int32(FLDIGI_DOMINOEX4)
        case .dominoex5: return Int32(FLDIGI_DOMINOEX5)
        case .dominoex8: return Int32(FLDIGI_DOMINOEX8)
        case .dominoex11: return Int32(FLDIGI_DOMINOEX11)
        case .dominoex16: return Int32(FLDIGI_DOMINOEX16)
        case .dominoex22: return Int32(FLDIGI_DOMINOEX22)
        case .dominoex44: return Int32(FLDIGI_DOMINOEX44)
        case .dominoex88: return Int32(FLDIGI_DOMINOEX88)
        case .thormicro: return Int32(FLDIGI_THORMICRO)
        case .thor4: return Int32(FLDIGI_THOR4)
        case .thor5: return Int32(FLDIGI_THOR5)
        case .thor8: return Int32(FLDIGI_THOR8)
        case .thor11: return Int32(FLDIGI_THOR11)
        case .thor16: return Int32(FLDIGI_THOR16)
        case .thor22: return Int32(FLDIGI_THOR22)
        case .thor25: return Int32(FLDIGI_THOR25)
        case .thor32: return Int32(FLDIGI_THOR32)
        case .thor44: return Int32(FLDIGI_THOR44)
        case .thor56: return Int32(FLDIGI_THOR56)
        case .thor100: return Int32(FLDIGI_THOR100)
        case .thor25x4: return Int32(FLDIGI_THOR25X4)
        case .thor50x1: return Int32(FLDIGI_THOR50X1)
        case .thor50x2: return Int32(FLDIGI_THOR50X2)
        case .throb1: return Int32(FLDIGI_THROB1)
        case .throb2: return Int32(FLDIGI_THROB2)
        case .throb4: return Int32(FLDIGI_THROB4)
        case .throbx1: return Int32(FLDIGI_THROBX1)
        case .throbx2: return Int32(FLDIGI_THROBX2)
        case .throbx4: return Int32(FLDIGI_THROBX4)
        case .ifkp05: return Int32(FLDIGI_IFKP05)
        case .ifkp10: return Int32(FLDIGI_IFKP10)
        case .ifkp20: return Int32(FLDIGI_IFKP20)
        case .fsq15: return Int32(FLDIGI_FSQ15)
        case .fsq2: return Int32(FLDIGI_FSQ2)
        case .fsq3: return Int32(FLDIGI_FSQ3)
        case .fsq45: return Int32(FLDIGI_FSQ45)
        case .fsq6: return Int32(FLDIGI_FSQ6)
        }
    }

    /// Abtastrate, mit der der Empfänger arbeitet (8000, 11025 oder 16000 Hz)
    public var sampleRate: Double { fldigi_mfsk_sample_rate(cValue) }

    public static func mode(for family: Family) -> [MFSKMode] { allCases.filter { $0.family == family } }

    /// Breite des Tonfeldes in Hz: MFSK (Töne − 1) · Tonabstand, DominoEX und Thor 18 · Tonabstand (Tonabstand = Abtastrate · Doppelabstand / Symbollänge)
    public var bandwidthHz: Double {
        switch self {
        case .mfsk4: return 121
        case .mfsk8: return 242
        case .mfsk11: return 161
        case .mfsk16: return 234
        case .mfsk22: return 323
        case .mfsk31: return 219
        case .mfsk32: return 469
        case .mfsk64, .mfsk64l: return 938
        case .mfsk128, .mfsk128l: return 1875
        case .dominoexmicro, .thormicro: return 36
        case .dominoex4, .thor4: return 141
        case .dominoex5, .thor5: return 194
        case .dominoex8, .thor8: return 281
        case .dominoex11, .thor11: return 194
        case .dominoex16, .thor16: return 281
        case .dominoex22, .thor22: return 388
        case .dominoex44: return 1550
        case .dominoex88: return 1550
        case .thor25: return 450
        case .thor32: return 563
        case .thor44: return 775
        case .thor56: return 993
        case .thor100, .thor25x4, .thor50x2: return 1800
        case .thor50x1: return 900
        case .throb1, .throb2: return 64
        case .throb4: return 128
        case .throbx1, .throbx2: return 78
        case .throbx4: return 156
        case .ifkp05, .ifkp10, .ifkp20: return 387
        case .fsq15, .fsq2, .fsq3, .fsq45, .fsq6: return 290
        }
    }
}

/// Swift-Hülle um MFSK, DominoEX und Thor aus fldigi 4.2.13 (`Vendor/Fldigi/src/mfsk`).
/// Alle Aufrufe eines Exemplars von derselben Queue. DominoEX und Thor: nur ein Exemplar gleichzeitig.
public final class FldigiMFSKCore {
    public struct Options: Equatable, Sendable, Codable {
        public var mode: MFSKMode = .mfsk16
        /// Frequenznachführung (fldigi AFC, nur MFSK)
        public var afc = true
        /// DominoEX: MultiPsk-Vorwärtsfehlerkorrektur (fldigi „FEC“)
        public var fec = false
        public var squelchOn = true
        /// 0 … 100 gegen die Signalqualität (fldigi: Regler, Standard 5; Digidec 30, weil bei 5 Rauschen Zeichen liefert)
        public var squelch: Double = 30
        public var reverse = false
        public init() {}
    }

    public struct Status: Equatable, Sendable {
        public var centerHz: Double
        public var metric: Double
        public var bandwidthHz: Double
        public var sampleRate: Double
        public var tones: Int
    }

    private var handle: OpaquePointer?
    private let sink: Sink
    public private(set) var options: Options

    public init(options: Options = Options(), centerHz: Double, onChar: @escaping (UInt8) -> Void) {
        self.options = options
        sink = Sink(onChar)
        var cfg = Self.config(options)
        handle = fldigi_mfsk_create(&cfg, centerHz, { ctx, c in
            guard let ctx, c != 0 else { return }
            Unmanaged<Sink>.fromOpaque(ctx).takeUnretainedValue().onChar(UInt8(truncatingIfNeeded: c))
        }, Unmanaged.passUnretained(sink).toOpaque())
    }

    deinit {
        fldigi_mfsk_destroy(handle)
    }

    public func configure(_ options: Options) {
        self.options = options
        var cfg = Self.config(options)
        fldigi_mfsk_configure(handle, &cfg)
    }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        fldigi_mfsk_process(handle, base, Int32(samples.count))
    }

    public func setCenter(_ hz: Double) {
        fldigi_mfsk_set_center(handle, hz)
    }

    public var status: Status {
        var s = fldigi_mfsk_status()
        fldigi_mfsk_get_status(handle, &s)
        return Status(centerHz: s.center_hz, metric: s.metric, bandwidthHz: s.bandwidth_hz, sampleRate: s.sample_rate, tones: Int(s.tones))
    }

    private static func config(_ o: Options) -> fldigi_mfsk_config {
        var c = fldigi_mfsk_default_config()
        c.mode = o.mode.cValue
        c.afc = o.afc ? 1 : 0
        c.fec = o.fec ? 1 : 0
        c.squelch_on = o.squelchOn ? 1 : 0
        c.squelch = o.squelch
        c.reverse = o.reverse ? 1 : 0
        return c
    }

    private final class Sink {
        let onChar: (UInt8) -> Void
        init(_ f: @escaping (UInt8) -> Void) { onChar = f }
    }

    /// Testsignal wie fldigi sendet (Vorspann, STX, Text, EOT, Nachspann) in der Abtastrate der Betriebsart, Amplitude 1 (nur für Tests)
    public static func synthesize(_ text: String, mode: MFSKMode, centerHz: Double) -> [Float]? {
        var out = [Float](repeating: 0, count: 16_000 * 400)
        let n = out.withUnsafeMutableBufferPointer { fldigi_mfsk_synthesize(mode.cValue, text, centerHz, $0.baseAddress, Int32($0.count)) }
        return n > 0 ? Array(out.prefix(Int(n))) : nil
    }
}
