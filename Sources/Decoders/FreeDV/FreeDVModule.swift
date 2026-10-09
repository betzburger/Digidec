// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os
import VoiceCore

// FreeDV: Modul. Das Audio des Funkgeräts (USB, 8 kHz) geht durch das Modem aus der Bibliothek Codec2; die decodierte Sprache
// wird direkt über den Standard-Ausgang abgespielt (kein Sprachstick nötig). Der Textkanal liefert das Rufzeichen der Gegenstation.

// MARK: - Einstellungen

@MainActor
public final class FreeDVSettingsStore: ObservableObject {
    @Published public var mode: FreeDVMode { didSet { UserDefaults.standard.set(Int(mode.rawValue), forKey: "freedvMode") } }
    /// Ton nur bei Synchronisation und ausreichendem Rauschabstand (sonst Stille statt Rauschen und Zischen)
    @Published public var squelch: Bool { didSet { UserDefaults.standard.set(squelch, forKey: "freedvSquelch") } }
    @Published public var playAudio: Bool { didSet { UserDefaults.standard.set(playAudio, forKey: "freedvPlayAudio") } }
    @Published public var keepCount: Int { didSet { UserDefaults.standard.set(keepCount, forKey: "freedvKeepCount") } }

    public init() {
        let d = UserDefaults.standard
        // Fehlender Wert = Standard 700D (0 wäre sonst die Kennung von 1600)
        mode = (d.object(forKey: "freedvMode") as? Int).flatMap { FreeDVMode(rawValue: Int32($0)) } ?? .mode700D
        squelch = d.object(forKey: "freedvSquelch") as? Bool ?? true
        playAudio = d.object(forKey: "freedvPlayAudio") as? Bool ?? true
        let k = d.integer(forKey: "freedvKeepCount")
        keepCount = (10...500).contains(k) ? k : 100
    }
}

extension FreeDVSettingsStore: TuningTarget {
    public var centerHz: Double { 1500 }
    public var tones: (mark: Double, space: Double) { (0, 0) }
    public var markerBandwidth: Double { mode.bandwidthHz }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .band("FreeDV \(mode.title) · NF-Band um 1500 Hz (USB)") }
}

// MARK: - Empfänger an der Pipeline

public final class FreeDVDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var status: FreeDVStatus
        public var texts: [Character]
        public var inputDB: Double
        public var speechSeconds: Double
    }

    public static let sampleRate = 8_000.0

    private let pipeline: AudioPipeline
    private var modem: FreeDVModem?
    private var mode = FreeDVMode.mode700D
    private var gate = true
    private var enabled = false
    private var meanSquare = 0.0
    private var lastSync = Date.distantPast
    private let lock = OSAllocatedUnfairLock()
    private var status = FreeDVStatus()
    private var texts: [Character] = []
    private var inputDB = -120.0
    private var speechSeconds = 0.0
    /// Decodierte Sprache (8 kHz, 16 Bit), aus dem Verarbeitungsfaden
    public var onSpeech: (([Int16]) -> Void)?

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addSink(rate: Self.sampleRate) { [weak self] samples in self?.consume(samples) }
    }

    /// Betriebsart und Sperre einstellen (öffnet das Modem neu)
    public func configure(mode: FreeDVMode, squelch: Bool, enabled on: Bool) {
        pipeline.perform { [self] in
            self.mode = mode
            gate = squelch
            enabled = on
            modem = on ? FreeDVModem(mode: mode) : nil
            modem?.onText = { [weak self] c in
                guard let self else { return }
                self.lock.withLockUnchecked { self.texts.append(c) }
            }
            lock.withLockUnchecked { status = FreeDVStatus(); speechSeconds = 0 }
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { texts.removeAll() }
            return Output(status: status, texts: texts, inputDB: inputDB, speechSeconds: speechSeconds)
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled, let modem else { return }
        var sum = 0.0
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, x) in samples.enumerated() {
            sum += Double(x) * Double(x)
            pcm[i] = Int16(max(-32768, min(32767, x * 32767)))
        }
        let block = samples.isEmpty ? 0 : sum / Double(samples.count)
        meanSquare += min(1.0, Double(samples.count) / (0.3 * Self.sampleRate)) * (block - meanSquare)
        let speech = modem.receive(pcm)
        let st = modem.status
        let now = Date()
        if st.sync { lastSync = now }
        // Mit Sperre: Ton nur, solange das Modem (vor höchstens einer halben Sekunde) synchron war
        let play = !gate || now.timeIntervalSince(lastSync) < 0.5
        if !speech.isEmpty, play { onSpeech?(speech) }
        let db = meanSquare > 1e-12 ? max(-120, 10 * log10(meanSquare)) : -120
        lock.withLockUnchecked {
            status = st
            inputDB = db
            if !speech.isEmpty, play { speechSeconds += Double(speech.count) / 8000 }
        }
    }
}

// MARK: - Verlauf

/// Eine Übertragung (von der Synchronisation bis zu ihrem Verlust)
public struct FreeDVTransmission: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var start: Date
    public var mode: FreeDVMode
    public var text = ""
    public var seconds = 0.0
    public var snrSum = 0.0
    public var snrCount = 0
    public var isLive = true
    public var averageSNR: Double { snrCount > 0 ? snrSum / Double(snrCount) : 0 }
}

// MARK: - Diagnose

public enum FreeDVDiagnosis {
    public enum Severity: Int, Sendable { case ok, waiting, problem }

    public struct Result: Equatable, Sendable {
        public var severity: Severity
        public var title: String
        public var advice: String
    }

    public static let silenceDB = -70.0

    public static func assess(inputDB: Double, sync: Bool, everSynced: Bool, mode: FreeDVMode) -> Result {
        if inputDB < silenceDB {
            return Result(severity: .problem, title: "Kein Audio", advice: "Am Eingang kommt kein Signal an. FreeDV braucht das Empfangs-Audio des Funkgeräts (USB-Seitenband, Filter etwa 300 bis 2500 Hz, AGC an).")
        }
        if sync { return Result(severity: .ok, title: "FreeDV \(mode.title) synchron", advice: "") }
        if everSynced { return Result(severity: .ok, title: "Warten auf die nächste Übertragung", advice: "") }
        return Result(severity: .waiting, title: "Warten auf FreeDV \(mode.title)", advice: "Noch keine Synchronisation. Prüfe die Betriebsart (700D und 700E sehen ähnlich aus), das Seitenband (USB, auch auf 40 m und 80 m) und dass das Signal in den NF-Bereich 500 bis 2500 Hz fällt.")
    }
}

// MARK: - Controller

@MainActor
public final class FreeDVController: ObservableObject {
    public let decoder: FreeDVDecoder
    public let logger = DecodeLogger(mode: "FREEDV")
    @Published public private(set) var transmissions: [FreeDVTransmission] = []
    @Published public private(set) var status = FreeDVStatus()
    @Published public private(set) var inputDB = -120.0
    @Published public private(set) var everSynced = false
    @Published public private(set) var isSpeaking = false
    public let recorder: InputRecorder
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var lastRecording: URL?
    @Published public var logEnabled: Bool { didSet { UserDefaults.standard.set(logEnabled, forKey: "freedvLogEnabled") } }
    public var rigDescription: String?

    private let settings: FreeDVSettingsStore
    private var timer: Timer?
    private var active = false
    private var current: Int?
    private var lastSyncAt: Date?
    private var line = ""
    private var lastSpeech = 0.0
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

    public init(pipeline: AudioPipeline, settings: FreeDVSettingsStore) {
        self.settings = settings
        decoder = FreeDVDecoder(pipeline: pipeline)
        recorder = InputRecorder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "freedvLogEnabled") as? Bool ?? true
        let player = self.player
        let playAudio = OSAllocatedUnfairLock(initialState: true)
        decoder.onSpeech = { speech in if playAudio.withLock({ $0 }) { player.enqueue(speech) } }
        settings.$playAudio.sink { value in playAudio.withLock { $0 = value } }.store(in: &cancellables)
        settings.$mode.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.reconfigure() } }.store(in: &cancellables)
        settings.$squelch.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.reconfigure() } }.store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func reconfigure() {
        decoder.configure(mode: settings.mode, squelch: settings.squelch, enabled: active)
        finishCurrent(now: Date())
    }

    public func setActive(_ on: Bool) {
        active = on
        decoder.configure(mode: settings.mode, squelch: settings.squelch, enabled: on)
        if on {
            if !playerRunning { do { try player.start(); playerRunning = true } catch {} }
        } else {
            finishCurrent(now: Date())
            if playerRunning { player.stop(); playerRunning = false }
        }
    }

    public func clear() {
        transmissions.removeAll()
        current = nil
        everSynced = false
    }

    public func toggleRecording() {
        if isRecording {
            lastRecording = recorder.stop()
            isRecording = false
            return
        }
        let name = InputRecorder.fileName(frequencyHz: nil, mode: nil, preset: settings.mode.title.lowercased(), prefix: "FREEDV")
        recorder.start(url: InputRecorder.directory.appendingPathComponent(name))
        isRecording = true
        recordingDuration = 0
    }

    public var diagnosis: FreeDVDiagnosis.Result {
        FreeDVDiagnosis.assess(inputDB: inputDB, sync: status.sync, everSynced: everSynced, mode: settings.mode)
    }

    // MARK: Verarbeitung

    private func poll() {
        guard active else { return }
        let out = decoder.takeOutput()
        let now = Date()
        status = out.status
        if abs(out.inputDB - inputDB) >= 0.5 { inputDB = out.inputDB }
        if isRecording { recordingDuration = recorder.duration }
        let speaking = out.speechSeconds > lastSpeech
        lastSpeech = out.speechSeconds
        if speaking != isSpeaking { isSpeaking = speaking }
        for c in out.texts { feed(c) }
        if out.status.sync {
            everSynced = true
            lastSyncAt = now
            if current == nil { begin(now: now) }
            if let i = current {
                transmissions[i].seconds = now.timeIntervalSince(transmissions[i].start)
                transmissions[i].snrSum += out.status.snr
                transmissions[i].snrCount += 1
            }
        } else if current != nil, let last = lastSyncAt, now.timeIntervalSince(last) > 2.0 {
            finishCurrent(now: now)
        }
    }

    /// Zeichen des Textkanals: eine Zeile endet mit Wagenrücklauf; angezeigt wird die letzte vollständige Zeile
    private func feed(_ c: Character) {
        if c == "\r" || c == "\n" {
            let text = line.trimmingCharacters(in: .whitespaces)
            line = ""
            if !text.isEmpty, let i = current, transmissions[i].text != text { transmissions[i].text = text }
        } else if c.isASCII, c.asciiValue.map({ $0 >= 0x20 && $0 < 0x7F }) == true {
            line.append(c)
            if line.count > 60 { line.removeFirst() }
        }
    }

    private func begin(now: Date) {
        transmissions.append(FreeDVTransmission(start: now, mode: settings.mode))
        if transmissions.count > settings.keepCount { transmissions.removeFirst(transmissions.count - settings.keepCount) }
        current = transmissions.count - 1
        line = ""
    }

    private func finishCurrent(now: Date) {
        guard let i = current, transmissions.indices.contains(i) else { current = nil; return }
        transmissions[i].isLive = false
        if transmissions[i].seconds < 1.0 { transmissions.remove(at: i) }
        else if logEnabled { logger.append(Self.logLine(transmissions[i]) + "\n", now: now) }
        current = nil
    }

    /// „08:15:02  FreeDV 700D  DL1ABC  12 s  S/N 7,2 dB“
    nonisolated public static func logLine(_ t: FreeDVTransmission) -> String {
        var s = utc.string(from: t.start) + "  FreeDV " + t.mode.title + "  " + (t.text.isEmpty ? "(ohne Text)" : t.text)
        if !t.isLive { s += String(format: "  %.0f s  S/N %.1f dB", t.seconds, t.averageSNR) }
        return s
    }
}
