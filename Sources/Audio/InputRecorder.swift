import Foundation
import AVFoundation
import os

/// Nimmt das Eingangssignal (nach Kanalwahl, vor der Wandlung auf 8 kHz) als WAV auf – für den Vergleich
/// mit fldigi (PLAN.md, Abschnitt 8) und zum späteren Nachdecodieren. 16 Bit PCM mono in Quell-Abtastrate.
public final class InputRecorder: @unchecked Sendable {
    public static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Digidec/Recordings", isDirectory: true)
    }

    private let pipeline: AudioPipeline
    private let lock = OSAllocatedUnfairLock()
    // Unter `lock` (Schreiben auf der Verarbeitungs-Queue, Start/Stopp vom Main Thread)
    private var file: AVAudioFile?
    private var fileRate: Double = 0
    private var framesWritten: Int64 = 0
    private var pendingURL: URL?

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addRawSink { [weak self] samples, rate in self?.write(samples, rate: rate) }
    }

    public var isRecording: Bool { lock.withLockUnchecked { file != nil || pendingURL != nil } }

    public var duration: TimeInterval {
        lock.withLockUnchecked { fileRate > 0 ? Double(framesWritten) / fileRate : 0 }
    }

    /// Startet eine Aufnahme; die Datei wird mit dem ersten Block angelegt (dann ist die Abtastrate bekannt).
    public func start(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        lock.withLockUnchecked {
            file = nil
            framesWritten = 0
            fileRate = 0
            pendingURL = url
        }
    }

    /// Beendet die Aufnahme und liefert die Datei
    @discardableResult
    public func stop() -> URL? {
        lock.withLockUnchecked {
            let url = file?.url ?? pendingURL
            file = nil              // AVAudioFile schließt beim Freigeben und schreibt den WAV-Kopf
            pendingURL = nil
            return url
        }
    }

    private func write(_ samples: UnsafeBufferPointer<Float>, rate: Double) {
        lock.withLockUnchecked {
            if let url = pendingURL {
                pendingURL = nil
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                               AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
                file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                fileRate = rate
            }
            guard let file, rate == fileRate, let base = samples.baseAddress,
                  let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))
            else { return }
            buf.frameLength = AVAudioFrameCount(samples.count)
            buf.floatChannelData![0].update(from: base, count: samples.count)
            if (try? file.write(from: buf)) != nil {
                framesWritten += Int64(samples.count)
            }
        }
    }

    /// „RTTY_2026-09-30_1937Z_4584700Hz_LSB_DWD-KW.wav“ (Präfix = Modul)
    public static func fileName(date: Date = Date(), frequencyHz: Int?, mode: String?, preset: String, prefix: String = "RTTY") -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        var name = "\(prefix)_\(f.string(from: date))"
        if let frequencyHz { name += "_\(frequencyHz)Hz" }
        if let mode { name += "_\(mode)" }
        name += "_\(preset.uppercased())"
        return name.replacingOccurrences(of: " ", with: "-") + ".wav"
    }
}
