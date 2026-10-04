import Foundation

// Sendeseite von AIS für Tests und Prüfstände: Nachrichten bauen (Typen 1, 4, 5, 18, 21, 24) und als FM-Diskriminator-Audio
// ausgeben (GMSK, 9600 Bd, BT 0,4), wie es ein SDR-Programm hinter dem FM-Demodulator liefert.

/// Schreibt Felder in eine Bitfolge (MSB zuerst)
public struct AISBitWriter {
    public var bits: [UInt8] = []

    public init() {}

    public mutating func u(_ value: UInt32, _ length: Int) {
        for k in (0..<length).reversed() { bits.append(UInt8((value >> UInt32(k)) & 1)) }
    }

    public mutating func i(_ value: Int, _ length: Int) {
        let mask = length >= 32 ? UInt32.max : (UInt32(1) << UInt32(length)) - 1
        u(UInt32(truncatingIfNeeded: value) & mask, length)
    }

    public mutating func flag(_ on: Bool) { bits.append(on ? 1 : 0) }

    /// Text in 6-Bit-ASCII, mit „@“ auf `chars` Zeichen aufgefüllt
    public mutating func text(_ s: String, chars: Int) {
        let up = Array(s.uppercased().unicodeScalars.prefix(chars))
        for k in 0..<chars {
            var v: UInt32 = 0
            if k < up.count {
                let c = up[k].value
                v = c >= 64 ? c - 64 : c
                if v > 63 { v = 0 }
            }
            u(v, 6)
        }
    }

    public mutating func pad(to length: Int) {
        while bits.count < length { bits.append(0) }
    }
}

public enum AISSignalGenerator {
    // MARK: Nachrichten

    /// Nachricht 1: Positionsbericht Klasse A (168 Bit)
    public static func positionReport(mmsi: UInt32, lat: Double, lon: Double, sog: Double = 0, cog: Double = 0, heading: Int = 511,
                                      navStatus: Int = 0, second: Int = 0, type: Int = 1) -> [UInt8] {
        var w = AISBitWriter()
        w.u(UInt32(type), 6); w.u(0, 2); w.u(mmsi, 30)
        w.u(UInt32(navStatus), 4)
        w.i(-128, 8)                                      // Drehrate nicht verfügbar
        w.u(UInt32((sog * 10).rounded()), 10)
        w.flag(true)
        w.i(Int((lon * 600_000).rounded()), 28)
        w.i(Int((lat * 600_000).rounded()), 27)
        w.u(UInt32((cog * 10).rounded()), 12)
        w.u(UInt32(heading), 9)
        w.u(UInt32(second), 6)
        w.u(0, 2); w.u(0, 3); w.flag(false)
        w.pad(to: 168)
        return w.bits
    }

    /// Nachricht 5: Stamm- und Reisedaten (424 Bit)
    public static func staticVoyage(mmsi: UInt32, imo: UInt32, callsign: String, name: String, shipType: Int,
                                    bow: Int, stern: Int, port: Int, starboard: Int, draught: Double,
                                    destination: String, etaMonth: Int = 0, etaDay: Int = 0, etaHour: Int = 24, etaMinute: Int = 60) -> [UInt8] {
        var w = AISBitWriter()
        w.u(5, 6); w.u(0, 2); w.u(mmsi, 30); w.u(0, 2); w.u(imo, 30)
        w.text(callsign, chars: 7); w.text(name, chars: 20)
        w.u(UInt32(shipType), 8)
        w.u(UInt32(bow), 9); w.u(UInt32(stern), 9); w.u(UInt32(port), 6); w.u(UInt32(starboard), 6)
        w.u(1, 4)
        w.u(UInt32(etaMonth), 4); w.u(UInt32(etaDay), 5); w.u(UInt32(etaHour), 5); w.u(UInt32(etaMinute), 6)
        w.u(UInt32((draught * 10).rounded()), 8)
        w.text(destination, chars: 20)
        w.flag(false); w.flag(false)
        w.pad(to: 424)
        return w.bits
    }

    /// Nachricht 18: Positionsbericht Klasse B (168 Bit)
    public static func classBPosition(mmsi: UInt32, lat: Double, lon: Double, sog: Double = 0, cog: Double = 0, heading: Int = 511, second: Int = 0) -> [UInt8] {
        var w = AISBitWriter()
        w.u(18, 6); w.u(0, 2); w.u(mmsi, 30); w.u(0, 8)
        w.u(UInt32((sog * 10).rounded()), 10)
        w.flag(true)
        w.i(Int((lon * 600_000).rounded()), 28)
        w.i(Int((lat * 600_000).rounded()), 27)
        w.u(UInt32((cog * 10).rounded()), 12)
        w.u(UInt32(heading), 9)
        w.u(UInt32(second), 6)
        w.u(0, 2); w.flag(true); w.flag(true); w.flag(true); w.flag(false); w.flag(false); w.flag(false)
        w.pad(to: 168)
        return w.bits
    }

    /// Nachricht 24 Teil A: Name (160 Bit) und Teil B: Typ, Rufzeichen, Maße (168 Bit)
    public static func classBStaticA(mmsi: UInt32, name: String) -> [UInt8] {
        var w = AISBitWriter()
        w.u(24, 6); w.u(0, 2); w.u(mmsi, 30); w.u(0, 2); w.text(name, chars: 20)
        w.pad(to: 168)
        return w.bits
    }

    public static func classBStaticB(mmsi: UInt32, shipType: Int, callsign: String, bow: Int, stern: Int, port: Int, starboard: Int) -> [UInt8] {
        var w = AISBitWriter()
        w.u(24, 6); w.u(0, 2); w.u(mmsi, 30); w.u(1, 2)
        w.u(UInt32(shipType), 8); w.text("", chars: 3); w.u(0, 4); w.u(0, 20)
        w.text(callsign, chars: 7)
        w.u(UInt32(bow), 9); w.u(UInt32(stern), 9); w.u(UInt32(port), 6); w.u(UInt32(starboard), 6)
        w.pad(to: 168)
        return w.bits
    }

    /// Nachricht 21: Seezeichen (272 Bit)
    public static func aidToNavigation(mmsi: UInt32, type: Int, name: String, lat: Double, lon: Double) -> [UInt8] {
        var w = AISBitWriter()
        w.u(21, 6); w.u(0, 2); w.u(mmsi, 30); w.u(UInt32(type), 5); w.text(name, chars: 20)
        w.flag(true)
        w.i(Int((lon * 600_000).rounded()), 28)
        w.i(Int((lat * 600_000).rounded()), 27)
        w.u(0, 9); w.u(0, 9); w.u(0, 6); w.u(0, 6)
        w.u(1, 4); w.u(60, 6); w.flag(false); w.u(0, 8); w.flag(false); w.flag(false); w.flag(false); w.flag(false)
        w.pad(to: 272)
        return w.bits
    }

    /// Nachricht 4: Basisstation (168 Bit)
    public static func baseStation(mmsi: UInt32, lat: Double, lon: Double, year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> [UInt8] {
        var w = AISBitWriter()
        w.u(4, 6); w.u(0, 2); w.u(mmsi, 30)
        w.u(UInt32(year), 14); w.u(UInt32(month), 4); w.u(UInt32(day), 5); w.u(UInt32(hour), 5); w.u(UInt32(minute), 6); w.u(UInt32(second), 6)
        w.flag(true)
        w.i(Int((lon * 600_000).rounded()), 28)
        w.i(Int((lat * 600_000).rounded()), 27)
        w.u(1, 4); w.u(0, 10); w.flag(false)
        w.pad(to: 168)
        return w.bits
    }

    // MARK: Zufall

    public struct RNG {
        var state: UInt64
        public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

        public mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        public mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

        public mutating func gaussian() -> Double {
            let u1 = max(uniform(), 1e-12), u2 = uniform()
            return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }
    }

    // MARK: Audio

    /// Ein Burst im Signal
    public struct Burst {
        public var payload: [UInt8]
        /// Beginn des Trainings in Sekunden
        public var start: Double
        /// Gleichanteil (Frequenzablage des Senders) als Audiowert, zusätzlich zum allgemeinen
        public var offset: Float = 0
        /// Startpegel nach NRZI (+1/−1)
        public var polarity: Float = 1
        /// Taktabweichung des Senders in ppm
        public var ppm: Double = 0
        public var amplitude: Float = 1

        public init(payload: [UInt8], start: Double, offset: Float = 0, polarity: Float = 1, ppm: Double = 0, amplitude: Float = 1) {
            self.payload = payload; self.start = start; self.offset = offset; self.polarity = polarity; self.ppm = ppm; self.amplitude = amplitude
        }
    }

    /// FM-Diskriminator-Audio: `swing` ist der Audiowert für den vollen Hub (±2,4 kHz), `noise` die Rauschstärke (Effektivwert) im Audio
    public static func audio(bursts: [Burst], duration: Double, sampleRate: Double = 48_000, swing: Float = 0.3,
                             noise: Float = 0, seed: UInt64 = 1) -> [Float] {
        let n = Int(duration * sampleRate)
        var out = [Float](repeating: 0, count: n)
        for b in bursts {
            let wire = AISFraming.wireBits(payload: b.payload)
            let levels = [Float](repeating: 0, count: 4) + AISFraming.nrzi(wire, start: b.polarity) + [Float](repeating: 0, count: 6)
            let sps = sampleRate / AISPulse.baud * (1 + b.ppm * 1e-6)
            let first = Int((b.start * sampleRate).rounded(.down)) - Int(4 * sps)
            let phase = b.start * sampleRate - Double(first) - 4 * sps
            let count = Int(Double(levels.count) * sps) + 4
            let wave = AISPulse.render(levels: levels, samplesPerBit: sps, count: count, phase: -phase + 0)
            for k in 0..<count {
                let idx = first + k
                if idx >= 0 && idx < n { out[idx] += swing * b.amplitude * wave[k] + b.offset }
            }
        }
        if noise > 0 {
            var rng = RNG(seed: seed)
            for k in 0..<n { out[k] += noise * Float(rng.gaussian()) }
        }
        return out
    }
}
