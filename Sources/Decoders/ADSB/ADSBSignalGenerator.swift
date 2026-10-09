// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Erzeugt Mode-S-/ADS-B-Meldungen und daraus 8-Bit-I/Q-Daten bei 2 MS/s für Tests und den Demo-Prüfstand (`Tools/MakeSignal`).
/// Alle Flugzeuge sind erfunden.
public enum ADSBSignalGenerator {
    // MARK: Meldungen

    /// Lange Meldung (14 Byte) mit gültiger Prüfsumme: DF, Fähigkeit, Adresse, 7 Byte Inhalt
    public static func extendedSquitter(icao: UInt32, me: [UInt8], df: Int = 17, ca: Int = 5) -> [UInt8] {
        var b: [UInt8] = [UInt8(df << 3 | ca), UInt8((icao >> 16) & 0xFF), UInt8((icao >> 8) & 0xFF), UInt8(icao & 0xFF)] + me
        let crc = parity(b)
        b += [UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
        return b
    }

    /// Kurze Meldung mit reiner Parität: Sammelantwort DF 11 (Interrogator 0)
    public static func allCallReply(icao: UInt32, ca: Int = 5) -> [UInt8] {
        var b: [UInt8] = [UInt8(11 << 3 | ca), UInt8((icao >> 16) & 0xFF), UInt8((icao >> 8) & 0xFF), UInt8(icao & 0xFF)]
        let crc = parity(b)
        b += [UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
        return b
    }

    /// Höhenantwort DF 4 (Adresse in der Parität überlagert): 13-Bit-Höhenfeld mit 25-Fuß-Codierung
    public static func altitudeReply(icao: UInt32, altitudeFt: Int, flightStatus: Int = 0) -> [UInt8] {
        let n = max(0, min(2047, (altitudeFt + 1000) / 25))
        // AC13: C1 A1 C2 A2 C4 A4 M B1 Q B2 D2 B4 D4: N ohne Q-Bit und M-Bit verteilt (Umkehrung von `altitudeAC13`)
        let high = (n >> 6) & 0x1F, bit7 = (n >> 5) & 1, bit5 = (n >> 4) & 1, low = n & 0xF
        var b: [UInt8] = [UInt8(4 << 3 | flightStatus), 0, UInt8(high), UInt8(bit7 << 7 | bit5 << 5 | 1 << 4 | low)]
        b[1] = 0
        let crc = parity(b)           // CRC der Datenbits
        let addr = icao & 0xFFFFFF
        let ap = crc ^ addr
        b += [UInt8((ap >> 16) & 0xFF), UInt8((ap >> 8) & 0xFF), UInt8(ap & 0xFF)]
        return b
    }

    /// Prüfsumme (CRC-24) über die Datenbytes
    static func parity(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0
        for b in data { c = ((c << 8) & 0xFFFFFF) ^ ModeSCRC.table[Int((c >> 16) ^ UInt32(b)) & 0xFF] }
        return c
    }

    // MARK: Inhalt (ME)

    private static let charset = Array("#ABCDEFGHIJKLMNOPQRSTUVWXYZ#####_###############0123456789######")

    public static func identification(callsign: String, category: Int = 0, typeCode: Int = 4) -> [UInt8] {
        var bits: UInt64 = 0
        let padded = Array(callsign.uppercased().padding(toLength: 8, withPad: " ", startingAt: 0))
        for ch in padded {
            let c = ch == " " ? "_" : ch
            let idx = charset.firstIndex(of: c) ?? 0
            bits = bits << 6 | UInt64(idx)
        }
        var me: [UInt8] = [UInt8(typeCode << 3 | category)]
        for k in 0..<6 { me.append(UInt8((bits >> UInt64(40 - 8 * k)) & 0xFF)) }
        return me
    }

    /// CPR-Rohwerte (17 Bit) einer Position für den geraden oder ungeraden Rahmen
    public static func cpr(lat: Double, lon: Double, odd: Bool, surface: Bool = false) -> (lat: Int, lon: Int) {
        let span = surface ? 90.0 : 360.0
        func mod(_ a: Double, _ b: Double) -> Double { let r = a.truncatingRemainder(dividingBy: b); return r < 0 ? r + b : r }
        let dlat = span / (odd ? 59 : 60)
        let yz = Int(floor(131072 * (mod(lat, dlat) / dlat) + 0.5))
        let rlat = dlat * (Double(yz) / 131072 + floor(lat / dlat))
        let ni = max(ADSBCPR.nl(rlat) - (odd ? 1 : 0), 1)
        let dlon = span / Double(ni)
        let xz = Int(floor(131072 * (mod(lon, dlon) / dlon) + 0.5))
        return (yz & 0x1FFFF, xz & 0x1FFFF)
    }

    public static func airbornePosition(altitudeFt: Int, lat: Double, lon: Double, odd: Bool, typeCode: Int = 11) -> [UInt8] {
        let n = max(0, min(2047, (altitudeFt + 1000) / 25))
        let c = cpr(lat: lat, lon: lon, odd: odd)
        return [UInt8(typeCode << 3),
                UInt8(((n >> 4) << 1) | 1),
                UInt8(((n & 0xF) << 4) | (odd ? 0x04 : 0) | ((c.lat >> 15) & 3)),
                UInt8((c.lat >> 7) & 0xFF),
                UInt8(((c.lat & 0x7F) << 1) | ((c.lon >> 16) & 1)),
                UInt8((c.lon >> 8) & 0xFF),
                UInt8(c.lon & 0xFF)]
    }

    /// Geschwindigkeit (Typ 19, Untertyp 1) aus Ost- und Nordanteil in Knoten und Steigrate in ft/min
    public static func velocity(eastKn: Double, northKn: Double, climbFpm: Int = 0) -> [UInt8] {
        func field(_ v: Double) -> (sign: Int, value: Int) { (v < 0 ? 1 : 0, min(1023, Int(abs(v).rounded()) + 1)) }
        let ew = field(eastKn), ns = field(northKn)
        let vr = min(511, abs(climbFpm) / 64 + 1)
        return [UInt8(19 << 3 | 1),
                UInt8(ew.sign << 2 | (ew.value >> 8)),
                UInt8(ew.value & 0xFF),
                UInt8(ns.sign << 7 | (ns.value >> 3)),
                UInt8(((ns.value & 7) << 5) | ((climbFpm < 0 ? 1 : 0) << 3) | (vr >> 6)),
                UInt8((vr & 0x3F) << 2),
                0]
    }

    /// Statusmeldung (Typ 28, Untertyp 1): Notlage und Kennung (vierstellig, Oktalziffern)
    public static func emergencyStatus(emergency: Int, squawk: String) -> [UInt8] {
        let d = squawk.compactMap { Int(String($0)) }
        guard d.count == 4 else { return [UInt8(28 << 3 | 1), 0, 0, 0, 0, 0, 0] }
        // ID13: C1 A1 C2 A2 C4 A4 X B1 D1 B2 D2 B4 D4
        let a = d[0], b = d[1], c = d[2], dd = d[3]
        func bit(_ v: Int, _ k: Int) -> Int { (v >> k) & 1 }
        let id = bit(c, 0) << 12 | bit(a, 0) << 11 | bit(c, 1) << 10 | bit(a, 1) << 9 | bit(c, 2) << 8 | bit(a, 2) << 7
            | bit(b, 0) << 5 | bit(dd, 0) << 4 | bit(b, 1) << 3 | bit(dd, 1) << 2 | bit(b, 2) << 1 | bit(dd, 2)
        return [UInt8(28 << 3 | 1), UInt8(emergency << 5 | ((id >> 8) & 0x1F)), UInt8(id & 0xFF), 0, 0, 0, 0]
    }

    // MARK: Signal

    public struct Burst: Sendable {
        public var startSample: Int
        public var bytes: [UInt8]
        /// Spitzenwert der Auslenkung (Mittelpunkt 127 ± amplitude), höchstens 120
        public var amplitude: Double
        public var phase: Double
        public init(startSample: Int, bytes: [UInt8], amplitude: Double = 60, phase: Double = 0) {
            self.startSample = startSample
            self.bytes = bytes
            self.amplitude = amplitude
            self.phase = phase
        }
    }

    /// 8-Bit-I/Q-Daten (abwechselnd I, Q, vorzeichenlos, Mittelpunkt 127.5 gerundet) mit Rauschen (Standardabweichung in Stufen)
    public static func samples(bursts: [Burst], totalSamples: Int, noise: Double = 1.5, seed: UInt64 = 1) -> [UInt8] {
        var rng = SplitMix(seed: seed)
        var out = [UInt8](repeating: 127, count: totalSamples * 2)
        if noise > 0 {
            for i in 0..<totalSamples {
                out[2 * i] = clamp(127 + gaussian(&rng) * noise)
                out[2 * i + 1] = clamp(127 + gaussian(&rng) * noise)
            }
        }
        for b in bursts {
            let n = b.bytes.count * 8
            var level = [Double](repeating: 0, count: 16 + n * 2)
            for s in [0, 2, 7, 9] { level[s] = 1 }
            for k in 0..<n {
                let bit = (b.bytes[k / 8] >> UInt8(7 - k % 8)) & 1
                level[16 + 2 * k + (bit == 1 ? 0 : 1)] = 1
            }
            for (j, l) in level.enumerated() where l > 0 {
                let idx = b.startSample + j
                guard idx >= 0, idx < totalSamples else { continue }
                // Beitrag zum vorhandenen Rauschen addieren
                let di = b.amplitude * cos(b.phase), dq = b.amplitude * sin(b.phase)
                out[2 * idx] = clamp(Double(out[2 * idx]) + di)
                out[2 * idx + 1] = clamp(Double(out[2 * idx + 1]) + dq)
            }
        }
        return out
    }

    private static func clamp(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    private static func gaussian(_ r: inout SplitMix) -> Double {
        let u1 = max(r.unit(), 1e-12), u2 = r.unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    // MARK: Demo

    public struct SimAircraft: Sendable {
        public var icao: UInt32
        public var callsign: String
        public var lat: Double
        public var lon: Double
        public var altitudeFt: Int
        /// Kurs in Grad und Geschwindigkeit in Knoten
        public var trackDeg: Double
        public var speedKn: Double
        public var climbFpm = 0
        public var emergency = false
        public init(icao: UInt32, callsign: String, lat: Double, lon: Double, altitudeFt: Int, trackDeg: Double, speedKn: Double, climbFpm: Int = 0, emergency: Bool = false) {
            self.icao = icao; self.callsign = callsign; self.lat = lat; self.lon = lon; self.altitudeFt = altitudeFt
            self.trackDeg = trackDeg; self.speedKn = speedKn; self.climbFpm = climbFpm; self.emergency = emergency
        }
    }

    /// Verkehr über `seconds` Sekunden: je Flugzeug alle 0,5 s eine Position (gerade/ungerade im Wechsel), alle 2 s Geschwindigkeit, alle 5 s Kennung,
    /// jede Sekunde eine Sammelantwort; Pegel nimmt mit der Entfernung zum Empfänger ab. Rückgabe: I/Q-Daten und Anzahl der Meldungen.
    public static func traffic(_ fleet: [SimAircraft], receiver: (lat: Double, lon: Double), seconds: Double, seed: UInt64 = 7) -> (iq: [UInt8], messages: Int) {
        var rng = SplitMix(seed: seed)
        let rate = 2_000_000.0
        let total = Int(seconds * rate)
        var bursts: [Burst] = []
        var planes = fleet
        var occupied = Set<Int>()           // belegte 128-µs-Fenster, damit sich Meldungen nicht überlagern
        func place(_ time: Double, _ bytes: [UInt8], _ p: SimAircraft) {
            let km = Geo.distanceKm(GeoPoint(lat: receiver.lat, lon: receiver.lon), GeoPoint(lat: p.lat, lon: p.lon))
            // Freiraumdämpfung: 110 Stufen bei 5 km, etwa 20 Stufen bei 350 km
            let amp = max(12, min(115, 110 * 5 / max(km, 5) + 12))
            var start = Int(time * rate)
            var tries = 0
            while tries < 40 {
                let slot = start / 260
                if !occupied.contains(slot) && !occupied.contains(slot + 1) && start + 16 + bytes.count * 16 < total { occupied.insert(slot); occupied.insert(slot + 1); break }
                start += 260
                tries += 1
            }
            guard start + 16 + bytes.count * 16 < total, tries < 40 else { return }
            bursts.append(Burst(startSample: start, bytes: bytes, amplitude: amp, phase: rng.unit() * 2 * .pi))
        }
        var count = 0
        var t = 0.0
        let dt = 0.05
        var tick = 0
        while t < seconds - 0.2 {
            for i in planes.indices {
                var p = planes[i]
                let jitter = Double(i) * 0.0037
                if tick % 10 == i % 10 {                                   // alle 0,5 s
                    let odd = (tick / 10 + i) % 2 == 1
                    place(t + jitter, extendedSquitter(icao: p.icao, me: airbornePosition(altitudeFt: p.altitudeFt, lat: p.lat, lon: p.lon, odd: odd)), p)
                    count += 1
                }
                if tick % 40 == (i * 3) % 40 {                             // alle 2 s
                    let r = p.trackDeg * .pi / 180
                    place(t + jitter, extendedSquitter(icao: p.icao, me: velocity(eastKn: p.speedKn * sin(r), northKn: p.speedKn * cos(r), climbFpm: p.climbFpm)), p)
                    count += 1
                }
                if tick % 100 == (i * 7) % 100 {                           // alle 5 s
                    place(t + jitter, extendedSquitter(icao: p.icao, me: identification(callsign: p.callsign, category: 5)), p)
                    count += 1
                    if p.emergency {
                        place(t + jitter + 0.01, extendedSquitter(icao: p.icao, me: emergencyStatus(emergency: 1, squawk: "7700")), p)
                        count += 1
                    }
                }
                if tick % 20 == (i * 11) % 20 {                            // jede Sekunde
                    place(t + jitter, allCallReply(icao: p.icao), p)
                    count += 1
                }
                // Weiterbewegen (ebene Näherung)
                let dist = p.speedKn * 1.852 / 3600 * dt            // km
                let r = p.trackDeg * .pi / 180
                p.lat += dist * cos(r) / 111.2
                p.lon += dist * sin(r) / (111.2 * cos(p.lat * .pi / 180))
                p.altitudeFt += Int(Double(p.climbFpm) * dt / 60)
                planes[i] = p
            }
            t += dt
            tick += 1
        }
        return (samples(bursts: bursts, totalSamples: total, noise: 1.5, seed: seed), count)
    }
}
