// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Meteomodem M10 und Meteosis M20: 9600 Symbole/s (Manchester, differenziell codiert, also 4800 Bit/s), GFSK, ein Rahmen je Sekunde.
// Rahmenaufbau, Prüfsumme und Formeln nach m10m20mod von zilog80 (radiosonde_auto_rx, GPL-3.0), siehe Vendor/Sonde/UPSTREAM_SONDE.md.
//
// Ein Rahmen beginnt (nach dem Synchronkopf) mit der Länge und der Typkennung: M10 `64 9F` (mit Trimble-GPS), `66 9F`, `64 AF` (mit Gtop-GPS),
// `64 49` (Doppelrahmen alle 10 s), M20 `45 20`. Am Ende steht eine 16-Bit-Prüfsumme. Je Byte kommt eine Größe vor: GPS-Daten (Big Endian), Messwerte (Little Endian).

enum M10Frame {
    static let symbolRate = 9600.0
    /// Synchronkopf als Rohsymbole (+1 / −1), 16 Bit
    static let headerSymbols: [Float] = Array("10011001100110010100110010011001").map { $0 == "1" ? 1 : -1 }
    static let m10Length = 0x64
    static let m20Length = 0x45
    static let auxLength = 64
    /// Längster Rahmen (Standardlänge plus Zusatzdaten) in Bytes
    static let maxBytes = m10Length + 1 + auxLength
    static let maxSymbols = maxBytes * 16

    enum Kind: UInt8 {
        case m2k2 = 0x8F, m10 = 0x9F, m10dub = 0x49, m10plus = 0xAF, m20 = 0x20
        var isM10Family: Bool { self != .m20 }
    }

    /// Weiche Manchester-Symbole → Bytes. Das Signal ist differenziell codiert: Bit = nicht (m ⊕ m_vorher). Das letzte Paar des Kopfes zählt als m = 1.
    static func bytes(fromSymbols s: [Float], count: Int? = nil) -> [UInt8] {
        let bitCount = (count ?? s.count / 16) * 8
        var out = [UInt8](repeating: 0, count: bitCount / 8)
        var previous: UInt8 = 1
        for i in 0..<min(bitCount, s.count / 2) {
            let m: UInt8 = s[2 * i + 1] >= s[2 * i] ? 1 : 0
            let bit: UInt8 = 1 - (m ^ previous)
            previous = m
            out[i / 8] |= bit << UInt8(7 - i % 8)
        }
        return out
    }

    // MARK: Prüfsumme

    static func updateCheck(_ c: Int, _ byte: UInt8) -> Int {
        var b = byte
        let c1 = c & 0xFF
        b = (b >> 1) | ((b & 1) << 7)
        b ^= (b >> 2) & 0xFF
        let t6 = (c & 1) ^ ((c >> 2) & 1) ^ ((c >> 4) & 1)
        let t7 = ((c >> 1) & 1) ^ ((c >> 3) & 1) ^ ((c >> 5) & 1)
        let t = (c & 0x3F) | (t6 << 6) | (t7 << 7)
        var s = (c >> 7) & 0xFF
        s ^= (s >> 2) & 0xFF
        let c0 = Int(b) ^ t ^ s
        return ((c1 << 8) | c0) & 0xFFFF
    }

    /// Prüfsumme über die ersten `count` Bytes
    static func check(_ msg: [UInt8], count: Int) -> Int {
        var cs = 0
        for i in 0..<count { cs = updateCheck(cs, msg[i]) }
        return cs & 0xFFFF
    }

    /// Prüfsumme des ersten Blocks (M20 mit Firmware unter 7): `len` zählt Block samt Prüfsumme
    static func blockCheck(length len: Int, _ msg: ArraySlice<UInt8>) -> Int {
        var cs = updateCheck(0, UInt8(len & 0xFF))
        let base = msg.startIndex
        for i in 0..<(len - 2) { cs = updateCheck(cs, msg[base + i]) }
        return cs & 0xFFFF
    }
}

// MARK: - Auswertung eines Rahmens

struct M10Parser {
    let bytes: [UInt8]
    let kind: M10Frame.Kind
    let length: Int
    var firmware = 0

    init(bytes: [UInt8], kind: M10Frame.Kind, length: Int) {
        self.bytes = bytes
        self.kind = kind
        self.length = length
        if kind == .m20 {
            let fw = Int(bytes[0x43])
            firmware = fw > 0x20 ? 0 : fw
        }
    }

    private func be(_ pos: Int, _ count: Int) -> Int {
        var v = 0
        for i in 0..<count { v = (v << 8) | Int(bytes[pos + i]) }
        return v
    }
    private func signed32(_ pos: Int) -> Int { Int(Int32(truncatingIfNeeded: be(pos, 4))) }
    private func signed16(_ pos: Int) -> Double { Double(Int16(truncatingIfNeeded: be(pos, 2))) }
    private func le16(_ pos: Int) -> Int { Int(bytes[pos]) | Int(bytes[pos + 1]) << 8 }

    private var isM20: Bool { kind == .m20 }

    // MARK: Zeit und Ort

    struct GPS {
        var week = 0
        var seconds = 0       // Sekunde der Woche
        var milliseconds = 0
        var utcOffset = 0
        var satellites: Int?
        var latitude = 0.0, longitude = 0.0, altitude = 0.0
        var speed = 0.0, heading = 0.0, climb = 0.0
        /// Zeit direkt als UTC (Gtop-GPS), sonst nil
        var utcDate: Date?
    }

    /// GPS-Daten oder nil, wenn Woche oder Zeit nicht plausibel sind
    func gps() -> GPS? {
        guard length > 0x24 else { return nil }
        var g = GPS()
        if kind == .m10plus { return gtop() }
        let towSeconds: Int
        if isM20 {
            towSeconds = be(0x0F, 3)
        } else {
            let ms = be(0x0A, 4)
            towSeconds = ms / 1000
            g.milliseconds = ms % 1000
            g.satellites = Int(bytes[0x1E])
            g.utcOffset = Int(bytes[0x1F])
        }
        guard towSeconds / 86_400 <= 6 else { return nil }
        var week = be(isM20 ? 0x1A : 0x20, 2)
        guard week <= 4000 else { return nil }
        if week < 1304 { week += 1024 }   // Überlauf der Wochenzählung (Trimble Copernicus II)
        g.week = week
        g.seconds = towSeconds
        if isM20 { g.utcOffset = 18 }

        let scale = isM20 ? 1e6 : Double(1 << 30) / 90
        g.latitude = Double(signed32(isM20 ? 0x1C : 0x0E)) / scale
        g.longitude = Double(signed32(isM20 ? 0x20 : 0x12)) / scale
        g.altitude = isM20 ? Double(be(0x08, 3)) / 100 : Double(signed32(0x16)) / 1000

        let vs = isM20 ? 100.0 : 200.0
        let vx = signed16(isM20 ? 0x0B : 0x04) / vs
        let vy = signed16(isM20 ? 0x0D : 0x06) / vs
        g.speed = (vx * vx + vy * vy).squareRoot()
        var dir = atan2(vx, vy) * 180 / .pi
        if dir < 0 { dir += 360 }
        g.heading = dir
        g.climb = signed16(isM20 ? 0x18 : 0x08) / vs
        return g
    }

    /// M10 mit Gtop-GPS: Ort in 1e-6°, Zeit und Datum als Dezimalzahlen
    private func gtop() -> GPS? {
        var g = GPS()
        g.latitude = Double(signed32(0x04)) / 1e6
        g.longitude = Double(signed32(0x08)) / 1e6
        var alt = be(0x0C, 3)
        if alt & 0x800000 != 0 { alt -= 0x1000000 }
        g.altitude = Double(alt) / 100
        let vx = signed16(0x0F) / 100, vy = signed16(0x11) / 100
        g.speed = (vx * vx + vy * vy).squareRoot()
        var dir = atan2(vx, vy) * 180 / .pi
        if dir < 0 { dir += 360 }
        g.heading = dir
        g.climb = signed16(0x13) / 100
        let time = be(0x15, 3), date = be(0x18, 3)
        let hh = time / 10_000, mm = (time % 10_000) / 100, ss = time % 100
        let year = 2000 + date % 100, month = (date % 10_000) / 100, day = date / 10_000
        guard hh < 24, mm < 60, ss < 61, (1...12).contains(month), (1...31).contains(day) else { return nil }
        let days = DFMDecoder.secondsSince1980(year: year, month: month, day: day, hour: hh, minute: mm, second: ss)
        g.utcDate = Date(timeIntervalSince1970: TimeInterval(days) + 315_964_800)
        return g
    }

    // MARK: Seriennummer

    var serial: String {
        if isM20 {
            let sn = Int(bytes[0x12]) | Int(bytes[0x13]) << 8 | Int(bytes[0x14]) << 16
            if sn == 0 { return "000-0-00000" }
            let ym = sn & 0x7F
            return String(format: "%d%02d-%d-%d%04d", ym / 12, ym % 12 + 1, ((sn >> 7) & 7) + 1, (sn >> 23) & 1, (sn >> 10) & 0x1FFF)
        }
        let raw = (0..<5).map { Int(bytes[0x5D + $0]) }
        let first = String(format: "%X%02d", (raw[2] >> 4) & 0xF, raw[2] & 0xF)
        let word = raw[3] | raw[4] << 8
        return first + String(format: "-%X-%d%04d", raw[0] & 0xF, (word >> 13) & 7, word & 0x1FFF)
    }

    // MARK: Messwerte

    /// Temperatur des Hauptfühlers in °C (NTC, Steinhart-Hart), nil wenn unplausibel
    func temperature() -> Double? {
        let p0 = 1.07303516e-03, p1 = 2.41296733e-04, p2 = 2.26744154e-06, p3 = 6.52855181e-08
        let rs = [12.1e3, 36.5e3, 475.0e3], rp = [1e20, 330.0e3, 2000.0e3]
        var scale = 0
        var adc = 0
        if isM20 {
            adc = le16(0x04)
            if adc > 8191 { scale = 2; adc -= 8192 } else if adc > 4095 { scale = 1; adc -= 4096 }
        } else {
            scale = Int(bytes[0x3E])
            adc = (le16(0x3F) - 0xA000) & 0xFFFF
        }
        guard adc > 0, scale < 3 else { return nil }
        let x = (4095.0 - Double(adc)) / Double(adc)
        let denom = x - rs[scale] / rp[scale]
        guard denom != 0 else { return nil }
        let r = rs[scale] / denom
        guard r > 0 else { return nil }
        let l = log(r)
        let t = 1 / (p0 + p1 * l + p2 * l * l + p3 * l * l * l) - 273.15
        return t < -120 || t > 60 ? nil : t
    }

    /// Temperatur des Feuchtesensors in °C
    func humiditySensorTemperature() -> Double? {
        let rs = 22.1e3
        if isM20 {
            let adc = Double(le16(0x06))
            guard adc > 0 else { return nil }
            let r = rs / ((4095 - adc) / adc)
            guard r > 0 else { return nil }
            return 1 / (1 / 298.15 + 1 / 3650 * log(r / 2.2e3)) - 273.15
        }
        let p0 = 4.42606809e-03, p1 = -6.58184309e-04, p2 = 8.95735557e-05, p3 = -2.84347503e-06
        let adc = Double(le16(0x59))
        guard adc > 0 else { return nil }
        let r = rs / ((4095 - adc) / adc)
        guard r > 0 else { return nil }
        let l = log(r)
        return 1 / (p0 + p1 * l + p2 * l * l + p3 * l * l * l) - 273.15
    }

    /// Relative Luftfeuchte in %
    func humidity(temperature: Double?) -> Double? {
        if isM20 {
            let humval = Double(le16(0x02))
            let rhCal = Double(le16(0x2F))
            guard let tu = humiditySensorTemperature(), humval < 48_000 else { return nil }
            let cal = 6.4e8 / (rhCal + 80_000)
            var x = (humval + 80_000) * cal * (1 - 5.8e-4 * (tu - 25))
            guard x != 0 else { return nil }
            x = 4.16e9 / x
            x = 10.087 * x * x * x - 211.62 * x * x + 1388.2 * x - 2797.0
            guard x > -20, x < 120 else { return nil }
            return min(100, max(0, x))
        }
        let ref = Double(Int(bytes[0x32]) | Int(bytes[0x33]) << 8 | Int(bytes[0x34]) << 16) / 1000
        let count = Double(Int(bytes[0x35]) | Int(bytes[0x36]) << 8 | Int(bytes[0x37]) << 16) / 1000
        guard ref > 0, count > 0, let t = temperature else { return nil }
        var rh = (count / ref - 0.8955) / 0.002
        if t < 0 { rh += 0 - t / 5.5 }
        if t < -30 { rh *= 1 + (-30 - t) / 75 }
        return min(100, max(0, rh))
    }

    /// Luftdruck in hPa (nur M20 mit Drucksensor)
    func pressure() -> Double? {
        guard isM20 else { return nil }
        var v = (Int(bytes[0x25]) << 8) | Int(bytes[0x24])
        let p0 = firmware >= 7 ? Int(bytes[0x16]) : 0
        v = (v << 8) | p0
        guard v > 0 else { return nil }
        let hPa = Double(v) / Double(16 * 256)
        return hPa > 2560 ? nil : hPa
    }

    var battery: Double {
        isM20 ? Double(bytes[0x26]) * (3.3 / 255) : 2.709 * Double(le16(0x45)) * 2.5 / 1023
    }
}

// MARK: - Empfänger

/// Sondenempfänger für Meteomodem M10 und Meteosis M20 (9600 Bd) aus FM-Audio
public final class M10Receiver: SondeReceiving {
    public var onTelemetry: ((SondeTelemetry) -> Void)?
    public private(set) var stats = SondeStats()
    public var level: Double { Double(demod.level) }
    public let sampleRate: Double

    private let demod: SymbolBurstDemodulator

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        demod = SymbolBurstDemodulator(sampleRate: sampleRate, symbolRate: M10Frame.symbolRate, header: M10Frame.headerSymbols,
                                       bodySymbols: M10Frame.maxSymbols, threshold: 0.75, tolerance: 0.02, earlyCount: 32)
        demod.earlyCheck = { symbols in
            let b = M10Frame.bytes(fromSymbols: symbols, count: 2)
            return M10Frame.Kind(rawValue: b[1]) != nil && (0x40...0xA6).contains(Int(b[0]))
        }
        demod.onBurst = { [unowned self] burst in self.accept(burst) }
    }

    public func reset() {
        demod.reset()
        stats = SondeStats()
    }

    public func resetStats() { stats = SondeStats() }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        demod.process(samples)
    }

    private func accept(_ burst: SymbolBurstDemodulator.Burst) {
        let bytes = M10Frame.bytes(fromSymbols: burst.symbols)
        guard let kind = M10Frame.Kind(rawValue: bytes[1]) else { return }
        let standard = kind == .m20 ? M10Frame.m20Length : M10Frame.m10Length
        var length = Int(bytes[0])
        if length - standard > M10Frame.auxLength { length = standard + M10Frame.auxLength }
        guard length >= 0x20, length + 1 <= bytes.count else { stats.failed += 1; return }
        let checkPosition = length - 1
        let found = Int(bytes[checkPosition]) << 8 | Int(bytes[checkPosition + 1])
        guard M10Frame.check(bytes, count: checkPosition) == found else {
            stats.headers += 1
            stats.failed += 1
            return
        }
        stats.headers += 1
        stats.frames += 1
        stats.lastFrameTime = burst.time
        // Doppelrahmen (alle 10 s) tragen Signalpegel der Satelliten, keine Position
        guard kind != .m10dub else { return }

        let parser = M10Parser(bytes: bytes, kind: kind, length: length)
        guard let gps = parser.gps() else { return }
        var t = SondeTelemetry(serial: (kind == .m20 ? "M20-" : "M10-") + parser.serial, frame: 0)
        t.model = kind == .m20 ? "M20" : kind == .m10plus ? "M10+" : "M10"
        t.frame = gps.utcDate == nil ? gps.week * 604_800 + gps.seconds : Int(gps.utcDate!.timeIntervalSince1970)
        if let d = gps.utcDate {
            t.time = d
        } else {
            let unix = Double(gps.week * 604_800 + gps.seconds - gps.utcOffset) + 315_964_800 + Double(gps.milliseconds) / 1000
            t.time = Date(timeIntervalSince1970: unix)
        }
        // Ohne GPS-Lösung sendet die Sonde Platzhalter (M10: 90° Nord, 0° Ost, 150 m): keine Position
        let fix = (gps.satellites ?? 4) >= 4 && abs(gps.latitude) < 89.999 && !(gps.latitude == 0 && gps.longitude == 0)
            && abs(gps.longitude) <= 180 && gps.altitude > -1000 && gps.altitude < 60_000
        if fix {
            t.latitude = gps.latitude
            t.longitude = gps.longitude
            t.altitude = gps.altitude
            t.speed = gps.speed
            t.heading = gps.heading
            t.climb = gps.climb
        }
        t.satellites = gps.satellites
        t.battery = parser.battery
        if kind != .m10plus {
            let temp = parser.temperature()
            t.temperature = temp
            t.humidity = parser.humidity(temperature: temp)
            t.pressure = parser.pressure()
        }
        onTelemetry?(t)
    }
}
