// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Fldigi

/// Swift-Hülle um den RTTY-Empfänger aus fldigi 4.2.13 (`Vendor/Fldigi`).
/// Nicht threadsicher: alle Aufrufe von derselben Queue (in der App: Verarbeitungs-Queue der Pipeline).
public final class FldigiRTTYCore {
    public static let sampleRate = Double(FLDIGI_RTTY_SAMPLE_RATE)

    public struct Options: Equatable, Sendable {
        public var afcOn = true
        /// 0 langsam, 1 normal, 2 schnell
        public var afcSpeed = 1
        public var squelchOn = false
        /// 0 … 100, verglichen mit `Status.metric`
        public var squelch: Double = 0
        /// 0 Mark-Space, 1 nur Mark, 2 nur Space
        public var cwi = 0
        public var unshiftOnSpace = true
        /// ITA2-Ziffernsatz (sonst US-TTY wie fldigi-Standard)
        public var ita2 = false
        public var trueScope = true
        /// Filter-Formfaktor; fldigi 4.2.13 verwendet fest 1,4
        public var filterK = 1.4
        public var lowCutoff: Double = 0
        public var highCutoff: Double = 4000

        public init() {}
    }

    public struct Status: Equatable, Sendable {
        public var centerHz: Double
        public var metric: Double
        public var snrDB: Double
        public var freqError: Double
        public var markMag: Double
        public var spaceMag: Double
    }

    private var handle: OpaquePointer?
    private let sink: CharSink
    public private(set) var parameters: RTTYParameters
    public private(set) var options: Options

    /// `onChar` wird synchron aus `process` heraus aufgerufen.
    public init(parameters: RTTYParameters, options: Options = Options(), centerHz: Double,
                onChar: @escaping (Character) -> Void) {
        self.parameters = parameters
        self.options = options
        sink = CharSink(onChar)
        var cfg = Self.config(parameters, options)
        handle = fldigi_rtty_create(&cfg, centerHz, { ctx, c in
            guard let ctx else { return }
            Unmanaged<CharSink>.fromOpaque(ctx).takeUnretainedValue().emit(c)
        }, Unmanaged.passUnretained(sink).toOpaque())
    }

    deinit {
        fldigi_rtty_destroy(handle)
    }

    public func configure(parameters: RTTYParameters, options: Options) {
        self.parameters = parameters
        self.options = options
        var cfg = Self.config(parameters, options)
        fldigi_rtty_configure(handle, &cfg)
    }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        fldigi_rtty_process(handle, base, Int32(samples.count))
    }

    public func setCenter(_ hz: Double) {
        fldigi_rtty_set_center(handle, hz)
    }

    public var status: Status {
        var s = fldigi_rtty_status()
        fldigi_rtty_get_status(handle, &s)
        return Status(centerHz: s.center_hz, metric: s.metric, snrDB: s.snr_db,
                      freqError: s.freq_error, markMag: s.mark_mag, spaceMag: s.space_mag)
    }

    /// XY-Scope-Punkte, älteste zuerst
    public func scopePoints(max: Int = 1024) -> [CGPoint] {
        var buf = [Double](repeating: 0, count: 2 * max)
        let n = Int(fldigi_rtty_get_scope(handle, &buf, Int32(max)))
        return (0..<n).map { CGPoint(x: buf[2 * $0], y: buf[2 * $0 + 1]) }
    }

    private static func config(_ p: RTTYParameters, _ o: Options) -> fldigi_rtty_config {
        var c = fldigi_rtty_default_config()
        c.shift = p.shift
        c.baud = p.baud
        c.bits = Int32(p.bits)
        c.parity = Int32(RTTYParity.allCases.firstIndex(of: p.parity) ?? 0)
        c.stop_bits = p.stopBits
        c.reverse = p.reverse ? 1 : 0
        c.afc_on = o.afcOn ? 1 : 0
        c.afc_speed = Int32(o.afcSpeed)
        c.squelch_on = o.squelchOn ? 1 : 0
        c.squelch = o.squelch
        c.cwi = Int32(o.cwi)
        c.uos_rx = o.unshiftOnSpace ? 1 : 0
        c.ita2 = o.ita2 ? 1 : 0
        c.true_scope = o.trueScope ? 1 : 0
        c.filter_k = o.filterK
        c.low_cutoff = o.lowCutoff
        c.high_cutoff = o.highCutoff
        return c
    }

    private final class CharSink {
        let onChar: (Character) -> Void
        init(_ f: @escaping (Character) -> Void) { onChar = f }
        func emit(_ c: Int32) {
            guard let scalar = Unicode.Scalar(UInt32(UInt8(truncatingIfNeeded: c))) else { return }
            onChar(Character(scalar))
        }
    }
}
