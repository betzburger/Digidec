// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
#if !canImport(AVFoundation)
import Foundation
import CPulseSimple
import os

/// Ton-Ausgabe nach dem Ziehprinzip (Linux): `render` füllt Blöcke mit verschachtelten Gleitkommawerten, ein Faden schreibt sie nach PulseAudio/PipeWire.
/// Gegenstück zu `AVAudioSourceNode` unter macOS.
final class PullAudioOutput: @unchecked Sendable {
    typealias Render = @Sendable (_ interleaved: UnsafeMutablePointer<Float>, _ frames: Int) -> Void

    private struct StreamBox: @unchecked Sendable { let pointer: OpaquePointer }

    private let sampleRate: Int
    private let channels: Int
    private let blockFrames: Int
    private let render: Render
    private let running = OSAllocatedUnfairLock(initialState: false)
    private var finished: DispatchSemaphore?

    init(sampleRate: Int, channels: Int, blockFrames: Int = 1024, render: @escaping Render) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.blockFrames = blockFrames
        self.render = render
    }

    deinit { stop() }

    /// Verbindung zum Ton-Server öffnen; `nil`, wenn er nicht erreichbar ist
    private func open() -> StreamBox? {
        var spec = pa_sample_spec(format: PA_SAMPLE_FLOAT32LE, rate: UInt32(sampleRate), channels: UInt8(channels))
        // Etwa 100 ms Vorlauf im Server: genug gegen Aussetzer, kurz genug für Lautstärke- und Stummschaltung
        var attributes = pa_buffer_attr(maxlength: UInt32.max, tlength: UInt32(sampleRate * channels * 4 / 10), prebuf: UInt32.max, minreq: UInt32.max, fragsize: UInt32.max)
        var error: Int32 = 0
        guard let stream = pa_simple_new(nil, "Digidec", PA_STREAM_PLAYBACK, nil, "Ton", &spec, nil, &attributes, &error) else { return nil }
        return StreamBox(pointer: stream)
    }

    /// `false`, wenn der Ton-Server nicht erreichbar ist
    func start() -> Bool {
        guard !running.withLock({ $0 }) else { return true }
        guard let first = open() else { return false }
        running.withLock { $0 = true }
        let done = DispatchSemaphore(value: 0)
        finished = done
        let thread = Thread { [self] in
            var box: StreamBox? = first
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames * channels)
            defer { buffer.deallocate() }
            var err: Int32 = 0
            while running.withLock({ $0 }) {
                guard let stream = box?.pointer else {
                    // Der Ton-Server ist weg (PipeWire/PulseAudio neu gestartet, Ausgabegerät entfernt): jede halbe Sekunde neu verbinden,
                    // sonst bliebe der Ton stumm, bis man das Modul neu startet. Der Erzeuger läuft weiter; sein Ringpuffer verwirft Altes.
                    Thread.sleep(forTimeInterval: 0.5)
                    box = open()
                    continue
                }
                render(buffer, blockFrames)
                if pa_simple_write(stream, buffer, blockFrames * channels * 4, &err) < 0 {
                    pa_simple_free(stream)
                    box = nil
                }
            }
            if let stream = box?.pointer {
                // Beim Anhalten nicht ausspielen lassen (drain wartet auf den Server): den Rest verwerfen
                pa_simple_flush(stream, &err)
                pa_simple_free(stream)
            }
            done.signal()
        }
        thread.name = "Digidec Ton-Ausgabe"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    /// Hält den Ausgabefaden an. Hängt der Ton-Server, wird nach 2 s nicht länger gewartet (der Faden gibt den Strom selbst frei,
    /// sobald der Schreibaufruf zurückkehrt) – Beenden und Modulwechsel blockieren so nie.
    func stop() {
        guard running.withLock({ let was = $0; $0 = false; return was }) else { return }
        _ = finished?.wait(timeout: .now() + 2)
        finished = nil
    }
}
#endif
