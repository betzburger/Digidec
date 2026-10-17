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

    /// `false`, wenn der Ton-Server nicht erreichbar ist
    func start() -> Bool {
        guard !running.withLock({ $0 }) else { return true }
        var spec = pa_sample_spec(format: PA_SAMPLE_FLOAT32LE, rate: UInt32(sampleRate), channels: UInt8(channels))
        // Etwa 100 ms Vorlauf im Server: genug gegen Aussetzer, kurz genug für Lautstärke- und Stummschaltung
        var attributes = pa_buffer_attr(maxlength: UInt32.max, tlength: UInt32(sampleRate * channels * 4 / 10), prebuf: UInt32.max, minreq: UInt32.max, fragsize: UInt32.max)
        var error: Int32 = 0
        guard let stream = pa_simple_new(nil, "Digidec", PA_STREAM_PLAYBACK, nil, "Ton", &spec, nil, &attributes, &error) else { return false }
        running.withLock { $0 = true }
        let box = StreamBox(pointer: stream)
        let done = DispatchSemaphore(value: 0)
        finished = done
        let thread = Thread { [self] in
            let stream = box.pointer
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames * channels)
            defer { buffer.deallocate() }
            var err: Int32 = 0
            while running.withLock({ $0 }) {
                render(buffer, blockFrames)
                if pa_simple_write(stream, buffer, blockFrames * channels * 4, &err) < 0 { break }
            }
            pa_simple_drain(stream, &err)
            pa_simple_free(stream)
            done.signal()
        }
        thread.name = "Digidec Ton-Ausgabe"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    func stop() {
        guard running.withLock({ let was = $0; $0 = false; return was }) else { return }
        finished?.wait()
        finished = nil
    }
}
#endif
