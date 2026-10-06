// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os
import VoiceCore

// M17: Modul. Der Empfänger liest FM-Diskriminator-Audio (48 kHz, 4FSK 4800 Symbole/s) und liefert Gespräche mit Absender, Ziel,
// Kanalzugriffsnummer (CAN) und Zusatzdaten (Text, Position). Die Sprache (Codec2) wird in der Bibliothek Codec2 decodiert und
// direkt abgespielt, ein Sprachstick ist nicht nötig.

// MARK: - Einstellungen

@MainActor
public final class M17SettingsStore: ObservableObject {
    /// Nur diese Kanalzugriffsnummer (0 … 15) beachten; −1 = alle
    @Published public var channelAccessNumber: Int { didSet { UserDefaults.standard.set(channelAccessNumber, forKey: "m17CAN") } }
    @Published public var playAudio: Bool { didSet { UserDefaults.standard.set(playAudio, forKey: "m17PlayAudio") } }
    @Published public var keepCount: Int { didSet { UserDefaults.standard.set(keepCount, forKey: "m17KeepCount") } }

    public init() {
        let d = UserDefaults.standard
        let can = d.object(forKey: "m17CAN") as? Int ?? -1
        channelAccessNumber = (-1...15).contains(can) ? can : -1
        playAudio = d.object(forKey: "m17PlayAudio") as? Bool ?? true
        let k = d.integer(forKey: "m17KeepCount")
        keepCount = (10...500).contains(k) ? k : 100
    }
}

extension M17SettingsStore: TuningTarget {
    public var centerHz: Double { 2400 }
    public var tones: (mark: Double, space: Double) { (0, 0) }
    public var markerBandwidth: Double { 4800 }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .band("M17 · Basisband (4FSK 4800 Bd, bis 2,4 kHz)") }
}

// MARK: - Empfänger an der Pipeline

public final class M17Decoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var events: [M17Event]
        public var stats: M17FramerStats
        public var level: Double
        public var inputDB: Double
        public var inverted: Bool
        public var locked: Bool
    }

    public static let sampleRate = 48_000.0

    private let pipeline: AudioPipeline
    private let slicer = FourFSKSlicer(sampleRate: M17Decoder.sampleRate)
    private let framer = M17Framer()
    private var enabled = false
    private var meanSquare = 0.0
    private let lock = OSAllocatedUnfairLock()
    private var pending: [M17Event] = []
    private var snapshot = (stats: M17FramerStats(), level: 0.0, inputDB: -120.0, inverted: false, locked: false)
    // Sprache (nur im Verarbeitungsfaden berührt)
    private var lsf: M17LSF?
    private var voice: M17Voice?
    private var held: [M17StreamFrame] = []
    private var canFilter = -1
    /// Decodierte Sprache (8 kHz, 16 Bit), aus dem Verarbeitungsfaden
    public var onSpeech: (([Int16]) -> Void)?

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        slicer.onSymbol = { [framer] symbol in framer.push(symbol: symbol) }
        framer.onEvent = { [weak self] event in self?.handle(event) }
        pipeline.addSink(rate: Self.sampleRate) { [weak self] samples in self?.consume(samples) }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            if on != enabled { slicer.reset(); framer.reset(); resetCall() }
            enabled = on
            if !on { lock.withLockUnchecked { pending.removeAll() } }
        }
    }

    /// Kanalzugriffsnummer-Filter (−1 = alle)
    public func configure(channelAccessNumber can: Int) {
        pipeline.perform { [self] in canFilter = can }
    }

    public func resetStats() {
        pipeline.perform { [self] in
            framer.reset()
            resetCall()
            lock.withLockUnchecked { snapshot.stats = M17FramerStats() }
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pending.removeAll() }
            return Output(events: pending, stats: snapshot.stats, level: snapshot.level, inputDB: snapshot.inputDB, inverted: snapshot.inverted, locked: snapshot.locked)
        }
    }

    private func resetCall() {
        lsf = nil
        held.removeAll()
        voice = nil
    }

    private func handle(_ event: M17Event) {
        switch event {
        case .callStart:
            resetCall()
            voice = M17Voice()                        // frischer Zustand des Sprachcodecs je Gespräch
        case .lsf(let l, _):
            lsf = l
            let queued = held
            held.removeAll()
            for f in queued { speak(f, l) }
        case .frame(let f):
            if let l = lsf { speak(f, l) } else if held.count < 8 { held.append(f) }
        case .callEnd, .lost:
            resetCall()
        }
        lock.withLockUnchecked { pending.append(event) }
    }

    /// Sprache eines Rahmens abspielen: nicht bei Verschlüsselung, Signaturrahmen, falscher CAN oder zu vielen Bitfehlern (dann Stille statt Krach)
    private func speak(_ f: M17StreamFrame, _ l: M17LSF) {
        guard l.isVoice, !l.isEncrypted, let voice, canFilter < 0 || l.channelAccessNumber == canFilter else { return }
        if f.frameNumber >= 0x7FFC { return }          // Rahmen mit digitaler Signatur tragen keine Sprache
        if f.errorRate > 0.2 {
            onSpeech?([Int16](repeating: 0, count: 320))
            return
        }
        onSpeech?(voice.decode(payload: f.payload, full: l.payload == .voice3200))
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

public enum M17Diagnosis {
    public enum Severity: Int, Sendable { case ok, waiting, problem }

    public struct Result: Equatable, Sendable {
        public var severity: Severity
        public var title: String
        public var advice: String
    }

    public static let silenceDB = -70.0

    public static func assess(inputDB: Double, stats: M17FramerStats, locked: Bool) -> Result {
        if inputDB < silenceDB {
            return Result(severity: .problem, title: "Kein Audio", advice: "Am Eingang kommt kein Signal an. M17 braucht das unbearbeitete FM-Diskriminator-Audio (Packet/Daten-Ausgang des Funkgeräts oder SDR-Programm mit FM-Audio ohne Entzerrung und ohne Hochpass).")
        }
        if locked {
            if stats.streamFrames + stats.badFrames > 20, Double(stats.badFrames) / Double(stats.streamFrames + stats.badFrames) > 0.4 {
                return Result(severity: .waiting, title: "Signal schwach oder verrauscht", advice: "Viele Rahmen sind nicht lesbar. Ein stärkeres Signal oder genaueres Abstimmen (Ablage unter 1 kHz) hilft.")
            }
            return Result(severity: .ok, title: "M17-Signal wird empfangen", advice: "")
        }
        if stats.syncs > 0 { return Result(severity: .ok, title: "Warten auf die nächste Aussendung", advice: "") }
        return Result(severity: .waiting, title: "Warten auf M17", advice: "Noch keine M17-Synchronisation. Das Audio muss die 4FSK-Daten mit 4800 Symbolen/s unverfälscht enthalten (nicht das fertig demodulierte Sprach-Audio).")
    }
}

// MARK: - Controller

@MainActor
public final class M17Controller: ObservableObject {
    public let decoder: M17Decoder
    public let logger = DecodeLogger(mode: "M17")
    @Published public private(set) var calls: [VoiceCall] = []
    @Published public private(set) var stats = M17FramerStats()
    @Published public private(set) var level = 0.0
    @Published public private(set) var inputDB = -120.0
    @Published public private(set) var inverted = false
    @Published public private(set) var locked = false
    /// Letzter Anteil gestörter Bits der Rahmen (gleitend, 0 … 0,5)
    @Published public private(set) var errorRate: Float = 0
    public let recorder: InputRecorder
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var lastRecording: URL?
    @Published public var logEnabled: Bool { didSet { UserDefaults.standard.set(logEnabled, forKey: "m17LogEnabled") } }
    public var rigDescription: String?

    private let settings: M17SettingsStore
    private var timer: Timer?
    private var current: Int?
    private var lastFrame: Date?
    private var currentLSF: M17LSF?
    private var textSegments: [Int: String] = [:]
    private let player = VoicePlayer()
    private var playerRunning = false
    private var cancellables: Set<AnyCancellable> = []

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: M17SettingsStore) {
        self.settings = settings
        decoder = M17Decoder(pipeline: pipeline)
        recorder = InputRecorder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "m17LogEnabled") as? Bool ?? true
        decoder.configure(channelAccessNumber: settings.channelAccessNumber)
        let player = self.player
        let playAudio = OSAllocatedUnfairLock(initialState: settings.playAudio)
        decoder.onSpeech = { speech in if playAudio.withLock({ $0 }) { player.enqueue(speech) } }
        settings.$playAudio.sink { value in playAudio.withLock { $0 = value } }.store(in: &cancellables)
        settings.$channelAccessNumber.receive(on: RunLoop.main).sink { [weak self] can in self?.decoder.configure(channelAccessNumber: can) }.store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
        if active {
            if !playerRunning { do { try player.start(); playerRunning = true } catch {} }
        } else {
            finish(reason: .lost, now: Date())
            if playerRunning { player.stop(); playerRunning = false }
        }
    }

    public func clear() {
        calls.removeAll()
        current = nil
        decoder.resetStats()
        stats = M17FramerStats()
    }

    public func toggleRecording() {
        if isRecording {
            lastRecording = recorder.stop()
            isRecording = false
            return
        }
        let name = InputRecorder.fileName(frequencyHz: nil, mode: nil, preset: "m17", prefix: "M17")
        recorder.start(url: InputRecorder.directory.appendingPathComponent(name))
        isRecording = true
        recordingDuration = 0
    }

    public var diagnosis: M17Diagnosis.Result { M17Diagnosis.assess(inputDB: inputDB, stats: stats, locked: locked) }

    public var currentCall: VoiceCall? {
        guard let i = current, calls.indices.contains(i) else { return nil }
        return calls[i]
    }

    // MARK: Verarbeitung

    private func poll() {
        let out = decoder.takeOutput()
        if out.stats != stats { stats = out.stats }
        level = out.level
        if abs(out.inputDB - inputDB) >= 0.5 { inputDB = out.inputDB }
        if out.inverted != inverted { inverted = out.inverted }
        if out.locked != locked { locked = out.locked }
        if abs(out.stats.errorRate - errorRate) > 0.005 { errorRate = out.stats.errorRate }
        if isRecording { recordingDuration = recorder.duration }
        let now = Date()
        for event in out.events { ingest(event, now: now) }
        if current != nil, let last = lastFrame, now.timeIntervalSince(last) > 3 { finish(reason: .lost, now: now) }
    }

    /// Ein Ereignis des Empfängers aufnehmen (auch für Tests und Dateiwiedergabe)
    public func ingest(_ event: M17Event, now: Date = Date()) {
        switch event {
        case .callStart:
            finish(reason: .lost, now: now)
            var c = VoiceCall(start: now, mode: "M17")
            c.lateEntry = true
            calls.append(c)
            if calls.count > settings.keepCount { calls.removeFirst(calls.count - settings.keepCount) }
            current = calls.count - 1
            currentLSF = nil
            textSegments = [:]
            lastFrame = now
        case .lsf(let lsf, let viaLICH):
            guard let i = current, calls.indices.contains(i) else { return }
            let can = settings.channelAccessNumber
            if can >= 0, lsf.channelAccessNumber != can {
                // Anderer Kanal: Gespräch nicht anzeigen
                calls.remove(at: i)
                current = nil
                return
            }
            currentLSF = lsf
            if !viaLICH { calls[i].lateEntry = false }
            apply(lsf, to: i)
        case .frame:
            guard let i = current, calls.indices.contains(i) else { return }
            lastFrame = now
            calls[i].frames += 2                                // 40 ms je Rahmen
        case .callEnd(let lost):
            finish(reason: lost ? .lost : .end, now: now)
        case .lost:
            finish(reason: .lost, now: now)
        }
    }

    private func apply(_ lsf: M17LSF, to i: Int) {
        calls[i].source = lsf.sourceName
        calls[i].target = lsf.destinationName
        var via = "CAN \(lsf.channelAccessNumber) · \(lsf.payloadText)"
        if lsf.isEncrypted { via += " · \(lsf.encryptionText)" }
        calls[i].via = via
        var notes: [String] = []
        if lsf.isEncrypted { notes.append("verschlüsselt, kein Ton") }
        if lsf.isSigned { notes.append("signiert") }
        switch lsf.content {
        case .text(let segment, _, let text):
            textSegments[segment] = text
            notes.append("„" + textSegments.sorted { $0.key < $1.key }.map(\.value).joined() + "“")
        case .position(let lat, let lon, let altitude, let speed, _, let station):
            var s = String(format: "%.4f° %@, %.4f° %@", abs(lat), lat >= 0 ? "N" : "S", abs(lon), lon >= 0 ? "O" : "W")
            if let altitude { s += String(format: ", %.0f m", altitude) }
            if let speed, speed > 0 { s += String(format: ", %.0f km/h", speed) }
            notes.append(s + " (\(station))")
        case .extendedCallsign(let first, let second):
            notes.append("CF1 \(first)" + (second.map { ", CF2 \($0)" } ?? ""))
        case .none, .unknown:
            break
        }
        if !notes.isEmpty { calls[i].note = notes.joined(separator: " · ") }
    }

    private func finish(reason: VoiceCall.Ended, now: Date) {
        guard let i = current, calls.indices.contains(i) else { current = nil; return }
        calls[i].endedBy = reason
        if calls[i].frames == 0 { calls.remove(at: i) }
        else if logEnabled { logger.append(Self.logLine(calls[i]) + "\n", now: now) }
        current = nil
        currentLSF = nil
    }

    /// „08:15:02  DL1ABC  → @ALL  CAN 0 · Sprache 3200  12,4 s“
    nonisolated public static func logLine(_ c: VoiceCall) -> String {
        var line = utc.string(from: c.start) + "  " + (c.source.isEmpty ? "(Absender unbekannt)" : c.source)
        if !c.target.isEmpty { line += "  → \(c.target)" }
        if !c.via.isEmpty { line += "  \(c.via)" }
        if !c.isLive { line += String(format: "  %.1f s", c.seconds) }
        if !c.note.isEmpty { line += "  \(c.note)" }
        if c.lateEntry { line += "  (später Einstieg)" }
        return line
    }
}
