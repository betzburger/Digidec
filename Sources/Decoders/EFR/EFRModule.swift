// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os

// MARK: - Stationen

public enum EFRStation: String, CaseIterable, Identifiable, Sendable {
    case dcf49 = "dcf49"
    case dcf39 = "dcf39"
    case hga22 = "hga22"
    case custom = "custom"

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .dcf49:  return "DCF49 Mainflingen"
        case .dcf39:  return "DCF39 Burg"
        case .hga22:  return "HGA22 Lakihegy"
        case .custom: return "Benutzerdefiniert"
        }
    }

    public var frequencyHz: Int64 {
        switch self {
        case .dcf49:  return 129_100
        case .dcf39:  return 139_000
        case .hga22:  return 135_600
        case .custom: return 129_100
        }
    }

    /// Empfohlene Empfänger-Abstimmfrequenz in USB bei NF-Mitte 1.500 Hz (f_dial = f_rf - 1500 Hz)
    public var idealDialHz: Int64 {
        frequencyHz - 1500
    }
}

// MARK: - Einstellungen

@MainActor
public final class EFRSettingsStore: ObservableObject {
    public static let centerRange: ClosedRange<Double> = 500...3000

    @Published public var station: EFRStation {
        didSet { UserDefaults.standard.set(station.rawValue, forKey: "efrStation") }
    }
    @Published public private(set) var centerHz: Double
    @Published public private(set) var manualCenterRevision = 0
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "efrLogEnabled") }
    }
    @Published public var rigFrequencyHz: Int64?

    public init() {
        let d = UserDefaults.standard
        let sKey = d.string(forKey: "efrStation") ?? "dcf49"
        station = EFRStation(rawValue: sKey) ?? .dcf49
        let c = d.double(forKey: "efrCenterHz")
        centerHz = Self.centerRange.contains(c) ? c : 1500.0
        logEnabled = d.object(forKey: "efrLogEnabled") as? Bool ?? true
    }

    public func setCenter(_ hz: Double) {
        centerHz = min(max(hz, Self.centerRange.lowerBound), Self.centerRange.upperBound).rounded()
        manualCenterRevision += 1
        UserDefaults.standard.set(centerHz, forKey: "efrCenterHz")
    }

    public var tuningGuidance: (statusText: String, isCorrect: Bool) {
        guard let f = rigFrequencyHz else {
            let idealKHz = Double(station.idealDialHz) / 1000.0
            return (String(format: "Empfänger auf %.3f kHz USB stellen", idealKHz), false)
        }

        let ideal = station.idealDialHz
        if f == ideal {
            return (String(format: "%.3f kHz USB (Mitte 1.500 Hz) – Ideal", Double(f) / 1000.0), true)
        } else {
            let diff = f - ideal
            if abs(diff) < 3000 {
                return (String(format: "Dial: %.3f kHz · Soll: %.3f kHz USB", Double(f) / 1000.0, Double(ideal) / 1000.0), false)
            } else {
                return (String(format: "Eingestellt: %.3f kHz · Soll: %.3f kHz USB", Double(f) / 1000.0, Double(ideal) / 1000.0), false)
            }
        }
    }
}

extension EFRSettingsStore: TuningTarget {
    public var tones: (mark: Double, space: Double) {
        (centerHz - 170.0, centerHz + 170.0)   // Mark = untere, Space = obere Frequenz (Marker der Abstimmung)
    }
    public var markerBandwidth: Double { 340.0 }
}

// MARK: - Decoder

public final class EFRDecoder: @unchecked Sendable {
    private let pipeline: AudioPipeline
    private let core: EFRCore
    private var enabled = false
    private let lock = OSAllocatedUnfairLock()
    private var pendingTelegrams: [EFRCore.DecodedTelegram] = []
    private var lastStatus: EFRCore.Status?

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        core = EFRCore(centerHz: 1500.0, shiftHz: 340.0)

        core.onTelegramDecoded = { [weak self] telegram in
            self?.lock.withLockUnchecked {
                self?.pendingTelegrams.append(telegram)
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

    public func takeStatus() -> (status: EFRCore.Status?, newTelegrams: [EFRCore.DecodedTelegram]) {
        lock.withLockUnchecked {
            let tel = pendingTelegrams
            pendingTelegrams.removeAll(keepingCapacity: true)
            return (lastStatus, tel)
        }
    }
}

// MARK: - Logger

public final class EFRLogger: @unchecked Sendable {
    private let folder: URL
    private let queue = DispatchQueue(label: "com.peterbetz.digidec.efrlogger")

    public init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        folder = docs.appendingPathComponent("Digidec/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    public func fileURL(date: Date = Date()) -> URL {
        let fmt = DateFormatter()
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        return folder.appendingPathComponent("EFR-\(fmt.string(from: date)).txt")
    }

    public func log(telegram: EFRCore.DecodedTelegram, station: EFRStation, source: String?) {
        queue.async { [self] in
            let url = fileURL(date: telegram.timestamp)
            let src = source ?? "Digidec"
            let line = String(format: "%@ | %@ | [%@] %@ | Hex: %@ | Quelle: %@\n",
                              telegram.formattedTime, station.name, telegram.title, telegram.summary, telegram.rawHex, src)
            if !FileManager.default.fileExists(atPath: url.path) {
                let header = "=== Digidec EFR Funkrundsteuer-Protokoll (DIN 19244) ===\n"
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
public final class EFRController: ObservableObject {
    @Published public private(set) var status: EFRCore.Status?
    @Published public private(set) var telegrams: [EFRCore.DecodedTelegram] = []
    @Published public var filterMode: FilterMode = .all
    @Published public var logEnabled: Bool {
        didSet { settings.logEnabled = logEnabled }
    }
    public var sourceDescription: String?

    public enum FilterMode: String, CaseIterable, Identifiable {
        case all = "Alle"
        case timeOnly = "Nur Zeit"
        case commandsOnly = "Nur Schaltung"
        public var id: String { rawValue }
    }

    public var filteredTelegrams: [EFRCore.DecodedTelegram] {
        switch filterMode {
        case .all: return telegrams
        case .timeOnly: return telegrams.filter(\.isTimeSync)
        case .commandsOnly: return telegrams.filter { !$0.isTimeSync }
        }
    }

    public let decoder: EFRDecoder
    public let settings: EFRSettingsStore
    public let logger = EFRLogger()

    private var timer: AnyCancellable?
    private var lastCenterRevision = -1

    public init(pipeline: AudioPipeline, settings: EFRSettingsStore) {
        self.settings = settings
        self.logEnabled = settings.logEnabled
        decoder = EFRDecoder(pipeline: pipeline)
        decoder.setCenter(settings.centerHz)

        timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.poll() }
    }

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
    }

    /// Fügt ein Telegramm vorn ein. Ein gleiches Telegramm innerhalb von 15 s (EFR sendet doppelt) zählt nur als Wiederholung.
    /// - Returns: `true`, wenn neu eingefügt (loggen), `false` bei Wiederholung.
    nonisolated public static func insertOrMerge(_ tel: EFRCore.DecodedTelegram, into list: inout [EFRCore.DecodedTelegram], maxEntries: Int) -> Bool {
        if let i = list.prefix(20).firstIndex(where: { $0.rawBytes == tel.rawBytes && tel.timestamp.timeIntervalSince($0.timestamp) < 15 }) {
            list[i].repeats += 1
            return false
        }
        list.insert(tel, at: 0)
        if list.count > maxEntries { list.removeLast() }
        return true
    }

    public func clearTelegrams() {
        telegrams.removeAll()
    }

    private func poll() {
        if settings.manualCenterRevision != lastCenterRevision {
            lastCenterRevision = settings.manualCenterRevision
            decoder.setCenter(settings.centerHz)
        }

        let (st, newTelegrams) = decoder.takeStatus()
        if let st {
            self.status = st
        }

        for tel in newTelegrams {
            // EFR sendet Telegramme zweimal hintereinander: Wiederholung zählt am ersten Eintrag, wird nicht neu gelistet/geloggt
            guard Self.insertOrMerge(tel, into: &telegrams, maxEntries: 200) else { continue }
            if logEnabled {
                logger.log(telegram: tel, station: settings.station, source: sourceDescription)
            }
        }
    }
}
