import Foundation
import SwiftUI
import AVFoundation

/// Zentraler App-Zustand. Ab M5 kommt der RTTY-Decoder, ab M7 der rigctld-Client dazu.
@MainActor
public final class DigidecState: ObservableObject {
    public static let shared = DigidecState()

    @Published public var activeModule: DecoderModuleInfo = .rtty
    /// Letzter gültiger Auftrag eines Hauptprogramms (URL-Schema).
    @Published public private(set) var currentRequest: DecodeRequest?
    /// Meldung zum letzten abgelehnten Auftrag, für die Statuszeile.
    @Published public private(set) var lastRequestError: String?

    public let audio = AudioInputManager()
    private var audioStarted = false

    private init() {}

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
