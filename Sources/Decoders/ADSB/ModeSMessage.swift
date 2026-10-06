// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - Prüfsumme

/// Die 24-Bit-Prüfsumme von Mode S (Polynom 0xFFF409, ohne Spiegelung, Anfangswert 0)
public enum ModeSCRC {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i) << 16
        for _ in 0..<8 { c = c & 0x800000 != 0 ? (c << 1) ^ 0x1FFF409 : c << 1 }
        return c & 0xFFFFFF
    }

    /// Syndrom: CRC der Datenbits, verknüpft (XOR) mit dem Paritätsfeld in den letzten drei Bytes.
    /// 0 bei einer ungestörten Meldung mit reiner Parität (DF 17, 18); bei Meldungen mit überlagerter Adresse
    /// (DF 0, 4, 5, 16, 20, 21) ist es die Adresse des Flugzeugs; bei DF 11 die Interrogator-Kennung (unter 80).
    public static func remainder(_ bytes: [UInt8]) -> UInt32 {
        guard bytes.count >= 4 else { return 0 }
        var c: UInt32 = 0
        for b in bytes[0..<(bytes.count - 3)] { c = ((c << 8) & 0xFFFFFF) ^ table[Int((c >> 16) ^ UInt32(b)) & 0xFF] }
        let parity = UInt32(bytes[bytes.count - 3]) << 16 | UInt32(bytes[bytes.count - 2]) << 8 | UInt32(bytes[bytes.count - 1])
        return (c ^ parity) & 0xFFFFFF
    }

    /// Rest einer Meldung, in der nur Bit `p` (0 = höchstes Bit) gesetzt ist: so sieht ein einzelner Bitfehler aus
    static let syndromes112: [UInt32] = (0..<112).map { p -> UInt32 in
        var b = [UInt8](repeating: 0, count: 14)
        b[p / 8] = 0x80 >> UInt8(p % 8)
        return remainder(b)
    }
}

// MARK: - Meldung

public struct ModeSMessage: Equatable, Sendable {
    /// Wie die Adresse gesichert ist
    public enum Confidence: String, Sendable {
        /// Prüfsumme stimmt (DF 17, 18) oder Interrogator-Anteil (DF 11)
        case crc
        /// Ein Bit wurde korrigiert
        case corrected
        /// Adresse stammt aus der Parität und ist von einem kürzlich gehörten Flugzeug bekannt
        case knownAddress
    }

    public var df: Int
    public var icao: UInt32
    public var confidence: Confidence
    /// Index des korrigierten Bits (nur bei `.corrected`)
    public var correctedBit: Int?
    public var bytes: [UInt8]
    public var levelDB: Double = 0

    // Inhalt (je nach Meldungsart)
    public var altitudeFt: Int?
    public var squawk: String?
    public var callsign: String?
    public var category: Int?
    public var typeCode: Int?
    public var onGround: Bool?
    public var emergency: Int?
    public var capability: Int?
    public var velocity: Velocity?
    /// CPR-Rohwerte einer Positionsmeldung
    public var cpr: CPRFrame?
    /// Höhe ist GNSS-Höhe (Typ 20–22) statt barometrisch
    public var altitudeIsGNSS = false
    public var flightStatus: Int?

    public struct Velocity: Equatable, Sendable {
        public var groundSpeedKn: Double?
        public var trackDeg: Double?
        public var airspeedKn: Double?
        public var airspeedIsTrue = false
        public var headingDeg: Double?
        public var verticalRateFpm: Int?
        public var subtype: Int
    }

    public struct CPRFrame: Equatable, Sendable {
        public var odd: Bool
        public var lat: Int
        public var lon: Int
        public var surface: Bool
    }

    public var icaoText: String { String(format: "%06X", icao) }
    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
    public var isExtendedSquitter: Bool { df == 17 || df == 18 }
}

/// Kenngrößen für das Rufzeichen: 6 Bit je Zeichen
private let callsignCharset = Array("#ABCDEFGHIJKLMNOPQRSTUVWXYZ#####_###############0123456789######")

// MARK: - Auswertung

/// Prüft und liest Mode-S-Meldungen. Meldungen ohne reine Parität (DF 0, 4, 5, 16, 20, 21) gelten nur für Adressen,
/// die kürzlich in einer gesicherten Meldung (DF 11, 17, 18) vorkamen; das schützt vor Zufallstreffern im Rauschen.
public final class ModeSDecoder: @unchecked Sendable {
    /// Wie lange eine Adresse als bekannt gilt
    public static let addressTTL: TimeInterval = 60
    /// Einzelbitfehler in DF 17 und 18 korrigieren
    public var correctSingleBit = true

    private var known: [UInt32: Date] = [:]
    private var now = Date()

    public init() {}

    public func reset() { known.removeAll() }

    /// Länge in Bytes nach der Meldungsart (DF ≥ 16: 14 Byte)
    public static func length(df: Int) -> Int { df >= 16 ? 14 : 7 }

    /// Meldung prüfen; nil, wenn sie sich nicht sichern lässt
    public func decode(_ raw: [UInt8], at time: Date = Date()) -> ModeSMessage? {
        guard raw.count >= 7 else { return nil }
        now = time
        let df = Int(raw[0] >> 3)
        let length = Self.length(df: df)
        guard raw.count >= length else { return nil }
        var bytes = Array(raw.prefix(length))
        let rem = ModeSCRC.remainder(bytes)
        var confidence = ModeSMessage.Confidence.crc
        var corrected: Int?
        var icao: UInt32

        switch df {
        case 17, 18:
            if rem != 0 {
                guard correctSingleBit, length == 14, let p = ModeSCRC.syndromes112.firstIndex(of: rem) else { return nil }
                bytes[p / 8] ^= 0x80 >> UInt8(p % 8)
                guard ModeSCRC.remainder(bytes) == 0 else { return nil }
                corrected = p
                confidence = .corrected
            }
            icao = UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            if df == 17 || df == 18 { remember(icao) }
        case 11:
            // Rest unter 80: der Interrogator-Kennung (7 Bit) überlagert, sonst gestört
            guard rem & 0xFFFF80 == 0 else { return nil }
            icao = UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            if rem == 0 { remember(icao) } else if !isKnown(icao) { return nil }
        case 0, 4, 5, 16, 20, 21:
            icao = rem
            guard isKnown(icao) else { return nil }
            confidence = .knownAddress
        default:
            return nil
        }

        var m = ModeSMessage(df: df, icao: icao, confidence: confidence, correctedBit: corrected, bytes: bytes)
        decodeContent(&m)
        return m
    }

    private func remember(_ icao: UInt32) {
        known[icao] = now
        if known.count > 4000 { known = known.filter { now.timeIntervalSince($0.value) < Self.addressTTL } }
    }

    private func isKnown(_ icao: UInt32) -> Bool {
        guard let t = known[icao] else { return false }
        return now.timeIntervalSince(t) < Self.addressTTL
    }

    // MARK: Inhalt

    private func decodeContent(_ m: inout ModeSMessage) {
        let b = m.bytes
        switch m.df {
        case 0, 4, 16, 20:
            m.altitudeFt = Self.altitudeAC13(b)
            m.flightStatus = m.df == 4 || m.df == 20 ? Int(b[0] & 7) : nil
            if m.df == 4 || m.df == 20 { m.onGround = (b[0] & 7) == 1 || (b[0] & 7) == 3 ? true : ((b[0] & 7) <= 3 ? false : nil) }
            if m.df == 0 || m.df == 16 { m.onGround = b[0] & 0x04 != 0 }
            if m.df == 20 { decodeCommB(&m) }
        case 5, 21:
            m.squawk = Self.squawkID13(b)
            m.flightStatus = Int(b[0] & 7)
            m.onGround = (b[0] & 7) == 1 || (b[0] & 7) == 3 ? true : ((b[0] & 7) <= 3 ? false : nil)
            if m.df == 21 { decodeCommB(&m) }
        case 11:
            m.capability = Int(b[0] & 7)
        case 17, 18:
            m.capability = Int(b[0] & 7)
            decodeExtendedSquitter(&m)
        default:
            break
        }
    }

    /// Höhe aus dem 13-Bit-Feld AC (DF 0, 4, 16, 20): nur die 25-Fuß-Codierung (Q-Bit) und Meter-Angabe werden gelesen.
    /// Die ältere Gillham-Codierung (Q = 0) bleibt ohne Höhe.
    static func altitudeAC13(_ b: [UInt8]) -> Int? {
        let mBit = b[3] & 0x40 != 0
        let qBit = b[3] & 0x10 != 0
        if mBit { return nil }
        guard qBit else { return nil }
        let n = (Int(b[2] & 31) << 6) | (Int(b[3] & 0x80) >> 2) | (Int(b[3] & 0x20) >> 1) | Int(b[3] & 15)
        return n * 25 - 1000
    }

    /// Höhe aus dem 12-Bit-Feld der Positionsmeldungen (Typ 9–18, 20–22)
    static func altitudeAC12(_ b: [UInt8]) -> Int? {
        guard b[5] & 1 != 0 else { return nil }
        let n = (Int(b[5] >> 1) << 4) | (Int(b[6] & 0xF0) >> 4)
        return n * 25 - 1000
    }

    /// Kennung aus dem 13-Bit-Feld ID (DF 5, 21): vier Oktalziffern (Squawk)
    static func squawkID13(_ b: [UInt8]) -> String {
        let id = (Int(b[2] & 0x1F) << 8) | Int(b[3])
        let c1 = (id >> 12) & 1, a1 = (id >> 11) & 1, c2 = (id >> 10) & 1, a2 = (id >> 9) & 1, c4 = (id >> 8) & 1, a4 = (id >> 7) & 1
        let b1 = (id >> 5) & 1, d1 = (id >> 4) & 1, b2 = (id >> 3) & 1, d2 = (id >> 2) & 1, b4 = (id >> 1) & 1, d4 = id & 1
        let a = a4 * 4 + a2 * 2 + a1, bb = b4 * 4 + b2 * 2 + b1, c = c4 * 4 + c2 * 2 + c1, d = d4 * 4 + d2 * 2 + d1
        return "\(a)\(bb)\(c)\(d)"
    }

    /// BDS 2,0 (Rufzeichen) aus dem Comm-B-Feld von DF 20 und 21
    private func decodeCommB(_ m: inout ModeSMessage) {
        let mb = Array(m.bytes[4..<11])
        guard mb[0] == 0x20 else { return }
        var s = ""
        let bits = mb[1...].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }      // 48 Bit
        for i in 0..<8 { s.append(callsignCharset[Int((bits >> UInt64(42 - 6 * i)) & 0x3F)]) }
        guard !s.contains("#"), s.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        m.callsign = s.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }

    private func decodeExtendedSquitter(_ m: inout ModeSMessage) {
        let b = m.bytes
        let me = Array(b[4..<11])
        let tc = Int(me[0] >> 3)
        m.typeCode = tc
        switch tc {
        case 1...4:
            m.category = Int(me[0] & 7)
            var s = ""
            let bits = me[1...].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            for i in 0..<8 { s.append(callsignCharset[Int((bits >> UInt64(42 - 6 * i)) & 0x3F)]) }
            m.callsign = s.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
        case 5...8:
            m.onGround = true
            let odd = me[2] & 0x04 != 0
            let lat = (Int(me[2] & 3) << 15) | (Int(me[3]) << 7) | Int(me[4] >> 1)
            let lon = (Int(me[4] & 1) << 16) | (Int(me[5]) << 8) | Int(me[6])
            m.cpr = .init(odd: odd, lat: lat, lon: lon, surface: true)
            // Bewegung (7 Bit) und Bahnwinkel (7 Bit mit Gültigkeitsbit)
            let movement = (Int(me[0] & 7) << 4) | Int(me[1] >> 4)
            var v = ModeSMessage.Velocity(subtype: 0)
            v.groundSpeedKn = Self.surfaceSpeed(movement)
            if me[1] & 0x08 != 0 {
                let t = (Int(me[1] & 7) << 4) | Int(me[2] >> 4)
                v.trackDeg = Double(t) * 360.0 / 128.0
            }
            if v.groundSpeedKn != nil || v.trackDeg != nil { m.velocity = v }
        case 9...18, 20...22:
            m.onGround = false
            m.altitudeFt = Self.altitudeAC12(b)
            m.altitudeIsGNSS = tc >= 20
            let odd = me[2] & 0x04 != 0
            let lat = (Int(me[2] & 3) << 15) | (Int(me[3]) << 7) | Int(me[4] >> 1)
            let lon = (Int(me[4] & 1) << 16) | (Int(me[5]) << 8) | Int(me[6])
            m.cpr = .init(odd: odd, lat: lat, lon: lon, surface: false)
        case 19:
            decodeVelocity(&m, me)
        case 28:
            if me[0] & 7 == 1 {
                m.emergency = Int(me[1] >> 5)
                let id = (Int(me[1] & 0x1F) << 8) | Int(me[2])
                var fake = [UInt8](repeating: 0, count: 14)
                fake[2] = UInt8((id >> 8) & 0x1F)
                fake[3] = UInt8(id & 0xFF)
                m.squawk = Self.squawkID13(fake)
            }
        default:
            break
        }
    }

    /// Geschwindigkeit am Boden aus der Bewegungsangabe (Typ 5–8), in Knoten; nil bei „keine Angabe“
    static func surfaceSpeed(_ mv: Int) -> Double? {
        switch mv {
        case 0, 125...127: return nil
        case 1: return 0
        case 2...8: return 0.125 * Double(mv - 1)          // bis 1 kn in 0,125-Schritten
        case 9...12: return 1 + 0.25 * Double(mv - 9)
        case 13...38: return 2 + 0.5 * Double(mv - 13)
        case 39...93: return 15 + Double(mv - 39)
        case 94...108: return 70 + 2 * Double(mv - 94)
        case 109...123: return 100 + 5 * Double(mv - 109)
        case 124: return 175
        default: return nil
        }
    }

    private func decodeVelocity(_ m: inout ModeSMessage, _ me: [UInt8]) {
        let subtype = Int(me[0] & 7)
        guard (1...4).contains(subtype) else { return }
        var v = ModeSMessage.Velocity(subtype: subtype)
        let vrSign = me[4] & 0x08 != 0
        let vr = ((Int(me[4] & 7) << 6) | Int(me[5] >> 2))
        if vr > 0 { v.verticalRateFpm = (vr - 1) * 64 * (vrSign ? -1 : 1) }
        if subtype == 1 || subtype == 2 {
            let scale = subtype == 2 ? 4.0 : 1.0
            let ewSign = me[1] & 0x04 != 0
            let ew = (Int(me[1] & 3) << 8) | Int(me[2])
            let nsSign = me[3] & 0x80 != 0
            let ns = (Int(me[3] & 0x7F) << 3) | Int(me[4] >> 5)
            if ew > 0 && ns > 0 {
                let vx = Double(ew - 1) * scale * (ewSign ? -1 : 1)
                let vy = Double(ns - 1) * scale * (nsSign ? -1 : 1)
                v.groundSpeedKn = (vx * vx + vy * vy).squareRoot()
                var t = atan2(vx, vy) * 180 / .pi
                if t < 0 { t += 360 }
                v.trackDeg = t
            }
        } else {
            let scale = subtype == 4 ? 4.0 : 1.0
            if me[1] & 0x04 != 0 {
                let hdg = (Int(me[1] & 3) << 8) | Int(me[2])
                v.headingDeg = Double(hdg) * 360.0 / 1024.0
            }
            v.airspeedIsTrue = me[3] & 0x80 != 0
            let air = (Int(me[3] & 0x7F) << 3) | Int(me[4] >> 5)
            if air > 0 { v.airspeedKn = Double(air - 1) * scale }
        }
        m.velocity = v
    }
}

// MARK: - CPR (Compact Position Reporting)

public enum ADSBCPR {
    /// Zahl der Längenzonen bei der Breite `lat` (NL)
    public static func nl(_ lat: Double) -> Int {
        let a = abs(lat)
        if a < 1e-9 { return 59 }
        if abs(a - 87) < 1e-9 { return 2 }
        if a > 87 { return 1 }
        let nz = 15.0
        let t = 1 - (1 - cos(.pi / (2 * nz))) / pow(cos(.pi / 180 * a), 2)
        return Int((2 * .pi / acos(t)).rounded(.down))
    }

    private static func mod(_ a: Int, _ b: Int) -> Int { let r = a % b; return r < 0 ? r + b : r }
    private static func fmod(_ a: Double, _ b: Double) -> Double { let r = a.truncatingRemainder(dividingBy: b); return r < 0 ? r + b : r }

    /// Globale Dekodierung aus einem geraden und einem ungeraden Rahmen in der Luft (Breite und Länge je 17 Bit).
    /// `newerIsOdd`: der jüngere Rahmen ist der ungerade. nil, wenn die beiden Rahmen in verschiedenen Längenzonen liegen.
    public static func globalAirborne(even: (lat: Int, lon: Int), odd: (lat: Int, lon: Int), newerIsOdd: Bool) -> (lat: Double, lon: Double)? {
        let dlat0 = 360.0 / 60, dlat1 = 360.0 / 59
        let lat0 = Double(even.lat), lat1 = Double(odd.lat), lon0 = Double(even.lon), lon1 = Double(odd.lon)
        let j = Int(floor((59 * lat0 - 60 * lat1) / 131072 + 0.5))
        var rlat0 = dlat0 * (Double(mod(j, 60)) + lat0 / 131072)
        var rlat1 = dlat1 * (Double(mod(j, 59)) + lat1 / 131072)
        if rlat0 >= 270 { rlat0 -= 360 }
        if rlat1 >= 270 { rlat1 -= 360 }
        guard abs(rlat0) <= 90, abs(rlat1) <= 90, nl(rlat0) == nl(rlat1) else { return nil }
        var lat: Double, lon: Double
        if newerIsOdd {
            let nlv = nl(rlat1)
            let ni = max(nlv - 1, 1)
            let m = Int(floor((lon0 * Double(nlv - 1) - lon1 * Double(nlv)) / 131072 + 0.5))
            lon = 360.0 / Double(ni) * (Double(mod(m, ni)) + lon1 / 131072)
            lat = rlat1
        } else {
            let nlv = nl(rlat0)
            let ni = max(nlv, 1)
            let m = Int(floor((lon0 * Double(nlv - 1) - lon1 * Double(nlv)) / 131072 + 0.5))
            lon = 360.0 / Double(ni) * (Double(mod(m, ni)) + lon0 / 131072)
            lat = rlat0
        }
        if lon >= 180 { lon -= 360 }
        return (lat, lon)
    }

    /// Dekodierung eines einzelnen Rahmens mit Bezugspunkt (Position des Flugzeugs von vorhin oder des Empfängers), gültig bis rund 180 sm Abstand
    public static func local(lat cprLat: Int, lon cprLon: Int, odd: Bool, ref: (lat: Double, lon: Double), surface: Bool = false) -> (lat: Double, lon: Double) {
        let span = surface ? 90.0 : 360.0
        let dlat = span / (odd ? 59 : 60)
        let latCPR = Double(cprLat) / 131072, lonCPR = Double(cprLon) / 131072
        let j = floor(ref.lat / dlat) + floor(0.5 + fmod(ref.lat, dlat) / dlat - latCPR)
        let lat = dlat * (j + latCPR)
        let ni = max(nl(lat) - (odd ? 1 : 0), 1)
        let dlon = span / Double(ni)
        let m = floor(ref.lon / dlon) + floor(0.5 + fmod(ref.lon, dlon) / dlon - lonCPR)
        var lon = dlon * (m + lonCPR)
        if lon >= 180 { lon -= 360 }
        if lon < -180 { lon += 360 }
        return (lat, lon)
    }
}
