import Foundation
import AVFoundation
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

/// Spielt eine Audiodatei (WAV, AIFF, CAF …) in Echtzeit in die Pipeline, als käme sie vom Empfänger.
/// Für Tests mit Aufnahmen (PLAN.md, Abschnitt 8) und zum Nachdecodieren.
public final class WAVFileSource: @unchecked Sendable {
    public let url: URL
    public let sampleRate: Double
    public let channelCount: Int
    public let frameCount: Int
    public var duration: TimeInterval { Double(frameCount) / sampleRate }

    private let file: AVAudioFile
    private let queue = DispatchQueue(label: "com.peterbetz.digidec.wavSource", qos: .userInitiated)
    private let modeLock = OSAllocatedUnfairLock(initialState: ChannelMode.left)
    // Nur auf `queue`
    private var timer: DispatchSourceTimer?
    private var startTime: DispatchTime = .now()
    private var framesDelivered = 0
    private var readBuffer: AVAudioPCMBuffer?
    private let mono = UnsafeMutablePointer<Float>.allocate(capacity: 16_384)
    private static let maxBlock = 16_384

    public init(url: URL) throws {
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw WAVFileError.unreadable(error.localizedDescription)
        }
        guard file.length > 0 else { throw WAVFileError.empty }
        self.url = url
        sampleRate = file.processingFormat.sampleRate
        channelCount = Int(file.processingFormat.channelCount)
        frameCount = Int(file.length)
    }

    deinit {
        mono.deallocate()
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
            file.framePosition = 0
            framesDelivered = 0
            readBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(Self.maxBlock))
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
        guard let buffer = readBuffer else { return false }

        while due > 0 {
            let n = min(due, Self.maxBlock)
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(n))
            } catch {
                return false
            }
            let got = Int(buffer.frameLength)
            guard got > 0, let data = buffer.floatChannelData else { return false }
            let planes = (0..<channelCount).map { UnsafePointer(data[$0]) }
            ChannelMode.extract(planar: planes, frames: got, mode: channelMode, into: mono)
            pipeline.ring.write(mono, count: got)
            framesDelivered += got
            due -= got
        }
        return framesDelivered < frameCount
    }
}
