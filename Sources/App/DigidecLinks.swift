// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Verbindung zusammenhängender Dienste im Programmzustand: sammelt Flugzeuge, Schiffe und Rufe aus den Modulen und aus den Kanälen der Kanalbank
// und liefert die Zuordnung aus `ServiceLinks` für die Listen (ACARS, VDL2, DSC, AIS, ADS-B).

extension DigidecState {
    /// Alle gehörten Schiffe: Modul AIS und AIS-Kanäle der Kanalbank (z. B. A und B getrennt)
    var linkedVessels: [UInt32: AISVessel] {
        var all: [UInt32: AISVessel] = [:]
        for c in [aisController] + channelHub.controllers(of: AISController.self) {
            for v in c.ships { if let old = all[v.mmsi], old.lastHeard >= v.lastHeard { continue }; all[v.mmsi] = v }
        }
        return all
    }

    var linkedDSCMessages: [DSCMessage] {
        ([dscController] + channelHub.controllers(of: DSCController.self)).flatMap(\.messages)
    }

    /// Alle ADS-B-Flugzeuge (Modul ADS-B)
    var linkedAircraft: [ADSBAircraft] { adsbController.aircraft }

    /// Name des Schiffs zu einer MMSI aus einem DSC-Ruf, falls es per AIS gehört wurde
    func vesselLabel(mmsi: String?) -> String? {
        ServiceLinks.vessel(mmsi: mmsi, in: linkedVessels).flatMap(ServiceLinks.label(of:))
    }

    /// Wurde zu dieser MMSI ein Seenot-Ruf (DSC) gehört? Der neueste.
    func distressCall(mmsi: UInt32) -> DSCMessage? {
        linkedDSCMessages.last { $0.isDistress && $0.from.flatMap { UInt32($0.trimmingCharacters(in: .whitespaces)) } == mmsi }
    }

    /// ADS-B-Flugzeug zu einer ACARS-Meldung
    func aircraft(for m: ACARSMessage) -> ADSBAircraft? {
        ServiceLinks.aircraft(registration: m.registration, flight: m.flightID, adsb: linkedAircraft, vdl2: vdl2Controller.aircraft,
                              registrations: adsbController.details.compactMapValues(\.registration))
    }

    /// Kurzangabe zum Flugzeug einer ACARS-Meldung („FL 380 · 112 km“), leer ohne ADS-B-Treffer
    func aircraftSummary(for m: ACARSMessage) -> String? {
        aircraft(for: m).map { ServiceLinks.summary(of: $0, from: home.point) }
    }

    /// Kurzangabe zum Flugzeug eines VDL2-Eintrags (Adresse = ICAO-Adresse)
    func aircraftSummary(for v: VDL2Aircraft) -> String? {
        let a = ServiceLinks.aircraft(registration: v.registration, flight: v.flight, icao: v.address.address, adsb: linkedAircraft)
        return a.map { ServiceLinks.summary(of: $0, from: home.point) }
    }

    /// Meldungen (ACARS) zu einem ADS-B-Flugzeug, neueste zuletzt
    func acarsMessages(for a: ADSBAircraft) -> [ACARSMessage] {
        let registrations = adsbController.details[a.icao]?.registration
        let vdl = vdl2Controller.aircraft.first { $0.address.address == a.icao }
        let regs = Set([registrations, vdl?.registration].compactMap { $0?.uppercased() })
        let callsign = a.callsign
        return ([acarsController] + channelHub.controllers(of: ACARSController.self)).flatMap(\.messages).filter { m in
            if regs.contains(m.registration.uppercased()) { return true }
            if let cs = callsign, let f = m.flightID, let wanted = AirlineCodes.callsign(fromFlight: f) { return AirlineCodes.sameCallsign(cs, wanted) }
            return false
        }.sorted { $0.time < $1.time }
    }
}
