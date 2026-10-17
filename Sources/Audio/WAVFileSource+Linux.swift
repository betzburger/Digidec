// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
#if !canImport(AVFoundation)
import Foundation
import CSndfile
import os

public enum WAVFileError: Error, CustomStringConvertible {
    case unreadable(String)
    case empty

    public var description: String {
        switch self {
        case .unreadable(let reason): return "Datei nicht lesbar: \(reason)"
        case .empty:                  return "Datei enthält kein Audio"
        }
    }
}

/// Spielt eine Audiodatei (WAV, AIFF, CAF, FLAC, OGG … über libsndfile) in Echtzeit in die Pipeline, als käme sie vom Empfänger.
public final class WAVFileSource: @unchecked Sendable {
    public let url: URL
    public let sampleRate: Double
    public let channelCount: Int
    public let frameCount: Int
    public var duration: TimeInterval { Double(frameCount) / sampleRate }

    private let file: OpaquePointer
    private let queue = DispatchQueue(label: "com.peterbetz.digidec.wavSource", qos: .userInitiated)
    private let modeLock = OSAllocatedUnfairLock(initialState: ChannelMode.left)
    // Nur auf `queue`
    private var timer: DispatchSourceTimer?
    private var startTime: DispatchTime = .now()
    private var framesDelivered = 0
    private let interleaved: UnsafeMutablePointer<Float>
    private let mono = UnsafeMutablePointer<Float>.allocate(capacity: 16_384)
    private let monoLeft = UnsafeMutablePointer<Float>.allocate(capacity: 16_384)
    private let monoRight = UnsafeMutablePointer<Float>.allocate(capacity: 16_384)
    private static let maxBlock = 16_384

    public init(url: URL) throws {
        var info = SF_INFO()
        guard let opened = sf_open(url.path, Int32(SFM_READ), &info) else {
            throw WAVFileError.unreadable(String(cString: sf_strerror(nil)))
        }
        guard info.frames > 0, info.channels > 0, info.samplerate > 0 else {
            sf_close(opened)
            throw WAVFileError.empty
        }
        file = opened
        self.url = url
        sampleRate = Double(info.samplerate)
        channelCount = Int(info.channels)
        frameCount = Int(info.frames)
        interleaved = .allocate(capacity: Self.maxBlock * Int(info.channels))
    }

    deinit {
        sf_close(file)
        interleaved.deallocate()
        mono.deallocate()
        monoLeft.deallocate()
        monoRight.deallocate()
    }

    public var channelMode: ChannelMode {
        get { modeLock.withLock { $0 } }
        set { modeLock.withLock { $0 = newValue } }
    }

    /// Startet die Wiedergabe von vorn. `progress` (0…1) und `finished` kommen auf der Quell-Queue.
    public func start(into pipeline: AudioPipeline,
                      progress: @escaping @Sendable (Double) -> Void,
                      finished: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            stopInternal()
            sf_seek(file, 0, SEEK_SET)
            framesDelivered = 0
            pipeline.sourceChannels = channelCount
            pipeline.start(inputRate: sampleRate)
            startTime = .now()

            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                if self.pump(into: pipeline) {
                    progress(Double(self.framesDelivered) / Double(self.frameCount))
                } else {
                    self.stopInternal()
                    progress(1)
                    finished()
                }
            }
            timer = t
            t.resume()
        }
    }

    public func stop() {
        queue.async { [self] in stopInternal() }
    }

    private func stopInternal() {
        timer?.cancel()
        timer = nil
    }

    /// Liefert so viele Frames, wie seit dem Start in Echtzeit fällig sind. `false` am Dateiende.
    private func pump(into pipeline: AudioPipeline) -> Bool {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1e9
        var due = min(Int(elapsed * sampleRate), frameCount) - framesDelivered

        while due > 0 {
            let n = min(due, Self.maxBlock)
            let got = Int(sf_readf_float(file, interleaved, sf_count_t(n)))
            guard got > 0 else { return false }
            ChannelMode.extract(interleaved: interleaved, frames: got, channels: channelCount, mode: channelMode, into: mono)
            pipeline.ring.write(mono, count: got)
            if pipeline.wantsStereo {
                ChannelMode.extract(interleaved: interleaved, frames: got, channels: channelCount, mode: .left, into: monoLeft)
                ChannelMode.extract(interleaved: interleaved, frames: got, channels: channelCount, mode: .right, into: monoRight)
                pipeline.writeStereo(left: monoLeft, right: monoRight, count: got)
            }
            framesDelivered += got
            due -= got
        }
        return framesDelivered < frameCount
    }
}
#endif
