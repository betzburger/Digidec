import Foundation
import SwiftUI

/// Frequenz und Mode des Funkgeräts – per rigctld: entweder der Commander, dessen Codec Digidec gerade liest (Automatik),
/// oder ein frei eingestelltes Gerät (`RigProfile`: Rechner, Port, Name), egal welches Audiogerät gelesen wird.
@MainActor
public final class RigModel: ObservableObject {
    @Published public private(set) var state = RigState()
    /// Commander-Funkgerät, dessen Codec gerade gelesen wird (nil = keins, z. B. bei VALHost 2ch oder Dateiwiedergabe)
    @Published public private(set) var radio: RadioSource?
    /// Frei eingestelltes Funkgerät, das gerade gilt (hat Vorrang vor der Automatik)
    @Published public private(set) var customProfile: RigProfile?
    /// Ein Auftrag per URL hat die gespeicherte Wahl für diese Sitzung übersteuert
    @Published public private(set) var overriddenByRequest = false

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

    /// Gibt es ein Funkgerät, dessen Frequenz und Mode abgefragt werden (verbunden oder nicht)?
    public var hasRig: Bool { radio != nil || customProfile != nil }

    /// Name des Funkgeräts für Anzeige, Log und Dateinamen
    public var rigName: String? { customProfile?.displayName ?? radio?.displayName }

    /// Auftrag eines Programms per URL: Mit einem Commander (`source=pcr1500|ft991a`) gilt wieder die Automatik; jede andere
    /// Quelle mit `rigctl=<Port>` wird als Gerät auf diesem Rechner (127.0.0.1) für diese Sitzung verwendet.
    /// Rechner außer 127.0.0.1 gibt es nur in den Einstellungen, nie per URL.
    public func apply(request: DecodeRequest) {
        guard let port = request.rigctlPort else { return }
        if let radio = RadioSource(requestSource: request.source) {
            requestPort = (radio, UInt16(port))
            customProfile = nil
            overriddenByRequest = true
        } else if let source = request.source {
            customProfile = RigProfile(id: "request", name: source, host: RigProfile.defaultHost, port: port)
            overriddenByRequest = true
        } else {
            return
        }
        updateConnection()
    }

    /// Das in den Einstellungen gewählte Gerät verwenden (nil = Automatik über den USB-Codec)
    public func use(profile: RigProfile?) {
        customProfile = profile
        overriddenByRequest = false
        updateConnection()
    }

    /// Welches Commander-Funkgerät gerade Audio liefert – bestimmt in der Automatik den rigctld-Port
    public func follow(radio newRadio: RadioSource?) {
        radio = newRadio
        updateConnection()
    }

    private func updateConnection() {
        if let profile = customProfile {
            client.setEndpoint(profile.endpoint)
            return
        }
        guard let r = radio else {
            client.setEndpoint(nil)
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
        guard let name = rigName else { return nil }
        var s = name
        if state.connected, let f = state.frequencyText {
            s += " · \(f)"
            if let m = state.mode { s += " \(m)" }
        }
        return s
    }
}
