// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import VoiceCore

/// Gemeinsame Tonausgabe der Sprachmodule (D-Star, YSF, DMR): Sprachstick öffnen (nur einmal je Anschluss), Rahmen in Ton wandeln, abspielen.
@MainActor
public final class VoiceOutput: ObservableObject {
    public static let shared = VoiceOutput()

    /// Anschluss des Sprachsticks (`/dev/cu.…`) oder leer
    @Published public var stickPort: String { didSet { UserDefaults.standard.set(stickPort, forKey: "voiceStickPort") } }
    /// Ton ausgeben, wenn ein Sprachdecoder da ist
    @Published public var playAudio: Bool { didSet { UserDefaults.standard.set(playAudio, forKey: "voicePlayAudio") } }
    /// Name des Decoders, der den Ton liefert; `nil` = keiner
    @Published public private(set) var decoderName: String?
    @Published public private(set) var error: String?

    private let player = VoicePlayer()
    private var playerRunning = false
    private let queue = DispatchQueue(label: "digidec.voice.output")
    private var stick: AMBE3000Stick?

    public init() {
        let d = UserDefaults.standard
        // Umgebung `DIGIDEC_AMBE_PORT` hat Vorrang (wird nicht gespeichert)
        stickPort = ProcessInfo.processInfo.environment["DIGIDEC_AMBE_PORT"] ?? d.string(forKey: "voiceStickPort") ?? ""
        playAudio = d.object(forKey: "voicePlayAudio") as? Bool ?? d.object(forKey: "dstarPlayAudio") as? Bool ?? true
        if !stickPort.isEmpty { connect() }
        refresh()
    }

    /// Öffnet den Stick am eingestellten Anschluss (oder gibt ihn frei, wenn leer) und trägt ihn in die Sammlung ein.
    public func connect() {
        error = nil
        VoiceRegistry.shared.removeAll(where: { $0.isHardware })
        stick = nil
        if !stickPort.isEmpty {
            do {
                let opened = try AMBE3000Stick(path: stickPort)
                stick = opened
                VoiceRegistry.shared.register(opened)
            } catch {
                self.error = "\(stickPort): \(error)"
            }
        }
        refresh()
    }

    /// Name des besten Decoders neu lesen (lokale Decoder können nach dem Start dazukommen)
    public func refresh() {
        let name = VoiceRegistry.shared.preferred(for: .dstar)?.name
        if name != decoderName { decoderName = name }
    }

    public func hasDecoder(for profile: VoiceProfile) -> Bool { VoiceRegistry.shared.preferred(for: profile) != nil }

    /// Gibt es einen Sprachdecoder für TETRA?
    public var tetraAvailable: Bool { VoiceRegistry.shared.tetraDecoder != nil }

    /// Wiedergabe für Echtzeitton (TETRA): startet bei Bedarf und gibt den Spieler zurück
    public func startLivePlayer() -> VoicePlayer? {
        if !playerRunning {
            do { try player.start(); playerRunning = true } catch { self.error = "Wiedergabe: \(error)"; return nil }
        }
        return player
    }

    /// Ein gespeichertes TETRA-Gespräch noch einmal abspielen (der Decoder beginnt mit frischem Zustand)
    public func playTetra(_ chunks: [TETRASpeechChunk]) {
        guard playAudio, !chunks.isEmpty, let decoder = VoiceRegistry.shared.tetraDecoder, let player = startLivePlayer() else { return }
        queue.async {
            decoder.reset()
            for c in chunks { player.enqueue(decoder.decode(bits: c.bits, badFrame: c.badFrame)) }
        }
    }

    /// Rahmen (9 Byte im Format des Decoders) in Ton wandeln und abspielen
    public func play(_ frames: [[UInt8]], profile: VoiceProfile) {
        guard playAudio, !frames.isEmpty, let voice = VoiceRegistry.shared.preferred(for: profile) else { return }
        if !playerRunning {
            do { try player.start(); playerRunning = true } catch { self.error = "Wiedergabe: \(error)"; return }
        }
        let player = self.player
        queue.async {
            for bytes in frames {
                guard let frame = VoiceFrame(bytes: bytes), let pcm = try? voice.decode(frame, profile: profile) else { continue }
                player.enqueue(pcm)
            }
        }
    }

    public func stopPlayback() {
        guard playerRunning else { return }
        player.stop()
        playerRunning = false
    }
}
