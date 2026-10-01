import Foundation
import SwiftUI

/// Frequenz und Mode des Funkgeräts, dessen Codec Digidec gerade liest – per rigctld des zugehörigen Commanders.
@MainActor
public final class RigModel: ObservableObject {
    @Published public private(set) var state = RigState()
    /// Funkgerät, zu dem die Verbindung gehört (nil = keine, z. B. bei VALHost 2ch oder Dateiwiedergabe)
    @Published public private(set) var radio: RadioSource?

    private var client: RigctlClient!
    /// Port aus einem Auftrag (gilt, solange das Auftrags-Funkgerät gelesen wird)
    private var requestPort: (radio: RadioSource, port: UInt16)?
    public var onChange: ((RigState) -> Void)?

    public init() {
        client = RigctlClient { [weak self] s in
            Task { @MainActor in
                guard let self else { return }
                self.state = s
                self.onChange?(s)
            }
        }
    }

    /// Auftrag eines Commanders: dessen rigctld-Port merken
    public func apply(request: DecodeRequest) {
        if let radio = RadioSource(requestSource: request.source), let port = request.rigctlPort {
            requestPort = (radio, UInt16(port))
        }
    }

    /// Welches Funkgerät gerade Audio liefert – bestimmt den rigctld-Port
    public func follow(radio newRadio: RadioSource?) {
        radio = newRadio
        guard let r = newRadio else {
            client.setPort(nil)
            return
        }
        if let rp = requestPort, rp.radio == r {
            client.setPort(rp.port)
        } else {
            client.setPort(RigctlClient.defaultPort(for: r))
        }
    }

    /// Meldung zum letzten Abstimmversuch (nil = keiner)
    @Published public private(set) var tuneMessage: String?

    /// Stellt das Funkgerät auf `target` ein (nur wenn eine Verbindung besteht). Der Aufrufer prüft die Freigabe des Nutzers.
    public func tune(to target: RigTuneTarget) {
        guard state.connected else {
            tuneMessage = "Funkgerät nicht erreichbar – nicht abgestimmt"
            return
        }
        tuneMessage = "Stimme Funkgerät ab: \(target.label) …"
        client.tune(frequencyHz: target.dialHz, mode: target.mode, passbandHz: target.passbandHz) { [weak self] result in
            Task { @MainActor in
                switch result {
                case .ok: self?.tuneMessage = "Funkgerät → \(target.label)"
                case .notConnected: self?.tuneMessage = "Funkgerät nicht erreichbar – nicht abgestimmt"
                case .rejected(let why): self?.tuneMessage = "Funkgerät lehnt ab (\(why))"
                }
            }
        }
    }

    /// „IC-PCR1500 · 4.584,700 kHz LSB“ bzw. nur der Gerätename ohne Verbindung
    public var description: String? {
        guard let radio else { return nil }
        var s = radio.displayName
        if state.connected, let f = state.frequencyText {
            s += " · \(f)"
            if let m = state.mode { s += " \(m)" }
        }
        return s
    }
}
