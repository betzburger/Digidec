import Foundation
import SwiftUI

/// Zentraler App-Zustand. Ab M2 kommen Audio-Eingang, ab M5 der RTTY-Decoder, ab M7 der rigctld-Client dazu.
@MainActor
public final class DigidecState: ObservableObject {
    public static let shared = DigidecState()

    @Published public var activeModule: DecoderModuleInfo = .rtty
    /// Letzter gültiger Auftrag eines Hauptprogramms (URL-Schema).
    @Published public private(set) var currentRequest: DecodeRequest?
    /// Meldung zum letzten abgelehnten Auftrag, für die Statuszeile.
    @Published public private(set) var lastRequestError: String?

    private init() {}

    public func handle(url: URL) {
        switch DecodeRequestParser.parse(url) {
        case .success(let request):
            currentRequest = request
            activeModule = request.module
            lastRequestError = nil
        case .failure(let error):
            lastRequestError = error.description
        }
    }

    public func select(module: DecoderModuleInfo) {
        guard module.isAvailable else { return }
        activeModule = module
    }

    public func cleanup() {
        // Ab M2: Audio-Eingang asynchron auf der Audio-Queue stoppen (PLAN.md, Abschnitt 6).
    }
}
