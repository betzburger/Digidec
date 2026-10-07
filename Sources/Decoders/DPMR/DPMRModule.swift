// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os
import VoiceCore

// dPMR (digital Private Mobile Radio, ETSI TS 102 658): Modul. Der Empfänger liest FM-Diskriminator-Audio (48 kHz, 4FSK 2400 Symbole/s)
// und liefert Gespräche mit gerufener und rufender Kennung, Kanalcode (Farbcode) und Sprachrahmen. Der Ton kommt wie bei DMR vom
// Sprachstick oder vom Software-Decoder, falls vorhanden.

// MARK: - Einstellungen

@MainActor
public final class DPMRSettingsStore: ObservableObject {
    /// Nur diesen Kanalcode (0 … 63) beachten; −1 = alle
    @Published public var colorCode: Int { didSet { UserDefaults.standard.set(colorCode, forKey: "dpmrColorCode") } }
    @Published public var keepCount: Int { didSet { UserDefaults.standard.set(keepCount, forKey: "dpmrKeepCount") } }

    public init() {
        let d = UserDefaults.standard
        let cc = d.object(forKey: "dpmrColorCode") as? Int ?? -1
        colorCode = (-1...63).contains(cc) ? cc : -1
        let k = d.integer(forKey: "dpmrKeepCount")
        keepCount = (10...500).contains(k) ? k : 100
    }
}

extension DPMRSettingsStore: TuningTarget {
    public var centerHz: Double { 1200 }
    public var tones: (mark: Double, space: Double) { (0, 0) }
    public var markerBandwidth: Double { 2400 }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .band("dPMR · Basisband (4FSK 2400 Bd, bis 1,2 kHz)") }
}

// MARK: - Empfänger an der Pipeline

public final class DPMRDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var events: [DPMREvent]
        public var stats: DPMRFramerStats
        public var level: Double
        public var inputDB: Double
        public var inverted: Bool
        public var locked: Bool
    }

    public static let sampleRate = 48_000.0

    private let pipeline: AudioPipeline
    private let receiver = DPMRReceiver(sampleRate: DPMRDecoder.sampleRate)
    private var enabled = false
    private var meanSquare = 0.0
    private let lock = OSAllocatedUnfairLock()
    private var pending: [DPMREvent] = []
    private var snapshot = (stats: DPMRFramerStats(), level: 0.0, inputDB: -120.0, inverted: false, locked: false)

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        receiver.onEvent = { [weak self] event in
            guard let self else { return }
            self.lock.withLockUnchecked { self.pending.append(event) }
        }
        pipeline.addSink(rate: Self.sampleRate) { [weak self] samples in self?.consume(samples) }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            if on != enabled { receiver.reset() }
            enabled = on
            if !on { lock.withLockUnchecked { pending.removeAll() } }
        }
    }

    public func resetStats() {
        pipeline.perform { [self] in
            receiver.reset()
            lock.withLockUnchecked { snapshot.stats = DPMRFramerStats() }
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
        receiver.process(Array(samples))
        let block = samples.isEmpty ? 0 : sum / Double(samples.count)
        meanSquare += min(1.0, Double(samples.count) / (0.3 * Self.sampleRate)) * (block - meanSquare)
        let db = meanSquare > 1e-12 ? max(-120, 10 * log10(meanSquare)) : -120
        let stats = receiver.stats, inverted = receiver.inverted, locked = receiver.isLocked
        let level = Double(receiver.level)
        lock.withLockUnchecked { snapshot = (stats, level, db, inverted, locked) }
    }
}

// MARK: - Controller

@MainActor
public final class DPMRController: ObservableObject {
    public let decoder: DPMRDecoder
    public let logger = DecodeLogger(mode: "DPMR")
    @Published public private(set) var calls: [VoiceCall] = []
    @Published public private(set) var stats = DPMRFramerStats()
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
    @Published public var logEnabled: Bool { didSet { UserDefaults.standard.set(logEnabled, forKey: "dpmrLogEnabled") } }
    public var rigDescription: String?

    private let settings: DPMRSettingsStore
    private var timer: Timer?
    private var current: Int?
    private var rejected = false                  // Gespräch mit falschem Kanalcode: nicht anzeigen und nicht abspielen
    private var scrambled = false
    private var lastVoice: Date?

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: DPMRSettingsStore) {
        self.settings = settings
        decoder = DPMRDecoder(pipeline: pipeline)
        recorder = InputRecorder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "dpmrLogEnabled") as? Bool ?? true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
        if !active { finish(reason: .lost, now: Date()); if !silent { output.stopPlayback() } }
    }

    public func clear() {
        calls.removeAll()
        current = nil
        decoder.resetStats()
        stats = DPMRFramerStats()
    }

    public func toggleRecording() {
        if isRecording {
            lastRecording = recorder.stop()
            isRecording = false
            return
        }
        let name = InputRecorder.fileName(frequencyHz: nil, mode: nil, preset: "dpmr", prefix: "DPMR")
        recorder.start(url: InputRecorder.directory.appendingPathComponent(name))
        isRecording = true
        recordingDuration = 0
    }

    public var diagnosis: DPMRDiagnosis.Result { DPMRDiagnosis.assess(inputDB: inputDB, stats: stats, locked: locked) }

    public var currentCall: VoiceCall? {
        guard let i = current, calls.indices.contains(i) else { return nil }
        return calls[i]
    }

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
        let now = Date()
        for event in out.events { ingest(event, now: now, audio: &toPlay) }
        if !silent { output.play(toPlay, profile: .dmr) }
        if current != nil, let last = lastVoice, now.timeIntervalSince(last) > 3 { finish(reason: .lost, now: now) }
    }

    /// Ein Ereignis des Empfängers aufnehmen (auch für Tests und Dateiwiedergabe)
    public func ingest(_ event: DPMREvent, now: Date = Date()) {
        var ignored: [[UInt8]] = []
        ingest(event, now: now, audio: &ignored)
    }

    private func ingest(_ event: DPMREvent, now: Date, audio: inout [[UInt8]]) {
        switch event {
        case .callStart:
            finish(reason: .lost, now: now)
            var c = VoiceCall(start: now, mode: "dPMR")
            c.lateEntry = false
            calls.append(c)
            if calls.count > settings.keepCount { calls.removeFirst(calls.count - settings.keepCount) }
            current = calls.count - 1
            rejected = false
            scrambled = false
            lastVoice = now
        case .info(let called, let calling, let cc, let emergency):
            guard let i = current, calls.indices.contains(i) else { return }
            if settings.colorCode >= 0, let cc, cc != settings.colorCode {
                calls.remove(at: i)                             // anderer Kanalcode: Gespräch nicht anzeigen
                current = nil
                rejected = true
                return
            }
            if let calling { calls[i].source = calling }
            if let called { calls[i].target = called }
            var parts: [String] = []
            if let cc { parts.append("KC \(cc)") }
            calls[i].via = parts.joined(separator: " · ")
            var notes: [String] = []
            if emergency { notes.append("NOTRUF") }
            if scrambled { notes.append("Scrambler, kein Ton") }
            calls[i].note = notes.joined(separator: " · ")
            calls[i].colorCode = cc
        case .voice(let v):
            if rejected { return }
            if current == nil { ingest(.callStart, now: now, audio: &audio) }
            guard let i = current, calls.indices.contains(i) else { return }
            lastVoice = now
            if v.scrambled {
                scrambled = true
                if !calls[i].note.contains("Scrambler") { calls[i].note += (calls[i].note.isEmpty ? "" : " · ") + "Scrambler, kein Ton" }
                calls[i].frames += v.frames.count
                return
            }
            calls[i].frames += v.frames.count
            calls[i].ambe += v.frames
            audio += v.frames
        case .callEnd(let lost):
            finish(reason: lost ? .lost : .end, now: now)
        }
    }

    private func finish(reason: VoiceCall.Ended, now: Date) {
        rejected = false
        guard let i = current, calls.indices.contains(i) else { current = nil; return }
        calls[i].endedBy = reason
        if calls[i].frames == 0 { calls.remove(at: i) }
        else if logEnabled { logger.append(Self.logLine(calls[i]) + "\n", now: now) }
        current = nil
    }

    /// „08:15:02  0000243 → 0010011  KC 31  12,4 s“
    nonisolated public static func logLine(_ c: VoiceCall) -> String {
        var line = utc.string(from: c.start) + "  " + (c.source.isEmpty ? "(Absender unbekannt)" : c.source)
        line += "  → " + (c.target.isEmpty ? "(Ziel unbekannt)" : c.target)
        if !c.via.isEmpty { line += "  \(c.via)" }
        if !c.isLive { line += String(format: "  %.1f s", c.seconds) }
        if !c.note.isEmpty { line += "  \(c.note)" }
        return line
    }
}
