// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - HFDL-Protokoll: SPDU, MPDU, LPDU, HFNPDU, ACARS (ARINC 635, 618)
//
// Eigene Umsetzung; Feldlagen und Typnummern nach dumphfdl (GPLv3), das nur gelesen wurde. Ein ACARS-Block (HFNPDU „Enveloped data“)
// ist wie in VHF-ACARS aufgebaut und wird vom ACARS-Parser des Programms gelesen.

/// Inhalt eines Squitters: Stand von drei Bodenstationen
public struct HFDLSquitterInfo: Sendable {
    public struct Station: Sendable {
        public var id: Int
        public var utcSync: Bool
        public var frequenciesKHz: [Double]
    }
    public var tableVersion: Int
    public var frameIndex: Int
    public var stations: [Station]
}

/// Ein auswertbares Ereignis aus einem Rahmen: ein Squitter oder ein LPDU (Anmeldung, Daten …)
public struct HFDLEvent: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case squitter, logonRequest, logonConfirm, logonDenied, logoff, logonResume, data, unknown
    }

    public var id = UUID()
    public var time: Date
    public var freqKHz: Double
    public var bitRate: Int
    public var doubleSlot: Bool
    public var snrDB: Double
    public var freqErrorHz: Double
    public var uplink: Bool
    public var kind: Kind
    /// Bodenstation (Nummer in der Systemtabelle) – Absender bei Aufwärtsstrecke, Ziel bei Abwärtsstrecke
    public var station: Int?
    /// Kurznummer des Flugzeugs auf diesem Kanal (255 = alle)
    public var aircraftID: Int?
    public var icao: UInt32?
    public var title: String
    /// Weitere Zeilen zum Inhalt
    public var lines: [String] = []
    public var flightID: String?
    public var registration: String?
    public var position: GeoPoint?
    /// Uhrzeit der Position (UTC) laut Meldung
    public var positionTime: String?
    public var acars: ACARSMessage?
    public var squitter: HFDLSquitterInfo?

    public var icaoHex: String? { icao.map { String(format: "%06X", $0) } }
}

/// Zuordnung Kurznummer → ICAO-Adresse je Kanal (die Nummern gelten nur auf einer Frequenz)
public struct HFDLAircraftCache: Sendable {
    private struct Key: Hashable { var freq: Int; var id: Int }
    private var forward: [Key: UInt32] = [:]
    private var inverse: [UInt32: Key] = [:]

    public init() {}

    public mutating func register(freqKHz: Double, id: Int, icao: UInt32) {
        let k = Key(freq: Int(freqKHz.rounded()), id: id)
        if let old = forward[k] { inverse[old] = nil }
        if let oldKey = inverse[icao] { forward[oldKey] = nil }
        forward[k] = icao
        inverse[icao] = k
    }

    public mutating func remove(icao: UInt32) {
        if let k = inverse[icao] { forward[k] = nil }
        inverse[icao] = nil
    }

    public func icao(freqKHz: Double, id: Int) -> UInt32? { forward[Key(freq: Int(freqKHz.rounded()), id: id)] }
}

public struct HFDLParseStats: Sendable {
    public var frames = 0, badHeader = 0, badLPDU = 0, lpdus = 0
}

public enum HFDLProtocol {

    // MARK: Hilfen

    static func reverse(_ b: UInt8) -> UInt8 {
        var v = b, r: UInt8 = 0
        for _ in 0..<8 { r = (r << 1) | (v & 1); v >>= 1 }
        return r
    }

    static func icao(_ b: ArraySlice<UInt8>) -> UInt32 {
        let a = Array(b)
        return UInt32(reverse(a[0])) << 16 | UInt32(reverse(a[1])) << 8 | UInt32(reverse(a[2]))
    }

    /// 20 Bit Zweierkomplement, 180° = 0x7FFFF
    static func coordinate(_ raw: UInt32) -> Double {
        var v = Int32(raw & 0xFFFFF)
        if v & 0x80000 != 0 { v -= 0x100000 }
        return Double(v) * 180.0 / Double(0x7FFFF)
    }

    static func clock(seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", (seconds / 3600) % 24, seconds / 60 % 60, seconds % 60)
    }

    static func khzText(_ f: Double) -> String { String(format: "%.1f", f).replacingOccurrences(of: ".", with: ",") }

    static func stationName(_ id: Int) -> String { HFDLStations.station(id)?.name ?? "Station \(id)" }

    static func freqList(_ station: Int, _ mask: UInt32) -> String {
        let f = HFDLStations.frequencies(station: station, mask: mask)
        if f.isEmpty { return mask == 0 ? "keine" : "Maske \(String(mask, radix: 16))" }
        return f.map { khzText($0) }.joined(separator: ", ")
    }

    // MARK: Einstieg

    /// Zerlegt einen Rahmen in Ereignisse. `cache` merkt die Zuordnung Kurznummer → ICAO über die Rahmen hinweg.
    public static func parse(_ frame: HFDLRawFrame, freqKHz: Double, time: Date, cache: inout HFDLAircraftCache,
                             stats: inout HFDLParseStats) -> [HFDLEvent] {
        let b = frame.bytes
        stats.frames += 1
        guard HFDLCRC.headerOK(b), let first = b.first else { stats.badHeader += 1; return [] }
        func base(uplink: Bool) -> HFDLEvent {
            HFDLEvent(time: time, freqKHz: freqKHz, bitRate: frame.bitRate, doubleSlot: frame.doubleSlot, snrDB: frame.snrDB,
                      freqErrorHz: frame.freqErrorHz, uplink: uplink, kind: .unknown, title: "")
        }
        if first & 1 == 0 {
            // SPDU (Squitter): immer Aufwärtsstrecke, 66 Bytes
            guard b.count >= 66 else { stats.badHeader += 1; return [] }
            return [squitter(b, base: base(uplink: true))]
        }
        // MPDU
        var events: [HFDLEvent] = []
        if first & 2 != 0 {
            let lpduCount = Int((first >> 2) & 0xF)
            let hdr = 6 + lpduCount
            var ev = base(uplink: false)
            ev.station = Int(b[1] & 0x7F)
            ev.aircraftID = Int(b[2])
            var p = hdr + 2
            for i in 0..<lpduCount {
                let len = Int(b[6 + i]) + 1
                guard p + len <= b.count else { break }
                if let e = lpdu(Array(b[p..<(p + len)]), template: ev, cache: &cache, stats: &stats) { events.append(e) }
                p += len
            }
        } else {
            let aircraft = Int((first & 0x70) >> 4) + 1
            var hdr = 2
            for _ in 0..<aircraft { hdr += 2 + Int(b[hdr + 1] >> 4) }
            var base0 = base(uplink: true)
            base0.station = Int(b[1] & 0x7F)
            var p = hdr + 2
            var h = 2
            for _ in 0..<aircraft {
                var ev = base0
                ev.aircraftID = Int(b[h])
                let cnt = Int(b[h + 1] >> 4)
                h += 2
                for i in 0..<cnt {
                    let len = Int(b[h + i]) + 1
                    guard p + len <= b.count else { return events }
                    if let e = lpdu(Array(b[p..<(p + len)]), template: ev, cache: &cache, stats: &stats) { events.append(e) }
                    p += len
                }
                h += cnt
            }
        }
        return events
    }

    // MARK: SPDU

    private static let changeNotes = ["keine", "Kanal ausgefallen", "Frequenzwechsel angekündigt", "Bodenstation ausgefallen"]

    static func squitter(_ b: [UInt8], base: HFDLEvent) -> HFDLEvent {
        var e = base
        e.kind = .squitter
        let gs = Int(b[1] & 0x7F)
        e.station = gs
        e.title = "Squitter"
        let version = Int((b[0] >> 2) & 3)
        let rls = b[0] & 2 != 0
        let iso = b[0] & 0x20 != 0
        let change = Int((b[0] & 0xC0) >> 6)
        let frameIndex = Int(b[2]) | Int(b[3] & 0xF) << 8
        let frameOffset = Int(b[3] >> 4)
        let minPriority = Int(b[52] & 0xF)
        let tableVersion = Int(b[53]) | Int(b[54] & 0xF) << 8
        let g0 = UInt32(b[54] >> 4) | UInt32(b[55]) << 4 | UInt32(b[56]) << 12
        let g1id = Int(b[57] & 0x7F)
        let g1 = UInt32(b[58]) | UInt32(b[59]) << 8 | UInt32(b[60] & 0xF) << 16
        let g2id = Int(b[60] >> 4) | Int(b[61] & 0x7) << 4
        let g2 = UInt32(b[61] >> 4) | UInt32(b[62]) << 4 | UInt32(b[63]) << 12
        e.lines.append("Version \(version), RLS \(rls ? "ja" : "nein"), ISO 8208 \(iso ? "ja" : "nein")")
        e.lines.append("Änderungshinweis: \(changeNotes[change])")
        e.lines.append("TDMA-Rahmen \(frameIndex), Versatz \(frameOffset), niedrigste Priorität \(minPriority)")
        e.lines.append("Systemtabelle Version \(tableVersion)" + (tableVersion != HFDLStations.tableVersion ? " (Digidec kennt \(HFDLStations.tableVersion))" : ""))
        let utc0 = b[1] & 0x80 != 0, utc1 = b[57] & 0x80 != 0, utc2 = b[61] & 0x8 != 0
        e.squitter = HFDLSquitterInfo(tableVersion: tableVersion, frameIndex: frameIndex, stations: [
            .init(id: gs, utcSync: utc0, frequenciesKHz: HFDLStations.frequencies(station: gs, mask: g0)),
            .init(id: g1id, utcSync: utc1, frequenciesKHz: HFDLStations.frequencies(station: g1id, mask: g1)),
            .init(id: g2id, utcSync: utc2, frequenciesKHz: HFDLStations.frequencies(station: g2id, mask: g2))
        ])
        e.lines.append("\(stationName(gs)): UTC-Sync \(utc0 ? "ja" : "nein"), Frequenzen in Benutzung \(freqList(gs, g0))")
        e.lines.append("\(stationName(g1id)): UTC-Sync \(utc1 ? "ja" : "nein"), Frequenzen in Benutzung \(freqList(g1id, g1))")
        e.lines.append("\(stationName(g2id)): UTC-Sync \(utc2 ? "ja" : "nein"), Frequenzen in Benutzung \(freqList(g2id, g2))")
        return e
    }

    // MARK: LPDU

    static func lpdu(_ buf: [UInt8], template: HFDLEvent, cache: inout HFDLAircraftCache, stats: inout HFDLParseStats) -> HFDLEvent? {
        stats.lpdus += 1
        guard buf.count >= 3, HFDLCRC.check(buf, length: buf.count - 2) else { stats.badLPDU += 1; return nil }
        let b = Array(buf[0..<(buf.count - 2)])
        var e = template
        e.id = UUID()                    // jede LPDU ein eigenes Ereignis (Kopien der Vorlage teilten sonst die Kennung)
        let type = b[0]
        var consumed = 0
        var icaoAddress: UInt32?
        let freq = template.freqKHz
        switch type {
        case 0x0D, 0x1D:
            e.kind = .data
            e.title = type == 0x1D ? "Daten mit Quittung" : "Daten"
            consumed = 1
        case 0x2F, 0x3F:
            e.kind = type == 0x2F ? .logonDenied : .logoff
            e.title = type == 0x2F ? "Anmeldung abgelehnt" : "Abmeldung"
            guard b.count >= 5 else { return nil }
            icaoAddress = icao(b[1..<4])
            let reasonDenied = [1: "Flugzeugnummer nicht verfügbar", 2: "Bodenstation unterstützt RLS nicht"]
            let reasonOff = [1: "nicht innerhalb der Slotgrenzen", 2: "Abwärtsstrecke im Aufwärts-Slot", 3: "RLS-Protokollfehler",
                             4: "ungültige Flugzeugnummer", 5: "Bodenstation unterstützt RLS nicht", 6: "andere"]
            let r = Int(b[4])
            e.lines.append("Grund: \(r) (\((type == 0x2F ? reasonDenied : reasonOff)[r] ?? "reserviert"))")
            consumed = 5
            if let ic = icaoAddress { cache.remove(icao: ic) }
        case 0x9F, 0x5F:
            e.kind = .logonConfirm
            e.title = type == 0x5F ? "Anmeldung wieder aufgenommen (Bestätigung)" : "Anmeldung bestätigt"
            guard b.count >= 8 else { return nil }
            icaoAddress = icao(b[1..<4])
            let assigned = Int(b[4])
            e.lines.append("Zugeteilte Kurznummer: \(assigned)")
            consumed = 8
            if let ic = icaoAddress { cache.register(freqKHz: freq, id: assigned, icao: ic) }
            e.aircraftID = assigned
        case 0x4F, 0x8F, 0xBF:
            e.kind = type == 0x4F ? .logonResume : .logonRequest
            e.title = type == 0x4F ? "Anmeldung wieder aufnehmen" : (type == 0x8F ? "Anmeldung (normal)" : "Anmeldung (DLS)")
            guard b.count >= 4 else { return nil }
            icaoAddress = icao(b[1..<4])
            consumed = 4
        default:
            e.kind = .unknown
            e.title = String(format: "LPDU Typ 0x%02X", type)
            e.lines.append("Daten: " + b.map { String(format: "%02X", $0) }.joined(separator: " "))
            consumed = b.count
        }
        if let ic = icaoAddress { e.icao = ic }
        else if let id = e.aircraftID, id != 255 { e.icao = cache.icao(freqKHz: freq, id: id) }
        if consumed < b.count { hfnpdu(Array(b[consumed...]), into: &e) }
        return e
    }

    // MARK: HFNPDU

    private static let freqChangeCodes = ["erste Frequenzsuche im Flugabschnitt", "zu viele NACKs", "SPDUs nicht mehr empfangen", "HFDL abgeschaltet",
                                         "Frequenzwechsel der Bodenstation", "Bodenstation oder Kanal ausgefallen", "schlechte Aufwärtsstrecke", "keine Änderung"]

    static func hfnpdu(_ b: [UInt8], into e: inout HFDLEvent) {
        guard !b.isEmpty else { return }
        guard b[0] == 0xFF else {
            e.lines.append("Daten: " + b.map { String(format: "%02X", $0) }.joined(separator: " "))
            return
        }
        guard b.count >= 2 else { return }
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func text(_ r: Range<Int>) -> String {
            String(decoding: b[r].map { $0 == 0 ? 0x20 : $0 & 0x7F }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        switch b[1] {
        case 0xD0:
            guard b.count >= 5 else { return }
            let total = Int(b[2] >> 4) + 1, seq = Int(b[2] & 0xF)
            let version = Int(b[3] >> 4) | Int(b[4]) << 4
            e.lines.append("Systemtabelle (Teil \(seq + 1) von \(total)), Version \(version)")
        case 0xD1:
            guard b.count >= 47 else { return }
            let flight = text(2..<8)
            let lat = coordinate(UInt32(b[8]) | UInt32(b[9]) << 8 | UInt32(b[10] & 0xF) << 16)
            let lon = coordinate(UInt32(b[10] >> 4) | UInt32(b[11]) << 4 | UInt32(b[12]) << 12)
            let t = 2 * u16(13)
            let gs = Int(b[17] & 0x7F)
            e.title += " · Leistungsdaten"
            e.flightID = flight
            e.position = GeoPoint(lat: lat, lon: lon)
            e.positionTime = clock(seconds: t)
            e.lines.append("Flug \(flight), Version \(b[15]), Flugabschnitt \(b[16])")
            if let f = HFDLStations.frequency(station: gs, index: Int(b[18])) {
                e.lines.append("Bodenstation \(stationName(gs)) auf \(khzText(f)) kHz")
            } else {
                e.lines.append("Bodenstation \(stationName(gs)), Frequenz Nr. \(b[18])")
            }
            e.lines.append("Frequenzsuchen: \(u16(21)) (vorher \(u16(19))), HFDL gesperrt: \(u16(25)) s (vorher \(u16(23)) s)")
            e.lines.append("MPDU empfangen 300/600/1200/1800: \(b[30])/\(b[29])/\(b[28])/\(b[27]), mit Fehlern \(b[34])/\(b[33])/\(b[32])/\(b[31])")
            e.lines.append("MPDU gesendet \(b[41])/\(b[40])/\(b[39])/\(b[38]), zugestellt \(b[45])/\(b[44])/\(b[43])/\(b[42])")
            e.lines.append("SPDU empfangen \(u16(35)), verpasst \(b[37])")
            e.lines.append("Letzter Frequenzwechsel: \(freqChangeCodes[Int(b[46] & 0x7)])")
        case 0xD2:
            e.title += " · Anfrage Systemtabelle"
        case 0xD5:
            guard b.count >= 15 else { return }
            let flight = text(2..<8)
            let lat = coordinate(UInt32(b[8]) | UInt32(b[9]) << 8 | UInt32(b[10] & 0xF) << 16)
            let lon = coordinate(UInt32(b[10] >> 4) | UInt32(b[11]) << 4 | UInt32(b[12]) << 12)
            let t = 2 * u16(13)
            e.title += " · Frequenzdaten"
            e.flightID = flight
            e.position = GeoPoint(lat: lat, lon: lon)
            e.positionTime = clock(seconds: t)
            e.lines.append("Flug \(flight)")
            var pos = 15
            while pos + 6 <= b.count && pos < 15 + 6 * 6 {
                let gs = Int(b[pos] & 0x7F)
                let heard = UInt32(b[pos + 1]) | UInt32(b[pos + 2]) << 8 | UInt32(b[pos + 3] & 0xF) << 16
                let listening = UInt32(b[pos + 3] >> 4) | UInt32(b[pos + 4]) << 4 | UInt32(b[pos + 5]) << 12
                e.lines.append("\(stationName(gs)): hört auf \(freqList(gs, listening)); empfangen auf \(freqList(gs, heard))")
                pos += 6
            }
        case 0xDE:
            e.title += " · Delayed Echo"
        case 0xFF:
            if b.count > 2 && b[2] == 1 { acars(Array(b[3...]), into: &e) }
            else { e.lines.append("Daten: " + b[2...].map { String(format: "%02X", $0) }.joined(separator: " ")) }
        default:
            e.lines.append(String(format: "HFNPDU Typ 0x%02X", b[1]))
        }
    }

    // MARK: ACARS im HFNPDU

    static func acars(_ p: [UInt8], into e: inout HFDLEvent) {
        // p: Bytes nach SOH, am Ende ETX/ETB, Prüfbytes, DEL
        guard p.count >= 16, p.last == 0x7F else {
            e.lines.append("ACARS-Block unlesbar (\(p.count) Bytes)")
            return
        }
        let n = p.count
        let block = ACARSBlock(bytes: Array(p[0..<(n - 3)]), crc: (p[n - 3], p[n - 2]), levelDB: e.snrDB)
        guard let m = ACARSParser.parse(block, at: e.time) else {
            e.lines.append("ACARS-Block mit Prüfsummenfehler")
            return
        }
        e.acars = m
        if !m.registration.isEmpty { e.registration = m.registration }
        if let f = m.flightID, !f.isEmpty { e.flightID = f }
        if let adv = mediaAdvisory(m.text), m.label == "SA" {
            e.lines.append(adv)
        }
        if e.position == nil, m.isDownlink || m.label == "HX", let p = ACARSPositionParser.parse(label: m.label, text: m.text) {
            e.position = p.point
            e.positionTime = p.timeUTC
        }
    }

    private static let linkTypes: [Character: String] = [
        "V": "VHF-ACARS", "S": "Satcom (Standard)", "H": "HF", "G": "Globalstar", "C": "ICO-Satcom", "2": "VDL2", "X": "Inmarsat Aero H/H+/I/L", "I": "Iridium"
    ]

    /// Medienhinweis (Label SA): „0LV211842SH/“ = Version 0, Verbindung verloren (L), VHF, 21:18:42, verfügbar: Satcom, HF
    static func mediaAdvisory(_ t: String) -> String? {
        let c = Array(t)
        guard c.count >= 10, c[0] == "0", c[1] == "E" || c[1] == "L", let cur = linkTypes[c[2]],
              c[3...8].allSatisfy(\.isNumber) else { return nil }
        let time = "\(c[3])\(c[4]):\(c[5])\(c[6]):\(c[7])\(c[8])"
        var avail: [String] = []
        var i = 9
        while i < c.count && c[i] != "/" {
            guard let n = linkTypes[c[i]] else { return nil }
            avail.append(n); i += 1
        }
        var s = "Medienhinweis: \(cur) \(c[1] == "E" ? "aufgebaut" : "verloren") um \(time) UTC; verfügbar: \(avail.joined(separator: ", "))"
        if i + 1 < c.count { s += "; Text: " + String(c[(i + 1)...]) }
        return s
    }
}
