// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

public struct ADSBTrackPoint: Equatable, Sendable {
    public var lat: Double
    public var lon: Double
    public var altitudeFt: Int?
    public var time: Date
}

/// Ein Flugzeug, das über Mode S gehört wurde (Schlüssel: ICAO-24-Bit-Adresse)
public struct ADSBAircraft: Identifiable, Equatable, Sendable {
    public var id: UInt32 { icao }
    public var icao: UInt32
    public var callsign: String?
    public var typeCode: Int?
    public var category: Int?
    public var squawk: String?
    public var altitudeFt: Int?
    public var altitudeIsGNSS = false
    public var groundSpeedKn: Double?
    public var trackDeg: Double?
    public var verticalRateFpm: Int?
    public var position: GeoPoint?
    public var positionTime: Date?
    public var onGround: Bool?
    public var emergency: Int?
    public var messages = 0
    public var positionMessages = 0
    public var firstSeen: Date
    public var lastSeen: Date
    public var track: [ADSBTrackPoint] = []
    /// Geglätteter Pegel in dB unter Vollaussteuerung
    public var levelDB: Double?
    /// Größte Entfernung zum Empfänger, bei der eine Position dieses Flugzeugs gehört wurde (km)
    public var maxRangeKm: Double?

    // Rohwerte für die CPR-Paarung
    var evenFrame: (lat: Int, lon: Int, time: Date)?
    var oddFrame: (lat: Int, lon: Int, time: Date)?

    public static func == (a: ADSBAircraft, b: ADSBAircraft) -> Bool {
        a.icao == b.icao && a.callsign == b.callsign && a.altitudeFt == b.altitudeFt && a.position == b.position
            && a.lastSeen == b.lastSeen && a.messages == b.messages && a.squawk == b.squawk && a.groundSpeedKn == b.groundSpeedKn
    }

    public var icaoText: String { String(format: "%06X", icao) }
    public var country: ICAOCountry? { ICAORanges.shared.country(icao) }
    public var categoryText: String? { ADSBNames.category(typeCode: typeCode, category: category) }
    public var emergencyText: String? { ADSBNames.emergency(emergency, squawk: squawk) }
    public var hasPosition: Bool { position != nil }

    /// Flughöhe als Flugfläche („FL 380“) oder in Fuß unter FL 100
    public var altitudeText: String? {
        guard let a = altitudeFt else { return nil }
        if onGround == true { return "Boden" }
        return abs(a) >= 10_000 ? "FL \(a / 100)" : "\(a) ft"
    }

    public func ageSeconds(now: Date) -> Int { max(0, Int(now.timeIntervalSince(lastSeen))) }
}

/// Führt die gehörten Mode-S-Meldungen zu einer Flugzeugliste zusammen: Kennung, Höhe, Geschwindigkeit, Position (CPR),
/// Weg. Positionen werden aus einem geraden und einem ungeraden Rahmen innerhalb von zehn Sekunden berechnet; danach genügt
/// ein einzelner Rahmen relativ zur letzten Position. Unplausible Sprünge werden verworfen.
public struct ADSBTracker: Sendable {
    public private(set) var aircraft: [UInt32: ADSBAircraft] = [:]
    /// Standort des Empfängers: Entfernungen und Bodenpositionen
    public var receiver: GeoPoint?
    public private(set) var messageCount = 0
    public private(set) var positionCount = 0
    public private(set) var rejectedPositions = 0
    /// Anzahl je Meldungsart (DF)
    public private(set) var dfCounts: [Int: Int] = [:]
    /// Weiteste gehörte Position je 10°-Sektor des Peilwinkels (km), Index 0 = Nord bis 10°
    public private(set) var rangeBySector = [Double](repeating: 0, count: 36)

    public static let pairWindow: TimeInterval = 10
    /// Größter glaubwürdiger Abstand zum Empfänger (km)
    public static let maxRangeKm = 1000.0
    /// Größte glaubwürdige Geschwindigkeit zwischen zwei Positionen (Knoten)
    public static let maxSpeedKn = 1500.0
    public static let maxTrackPoints = 400

    public init(receiver: GeoPoint? = nil) { self.receiver = receiver }

    public mutating func clear() {
        aircraft.removeAll()
        messageCount = 0
        positionCount = 0
        rejectedPositions = 0
        dfCounts.removeAll()
        rangeBySector = [Double](repeating: 0, count: 36)
    }

    /// Flugzeuge entfernen, die seit `maxAge` Sekunden nicht mehr gehört wurden
    public mutating func expire(now: Date, maxAge: TimeInterval) {
        aircraft = aircraft.filter { now.timeIntervalSince($0.value.lastSeen) <= maxAge }
    }

    @discardableResult
    public mutating func ingest(_ m: ModeSMessage, at now: Date) -> ADSBAircraft? {
        messageCount += 1
        dfCounts[m.df, default: 0] += 1
        var a = aircraft[m.icao] ?? ADSBAircraft(icao: m.icao, firstSeen: now, lastSeen: now)
        a.lastSeen = now
        a.messages += 1
        if m.levelDB != 0 { a.levelDB = a.levelDB.map { 0.9 * $0 + 0.1 * m.levelDB } ?? m.levelDB }
        if let c = m.callsign, !c.isEmpty { a.callsign = c }
        if let t = m.typeCode, (1...4).contains(t) { a.typeCode = t; a.category = m.category }
        if let s = m.squawk { a.squawk = s }
        if let e = m.emergency { a.emergency = e }
        if let g = m.onGround { a.onGround = g }
        if let alt = m.altitudeFt {
            a.altitudeFt = alt
            a.altitudeIsGNSS = m.altitudeIsGNSS
        }
        if let v = m.velocity {
            if let g = v.groundSpeedKn { a.groundSpeedKn = g }
            if let t = v.trackDeg { a.trackDeg = t } else if let h = v.headingDeg, a.groundSpeedKn == nil { a.trackDeg = h }
            if let vr = v.verticalRateFpm { a.verticalRateFpm = vr }
            if v.airspeedKn != nil, a.groundSpeedKn == nil, let air = v.airspeedKn { a.groundSpeedKn = air }
        }
        if let c = m.cpr { updatePosition(&a, cpr: c, altitude: m.altitudeFt, now: now) }
        aircraft[m.icao] = a
        return a
    }

    // MARK: Position

    private mutating func updatePosition(_ a: inout ADSBAircraft, cpr c: ModeSMessage.CPRFrame, altitude: Int?, now: Date) {
        a.positionMessages += 1
        if c.odd { a.oddFrame = (c.lat, c.lon, now) } else { a.evenFrame = (c.lat, c.lon, now) }
        var result: (lat: Double, lon: Double)?

        if c.surface {
            // Am Boden: Bezugspunkt ist die letzte Position, sonst der Empfänger (Flughäfen in der Nähe)
            let ref = a.position.map { (lat: $0.lat, lon: $0.lon) } ?? receiver.map { (lat: $0.lat, lon: $0.lon) }
            if let ref {
                let p = ADSBCPR.local(lat: c.lat, lon: c.lon, odd: c.odd, ref: ref, surface: true)
                // Ohne eigene frühere Position muss es nahe am Empfänger liegen
                if a.position != nil || distanceToReceiver(p).map({ $0 < 100 }) == true { result = p }
            }
        } else {
            if let e = a.evenFrame, let o = a.oddFrame, abs(e.time.timeIntervalSince(o.time)) <= Self.pairWindow {
                result = ADSBCPR.globalAirborne(even: (e.lat, e.lon), odd: (o.lat, o.lon), newerIsOdd: o.time > e.time)
            } else if let last = a.position, let t = a.positionTime, now.timeIntervalSince(t) < 300 {
                result = ADSBCPR.local(lat: c.lat, lon: c.lon, odd: c.odd, ref: (last.lat, last.lon))
            }
        }
        guard let p = result else { return }
        guard abs(p.lat) <= 90, abs(p.lon) <= 180 else { rejectedPositions += 1; return }
        let point = GeoPoint(lat: p.lat, lon: p.lon)
        // Entfernung zum Empfänger und Sprung seit der letzten Position prüfen
        let range = distanceToReceiver(p)
        if let r = range, r > Self.maxRangeKm { rejectedPositions += 1; a.evenFrame = nil; a.oddFrame = nil; return }
        if let last = a.position, let t = a.positionTime {
            let dt = max(now.timeIntervalSince(t), 0.5)
            let km = Geo.distanceKm(last, point)
            if km / dt * 3600 / 1.852 > Self.maxSpeedKn && km > 2 {
                rejectedPositions += 1
                a.evenFrame = nil
                a.oddFrame = nil
                return
            }
        }
        a.position = point
        a.positionTime = now
        positionCount += 1
        if let r = range {
            a.maxRangeKm = max(a.maxRangeKm ?? 0, r)
            if let rx = receiver {
                let bearing = Geo.bearing(from: rx, to: point)
                let sector = min(35, max(0, Int(bearing / 10)))
                rangeBySector[sector] = max(rangeBySector[sector], r)
            }
        }
        if let last = a.track.last {
            if Geo.distanceKm(GeoPoint(lat: last.lat, lon: last.lon), point) > 0.1 || now.timeIntervalSince(last.time) > 30 {
                a.track.append(ADSBTrackPoint(lat: p.lat, lon: p.lon, altitudeFt: a.altitudeFt, time: now))
            }
        } else {
            a.track.append(ADSBTrackPoint(lat: p.lat, lon: p.lon, altitudeFt: a.altitudeFt, time: now))
        }
        if a.track.count > Self.maxTrackPoints { a.track.removeFirst(a.track.count - Self.maxTrackPoints) }
    }

    private func distanceToReceiver(_ p: (lat: Double, lon: Double)) -> Double? {
        receiver.map { Geo.distanceKm($0, GeoPoint(lat: p.lat, lon: p.lon)) }
    }
}
