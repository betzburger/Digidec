// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
#if !canImport(AudioToolbox)
import Foundation
import CPulseSimple
import os

public enum LiveCaptureError: Error, CustomStringConvertible {
    case queueCreation(String)
    case deviceSelection(String)
    case start(String)

    public var description: String {
        switch self {
        case .queueCreation(let s):   return "Audio-Eingang konnte nicht angelegt werden (\(s))"
        case .deviceSelection(let s): return "Audiogerät konnte nicht gewählt werden (\(s))"
        case .start(let s):           return "Audio-Eingang startet nicht (\(s))"
        }
    }
}

/// Nimmt von einer PulseAudio-/PipeWire-Quelle auf und schreibt Mono-Samples in die Pipeline (Gegenstück zur CoreAudio-Fassung).
/// Start/Stopp nur auf `workQueue`; gelesen wird auf einem eigenen Faden.
public final class LiveAudioCapture: @unchecked Sendable {
    public static let captureSampleRate: Double = 48_000
    private static let channels = 2
    private static let framesPerBuffer = 2_048

    private let pipeline: AudioPipeline
    private let workQueue = DispatchQueue(label: "com.peterbetz.digidec.audioWork", qos: .userInitiated)
    private let modeLock = OSAllocatedUnfairLock(initialState: ChannelMode.left)
    private var reader: Reader?

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
    }

    deinit { reader?.stop() }

    public var channelMode: ChannelMode {
        get { modeLock.withLock { $0 } }
        set { modeLock.withLock { $0 = newValue } }
    }

    public func start(deviceUID: String, completion: @escaping @Sendable (Result<Void, LiveCaptureError>) -> Void) {
        workQueue.async { [self] in
            teardown()
            completion(setup(deviceUID: deviceUID))
        }
    }

    public func stop(completion: (@Sendable () -> Void)? = nil) {
        workQueue.async { [self] in
            teardown()
            completion?()
        }
    }

    public func stopSynchronously() {
        workQueue.sync { teardown() }
    }

    // MARK: - Nur auf workQueue

    private func setup(deviceUID: String) -> Result<Void, LiveCaptureError> {
        var spec = pa_sample_spec(format: PA_SAMPLE_FLOAT32LE, rate: UInt32(Self.captureSampleRate), channels: UInt8(Self.channels))
        // Kleine Blöcke (etwa 43 ms), damit Stopp und Pegel zeitnah bleiben
        var attributes = pa_buffer_attr(maxlength: UInt32.max, tlength: UInt32.max, prebuf: UInt32.max, minreq: UInt32.max,
                                        fragsize: UInt32(Self.framesPerBuffer * 4 * Self.channels))
        var error: Int32 = 0
        let handle = deviceUID.isEmpty
            ? pa_simple_new(nil, "Digidec", PA_STREAM_RECORD, nil, "Eingang", &spec, nil, &attributes, &error)
            : pa_simple_new(nil, "Digidec", PA_STREAM_RECORD, deviceUID, "Eingang", &spec, nil, &attributes, &error)
        guard let handle else { return .failure(.deviceSelection(String(cString: pa_strerror(error)))) }

        pipeline.sourceChannels = Self.channels
        pipeline.start(inputRate: Self.captureSampleRate)
        let newReader = Reader(stream: handle, owner: self)
        reader = newReader
        newReader.start()
        return .success(())
    }

    private func teardown() {
        guard let reader else { return }
        self.reader = nil
        reader.stop()
        pipeline.stop()
    }

    // MARK: - Lesefaden

    private final class Reader: @unchecked Sendable {
        private let stream: OpaquePointer
        private unowned let owner: LiveAudioCapture
        private let running = OSAllocatedUnfairLock(initialState: true)
        private let finished = DispatchSemaphore(value: 0)
        private let mono = UnsafeMutablePointer<Float>.allocate(capacity: framesPerBuffer * 2)
        private let monoLeft = UnsafeMutablePointer<Float>.allocate(capacity: framesPerBuffer * 2)
        private let monoRight = UnsafeMutablePointer<Float>.allocate(capacity: framesPerBuffer * 2)
        private let raw = UnsafeMutablePointer<Float>.allocate(capacity: framesPerBuffer * channels)

        init(stream: OpaquePointer, owner: LiveAudioCapture) {
            self.stream = stream
            self.owner = owner
        }

        deinit {
            mono.deallocate(); monoLeft.deallocate(); monoRight.deallocate(); raw.deallocate()
        }

        func start() {
            let thread = Thread { [self] in
                var error: Int32 = 0
                while running.withLock({ $0 }) {
                    let bytes = LiveAudioCapture.framesPerBuffer * 4 * LiveAudioCapture.channels
                    guard pa_simple_read(stream, raw, bytes, &error) >= 0 else { break }
                    owner.handle(raw, frames: LiveAudioCapture.framesPerBuffer, mono: mono, left: monoLeft, right: monoRight)
                }
                pa_simple_free(stream)
                finished.signal()
            }
            thread.name = "Digidec Audio-Eingang"
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        func stop() {
            running.withLock { $0 = false }
            finished.wait()
        }
    }

    private func handle(_ src: UnsafePointer<Float>, frames: Int, mono: UnsafeMutablePointer<Float>,
                        left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        ChannelMode.extract(interleaved: src, frames: frames, channels: Self.channels, mode: channelMode, into: mono)
        pipeline.ring.write(mono, count: frames)
        if pipeline.wantsStereo {
            ChannelMode.extract(interleaved: src, frames: frames, channels: Self.channels, mode: .left, into: left)
            ChannelMode.extract(interleaved: src, frames: frames, channels: Self.channels, mode: .right, into: right)
            pipeline.writeStereo(left: left, right: right, count: frames)
        }
    }
}
#endif
