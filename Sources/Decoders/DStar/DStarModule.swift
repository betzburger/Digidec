// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os
import VoiceCore

// D-Star (Betriebsart DV): Modul. Der Empfänger liest FM-Diskriminator-Audio (48 kHz), liefert Kopf, Langsamdaten und
// Sprachrahmen; ein Sprachdecoder aus `VoiceRegistry` macht daraus Ton. Ohne Decoder zeigt das Modul nur die Steuerdaten.

// MARK: - Einstellungen

@MainActor
public final class DStarSettingsStore: ObservableObject {
    /// Wie viele Aussendungen im Verlauf bleiben
    @Published public var keepCount: Int { didSet { UserDefaults.standard.set(keepCount, forKey: "dstarKeepCount") } }

    public init() {
        let k = UserDefaults.standard.integer(forKey: "dstarKeepCount")
        keepCount = (10...500).contains(k) ? k : 100
    }
}

extension DStarSettingsStore: TuningTarget {
    public var centerHz: Double { 2400 }
    public var tones: (mark: Double, space: Double) { (0, 0) }
    public var markerBandwidth: Double { 4800 }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .band("D-STAR · Basisband (GMSK 4800 Bd, bis 2,4 kHz)") }
}

// MARK: - Aussendung

/// Eine empfangene Aussendung (Kopf bis Ende)
public struct DStarTransmission: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var start: Date
    public var header: DStarHeader?
    /// Prüfsumme des Kopfes war in Ordnung (sonst nur aus der Kopf-Wiederholung der Langsamdaten)
    public var headerFromAir = false
    public var message: String?
    public var position: DStarPosition?
    public var frames = 0
    public var lateEntry = false
    /// `nil` = läuft noch
    public var endedBy: Ended?
    public var ambe: [[UInt8]] = []

    public enum Ended: String, Sendable { case end, lost }

    public var seconds: Double { Double(frames) * 0.02 }
    public var myCall: String { header?.myCall ?? "" }
    public var isLive: Bool { endedBy == nil }
}

// MARK: - Empfänger an der Pipeline

public final class DStarDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var events: [DStarEvent]
        public var stats: DStarFramerStats
        public var level: Double
        public var inputDB: Double
        public var inverted: Bool
        public var locked: Bool
    }

    public static let sampleRate = 48_000.0

    private let pipeline: AudioPipeline
    private let slicer = DStarBitSlicer(sampleRate: DStarDecoder.sampleRate)
    private let framer = DStarFramer()
    // Nur auf der Verarbeitungs-Queue
    private var enabled = false
    private var meanSquare = 0.0

    private let lock = OSAllocatedUnfairLock()
    private var pending: [DStarEvent] = []
    private var snapshot = (stats: DStarFramerStats(), level: 0.0, inputDB: -120.0, inverted: false, locked: false)

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        slicer.onBit = { [framer] bit, soft in framer.push(bit: bit, soft: soft) }
        framer.onEvent = { [weak self] event in
            guard let self else { return }
            self.lock.withLockUnchecked { self.pending.append(event) }
        }
        pipeline.addSink(rate: Self.sampleRate) { [weak self] samples in self?.consume(samples) }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            if on != enabled { slicer.reset(); framer.reset() }
            enabled = on
            if !on { lock.withLockUnchecked { pending.removeAll() } }
        }
    }

    public func resetStats() {
        pipeline.perform { [self] in
            framer.reset()
            lock.withLockUnchecked { snapshot.stats = DStarFramerStats() }
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pending.removeAll() }
            return Output(events: pending, stats: snapshot.stats, level: snapshot.level, inputDB: snapshot.inputDB, inverted: snapshot.inverted, locked: snapshot.locked)
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled else { return }
        var sum = 0.0
        for x in samples { sum += Double(x) * Double(x) }
        slicer.process(Array(samples))
        let block = samples.isEmpty ? 0 : sum / Double(samples.count)
        meanSquare += min(1.0, Double(samples.count) / (0.3 * Self.sampleRate)) * (block - meanSquare)
        let db = meanSquare > 1e-12 ? max(-120, 10 * log10(meanSquare)) : -120
        let stats = framer.stats, inverted = framer.inverted, locked = framer.isLocked
        let level = Double(slicer.level)
        lock.withLockUnchecked { snapshot = (stats, level, db, inverted, locked) }
    }
}

// MARK: - Diagnose

public enum DStarDiagnosis {
    public enum Severity: Int, Sendable { case ok, waiting, problem }

    public struct Result: Equatable, Sendable {
        public var severity: Severity
        public var title: String
        public var advice: String
    }

    public static let silenceDB = -70.0

    public static func assess(inputDB: Double, stats: DStarFramerStats, locked: Bool) -> Result {
        if inputDB < silenceDB {
            return Result(severity: .problem, title: "Kein Audio", advice: "Am Eingang kommt kein Signal an. D-Star braucht das unbearbeitete FM-Diskriminator-Audio (Packet/Daten-Ausgang des Funkgeräts oder SDR-Programm mit FM-Audio ohne Entzerrung und ohne Hochpass).")
        }
        if locked { return Result(severity: .ok, title: "Aussendung wird empfangen", advice: "") }
        if stats.headersOK + stats.lateEntries > 0 {
            return Result(severity: .ok, title: "Warten auf die nächste Aussendung", advice: "")
        }
        if stats.headersBad > 0 {
            return Result(severity: .problem, title: "Kopf nicht lesbar", advice: "Die Synchronisation wird gefunden, aber der Kopf hat Fehler: Signal zu schwach oder verrauscht, oder das Audio ist durch Filter und Hochpass verformt.")
        }
        return Result(severity: .waiting, title: "Warten auf D-Star", advice: "Noch keine D-Star-Synchronisation. Das Audio muss die GMSK-Daten mit 4800 Bd unverfälscht enthalten (nicht das fertig demodulierte Sprach-Audio).")
    }
}

// MARK: - Controller

@MainActor
public final class DStarController: ObservableObject {
    public let decoder: DStarDecoder
    public let logger = DecodeLogger(mode: "DSTAR")
    /// Verlauf der Aussendungen, neueste zuletzt
    @Published public private(set) var transmissions: [DStarTransmission] = []
    /// Positionen (DPRS) der gehörten Stationen für die Karte
    @Published public private(set) var positions = VoicePositionBook()
    @Published public var selection: String?
    @Published public private(set) var stats = DStarFramerStats()
    @Published public private(set) var level = 0.0
    @Published public private(set) var inputDB = -120.0
    @Published public private(set) var inverted = false
    @Published public private(set) var locked = false
    public let recorder: InputRecorder
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var lastRecording: URL?
    @Published public var logEnabled: Bool { didSet { UserDefaults.standard.set(logEnabled, forKey: "dstarLogEnabled") } }
    public var rigDescription: String?

    private let settings: DStarSettingsStore
    private var timer: Timer?
    private var slow = DStarSlowData()
    private var currentIndex: Int?
    private var lastFrameAt: Date?
    private var cancellables: Set<AnyCancellable> = []
    public let output = VoiceOutput.shared
    /// Kanal einer Kanalbank (mehrere Decoder zugleich): keine Sprachausgabe, der Stick gehört dem Hauptmodul
    public var silent = false

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: DStarSettingsStore) {
        self.settings = settings
        decoder = DStarDecoder(pipeline: pipeline)
        recorder = InputRecorder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "dstarLogEnabled") as? Bool ?? true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
        if !active { finishCurrent(.lost, now: Date()); if !silent { output.stopPlayback() } }
    }

    public func clear() {
        transmissions.removeAll()
        positions.clear()
        selection = nil
        currentIndex = nil
        decoder.resetStats()
        stats = DStarFramerStats()
    }

    public func toggleRecording() {
        if isRecording {
            lastRecording = recorder.stop()
            isRecording = false
            return
        }
        let name = InputRecorder.fileName(frequencyHz: nil, mode: nil, preset: "dstar", prefix: "DSTAR")
        recorder.start(url: InputRecorder.directory.appendingPathComponent(name))
        isRecording = true
        recordingDuration = 0
    }

    public var diagnosis: DStarDiagnosis.Result { DStarDiagnosis.assess(inputDB: inputDB, stats: stats, locked: locked) }

    /// Eine Aussendung aus dem Verlauf noch einmal abspielen
    public func replay(_ t: DStarTransmission) {
        if !silent { output.play(t.ambe, profile: .dstar) }
    }

    // MARK: Verarbeitung

    private func poll() {
        let out = decoder.takeOutput()
        if out.stats != stats { stats = out.stats }
        level = out.level
        if abs(out.inputDB - inputDB) >= 0.5 { inputDB = out.inputDB }
        if out.inverted != inverted { inverted = out.inverted }
        if out.locked != locked { locked = out.locked }
        if isRecording { recordingDuration = recorder.duration }
        output.refresh()
        var toPlay: [[UInt8]] = []
        for event in out.events { ingest(event, audio: &toPlay) }
        if !silent { output.play(toPlay, profile: .dstar) }
        // Audio reißt ab, ohne dass Ende-Muster oder Verlust gemeldet werden: nach 3 s ohne Rahmen beenden
        if currentIndex != nil, let last = lastFrameAt, Date().timeIntervalSince(last) > 3 { finishCurrent(.lost, now: Date()) }
    }

    /// Ein Ereignis des Empfängers aufnehmen (auch für Tests und Dateiwiedergabe)
    public func ingest(_ event: DStarEvent, now: Date = Date()) {
        var ignored: [[UInt8]] = []
        ingest(event, now: now, audio: &ignored)
    }

    private func ingest(_ event: DStarEvent, now: Date = Date(), audio: inout [[UInt8]]) {
        switch event {
        case .header(let header, let ok):
            guard ok else { return }
            finishCurrent(.lost, now: now)
            var t = DStarTransmission(start: now, header: header)
            t.headerFromAir = true
            append(t)
            slow.reset()
            if logEnabled { logger.append(Self.logLine(t) + "\n", now: now) }
        case .voice(let frame):
            if currentIndex == nil {
                var t = DStarTransmission(start: now)
                t.lateEntry = true
                append(t)
                slow.reset()
            }
            guard let i = currentIndex else { return }
            lastFrameAt = now
            transmissions[i].frames += 1
            transmissions[i].ambe.append(frame.ambe)
            audio.append(frame.ambe)
            if frame.index > 0, slow.add(frameIndex: frame.index, bytes: frame.slowData) {
                if transmissions[i].header == nil, let h = slow.header { transmissions[i].header = h }
                if let m = slow.message { transmissions[i].message = m }
                if let p = slow.position {
                    transmissions[i].position = p
                    let call = p.callsign.isEmpty ? (transmissions[i].header?.myCall ?? "") : p.callsign
                    positions.update(mode: "D-STAR", callsign: call, latitude: p.latitude, longitude: p.longitude, comment: p.comment, now: now)
                }
            }
        case .end:
            finishCurrent(.end, now: now)
        case .lost:
            finishCurrent(.lost, now: now)
        }
    }

    private func append(_ t: DStarTransmission) {
        transmissions.append(t)
        if transmissions.count > settings.keepCount { transmissions.removeFirst(transmissions.count - settings.keepCount) }
        currentIndex = transmissions.count - 1
        lastFrameAt = Date()
    }

    private func finishCurrent(_ reason: DStarTransmission.Ended, now: Date) {
        guard let i = currentIndex, transmissions.indices.contains(i) else { currentIndex = nil; return }
        transmissions[i].endedBy = reason
        // Keine Sprachrahmen: keine Aussendung (falscher Kopf), nicht im Verlauf behalten
        if transmissions[i].frames == 0 { transmissions.remove(at: i) }
        else if logEnabled { logger.append(Self.logLine(transmissions[i]) + "\n", now: now) }
        currentIndex = nil
    }

    /// „08:15:02  DL1ABC /TEST  → CQCQCQ  über DB0XYZ B  12,4 s  Text“
    nonisolated public static func logLine(_ t: DStarTransmission) -> String {
        var line = utc.string(from: t.start) + "  " + (t.header.map { $0.myCall + ($0.myCall2.isEmpty ? "" : " /" + $0.myCall2) } ?? "(ohne Kopf)")
        if let h = t.header { line += "  → \(h.yourCall)  über \(h.repeater1.isEmpty ? "direkt" : h.repeater1)" }
        if !t.isLive { line += String(format: "  %.1f s", t.seconds) }
        if let m = t.message { line += "  „\(m)“" }
        if let p = t.position { line += String(format: "  %.4f %.4f", p.latitude, p.longitude) }
        return line
    }
}
