// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import SwiftUI
import AVFoundation
import Combine

/// Darstellung im unteren Hauptbereich: Liste (bzw. Bild/Text), Karte oder beides übereinander
public enum MapLayout: String, Sendable {
    case list, map, split
}

/// Zentraler App-Zustand. Ab M5 kommt der RTTY-Decoder, ab M7 der rigctld-Client dazu.
@MainActor
public final class DigidecState: ObservableObject {
    public static let shared = DigidecState()

    @Published public var activeModule: DecoderModuleInfo = .rtty
    /// Letzter gültiger Auftrag eines Hauptprogramms (URL-Schema).
    @Published public private(set) var currentRequest: DecodeRequest?
    /// Meldung zum letzten abgelehnten Auftrag, für die Statuszeile.
    @Published public private(set) var lastRequestError: String?
    /// Zeitpunkt des letzten angenommenen Auftrags
    @Published public private(set) var lastRequestDate: Date?

    public let audio: AudioInputManager
    public let rtty = RTTYSettingsStore()
    public let waterfall: WaterfallModel
    public let rttyController: RTTYController
    public let rig = RigModel()
    /// Gespeicherte freie Funkgeräte (rigctld auf beliebigem Rechner und Port)
    public let rigProfiles = RigProfileStore()
    /// Dialog „Funkgerät“ offen?
    @Published public var showRigSettings = false
    /// Info-Fenster (Version, Lizenz, Quellen) offen?
    @Published public var showAbout = false
    /// Eigener Standort für alle Karten und Entfernungen
    public let home = HomeLocation()
    public let navtex = NavtexSettingsStore()
    public let navtexController: NavtexController
    public let cw = CWSettingsStore()
    public let cwController: CWController
    public let psk = PSKSettingsStore()
    public let pskController: PSKController
    public let skimmer = SkimmerSettingsStore()
    public let skimmerController: SkimmerController
    public let olivia = OliviaSettingsStore()
    public let oliviaController: OliviaController
    public let mt63 = MT63SettingsStore()
    public let mt63Controller: MT63Controller
    public let mfsk = MFSKSettingsStore()
    public let mfskController: MFSKController
    public let hell = HellSettingsStore()
    public let hellController: HellController
    public let dsc = DSCSettingsStore()
    public let dscController: DSCController
    public let ale = ALESettingsStore()
    public let aleController: ALEController
    public let aprs = APRSSettingsStore()
    public let aprsController: APRSController
    public let packet = PacketSettingsStore()
    public let packetController: PacketController
    public let adsb = ADSBSettingsStore()
    public let adsbController: ADSBController
    public let acars = ACARSSettingsStore()
    public let acarsController: ACARSController
    public let ais = AISSettingsStore()
    public let aisController: AISController
    public let dstar = DStarSettingsStore()
    public let dstarController: DStarController
    public let ysf = YSFSettingsStore()
    public let ysfController: YSFController
    public let dmr = DMRSettingsStore()
    public let dmrController: DMRController
    public let dpmr = DPMRSettingsStore()
    public let dpmrController: DPMRController
    public let ndb = NDBSettingsStore()
    public let ndbController: NDBController
    public let tetra = TETRASettingsStore()
    public let tetraController: TETRAController
    public let m17 = M17SettingsStore()
    public let m17Controller: M17Controller
    public let sensors = SensorsSettingsStore()
    public let sensorsController: SensorsController
    public let sdr = SDRSettingsStore()
    public let sdrController: SDRController
    /// Mehrkanalbetrieb: Decoder zu den Kanälen der Kanalbank (Modul KANÄLE)
    public private(set) var channelHub: ChannelHub!
    public let vdl2 = VDL2SettingsStore()
    public let vdl2Controller: VDL2Controller
    public let dab = DABSettingsStore()
    public let dabController: DABController
    public let nav = NavSettingsStore()
    public let navController: NavController
    public let freedv = FreeDVSettingsStore()
    public let freedvController: FreeDVController
    public let hfdl = HFDLSettingsStore()
    public let hfdlController: HFDLController
    public let sonde = SondeSettingsStore()
    public let sondeController: SondeController
    public let pager = PagerSettingsStore()
    public let pagerController: PagerController
    public let tones = TonesSettingsStore()
    public let tonesController: TonesController
    public let wefax = WefaxSettingsStore()
    public let wefaxController: WefaxController
    public let ft8 = FT8SettingsStore()
    public let ft8Controller: FT8Controller
    public let ft4 = FT4SettingsStore()
    public let ft4Controller: FT4Controller
    public let wspr = WSPRSettingsStore()
    public let wsprController: WSPRController
    public let dcf77 = DCF77SettingsStore()
    public let dcf77Controller: DCF77Controller
    public let efr = EFRSettingsStore()
    public let efrController: EFRController
    public let sstv = SSTVSettingsStore()
    public let sstvController: SSTVController
    public let wefaxSchedule = WefaxScheduleStore()
    public let rttySchedule = RttyScheduleStore()
    public let navtexPlan = NavtexPlanStore()
    public let sondePlan = SondePlanStore()
    public private(set) var autoRecorder: ScheduleAutoRecorder!
    public private(set) var sondeScanner: SondeScanner!
    /// Welcher Sendeplan gerade im Fenster gezeigt wird (nil = Fenster zu)
    @Published public var scheduleSheet: BroadcastService?
    /// Darstellung je Modul: Liste, Karte oder beides (gemerkt). Frühere Versionen merkten nur „Karte“ in `mapModules`.
    @Published public private(set) var mapLayouts: [String: String] = {
        var d = (UserDefaults.standard.dictionary(forKey: "mapLayouts") as? [String: String]) ?? [:]
        for m in UserDefaults.standard.stringArray(forKey: "mapModules") ?? [] where d[m] == nil { d[m] = MapLayout.map.rawValue }
        return d
    }()
    /// Darf Digidec das Funkgerät über den rigctld des Commanders abstimmen? Standard: aus (nur lesen).
    @Published public var rigControlEnabled: Bool {
        didSet { UserDefaults.standard.set(rigControlEnabled, forKey: "rigControlEnabled") }
    }
    /// Nach einem Auftrag eines Commanders (URL) stimmt dieser das Gerät selbst ab: nicht gegenläufig nachstellen
    private var suppressRigTuneUntil = Date.distantPast
    /// Dial-Frequenz und Mode des Funkgeräts für das NDB-Modul
    private var ndbRigState: (hz: Int?, mode: String?) = (nil, nil)
    private var audioStarted = false
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        rigControlEnabled = UserDefaults.standard.bool(forKey: "rigControlEnabled")
        audio = AudioInputManager()
        waterfall = WaterfallModel(pipeline: audio.pipeline)
        rttyController = RTTYController(pipeline: audio.pipeline, settings: rtty)
        navtexController = NavtexController(pipeline: audio.pipeline, settings: navtex)
        cwController = CWController(pipeline: audio.pipeline, settings: cw)
        pskController = PSKController(pipeline: audio.pipeline, settings: psk)
        skimmerController = SkimmerController(pipeline: audio.pipeline, settings: skimmer)
        oliviaController = OliviaController(pipeline: audio.pipeline, settings: olivia)
        mt63Controller = MT63Controller(pipeline: audio.pipeline, settings: mt63)
        mfskController = MFSKController(pipeline: audio.pipeline, settings: mfsk)
        hellController = HellController(pipeline: audio.pipeline, settings: hell)
        dscController = DSCController(pipeline: audio.pipeline, settings: dsc)
        aleController = ALEController(pipeline: audio.pipeline, settings: ale)
        aprsController = APRSController(pipeline: audio.pipeline, settings: aprs)
        packetController = PacketController(pipeline: audio.pipeline, settings: packet)
        adsbController = ADSBController(settings: adsb)
        acarsController = ACARSController(pipeline: audio.pipeline, settings: acars)
        aisController = AISController(pipeline: audio.pipeline, settings: ais)
        dstarController = DStarController(pipeline: audio.pipeline, settings: dstar)
        ysfController = YSFController(pipeline: audio.pipeline, settings: ysf)
        dmrController = DMRController(pipeline: audio.pipeline, settings: dmr)
        dpmrController = DPMRController(pipeline: audio.pipeline, settings: dpmr)
        tetraController = TETRAController(settings: tetra)
        ndbController = NDBController(pipeline: audio.pipeline, settings: ndb)
        m17Controller = M17Controller(pipeline: audio.pipeline, settings: m17)
        sensorsController = SensorsController(settings: sensors)
        sdrController = SDRController(pipeline: audio.pipeline, settings: sdr)
        audio.sdr = sdrController
        vdl2Controller = VDL2Controller(settings: vdl2)
        dabController = DABController(settings: dab)
        navController = NavController(pipeline: audio.pipeline, settings: nav)
        freedvController = FreeDVController(pipeline: audio.pipeline, settings: freedv)
        hfdlController = HFDLController(pipeline: audio.pipeline, settings: hfdl)
        sondeController = SondeController(pipeline: audio.pipeline, settings: sonde)
        pagerController = PagerController(pipeline: audio.pipeline, settings: pager)
        tonesController = TonesController(pipeline: audio.pipeline, settings: tones)
        wefaxController = WefaxController(pipeline: audio.pipeline, settings: wefax)
        ft8Controller = FT8Controller(pipeline: audio.pipeline, settings: ft8)
        ft4Controller = FT4Controller(pipeline: audio.pipeline, settings: ft4)
        wsprController = WSPRController(pipeline: audio.pipeline, settings: wspr)
        dcf77Controller = DCF77Controller(pipeline: audio.pipeline, settings: dcf77)
        efrController = EFRController(pipeline: audio.pipeline, settings: efr)
        sstvController = SSTVController(pipeline: audio.pipeline, settings: sstv)

        channelHub = ChannelHub(bank: sdrController.bank, state: self)
        sdrController.slotAudio = { [unowned self] id in self.channelHub.audioHandler(for: id) }

        autoRecorder = ScheduleAutoRecorder(state: self, wefax: wefaxSchedule, rtty: rttySchedule, navtex: navtexPlan, sonde: sondePlan)
        // Suchlauf nach Sonden: stimmt über die Abstimmung des Moduls (QSY AUTO, rigctld) Frequenz für Frequenz ab
        sondeScanner = SondeScanner(
            settings: sonde, controller: sondeController,
            rigReady: { [unowned self] in self.rigCanTune && self.rig.state.connected },
            isActive: { [unowned self] in self.activeModule == .sonde },
            knownFrequencies: { [unowned self] in self.sondePlan.knownFrequencies(home: self.home.point) + self.sondeController.heardFrequencies })

        // NDB: Frequenz und Mode des Funkgeräts lesen, Funkgerät abstimmen (Klick auf ein Funkfeuer, Suchlauf)
        ndbController.rigState = { [unowned self] in self.ndbRigState }
        ndbController.rigAvailable = { [unowned self] in self.rigCanTune && self.rig.state.connected }
        ndbController.tuneRig = { [unowned self] target in self.tuneRig(to: target) }
        ndbController.home = { [unowned self] in self.home.point }

        // Standort für die AIS-Entfernungen (weitester Empfang)
        aisController.homePoint = home.point
        home.$locator.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.aisController.homePoint = self?.home.point }.store(in: &cancellables)
        // Standort des Empfängers für ADS-B (Entfernungen, Bodenpositionen, Reichweite)
        adsbController.homePoint = home.point
        home.$locator.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.adsbController.homePoint = self?.home.point }.store(in: &cancellables)

        // Ein Standort für alle: der Locator der Karte gilt auch für Entfernungen in FT8, FT4, WSPR und die NAVTEX-Stationssuche
        let syncLocators: @MainActor (String) -> Void = { [weak self] loc in
            guard let self, Maidenhead.coordinate(loc) != nil else { return }
            if ft8.locator != loc { ft8.locator = loc }
            if ft4.locator != loc { ft4.locator = loc }
            if wspr.locator != loc { wspr.locator = loc }
            if navtex.locator != loc { navtex.locator = loc }
        }
        home.$locator.removeDuplicates().receive(on: RunLoop.main).sink { loc in syncLocators(loc.uppercased()) }.store(in: &cancellables)
        for pub in [ft8.$locator, ft4.$locator, wspr.$locator, navtex.$locator] {
            pub.removeDuplicates().dropFirst().receive(on: RunLoop.main).sink { [weak self] loc in
                let v = loc.uppercased().trimmingCharacters(in: .whitespaces)
                if let self, Maidenhead.coordinate(v) != nil, self.home.locator != v { self.home.locator = v }
            }.store(in: &cancellables)
        }

        // Nur das gewählte Modul decodiert
        $activeModule
            .receive(on: RunLoop.main)
            .sink { [weak self] module in
                // Module mit eigenem I/Q-Eingang brauchen das Gerät: der SDR-Empfänger gibt es ab und nimmt es danach wieder
                if module.usesOwnIQDevice { self?.sdrController.suspend() }
                self?.rttyController.decoder.setEnabled(module == .rtty)
                self?.navtexController.setActive(module == .navtex)
                self?.cwController.setActive(module == .cw)
                self?.pskController.setActive(module == .psk)
                self?.skimmerController.setActive(module == .skimmer)
                self?.oliviaController.setActive(module == .olivia)
                self?.mt63Controller.setActive(module == .mt63)
                self?.mfskController.setActive(module == .mfsk)
                self?.hellController.setActive(module == .hell)
                self?.dscController.setActive(module == .dsc)
                self?.aleController.setActive(module == .ale)
                self?.aprsController.setActive(module == .aprs)
                self?.packetController.setActive(module == .packet)
                self?.adsbController.setActive(module == .adsb)
                self?.acarsController.setActive(module == .acars)
                self?.aisController.setActive(module == .ais)
                self?.dstarController.setActive(module == .dstar)
                self?.ysfController.setActive(module == .ysf)
                self?.dmrController.setActive(module == .dmr)
                self?.dpmrController.setActive(module == .dpmr)
                self?.tetraController.setActive(module == .tetra)
                self?.ndbController.setActive(module == .ndb)
                self?.m17Controller.setActive(module == .m17)
                self?.sensorsController.setActive(module == .sensors)
                self?.vdl2Controller.setActive(module == .vdl2)
                self?.dabController.setActive(module == .dab)
                self?.navController.setActive(module == .vor)
                self?.freedvController.setActive(module == .freedv)
                self?.hfdlController.setActive(module == .hfdl)
                self?.sondeController.setActive(module == .sonde)
                self?.pagerController.setActive(module == .pager)
                self?.tonesController.setActive(module == .tones)
                self?.wefaxController.setActive(module == .wefax)
                self?.ft8Controller.setActive(module == .ft8)
                self?.ft4Controller.setActive(module == .ft4)
                self?.wsprController.setActive(module == .wspr)
                self?.dcf77Controller.setActive(module == .dcf77)
                self?.efrController.setActive(module == .efr)
                self?.sstvController.setActive(module == .sstv)
                self?.updateChannelBank(active: module == .channels)
                if !module.usesOwnIQDevice { self?.sdrController.resume() }
            }
            .store(in: &cancellables)

        // Funkgerät folgt den Voreinstellungen: Moduswechsel und Klick auf Band/Kanal/Sender stellen es ab (wenn freigegeben)
        observeForTuning($activeModule)
        observeForTuning(ft8.$band)
        observeForTuning(ft4.$band)
        observeForTuning(wspr.$band)
        observeForTuning(psk.$band)
        observeForTuning(skimmer.$cwBand)
        observeForTuning(skimmer.$pskBand)
        observeForTuning(skimmer.$mode)
        observeForTuning(dsc.$channel)
        observeForTuning(aprs.$channel)
        observeForTuning(packet.$channel)
        observeForTuning(acars.$channel)
        observeForTuning(ais.$channel)
        observeForTuning(hfdl.$frequencyKHz)
        observeForTuning(sonde.$frequencyKHz)
        observeForTuning(sonde.$filterKHz)
        observeForTuning(pager.$channel)
        observeForTuning(sstv.$channel)
        observeForTuning(efr.$station)
        observeForTuning(wefax.$station)
        observeForTuning(navtex.$frequency)
        observeForTuning(rtty.$presetID)
        observeForTuning(rtty.$dwdFrequencyHz)

        // rigctld des Funkgeräts, dessen Codec gerade gelesen wird (bei Dateiwiedergabe keins)
        audio.$activeInput.combineLatest(audio.$sourceKind)
            .receive(on: RunLoop.main)
            .sink { [weak self] input, kind in
                self?.rig.follow(radio: kind == .live ? input?.radio : nil)
            }
            .store(in: &cancellables)
        sdrController.shouldYield = { [unowned self] in self.activeModule.usesOwnIQDevice }
        // Eingebauter SDR-Empfänger als Funkgerät: Frequenz und Betriebsart kommen von ihm, die Module stimmen ihn ab
        sdrController.onRigState = { [weak self] state in
            guard let self else { return }
            if let state {
                let name = self.sdrController.rigName
                var justAttached = false
                if self.rig.internalName != name {
                    self.rig.useInternal(name: name, tune: { [weak self] target in self?.sdrController.tune(to: target) ?? .notConnected })
                    justAttached = true
                }
                self.rig.setInternal(state: state)
                // Gerade angemeldet: gleich auf die Frequenz des aktiven Moduls stellen (AIS, APRS, Funkruf …)
                if justAttached { Task { @MainActor in self.tuneRigForActiveModule() } }
            } else if self.rig.isInternal {
                self.rig.useInternal(name: nil)
            }
        }
        // Freies Funkgerät aus den Einstellungen: gilt ab Start und bei jeder Änderung der Liste
        rig.use(profile: rigProfiles.active)
        rigProfiles.$list
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] list in
                guard let self else { return }
                // Nur neu setzen, wenn sich das wirksame Gerät ändert (z. B. nicht beim Tippen im Namensfeld eines anderen Geräts)
                if self.rig.customProfile != list.active || self.rig.overriddenByRequest { self.rig.use(profile: list.active) }
            }
            .store(in: &cancellables)
        rig.onChange = { [weak self] state in
            guard let self else { return }
            rtty.rigIsLSB = state.isLSB
            navtex.rigIsLSB = state.isLSB
            wefax.rigIsLSB = state.isLSB
            skimmer.rigDialHz = state.connected ? state.frequencyHz.map { Int($0) } : nil
            skimmer.rigIsLSB = state.isLSB
            ft8.rigDialHz = state.connected ? state.frequencyHz.map { Int($0) } : nil
            ft4.rigDialHz = state.connected ? state.frequencyHz.map { Int($0) } : nil
            wspr.rigDialHz = state.connected ? state.frequencyHz.map { Int($0) } : nil
            wefaxController.rigFrequencyHz = state.connected ? state.frequencyHz.map(Int64.init) : nil
            navtexController.rigFrequencyHz = state.connected ? state.frequencyHz.map(Double.init) : nil
            dcf77.rigFrequencyHz = state.connected ? state.frequencyHz.map(Int64.init) : nil
            ndbRigState = (state.connected ? state.frequencyHz.map { Int($0) } : nil, state.mode)
            efr.rigFrequencyHz = state.connected ? state.frequencyHz.map(Int64.init) : nil
            sstv.rigIsLSB = state.isLSB
            sstv.rigDialHz = state.connected ? state.frequencyHz.map { Int($0) } : nil
            sstvController.rigFrequencyHz = state.connected ? state.frequencyHz.map(Int64.init) : nil
            rttyController.rigDescription = rig.description
            cwController.rigDescription = rig.description
            pskController.rigDescription = rig.description
            skimmerController.rigDescription = rig.description
            oliviaController.rigDescription = rig.description
            mt63Controller.rigDescription = rig.description
            mfskController.rigDescription = rig.description
            dscController.rigDescription = rig.description
            aleController.rigDescription = rig.description
            aprsController.rigDescription = rig.description
            packetController.rigDescription = rig.description
            acarsController.rigDescription = rig.description
            aisController.rigDescription = rig.description
            dstarController.rigDescription = rig.description
            ysfController.rigDescription = rig.description
            dmrController.rigDescription = rig.description
            m17Controller.rigDescription = rig.description
            freedvController.rigDescription = rig.description
            hfdlController.rigDescription = rig.description
            sondeController.rigDescription = rig.description
            pagerController.rigDescription = rig.description
            tonesController.rigDescription = rig.description
            dcf77Controller.sourceDescription = rig.description
            efrController.sourceDescription = rig.description
            sstvController.sourceDescription = rig.description
            rttyController.rigState = state
        }
    }

    /// Modul KANÄLE gewählt: der SDR-Empfänger wird als Quelle gewählt und die Kanalbank läuft; sonst hält sie an
    private func updateChannelBank(active: Bool) {
        if active, audio.sourceKind != .sdr { audio.selectSDR() }
        sdrController.bank.setActive(active)
        // Die Kanäle sind in der Engine des SDR-Empfängers; nach dem Umschalten Zustand übernehmen
        if active { channelHub.sync() }
    }

    private func observeForTuning<P: Publisher>(_ publisher: P) where P.Output: Equatable, P.Failure == Never {
        publisher
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.tuneRigForActiveModule() }
            .store(in: &cancellables)
    }

    /// Abstimmziel des aktiven Moduls (nil: RTTY, CW oder freie Einstellung ohne feste Frequenz)
    public var rigTargetForActiveModule: RigTuneTarget? {
        switch activeModule {
        case .ft8:    return .ft8(band: ft8.band)
        case .ft4:    return .ft4(band: ft4.band)
        case .wspr:   return .wspr(band: wspr.band)
        case .psk:    return .psk(band: psk.band)
        case .skimmer: return .skimmer(mode: skimmer.mode, cwBand: skimmer.cwBand, pskBand: skimmer.pskBand)
        case .sstv:   return .sstv(channel: sstv.channel)
        case .efr:    return .efr(station: efr.station, centerHz: efr.centerHz)
        case .dcf77:  return .dcf77(centerHz: dcf77.centerHz)
        case .wefax:  return .wefax(station: wefax.station, centerHz: wefax.centerHz)
        case .navtex: return .navtex(frequency: navtex.frequency, centerHz: navtex.centerHz)
        case .dsc:    return .dsc(channel: dsc.channel, centerHz: dsc.centerHz)
        case .aprs:   return .aprs(channel: aprs.channel)
        case .packet: return .packet(channel: packet.channel)
        case .adsb:   return nil
        case .acars:  return .acars(channel: acars.channel)
        case .ais:    return .ais(channel: ais.channel)
        case .dstar, .ysf, .dmr, .dpmr, .tetra, .m17, .sensors, .vdl2, .dab, .vor, .freedv, .channels: return nil
        case .hfdl:   return .hfdl(frequencyKHz: hfdl.frequencyKHz)
        case .sonde:  return .sonde(frequencyKHz: sonde.frequencyKHz, filterKHz: sonde.filterKHz)
        case .pager:  return .pager(channel: pager.channel)
        case .rtty:   return rttyDWDTarget
        case .cw, .olivia, .mt63, .mfsk, .hell, .ale, .tones, .ndb: return nil
        }
    }

    /// DWD-Funkfernschreiben: gewählte Frequenz des Presets, sonst die Automatik des Sendeplans (Tageszeit); andere Presets nichts
    public var rttyDWDTarget: RigTuneTarget? {
        guard rtty.presetID == "dwd-kw" || rtty.presetID == "dwd-lw" else { return nil }
        let hz = rtty.selectedDWDFrequencyHz
            ?? rttySchedule.automaticFrequency(program: rtty.presetID == "dwd-lw" ? 2 : 1, at: Date())?.hz
        return hz.map { RigTuneTarget.rtty(frequencyHz: $0, centerHz: rtty.centerHz) }
    }

    /// Gerät im Dialog „Funkgerät“ wählen (nil = Automatik über den USB-Codec der Commander). Gehört zum Gerät ein Audio-Eingang,
    /// wird er mit gewählt: zuerst über die UID, sonst über den Namen (die UID von USB-Geräten ändert sich beim Umstecken).
    public func activateRigProfile(id: String?) {
        rigProfiles.setActive(id: id)
        rig.use(profile: rigProfiles.active)
        guard let profile = rigProfiles.active, profile.audioUID != nil || profile.audioName != nil else { return }
        audio.refreshDevices()
        let device = audio.devices.first { $0.id == profile.audioUID }
            ?? audio.devices.first { $0.name == profile.audioName }
        if let device { audio.select(device: device) }
    }

    /// Darf Digidec das Funkgerät abstimmen? Der eingebaute SDR-Empfänger folgt den Modulen, solange „FOLGT MODUL“ an ist (eigenes Gerät, keine Gefahr für ein Funkgerät);
    /// ein Funkgerät hinter rigctld nur mit QSY AUTO.
    public var rigCanTune: Bool {
        guard rig.hasRig else { return false }
        return rig.isInternal ? sdr.followModules : rigControlEnabled
    }

    /// Stimmt das Funkgerät auf ein Ziel ab (geplante Aufnahme) – nur mit Freigabe (QSY AUTO) und Verbindung.
    /// Die Abstimmung nach Modul-/Voreinstellungswechsel wird kurz unterdrückt, damit nicht doppelt gesendet wird.
    public func tuneRig(to target: RigTuneTarget) {
        guard rigCanTune else { return }
        suppressRigTuneUntil = Date().addingTimeInterval(3.0)
        rig.tune(to: target)
    }

    /// Stellt das Funkgerät auf das Ziel des aktiven Moduls – nur mit Freigabe und Verbindung
    public func tuneRigForActiveModule() {
        guard rigCanTune, Date() >= suppressRigTuneUntil,
              let target = rigTargetForActiveModule else { return }
        rig.tune(to: target)
    }

    /// Beim Programmstart: Mikrofon-Freigabe abwarten (nötig für den Eingang der virtuellen Soundkarte),
    /// dann den Live-Eingang starten. Kam der Start per Auftrag, hat `handle(url:)` das schon erledigt.
    public func startAudio() {
        guard !audioStarted else { return }
        audioStarted = true
        let start: @MainActor () -> Void = {
            let state = DigidecState.shared
            // Entwicklungshilfe: DIGIDEC_ADSB_FILE=/Pfad/aufnahme.bin (8-Bit-I/Q, 2 MS/s) statt eines Geräts; DIGIDEC_ADSB_REALTIME=0 schneller als in Echtzeit
            if let path = ProcessInfo.processInfo.environment["DIGIDEC_ADSB_FILE"] {
                state.adsbController.fileOverride = URL(fileURLWithPath: path)
                state.adsbController.fileRealtime = ProcessInfo.processInfo.environment["DIGIDEC_ADSB_REALTIME"] != "0"
            }
            // Entwicklungshilfe: DIGIDEC_SENSORS_FILE=/Pfad/aufnahme_250k.cu8 (8-Bit-I/Q, Abtastrate im Namen) statt eines Geräts; DIGIDEC_SENSORS_BAND=868.3; DIGIDEC_SENSORS_REALTIME=0 schneller
            if let path = ProcessInfo.processInfo.environment["DIGIDEC_SENSORS_FILE"] {
                state.sensorsController.fileOverride = URL(fileURLWithPath: path)
                state.sensorsController.fileSampleRate = SensorsController.sampleRate(inFileName: URL(fileURLWithPath: path).lastPathComponent)
                state.sensorsController.fileRealtime = ProcessInfo.processInfo.environment["DIGIDEC_SENSORS_REALTIME"] != "0"
                if let b = ProcessInfo.processInfo.environment["DIGIDEC_SENSORS_BAND"].flatMap(SensorBand.init(rawValue:)) { state.sensors.band = b }
            }
            // Entwicklungshilfe: DIGIDEC_VDL2_FILE=/Pfad/aufnahme_1050kHz.wav (I/Q, WAV oder cu8; ein Kanal in der Mitte); DIGIDEC_VDL2_REALTIME=0 schneller
            if let path = ProcessInfo.processInfo.environment["DIGIDEC_VDL2_FILE"] {
                state.vdl2Controller.fileOverride = URL(fileURLWithPath: path)
                state.vdl2Controller.fileRealtime = ProcessInfo.processInfo.environment["DIGIDEC_VDL2_REALTIME"] != "0"
            }
            // Entwicklungshilfe: DIGIDEC_DAB_FILE=/Pfad/aufnahme.raw (8-Bit-I/Q, 2,048 MS/s); DIGIDEC_DAB_SIGNED=1 für HackRF-Rohdaten (vorzeichenbehaftet),
            // DIGIDEC_DAB_REALTIME=0 schneller, DIGIDEC_DAB_SERVICE=<Name> wählt den Dienst (Teil des Namens)
            if let path = ProcessInfo.processInfo.environment["DIGIDEC_DAB_FILE"] {
                state.dabController.fileOverride = URL(fileURLWithPath: path)
                state.dabController.fileSigned = ProcessInfo.processInfo.environment["DIGIDEC_DAB_SIGNED"] != nil
                state.dabController.fileRealtime = ProcessInfo.processInfo.environment["DIGIDEC_DAB_REALTIME"] != "0"
            }
            if let name = ProcessInfo.processInfo.environment["DIGIDEC_DAB_SERVICE"] { state.dabController.autoSelectName = name }
            if ProcessInfo.processInfo.environment["DIGIDEC_DAB_MUTE"] != nil { state.dab.muted = true }
            if ProcessInfo.processInfo.environment["DIGIDEC_DAB_SCAN"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { MainActor.assumeIsolated { DigidecState.shared.dabController.startScan() } }
            }
            if let b = ProcessInfo.processInfo.environment["DIGIDEC_DAB_BLOCK"], let blk = DABBlock.named(b) { state.dab.blockName = blk.name }
            // Entwicklungshilfe: DIGIDEC_TETRA_FILE=/Pfad/aufnahme.wav (I/Q, WAV oder cu8; ein Träger in der Mitte); DIGIDEC_TETRA_REALTIME=0 schneller
            if let path = ProcessInfo.processInfo.environment["DIGIDEC_TETRA_FILE"] {
                state.tetraController.fileOverride = URL(fileURLWithPath: path)
                state.tetraController.fileRealtime = ProcessInfo.processInfo.environment["DIGIDEC_TETRA_REALTIME"] != "0"
            }
            // Entwicklungshilfe: DIGIDEC_MODULE=aprs startet im genannten Modul (nur dieses decodiert), DIGIDEC_PLAY_FILE=/Pfad/aufnahme.wav
            // spielt eine Datei statt des Live-Eingangs ab
            if let id = ProcessInfo.processInfo.environment["DIGIDEC_MODULE"], let module = DecoderModuleInfo(rawValue: id) {
                state.activeModule = module
            }
            // Entwicklungshilfe: DIGIDEC_AIS_NMEA=/Pfad/sätze.nmea nimmt AIS-Sätze (!AIVDM) wie empfangen auf (Schnappschüsse ohne Funksignal)
            if let path = ProcessInfo.processInfo.environment["DIGIDEC_AIS_NMEA"], let text = try? String(contentsOfFile: path, encoding: .utf8) {
                var asm = AISNMEA.Assembler()
                for line in text.split(whereSeparator: \.isNewline) {
                    if let s = AISNMEA.parse(String(line)), let bits = asm.add(s) { state.aisController.ingest(bits: bits) }
                }
            }
            if let path = ProcessInfo.processInfo.environment["DIGIDEC_PLAY_FILE"] {
                state.audio.openFile(URL(fileURLWithPath: path))
                state.audio.playFile()
            } else if let request = state.currentRequest, RadioSource(requestSource: request.source) != nil || request.deviceUID != nil {
                state.audio.apply(request: request)
            } else if ProcessInfo.processInfo.environment["DIGIDEC_SDR_FILE"] != nil || ProcessInfo.processInfo.environment["DIGIDEC_SDR"] != nil || state.sdr.autoStart {
                // Entwicklungshilfe: DIGIDEC_SDR_FILE=/Pfad/aufnahme.cu8 (8-Bit-I/Q) mit DIGIDEC_SDR_RATE (Standard 2400000), DIGIDEC_SDR_CENTER (Hz),
                // DIGIDEC_SDR=1 (Gerät statt Aufnahme), DIGIDEC_SDR_FREQ (gehörte Frequenz in Hz), DIGIDEC_SDR_MODE (fm, wfm, am, usb, lsb, cw), DIGIDEC_SDR_REALTIME=0 schneller
                let env = ProcessInfo.processInfo.environment
                if let path = env["DIGIDEC_SDR_FILE"] {
                    state.sdrController.fileOverride = URL(fileURLWithPath: path)
                    state.sdrController.fileSampleRate = Int(env["DIGIDEC_SDR_RATE"] ?? "") ?? 2_400_000
                    state.sdrController.fileCenterHz = Double(env["DIGIDEC_SDR_CENTER"] ?? "") ?? 0
                    state.sdrController.fileRealtime = env["DIGIDEC_SDR_REALTIME"] != "0"
                }
                // DIGIDEC_BANK="aprs@144.8,acars@131.55": Kanäle der Kanalbank (Modul@MHz), ersetzen die gespeicherten
                if let list = env["DIGIDEC_BANK"] {
                    state.sdrController.bank.removeAll()
                    for item in list.split(separator: ",") {
                        let parts = item.split(separator: "@")
                        guard parts.count == 2, let module = DecoderModuleInfo(rawValue: String(parts[0])), let mhz = Double(parts[1]) else { continue }
                        let d = ChannelCatalog.defaults(for: module)
                        state.sdrController.bank.add(moduleID: module.rawValue, frequencyHz: (mhz * 1e6).rounded(), mode: d.mode, bandwidthHz: d.bandwidthHz)
                    }
                }
                if let n = env["DIGIDEC_BANK_SELECT"].flatMap({ Int($0) }), state.sdrController.bank.slots.indices.contains(n - 1) { state.sdrController.bank.selectedID = state.sdrController.bank.slots[n - 1].id }
                if env["DIGIDEC_SDR_MONITOR"] != nil { state.sdr.monitor = true }
                if let m = env["DIGIDEC_SDR_MODE"].flatMap({ SDRMode(hamlib: $0) }) { state.sdr.select(mode: m) }
                if let f = env["DIGIDEC_SDR_FREQ"].flatMap({ Double($0) }) { state.sdr.frequencyHz = f }
                state.audio.selectSDR()
            } else {
                state.audio.startLive()
            }
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in start() }
            }
        } else {
            start()
        }
    }

    public func handle(url: URL) {
        switch DecodeRequestParser.parse(url) {
        case .success(let request):
            // Der Commander hat das Funkgerät für diesen Auftrag selbst eingestellt: nicht dagegen arbeiten
            suppressRigTuneUntil = Date().addingTimeInterval(2.0)
            currentRequest = request
            if let module = request.module {
                activeModule = module
                switch module {
                case .rtty:
                    if let preset = request.presetID { rtty.select(presetID: preset) }
                    if let center = request.centerHz { rtty.setCenter(center) }
                case .navtex:
                    if let preset = request.presetID, let f = NavtexFrequency(rawValue: preset) { navtex.frequency = f }
                    if let center = request.centerHz { navtex.setCenter(center) }
                case .cw:
                    if let center = request.centerHz { cw.setCenter(center) }
                case .olivia:
                    if let preset = request.presetID, let o = FldigiOliviaCore.Options(presetID: preset) { olivia.options = o }
                    if let center = request.centerHz { olivia.setCenter(center) }
                case .ale:
                    if let center = request.centerHz { ale.setCenter(center) }
                case .aprs:
                    if let preset = request.presetID, let c = APRSChannel(rawValue: preset) { aprs.channel = c }
                    if let center = request.centerHz { aprs.setCenter(center) }
                case .packet:
                    if let preset = request.presetID, let c = PacketChannel(rawValue: preset) { packet.channel = c }
                    if let center = request.centerHz { packet.setCenter(center) }
                case .adsb:
                    if let preset = request.presetID, let k = ADSBSourceKind(rawValue: preset) { adsb.source = k }
                case .acars:
                    if let preset = request.presetID, let c = ACARSChannel(rawValue: preset) { acars.channel = c }
                case .ais:
                    if let preset = request.presetID, let c = AISChannel(rawValue: preset) { ais.channel = c }
                case .dstar, .ysf, .dmr, .dpmr, .tetra, .ndb, .m17:
                    break
                case .sensors:
                    if let preset = request.presetID, let b = SensorBand(rawValue: preset) { sensors.band = b }
                case .vor:
                    switch request.presetID {
                    case "loc": nav.ilsKind = .localizer
                    case "gs": nav.ilsKind = .glideslope
                    default: break
                    }
                case .dab:
                    if let preset = request.presetID, let b = DABBlock.named(preset) { dab.blockName = b.name }
                case .vdl2:
                    switch request.presetID {
                    case "csc": vdl2.channels = [VDL2.commonSignallingChannel / 1e6]
                    case "alle": vdl2.channels = VDL2Channels.all
                    case "europa": vdl2.channels = VDL2Channels.europe
                    default: break
                    }
                case .freedv:
                    if let preset = request.presetID, let m = FreeDVMode(preset: preset) { freedv.mode = m }
                case .hfdl:
                    if let preset = request.presetID, let f = HFDLChannels.kHz(presetID: preset) { hfdl.frequencyKHz = f }
                case .sonde:
                    break
                case .pager:
                    if let preset = request.presetID, let c = PagerChannel(rawValue: preset) { pager.channel = c }
                case .tones:
                    break
                case .dsc:
                    if let preset = request.presetID, let c = DSCChannel(rawValue: preset) { dsc.channel = c }
                    if let center = request.centerHz { dsc.setCenter(center) }
                case .mt63:
                    if let preset = request.presetID, let o = FldigiMT63Core.Options(presetID: preset) { mt63.options = o }
                    if let center = request.centerHz { mt63.setCenter(center) }
                case .mfsk:
                    if let preset = request.presetID, let m = MFSKMode(rawValue: preset) { mfsk.options.mode = m }
                    if let center = request.centerHz { mfsk.setCenter(center) }
                case .hell:
                    if let preset = request.presetID, let m = HellMode(rawValue: preset) { hell.options.mode = m }
                    if let center = request.centerHz { hell.setCenter(center) }
                case .psk:
                    if let preset = request.presetID, let m = PSKMode(rawValue: preset) { psk.options.mode = m }
                    if let center = request.centerHz { psk.setCenter(center) }
                case .skimmer:
                    if let preset = request.presetID, let m = SkimMode(rawValue: preset) { skimmer.mode = m }
                case .ft8:
                    if let preset = request.presetID, let b = FT8Band(rawValue: preset) { ft8.band = b }
                case .ft4:
                    if let preset = request.presetID, let b = FT4Band(rawValue: preset) { ft4.band = b }
                case .wspr:
                    if let preset = request.presetID, let b = WSPRBand(rawValue: preset) { wspr.band = b }
                case .wefax:
                    if let preset = request.presetID, let s = WefaxStation(rawValue: preset) { wefax.station = s }
                    if let center = request.centerHz { wefax.setCenter(center) }
                case .dcf77:
                    if let center = request.centerHz { dcf77.setCenter(center) }
                case .efr:
                    if let preset = request.presetID, let st = EFRStation(rawValue: preset) { efr.station = st }
                    if let center = request.centerHz { efr.setCenter(center) }
                case .sstv:
                    if let preset = request.presetID, let ch = SSTVChannel(rawValue: preset) { sstv.channel = ch }
                    if let center = request.centerHz { sstv.setCenter(center) }
                case .channels:
                    break
                }
            }
            lastRequestError = nil
            lastRequestDate = Date()
            rttyController.sourceDescription = request.sourceDisplayName
            dcf77Controller.sourceDescription = request.sourceDisplayName
            efrController.sourceDescription = request.sourceDisplayName
            sstvController.sourceDescription = request.sourceDisplayName
            rig.apply(request: request)
            if audioStarted {
                audio.apply(request: request)
            } else {
                startAudio()
            }
        case .failure(let error):
            lastRequestError = error.description
        }
    }

    /// Wie zeigt das Modul seine Daten? Ohne Ortsdaten immer als Liste.
    public func mapLayout(_ module: DecoderModuleInfo) -> MapLayout {
        guard module.hasMap else { return .list }
        return mapLayouts[module.rawValue].flatMap(MapLayout.init(rawValue:)) ?? .list
    }

    public func setMapLayout(_ layout: MapLayout, for module: DecoderModuleInfo) {
        guard module.hasMap else { return }
        mapLayouts[module.rawValue] = layout.rawValue
        UserDefaults.standard.set(mapLayouts, forKey: "mapLayouts")
    }

    /// Zeigt das Modul die Karte (allein oder neben der Liste)?
    public func isMapVisible(_ module: DecoderModuleInfo) -> Bool {
        mapLayout(module) != .list
    }

    public func select(module: DecoderModuleInfo) {
        guard module.isAvailable else { return }
        activeModule = module
    }

    /// Station des Skimmers im CW- bzw. PSK-Modul öffnen: Modul wechseln und den Ton auf das Signal stellen
    /// (dort liest der fldigi-Empfänger mit AFC und allen Einstellungen)
    public func openSkimmerStation(_ station: SkimStation) {
        switch station.mode {
        case .cw:
            cw.setCenter(station.audioHz)
            select(module: .cw)
        case .psk31, .psk63:
            var o = psk.options
            o.mode = station.mode == .psk63 ? .bpsk63 : .bpsk31
            psk.options = o
            psk.setCenter(station.audioHz)
            select(module: .psk)
        }
    }

    public func cleanup() {
        if rttyController.isRecording { rttyController.toggleRecording() }   // WAV-Kopf abschließen
        sdrController.stopSource()                                          // Gerät sauber schließen
        dabController.stopSource()
        audio.cleanup()
    }
}
