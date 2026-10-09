// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

public struct MainWindowView: View {
    @ObservedObject public var state: DigidecState
    @State private var showRTTYSettings = false
    @Environment(\.openWindow) private var openWindow

    public init(state: DigidecState) {
        self.state = state
    }

    /// Hauptbereich des aktiven Moduls ohne Karte (Liste, Text, Bild)
    @ViewBuilder
    private var mainPanel: some View {
        if state.activeModule == .navtex {
                                NavtexReceivePanel(controller: state.navtexController)
                            } else if state.activeModule == .cw {
                                CWReceivePanel(controller: state.cwController)
                            } else if state.activeModule == .olivia {
                                TextModeReceivePanel(controller: state.oliviaController)
                            } else if state.activeModule == .mt63 {
                                TextModeReceivePanel(controller: state.mt63Controller)
                            } else if state.activeModule == .mfsk {
                                TextModeReceivePanel(controller: state.mfskController)
                            } else if state.activeModule == .hell {
                                HellRasterPanel(controller: state.hellController, settings: state.hell)
                            } else if state.activeModule == .dsc {
                                DSCMessagePanel(controller: state.dscController)
                            } else if state.activeModule == .ale {
                                ALEMessagePanel(controller: state.aleController)
                            } else if state.activeModule == .aprs {
                                APRSMainPanel(controller: state.aprsController, settings: state.aprs, home: state.home)
                            } else if state.activeModule == .adsb {
                                ADSBMainPanel(controller: state.adsbController, settings: state.adsb, home: state.home)
                            } else if state.activeModule == .packet {
                                PacketMainPanel(controller: state.packetController, settings: state.packet)
                            } else if state.activeModule == .acars {
                                ACARSMessagePanel(controller: state.acarsController, settings: state.acars)
                            } else if state.activeModule == .ais {
                                AISMainPanel(controller: state.aisController, settings: state.ais, home: state.home)
                            } else if state.activeModule == .dstar {
                                DStarMainPanel(controller: state.dstarController, settings: state.dstar)
                            } else if state.activeModule == .ysf {
                                YSFMainPanel(controller: state.ysfController, settings: state.ysf, output: state.dstarController.output)
                            } else if state.activeModule == .dmr {
                                DMRMainPanel(controller: state.dmrController, settings: state.dmr, output: state.dstarController.output)
                            } else if state.activeModule == .dpmr {
                                DPMRMainPanel(controller: state.dpmrController, settings: state.dpmr, output: state.dstarController.output)
                            } else if state.activeModule == .nxdn {
                                NXDNMainPanel(controller: state.nxdnController, settings: state.nxdn, output: state.dstarController.output)
                            } else if state.activeModule == .p25 {
                                P25MainPanel(controller: state.p25Controller, settings: state.p25, output: state.dstarController.output)
                            } else if state.activeModule == .ndb {
                                NDBMainPanel(controller: state.ndbController, settings: state.ndb)
                            } else if state.activeModule == .tetra {
                                TETRAMainPanel(controller: state.tetraController, settings: state.tetra)
                            } else if state.activeModule == .sensors {
                                SensorsMainPanel(controller: state.sensorsController, settings: state.sensors)
                            } else if state.activeModule == .dab {
                                DABMainPanel(controller: state.dabController, settings: state.dab)
                            } else if state.activeModule == .rds {
                                RDSPanelView(controller: state.rdsController, settings: state.rds, sdr: state.sdrController)
                            } else if state.activeModule == .vdl2 {
                                VDL2MainPanel(controller: state.vdl2Controller, settings: state.vdl2)
                            } else if state.activeModule == .vor {
                                NavMainPanel(controller: state.navController, settings: state.nav)
                            } else if state.activeModule == .m17 {
                                M17MainPanel(controller: state.m17Controller, settings: state.m17)
                            } else if state.activeModule == .freedv {
                                FreeDVMainPanel(controller: state.freedvController, settings: state.freedv)
                            } else if state.activeModule == .drm {
                                DRMMainPanel(controller: state.drmController, settings: state.drm)
                            } else if state.activeModule == .hfdl {
                                HFDLMessagePanel(controller: state.hfdlController, settings: state.hfdl)
                            } else if state.activeModule == .sonde {
                                SondeMainPanel(controller: state.sondeController, settings: state.sonde, home: state.home)
                            } else if state.activeModule == .pager {
                                PagerMessagePanel(controller: state.pagerController, settings: state.pager)
                            } else if state.activeModule == .tones {
                                TonesListPanel(controller: state.tonesController, settings: state.tones)
                            } else if state.activeModule == .psk {
                                PSKReceivePanel(controller: state.pskController)
                            } else if state.activeModule == .skimmer {
                                SkimmerMainPanel(controller: state.skimmerController, settings: state.skimmer, openStation: { state.openSkimmerStation($0) })
                            } else if state.activeModule == .wefax {
                                WefaxImagePanel(controller: state.wefaxController, schedule: state.wefaxSchedule, auto: state.autoRecorder, openSchedule: { state.scheduleSheet = .wefax })
                            } else if state.activeModule == .ft8 {
                                FT8ActivityPanel(controller: state.ft8Controller, settings: state.ft8)
                            } else if state.activeModule == .ft4 {
                                FT4ActivityPanel(controller: state.ft4Controller, settings: state.ft4)
                            } else if state.activeModule == .wspr {
                                WSPRActivityPanel(controller: state.wsprController, settings: state.wspr)
                            } else if state.activeModule == .js8 {
                                JS8ActivityPanel(controller: state.js8Controller, settings: state.js8)
                            } else if state.activeModule == .dcf77 {
                                DCF77MainPanel(controller: state.dcf77Controller, settings: state.dcf77)
                            } else if state.activeModule == .efr {
                                EFRMainPanel(controller: state.efrController, settings: state.efr)
                            } else if state.activeModule == .sstv {
                                SSTVImagePanel(controller: state.sstvController)
                            } else if state.activeModule == .channels {
                                ChannelsMainPanel(hub: state.channelHub, bank: state.sdrController.bank, controller: state.sdrController)
                            } else {
                                ReceivePanel(controller: state.rttyController, settings: state.rtty)
                            }
    }

    public var body: some View {
        ZStack {
            RadioTheme.bgPanel.ignoresSafeArea()

            HStack(spacing: 0) {
            VStack(spacing: 10) {
                HeaderBar(state: state)
                ModuleBar(state: state)

                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 10) {
                        SDRWaterfallHost(audio: state.audio, settings: state.sdr, controller: state.sdrController, module: state.activeModule) {
                        Group {
                            if state.activeModule == .navtex {
                                WaterfallView(model: state.waterfall, rtty: state.navtex, audio: state.audio)
                            } else if state.activeModule == .cw {
                                WaterfallView(model: state.waterfall, rtty: state.cw, audio: state.audio)
                            } else if state.activeModule == .olivia {
                                WaterfallView(model: state.waterfall, rtty: state.olivia, audio: state.audio)
                            } else if state.activeModule == .mt63 {
                                WaterfallView(model: state.waterfall, rtty: state.mt63, audio: state.audio)
                            } else if state.activeModule == .mfsk {
                                WaterfallView(model: state.waterfall, rtty: state.mfsk, audio: state.audio)
                            } else if state.activeModule == .hell {
                                WaterfallView(model: state.waterfall, rtty: state.hell, audio: state.audio)
                            } else if state.activeModule == .dsc {
                                WaterfallView(model: state.waterfall, rtty: state.dsc, audio: state.audio)
                            } else if state.activeModule == .ale {
                                WaterfallView(model: state.waterfall, rtty: state.ale, audio: state.audio)
                            } else if state.activeModule == .aprs {
                                WaterfallView(model: state.waterfall, rtty: state.aprs, audio: state.audio)
                            } else if state.activeModule == .adsb {
                                ADSBScopePanel(controller: state.adsbController)
                            } else if state.activeModule == .sensors {
                                SensorsScopePanel(controller: state.sensorsController)
                            } else if state.activeModule == .tetra {
                                TETRAScopePanel(controller: state.tetraController)
                            } else if state.activeModule == .dab {
                                DABSpectrumPanel(controller: state.dabController, settings: state.dab)
                            } else if state.activeModule == .rds {
                                WaterfallView(model: state.waterfall, rtty: state.rds, audio: state.audio)
                            } else if state.activeModule == .vdl2 {
                                VDL2ScopePanel(controller: state.vdl2Controller)
                            } else if state.activeModule == .vor {
                                NavScopePanel(controller: state.navController, settings: state.nav)
                            } else if state.activeModule == .packet {
                                WaterfallView(model: state.waterfall, rtty: state.packet, audio: state.audio)
                            } else if state.activeModule == .acars {
                                WaterfallView(model: state.waterfall, rtty: state.acars, audio: state.audio)
                            } else if state.activeModule == .ais {
                                WaterfallView(model: state.waterfall, rtty: state.ais, audio: state.audio)
                            } else if state.activeModule == .dstar {
                                WaterfallView(model: state.waterfall, rtty: state.dstar, audio: state.audio)
                            } else if state.activeModule == .ysf {
                                WaterfallView(model: state.waterfall, rtty: state.ysf, audio: state.audio)
                            } else if state.activeModule == .dmr {
                                WaterfallView(model: state.waterfall, rtty: state.dmr, audio: state.audio)
                            } else if state.activeModule == .dpmr {
                                WaterfallView(model: state.waterfall, rtty: state.dpmr, audio: state.audio)
                            } else if state.activeModule == .nxdn {
                                WaterfallView(model: state.waterfall, rtty: state.nxdn, audio: state.audio)
                            } else if state.activeModule == .p25 {
                                WaterfallView(model: state.waterfall, rtty: state.p25, audio: state.audio)
                            } else if state.activeModule == .m17 {
                                WaterfallView(model: state.waterfall, rtty: state.m17, audio: state.audio)
                            } else if state.activeModule == .freedv {
                                WaterfallView(model: state.waterfall, rtty: state.freedv, audio: state.audio)
                            } else if state.activeModule == .drm {
                                WaterfallView(model: state.waterfall, rtty: state.drm, audio: state.audio)
                            } else if state.activeModule == .hfdl {
                                WaterfallView(model: state.waterfall, rtty: state.hfdl, audio: state.audio)
                            } else if state.activeModule == .sonde {
                                WaterfallView(model: state.waterfall, rtty: state.sonde, audio: state.audio)
                            } else if state.activeModule == .pager {
                                WaterfallView(model: state.waterfall, rtty: state.pager, audio: state.audio)
                            } else if state.activeModule == .tones {
                                WaterfallView(model: state.waterfall, rtty: state.tones, audio: state.audio)
                            } else if state.activeModule == .psk {
                                WaterfallView(model: state.waterfall, rtty: state.psk, audio: state.audio)
                            } else if state.activeModule == .skimmer {
                                WaterfallView(model: state.waterfall, rtty: state.skimmer, audio: state.audio)
                            } else if state.activeModule == .wefax {
                                WaterfallView(model: state.waterfall, rtty: state.wefax, audio: state.audio)
                            } else if state.activeModule == .ft8 {
                                WaterfallView(model: state.waterfall, rtty: state.ft8, audio: state.audio)
                            } else if state.activeModule == .ft4 {
                                WaterfallView(model: state.waterfall, rtty: state.ft4, audio: state.audio)
                            } else if state.activeModule == .wspr {
                                WaterfallView(model: state.waterfall, rtty: state.wspr, audio: state.audio)
                            } else if state.activeModule == .js8 {
                                WaterfallView(model: state.waterfall, rtty: state.js8, audio: state.audio)
                            } else if state.activeModule == .ndb {
                                WaterfallView(model: state.waterfall, rtty: state.ndb, audio: state.audio)
                            } else if state.activeModule == .dcf77 {
                                WaterfallView(model: state.waterfall, rtty: state.dcf77, audio: state.audio)
                            } else if state.activeModule == .efr {
                                WaterfallView(model: state.waterfall, rtty: state.efr, audio: state.audio)
                            } else if state.activeModule == .sstv {
                                WaterfallView(model: state.waterfall, rtty: state.sstv, audio: state.audio)
                            } else {
                                WaterfallView(model: state.waterfall, rtty: state.rtty, audio: state.audio)
                            }
                        }
                        }
                        .frame(height: 260)
                        .radioCard(title: state.activeModule == .adsb || state.activeModule == .sensors || state.activeModule == .vdl2 || state.activeModule == .tetra || state.activeModule == .vor || state.activeModule == .dab ? "Empfang" : state.activeModule == .channels ? "HF-Fenster" : "Wasserfall")

                        Group {
                            switch state.mapLayout(state.activeModule) {
                            case .list:
                                mainPanel
                            case .map:
                                ModuleMapView(state: state)
                            case .split:
                                GeometryReader { geo in
                                    VStack(spacing: 8) {
                                        mainPanel.frame(maxHeight: .infinity)
                                        ModuleMapView(state: state)
                                            .frame(height: max(190, geo.size.height * 0.42))
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: .infinity)
                        .radioCard(title: state.mapLayout(state.activeModule) == .map ? "Karte" : state.activeModule == .aprs ? "APRS Stationen" : state.activeModule == .packet ? "Packet-Radio" : state.activeModule == .adsb ? "Flugzeuge" : state.activeModule == .acars ? "ACARS Meldungen" : state.activeModule == .ais ? "AIS Schiffe" : state.activeModule == .dstar ? "D-Star Aussendungen" : state.activeModule == .ysf ? "YSF Aussendungen" : state.activeModule == .dmr ? "DMR Gespräche" : state.activeModule == .dpmr ? "dPMR Gespräche" : state.activeModule == .nxdn ? "NXDN Gespräche" : state.activeModule == .p25 ? "P25 Gespräche" : state.activeModule == .drm ? "DRM Dienste" : state.activeModule == .tetra ? "TETRA Gespräche" : state.activeModule == .ndb ? "NDB Funkfeuer" : state.activeModule == .m17 ? "M17 Gespräche" : state.activeModule == .sensors ? "Funksensoren" : state.activeModule == .dab ? "DAB Dienste" : state.activeModule == .vdl2 ? "VDL2 Flugzeuge" : state.activeModule == .vor ? "VOR/ILS Messwerte" : state.activeModule == .freedv ? "FreeDV Übertragungen" : state.activeModule == .hfdl ? "HFDL Meldungen" : state.activeModule == .skimmer ? "Skimmer Signale" : state.activeModule == .sonde ? "Radiosonden" : state.activeModule == .pager ? "Funkruf" : state.activeModule == .tones ? "Tonfolgen" : state.activeModule == .wefax ? "Wetterfax" : state.activeModule == .sstv ? "SSTV Bild" : (state.activeModule == .ft8 || state.activeModule == .ft4) ? "Bandaktivität" : state.activeModule == .wspr ? "WSPR Spots" : state.activeModule == .js8 ? "JS8 Aktivität" : state.activeModule == .dsc ? "DSC Rufe" : state.activeModule == .ale ? "ALE Aussendungen" : state.activeModule == .dcf77 ? "DCF77 Atomzeit" : state.activeModule == .efr ? "EFR Rundsteuerung" : state.activeModule == .channels ? "Mehrkanal" : "Empfangstext")
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 10) {
                        if state.activeModule == .navtex {
                            NavtexTuningPanel(controller: state.navtexController, settings: state.navtex)
                                .radioCard(title: "Abstimmanzeige")
                            NavtexSettingsPanel(settings: state.navtex)
                                .radioCard(title: "NAVTEX")
                            NavtexMessageList(controller: state.navtexController)
                                .radioCard(title: "Nachrichten")
                        } else if state.activeModule == .cw {
                            CWTuningPanel(controller: state.cwController, settings: state.cw)
                                .radioCard(title: "Abstimmanzeige")
                            CWSettingsPanel(settings: state.cw)
                                .radioCard(title: "CW")
                        } else if state.activeModule == .olivia {
                            OliviaTuningPanel(controller: state.oliviaController, settings: state.olivia)
                                .radioCard(title: "Abstimmanzeige")
                            OliviaSettingsPanel(settings: state.olivia)
                                .radioCard(title: "OLIVIA · CONTESTIA")
                        } else if state.activeModule == .ale {
                            ALETuningPanel(controller: state.aleController, settings: state.ale)
                                .radioCard(title: "Abstimmanzeige")
                            ALESettingsPanel(settings: state.ale)
                                .radioCard(title: "ALE")
                        } else if state.activeModule == .aprs {
                            APRSTuningPanel(controller: state.aprsController, settings: state.aprs)
                                .radioCard(title: "Abstimmanzeige")
                            APRSSettingsPanel(settings: state.aprs)
                                .radioCard(title: "APRS")
                        } else if state.activeModule == .adsb {
                            ADSBTuningPanel(controller: state.adsbController, settings: state.adsb)
                                .radioCard(title: "Abstimmanzeige")
                            ADSBSettingsPanel(controller: state.adsbController, settings: state.adsb)
                                .radioCard(title: "ADS-B")
                        } else if state.activeModule == .packet {
                            PacketTuningPanel(controller: state.packetController, settings: state.packet)
                                .radioCard(title: "Abstimmanzeige")
                            PacketSettingsPanel(settings: state.packet)
                                .radioCard(title: "PACKET")
                        } else if state.activeModule == .acars {
                            ACARSTuningPanel(controller: state.acarsController, settings: state.acars)
                                .radioCard(title: "Abstimmanzeige")
                            ACARSSettingsPanel(settings: state.acars)
                                .radioCard(title: "ACARS")
                        } else if state.activeModule == .ais {
                            AISTuningPanel(controller: state.aisController, settings: state.ais, home: state.home)
                                .radioCard(title: "Abstimmanzeige")
                            AISSettingsPanel(settings: state.ais)
                                .radioCard(title: "AIS")
                        } else if state.activeModule == .dstar {
                            DStarTuningPanel(controller: state.dstarController, settings: state.dstar)
                                .radioCard(title: "Abstimmanzeige")
                            DStarSettingsPanel(controller: state.dstarController, settings: state.dstar)
                                .radioCard(title: "D-STAR")
                        } else if state.activeModule == .ysf {
                            YSFTuningPanel(controller: state.ysfController, settings: state.ysf, output: state.dstarController.output)
                                .radioCard(title: "Abstimmanzeige")
                            YSFSettingsPanel(output: state.dstarController.output)
                                .radioCard(title: "YSF")
                        } else if state.activeModule == .dmr {
                            DMRTuningPanel(controller: state.dmrController, settings: state.dmr, output: state.dstarController.output)
                                .radioCard(title: "Abstimmanzeige")
                            DMRSettingsPanel(settings: state.dmr, output: state.dstarController.output)
                                .radioCard(title: "DMR")
                        } else if state.activeModule == .dpmr {
                            DPMRTuningPanel(controller: state.dpmrController, settings: state.dpmr, output: state.dstarController.output)
                                .radioCard(title: "Abstimmanzeige")
                            DPMRSettingsPanel(settings: state.dpmr, output: state.dstarController.output)
                                .radioCard(title: "dPMR")
                        } else if state.activeModule == .nxdn {
                            NXDNTuningPanel(controller: state.nxdnController, settings: state.nxdn, output: state.dstarController.output)
                                .radioCard(title: "Abstimmanzeige")
                            NXDNSettingsPanel(settings: state.nxdn, output: state.dstarController.output)
                                .radioCard(title: "NXDN")
                        } else if state.activeModule == .p25 {
                            P25TuningPanel(controller: state.p25Controller, settings: state.p25, output: state.dstarController.output)
                                .radioCard(title: "Abstimmanzeige")
                            P25SettingsPanel(settings: state.p25, output: state.dstarController.output)
                                .radioCard(title: "P25")
                        } else if state.activeModule == .sensors {
                            SensorsTuningPanel(controller: state.sensorsController, settings: state.sensors)
                                .radioCard(title: "Abstimmanzeige")
                            SensorsSettingsPanel(controller: state.sensorsController, settings: state.sensors)
                                .radioCard(title: "SENSOREN")
                        } else if state.activeModule == .tetra {
                            TETRATuningPanel(controller: state.tetraController, settings: state.tetra)
                                .radioCard(title: "Abstimmanzeige")
                            TETRASettingsPanel(controller: state.tetraController, settings: state.tetra)
                                .radioCard(title: "TETRA")
                        } else if state.activeModule == .channels {
                            ChannelsSettingsPanel(bank: state.sdrController.bank, settings: state.sdr, controller: state.sdrController)
                                .radioCard(title: "MEHRKANAL")
                        } else if state.activeModule == .dab {
                            DABTuningPanel(controller: state.dabController)
                                .radioCard(title: "Abstimmanzeige")
                            DABSettingsPanel(controller: state.dabController, settings: state.dab)
                                .radioCard(title: "DAB")
                        } else if state.activeModule == .rds {
                            RDSTuningPanel(controller: state.rdsController, settings: state.rds)
                                .radioCard(title: "Abstimmanzeige")
                            RDSSettingsPanel(controller: state.rdsController, settings: state.rds, sdr: state.sdrController)
                                .radioCard(title: "RDS")
                        } else if state.activeModule == .vdl2 {
                            VDL2TuningPanel(controller: state.vdl2Controller, settings: state.vdl2)
                                .radioCard(title: "Abstimmanzeige")
                            VDL2SettingsPanel(controller: state.vdl2Controller, settings: state.vdl2)
                                .radioCard(title: "VDL2")
                        } else if state.activeModule == .vor {
                            NavTuningPanel(controller: state.navController, settings: state.nav)
                                .radioCard(title: "Abstimmanzeige")
                            NavSettingsPanel(controller: state.navController, settings: state.nav)
                                .radioCard(title: "VOR/ILS")
                        } else if state.activeModule == .m17 {
                            M17TuningPanel(controller: state.m17Controller, settings: state.m17)
                                .radioCard(title: "Abstimmanzeige")
                            M17SettingsPanel(settings: state.m17)
                                .radioCard(title: "M17")
                        } else if state.activeModule == .freedv {
                            FreeDVTuningPanel(controller: state.freedvController, settings: state.freedv)
                                .radioCard(title: "Abstimmanzeige")
                            FreeDVSettingsPanel(settings: state.freedv)
                                .radioCard(title: "FREEDV")
                        } else if state.activeModule == .drm {
                            DRMTuningPanel(controller: state.drmController, settings: state.drm)
                                .radioCard(title: "Abstimmanzeige")
                            DRMSettingsPanel(settings: state.drm, controller: state.drmController)
                                .radioCard(title: "DRM")
                        } else if state.activeModule == .hfdl {
                            HFDLTuningPanel(controller: state.hfdlController, settings: state.hfdl)
                                .radioCard(title: "Abstimmanzeige")
                            HFDLSettingsPanel(controller: state.hfdlController, settings: state.hfdl)
                                .radioCard(title: "HFDL")
                        } else if state.activeModule == .sonde {
                            SondeTuningPanel(controller: state.sondeController, settings: state.sonde)
                                .radioCard(title: "Abstimmanzeige")
                            SondeSettingsPanel(controller: state.sondeController, settings: state.sonde, home: state.home, plan: state.sondePlan, scanner: state.sondeScanner)
                                .radioCard(title: "SONDE")
                        } else if state.activeModule == .pager {
                            PagerTuningPanel(controller: state.pagerController, settings: state.pager)
                                .radioCard(title: "Abstimmanzeige")
                            PagerSettingsPanel(settings: state.pager)
                                .radioCard(title: "PAGER")
                        } else if state.activeModule == .tones {
                            TonesTuningPanel(controller: state.tonesController, settings: state.tones)
                                .radioCard(title: "Abstimmanzeige")
                            TonesSettingsPanel(settings: state.tones)
                                .radioCard(title: "TÖNE")
                        } else if state.activeModule == .dsc {
                            DSCTuningPanel(controller: state.dscController, settings: state.dsc)
                                .radioCard(title: "Abstimmanzeige")
                            DSCSettingsPanel(settings: state.dsc)
                                .radioCard(title: "DSC")
                        } else if state.activeModule == .mt63 {
                            MT63TuningPanel(controller: state.mt63Controller, settings: state.mt63)
                                .radioCard(title: "Abstimmanzeige")
                            MT63SettingsPanel(settings: state.mt63)
                                .radioCard(title: "MT63")
                        } else if state.activeModule == .mfsk {
                            MFSKTuningPanel(controller: state.mfskController, settings: state.mfsk)
                                .radioCard(title: "Abstimmanzeige")
                            MFSKSettingsPanel(settings: state.mfsk)
                                .radioCard(title: "MFSK · DOMINOEX · THOR · THROB · IFKP · FSQ")
                        } else if state.activeModule == .hell {
                            HellTuningPanel(controller: state.hellController, settings: state.hell)
                                .radioCard(title: "Abstimmanzeige")
                            HellSettingsPanel(settings: state.hell)
                                .radioCard(title: "HELL")
                        } else if state.activeModule == .psk {
                            PSKTuningPanel(controller: state.pskController, settings: state.psk)
                                .radioCard(title: "Abstimmanzeige")
                            PSKSettingsPanel(settings: state.psk)
                                .radioCard(title: "PSK")
                        } else if state.activeModule == .skimmer {
                            SkimmerTuningPanel(controller: state.skimmerController, settings: state.skimmer)
                                .radioCard(title: "Abstimmanzeige")
                            SkimmerSettingsPanel(settings: state.skimmer)
                                .radioCard(title: "SKIMMER")
                        } else if state.activeModule == .wefax {
                            WefaxTuningPanel(controller: state.wefaxController, settings: state.wefax, schedule: state.wefaxSchedule, auto: state.autoRecorder)
                                .radioCard(title: "Abstimmanzeige")
                            WefaxSettingsPanel(settings: state.wefax)
                                .radioCard(title: "WEFAX")
                            WefaxGallery(controller: state.wefaxController)
                                .radioCard(title: "Bilder")
                        } else if state.activeModule == .ft8 {
                            FT8CyclePanel(controller: state.ft8Controller, settings: state.ft8)
                                .radioCard(title: "Zyklus · Rx-Frequenz")
                            FT8SettingsPanel(settings: state.ft8)
                                .radioCard(title: "FT8")
                        } else if state.activeModule == .ft4 {
                            FT4CyclePanel(controller: state.ft4Controller, settings: state.ft4)
                                .radioCard(title: "Zyklus · Rx-Frequenz")
                            FT4SettingsPanel(settings: state.ft4)
                                .radioCard(title: state.ft4.mode.rawValue)
                        } else if state.activeModule == .wspr {
                            WSPRCyclePanel(controller: state.wsprController, settings: state.wspr)
                                .radioCard(title: "Zyklus")
                            WSPRSettingsPanel(settings: state.wspr)
                                .radioCard(title: "WSPR")
                        } else if state.activeModule == .js8 {
                            JS8CyclePanel(controller: state.js8Controller, settings: state.js8)
                                .radioCard(title: "Zyklus · Rx-Frequenz")
                            JS8SettingsPanel(settings: state.js8)
                                .radioCard(title: "JS8")
                        } else if state.activeModule == .ndb {
                            NDBTuningPanel(controller: state.ndbController, settings: state.ndb)
                                .radioCard(title: "Signal · Ton")
                            NDBSettingsPanel(controller: state.ndbController, settings: state.ndb)
                                .radioCard(title: "NDB")
                        } else if state.activeModule == .dcf77 {
                            DCF77TuningPanel(controller: state.dcf77Controller, settings: state.dcf77)
                                .radioCard(title: "Signal · Pegel")
                            DCF77SettingsPanel(settings: state.dcf77, controller: state.dcf77Controller)
                                .radioCard(title: "DCF77")
                            DCF77HistoryPanel(controller: state.dcf77Controller)
                                .radioCard(title: "Telegramme")
                        } else if state.activeModule == .efr {
                            EFRTuningPanel(controller: state.efrController, settings: state.efr)
                                .radioCard(title: "Signal · Pegel")
                            EFRSettingsPanel(settings: state.efr, controller: state.efrController)
                                .radioCard(title: "EFR")
                        } else if state.activeModule == .sstv {
                            SSTVTuningPanel(controller: state.sstvController, settings: state.sstv)
                                .radioCard(title: "Abstimmanzeige")
                            SSTVSettingsPanel(settings: state.sstv, controller: state.sstvController)
                                .radioCard(title: "SSTV")
                            SSTVGallery(controller: state.sstvController)
                                .radioCard(title: "Bilder")
                        } else {
                            TuningPanel(controller: state.rttyController, settings: state.rtty)
                                .radioCard(title: "Abstimmanzeige")

                            VStack(spacing: 8) {
                                PresetPanel(rtty: state.rtty, schedule: state.rttySchedule)
                                RTTYQuickControls(settings: state.rtty, showSettings: $showRTTYSettings)
                            }
                            .radioCard(title: "Preset")
                        }

                        SDRconnectControlHost(rig: state.rig)

                        if state.activeModule == .adsb {
                            ADSBReceiverCard(controller: state.adsbController)
                                .radioCard(title: "Empfänger")
                        } else if state.activeModule == .sensors {
                            SensorsReceiverCard(controller: state.sensorsController)
                                .radioCard(title: "Empfänger")
                        } else if state.activeModule == .tetra {
                            TETRAReceiverCard(controller: state.tetraController)
                                .radioCard(title: "Empfänger")
                        } else if state.activeModule == .dab {
                            DABReceiverCard()
                                .radioCard(title: "Empfänger")
                        } else if state.activeModule == .vdl2 {
                            VDL2ReceiverCard(controller: state.vdl2Controller)
                                .radioCard(title: "Empfänger")
                        } else {
                            InputPanelView(audio: state.audio)
                                .radioCard(title: "Eingang")
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(width: 330)
                }
                .padding(.horizontal, 14)

                StatusBar(state: state, rtty: state.rtty, navtex: state.navtex, cw: state.cw, wefax: state.wefax, psk: state.psk, skimmer: state.skimmer, skimmerController: state.skimmerController, olivia: state.olivia, mt63: state.mt63, mfsk: state.mfsk, hell: state.hell, dsc: state.dsc, ale: state.ale, aprs: state.aprs, packet: state.packet, packetController: state.packetController, adsb: state.adsb, adsbController: state.adsbController, acars: state.acars, ais: state.ais, aisController: state.aisController, hfdl: state.hfdl, drm: state.drm, sonde: state.sonde, sondeController: state.sondeController, pager: state.pager, tones: state.tones, ft8: state.ft8, ft4: state.ft4, ft4Controller: state.ft4Controller, wspr: state.wspr, js8: state.js8, dcf77: state.dcf77, dcf77Controller: state.dcf77Controller, efr: state.efr, efrController: state.efrController, sstv: state.sstv, sstvController: state.sstvController)
            }
            .padding(.bottom, 8)
            PropagationRuler(service: state.propagation, home: state.home, sdr: state.sdrController, settings: state.sdr)
                .ignoresSafeArea()
            }
        }
        .frame(minWidth: 1060, minHeight: 730)
        .task {
            // Entwicklungshilfe: DIGIDEC_AIS_INFO=<MMSI> öffnet das Fenster „Schiffsdaten“ nach 5 s (für Schnappschüsse)
            if let v = ProcessInfo.processInfo.environment["DIGIDEC_AIS_INFO"], let mmsi = UInt32(v) {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                state.aisController.showInfo(for: mmsi)
                openWindow(id: "ship-info")
            }
            // Entwicklungshilfe: DIGIDEC_QRZ=<Rufzeichen> öffnet das Fenster „QRZ.com“ nach 4 s (für Schnappschüsse)
            if let v = ProcessInfo.processInfo.environment["DIGIDEC_QRZ"] {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if QRZLookup.shared.show(v) { openWindow(id: "qrz") }
            }
            // Entwicklungshilfe: DIGIDEC_ADSB_INFO=<ICAO hex> öffnet das Fenster „Flugzeugdaten“ nach 12 s (für Schnappschüsse)
            if let v = ProcessInfo.processInfo.environment["DIGIDEC_ADSB_INFO"], let icao = UInt32(v, radix: 16) {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                state.adsbController.showInfo(for: icao)
                openWindow(id: "aircraft-info")
            }
        }
        .sheet(isPresented: $showRTTYSettings) {
            RTTYSettingsSheet(settings: state.rtty)
        }
        .sheet(item: $state.scheduleSheet) { service in
            ScheduleSheet(state: state, tab: service)
        }
        .sheet(isPresented: $state.showRigSettings) {
            RigSettingsSheet(state: state)
        }
        .sheet(isPresented: $state.showAbout) {
            AboutSheet()
        }
    }
}

// MARK: - Kopfzeile

private struct HeaderBar: View {
    @ObservedObject var state: DigidecState

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(RadioTheme.vfdCyan)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("DIGIDEC")
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                            .foregroundColor(RadioTheme.textBright)

                        Text(AppVersion.string)
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RadioTheme.bgDeep.opacity(0.8))
                            .cornerRadius(3)
                    }

                    Text("DIGITAL MODE DECODER")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.vfdAmber)
                        .tracking(1.0)
                }
            }

            Spacer()

            MapToggleButton(state: state)
            ScheduleButton(state: state, auto: state.autoRecorder)
            RigControlToggle(state: state, rig: state.rig)
            RigBadge(rig: state.rig, audio: state.audio, onTap: { state.showRigSettings = true })
            AboutButton(onTap: { state.showAbout = true })
            UTCClock()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }
}

/// Darstellung des unteren Bereichs: Liste (bzw. Bild/Text), Karte oder beides übereinander
private struct MapToggleButton: View {
    @ObservedObject var state: DigidecState

    var body: some View {
        let module = state.activeModule
        let current = state.mapLayout(module)
        HStack(spacing: 2) {
            segment(module.mainViewIcon, module.mainViewName, .list, current, module, help: module.mainViewHelp)
            segment("map", "KARTE", .map, current, module, help: "Nur die Karte zeigen (Stationen, Sender, Positionen)")
            segment("rectangle.split.1x2", "BEIDE", .split, current, module, help: "\(module.mainViewName.capitalized) oben, Karte darunter")
        }
        .padding(2)
        .background(RadioTheme.bgDeep)
        .cornerRadius(5)
        .opacity(module.hasMap ? 1 : 0.5)
        .help(module.hasMap ? "Darstellung umschalten" : "\(module.displayName) hat keine Ortsdaten, daher keine Karte")
    }

    private func segment(_ icon: String, _ text: String, _ layout: MapLayout, _ current: MapLayout, _ module: DecoderModuleInfo, help: String) -> some View {
        Button {
            state.setMapLayout(layout, for: module)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
                Text(text).font(.system(size: 9, weight: .bold, design: .monospaced))
            }
            .foregroundColor(current == layout ? RadioTheme.vfdCyan : RadioTheme.textMuted)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(current == layout ? RadioTheme.vfdCyan.opacity(0.18) : .clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .disabled(!module.hasMap)
        .help(help)
    }
}

/// Öffnet den Sendeplan (Wetterfax, RTTY, NAVTEX, Radiosonden); zeigt eine laufende geplante Aufnahme
private struct ScheduleButton: View {
    @ObservedObject var state: DigidecState
    @ObservedObject var auto: ScheduleAutoRecorder

    var body: some View {
        Button {
            let service = BroadcastService.allCases.first { $0.module == state.activeModule } ?? .wefax
            state.scheduleSheet = service
        } label: {
            HStack(spacing: 5) {
                Image(systemName: auto.session != nil ? "record.circle.fill" : "calendar")
                    .font(.system(size: 9, weight: .bold))
                Text("SENDEPLAN")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
            }
            .foregroundColor(auto.session != nil ? RadioTheme.ledRed : RadioTheme.textBright)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RadioTheme.bgDeep)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help("Sendepläne von Wetterfax, RTTY, NAVTEX und Radiosonden ansehen und Sendungen zur automatischen Aufnahme wählen")
    }
}

/// Schalter: Digidec stimmt das Funkgerät über den rigctld des Commanders auf Band/Kanal/Sender des Moduls ab
private struct RigControlToggle: View {
    @ObservedObject var state: DigidecState
    @ObservedObject var rig: RigModel

    var body: some View {
        Button {
            state.rigControlEnabled.toggle()
            if state.rigControlEnabled { state.tuneRigForActiveModule() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 9, weight: .bold))
                Text(state.rigControlEnabled ? "QSY AUTO" : "QSY MANUELL")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
            }
            .foregroundColor(state.rigControlEnabled ? RadioTheme.vfdAmber : RadioTheme.textDim)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RadioTheme.bgDeep)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .disabled(!rig.hasRig)
        .help(help)
    }

    private var help: String {
        if !rig.hasRig { return "Kein Funkgerät gewählt (Klick auf die Funkgeräte-Anzeige oben rechts)" }
        var s = state.rigControlEnabled
            ? "Digidec stimmt das Funkgerät über den rigctld des Commanders ab (nur Frequenz F und Mode M, nie PTT), wenn Modul, Band, Kanal oder Sender gewechselt wird. Klicken zum Ausschalten."
            : "Digidec liest nur Frequenz und Mode. Klicken, damit es das Funkgerät auf Band, Kanal oder Sender des Moduls abstimmt."
        if let m = rig.tuneMessage { s += "\n\(m)" }
        return s
    }
}

/// Funkgerät, Frequenz und Mode laut rigctld; ein Klick öffnet den Dialog „Funkgerät“
private struct RigBadge: View {
    @ObservedObject var rig: RigModel
    @ObservedObject var audio: AudioInputManager
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RadioTheme.bgDeep)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var color: Color {
        if !rig.hasRig { return RadioTheme.textDim }
        return rig.state.connected ? RadioTheme.vfdGreen : RadioTheme.ledYellow
    }

    private var label: String {
        if audio.sourceKind == .file { return "DATEI" }
        guard let name = rig.rigName else {
            return (audio.activeInput?.device.name ?? "KEIN EINGANG").uppercased()
        }
        guard rig.state.connected else { return "\(name) · RIGCTLD ?" }
        var s = name.uppercased()
        if let f = rig.state.frequencyText { s += " · \(f)" }
        if let m = rig.state.mode { s += " · \(m)" }
        return s
    }

    private var help: String {
        let click = "\nKlick: Funkgerät einstellen (rigctld auf beliebigem Rechner und Port)"
        guard let name = rig.rigName else { return "Kein Funkgerät – Frequenz und Mode unbekannt" + click }
        let target = rig.state.host.map { h in "\(h):\(rig.state.port.map(String.init) ?? "?")" } ?? (rig.state.port.map { "Port \($0)" } ?? "?")
        let source = rig.customProfile != nil ? "rigctld" : "Commander, rigctld"
        return (rig.state.connected
            ? "\(name): Frequenz und Mode (\(source) \(target))" + (rig.tuneMessage.map { "\n\($0)" } ?? "")
            : "\(name): rigctld \(target) nicht erreichbar – läuft er?") + click
    }
}

/// Info-Knopf in der Kopfzeile: Version, Lizenz, Quellen
private struct AboutButton: View {
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(RadioTheme.textMuted)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .help("Info: Version, Lizenz (GPL-3.0-or-later), Quelltext, verwendete Quellen und Drittanbieter-Software")
    }
}

private struct UTCClock: View {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text("\(Self.formatter.string(from: context.date)) UTC")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.vfdAmber)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RadioTheme.bgDeep)
                .cornerRadius(4)
        }
    }
}

// MARK: - Modul-Leiste

private struct ModuleBar: View {
    @ObservedObject var state: DigidecState

    /// Breite des Mehrkanal-Knopfes: etwa zwei gewöhnliche Knöpfe
    private static let multiWidth: CGFloat = 132
    private static let labelWidth: CGFloat = 52

    var body: some View {
        // Die Rubriken reservieren links Platz für den Mehrkanal-Knopf; er liegt als Überlagerung darüber und hat damit genau die Höhe der Zeilen:
        // vom oberen Rand des ersten bis zum unteren Rand des letzten Knopfes
        VStack(spacing: 6) {
            ForEach(DecoderModuleInfo.Band.allCases) { band in
                bandRow(band)
            }
        }
        .overlay(alignment: .topLeading) {
            multiButton
                .padding(.leading, 11 + Self.labelWidth + 8)
        }
        .padding(.horizontal, 14)
    }

    /// Ein Knopf für beide Rubriken: Rand wie alle anderen Modul-Buttons (RadioTheme.borderSubtle / vfdCyan)
    private var multiButton: some View {
        let module = DecoderModuleInfo.channels
        let selected = state.activeModule == module
        return Button { state.select(module: module) } label: {
            VStack(spacing: 3) {
                Text(module.displayName)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                Text("HF + VHF/UHF")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .opacity(0.75)
            }
            .frame(width: Self.multiWidth)
            .frame(maxHeight: .infinity)
            .foregroundColor(selected ? RadioTheme.vfdCyan : RadioTheme.textMuted)
            .background(selected ? RadioTheme.vfdCyan.opacity(0.2) : RadioTheme.bgPanel)
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(selected ? RadioTheme.vfdCyan : RadioTheme.borderSubtle, lineWidth: selected ? 1.5 : 1)
            )
            .shadow(color: selected ? RadioTheme.vfdCyan.opacity(0.3) : .clear, radius: 4)
        }
        .buttonStyle(.plain)
        .help("MEHRKANAL · mehrere Decoder zugleich aus einem Fenster des SDR, auf Kurzwelle wie auf UKW")
    }

    /// Eine Rubrik: farbige Leiste links, Kürzel des Bereichs, dann die Module A–Z
    private func bandRow(_ band: DecoderModuleInfo.Band) -> some View {
        let color = Self.color(of: band)
        return HStack(alignment: .top, spacing: 8) {
            Text(band.title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .tracking(0.8)
                .frame(width: Self.labelWidth, alignment: .leading)
                .padding(.top, 8)
                .help(band.detail)
            // Platz für den Mehrkanal-Knopf
            Color.clear.frame(width: Self.multiWidth, height: 1)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(band.modules) { module in
                    Button(module.displayName) {
                        state.select(module: module)
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: state.activeModule == module))
                    .disabled(!module.isAvailable)
                    .opacity(module.isAvailable ? 1.0 : 0.45)
                    .help(module.isAvailable ? "\(module.displayName) · \(band.title)" : "\(module.displayName) – geplant")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 11)
        // Als Hintergrund hat die Leiste genau die Höhe der Buttons (ein frei stehendes Shape dehnt sich auf die ganze Fensterhöhe)
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3)
                .shadow(color: color.opacity(0.5), radius: 3)
        }
    }

    private static func color(of band: DecoderModuleInfo.Band) -> Color {
        switch band {
        case .hf:     return RadioTheme.vfdAmber
        case .vhfUhf: return RadioTheme.vfdGreen
        }
    }
}

/// Reiht Schaltflächen nebeneinander und bricht bei Platzmangel in die nächste Zeile um
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width
            usedWidth = max(usedWidth, x)
            x += spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: usedWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + lineSpacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Preset (Auswahl; weitere Einstellungen folgen mit M5)

struct PresetPanel: View {
    @ObservedObject var rtty: RTTYSettingsStore
    @ObservedObject var schedule: RttyScheduleStore

    var body: some View {
        VStack(spacing: 8) {
            presetGrid
            if rtty.presetID == "dwd-kw" || rtty.presetID == "dwd-lw" {
                frequencyRow
            }
        }
    }

    /// Frequenzen des gewählten DWD-Presets aus dem Sendeplan (Langwelle oder Kurzwelle)
    private var frequencies: [RttyFrequency] {
        schedule.schedule.frequencies.filter { $0.presetID == rtty.presetID }.sorted { $0.hz < $1.hz }
    }

    /// Aktive Frequenz: Wahl des Nutzers, sonst Automatik nach Tageszeit
    private var activeHz: Double? {
        rtty.selectedDWDFrequencyHz ?? schedule.automaticFrequency(program: rtty.presetID == "dwd-lw" ? 2 : 1, at: Date())?.hz
    }

    private var frequencyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: frequencies.count > 3 ? 3 : max(1, frequencies.count)), spacing: 4) {
                ForEach(frequencies) { f in
                    Button {
                        rtty.selectDWDFrequency(f.hz, presetID: rtty.presetID)
                    } label: {
                        VStack(spacing: 1) {
                            Text(f.label)
                            Text("\(f.callsign) · P\(f.program)")
                                .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                                .foregroundColor(RadioTheme.textDim)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ModeButtonStyle(isSelected: activeHz == f.hz))
                    .help("\(f.callsign), Programm \(f.program), \(f.label), Hub ±\(String(format: "%g", f.shiftHalfHz).replacingOccurrences(of: ".", with: ",")) Hz. Nur mit QSY AUTO wird das Funkgerät auf den USB-Dial (Frequenz minus NF-Mitte) abgestimmt")
                }
            }
            Text(rtty.selectedDWDFrequencyHz == nil ? "Frequenz automatisch nach Tageszeit" : "Frequenz von Hand gewählt")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
        }
    }

    private var presetGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(RTTYPreset.all) { preset in
                Button {
                    rtty.select(presetID: preset.id)
                } label: {
                    VStack(spacing: 2) {
                        Text(preset.name)
                        Text(detail(for: preset))
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(RadioTheme.textDim)
                    }
                    .frame(maxWidth: .infinity)
                    .modifier(ModeLabelLook(isSelected: preset.id == rtty.presetID))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(preset.note)
            }
        }
    }

    private func detail(for preset: RTTYPreset) -> String {
        let p = preset.id == "custom" ? rtty.customParameters : preset.parameters
        let b = p.baud == p.baud.rounded() ? String(format: "%.0f", p.baud) : String(format: "%.2f", p.baud).replacingOccurrences(of: ".", with: ",")
        return "\(b) Bd · \(Int(p.shift)) Hz"
    }
}

/// Optik von `ModeButtonStyle` für reine Anzeigen ohne Button.
private struct ModeLabelLook: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(isSelected ? RadioTheme.vfdCyan.opacity(0.2) : RadioTheme.bgPanel)
            .foregroundColor(isSelected ? RadioTheme.vfdCyan : RadioTheme.textMuted)
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isSelected ? RadioTheme.vfdCyan : RadioTheme.borderSubtle, lineWidth: isSelected ? 1.5 : 1)
            )
    }
}

// MARK: - Statuszeile

private struct StatusBar: View {
    @ObservedObject var state: DigidecState
    @ObservedObject var rtty: RTTYSettingsStore
    @ObservedObject var navtex: NavtexSettingsStore
    @ObservedObject var cw: CWSettingsStore
    @ObservedObject var wefax: WefaxSettingsStore
    @ObservedObject var psk: PSKSettingsStore
    @ObservedObject var skimmer: SkimmerSettingsStore
    @ObservedObject var skimmerController: SkimmerController
    @ObservedObject var olivia: OliviaSettingsStore
    @ObservedObject var mt63: MT63SettingsStore
    @ObservedObject var mfsk: MFSKSettingsStore
    @ObservedObject var hell: HellSettingsStore
    @ObservedObject var dsc: DSCSettingsStore
    @ObservedObject var ale: ALESettingsStore
    @ObservedObject var aprs: APRSSettingsStore
    @ObservedObject var packet: PacketSettingsStore
    @ObservedObject var packetController: PacketController
    @ObservedObject var adsb: ADSBSettingsStore
    @ObservedObject var adsbController: ADSBController
    @ObservedObject var acars: ACARSSettingsStore
    @ObservedObject var ais: AISSettingsStore
    @ObservedObject var aisController: AISController
    @ObservedObject var hfdl: HFDLSettingsStore
    @ObservedObject var drm: DRMSettingsStore
    @ObservedObject var sonde: SondeSettingsStore
    @ObservedObject var sondeController: SondeController
    @ObservedObject var pager: PagerSettingsStore
    @ObservedObject var tones: TonesSettingsStore
    @ObservedObject var ft8: FT8SettingsStore
    @ObservedObject var ft4: FT4SettingsStore
    @ObservedObject var ft4Controller: FT4Controller
    @ObservedObject var wspr: WSPRSettingsStore
    @ObservedObject var js8: JS8SettingsStore
    @ObservedObject var dcf77: DCF77SettingsStore
    @ObservedObject var dcf77Controller: DCF77Controller
    @ObservedObject var efr: EFRSettingsStore
    @ObservedObject var efrController: EFRController
    @ObservedObject var sstv: SSTVSettingsStore
    @ObservedObject var sstvController: SSTVController

    var body: some View {
        HStack(spacing: 10) {
            Text(currentLine)
                .foregroundColor(RadioTheme.textMuted)
                .lineLimit(1)
            Spacer()
            if let error = state.lastRequestError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(RadioTheme.ledYellow)
            } else if let request = state.currentRequest, let date = state.lastRequestDate {
                Text((request.sourceDisplayName.map { "Auftrag von \($0)" } ?? "Auftrag ohne Quelle") + " · \(Self.time.string(from: date)) UTC")
                    .foregroundColor(RadioTheme.textDim)
            } else {
                Text("Bereit für Aufträge (digidec://decode?…)")
                    .foregroundColor(RadioTheme.textDim)
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .padding(.horizontal, 14)
    }

    /// Aktueller Decoder-Stand, z. B. „RTTY · DWD KW · 50 Bd · 450 Hz · 5/1,5 · REV · LSB (auto) · Mitte 1696 Hz“
    private var current: String {
        let p = rtty.parameters
        var s = "\(state.activeModule.displayName) · \(rtty.preset.name) · \(p.summary)"
        if p.reverse { s += " · REV" }
        s += p.ita2 ? " · ITA2" : " · US-TTY"
        s += " · \(rtty.effectiveLSB ? "LSB" : "USB")"
        if rtty.sidebandMode == .auto { s += rtty.rigIsLSB == nil ? " (auto, unbekannt)" : " (auto)" }
        s += " · Mitte \(Int(rtty.centerHz.rounded())) Hz"
        return s
    }

    /// „NAVTEX · 518 kHz · 100 Bd · ±85 Hz · USB (auto) · Mitte 1000 Hz“
    private var navtexCurrent: String {
        var s = "NAVTEX · \(navtex.frequency.label) · 100 Bd · ±85 Hz"
        if navtex.reverse { s += " · REV" }
        s += navtex.ita2 ? " · ITA2" : " · US-TTY"
        s += " · \(navtex.effectiveLSB ? "LSB" : "USB")"
        if navtex.sidebandMode == .auto { s += navtex.rigIsLSB == nil ? " (auto, unbekannt)" : " (auto)" }
        s += " · Mitte \(Int(navtex.centerHz.rounded())) Hz"
        return s
    }

    private var currentLine: String {
        switch state.activeModule {
        case .channels: return "MEHRKANAL · \(state.sdrController.bank.slots.filter(\.enabled).count) Decoder zugleich aus einem Fenster des SDR"
        case .navtex: return navtexCurrent
        case .cw: return cwCurrent
        case .psk: return pskCurrent
        case .skimmer: return skimmerCurrent
        case .olivia: return "\(olivia.options.familyName.uppercased()) · \(olivia.options.label) · Mitte \(Int(olivia.centerHz.rounded())) Hz" + (olivia.options.reverse ? " · REV" : "") + (olivia.options.squelchOn ? " · SQL \(Int(olivia.options.squelch))" : " · SQL aus")
        case .acars: return "ACARS · \(acars.channel.label) MHz AM · MSK 2400 Bd" + (acars.hideEmpty ? " · ohne leere" : "") + (acars.showUplink ? "" : " · nur Abwärts")
        case .hfdl: return "HFDL · \(HFDLChannels.label(hfdl.frequencyKHz)) kHz USB · PSK 1800 Bd · Träger 1440 Hz" + (hfdl.showUplink ? "" : " · nur Abwärts") + (hfdl.onlyContent ? " · nur Inhalt" : "")
        case .sonde: return sondeCurrent
        case .ais: return aisCurrent
        case .dstar: return "D-STAR · DV · GMSK 4800 Bd · FM-Diskriminator-Audio"
        case .ysf: return "YSF · C4FM 4800 Bd · FM-Diskriminator-Audio"
        case .dpmr: return "dPMR · 4FSK 2400 Bd · 6,25 kHz · FM-Diskriminator-Audio"
        case .drm: return "DRM · \(String(format: "%.1f", drm.frequencyKHz).replacingOccurrences(of: ".0", with: "")) kHz USB (Dial 6 kHz tiefer) · OFDM 4,5 bis 20 kHz"
        case .p25: return "P25 Phase 1 · C4FM 4800 Bd · 12,5 kHz · FM-Diskriminator-Audio"
        case .nxdn: return "NXDN · 4FSK 2400 Bd (6,25 kHz) und 4800 Bd (12,5 kHz) · FM-Diskriminator-Audio"
        case .ndb: return "NDB · Funkfeuer 190 bis 535 kHz · AM-Audio, Kennungston 400/1020 Hz oder Überlagerungston"
        case .tetra: return "TETRA · π/4-DQPSK 18 000 Bd · 25 kHz · I/Q direkt vom Gerät"
        case .dmr: return "DMR · 4FSK 4800 Bd · 2 Zeitschlitze · FM-Diskriminator-Audio"
        case .m17: return "M17 · 4FSK 4800 Bd · Codec2 · FM-Diskriminator-Audio"
        case .sensors: return "SENSOREN · Funksensoren 433,92 und 868,3 MHz · I/Q direkt vom Gerät"
        case .vor: return "VOR/ILS · Peilung und Kennung · AM-Audio 48 kHz (Bandbreite ≥ 25 kHz)"
        case .dab: return "DAB · Digitalradio Band III · 174 bis 240 MHz · COFDM · DAB+ (HE-AAC) · I/Q direkt vom Gerät"
        case .rds: return "RDS · \(String(format: "%.1f MHz", state.rds.frequencyHz / 1e6).replacingOccurrences(of: ".", with: ",")) · WFM 230 kHz · Stereo · 57 kHz RDS-Unterträger · UKW-Rundfunk (87,5–108 MHz)"
        case .vdl2: return "VDL2 · VDL Mode 2 · 136,725 bis 136,975 MHz · D8PSK 10 500 Bd · I/Q direkt vom Gerät"
        case .freedv: return "FREEDV · digitale Sprache KW · USB · NF 500 bis 2500 Hz"
        case .packet: return packetCurrent
        case .adsb: return adsbCurrent
        case .pager: return "PAGER · \(pager.channel.label) MHz FM · POCSAG " + POCSAG.rates.filter(pager.rates.contains).map(String.init).joined(separator: "/") + (pager.flex ? " · FLEX" : "")
        case .tones: return "TÖNE · " + ToneStandard.allCases.filter(tones.standards.contains).map(\.name).joined(separator: ", ")
        case .aprs: return "APRS · \(aprs.channel.label) MHz FM · AFSK 1200 Bd · Töne \(Int(aprs.centerHz - 500)) / \(Int(aprs.centerHz + 500)) Hz" + (aprs.repairBits ? " · Korrektur" : "") + (aprs.emphasis == .auto ? "" : aprs.emphasis == .on ? " · DE-EMPH." : " · FLACH")
        case .ale: return "ALE · 8-FSK 125 Bd · Verstimmung \(Int(ale.offsetHz.rounded())) Hz" + (ale.auto ? " · AUTO" : "") + " · \(ale.sensitivity.rawValue)"
        case .dsc where dsc.channel.isVHF: return "DSC · UKW Kanal 70 · 156,525 MHz FM · 1200 Bd / 1300 + 2100 Hz"
        case .dsc: return "DSC · \(dsc.channel.label) kHz · Mitte \(Int(dsc.centerHz.rounded())) Hz · 100 Bd / 170 Hz" + (dsc.autoCenter ? " · AUTO" : "") + (dsc.reversed ? " · REV" : "")
        case .mt63: return "MT63 · \(mt63.options.label) · Mitte \(Int(mt63.centerHz.rounded())) Hz" + (mt63.options.squelchOn ? " · SQL \(Int(mt63.options.squelch))" : " · SQL aus")
        case .mfsk: return "\(mfsk.options.mode.displayName.uppercased()) · Mitte \(Int(mfsk.centerHz.rounded())) Hz · \(Int(mfsk.options.mode.bandwidthHz)) Hz breit" + (mfsk.options.reverse ? " · REV" : "") + (mfsk.options.squelchOn ? " · SQL \(Int(mfsk.options.squelch))" : " · SQL aus")
        case .hell: return "\(hell.options.mode.displayName.uppercased()) · Mitte \(Int(hell.centerHz.rounded())) Hz · \(Int(hell.options.mode.bandwidthHz)) Hz breit" + (hell.options.reverse && hell.options.mode.isFSK ? " · REV" : "") + (hell.options.squelchOn ? " · SQL \(Int(hell.options.squelch))" : " · SQL aus")
        case .wefax: return wefaxCurrent
        case .ft8: return ft8Current
        case .ft4: return ft4Current
        case .wspr: return wsprCurrent
        case .js8: return js8Current
        case .dcf77: return dcf77Current
        case .efr: return efrCurrent
        case .sstv: return sstvCurrent
        default: return current
        }
    }

    /// „SSTV · 20m · Martin 1 · Ton 1750 Hz · Empfange M1 · Zeile 120/256 (46%)“
    private var sstvCurrent: String {
        let modeName = (sstvController.detectedMode ?? sstv.manualMode)?.spec.name ?? "VIS Auto"
        return "SSTV · \(sstv.channel.name) · \(modeName) · Ton \(Int(sstv.centerHz)) Hz · \(sstvController.statusMessage)"
    }

    /// „FT4 · 20m · Dial 14,080 MHz · 150–3600 Hz · JN49WS“
    private var ft4Current: String {
        let dial = String(format: "%.3f", Double(ft4.dialHz) / 1_000_000).replacingOccurrences(of: ".", with: ",")
        var s = "\(ft4.mode.rawValue) · \(ft4.band.rawValue) · Dial \(dial) MHz"
        s += " · \(Int(ft4.core.minHz))–\(Int(ft4.core.maxHz)) Hz"
        s += " · \(ft4.locator)"
        if !ft4.myCall.isEmpty { s += " · \(ft4.myCall)" }
        return s
    }

    /// „SKIMMER · CW · Dial 14,020 MHz · Schwelle 8 dB · 7 Signale · 3 mit Rufzeichen“
    private var skimmerCurrent: String {
        var s = "SKIMMER · \(skimmer.mode.name)"
        if let d = skimmer.dialHz { s += String(format: " · Dial %.3f MHz", Double(d) / 1_000_000).replacingOccurrences(of: ".", with: ",") }
        s += " · Schwelle \(Int(skimmer.thresholdDB)) dB"
        let live = skimmerController.stations.filter(\.isLive)
        s += " · \(live.count) Signale · \(live.filter { $0.call != nil }.count) mit Rufzeichen"
        return s
    }

    /// „ADS-B · 1090 MHz · HackRF · 23 Flugzeuge · 18 mit Position · 112 Meldungen/s“
    private var adsbCurrent: String {
        var s = "ADS-B · 1090 MHz · \(adsb.source.title)"
        let n = adsbController.aircraft.count
        if n > 0 {
            s += " · \(n) Flugzeug" + (n == 1 ? "" : "e") + " · \(adsbController.aircraft.filter(\.hasPosition).count) mit Position"
            s += " · \(Int(adsbController.stats.messagesPerSecond.rounded())) Meldungen/s"
        }
        return s
    }

    /// „PACKET · 144,8125 MHz FM · AFSK 1200 Bd (oder G3RUH 9600 Bd) · 12 Stationen · 3 Verbindungen · 2 Nachrichten“
    private var packetCurrent: String {
        var s = "PACKET · \(packet.channel.label) MHz FM · " + (packet.baud == .baud9600 ? "G3RUH 9600 Bd" : "AFSK 1200 Bd")
        let c = packetController
        if c.frameCount > 0 {
            s += " · \(c.stations.count) Stationen"
            if !c.sessions.isEmpty { s += " · \(c.sessions.count) Verbindung" + (c.sessions.count == 1 ? "" : "en") }
            if !c.mail.isEmpty { s += " · \(c.mail.count) Nachricht" + (c.mail.count == 1 ? "" : "en") }
        }
        return s
    }

    /// „AIS · 161,975 MHz FM · GMSK 9600 Bd · 14 Schiffe · 212 Meldungen“
    private var aisCurrent: String {
        var s = "AIS · \(ais.channel.label) MHz FM · GMSK 9600 Bd"
        let n = aisController.ships.filter { $0.kind != .aid && $0.kind != .base }.count
        if n > 0 { s += " · \(n) Schiff" + (n == 1 ? "" : "e") }
        s += " · \(aisController.messageCount) Meldungen"
        return s
    }

    /// „SONDE · 403,500 MHz FM 15 kHz · RS41/DFM/M10/M20 · 2 Sonden · 118 Rahmen“
    private var sondeCurrent: String {
        var s = "SONDE · \(sonde.frequencyText) FM \(sonde.filterKHz) kHz · RS41/DFM/M10/M20"
        let n = sondeController.flights.count
        if n > 0 { s += " · \(n) Sonde" + (n == 1 ? "" : "n") }
        s += " · \(sondeController.stats.frames) Rahmen"
        return s
    }

    /// „PSK · BPSK31 · Mitte 1000 Hz · AFC · SQL 5“
    private var pskCurrent: String {
        var s = "PSK · \(psk.options.mode.displayName) · Mitte \(Int(psk.centerHz.rounded())) Hz"
        s += psk.options.afc ? " · AFC" : " · AFC aus"
        if psk.options.reverse { s += " · REV" }
        s += psk.options.squelchOn ? " · SQL \(Int(psk.options.squelch))" : " · SQL aus"
        if let d = psk.band.dialHz { s += String(format: " · %.3f MHz", Double(d) / 1_000_000).replacingOccurrences(of: ".", with: ",") }
        return s
    }

    /// „WSPR · 20m · Dial 14,0956 MHz · 1400–1600 Hz · JN49WS“
    private var wsprCurrent: String {
        let dial = String(format: "%.4f", Double(wspr.dialHz) / 1_000_000).replacingOccurrences(of: ".", with: ",")
        var s = "WSPR · \(wspr.band.rawValue) · Dial \(dial) MHz"
        s += wspr.core.wide ? " · 1350–1650 Hz" : " · 1390–1610 Hz"
        if wspr.core.deep { s += " · tief" }
        s += " · \(wspr.locator)"
        if !wspr.myCall.isEmpty { s += " · \(wspr.myCall)" }
        return s
    }

    /// „EFR · DCF49 Mainflingen · 200 Bd · Shift 340 Hz · DIN 19244 · Ton 1500 Hz“
    private var efrCurrent: String {
        var s = "EFR · \(efr.station.name) · 200 Bd · Shift 340 Hz · DIN 19244 · Ton \(Int(efr.centerHz.rounded())) Hz"
        if let st = efrController.status {
            s += String(format: " · SNR %.1f dB · %d Telegramme", st.snrDb, st.telegramsDecoded)
        }
        return s
    }

    /// „DCF77 · 77,5 kHz · AM 100/200 ms · Ton 1000 Hz · SYNC OK · SNR 24.5 dB“
    private var dcf77Current: String {
        var s = "DCF77 · 77,5 kHz · AM 100/200 ms · Ton \(Int(dcf77.centerHz.rounded())) Hz"
        if let st = dcf77Controller.status {
            s += st.isSynchronized ? " · SYNC OK" : (st.currentSecond >= 0 ? " · Sekunde \(st.currentSecond)" : " · SUCHE...")
            s += String(format: " · SNR %.1f dB", st.snrDb)
        }
        return s
    }

    /// „FT8 · 20m · Dial 14,074 MHz · 150–3600 Hz · 3 s Rechenzeit · JN49WS“
    private var ft8Current: String {
        let dial = String(format: "%.3f", Double(ft8.dialHz) / 1_000_000).replacingOccurrences(of: ".", with: ",")
        var s = "FT8 · \(ft8.band.rawValue) · Dial \(dial) MHz"
        s += " · \(Int(ft8.core.minHz))–\(Int(ft8.core.maxHz)) Hz"
        s += " · " + String(format: "%.1f", ft8.core.budgetSeconds).replacingOccurrences(of: ".", with: ",") + " s Rechenzeit"
        s += " · \(ft8.locator)"
        if !ft8.myCall.isEmpty { s += " · \(ft8.myCall)" }
        return s
    }

    /// „JS8 · 20m · Dial 14,078 MHz · A+C · JN49WS“
    private var js8Current: String {
        let dial = String(format: "%.3f", Double(js8.dialHz) / 1_000_000).replacingOccurrences(of: ".", with: ",")
        var s = "JS8 · \(js8.band.rawValue) · Dial \(dial) MHz"
        s += " · " + js8.modes.sorted().map(\.letter).joined(separator: "+")
        s += " · \(Int(js8.core.minHz))–\(Int(js8.core.maxHz)) Hz"
        s += " · \(js8.locator)"
        if !js8.myCall.isEmpty { s += " · \(js8.myCall)" }
        return s
    }

    /// „WEFAX · DWD 7880 · IOC 576 · 120 LPM · Hub 850 Hz · Mitte 1900 Hz · AFC“
    private var wefaxCurrent: String {
        let o = wefax.options
        var s = "WEFAX · " + (wefax.station == .custom ? "Frei" : "DWD \(wefax.station.label)")
        s += " · IOC \(o.ioc) · \(o.lpm) LPM · Hub \(o.shiftHz) Hz · Mitte \(o.centerHz) Hz"
        if o.afc { s += " · AFC" }
        if wefax.rigIsLSB == true { s += " · LSB!" }
        return s
    }

    /// „CW · Ton 700 Hz · Filter 150 Hz · Start 18 WpM · Nachführung 8–28“
    private var cwCurrent: String {
        let o = cw.options
        var s = "CW · Ton \(Int(cw.centerHz.rounded())) Hz · Filter \(Int(cw.effectiveBandwidth)) Hz"
        if o.matchedFilter { s += " (MF)" }
        s += " · Start \(o.speedWPM) WpM"
        s += o.track ? " · Nachführung \(max(o.lowerWPM, o.speedWPM - o.rangeWPM))–\(min(o.upperWPM, o.speedWPM + o.rangeWPM))" : " · fest"
        if o.somDecoding { s += " · SOM" }
        return s
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

// MARK: - Platzhalter für spätere Meilensteine

private struct PlaceholderPanel: View {
    let icon: String
    let text: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundColor(RadioTheme.textDim)
            Text(text.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(RadioTheme.textMuted)
                .tracking(1.0)
            Text(detail)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(RadioTheme.textDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RadioTheme.bgDeep)
        .cornerRadius(6)
    }
}
