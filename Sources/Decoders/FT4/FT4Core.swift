// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import FT8

/// Betriebsart des Moduls: FT4 oder das inoffizielle FT2. FT2 ist FT4 bei halber Symboldauer (gleiche Codierung, gleiche Sync-Folgen).
public enum FT4Mode: String, CaseIterable, Identifiable, Codable, Sendable {
    case ft4 = "FT4", ft2 = "FT2"

    public var id: String { rawValue }
    /// Zyklus in Sekunden (UTC-Raster)
    public var cycleSeconds: Double { self == .ft4 ? 7.5 : 3.75 }
    /// Symboldauer in Sekunden
    public var symbolPeriod: Double { self == .ft4 ? 0.048 : 0.024 }
    /// Tonabstand = Symbolrate in Hz (20,8333 / 41,6667)
    public var toneSpacing: Double { 1 / symbolPeriod }
    /// Belegte Bandbreite: vier Töne
    public var bandwidth: Double { 4 * toneSpacing }
    /// Sendebeginn nach Zyklusbeginn, auf den sich DT bezieht (FT4 laut WSJT-X 0,5 s; FT2 0,3 s wie Decodium)
    public var txDelay: Double { self == .ft4 ? 0.5 : 0.3 }
    /// Dauer der Aussendung (105 Symbole)
    public var transmitSeconds: Double { 105 * symbolPeriod }
    /// Sekunden nach Zyklusbeginn, zu denen decodiert wird
    public var decodeAt: Double { self == .ft4 ? 7.1 : 3.3 }
    /// Mindestens so viel Audio (Sekunden) muss vom Zyklus vorliegen
    public var minimumSeconds: Double { cycleSeconds * 2 / 3 }
    public var title: String { self == .ft4 ? "FT4" : "FT2 (experimentell)" }
}

/// Eine decodierte FT4-Meldung (7,5-s-Zyklus, 4-GFSK, 20,8333 Baud) oder FT2-Meldung (3,75-s-Zyklus, 41,6667 Baud)
public struct FT4Decode: Identifiable, Sendable, Equatable {
    public let id = UUID()
    /// Beginn des 7,5-s-Zyklus (UTC)
    public var cycleStart: Date
    public var text: String
    /// S/N in 2500 Hz wie WSJT-X
    public var snrDB: Int
    /// Zeitversatz nach Zyklusbeginn in Sekunden
    public var dt: Double
    /// NF-Frequenz des untersten Tons
    public var freqHz: Double
    /// Bits, die nach LDPC mit der Prüfsumme übereinstimmen (von 174)
    public var correctBits: Int
    /// Durchgang (> 0 falls Mehrfachdurchgang)
    public var pass: Int
    public var mode: FT4Mode = .ft4

    public static let uncertainBelow = 140

    public var message: FT8Message { FT8Message(text) }

    /// Wie WSJT-X „?“: unplausible Rufzeichen oder unsichere Decodierung
    public var isUncertain: Bool {
        correctBits < Self.uncertainBelow || !message.isPlausible
    }

    public static func == (a: FT4Decode, b: FT4Decode) -> Bool {
        a.cycleStart == b.cycleStart && a.text == b.text && a.snrDB == b.snrDB && a.freqHz == b.freqHz && a.mode == b.mode
    }
}

/// Swift-Hülle um den FT4-Decoder (`Vendor/FT8`): decodiert einen 7,5-s-Zyklus (FT2: 3,75 s).
public enum FT4Core {
    public static let sampleRate = 12_000.0
    public static let cycleSeconds = 7.5

    public struct Settings: Equatable, Sendable, Codable {
        public var minHz = 150.0
        public var maxHz = 3600.0
        public init() {}
    }

    /// Decodiert einen Zyklus. `samples` beginnen beim Zyklusbeginn (FT4: Sekunde 0.0, 7.5, 15.0 …; FT2: 0.0, 3.75, 7.5 …).
    public static func decode(_ samples: [Float], rate: Int = 12_000, cycleStart: Date = Date(),
                              settings: Settings = Settings(), mode: FT4Mode = .ft4) -> [FT4Decode] {
        final class Box { var list: [FT4Decode] = []; let start: Date; let mode: FT4Mode; init(_ s: Date, _ m: FT4Mode) { start = s; mode = m } }
        let box = Box(cycleStart, mode)
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        let decodeFn = mode == .ft2 ? ft2dd_decode_cycle : ft4dd_decode_cycle
        samples.withUnsafeBufferPointer { buf in
            _ = decodeFn(buf.baseAddress, Int32(buf.count), Int32(rate), settings.minHz, settings.maxHz, { ctx, d in
                guard let ctx, let d else { return }
                let b = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue()
                let text = withUnsafeBytes(of: d.pointee.text) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                let clean = text.split(separator: " ").joined(separator: " ")
                if clean.contains("i3=") { return }
                b.list.append(FT4Decode(cycleStart: b.start, text: clean, snrDB: Int(d.pointee.snr_db.rounded()),
                                        dt: d.pointee.dt, freqHz: d.pointee.freq_hz,
                                        correctBits: Int(d.pointee.correct_bits), pass: Int(d.pointee.pass), mode: b.mode))
            }, ctx)
        }
        return box.list.sorted { $0.freqHz < $1.freqHz }
    }

    /// FT4-Testsignal (nur für Tests, Digidec sendet nie): Klartext, unterster Ton bei `frequency`, Amplitude 1
    public static func synthesize(_ text: String, frequency: Double, rate: Int = 12_000, mode: FT4Mode = .ft4) -> [Float]? {
        var out = [Float](repeating: 0, count: rate * 8)
        let n = out.withUnsafeMutableBufferPointer { mode == .ft2 ? ft2dd_synthesize(text, frequency, Int32(rate), $0.baseAddress, Int32($0.count)) : ft4dd_synthesize(text, frequency, Int32(rate), $0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return nil }
        return Array(out.prefix(Int(n)))
    }

    /// Zyklus mit mehreren Signalen: (Text, Frequenz, Startzeit nach Zyklusbeginn, Amplitude)
    public static func cycle(_ signals: [(text: String, hz: Double, start: Double, amplitude: Double)],
                             rate: Int = 12_000, mode: FT4Mode = .ft4) -> [Float] {
        var out = [Float](repeating: 0, count: Int(mode.cycleSeconds * Double(rate)))
        for s in signals {
            guard let wave = synthesize(s.text, frequency: s.hz, rate: rate, mode: mode) else { continue }
            let i0 = Int(s.start * Double(rate))
            for (k, v) in wave.enumerated() where i0 + k >= 0 && i0 + k < out.count {
                out[i0 + k] += Float(s.amplitude) * v
            }
        }
        return out
    }
}
