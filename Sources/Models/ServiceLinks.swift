// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Verbindung zusammenhängender Dienste: dieselbe Station oder dasselbe Flugzeug erscheint in mehreren Modulen mit verschiedenen Kennungen.
// Flugzeuge: ADS-B kennt die 24-Bit-Adresse und das Rufzeichen („DLH123“), VDL2 Adresse, Kennzeichen und Flugnummer („LH123“), ACARS Kennzeichen und
// Flugnummer. Schiffe: AIS kennt die MMSI mit Name und Position, DSC nennt nur die MMSI. Hier steht die Zuordnung ohne Oberfläche, damit sie sich prüfen lässt.

/// Flugnummer (IATA, „LH123“) in das Rufzeichen des Flugverkehrs (ICAO, „DLH123“): die Fluggesellschaften der wichtigsten Strecken in Europa und weltweit
public enum AirlineCodes {
    /// IATA → ICAO
    public static let table: [String: String] = [
        "LH": "DLH", "EW": "EWG", "4U": "GWI", "DE": "CFG", "X3": "TUI", "BA": "BAW", "AF": "AFR", "KL": "KLM", "LX": "SWR", "OS": "AUA",
        "FR": "RYR", "U2": "EZY", "W6": "WZZ", "TK": "THY", "SK": "SAS", "AY": "FIN", "IB": "IBE", "AZ": "ITY", "LO": "LOT", "EK": "UAE",
        "QR": "QTR", "EY": "ETD", "TP": "TAP", "DY": "NOZ", "VY": "VLG", "SN": "BEL", "EI": "EIN", "TO": "TVF", "HV": "TRA", "PC": "PGT",
        "LS": "EXS", "BY": "TOM", "MT": "TCX", "OU": "CTN", "JU": "ASL", "RO": "ROT", "A3": "AEE", "OK": "CSA", "BT": "BTI", "KM": "AMC",
        "UA": "UAL", "AA": "AAL", "DL": "DAL", "AC": "ACA", "WN": "SWA", "B6": "JBU", "AS": "ASA", "NH": "ANA", "JL": "JAL", "SQ": "SIA",
        "CX": "CPA", "QF": "QFA", "EL": "ELB", "LA": "LAN", "AM": "AMX", "TG": "THA", "KE": "KAL", "OZ": "AAR", "CA": "CCA", "MU": "CES",
        "CZ": "CSN", "AI": "AIC", "SV": "SVA", "MS": "MSR", "ET": "ETH", "SA": "SAA", "RJ": "RJA", "GF": "GFA", "WY": "OMA", "5F": "FIA",
        "D8": "IBK", "V7": "VOE", "N0": "NRS", "FZ": "FDB", "XQ": "SXS", "PS": "AUI", "S7": "SBI", "SU": "AFL", "UT": "UTA", "BR": "EVA",
    ]

    /// „LH123“ → „DLH123“ (nil, wenn die Gesellschaft nicht bekannt ist oder keine Nummer folgt)
    public static func callsign(fromFlight flight: String) -> String? {
        let f = flight.trimmingCharacters(in: .whitespaces).uppercased()
        guard f.count >= 3 else { return nil }
        let prefix = String(f.prefix(2)), number = String(f.dropFirst(2))
        guard number.first?.isNumber == true, let icao = table[prefix] else { return nil }
        let digits = String(number.drop { $0 == "0" })
        return icao + (digits.isEmpty ? "0" : digits)
    }

    /// Zwei Rufzeichen derselben Nummer, auch mit führenden Nullen („DLH0123“ = „DLH123“)
    public static func sameCallsign(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespaces).uppercased()
            guard t.count > 3 else { return t }
            return String(t.prefix(3)) + t.dropFirst(3).drop { $0 == "0" }
        }
        return !a.isEmpty && norm(a) == norm(b)
    }
}

public enum ServiceLinks {
    /// Das ADS-B-Flugzeug zu einem ACARS- oder VDL2-Eintrag: erst über die Adresse (VDL2 kennt Kennzeichen und Adresse), dann über das Kennzeichen aus dem
    /// Flugzeugdatenblatt, zuletzt über die Flugnummer
    public static func aircraft(registration: String?, flight: String?, icao: UInt32? = nil, adsb: [ADSBAircraft], vdl2: [VDL2Aircraft] = [],
                                registrations: [UInt32: String] = [:]) -> ADSBAircraft? {
        let byICAO = Dictionary(adsb.map { ($0.icao, $0) }, uniquingKeysWith: { a, _ in a })
        if let icao, let a = byICAO[icao] { return a }
        let reg = registration?.trimmingCharacters(in: .whitespaces).uppercased().filter { $0 != "-" && $0 != "." } ?? ""
        if !reg.isEmpty {
            if let v = vdl2.first(where: { ($0.registration ?? "").uppercased().filter { $0 != "-" && $0 != "." } == reg }), let a = byICAO[v.address.address] { return a }
            if let pair = registrations.first(where: { $0.value.uppercased().filter { $0 != "-" && $0 != "." } == reg }), let a = byICAO[pair.key] { return a }
        }
        if let flight, !flight.isEmpty {
            let wanted = AirlineCodes.callsign(fromFlight: flight) ?? flight
            if let a = adsb.first(where: { $0.callsign.map { AirlineCodes.sameCallsign($0, wanted) } ?? false }) { return a }
        }
        return nil
    }

    /// „FL 380 · 112 km“, „am Boden“, „Kennung DLH123“ – eine kurze Angabe zum Flugzeug für die Meldungslisten
    public static func summary(of a: ADSBAircraft, from receiver: GeoPoint?) -> String {
        var parts: [String] = []
        if let alt = a.altitudeText { parts.append(alt) }
        if let p = a.position, let r = receiver { parts.append(String(format: "%.0f km", Geo.distanceKm(r, p))) }
        if parts.isEmpty { parts.append(a.callsign ?? a.icaoText) }
        return parts.joined(separator: " · ")
    }

    /// Name eines Schiffs zu einer MMSI aus dem DSC-Ruf (neun Ziffern)
    public static func vessel(mmsi text: String?, in vessels: [UInt32: AISVessel]) -> AISVessel? {
        guard let text, let value = UInt32(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        return vessels[value]
    }

    /// Anzeigename: Name, sonst Rufzeichen
    public static func label(of vessel: AISVessel) -> String? {
        let name = vessel.name?.trimmingCharacters(in: .whitespaces) ?? ""
        if !name.isEmpty { return name }
        let call = vessel.callsign?.trimmingCharacters(in: .whitespaces) ?? ""
        return call.isEmpty ? nil : call
    }
}
