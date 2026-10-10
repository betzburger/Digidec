// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - Web-Dashboard: Modulliste und Karte

extension DigidecState {
    /// Alle Module der Modulleiste der App außer MEHRKANAL: HF und VHF/UHF, darin A–Z
    public var webModules: [WebModuleEntry] {
        // MEHRKANAL (Kanalbank mit mehreren Decodern zugleich) gibt es nur in der App: dort wählt man Kanäle und Hörkanal am SDR-Fenster
        var out: [WebModuleEntry] = []
        for band in DecoderModuleInfo.Band.allCases {
            for m in band.modules where m.isAvailable {
                out.append(WebModuleEntry(id: m.id, name: m.displayName, group: band.title, hasMap: m.hasMap))
            }
        }
        return out
    }

    /// Karteninhalt des aktiven Moduls, derselbe wie in der Kartenansicht der App (`ModuleMapView`);
    /// ohne die Bedienung dort (Auswahl, Ebenenwahl: RTTY zeigt die Ebene „Symbol“ bzw. die gemerkte Ebene).
    public func webMapContent(now: Date) -> MapContent? {
        let home = self.home.point
        switch activeModule {
        case .adsb:   return adsbController.mapContent(home: home, now: now)
        case .aprs:   return aprsController.mapContent(home: home, now: now)
        case .acars:  return acarsController.mapContent(home: home, now: now)
        case .ais:    return aisController.mapContent(home: home, now: now)
        case .hfdl:   return hfdlController.mapContent(home: home, now: now)
        case .sonde:  return sondeController.mapContent(home: home, now: now)
        case .ft8:    return HeardMapBuilder.content(Self.heard(from: ft8Controller.entries), home: home, now: now, mode: "FT8", maxAge: 3600)
        case .ft4:    return HeardMapBuilder.content(Self.heard(from: ft4Controller.entries), home: home, now: now, mode: ft4Controller.modeName, maxAge: 3600)
        case .ft2:    return HeardMapBuilder.content(Self.heard(from: ft2Controller.entries), home: home, now: now, mode: ft2Controller.modeName, maxAge: 3600)
        case .wspr:
            let heard: [HeardStation] = wsprController.entries.compactMap { e in
                let m = e.decode.message
                guard !m.isHashed, !m.call.isEmpty else { return nil }
                return HeardStation(call: m.call, grid: m.grid, dxcc: e.dxcc, snr: e.decode.snrDB, time: e.decode.slotStart, text: e.decode.text,
                                    mentionsMe: e.mentionsMe, rfHz: e.rfHz, powerDBm: m.powerDBm)
            }
            return HeardMapBuilder.content(heard, home: home, now: now, mode: "WSPR", maxAge: 6 * 3600)
        case .js8:
            let heard: [HeardStation] = js8Controller.stations.map { s in
                HeardStation(call: s.call, grid: s.grid, dxcc: s.dxcc, snr: s.snrDB, time: s.lastHeard, text: s.lastText,
                             mentionsMe: s.mentionsMe, count: s.count)
            }
            return HeardMapBuilder.content(heard, home: home, now: now, mode: "JS8", maxAge: 3600)
        case .dsc:    return DSCMapBuilder.content(dscController.messages, home: home, now: now)
        case .navtex: return NavtexMapBuilder.content(navtexController.entries, home: home, now: now)
        case .rtty:   return rttyWebMapContent(home: home, now: now)
        case .cw:     return Self.callContent(cwController.textModel, mode: "CW", home: home, now: now)
        case .psk:    return Self.callContent(pskController.textModel, mode: "PSK", home: home, now: now)
        case .olivia: return Self.callContent(oliviaController.textModel, mode: "Olivia", home: home, now: now)
        case .mt63:   return Self.callContent(mt63Controller.textModel, mode: "MT63", home: home, now: now)
        case .mfsk:   return Self.callContent(mfskController.textModel, mode: mfsk.options.mode.family.title, home: home, now: now)
        case .skimmer:
            return HeardMapBuilder.content(skimmerController.heard, home: home, now: now, mode: skimmer.mode.name,
                                           emptyHint: "Noch kein Rufzeichen gehört (nach CQ oder DE, oder mehrfach)")
        case .wefax:  return TransmitterMap.content(Transmitters.dwd("wefax", frequency: "\(wefax.station.label) kHz"), home: home)
        case .dcf77:  return TransmitterMap.content(Transmitters.dcf77(), home: home)
        case .efr:    return TransmitterMap.content(Transmitters.efr(efr.station), home: home)
        case .ndb:    return ndbController.mapContent(now: now)
        case .dstar:  return dstarController.positions.mapContent(home: home, now: now, selection: nil,
                                                                  hint: "Noch keine DPRS-Position empfangen (Langsamdaten der Aussendungen)")
        case .m17:    return m17Controller.positions.mapContent(home: home, now: now, selection: nil,
                                                                hint: "Noch keine Position empfangen (M17-Zusatzdaten)")
        case .sstv, .ale, .pager, .tones, .hell, .packet, .ysf, .dmr, .dpmr, .nxdn, .p25, .drm, .tetra, .sensors, .vdl2, .dab, .vor, .freedv, .channels, .rds:
            return nil
        }
    }

    private static func heard(from entries: [FT8Entry]) -> [HeardStation] {
        entries.compactMap { e in
            let d = e.decode, m = d.message
            guard !d.isUncertain, let call = m.sender, !FT8Message.isHashed(call) else { return nil }
            return HeardStation(call: call, grid: m.grid, dxcc: e.dxcc, snr: d.snrDB, time: d.cycleStart, text: d.text,
                                isCQ: m.isCQ, mentionsMe: e.mentionsMe)
        }
    }

    private static func heard(from entries: [FT4Entry]) -> [HeardStation] {
        entries.compactMap { e in
            let d = e.decode, m = d.message
            guard !d.isUncertain, let call = m.sender, !FT8Message.isHashed(call) else { return nil }
            return HeardStation(call: call, grid: m.grid, dxcc: e.dxcc, snr: d.snrDB, time: d.cycleStart, text: d.text,
                                isCQ: m.isCQ, mentionsMe: e.mentionsMe)
        }
    }

    private static func callContent(_ model: ReceiveTextModel, mode: String, home: GeoPoint?, now: Date) -> MapContent {
        HeardMapBuilder.content(model.calls.heard, home: home, now: now, mode: mode,
                                emptyHint: "Noch kein Rufzeichen im Text erkannt (nach CQ oder DE, oder mehrfach)")
    }

    /// RTTY wie `RTTYMapView.content(now:)`: Wetterlage (SYNOP/See) aus der gemerkten Ebene, dazu Rufzeichen
    private func rttyWebMapContent(home: GeoPoint?, now: Date) -> MapContent {
        let layer = SynopLog.Layer(rawValue: UserDefaults.standard.string(forKey: "synopLayer") ?? "") ?? .symbol
        let overlay = SynopOverlayOptions(isobarStepHPa: UserDefaults.standard.integer(forKey: "synopIsobarStep"),
                                          temperatureField: UserDefaults.standard.bool(forKey: "synopTempField"))
        let model = rttyController.textModel
        let sites: [TransmitterSite]
        switch rtty.presetID {
        case "dwd-kw": sites = Transmitters.dwd("rtty", frequency: "DDK2 4583 kHz · DDH7 7646 kHz · DDK9 10100,8 kHz · DDH9 11039 kHz · DDH8 14467,3 kHz")
        case "dwd-lw": sites = Transmitters.dwd("rtty", frequency: "DDH47 147,3 kHz")
        default:       sites = []
        }
        var content = layer == .sea
            ? model.sea.content(home: home, now: now, transmitters: sites)
            : model.synop.content(home: home, now: now, transmitters: sites, layer: layer, overlay: overlay)
        if layer != .sea { content.markers += model.sea.pointMarkers(home: home, layer: layer) }
        let calls = HeardMapBuilder.content(model.calls.heard, home: home, now: now, mode: "RTTY")
        content.markers += calls.markers
        content.lines += calls.lines
        if layer != .sea && content.markers.isEmpty {
            content.emptyHint = "Noch keine SYNOP-Meldung, Punktvorhersage oder kein Rufzeichen mit Ort empfangen"
        }
        return content
    }
}
