// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import JS8

/// Betriebsarten von JS8 (Namen und Werte wie in JS8Call). „Ultra“ ist in JS8Call abgeschaltet und fehlt hier.
public enum JS8Submode: Int, CaseIterable, Identifiable, Codable, Sendable, Comparable {
    case normal = 0
    case fast = 1
    case turbo = 2
    case slow = 4

    public var id: Int { rawValue }

    public static func < (a: JS8Submode, b: JS8Submode) -> Bool { a.periodSeconds < b.periodSeconds }

    /// Buchstabe wie in ALL.TXT von JS8Call
    public var letter: String {
        switch self {
        case .normal: return "A"
        case .fast: return "B"
        case .turbo: return "C"
        case .slow: return "E"
        }
    }

    public var title: String {
        switch self {
        case .normal: return "NORMAL"
        case .fast: return "FAST"
        case .turbo: return "TURBO"
        case .slow: return "SLOW"
        }
    }

    /// Länge des Zyklus (UTC-Raster)
    public var periodSeconds: Double { Double(js8dd_period_seconds(Int32(rawValue))) }
    /// Abtastwerte je Symbol bei 12 kHz
    public var symbolSamples: Int { Int(js8dd_symbol_samples(Int32(rawValue))) }
    /// Verzögerung der Aussendung nach Zyklusbeginn
    public var startDelay: Double { Double(js8dd_start_delay_ms(Int32(rawValue))) / 1000 }
    /// Symbolrate in Baud
    public var baud: Double { 12_000 / Double(symbolSamples) }
    /// Abstand der 8 Töne (= Symbolrate)
    public var toneSpacing: Double { baud }
    /// Belegte Bandbreite (8 Töne)
    public var bandwidth: Double { 8 * toneSpacing }
    /// Dauer der Aussendung (79 Symbole)
    public var txDuration: Double { Double(79 * symbolSamples) / 12_000 }
    /// Schreibtempo laut JS8Call
    public var wordsPerMinute: Int {
        switch self {
        case .normal: return 16
        case .fast: return 24
        case .turbo: return 40
        case .slow: return 8
        }
    }

    /// Sekunden nach Zyklusbeginn, zu denen decodiert wird: kurz nach dem Ende der Aussendung
    public var decodeAt: Double { min(periodSeconds - 0.05, startDelay + txDuration + 0.3) }

    public static func submode(letter: String) -> JS8Submode? { allCases.first { $0.letter == letter.uppercased() } }
}

/// Ein decodierter JS8-Rahmen (12 Zeichen, 3 Bit Übertragungsart) mit dem ausgepackten Inhalt
public struct JS8Decode: Identifiable, Sendable, Equatable {
    public let id = UUID()
    /// Beginn des Zyklus (UTC)
    public var cycleStart: Date
    public var submode: JS8Submode
    /// Die 12 Zeichen des Rahmens
    public var frame: String
    public var bits: JS8FrameBits
    /// S/N in 2500 Hz (JS8Call-Konvention)
    public var snrDB: Int
    /// Zeitversatz in Sekunden gegen den nominellen Beginn
    public var dt: Double
    /// NF-Frequenz des untersten Tons
    public var freqHz: Double
    /// 0…1 (1 − Bitfehler/60); unter 0,17 zeigt JS8Call den Rahmen in Klammern
    public var quality: Double
    /// Inhalt, nil wenn der Rahmen zu keiner bekannten Art passt
    public var unpacked: JS8Unpacked?

    public static let uncertainBelow = 0.17

    public var isUncertain: Bool { quality < Self.uncertainBelow }

    public init(cycleStart: Date, submode: JS8Submode, frame: String, bits: JS8FrameBits, snrDB: Int, dt: Double, freqHz: Double, quality: Double) {
        self.cycleStart = cycleStart
        self.submode = submode
        self.frame = frame
        self.bits = bits
        self.snrDB = snrDB
        self.dt = dt
        self.freqHz = freqHz
        self.quality = quality
        unpacked = JS8Varicode.unpack(frame, bits: bits)
    }

    /// Text wie JS8Call ihn anzeigt (unbekannte Rahmen als Rohtext)
    public var text: String { unpacked?.text ?? frame }

    public static func == (a: JS8Decode, b: JS8Decode) -> Bool {
        a.cycleStart == b.cycleStart && a.frame == b.frame && a.freqHz == b.freqHz && a.submode == b.submode
    }
}

/// Swift-Hülle um den JS8-Decoder (`Vendor/JS8`, aus JS8Call): decodiert einen Zyklus einer Betriebsart.
public enum JS8Core {
    public static let sampleRate = 12_000

    public struct Settings: Equatable, Sendable, Codable {
        /// Suchbereich im NF
        public var minHz: Double = 200
        public var maxHz: Double = 3_500
        public init(minHz: Double = 200, maxHz: Double = 3_500) { self.minHz = minHz; self.maxHz = maxHz }
    }

    /// Decodiert einen Zyklus. `samples` beginnen beim Zyklusbeginn, 12 000 Hz, Vollaussteuerung = ±1.
    /// Der Decoder bevorzugt Signale nahe `preferHz`.
    public static func decode(_ samples: [Float], submode: JS8Submode, cycleStart: Date = Date(), settings: Settings = Settings(),
                              preferHz: Double = 1_500) -> [JS8Decode] {
        final class Box {
            var list: [JS8Decode] = []
            let start: Date
            let mode: JS8Submode
            init(_ s: Date, _ m: JS8Submode) { start = s; mode = m }
        }
        let box = Box(cycleStart, submode)
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        // Der Decoder rechnet mit der Skala von 16-Bit-Zahlen (daran hängen die S/N-Werte)
        let scaled = samples.map { $0 * 32_768 }
        scaled.withUnsafeBufferPointer { buf in
            _ = js8dd_decode_window(buf.baseAddress, Int32(buf.count), Int32(submode.rawValue),
                                    Int32(settings.minHz), Int32(settings.maxHz), Int32(preferHz), { ctx, d in
                guard let ctx, let d else { return }
                let b = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue()
                let frame = withUnsafeBytes(of: d.pointee.data) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                b.list.append(JS8Decode(cycleStart: b.start, submode: b.mode, frame: frame,
                                        bits: JS8FrameBits(rawValue: Int(d.pointee.frame_type)),
                                        snrDB: Int(d.pointee.snr), dt: Double(d.pointee.dt),
                                        freqHz: Double(d.pointee.freq_hz), quality: Double(d.pointee.quality)))
            }, ctx)
        }
        return box.list.sorted { $0.freqHz < $1.freqHz }
    }

    /// Testsignal (nur für Tests, Digidec sendet nie): ein Rahmen aus 12 Zeichen, unterster Ton bei `frequency`, Beginn mit der
    /// Startverzögerung der Betriebsart, `amplitude` in Einheiten von Vollaussteuerung = 1. Die Länge deckt einen ganzen Zyklus ab.
    public static func synthesize(frame: String, bits: JS8FrameBits = [.first, .last], submode: JS8Submode = .normal,
                                  frequency: Double = 1_000, amplitude: Double = 0.1) -> [Float]? {
        let total = Int(submode.periodSeconds) * sampleRate
        var out = [Float](repeating: 0, count: total)
        let n = out.withUnsafeMutableBufferPointer {
            js8dd_synthesize(Int32(bits.rawValue), Int32(submode.rawValue), frame, frequency, amplitude, $0.baseAddress, Int32($0.count))
        }
        return n > 0 ? out : nil
    }
}
