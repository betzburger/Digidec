// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os
import VoiceCore

// Yaesu System Fusion (C4FM): Modul. Der Empfänger liest FM-Diskriminator-Audio (48 kHz, 4FSK 4800 Symbole/s) und liefert
// Rufzeichen und Sprachrahmen; der Ton kommt wie bei D-Star aus dem Sprachstick (`VoiceOutput`).

// MARK: - Einstellungen

@MainActor
public final class YSFSettingsStore: ObservableObject {
    @Published public var keepCount: Int { didSet { UserDefaults.standard.set(keepCount, forKey: "ysfKeepCount") } }

    public init() {
        let k = UserDefaults.standard.integer(forKey: "ysfKeepCount")
        keepCount = (10...500).contains(k) ? k : 100
    }
}

extension YSFSettingsStore: TuningTarget {
    public var centerHz: Double { 2400 }
    public var tones: (mark: Double, space: Double) { (0, 0) }
    public var markerBandwidth: Double { 4800 }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .band("YSF · Basisband (C4FM 4800 Bd, bis 2,4 kHz)") }
}

// MARK: - Empfänger an der Pipeline

public final class YSFDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var events: [YSFEvent]
        public var stats: YSFFramerStats
        public var level: Double
        public var inputDB: Double
        public var inverted: Bool
        public var locked: Bool
    }

    public static let sampleRate = 48_000.0

    private let pipeline: AudioPipeline
    private let slicer = FourFSKSlicer(sampleRate: YSFDecoder.sampleRate)
    private let framer = YSFFramer()
    private var enabled = false
    private var meanSquare = 0.0
    private let lock = OSAllocatedUnfairLock()
    private var pending: [YSFEvent] = []
    private var snapshot = (stats: YSFFramerStats(), level: 0.0, inputDB: -120.0, inverted: false, locked: false)

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        slicer.onSymbol = { [framer] symbol in framer.push(symbol: symbol) }
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
            lock.withLockUnchecked { snapshot.stats = YSFFramerStats() }
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

public enum YSFDiagnosis {
    public enum Severity: Int, Sendable { case ok, waiting, problem }

    public struct Result: Equatable, Sendable {
        public var severity: Severity
        public var title: String
        public var advice: String
    }

    public static let silenceDB = -70.0

    public static func assess(inputDB: Double, stats: YSFFramerStats, locked: Bool) -> Result {
        if inputDB < silenceDB {
            return Result(severity: .problem, title: "Kein Audio", advice: "Am Eingang kommt kein Signal an. YSF braucht das unbearbeitete FM-Diskriminator-Audio (Packet/Daten-Ausgang des Funkgeräts oder SDR-Programm mit FM-Audio ohne Entzerrung und ohne Hochpass).")
        }
        if locked { return Result(severity: .ok, title: "Aussendung wird empfangen", advice: "") }
        if stats.frames > 0 { return Result(severity: .ok, title: "Warten auf die nächste Aussendung", advice: "") }
        if stats.syncs > 0 || stats.fichBad > 0 {
            return Result(severity: .problem, title: "Rahmen nicht lesbar", advice: "Die Synchronisation wird gefunden, aber der Kopfteil (FICH) hat zu viele Fehler: Signal zu schwach oder verrauscht, oder das Audio ist durch Filter und Hochpass verformt.")
        }
        return Result(severity: .waiting, title: "Warten auf YSF", advice: "Noch keine YSF-Synchronisation. Das Audio muss die C4FM-Daten mit 4800 Symbolen/s unverfälscht enthalten (nicht das fertig demodulierte Sprach-Audio).")
    }
}

// MARK: - Controller

@MainActor
public final class YSFController: ObservableObject {
    public let decoder: YSFDecoder
    public let logger = DecodeLogger(mode: "YSF")
    @Published public private(set) var calls: [VoiceCall] = []
    @Published public private(set) var stats = YSFFramerStats()
    @Published public private(set) var level = 0.0
    @Published public private(set) var inputDB = -120.0
    @Published public private(set) var inverted = false
    @Published public private(set) var locked = false
    public let output = VoiceOutput.shared
    /// Kanal einer Kanalbank (mehrere Decoder zugleich): keine Sprachausgabe, der Stick gehört dem Hauptmodul
    public var silent = false
    public let recorder: InputRecorder
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var lastRecording: URL?
    @Published public var logEnabled: Bool { didSet { UserDefaults.standard.set(logEnabled, forKey: "ysfLogEnabled") } }
    public var rigDescription: String?

    private let settings: YSFSettingsStore
    private var timer: Timer?
    private var currentIndex: Int?
    private var lastFrameAt: Date?

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: YSFSettingsStore) {
        self.settings = settings
        decoder = YSFDecoder(pipeline: pipeline)
        recorder = InputRecorder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "ysfLogEnabled") as? Bool ?? true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
        if !active { finishCurrent(.lost, now: Date()); if !silent { output.stopPlayback() } }
    }

    public func clear() {
        calls.removeAll()
        currentIndex = nil
        decoder.resetStats()
        stats = YSFFramerStats()
    }

    public func toggleRecording() {
        if isRecording {
            lastRecording = recorder.stop()
            isRecording = false
            return
        }
        let name = InputRecorder.fileName(frequencyHz: nil, mode: nil, preset: "ysf", prefix: "YSF")
        recorder.start(url: InputRecorder.directory.appendingPathComponent(name))
        isRecording = true
        recordingDuration = 0
    }

    public var diagnosis: YSFDiagnosis.Result { YSFDiagnosis.assess(inputDB: inputDB, stats: stats, locked: locked) }

    public func replay(_ call: VoiceCall) { output.play(call.ambe, profile: .dmr) }

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
        if !silent { output.play(toPlay, profile: .dmr) }
        if currentIndex != nil, let last = lastFrameAt, Date().timeIntervalSince(last) > 3 { finishCurrent(.lost, now: Date()) }
    }

    /// Ein Ereignis des Empfängers aufnehmen (auch für Tests und Dateiwiedergabe)
    public func ingest(_ event: YSFEvent, now: Date = Date()) {
        var ignored: [[UInt8]] = []
        ingest(event, now: now, audio: &ignored)
    }

    private static func modeName(_ f: YSFFich) -> String {
        switch f.dt {
        case 0: return "YSF V/D 1"
        case 1: return "YSF Daten"
        case 2: return "YSF V/D 2"
        default: return "YSF Sprache (Vollrate)"
        }
    }

    private func ingest(_ event: YSFEvent, now: Date = Date(), audio: inout [[UInt8]]) {
        switch event {
        case .lost:
            finishCurrent(.lost, now: now)
        case .frame(let frame):
            guard let f = frame.fich else { return }
            if f.isHeader { finishCurrent(.lost, now: now) }
            if currentIndex == nil {
                var c = VoiceCall(start: now, mode: Self.modeName(f))
                c.lateEntry = !f.isHeader
                calls.append(c)
                if calls.count > settings.keepCount { calls.removeFirst(calls.count - settings.keepCount) }
                currentIndex = calls.count - 1
            }
            guard let i = currentIndex else { return }
            lastFrameAt = now
            calls[i].mode = Self.modeName(f)
            calls[i].via = calls[i].via.isEmpty ? (f.viaRepeater ? "Repeater" : "direkt") : calls[i].via
            for text in frame.texts {
                switch text {
                case .destination(let s): if !s.isEmpty { calls[i].target = s }
                case .source(let s): if !s.isEmpty { calls[i].source = s }
                case .uplink(let s): if !s.isEmpty { calls[i].via = s }
                case .downlink: break
                case .remarks(let s): if !s.isEmpty { calls[i].note = s }
                case .radioIDs(let dst, let src): calls[i].target = dst; if calls[i].source.isEmpty { calls[i].source = src }
                }
            }
            if frame.voiceUnsupported { calls[i].note = "Sprachanteil dieses Datentyps wird nicht unterstützt" }
            for v in frame.voice { calls[i].frames += 1; calls[i].ambe.append(v); audio.append(v) }
            if f.isTerminator { finishCurrent(.end, now: now) }
        }
    }

    private func finishCurrent(_ reason: VoiceCall.Ended, now: Date) {
        guard let i = currentIndex, calls.indices.contains(i) else { currentIndex = nil; return }
        calls[i].endedBy = reason
        if calls[i].frames == 0 && calls[i].source.isEmpty { calls.remove(at: i) }
        else if logEnabled { logger.append(Self.logLine(calls[i]) + "\n", now: now) }
        currentIndex = nil
    }

    /// „08:15:02  F6FCE  → **********  über F5ZOO-R1  12,4 s  Bemerkung“
    nonisolated public static func logLine(_ c: VoiceCall) -> String {
        var line = utc.string(from: c.start) + "  " + (c.source.isEmpty ? "(Absender unbekannt)" : c.source)
        if !c.target.isEmpty { line += "  → \(c.target)" }
        if !c.via.isEmpty { line += "  über \(c.via)" }
        if !c.isLive { line += String(format: "  %.1f s", c.seconds) }
        if !c.note.isEmpty { line += "  „\(c.note)“" }
        return line
    }
}
