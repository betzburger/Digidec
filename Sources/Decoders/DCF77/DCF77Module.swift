import Foundation
import Combine
import SwiftUI
import os

// MARK: - Einstellungen

/// Einstellungen des DCF77-Moduls (Mitte = Trägerton im NF).
@MainActor
public final class DCF77SettingsStore: ObservableObject {
    public static let centerRange: ClosedRange<Double> = 200...3500

    @Published public private(set) var centerHz: Double
    @Published public private(set) var manualCenterRevision = 0
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "dcf77LogEnabled") }
    }
    /// Von rigctld gemeldete Frequenz in Hz (z. B. 76500)
    @Published public var rigFrequencyHz: Int64?

    public init() {
        let d = UserDefaults.standard
        let c = d.double(forKey: "dcf77CenterHz")
        centerHz = Self.centerRange.contains(c) ? c : 1000.0
        logEnabled = d.object(forKey: "dcf77LogEnabled") as? Bool ?? true
    }

    public func setCenter(_ hz: Double) {
        centerHz = min(max(hz, Self.centerRange.lowerBound), Self.centerRange.upperBound).rounded()
        manualCenterRevision += 1
        UserDefaults.standard.set(centerHz, forKey: "dcf77CenterHz")
    }

    /// Abstimmhinweis anhand der aktuellen Funkgerätefrequenz
    public var tuningGuidance: (statusText: String, isCorrect: Bool) {
        guard let f = rigFrequencyHz else {
            return ("Empfänger auf 76,500 kHz USB stellen", false)
        }
        if f == 76_500 {
            return ("76,500 kHz USB (Mitte 1.000 Hz) – Ideal", true)
        } else if f == 77_000 {
            return ("77,000 kHz USB (Mitte 500 Hz)", true)
        } else if f == 77_500 {
            return ("77,500 kHz (Träger auf 77,5 kHz)", true)
        } else {
            return (String(format: "Eingestellt: %.3f kHz · Soll: 76,500 kHz USB", Double(f) / 1000.0), false)
        }
    }
}

extension DCF77SettingsStore: TuningTarget {
    public var tones: (mark: Double, space: Double) { (centerHz, centerHz) }
    public var markerBandwidth: Double { 100.0 }
}

// MARK: - Decoder

/// DCF77-Kern als 8-kHz-Senke an der Audio-Pipeline
public final class DCF77Decoder: @unchecked Sendable {
    private let pipeline: AudioPipeline
    private let core: DCF77Core
    private var enabled = false
    private let lock = OSAllocatedUnfairLock()
    private var pendingDecodes: [DCF77Core.DecodedTime] = []
    private var lastStatus: DCF77Core.Status?

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        core = DCF77Core(centerHz: 1000.0)

        core.onTimeDecoded = { [weak self] time in
            self?.lock.withLockUnchecked {
                self?.pendingDecodes.append(time)
            }
        }

        pipeline.addSink { [weak self] samples in
            self?.consume(samples)
        }
    }

    public func setCenter(_ hz: Double) {
        pipeline.perform { [self] in
            core.setCenter(hz)
        }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            enabled = on
            if !on { core.reset() }
        }
    }

    public func reset() {
        pipeline.perform { [self] in
            core.reset()
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled else { return }
        core.process(samples)
        let s = core.getStatus()
        lock.withLockUnchecked {
            lastStatus = s
        }
    }

    public func takeStatus() -> (status: DCF77Core.Status?, newDecodes: [DCF77Core.DecodedTime]) {
        lock.withLockUnchecked {
            let dec = pendingDecodes
            pendingDecodes.removeAll(keepingCapacity: true)
            return (lastStatus, dec)
        }
    }
}

// MARK: - Logger

/// Schreibt erfolgreich decodierte DCF77-Minutentelegramme in Tagesdateien
public final class DCF77Logger: @unchecked Sendable {
    private let folder: URL
    private let queue = DispatchQueue(label: "com.peterbetz.digidec.dcf77logger")

    public init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        folder = docs.appendingPathComponent("Digidec/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    public func fileURL(date: Date = Date()) -> URL {
        let fmt = DateFormatter()
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        return folder.appendingPathComponent("DCF77-\(fmt.string(from: date)).txt")
    }

    public func log(time: DCF77Core.DecodedTime, source: String?) {
        queue.async { [self] in
            let url = fileURL(date: time.receivedAt)
            let src = source ?? "Digidec"
            let deltaSign = time.deltaMilliseconds >= 0 ? "+" : ""
            let line = String(format: "%@ | %@ | Δt: %@%.1f ms | Quelle: %@ | DCF77 Mainflingen 77,5 kHz\n",
                              time.formattedDate, time.formattedTime, deltaSign, time.deltaMilliseconds, src)
            if !FileManager.default.fileExists(atPath: url.path) {
                let header = "=== Digidec DCF77 Atomzeit-Protokoll ===\n"
                try? header.write(to: url, atomically: true, encoding: .utf8)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                if let d = line.data(using: .utf8) { handle.write(d) }
                try? handle.close()
            }
        }
    }
}

// MARK: - Controller

@MainActor
public final class DCF77Controller: ObservableObject {
    @Published public private(set) var status: DCF77Core.Status?
    @Published public private(set) var lastTime: DCF77Core.DecodedTime?
    @Published public private(set) var decodedHistory: [DCF77Core.DecodedTime] = []
    @Published public var logEnabled: Bool {
        didSet { settings.logEnabled = logEnabled }
    }
    public var sourceDescription: String?

    public let decoder: DCF77Decoder
    public let settings: DCF77SettingsStore
    public let logger = DCF77Logger()

    private var timer: AnyCancellable?
    private var lastCenterRevision = -1

    public init(pipeline: AudioPipeline, settings: DCF77SettingsStore) {
        self.settings = settings
        self.logEnabled = settings.logEnabled
        decoder = DCF77Decoder(pipeline: pipeline)
        decoder.setCenter(settings.centerHz)

        timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.poll() }
    }

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
    }

    public func clearHistory() {
        decodedHistory.removeAll()
    }

    private func poll() {
        if settings.manualCenterRevision != lastCenterRevision {
            lastCenterRevision = settings.manualCenterRevision
            decoder.setCenter(settings.centerHz)
        }

        let (st, newDecodes) = decoder.takeStatus()
        if let st {
            self.status = st
            if let last = st.lastDecodedTime {
                self.lastTime = last
            }
        }

        for dec in newDecodes {
            decodedHistory.insert(dec, at: 0)
            if decodedHistory.count > 60 { decodedHistory.removeLast() }
            if logEnabled {
                logger.log(time: dec, source: sourceDescription)
            }
        }
    }
}
