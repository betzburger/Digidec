// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import AudioToolbox
import CoreAudio
import os

public enum LiveCaptureError: Error, CustomStringConvertible {
    case queueCreation(OSStatus)
    case deviceSelection(OSStatus)
    case start(OSStatus)

    public var description: String {
        switch self {
        case .queueCreation(let s):   return "Audio-Eingang konnte nicht angelegt werden (\(s))"
        case .deviceSelection(let s): return "Audiogerät konnte nicht gewählt werden (\(s))"
        case .start(let s):           return "Audio-Eingang startet nicht (\(s))"
        }
    }
}

/// Nimmt von einem CoreAudio-Gerät (Standard: VALHost 2ch) auf und schreibt Mono-Samples in die Pipeline.
/// Gleiches Muster wie die Commander (AudioQueue + `kAudioQueueProperty_CurrentDevice`):
/// Start/Stop nur auf `workQueue`, nie synchron auf dem Main Thread.
public final class LiveAudioCapture: @unchecked Sendable {
    /// CoreAudio wandelt von der Geräte-Rate (VALHost: 44,1 kHz) auf diese Rate.
    public static let captureSampleRate: Double = 48_000
    private static let channels = 2
    private static let framesPerBuffer = 2_048

    private let pipeline: AudioPipeline
    private let workQueue = DispatchQueue(label: "com.peterbetz.digidec.audioWork", qos: .userInitiated)
    private let modeLock = OSAllocatedUnfairLock(initialState: ChannelMode.left)
    private var queue: AudioQueueRef?
    /// Nur im Audio-Callback benutzt
    private let mono = UnsafeMutablePointer<Float>.allocate(capacity: framesPerBuffer * 2)
    private let monoLeft = UnsafeMutablePointer<Float>.allocate(capacity: framesPerBuffer * 2)
    private let monoRight = UnsafeMutablePointer<Float>.allocate(capacity: framesPerBuffer * 2)

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
    }

    deinit {
        if let q = queue {
            AudioQueueStop(q, true)
            AudioQueueDispose(q, true)
        }
        mono.deallocate()
        monoLeft.deallocate()
        monoRight.deallocate()
    }

    public var channelMode: ChannelMode {
        get { modeLock.withLock { $0 } }
        set { modeLock.withLock { $0 = newValue } }
    }

    /// Startet die Aufnahme vom Gerät mit der UID; eine laufende Aufnahme wird vorher beendet.
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

    /// Beim Beenden der App: synchron, damit CoreAudio sauber freigegeben ist.
    public func stopSynchronously() {
        workQueue.sync { teardown() }
    }

    // MARK: - Nur auf workQueue

    private func setup(deviceUID: String) -> Result<Void, LiveCaptureError> {
        var format = AudioStreamBasicDescription(
            mSampleRate: Self.captureSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * Self.channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * Self.channels),
            mChannelsPerFrame: UInt32(Self.channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var newQueue: AudioQueueRef?
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioQueueNewInput(&format, { userData, queue, buffer, _, _, _ in
            guard let userData else { return }
            let this = Unmanaged<LiveAudioCapture>.fromOpaque(userData).takeUnretainedValue()
            this.handle(buffer)
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }, selfPtr, nil, nil, 0, &newQueue)
        guard status == noErr, let q = newQueue else { return .failure(.queueCreation(status)) }

        var uid = deviceUID as CFString
        let devStatus = withUnsafePointer(to: &uid) { ptr in
            AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, ptr, UInt32(MemoryLayout<CFString>.size))
        }
        guard devStatus == noErr else {
            AudioQueueDispose(q, true)
            return .failure(.deviceSelection(devStatus))
        }

        let bytes = UInt32(Self.framesPerBuffer * 4 * Self.channels)
        for _ in 0..<4 {
            var buf: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(q, bytes, &buf) == noErr, let b = buf {
                AudioQueueEnqueueBuffer(q, b, 0, nil)
            }
        }

        pipeline.sourceChannels = Self.channels
        pipeline.start(inputRate: Self.captureSampleRate)
        let startStatus = AudioQueueStart(q, nil)
        guard startStatus == noErr else {
            AudioQueueDispose(q, true)
            pipeline.stop()
            return .failure(.start(startStatus))
        }
        queue = q
        return .success(())
    }

    private func teardown() {
        guard let q = queue else { return }
        queue = nil
        AudioQueueStop(q, true)
        AudioQueueDispose(q, true)
        pipeline.stop()
    }

    // MARK: - Audio-Thread: keine Allokation, nur Kopieren

    private func handle(_ buffer: AudioQueueBufferRef) {
        let frames = min(Int(buffer.pointee.mAudioDataByteSize) / (4 * Self.channels), Self.framesPerBuffer * 2)
        guard frames > 0 else { return }
        let src = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
        ChannelMode.extract(interleaved: src, frames: frames, channels: Self.channels, mode: channelMode, into: mono)
        pipeline.ring.write(mono, count: frames)
        if pipeline.wantsStereo {
            ChannelMode.extract(interleaved: src, frames: frames, channels: Self.channels, mode: .left, into: monoLeft)
            ChannelMode.extract(interleaved: src, frames: frames, channels: Self.channels, mode: .right, into: monoRight)
            pipeline.writeStereo(left: monoLeft, right: monoRight, count: frames)
        }
    }
}
