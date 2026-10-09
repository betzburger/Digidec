// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os
import VoiceCore

// NXDN (Kenwood NEXEDGE, Icom IDAS): Modul. Der Empfänger liest FM-Diskriminator-Audio (48 kHz, 4FSK 2400 oder 4800 Symbole/s; beide
// Raten laufen nebeneinander) und liefert Gespräche mit Quelle, Ziel, Ruftyp, Funkzugangsnummer (RAN) und Sprachrahmen. Der Ton kommt
// wie bei DMR vom Sprachstick oder vom Software-Decoder, falls vorhanden.

// MARK: - Einstellungen

@MainActor
public final class NXDNSettingsStore: ObservableObject {
    /// Nur diese Funkzugangsnummer (0 … 63) beachten; −1 = alle
    @Published public var ran: Int { didSet { UserDefaults.standard.set(ran, forKey: "nxdnRAN") } }
    @Published public var keepCount: Int { didSet { UserDefaults.standard.set(keepCount, forKey: "nxdnKeepCount") } }

    public init() {
        let d = UserDefaults.standard
        let r = d.object(forKey: "nxdnRAN") as? Int ?? -1
        ran = (-1...63).contains(r) ? r : -1
        let k = d.integer(forKey: "nxdnKeepCount")
        keepCount = (10...500).contains(k) ? k : 100
    }
}

extension NXDNSettingsStore: TuningTarget {
    public var centerHz: Double { 2400 }
    public var tones: (mark: Double, space: Double) { (0, 0) }
    public var markerBandwidth: Double { 4800 }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .band("NXDN · Basisband (4FSK 2400 / 4800 Bd, bis 2,4 kHz)") }
}

// MARK: - Empfänger an der Pipeline

public final class NXDNDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var events: [NXDNEvent]
        public var stats: NXDNFramerStats
        public var level: Double
        public var inputDB: Double
        public var inverted: Bool
        public var locked: Bool
        public var baud: Double
    }

    public static let sampleRate = 48_000.0
    public static let bauds: [Double] = [2400, 4800]

    private let pipeline: AudioPipeline
    private let receivers: [NXDNReceiver] = NXDNDecoder.bauds.map { NXDNReceiver(sampleRate: NXDNDecoder.sampleRate, baud: $0) }
    private var enabled = false
    private var meanSquare = 0.0
    private let lock = OSAllocatedUnfairLock()
    private var pending: [NXDNEvent] = []
    private var snapshot = (stats: NXDNFramerStats(), level: 0.0, inputDB: -120.0, inverted: false, locked: false, baud: 0.0)

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        for r in receivers {
            r.onEvent = { [weak self] event in
                guard let self else { return }
                self.lock.withLockUnchecked { self.pending.append(event) }
            }
        }
        pipeline.addSink(rate: Self.sampleRate) { [weak self] samples in self?.consume(samples) }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            if on != enabled { for r in receivers { r.reset() } }
            enabled = on
            if !on { lock.withLockUnchecked { pending.removeAll() } }
        }
    }

    public func resetStats() {
        pipeline.perform { [self] in
            for r in receivers { r.reset() }
            lock.withLockUnchecked { snapshot.stats = NXDNFramerStats() }
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pending.removeAll() }
            return Output(events: pending, stats: snapshot.stats, level: snapshot.level, inputDB: snapshot.inputDB, inverted: snapshot.inverted, locked: snapshot.locked, baud: snapshot.baud)
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled else { return }
        var sum = 0.0
        for x in samples { sum += Double(x) * Double(x) }
        let block = Array(samples)
        for r in receivers { r.process(block) }
        let power = samples.isEmpty ? 0 : sum / Double(samples.count)
        meanSquare += min(1.0, Double(samples.count) / (0.3 * Self.sampleRate)) * (power - meanSquare)
        let db = meanSquare > 1e-12 ? max(-120, 10 * log10(meanSquare)) : -120
        let stats = receivers.dropFirst().reduce(receivers[0].stats) { $0 + $1.stats }
        let best = receivers.first(where: { $0.isLocked }) ?? receivers[0]
        let snap = (stats: stats, level: Double(best.level), inputDB: db, inverted: best.inverted, locked: best.isLocked, baud: best.baud)
        lock.withLockUnchecked { snapshot = snap }
    }
}

// MARK: - Controller

@MainActor
public final class NXDNController: ObservableObject {
    public let decoder: NXDNDecoder
    public let logger = DecodeLogger(mode: "NXDN")
    @Published public private(set) var calls: [VoiceCall] = []
    @Published public private(set) var stats = NXDNFramerStats()
    @Published public private(set) var level = 0.0
    @Published public private(set) var inputDB = -120.0
    @Published public private(set) var inverted = false
    @Published public private(set) var locked = false
    @Published public private(set) var baud = 0.0
    public let output = VoiceOutput.shared
    /// Kanal einer Kanalbank (mehrere Decoder zugleich): keine Sprachausgabe, der Stick gehört dem Hauptmodul
    public var silent = false
    public let recorder: InputRecorder
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var lastRecording: URL?
    @Published public var logEnabled: Bool { didSet { UserDefaults.standard.set(logEnabled, forKey: "nxdnLogEnabled") } }
    public var rigDescription: String?

    private let settings: NXDNSettingsStore
    private var timer: Timer?
    private var current: Int?
    private var rejected = false                  // Gespräch mit falscher Funkzugangsnummer: nicht anzeigen und nicht abspielen
    private var scrambled = false
    private var lastVoice: Date?
    private var currentBaud = 0.0

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: NXDNSettingsStore) {
        self.settings = settings
        decoder = NXDNDecoder(pipeline: pipeline)
        recorder = InputRecorder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "nxdnLogEnabled") as? Bool ?? true
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
        stats = NXDNFramerStats()
    }

    public func toggleRecording() {
        if isRecording {
            lastRecording = recorder.stop()
            isRecording = false
            return
        }
        let name = InputRecorder.fileName(frequencyHz: nil, mode: nil, preset: "nxdn", prefix: "NXDN")
        recorder.start(url: InputRecorder.directory.appendingPathComponent(name))
        isRecording = true
        recordingDuration = 0
    }

    public var diagnosis: NXDNDiagnosis.Result { NXDNDiagnosis.assess(inputDB: inputDB, stats: stats, locked: locked) }

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
        if out.baud != baud { baud = out.baud }
        if isRecording { recordingDuration = recorder.duration }
        output.refresh()
        var toPlay: [[UInt8]] = []
        let now = Date()
        for event in out.events { ingest(event, now: now, audio: &toPlay) }
        if !silent { output.play(toPlay, profile: .dmr) }
        if current != nil, let last = lastVoice, now.timeIntervalSince(last) > 3 { finish(reason: .lost, now: now) }
    }

    /// Ein Ereignis des Empfängers aufnehmen (auch für Tests und Dateiwiedergabe)
    public func ingest(_ event: NXDNEvent, now: Date = Date()) {
        var ignored: [[UInt8]] = []
        ingest(event, now: now, audio: &ignored)
    }

    private func ingest(_ event: NXDNEvent, now: Date, audio: inout [[UInt8]]) {
        switch event {
        case .callStart(let rate):
            finish(reason: .lost, now: now)
            currentBaud = rate
            var c = VoiceCall(start: now, mode: rate >= 4800 ? "NXDN96" : "NXDN48")
            c.lateEntry = false
            calls.append(c)
            if calls.count > settings.keepCount { calls.removeFirst(calls.count - settings.keepCount) }
            current = calls.count - 1
            rejected = false
            scrambled = false
            lastVoice = now
        case .info(let info):
            guard let i = current, calls.indices.contains(i) else { return }
            if settings.ran >= 0, let ran = info.ran, ran != settings.ran {
                calls.remove(at: i)                             // andere Funkzugangsnummer: Gespräch nicht anzeigen
                current = nil
                rejected = true
                return
            }
            if let s = info.source { calls[i].source = String(s); calls[i].sourceID = s }
            if let d = info.destination {
                calls[i].target = String(d)
                calls[i].targetID = d
            }
            if let t = info.callType {
                calls[i].isGroup = t == 1 || t == 0
            }
            var via: [String] = []
            if let r = info.ran { via.append("RAN \(r)") }
            if let t = info.callType { via.append(NXDN.callTypeName(t)) }
            calls[i].via = via.joined(separator: " · ")
            calls[i].colorCode = info.ran
            var notes: [String] = []
            if let o = info.option {
                notes.append(NXDN.transmissionName(option: o))
                if o & 7 == 3 { notes.append("EFR-Codec, kein Ton"); scrambled = true }     // 9600 bit/s EFR: Vollraten-Codec, nicht unterstützt
            }
            if let c = info.cipher, c != 0 {
                notes.append("\(NXDN.cipherName(c))\(info.keyID.map { " Schlüssel \($0)" } ?? ""), kein Ton")
                scrambled = true
            }
            calls[i].note = notes.joined(separator: " · ")
        case .voice(let v):
            if rejected { return }
            if current == nil { ingest(.callStart(baud: currentBaud > 0 ? currentBaud : 2400), now: now, audio: &audio) }
            guard let i = current, calls.indices.contains(i) else { return }
            lastVoice = now
            if v.scrambled || scrambled {
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

    /// „08:15:02  NXDN96  901 → 4711  RAN 1 · Gruppe  12,4 s“
    nonisolated public static func logLine(_ c: VoiceCall) -> String {
        var line = utc.string(from: c.start) + "  " + c.mode + "  " + (c.source.isEmpty ? "(Absender unbekannt)" : c.source)
        line += "  → " + (c.target.isEmpty ? "(Ziel unbekannt)" : c.target)
        if !c.via.isEmpty { line += "  \(c.via)" }
        if !c.isLive { line += String(format: "  %.1f s", c.seconds) }
        if !c.note.isEmpty { line += "  \(c.note)" }
        return line
    }
}
