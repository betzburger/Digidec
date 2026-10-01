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
    public let dcf77 = DCF77SettingsStore()
    public let dcf77Controller: DCF77Controller
    public let efr = EFRSettingsStore()
    public let efrController: EFRController
    private var audioStarted = false
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        audio = AudioInputManager()
        waterfall = WaterfallModel(pipeline: audio.pipeline)
        rttyController = RTTYController(pipeline: audio.pipeline, settings: rtty)
        navtexController = NavtexController(pipeline: audio.pipeline, settings: navtex)
        cwController = CWController(pipeline: audio.pipeline, settings: cw)
        wefaxController = WefaxController(pipeline: audio.pipeline, settings: wefax)
        ft8Controller = FT8Controller(pipeline: audio.pipeline, settings: ft8)
        dcf77Controller = DCF77Controller(pipeline: audio.pipeline, settings: dcf77)
        efrController = EFRController(pipeline: audio.pipeline, settings: efr)

        // Nur das gewählte Modul decodiert
        $activeModule
            .receive(on: RunLoop.main)
            .sink { [weak self] module in
                self?.rttyController.decoder.setEnabled(module == .rtty)
                self?.navtexController.setActive(module == .navtex)
                self?.cwController.setActive(module == .cw)
                self?.wefaxController.setActive(module == .wefax)
                self?.ft8Controller.setActive(module == .ft8)
                self?.dcf77Controller.setActive(module == .dcf77)
                self?.efrController.setActive(module == .efr)
            }
            .store(in: &cancellables)

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
            wefaxController.rigFrequencyHz = state.connected ? state.frequencyHz.map(Int64.init) : nil
            navtexController.rigFrequencyHz = state.connected ? state.frequencyHz.map(Double.init) : nil
            dcf77.rigFrequencyHz = state.connected ? state.frequencyHz.map(Int64.init) : nil
            efr.rigFrequencyHz = state.connected ? state.frequencyHz.map(Int64.init) : nil
            rttyController.rigDescription = rig.description
            cwController.rigDescription = rig.description
            dcf77Controller.sourceDescription = rig.description
            efrController.sourceDescription = rig.description
            rttyController.rigState = state
        }
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
                case .wefax:
                    if let preset = request.presetID, let s = WefaxStation(rawValue: preset) { wefax.station = s }
                    if let center = request.centerHz { wefax.setCenter(center) }
                case .dcf77:
                    if let center = request.centerHz { dcf77.setCenter(center) }
                case .efr:
                    if let preset = request.presetID, let st = EFRStation(rawValue: preset) { efr.station = st }
                    if let center = request.centerHz { efr.setCenter(center) }
                }
            }
            lastRequestError = nil
            lastRequestDate = Date()
            rttyController.sourceDescription = request.sourceDisplayName
            dcf77Controller.sourceDescription = request.sourceDisplayName
            efrController.sourceDescription = request.sourceDisplayName
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
