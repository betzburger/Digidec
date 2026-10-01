import Foundation
import SwiftUI
import AVFoundation
import Combine

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
    public let navtex = NavtexSettingsStore()
    public let navtexController: NavtexController
    public let cw = CWSettingsStore()
    public let cwController: CWController
    public let wefax = WefaxSettingsStore()
    public let wefaxController: WefaxController
    public let ft8 = FT8SettingsStore()
    public let ft8Controller: FT8Controller
    public let ft4 = FT4SettingsStore()
    public let ft4Controller: FT4Controller
    public let dcf77 = DCF77SettingsStore()
    public let dcf77Controller: DCF77Controller
    public let efr = EFRSettingsStore()
    public let efrController: EFRController
    public let sstv = SSTVSettingsStore()
    public let sstvController: SSTVController
    public let wefaxSchedule = WefaxScheduleStore()
    public private(set) var wefaxAuto: WefaxAutoRecorder!
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
        wefaxController = WefaxController(pipeline: audio.pipeline, settings: wefax)
        ft8Controller = FT8Controller(pipeline: audio.pipeline, settings: ft8)
        ft4Controller = FT4Controller(pipeline: audio.pipeline, settings: ft4)
        dcf77Controller = DCF77Controller(pipeline: audio.pipeline, settings: dcf77)
        efrController = EFRController(pipeline: audio.pipeline, settings: efr)
        sstvController = SSTVController(pipeline: audio.pipeline, settings: sstv)

        wefaxAuto = WefaxAutoRecorder(state: self, store: wefaxSchedule)

        // Nur das gewählte Modul decodiert
        $activeModule
            .receive(on: RunLoop.main)
            .sink { [weak self] module in
                self?.rttyController.decoder.setEnabled(module == .rtty)
                self?.navtexController.setActive(module == .navtex)
                self?.cwController.setActive(module == .cw)
                self?.wefaxController.setActive(module == .wefax)
                self?.ft8Controller.setActive(module == .ft8)
                self?.ft4Controller.setActive(module == .ft4)
                self?.dcf77Controller.setActive(module == .dcf77)
                self?.efrController.setActive(module == .efr)
                self?.sstvController.setActive(module == .sstv)
            }
            .store(in: &cancellables)

        // Funkgerät folgt den Voreinstellungen: Moduswechsel und Klick auf Band/Kanal/Sender stellen es ab (wenn freigegeben)
        observeForTuning($activeModule)
        observeForTuning(ft8.$band)
        observeForTuning(ft4.$band)
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
            wefaxController.rigFrequencyHz = state.connected ? state.frequencyHz.map(Int64.init) : nil
            navtexController.rigFrequencyHz = state.connected ? state.frequencyHz.map(Double.init) : nil
            dcf77.rigFrequencyHz = state.connected ? state.frequencyHz.map(Int64.init) : nil
            efr.rigFrequencyHz = state.connected ? state.frequencyHz.map(Int64.init) : nil
            sstv.rigIsLSB = state.isLSB
            sstv.rigDialHz = state.connected ? state.frequencyHz.map { Int($0) } : nil
            sstvController.rigFrequencyHz = state.connected ? state.frequencyHz.map(Int64.init) : nil
            rttyController.rigDescription = rig.description
            cwController.rigDescription = rig.description
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
        case .sstv:   return .sstv(channel: sstv.channel)
        case .efr:    return .efr(station: efr.station, centerHz: efr.centerHz)
        case .dcf77:  return .dcf77(centerHz: dcf77.centerHz)
        case .wefax:  return .wefax(station: wefax.station, centerHz: wefax.centerHz)
        case .navtex: return .navtex(frequency: navtex.frequency, centerHz: navtex.centerHz)
        case .rtty, .cw: return nil
        }
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
            if let request = state.currentRequest, RadioSource(requestSource: request.source) != nil || request.deviceUID != nil {
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
                case .ft8:
                    if let preset = request.presetID, let b = FT8Band(rawValue: preset) { ft8.band = b }
                case .ft4:
                    if let preset = request.presetID, let b = FT4Band(rawValue: preset) { ft4.band = b }
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

    public func select(module: DecoderModuleInfo) {
        guard module.isAvailable else { return }
        activeModule = module
    }

    public func cleanup() {
        if rttyController.isRecording { rttyController.toggleRecording() }   // WAV-Kopf abschließen
        audio.cleanup()
    }
}
