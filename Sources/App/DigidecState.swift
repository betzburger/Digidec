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
    /// Eigener Standort für alle Karten und Entfernungen
    public let home = HomeLocation()
    public let navtex = NavtexSettingsStore()
    public let navtexController: NavtexController
    public let cw = CWSettingsStore()
    public let cwController: CWController
    public let psk = PSKSettingsStore()
    public let pskController: PSKController
    public let olivia = OliviaSettingsStore()
    public let oliviaController: OliviaController
    public let mt63 = MT63SettingsStore()
    public let mt63Controller: MT63Controller
    public let dsc = DSCSettingsStore()
    public let dscController: DSCController
    public let ale = ALESettingsStore()
    public let aleController: ALEController
    public let aprs = APRSSettingsStore()
    public let aprsController: APRSController
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
    public private(set) var autoRecorder: ScheduleAutoRecorder!
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
        oliviaController = OliviaController(pipeline: audio.pipeline, settings: olivia)
        mt63Controller = MT63Controller(pipeline: audio.pipeline, settings: mt63)
        dscController = DSCController(pipeline: audio.pipeline, settings: dsc)
        aleController = ALEController(pipeline: audio.pipeline, settings: ale)
        aprsController = APRSController(pipeline: audio.pipeline, settings: aprs)
        pagerController = PagerController(pipeline: audio.pipeline, settings: pager)
        tonesController = TonesController(pipeline: audio.pipeline, settings: tones)
        wefaxController = WefaxController(pipeline: audio.pipeline, settings: wefax)
        ft8Controller = FT8Controller(pipeline: audio.pipeline, settings: ft8)
        ft4Controller = FT4Controller(pipeline: audio.pipeline, settings: ft4)
        wsprController = WSPRController(pipeline: audio.pipeline, settings: wspr)
        dcf77Controller = DCF77Controller(pipeline: audio.pipeline, settings: dcf77)
        efrController = EFRController(pipeline: audio.pipeline, settings: efr)
        sstvController = SSTVController(pipeline: audio.pipeline, settings: sstv)

        autoRecorder = ScheduleAutoRecorder(state: self, wefax: wefaxSchedule, rtty: rttySchedule, navtex: navtexPlan)

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
                self?.rttyController.decoder.setEnabled(module == .rtty)
                self?.navtexController.setActive(module == .navtex)
                self?.cwController.setActive(module == .cw)
                self?.pskController.setActive(module == .psk)
                self?.oliviaController.setActive(module == .olivia)
                self?.mt63Controller.setActive(module == .mt63)
                self?.dscController.setActive(module == .dsc)
                self?.aleController.setActive(module == .ale)
                self?.aprsController.setActive(module == .aprs)
                self?.pagerController.setActive(module == .pager)
                self?.tonesController.setActive(module == .tones)
                self?.wefaxController.setActive(module == .wefax)
                self?.ft8Controller.setActive(module == .ft8)
                self?.ft4Controller.setActive(module == .ft4)
                self?.wsprController.setActive(module == .wspr)
                self?.dcf77Controller.setActive(module == .dcf77)
                self?.efrController.setActive(module == .efr)
                self?.sstvController.setActive(module == .sstv)
            }
            .store(in: &cancellables)

        // Funkgerät folgt den Voreinstellungen: Moduswechsel und Klick auf Band/Kanal/Sender stellen es ab (wenn freigegeben)
        observeForTuning($activeModule)
        observeForTuning(ft8.$band)
        observeForTuning(ft4.$band)
        observeForTuning(wspr.$band)
        observeForTuning(psk.$band)
        observeForTuning(dsc.$channel)
        observeForTuning(aprs.$channel)
        observeForTuning(pager.$channel)
        observeForTuning(sstv.$channel)
        observeForTuning(efr.$station)
        observeForTuning(wefax.$station)
        observeForTuning(navtex.$frequency)

        // rigctld des Funkgeräts, dessen Codec gerade gelesen wird (bei Dateiwiedergabe keins)
        audio.$activeInput.combineLatest(audio.$sourceKind)
            .receive(on: RunLoop.main)
            .sink { [weak self] input, kind in
                self?.rig.follow(radio: kind == .live ? input?.radio : nil)
            }
            .store(in: &cancellables)
        rig.onChange = { [weak self] state in
            guard let self else { return }
            rtty.rigIsLSB = state.isLSB
            navtex.rigIsLSB = state.isLSB
            wefax.rigIsLSB = state.isLSB
            ft8.rigDialHz = state.connected ? state.frequencyHz.map { Int($0) } : nil
            ft4.rigDialHz = state.connected ? state.frequencyHz.map { Int($0) } : nil
            wspr.rigDialHz = state.connected ? state.frequencyHz.map { Int($0) } : nil
            wefaxController.rigFrequencyHz = state.connected ? state.frequencyHz.map(Int64.init) : nil
            navtexController.rigFrequencyHz = state.connected ? state.frequencyHz.map(Double.init) : nil
            dcf77.rigFrequencyHz = state.connected ? state.frequencyHz.map(Int64.init) : nil
            efr.rigFrequencyHz = state.connected ? state.frequencyHz.map(Int64.init) : nil
            sstv.rigIsLSB = state.isLSB
            sstv.rigDialHz = state.connected ? state.frequencyHz.map { Int($0) } : nil
            sstvController.rigFrequencyHz = state.connected ? state.frequencyHz.map(Int64.init) : nil
            rttyController.rigDescription = rig.description
            cwController.rigDescription = rig.description
            pskController.rigDescription = rig.description
            oliviaController.rigDescription = rig.description
            mt63Controller.rigDescription = rig.description
            dscController.rigDescription = rig.description
            aleController.rigDescription = rig.description
            aprsController.rigDescription = rig.description
            pagerController.rigDescription = rig.description
            tonesController.rigDescription = rig.description
            dcf77Controller.sourceDescription = rig.description
            efrController.sourceDescription = rig.description
            sstvController.sourceDescription = rig.description
            rttyController.rigState = state
        }
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
        case .sstv:   return .sstv(channel: sstv.channel)
        case .efr:    return .efr(station: efr.station, centerHz: efr.centerHz)
        case .dcf77:  return .dcf77(centerHz: dcf77.centerHz)
        case .wefax:  return .wefax(station: wefax.station, centerHz: wefax.centerHz)
        case .navtex: return .navtex(frequency: navtex.frequency, centerHz: navtex.centerHz)
        case .dsc:    return .dsc(channel: dsc.channel, centerHz: dsc.centerHz)
        case .aprs:   return .aprs(channel: aprs.channel)
        case .pager:  return .pager(channel: pager.channel)
        case .rtty, .cw, .olivia, .mt63, .ale, .tones: return nil
        }
    }

    /// Stimmt das Funkgerät auf ein Ziel ab (geplante Aufnahme) – nur mit Freigabe (QSY AUTO) und Verbindung.
    /// Die Abstimmung nach Modul-/Voreinstellungswechsel wird kurz unterdrückt, damit nicht doppelt gesendet wird.
    public func tuneRig(to target: RigTuneTarget) {
        guard rigControlEnabled, rig.radio != nil else { return }
        suppressRigTuneUntil = Date().addingTimeInterval(3.0)
        rig.tune(to: target)
    }

    /// Stellt das Funkgerät auf das Ziel des aktiven Moduls – nur mit Freigabe und Verbindung
    public func tuneRigForActiveModule() {
        guard rigControlEnabled, Date() >= suppressRigTuneUntil, rig.radio != nil,
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
            // Entwicklungshilfe: DIGIDEC_PLAY_FILE=/Pfad/aufnahme.wav spielt eine Datei statt des Live-Eingangs ab
            if let path = ProcessInfo.processInfo.environment["DIGIDEC_PLAY_FILE"] {
                state.audio.openFile(URL(fileURLWithPath: path))
                state.audio.playFile()
            } else if let request = state.currentRequest, RadioSource(requestSource: request.source) != nil || request.deviceUID != nil {
                state.audio.apply(request: request)
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
                case .psk:
                    if let preset = request.presetID, let m = PSKMode(rawValue: preset) { psk.options.mode = m }
                    if let center = request.centerHz { psk.setCenter(center) }
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

    public func cleanup() {
        if rttyController.isRecording { rttyController.toggleRecording() }   // WAV-Kopf abschließen
        audio.cleanup()
    }
}
