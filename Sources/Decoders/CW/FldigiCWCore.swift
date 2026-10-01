import Foundation
import Fldigi

/// Swift-Hülle um den CW-Empfänger aus fldigi 4.2.13 (`Vendor/Fldigi/src/cw`).
/// fldigi nutzt file-static-Variablen → nur **ein** Exemplar gleichzeitig. Alle Aufrufe von derselben Queue.
public final class FldigiCWCore {
    public static let sampleRate = Double(FLDIGI_CW_SAMPLE_RATE)

    public struct Options: Equatable, Sendable, Codable {
        /// Startgeschwindigkeit und Mitte des Nachführbereichs (fldigi CWspeed)
        public var speedWPM = 18
        public var bandwidthHz = 150
        /// Bandbreite automatisch 2 × WpM (fldigi „matched filter“)
        public var matchedFilter = false
        /// 0: 128, 1: 256, 2: 512, 3: 1024 FIR-Taps
        public var filterLength = 2
        public var track = true
        public var rangeWPM = 10
        public var lowerWPM = 5
        public var upperWPM = 50
        /// 0 langsam, 1 mittel, 2 schnell
        public var attack = 1
        public var decay = 1
        public var somDecoding = false
        public var squelchOn = false
        public var squelch: Double = 20
        public init() {}
    }

    public struct Status: Equatable, Sendable {
        public var centerHz: Double
        public var metric: Double
        public var wpm: Double
        public var level: Double
    }

    private var handle: OpaquePointer?
    private let sink: Sink
    public private(set) var options: Options

    /// `onText` bekommt Zeichen, Wortabstände und Prosigns („<BT>“; `isProsign`)
    public init(options: Options = Options(), centerHz: Double, onText: @escaping (String, Bool) -> Void) {
        self.options = options
        sink = Sink(onText)
        var cfg = Self.config(options)
        handle = fldigi_cw_create(&cfg, centerHz, { ctx, text, prosign in
            guard let ctx, let text else { return }
            let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self), count: strlen(text))
            // fldigis Morsetabelle ist UTF-8 (Ä, Ö, Ü …); Einzelbytes eines Mehrbyte-Zeichens kommen getrennt
            Unmanaged<Sink>.fromOpaque(ctx).takeUnretainedValue().add(Array(bytes), prosign: prosign != 0)
        }, Unmanaged.passUnretained(sink).toOpaque())
    }

    deinit {
        fldigi_cw_destroy(handle)
    }

    public func configure(_ options: Options) {
        self.options = options
        var cfg = Self.config(options)
        fldigi_cw_configure(handle, &cfg)
    }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        fldigi_cw_process(handle, base, Int32(samples.count))
    }

    public func setCenter(_ hz: Double) {
        fldigi_cw_set_center(handle, hz)
    }

    public var status: Status {
        var s = fldigi_cw_status()
        fldigi_cw_get_status(handle, &s)
        return Status(centerHz: s.center_hz, metric: s.metric, wpm: s.rx_wpm, level: s.level)
    }

    /// Hüllkurve der letzten Zeichen (0…1) für die Abstimmanzeige
    public func scope(max: Int = 512) -> [Double] {
        var buf = [Double](repeating: 0, count: max)
        let n = Int(fldigi_cw_get_scope(handle, &buf, Int32(max)))
        return Array(buf.prefix(n))
    }

    private static func config(_ o: Options) -> fldigi_cw_config {
        var c = fldigi_cw_default_config()
        c.speed_wpm = Int32(o.speedWPM)
        c.bandwidth_hz = Int32(o.bandwidthHz)
        c.matched_filter = o.matchedFilter ? 1 : 0
        c.filter_length = Int32(o.filterLength)
        c.track = o.track ? 1 : 0
        c.range_wpm = Int32(o.rangeWPM)
        c.lower_wpm = Int32(o.lowerWPM)
        c.upper_wpm = Int32(o.upperWPM)
        c.attack = Int32(o.attack)
        c.decay = Int32(o.decay)
        c.som_decoding = o.somDecoding ? 1 : 0
        c.squelch_on = o.squelchOn ? 1 : 0
        c.squelch = o.squelch
        return c
    }

    /// Setzt UTF-8-Byte für Byte wieder zu Zeichen zusammen
    private final class Sink {
        let onText: (String, Bool) -> Void
        var pending: [UInt8] = []
        init(_ f: @escaping (String, Bool) -> Void) { onText = f }
        func add(_ bytes: [UInt8], prosign: Bool) {
            pending += bytes
            // vollständige UTF-8-Folge? (Startbyte bestimmt die Länge)
            guard let first = pending.first else { return }
            let need = first < 0x80 ? 1 : first >= 0xF0 ? 4 : first >= 0xE0 ? 3 : first >= 0xC0 ? 2 : 1
            guard pending.count >= need else { return }
            onText(String(decoding: pending, as: UTF8.self), prosign)
            pending.removeAll()
        }
    }
}

/// CW-Testsignal: Morse mit Punktlänge 1,2 s / WpM, weichen Flanken und Ton bei `toneHz`
public struct CWSignalGenerator {
    public var wpm: Double = 18
    public var toneHz: Double = 700
    public var sampleRate: Double = FldigiCWCore.sampleRate
    public var amplitude: Double = 0.5
    /// Anstiegszeit der Flanken in Sekunden
    public var rise: Double = 0.005

    public static let code: [Character: String] = [
        "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".", "F": "..-.", "G": "--.", "H": "....", "I": "..",
        "J": ".---", "K": "-.-", "L": ".-..", "M": "--", "N": "-.", "O": "---", "P": ".--.", "Q": "--.-", "R": ".-.",
        "S": "...", "T": "-", "U": "..-", "V": "...-", "W": ".--", "X": "-..-", "Y": "-.--", "Z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-", "5": ".....", "6": "-....",
        "7": "--...", "8": "---..", "9": "----.", "/": "-..-.", "?": "..--..", ".": ".-.-.-", ",": "--..--",
        "=": "-...-", "Ä": ".-.-", "Ö": "---.", "Ü": "..--"
    ]

    public init() {}

    public func samples(for text: String, leadIn: Double = 0.5, tail: Double = 1.0) -> [Float] {
        let dot = 1.2 / wpm
        var key: [(on: Bool, secs: Double)] = [(false, leadIn)]
        for ch in text.uppercased() {
            if ch == " " { key.append((false, 4 * dot)); continue }
            guard let c = Self.code[ch] else { continue }
            for el in c {
                key.append((true, el == "." ? dot : 3 * dot))
                key.append((false, dot))
            }
            key.append((false, 2 * dot))          // Zeichenabstand 3 Punkte insgesamt
        }
        key.append((false, tail))
        var out = [Float]()
        var env = 0.0
        let a = min(1, 1 / (rise * sampleRate) * 3)
        var n = 0
        for k in key {
            let count = Int((k.secs * sampleRate).rounded())
            for _ in 0..<count {
                env += ((k.on ? 1 : 0) - env) * a
                out.append(Float(amplitude * env * sin(2 * Double.pi * toneHz * Double(n) / sampleRate)))
                n += 1
            }
        }
        return out
    }
}
