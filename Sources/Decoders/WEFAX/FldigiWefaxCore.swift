// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Fldigi

/// Ein fertig empfangenes Wetterfax (fldigi save_automatic bzw. Knopf Speichern)
public struct WefaxImage: Identifiable, Sendable {
    public let id = UUID()
    /// fldigis Dateiname „wefax_JJJJMMTT_hhmmss_<HF>_<Grund>.png“
    public var name: String
    /// fldigis Kommentare (Steuerung, LPM, Mitte, Korrelation, Grund des Endes …)
    public var comments: String
    public var width: Int
    public var height: Int
    /// Graustufen, Zeile für Zeile
    public var pixels: [UInt8]
    public var receivedAt: Date
    /// Ort der PNG-Datei, sobald gespeichert
    public var fileURL: URL?

    /// Grund des Endes aus dem Dateinamen: ok/ok2 (APT-Stopp), nocorr (Korrelation weg), max, phasing, apt, gui
    public var endReason: String {
        let base = (name as NSString).deletingPathExtension
        return base.split(separator: "_").last.map(String.init) ?? ""
    }

    public var endReasonGerman: String {
        switch endReason {
        case "ok", "ok2": return "APT-Stopp"
        case "nocorr": return "Signal verloren"
        case "max": return "Zeilengrenze"
        case "phasing", "apt", "apt2": return "nächstes Bild begann"
        case "gui": return "von Hand gespeichert"
        default: return endReason
        }
    }
}

/// Swift-Hülle um den WEFAX-Empfänger aus fldigi 4.2.13 (`Vendor/Fldigi/src/wefax`).
/// fldigis Hub ist dateiweit → nur **ein** Exemplar gleichzeitig. Alle Aufrufe von derselben Queue.
public final class FldigiWefaxCore {
    public static let sampleRate = Double(FLDIGI_WEFAX_SAMPLE_RATE)
    public static let lpmValues = [240, 120, 90, 60]

    public struct Options: Equatable, Sendable, Codable {
        /// 576 (Standard, 1809 Pixel je Zeile) oder 288
        public var ioc = 576
        public var lpm = 120
        /// Hub: fldigi-Standard 800 Hz; DWD laut fldigi 850 Hz
        public var shiftHz = 800
        public var centerHz = 1900
        /// 0 schmal, 1 mittel, 2 breit (ACfax-Filter)
        public var filter = 0
        public var afc = true
        public var autoCenter = true
        public var noiseRemoval = false
        public var maxRows = 4000
        /// Schräglauf-Korrektur in Prozent (fldigi „Slant“)
        public var slant = 0.0
        public init() {}

        /// Pixel je Zeile (fldigi ioc_to_width)
        public var width: Int { Int(Double(ioc) * Double.pi) }
    }

    public enum State: Int, Sendable {
        case aptStart = 0, aptStop = 1, phasing = 2, image = 3, idle = 10

        public var label: String {
            switch self {
            case .aptStart: return "WARTEN AUF APT"
            case .aptStop: return "APT-STOPP"
            case .phasing: return "PHASING"
            case .image: return "BILD"
            case .idle: return "BEREIT"
            }
        }
    }

    public struct Status: Equatable, Sendable {
        public var centerHz: Double
        /// Zeilenkorrelation × 100
        public var metric: Double
        public var snrDB: Double
        public var state: State
        public var lpm: Double
        public var width: Int
        public var rows: Int
        public var manual: Bool
        public var revision: UInt32
    }

    private var handle: OpaquePointer?
    private let sink: Sink
    public private(set) var options: Options

    public init(options: Options = Options(), onSaved: @escaping (WefaxImage) -> Void) {
        self.options = options
        sink = Sink(onSaved)
        var cfg = Self.config(options)
        handle = fldigi_wefax_create(&cfg, { ctx, name, comments, gray, width, height in
            guard let ctx else { return }
            let w = Int(width), h = Int(height)
            let px = (gray != nil && w > 0 && h > 0) ? Array(UnsafeBufferPointer(start: gray, count: w * h)) : []
            let img = WefaxImage(name: name.map { String(cString: $0) } ?? "wefax.png",
                                 comments: comments.map { String(cString: $0) } ?? "",
                                 width: w, height: h, pixels: px, receivedAt: Date())
            Unmanaged<Sink>.fromOpaque(ctx).takeUnretainedValue().onSaved(img)
        }, Unmanaged.passUnretained(sink).toOpaque())
    }

    deinit {
        fldigi_wefax_destroy(handle)
    }

    /// IOC und Hub verlangen ein neues Exemplar (fldigi: Moduswechsel)
    public static func needsRecreate(_ a: Options, _ b: Options) -> Bool {
        a.ioc != b.ioc || a.shiftHz != b.shiftHz
    }

    public func configure(_ options: Options) {
        self.options = options
        var cfg = Self.config(options)
        fldigi_wefax_configure(handle, &cfg)
    }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        fldigi_wefax_process(handle, base, Int32(samples.count))
    }

    public func setRF(_ hz: Int64) {
        fldigi_wefax_set_rf(handle, hz)
    }

    public var status: Status {
        var s = fldigi_wefax_status()
        fldigi_wefax_get_status(handle, &s)
        return Status(centerHz: s.center_hz, metric: s.metric, snrDB: s.snr_db,
                      state: State(rawValue: Int(s.state)) ?? .idle, lpm: s.lpm,
                      width: Int(s.width), rows: Int(s.rows), manual: s.manual != 0, revision: s.revision)
    }

    /// Aktuelles Bild (Graustufen, Breite × Zeilen)
    public func copyImage() -> (pixels: [UInt8], width: Int, rows: Int) {
        let st = status
        guard st.width > 0, st.rows > 0 else { return ([], st.width, 0) }
        var buf = [UInt8](repeating: 255, count: st.width * st.rows)
        let rows = Int(fldigi_wefax_copy_image(handle, &buf, Int32(buf.count)))
        return (Array(buf.prefix(rows * st.width)), st.width, rows)
    }

    public func skipAPT() { fldigi_wefax_skip_apt(handle) }
    public func skipPhasing() { fldigi_wefax_skip_phasing(handle) }
    public func abort() { fldigi_wefax_abort(handle) }
    public func setManual(_ on: Bool) { fldigi_wefax_set_manual(handle, on ? 1 : 0) }
    public func save() { fldigi_wefax_save(handle) }

    private static func config(_ o: Options) -> fldigi_wefax_config {
        var c = fldigi_wefax_default_config()
        c.ioc = Int32(o.ioc)
        c.lpm = Int32(o.lpm)
        c.shift_hz = Int32(o.shiftHz)
        c.center_hz = Int32(o.centerHz)
        c.filter = Int32(o.filter)
        c.afc = o.afc ? 1 : 0
        c.auto_center = o.autoCenter ? 1 : 0
        c.noise_removal = o.noiseRemoval ? 1 : 0
        c.max_rows = Int32(o.maxRows)
        c.slant = o.slant
        return c
    }

    private final class Sink {
        let onSaved: (WefaxImage) -> Void
        init(_ f: @escaping (WefaxImage) -> Void) { onSaved = f }
    }
}

/// WEFAX-Testsignal nach WMO/ITU: APT-Start (IOC 576: 300 Hz, IOC 288: 675 Hz Schwarz/Weiß), Phasing-Zeilen
/// (5 % Weiß um den Zeilenanfang), Bildzeilen, APT-Stopp (450 Hz). FM: Weiß = Mitte + Hub/2, Schwarz = Mitte − Hub/2.
public struct WefaxSignalGenerator {
    public var centerHz: Double = 1900
    public var shiftHz: Double = 800
    public var lpm: Double = 120
    public var ioc = 576
    public var sampleRate: Double = FldigiWefaxCore.sampleRate
    public var amplitude: Double = 0.5

    public init() {}

    public var width: Int { Int(Double(ioc) * Double.pi) }
    public var samplesPerLine: Double { sampleRate * 60 / lpm }

    /// Ganze Aussendung: Vorlauf Schwarz, APT-Start 5 s, `phasingLines` Phasing-Zeilen, das Bild, APT-Stopp 5 s, Schwarz
    public func transmission(rows: Int, phasingLines: Int = 60, pixel: (Int, Int) -> UInt8) -> [Float] {
        var g = State(gen: self)
        g.tone(0, seconds: 1)
        g.apt(hz: ioc == 288 ? 675 : 300, seconds: 5)
        let w = width
        let phasing = (0..<w).map { c -> UInt8 in (Double(c) < Double(w) * 0.025 || Double(c) >= Double(w) * 0.975) ? 255 : 0 }
        for _ in 0..<phasingLines { g.line(phasing) }
        for r in 0..<rows { g.line((0..<w).map { pixel(r, $0) }) }
        g.apt(hz: 450, seconds: 5)
        g.tone(0, seconds: 10)
        return g.out
    }

    private struct State {
        let gen: WefaxSignalGenerator
        var out: [Float] = []
        var phase = 0.0
        var lineStart = -1.0   // exakte Startzeit der nächsten Zeile (keine Rundungsdrift)

        init(gen: WefaxSignalGenerator) { self.gen = gen }

        mutating func emit(_ v: Double, count: Int) {
            let f = gen.centerHz + gen.shiftHz / 2 * (2 * v / 255 - 1)
            let dphi = 2 * Double.pi * f / gen.sampleRate
            for _ in 0..<max(0, count) {
                phase += dphi
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                out.append(Float(gen.amplitude * sin(phase)))
            }
        }

        mutating func tone(_ v: Double, seconds: Double) {
            emit(v, count: Int(seconds * gen.sampleRate))
            lineStart = -1
        }

        mutating func apt(hz: Double, seconds: Double) {
            let half = gen.sampleRate / hz / 2
            let start = Double(out.count)
            var t = 0.0, hi = true
            while t < seconds * gen.sampleRate {
                let end = Int((start + t + half).rounded())
                emit(hi ? 255 : 0, count: end - out.count)
                hi.toggle()
                t += half
            }
            lineStart = -1
        }

        mutating func line(_ pixels: [UInt8]) {
            if lineStart < 0 { lineStart = Double(out.count) }
            let spl = gen.samplesPerLine
            for (c, v) in pixels.enumerated() {
                let end = Int((lineStart + spl * Double(c + 1) / Double(pixels.count)).rounded())
                emit(Double(v), count: end - out.count)
            }
            lineStart += spl
        }
    }
}
