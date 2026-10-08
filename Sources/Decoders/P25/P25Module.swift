// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os
import VoiceCore

// P25 Phase 1 (APCO-25, C4FM 4800 Bd): Modul. Der Empfänger liest FM-Diskriminator-Audio (48 kHz) und liefert Aussendungen mit Netzkennung
// (NAC), Gruppe, Quelle, Hersteller, Verschlüsselung und die IMBE-Sprachrahmen. Der Ton kommt vom Sprachstick, falls vorhanden.

// MARK: - Einstellungen

@MainActor
public final class P25SettingsStore: ObservableObject {
    /// Nur diese Netzkennung (NAC, 0 … 0xFFF) beachten; −1 = alle
    @Published public var nac: Int { didSet { UserDefaults.standard.set(nac, forKey: "p25NAC") } }
    @Published public var keepCount: Int { didSet { UserDefaults.standard.set(keepCount, forKey: "p25KeepCount") } }

    public init() {
        let d = UserDefaults.standard
        let n = d.object(forKey: "p25NAC") as? Int ?? -1
        nac = (-1...0xFFF).contains(n) ? n : -1
        let k = d.integer(forKey: "p25KeepCount")
        keepCount = (10...500).contains(k) ? k : 100
    }

    /// Eingabe als Hexzahl („293“, „0x293“); leer = alle
    public static func parseNAC(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "0x", with: "")
        if t.isEmpty { return -1 }
        guard let v = Int(t, radix: 16), (0...0xFFF).contains(v) else { return nil }
        return v
    }
}

extension P25SettingsStore: TuningTarget {
    public var centerHz: Double { 2400 }
    public var tones: (mark: Double, space: Double) { (0, 0) }
    public var markerBandwidth: Double { 4800 }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .band("P25 · Basisband (C4FM 4800 Bd, bis 2,4 kHz)") }
}

// MARK: - Empfänger an der Pipeline

public final class P25Decoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var events: [P25Event]
        public var stats: P25FramerStats
        public var level: Double
        public var inputDB: Double
        public var inverted: Bool
        public var locked: Bool
    }

    public static let sampleRate = 48_000.0

    private let pipeline: AudioPipeline
    private let receiver = P25Receiver(sampleRate: P25Decoder.sampleRate)
    private var enabled = false
    private var meanSquare = 0.0
    private let lock = OSAllocatedUnfairLock()
    private var pending: [P25Event] = []
    private var snapshot = (stats: P25FramerStats(), level: 0.0, inputDB: -120.0, inverted: false, locked: false)

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
            lock.withLockUnchecked { snapshot.stats = P25FramerStats() }
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
        let power = samples.isEmpty ? 0 : sum / Double(samples.count)
        meanSquare += min(1.0, Double(samples.count) / (0.3 * Self.sampleRate)) * (power - meanSquare)
        let db = meanSquare > 1e-12 ? max(-120, 10 * log10(meanSquare)) : -120
        let snap = (stats: receiver.stats, level: Double(receiver.level), inputDB: db, inverted: receiver.inverted, locked: receiver.isLocked)
        lock.withLockUnchecked { snapshot = snap }
    }
}

// MARK: - Controller

@MainActor
public final class P25Controller: ObservableObject {
    public let decoder: P25Decoder
    public let logger = DecodeLogger(mode: "P25")
    @Published public private(set) var calls: [VoiceCall] = []
    @Published public private(set) var stats = P25FramerStats()
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
    @Published public var logEnabled: Bool { didSet { UserDefaults.standard.set(logEnabled, forKey: "p25LogEnabled") } }
    public var rigDescription: String?

    private let settings: P25SettingsStore
    private var timer: Timer?
    private var current: Int?
    private var rejected = false                  // Gespräch mit falscher Funkzugangsnummer: nicht anzeigen und nicht abspielen
    private var scrambled = false
    private var lastVoice: Date?

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: P25SettingsStore) {
        self.settings = settings
        decoder = P25Decoder(pipeline: pipeline)
        recorder = InputRecorder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "p25LogEnabled") as? Bool ?? true
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
        stats = P25FramerStats()
    }

    public func toggleRecording() {
        if isRecording {
            lastRecording = recorder.stop()
            isRecording = false
            return
        }
        let name = InputRecorder.fileName(frequencyHz: nil, mode: nil, preset: "p25", prefix: "P25")
        recorder.start(url: InputRecorder.directory.appendingPathComponent(name))
        isRecording = true
        recordingDuration = 0
    }

    public var diagnosis: P25Diagnosis.Result { P25Diagnosis.assess(inputDB: inputDB, stats: stats, locked: locked) }

    public var currentCall: VoiceCall? {
        guard let i = current, calls.indices.contains(i) else { return nil }
        return calls[i]
    }

    public func replay(_ call: VoiceCall) { output.play(call.ambe, profile: .p25) }

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
        if !silent { output.play(toPlay, profile: .p25) }
        if current != nil, let last = lastVoice, now.timeIntervalSince(last) > 3 { finish(reason: .lost, now: now) }
    }

    /// Ein Ereignis des Empfängers aufnehmen (auch für Tests und Dateiwiedergabe)
    public func ingest(_ event: P25Event, now: Date = Date()) {
        var ignored: [[UInt8]] = []
        ingest(event, now: now, audio: &ignored)
    }

    private func ingest(_ event: P25Event, now: Date, audio: inout [[UInt8]]) {
        switch event {
        case .callStart:
            finish(reason: .lost, now: now)
            var c = VoiceCall(start: now, mode: "P25")
            c.lateEntry = false
            calls.append(c)
            if calls.count > settings.keepCount { calls.removeFirst(calls.count - settings.keepCount) }
            current = calls.count - 1
            rejected = false
            scrambled = false
            lastVoice = now
        case .info(let info):
            guard let i = current, calls.indices.contains(i) else { return }
            if settings.nac >= 0, let nac = info.nac, nac != settings.nac {
                calls.remove(at: i)                             // andere Netzkennung: Aussendung nicht anzeigen
                current = nil
                rejected = true
                return
            }
            if let s = info.source { calls[i].source = String(s); calls[i].sourceID = s }
            if let g = info.group {
                calls[i].target = String(g)
                calls[i].targetID = g
                calls[i].isGroup = true
            } else if let t = info.target {
                calls[i].target = String(t)
                calls[i].targetID = t
                calls[i].isGroup = false
            }
            var via: [String] = []
            if let n = info.nac { via.append(String(format: "NAC %03X", n)) }
            via.append(info.group != nil ? "Gruppe" : info.target != nil ? "Einzelruf" : "")
            calls[i].via = via.filter { !$0.isEmpty }.joined(separator: " · ")
            calls[i].colorCode = info.nac
            var notes: [String] = []
            if info.emergency { notes.append("NOTRUF") }
            if let m = info.manufacturer, m > 1 { notes.append(P25.manufacturerName(m)) }
            if let a = info.algorithm, a != 0x80, a != 0 {
                notes.append("\(P25.algorithmName(a))\(info.keyID.map { " Schlüssel \($0)" } ?? ""), kein Ton")
                scrambled = true
            } else if info.algorithm == nil, info.serviceEncrypted {
                notes.append("verschlüsselt, kein Ton")
                scrambled = true
            }
            calls[i].note = notes.joined(separator: " · ")
        case .voice(let v):
            if rejected { return }
            if current == nil { ingest(.callStart(nac: 0), now: now, audio: &audio) }
            guard let i = current, calls.indices.contains(i) else { return }
            lastVoice = now
            if v.encrypted || scrambled {
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

    /// „08:15:02  P25  1234 → 4711  NAC 293 · Gruppe  12,4 s“
    nonisolated public static func logLine(_ c: VoiceCall) -> String {
        var line = utc.string(from: c.start) + "  " + c.mode + "  " + (c.source.isEmpty ? "(Absender unbekannt)" : c.source)
        line += "  → " + (c.target.isEmpty ? "(Ziel unbekannt)" : c.target)
        if !c.via.isEmpty { line += "  \(c.via)" }
        if !c.isLive { line += String(format: "  %.1f s", c.seconds) }
        if !c.note.isEmpty { line += "  \(c.note)" }
        return line
    }
}
