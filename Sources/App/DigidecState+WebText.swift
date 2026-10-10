// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - Web-Dashboard: Text und Listen der Module

/// Was der Browser statt der Listen und Bilder der App zeigt: je Modul der Empfangstext bzw. eine Zeilenliste aus demselben Zustand,
/// den die App darstellt. Der Browser bekommt den Stand beim Umschalten komplett und danach nur Änderungen.
extension DigidecState {
    private static let utcTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func hms(_ d: Date) -> String { utcTime.string(from: d) }

    private static func num(_ v: Double?, _ format: String, _ unit: String = "") -> String {
        guard let v else { return "" }
        return String(format: format, v).replacingOccurrences(of: ".", with: ",") + unit
    }

    /// Mehrzeiliger Text in Zeilen, ohne die Endmarke
    private static func textLines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).replacingOccurrences(of: "\r", with: "") }
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func log(_ title: String, _ lines: [String]) -> WebTranscript {
        .limited(kind: .log, title: title, lines: lines)
    }

    private func list(_ title: String, _ lines: [String]) -> WebTranscript {
        .limited(kind: .list, title: title, lines: lines)
    }

    private func stream(_ title: String, _ model: ReceiveTextModel) -> WebTranscript {
        log(title, Self.textLines(model.text))
    }

    /// Titel der Hauptansicht des Moduls (wie in der App)
    public var webPanelTitle: String {
        switch activeModule {
        case .aprs: return "APRS Stationen"
        case .packet: return "Packet-Radio"
        case .adsb: return "Flugzeuge"
        case .acars: return "ACARS Meldungen"
        case .ais: return "AIS Schiffe"
        case .dstar: return "D-Star Aussendungen"
        case .ysf: return "YSF Aussendungen"
        case .dmr: return "DMR Gespräche"
        case .dpmr: return "dPMR Gespräche"
        case .nxdn: return "NXDN Gespräche"
        case .p25: return "P25 Gespräche"
        case .drm: return "DRM Dienste"
        case .tetra: return "TETRA Gespräche"
        case .ndb: return "NDB Funkfeuer"
        case .m17: return "M17 Gespräche"
        case .sensors: return "Funksensoren"
        case .dab: return "DAB Dienste"
        case .vdl2: return "VDL2 Flugzeuge"
        case .vor: return "VOR/ILS Messwerte"
        case .freedv: return "FreeDV Übertragungen"
        case .hfdl: return "HFDL Meldungen"
        case .skimmer: return "Skimmer Signale"
        case .sonde: return "Radiosonden"
        case .pager: return "Funkruf"
        case .tones: return "Tonfolgen"
        case .wefax: return "Wetterfax"
        case .sstv: return "SSTV Bild"
        case .ft8, .ft4, .ft2: return "Bandaktivität"
        case .wspr: return "WSPR Spots"
        case .js8: return "JS8 Aktivität"
        case .dsc: return "DSC Rufe"
        case .ale: return "ALE Aussendungen"
        case .dcf77: return "DCF77 Atomzeit"
        case .efr: return "EFR Rundsteuerung"
        case .rds: return "RDS Rundfunkdaten"
        case .channels: return "Mehrkanal"
        default: return "Empfangstext"
        }
    }

    public var webTranscript: WebTranscript {
        let title = webPanelTitle
        switch activeModule {

        // Textverfahren: der Empfangstext
        case .rtty:   return stream(title, rttyController.textModel)
        case .navtex: return stream(title, navtexController.textModel)
        case .cw:     return stream(title, cwController.textModel)
        case .psk:    return stream(title, pskController.textModel)
        case .olivia: return stream(title, oliviaController.textModel)
        case .mt63:   return stream(title, mt63Controller.textModel)
        case .mfsk:   return stream(title, mfskController.textModel)

        // Meldungen: ein Eintrag je Zeile, älteste zuerst
        case .dsc:    return log(title, dscController.messages.map { Self.trimmed(DSCController.logLine($0, dial: nil)) })
        case .ale:    return log(title, aleController.messages.map { Self.trimmed(ALEController.logLine($0)) })
        case .acars:  return log(title, acarsController.messages.map { Self.trimmed(ACARSController.logLine($0)) })
        case .hfdl:   return log(title, hfdlController.events.map { Self.trimmed(HFDLController.logLine($0)) })
        case .pager:  return log(title, pagerController.messages.map { Self.trimmed(PagerController.logLine($0)) })
        case .tones:
            return log(title, tonesController.sequences.map { "\(Self.hms($0.start))  \($0.standard.name)  \($0.text)" })
        case .packet:
            return log(title, packetController.monitor.map { "\(Self.hms($0.time))  \($0.line)" })
        case .aprs:
            return log(title, aprsController.packets.sorted { $0.time < $1.time }.map { "\(Self.hms($0.time))  \($0.tnc2)" })
        case .dstar:  return log(title, dstarController.transmissions.map { Self.trimmed(DStarController.logLine($0)) })
        case .ysf:    return log(title, ysfController.calls.map { Self.trimmed(YSFController.logLine($0)) })
        case .dmr:    return log(title, dmrController.calls.map { Self.trimmed(DMRController.logLine($0)) })
        case .dpmr:   return log(title, dpmrController.calls.map { Self.trimmed(DPMRController.logLine($0)) })
        case .nxdn:   return log(title, nxdnController.calls.map { Self.trimmed(NXDNController.logLine($0)) })
        case .p25:    return log(title, p25Controller.calls.map { Self.trimmed(P25Controller.logLine($0)) })
        case .m17:    return log(title, m17Controller.calls.map { Self.trimmed(M17Controller.logLine($0)) })
        case .freedv: return log(title, freedvController.transmissions.map { Self.trimmed(FreeDVController.logLine($0)) })
        case .sensors:
            return log(title, sensorsController.recent.map { Self.trimmed(SensorsController.logLine($0.event, summary: $0.summary, time: $0.time)) })
        case .vdl2:
            return log(title, vdl2Controller.recent.map { Self.trimmed(VDL2Controller.logLine($0.frame, summary: $0.summary, time: $0.time)) })
        case .tetra:
            return log(title, tetraController.snapshot.events.map {
                "\(Self.hms($0.time))  \(TETRAChannelPlan.title($0.frequency))  \($0.tetraTime)  \($0.kind)  \($0.text)"
            })

        // Funkverkehr auf Kurzwelle: ein Eintrag je Dekodierung
        case .ft8:  return log(title, ft8Controller.entries.map { Self.ft8Line($0.decode.cycleStart, $0.decode.snrDB, $0.decode.dt, $0.decode.freqHz, $0.decode.text, $0.mentionsMe, $0.dxcc?.name) })
        case .ft4:  return log(title, ft4Controller.entries.map { Self.ft8Line($0.decode.cycleStart, $0.decode.snrDB, $0.decode.dt, $0.decode.freqHz, $0.decode.text, $0.mentionsMe, $0.dxcc?.name) })
        case .ft2:  return log(title, ft2Controller.entries.map { Self.ft8Line($0.decode.cycleStart, $0.decode.snrDB, $0.decode.dt, $0.decode.freqHz, $0.decode.text, $0.mentionsMe, $0.dxcc?.name) })
        case .wspr:
            return log(title, wsprController.entries.map {
                let d = $0.decode
                return "\(Self.hms(d.slotStart))  \(String(format: "%+3d", d.snrDB)) dB  \(Self.num(d.dt, "%.1f", " s"))  \(Self.num($0.rfHz / 1e6, "%.6f", " MHz"))  \(d.text)" + ($0.dxcc.map { "  · \($0.name)" } ?? "")
            })
        case .js8:
            return log(title, js8Controller.lines.map {
                "\(Self.hms($0.start))  \(String(format: "%+3d", $0.snrDB)) dB  \(Self.num($0.freqHz, "%.0f", " Hz"))  \($0.text)"
            })
        case .skimmer:
            return list(title, skimmerController.stations.filter(\.isLive).sorted { $0.audioHz < $1.audioHz }.map {
                "\(String(format: "%4.0f", $0.audioHz)) Hz  \($0.mode.name)  \(Self.num($0.snrDB, "%.0f", " dB"))  \($0.call ?? "—")  \($0.text.suffix(48))"
            })

        // Bestandslisten: aktueller Stand
        case .adsb:
            let now = Date()
            let rows = adsbController.aircraft.sorted { $0.lastSeen > $1.lastSeen }.map { a -> String in
                let call = (a.callsign ?? "").padding(toLength: 8, withPad: " ", startingAt: 0)
                let alt = a.altitudeFt.map { String(format: "%6d ft", $0) } ?? "      — "
                let gs = a.groundSpeedKn.map { String(format: "%4.0f kn", $0) } ?? "   — "
                let trk = a.trackDeg.map { String(format: "%3.0f°", $0) } ?? " —°"
                let pos = a.position.map { String(format: "%.3f %.3f", $0.lat, $0.lon) } ?? "keine Position"
                let age = Int(now.timeIntervalSince(a.lastSeen))
                return "\(a.icaoText)  \(call)  \(alt)  \(gs)  \(trk)  \(a.squawk ?? "----")  \(pos)  \(a.messages) Mld  vor \(age) s"
            }
            let withPos = adsbController.aircraft.filter(\.hasPosition).count
            let head = "\(adsbController.aircraft.count) Flugzeuge · \(withPos) mit Position · \(Int(adsbController.stats.messagesPerSecond.rounded())) Meldungen/s · \(sdrStatusMessage)"
            return list(title, [head] + rows)
        case .ais:
            let rows = aisController.ships.sorted { $0.lastHeard > $1.lastHeard }.map { v -> String in
                let name = (v.name ?? "").padding(toLength: 20, withPad: " ", startingAt: 0)
                let sog = v.sog.map { String(format: "%4.1f kn", $0).replacingOccurrences(of: ".", with: ",") } ?? "   — "
                let cog = v.cog.map { String(format: "%3.0f°", $0) } ?? " —°"
                let pos = (v.latitude != nil && v.longitude != nil) ? String(format: "%.4f %.4f", v.latitude!, v.longitude!) : "keine Position"
                let kind = v.isBase ? "Basisstation" : v.isAid ? "Seezeichen" : v.isAircraft ? "Luftfahrzeug" : (v.isClassB ? "Klasse B" : "Klasse A")
                return "\(v.mmsi)  \(name)  \(sog)  \(cog)  \(pos)  \(kind)  \(v.messages) Mld"
            }
            return list(title, ["\(aisController.ships.count) Objekte · \(aisController.messageCount) Meldungen"] + rows)
        case .sonde:
            return list(title, sondeController.flights.sorted { $0.lastHeard > $1.lastHeard }.map { Self.trimmed(SondeController.logLine($0.latest)) })
        case .ndb:
            return list(title, ndbController.heard.sorted { $0.last > $1.last }.map { h in
                let name = h.station.map { "\($0.name) (\($0.country))" } ?? "unbekannt"
                return "\(h.ident)  \(NDBFormat.khzText(h.frequencyKHz))  \(name)  \(Self.num(h.snrDB, "%.0f", " dB"))  \(h.count)×" + (h.km.map { "  \(Geo.formatKm($0))" } ?? "") + (h.confirmedByList ? "  bestätigt" : "")
            })

        // Zeit- und Steuersignale
        case .dcf77:
            var rows: [String] = []
            if let s = dcf77Controller.status { rows.append("Signal: \(s)") }
            for t in dcf77Controller.decodedHistory {
                rows.append(String(format: "%02d.%02d.%04d  %02d:%02d  %@  %@", t.day, t.month, t.year, t.hour, t.minute, t.timeZoneName, t.weekdayName))
            }
            return list(title, rows)
        case .efr:
            var rows: [String] = []
            if let st = efrController.status {
                rows.append(String(format: "Signal %.0f %%  SNR %.1f dB  %d Telegramme", st.signalLevel, st.snrDb, st.telegramsDecoded))
            }
            for t in efrController.telegrams.reversed() {
                rows.append("\(t.formattedTime)  \(t.title)" + (t.summary.isEmpty ? "" : " · \(t.summary)") + (t.repeats > 0 ? "  (\(t.repeats)× wiederholt)" : ""))
            }
            return list(title, rows)

        // Rundfunk
        case .rds:
            let i = rdsController.info
            var rows: [String] = []
            rows.append(String(format: "Frequenz: %.1f MHz", rds.frequencyHz / 1e6).replacingOccurrences(of: ".", with: ","))
            if !i.programService.isEmpty { rows.append("Sender (PS): \(i.programService)") }
            if let pi = i.piHex { rows.append("PI: \(pi)" + (i.country.map { "  · \($0)" } ?? "")) }
            if let p = i.ptyName { rows.append("Programmart: \(p)") }
            if !i.radioText.isEmpty { rows.append("Radiotext: \(i.radioText)") }
            for h in i.radioTextHistory.suffix(12).reversed() where h != i.radioText { rows.append("   früher: \(h)") }
            if i.ta { rows.append("Verkehrsdurchsage (TA)") } else if i.tp { rows.append("Verkehrsfunk (TP)") }
            if let c = i.clockUTC { rows.append("Uhrzeit: " + Self.hms(c) + " UTC") }
            if !i.alternativeFrequencies.isEmpty {
                rows.append("Alternativfrequenzen (MHz): " + i.alternativeFrequencies.prefix(12).map { String(format: "%.1f", $0).replacingOccurrences(of: ".", with: ",") }.joined(separator: "  "))
            }
            if i.totalGroups == 0 { rows.append("Noch keine RDS-Gruppe empfangen") }
            return list(title, rows)
        case .dab:
            var rows: [String] = []
            let s = dabController.snapshot
            rows.append(s.synced ? "Ensemble: \(s.ensembleLabel)  ·  SNR \(Self.num(s.snrDB, "%.0f", " dB"))" : "Kein DAB-Signal im Block \(dab.block.name)")
            for svc in s.services { rows.append("\(String(format: "%04X", svc.sid))  \(svc.label)" + (svc.isDABPlus ? "  DAB+" : "")) }
            if !s.dynamicLabel.isEmpty { rows.append("Dynamic Label: \(s.dynamicLabel)") }
            if dabController.scanning || !dabController.scanResults.isEmpty {
                rows.append("")
                rows.append(dabController.scanning ? "Suchlauf: \(dabController.scanText)" : "Suchlauf-Ergebnis:")
                for r in dabController.scanResults { rows.append("  \(r.block)  \(r.label)  \(r.serviceCount) Dienste  SNR \(Self.num(r.snrDB, "%.0f", " dB"))") }
            }
            return list(title, rows)
        case .drm:
            var rows: [String] = []
            if !drmController.audioDescription.isEmpty { rows.append(drmController.audioDescription) }
            if !drmController.text.isEmpty { rows.append(contentsOf: Self.textLines(drmController.text)) }
            if !drmController.unsupportedReason.isEmpty { rows.append(drmController.unsupportedReason) }
            if rows.isEmpty { rows.append("Noch kein DRM-Dienst empfangen") }
            return list(title, rows)

        // Navigation
        case .vor:
            var rows: [String] = ["Betriebsart: \(navController.mode)"]
            if !navController.ident.isEmpty { rows.append("Kennung: \(navController.ident)" + (navController.identConfirmed ? " (bestätigt)" : "")) }
            rows.append(String(format: "Eingangspegel: %.0f dB", navController.inputDB))
            return list(title, rows)

        // Bilder: der Browser zeigt den Zustand als Text
        case .sstv:
            return list(title, ["\(sstvController.statusMessage)", "Bilder in der Galerie: \(sstvController.gallery.count)"])
        case .wefax:
            return list(title, [wefaxController.status.map { "\($0)" } ?? "Bereit", "Zeilen empfangen: \(wefaxController.liveRows)", "Bilder in der Galerie: \(wefaxController.gallery.count)"])
        case .hell:
            return list(title, ["Hell-Schreiber: Das Bild zeigt nur die App"])
        case .channels:
            return list(title, ["MEHRKANAL gibt es nur in der App"])
        }
    }

    private static func ft8Line(_ time: Date, _ snr: Int, _ dt: Double, _ freq: Double, _ text: String, _ me: Bool, _ country: String?) -> String {
        "\(hms(time))  \(String(format: "%+3d", snr))  \(num(dt, "%.1f"))  \(String(format: "%4.0f", freq))  \(text)" + (country.map { "  · \($0)" } ?? "") + (me ? "  ◀" : "")
    }
}
