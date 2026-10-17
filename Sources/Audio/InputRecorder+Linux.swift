// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
#if !canImport(AVFoundation)
import Foundation
import CSndfile
import os

/// Nimmt das Eingangssignal (nach Kanalwahl, vor der Wandlung auf 8 kHz) als WAV auf (Fassung mit libsndfile).
/// 16 Bit PCM mono in Quell-Abtastrate.
public final class InputRecorder: @unchecked Sendable {
    public static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Digidec/Recordings", isDirectory: true)
    }

    private let pipeline: AudioPipeline
    private let lock = OSAllocatedUnfairLock()
    // Unter `lock`
    private var file: OpaquePointer?
    private var fileURL: URL?
    private var fileRate: Double = 0
    private var framesWritten: Int64 = 0
    private var pendingURL: URL?

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addRawSink { [weak self] samples, rate in self?.write(samples, rate: rate) }
    }

    deinit { if let file { sf_close(file) } }

    public var isRecording: Bool { lock.withLockUnchecked { file != nil || pendingURL != nil } }

    public var duration: TimeInterval {
        lock.withLockUnchecked { fileRate > 0 ? Double(framesWritten) / fileRate : 0 }
    }

    /// Startet eine Aufnahme; die Datei wird mit dem ersten Block angelegt (dann ist die Abtastrate bekannt).
    public func start(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        lock.withLockUnchecked {
            closeFile()
            framesWritten = 0
            fileRate = 0
            pendingURL = url
        }
    }

    /// Beendet die Aufnahme und liefert die Datei
    @discardableResult
    public func stop() -> URL? {
        lock.withLockUnchecked {
            let url = fileURL ?? pendingURL
            closeFile()
            pendingURL = nil
            return url
        }
    }

    private func closeFile() {
        if let file { sf_close(file) }
        file = nil
        fileURL = nil
    }

    private func write(_ samples: UnsafeBufferPointer<Float>, rate: Double) {
        lock.withLockUnchecked {
            if let url = pendingURL {
                pendingURL = nil
                var info = SF_INFO(frames: 0, samplerate: Int32(rate), channels: 1, format: Int32(SF_FORMAT_WAV | SF_FORMAT_PCM_16), sections: 0, seekable: 0)
                file = sf_open(url.path, Int32(SFM_WRITE), &info)
                fileURL = file == nil ? nil : url
                fileRate = rate
            }
            guard let file, rate == fileRate, let base = samples.baseAddress else { return }
            let written = sf_writef_float(file, base, sf_count_t(samples.count))
            framesWritten += Int64(written)
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
#endif
