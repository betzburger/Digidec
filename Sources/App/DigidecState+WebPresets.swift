// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - Web-Dashboard: Auswahllisten der Module (Kanäle, Bänder, Betriebsarten, Sender)

/// Was in der App die Kanal-, Band- und Senderlisten der Modulkarten sind, bekommt der Browser als Auswahlmenüs in einer Zeile.
/// Gewählt wird über dieselben Einstellungen wie in der App; der Funkgerät-/SDR-Nachlauf (QSY AUTO, „FOLGT MODUL“) greift wie dort.
extension DigidecState {
    private typealias Option = WebPresetGroup.Option

    private func mhz(_ hz: Double, _ digits: Int = 4) -> String {
        String(format: "%.\(digits)f", hz / 1e6).replacingOccurrences(of: ".", with: ",")
    }

    public var webPresets: [WebPresetGroup] {
        switch activeModule {
        case .rtty:
            var out = [WebPresetGroup(key: "preset", label: "PRESET", options: rtty.presets.map { Option(id: $0.id, label: $0.name) }, selected: rtty.presetID)]
            let freqs = rtty.preset.frequencies
            if !freqs.isEmpty {
                var opts = [Option(id: "auto", label: rtty.presetID.hasPrefix("dwd") ? "Automatik (Tageszeit)" : "—")]
                opts += freqs.map { Option(id: String(Int($0.hz.rounded())), label: "\($0.label) · \(mhz($0.hz, 4)) MHz" + ($0.callsign.isEmpty ? "" : " · \($0.callsign)")) }
                let sel = rtty.selectedFrequencyHz.map { String(Int($0.rounded())) } ?? "auto"
                out.append(WebPresetGroup(key: "frequency", label: "FREQUENZ", options: opts, selected: sel))
            }
            return out
        case .navtex:
            return [WebPresetGroup(key: "frequency", label: "FREQUENZ", options: navtex.frequencies.map { Option(id: $0.id, label: $0.label + ($0.note.isEmpty ? "" : " · \($0.note)")) }, selected: navtex.selectedFrequencyID)]
        case .psk:
            return [
                WebPresetGroup(key: "mode", label: "MODUS", options: PSKMode.allCases.map { Option(id: $0.rawValue, label: $0.displayName) }, selected: psk.options.mode.rawValue),
                WebPresetGroup(key: "band", label: "BAND", options: psk.bands.map { Option(id: $0.id, label: $0.name) }, selected: psk.selectedBandID)
            ]
        case .skimmer:
            var out = [WebPresetGroup(key: "mode", label: "MODUS", options: SkimMode.allCases.map { Option(id: $0.rawValue, label: $0.name) }, selected: skimmer.mode.rawValue)]
            if skimmer.mode == .cw {
                out.append(WebPresetGroup(key: "band", label: "BAND", options: SkimBand.allCases.map { Option(id: $0.rawValue, label: $0.rawValue) }, selected: skimmer.cwBand.rawValue))
            } else {
                out.append(WebPresetGroup(key: "band", label: "BAND", options: PSKBand.allCases.map { Option(id: $0.rawValue, label: $0.rawValue) }, selected: skimmer.pskBand.rawValue))
            }
            return out
        case .olivia:
            let opts = DecoderModuleInfo.olivia.presetIDs.compactMap { id in FldigiOliviaCore.Options(presetID: id).map { Option(id: id, label: "\($0.familyName) \($0.label)") } }
            return [WebPresetGroup(key: "preset", label: "MODUS", options: opts, selected: olivia.options.presetID)]
        case .mt63:
            let opts = DecoderModuleInfo.mt63.presetIDs.compactMap { id in FldigiMT63Core.Options(presetID: id).map { Option(id: id, label: "MT63-\($0.label)") } }
            return [WebPresetGroup(key: "preset", label: "MODUS", options: opts, selected: mt63.options.presetID)]
        case .mfsk:
            return [WebPresetGroup(key: "mode", label: "MODUS", options: MFSKMode.allCases.map { Option(id: $0.rawValue, label: $0.displayName) }, selected: mfsk.options.mode.rawValue)]
        case .hell:
            return [WebPresetGroup(key: "mode", label: "MODUS", options: HellMode.allCases.map { Option(id: $0.rawValue, label: $0.displayName) }, selected: hell.options.mode.rawValue)]
        case .dsc:
            return [WebPresetGroup(key: "channel", label: "KANAL", options: dsc.channels.map { Option(id: $0.id, label: $0.label) }, selected: dsc.selectedChannelID)]
        case .aprs:
            return [WebPresetGroup(key: "channel", label: "KANAL", options: APRSChannel.allCases.map { Option(id: $0.rawValue, label: $0.frequencyHz == nil ? $0.label : "\($0.label) MHz") }, selected: aprs.channel.rawValue)]
        case .packet:
            return [WebPresetGroup(key: "channel", label: "KANAL", options: packet.channels.map { Option(id: $0.id, label: $0.name) }, selected: packet.selectedChannelID)]
        case .acars:
            return [WebPresetGroup(key: "channel", label: "KANAL", options: acars.channels.map { Option(id: $0.id, label: $0.name) }, selected: acars.selectedChannelID)]
        case .ais:
            return [WebPresetGroup(key: "channel", label: "KANAL", options: AISChannel.allCases.map { Option(id: $0.rawValue, label: $0.label) }, selected: ais.channel.rawValue)]
        case .pager:
            return [WebPresetGroup(key: "channel", label: "KANAL", options: pager.channels.map { Option(id: $0.id, label: $0.name) }, selected: pager.selectedChannelID)]
        case .freedv:
            return [WebPresetGroup(key: "mode", label: "MODUS", options: FreeDVMode.allCases.map { Option(id: String($0.rawValue), label: $0.title) }, selected: String(freedv.mode.rawValue))]
        case .hfdl:
            let all = HFDLStations.channels.map(\.kHz)
            return [WebPresetGroup(key: "channel", label: "KANAL", options: all.map { Option(id: HFDLChannels.presetID($0), label: HFDLChannels.label($0) + " kHz") }, selected: HFDLChannels.presetID(hfdl.frequencyKHz))]
        case .wefax:
            return [WebPresetGroup(key: "station", label: "SENDER", options: wefax.stations.map { Option(id: $0.id, label: $0.label) }, selected: wefax.selectedStationID)]
        case .sstv:
            return [WebPresetGroup(key: "channel", label: "KANAL", options: sstv.channels.map { Option(id: $0.id, label: $0.name) }, selected: sstv.selectedChannelID)]
        case .efr:
            return [WebPresetGroup(key: "station", label: "SENDER", options: EFRStation.allCases.map { Option(id: $0.rawValue, label: $0.name) }, selected: efr.station.rawValue)]
        case .ft8:
            return [WebPresetGroup(key: "band", label: "BAND", options: FT8Band.allCases.map { Option(id: $0.rawValue, label: "\($0.rawValue) · \(mhz(Double($0.dialHz), 3)) MHz") }, selected: ft8.band.rawValue)]
        case .ft4:
            return [WebPresetGroup(key: "band", label: "BAND", options: FT4Band.available(for: .ft4).map { Option(id: $0.rawValue, label: $0.rawValue) }, selected: ft4.band.rawValue)]
        case .ft2:
            return [WebPresetGroup(key: "band", label: "BAND", options: FT4Band.available(for: .ft2).map { Option(id: $0.rawValue, label: $0.rawValue) }, selected: ft2.band.rawValue)]
        case .wspr:
            return [WebPresetGroup(key: "band", label: "BAND", options: WSPRBand.allCases.map { Option(id: $0.rawValue, label: $0.rawValue) }, selected: wspr.band.rawValue)]
        case .js8:
            return [WebPresetGroup(key: "band", label: "BAND", options: JS8Band.allCases.map { Option(id: $0.rawValue, label: $0.rawValue) }, selected: js8.band.rawValue)]
        case .rds:
            var opts: [Option] = rds.favorites.map { Option(id: String(Int($0.frequencyHz.rounded())), label: ($0.name.isEmpty ? "" : "★ \($0.name) · ") + "\(mhz($0.frequencyHz, 1)) MHz") }
            for p in DecoderModuleInfo.rds.presetIDs {
                guard let f = Double(p) else { continue }
                let id = String(Int((f * 1e6).rounded()))
                if !opts.contains(where: { $0.id == id }) { opts.append(Option(id: id, label: "\(mhz(f * 1e6, 1)) MHz")) }
            }
            return [WebPresetGroup(key: "frequency", label: "SENDER", options: opts, selected: String(Int(rds.frequencyHz.rounded())))]
        case .dab:
            let found = Dictionary(uniqueKeysWithValues: dabController.scanResults.map { ($0.block, $0) })
            var out = [WebPresetGroup(key: "block", label: "BLOCK", options: DABBlock.all.map { b in
                Option(id: b.name, label: b.title + (found[b.name].map { " · \($0.label) (\($0.serviceCount))" } ?? ""))
            }, selected: dab.blockName)]
            let services = dabController.snapshot.services
            if !services.isEmpty {
                out.append(WebPresetGroup(key: "service", label: "DIENST", options: services.map { Option(id: String($0.sid), label: $0.label.trimmingCharacters(in: .whitespaces) + ($0.isDABPlus ? " (DAB+)" : "")) }, selected: String(dab.selectedSID)))
            }
            let scanLabel = dabController.scanning ? "Suchlauf abbrechen" + (dabController.scanText.isEmpty ? "" : " · \(dabController.scanText)") : "Suchlauf über alle Blöcke starten"
            out.append(WebPresetGroup(key: "scan", label: "SUCHLAUF", options: [Option(id: "toggle", label: scanLabel)], selected: ""))
            return out
        case .sensors:
            return [WebPresetGroup(key: "band", label: "BAND", options: SensorBand.allCases.map { Option(id: $0.rawValue, label: $0.title) }, selected: sensors.band.rawValue)]
        case .vdl2:
            let sel = vdl2.channels.sorted()
            let id = sel == VDL2Channels.europe.sorted() ? "europa" : sel == VDL2Channels.all.sorted() ? "alle" : sel == [VDL2.commonSignallingChannel / 1e6] ? "csc" : ""
            return [WebPresetGroup(key: "channels", label: "KANÄLE", options: [Option(id: "europa", label: "Europa (6 Kanäle)"), Option(id: "csc", label: "Nur 136,975 MHz"), Option(id: "alle", label: "Alle Kanäle")], selected: id)]
        case .vor:
            return [WebPresetGroup(key: "kind", label: "ANZEIGE", options: ILSKind.allCases.map { Option(id: $0.rawValue, label: $0.title) }, selected: nav.ilsKind.rawValue)]
        case .cw, .ale, .ndb, .dcf77, .dstar, .ysf, .dmr, .dpmr, .nxdn, .p25, .tetra, .m17, .adsb, .sonde, .tones, .drm, .channels:
            return []
        }
    }

    public func setPreset(key: String, id: String) {
        switch activeModule {
        case .rtty:
            if key == "preset" { rtty.select(presetID: id) }
            else if key == "frequency" {
                let hz = id == "auto" ? nil : rtty.preset.frequencies.first { String(Int($0.hz.rounded())) == id }?.hz
                rtty.selectFrequency(hz, presetID: rtty.presetID)
                tuneRigForActiveModule()
            }
        case .navtex:
            if navtex.frequencies.contains(where: { $0.id == id }) { navtex.selectedFrequencyID = id }
        case .psk:
            if key == "mode", let m = PSKMode(rawValue: id) { psk.options.mode = m }
            else if key == "band", psk.bands.contains(where: { $0.id == id }) { psk.selectedBandID = id }
        case .skimmer:
            if key == "mode", let m = SkimMode(rawValue: id) { skimmer.mode = m }
            else if key == "band" {
                if skimmer.mode == .cw { if let b = SkimBand(rawValue: id) { skimmer.cwBand = b } }
                else if let b = PSKBand(rawValue: id) { skimmer.pskBand = b }
            }
        case .olivia:
            if let o = FldigiOliviaCore.Options(presetID: id) { olivia.options = o }
        case .mt63:
            if let o = FldigiMT63Core.Options(presetID: id) { mt63.options = o }
        case .mfsk:
            if let m = MFSKMode(rawValue: id) { mfsk.options.mode = m }
        case .hell:
            if let m = HellMode(rawValue: id) { hell.options.mode = m }
        case .dsc:
            if dsc.channels.contains(where: { $0.id == id }) { dsc.selectedChannelID = id }
        case .aprs:
            if let c = APRSChannel(rawValue: id) { aprs.channel = c }
        case .packet:
            if packet.channels.contains(where: { $0.id == id }) { packet.selectedChannelID = id }
        case .acars:
            if acars.channels.contains(where: { $0.id == id }) { acars.selectedChannelID = id }
        case .ais:
            if let c = AISChannel(rawValue: id) { ais.channel = c }
        case .pager:
            if pager.channels.contains(where: { $0.id == id }) { pager.selectedChannelID = id }
        case .freedv:
            if let raw = Int32(id), let m = FreeDVMode(rawValue: raw) { freedv.mode = m }
        case .hfdl:
            if let f = HFDLChannels.kHz(presetID: id) { hfdl.frequencyKHz = f }
        case .wefax:
            if wefax.stations.contains(where: { $0.id == id }) { wefax.selectedStationID = id }
        case .sstv:
            if sstv.channels.contains(where: { $0.id == id }) { sstv.selectedChannelID = id }
        case .efr:
            if let s = EFRStation(rawValue: id) { efr.station = s }
        case .ft8:
            if let b = FT8Band(rawValue: id) { ft8.band = b }
        case .ft4:
            if let b = FT4Band(rawValue: id), b.dialHz(for: .ft4) != nil { ft4.band = b }
        case .ft2:
            if let b = FT4Band(rawValue: id), b.dialHz(for: .ft2) != nil { ft2.band = b }
        case .wspr:
            if let b = WSPRBand(rawValue: id) { wspr.band = b }
        case .js8:
            if let b = JS8Band(rawValue: id) { js8.band = b }
        case .rds:
            if let hz = Double(id) { rdsController.tune(frequencyHz: hz) }
        case .dab:
            if key == "block", let b = DABBlock.named(id) { dabController.tune(block: b) }
            else if key == "scan" { if dabController.scanning { dabController.cancelScan() } else { dabController.startScan() } }
            else if key == "service", let sid = UInt32(id), let svc = dabController.snapshot.services.first(where: { $0.sid == sid }) { dabController.select(service: svc) }
        case .sensors:
            if let b = SensorBand(rawValue: id) { sensors.band = b }
        case .vdl2:
            switch id {
            case "csc": vdl2.channels = [VDL2.commonSignallingChannel / 1e6]
            case "alle": vdl2.channels = VDL2Channels.all
            case "europa": vdl2.channels = VDL2Channels.europe
            default: break
            }
        case .vor:
            if let k = ILSKind(rawValue: id) { nav.ilsKind = k }
        case .cw, .ale, .ndb, .dcf77, .dstar, .ysf, .dmr, .dpmr, .nxdn, .p25, .tetra, .m17, .adsb, .sonde, .tones, .drm, .channels:
            break
        }
    }
}
