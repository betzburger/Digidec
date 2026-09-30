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
    private var audioStarted = false
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        audio = AudioInputManager()
        waterfall = WaterfallModel(pipeline: audio.pipeline)
        rttyController = RTTYController(pipeline: audio.pipeline, settings: rtty)

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
            rttyController.rigDescription = rig.description
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
            activeModule = request.module
            lastRequestError = nil
            lastRequestDate = Date()
            if request.module == .rtty {
                rtty.select(presetID: request.presetID)
                if let center = request.centerHz {
                    rtty.setCenter(center)
                }
            }
            rttyController.sourceDescription = request.sourceDisplayName
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
        audio.cleanup()
    }
}
