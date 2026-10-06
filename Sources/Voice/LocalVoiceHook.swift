// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import VoiceCore
#if DIGIDEC_LOCAL_VOCODER
import LocalVocoder
#endif

/// Trägt die Sprachdecoder in `VoiceRegistry.shared` ein: den Sprachstick (wenn sein Anschluss gewählt ist)
/// und, falls vorhanden, lokal gebaute Decoder, die nicht Teil des Repositorys sind.
enum LocalVoiceHook {
    /// Umgebung `DIGIDEC_AMBE_PORT` oder Einstellung `voiceStickPort`, z. B. `/dev/cu.usbserial-0001`.
    /// Der Stick wird nur geöffnet, wenn der Anschluss ausdrücklich gewählt ist: andere serielle Geräte
    /// (etwa das CAT-Kabel des Funkgeräts) bekommen so keine fremden Pakete.
    static var stickPort: String? {
        let port = ProcessInfo.processInfo.environment["DIGIDEC_AMBE_PORT"] ?? UserDefaults.standard.string(forKey: "voiceStickPort")
        return (port?.isEmpty ?? true) ? nil : port
    }

    static func install() {
        if let port = stickPort {
            do {
                VoiceRegistry.shared.register(try AMBE3000Stick(path: port))
            } catch {
                FileHandle.standardError.write(Data("Sprachstick \(port): \(error)\n".utf8))
            }
        }
        #if DIGIDEC_LOCAL_VOCODER
        registerLocalVoiceDecoders(into: .shared)
        #endif
    }
}
