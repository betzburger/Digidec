// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os
import VoiceCore

// DMR (Digital Mobile Radio, Stufe 1, zwei Zeitschlitze): Modul. Der Empfänger liest FM-Diskriminator-Audio (48 kHz, 4FSK 4800
// Symbole/s) und liefert Gespräche je Zeitschlitz mit Absender, Ziel und Sprachrahmen. Der Ton kommt aus dem Sprachstick; weil
// der Chip nur einen Kanal hat, wird ein Zeitschlitz abgespielt (wählbar, oder der zuerst aktive).

// MARK: - Einstellungen

public enum DMRAudioSlot: String, CaseIterable, Identifiable, Sendable {
    case auto, slot1, slot2
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .auto: return "AUTO"
        case .slot1: return "ZS 1"
        case .slot2: return "ZS 2"
        }
    }
}

@MainActor
public final class DMRSettingsStore: ObservableObject {
    /// Zeitschlitz für den Ton
    @Published public var audioSlot: DMRAudioSlot { didSet { UserDefaults.standard.set(audioSlot.rawValue, forKey: "dmrAudioSlot") } }
    /// Nur diesen Farbcode (0 … 15) beachten; −1 = alle
    @Published public var colorCode: Int { didSet { UserDefaults.standard.set(colorCode, forKey: "dmrColorCode") } }
    @Published public var keepCount: Int { didSet { UserDefaults.standard.set(keepCount, forKey: "dmrKeepCount") } }

    public init() {
        let d = UserDefaults.standard
        audioSlot = DMRAudioSlot(rawValue: d.string(forKey: "dmrAudioSlot") ?? "") ?? .auto
        let cc = d.object(forKey: "dmrColorCode") as? Int ?? -1
        colorCode = (-1...15).contains(cc) ? cc : -1
        let k = d.integer(forKey: "dmrKeepCount")
        keepCount = (10...500).contains(k) ? k : 100
    }
}

extension DMRSettingsStore: TuningTarget {
    public var centerHz: Double { 2400 }
    public var tones: (mark: Double, space: Double) { (0, 0) }
    public var markerBandwidth: Double { 4800 }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .band("DMR · Basisband (4FSK 4800 Bd, bis 2,4 kHz)") }
}

// MARK: - Empfänger an der Pipeline

public final class DMRDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var events: [DMREvent]
        public var stats: DMRFramerStats
        public var level: Double
        public var inputDB: Double
        public var inverted: Bool
        public var locked: Bool
        public var baseStation: Bool
    }

    public static let sampleRate = 48_000.0

    private let pipeline: AudioPipeline
    private let slicer = FourFSKSlicer(sampleRate: DMRDecoder.sampleRate)
    private let framer = DMRFramer()
    private var enabled = false
    private var meanSquare = 0.0
    private let lock = OSAllocatedUnfairLock()
    private var pending: [DMREvent] = []
    private var snapshot = (stats: DMRFramerStats(), level: 0.0, inputDB: -120.0, inverted: false, locked: false, base: true)

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

    /// Farbcode-Filter (−1 = alle)
    public func configure(colorCode: Int) {
        pipeline.perform { [self] in framer.colorCodeFilter = colorCode >= 0 ? colorCode : nil }
    }

    public func resetStats() {
        pipeline.perform { [self] in
            framer.reset()
            lock.withLockUnchecked { snapshot.stats = DMRFramerStats() }
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pending.removeAll() }
            return Output(events: pending, stats: snapshot.stats, level: snapshot.level, inputDB: snapshot.inputDB, inverted: snapshot.inverted, locked: snapshot.locked, baseStation: snapshot.base)
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
        let stats = framer.stats, inverted = framer.inverted, locked = framer.isLocked, base = framer.isBaseStation
        let level = Double(slicer.level)
        lock.withLockUnchecked { snapshot = (stats, level, db, inverted, locked, base) }
    }
}

// MARK: - Diagnose

public enum DMRDiagnosis {
    public enum Severity: Int, Sendable { case ok, waiting, problem }

    public struct Result: Equatable, Sendable {
        public var severity: Severity
        public var title: String
        public var advice: String
    }

    public static let silenceDB = -70.0

    public static func assess(inputDB: Double, stats: DMRFramerStats, locked: Bool) -> Result {
        if inputDB < silenceDB {
            return Result(severity: .problem, title: "Kein Audio", advice: "Am Eingang kommt kein Signal an. DMR braucht das unbearbeitete FM-Diskriminator-Audio (Packet/Daten-Ausgang des Funkgeräts oder SDR-Programm mit FM-Audio ohne Entzerrung und ohne Hochpass).")
        }
        if locked {
            if stats.voiceBursts > 0, stats.frames > 0, Double(stats.cleanFrames) / Double(stats.frames) < 0.15 {
                return Result(severity: .waiting, title: "Signal schwach oder verrauscht", advice: "Die Sprachrahmen haben viele Bitfehler (der Sprachchip glättet das, es kann aber rauschen oder knacken). Ein stärkeres Signal oder ein breiteres Diskriminator-Audio hilft.")
            }
            return Result(severity: .ok, title: "DMR-Signal wird empfangen", advice: "")
        }
        if stats.syncs > 0 { return Result(severity: .ok, title: "Warten auf die nächste Aussendung", advice: "") }
        return Result(severity: .waiting, title: "Warten auf DMR", advice: "Noch keine DMR-Synchronisation. Das Audio muss die 4FSK-Daten mit 4800 Symbolen/s unverfälscht enthalten (nicht das fertig demodulierte Sprach-Audio).")
    }
}

// MARK: - Controller

@MainActor
public final class DMRController: ObservableObject {
    public let decoder: DMRDecoder
    public let logger = DecodeLogger(mode: "DMR")
    @Published public private(set) var calls: [VoiceCall] = []
    @Published public private(set) var stats = DMRFramerStats()
    @Published public private(set) var level = 0.0
    @Published public private(set) var inputDB = -120.0
    @Published public private(set) var inverted = false
    @Published public private(set) var locked = false
    @Published public private(set) var baseStation = true
    /// Zeitschlitz (0 oder 1), dessen Ton gerade abgespielt wird
    @Published public private(set) var audibleSlot: Int?
    public let output = VoiceOutput.shared
    /// Kanal einer Kanalbank (mehrere Decoder zugleich): keine Sprachausgabe, der Stick gehört dem Hauptmodul
    public var silent = false
    public let recorder: InputRecorder
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var lastRecording: URL?
    @Published public var logEnabled: Bool { didSet { UserDefaults.standard.set(logEnabled, forKey: "dmrLogEnabled") } }
    public var rigDescription: String?

    private let settings: DMRSettingsStore
    private var timer: Timer?
    private var aliases = [DMRTalkerAlias(), DMRTalkerAlias()]     // Talker Alias je Zeitschlitz
    private var current: [Int?] = [nil, nil]          // Index in `calls` je Zeitschlitz
    private var lastVoice: [Date?] = [nil, nil]
    private var cancellables: Set<AnyCancellable> = []

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: DMRSettingsStore) {
        self.settings = settings
        decoder = DMRDecoder(pipeline: pipeline)
        recorder = InputRecorder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "dmrLogEnabled") as? Bool ?? true
        decoder.configure(colorCode: settings.colorCode)
        DMRIDDatabase.shared.$count.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshAllNames() }.store(in: &cancellables)
        settings.$colorCode.receive(on: RunLoop.main).sink { [weak self] cc in self?.decoder.configure(colorCode: cc) }.store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
        if !active { for slot in 0..<2 { finish(slot: slot, reason: .lost, now: Date()) }; if !silent { output.stopPlayback() } }
    }

    public func clear() {
        calls.removeAll()
        current = [nil, nil]
        decoder.resetStats()
        stats = DMRFramerStats()
    }

    public func toggleRecording() {
        if isRecording {
            lastRecording = recorder.stop()
            isRecording = false
            return
        }
        let name = InputRecorder.fileName(frequencyHz: nil, mode: nil, preset: "dmr", prefix: "DMR")
        recorder.start(url: InputRecorder.directory.appendingPathComponent(name))
        isRecording = true
        recordingDuration = 0
    }

    public var diagnosis: DMRDiagnosis.Result { DMRDiagnosis.assess(inputDB: inputDB, stats: stats, locked: locked) }

    /// Aktuelles Gespräch eines Zeitschlitzes (0 oder 1)
    public func currentCall(slot: Int) -> VoiceCall? {
        guard let i = current[slot], calls.indices.contains(i) else { return nil }
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
        if out.baseStation != baseStation { baseStation = out.baseStation }
        if isRecording { recordingDuration = recorder.duration }
        output.refresh()
        var toPlay: [[UInt8]] = []
        let now = Date()
        for event in out.events { ingest(event, now: now, audio: &toPlay) }
        if !silent { output.play(toPlay, profile: .dmr) }
        for slot in 0..<2 {
            if current[slot] != nil, let last = lastVoice[slot], now.timeIntervalSince(last) > 3 { finish(slot: slot, reason: .lost, now: now) }
        }
    }

    /// Ein Ereignis des Empfängers aufnehmen (auch für Tests und Dateiwiedergabe)
    public func ingest(_ event: DMREvent, now: Date = Date()) {
        var ignored: [[UInt8]] = []
        ingest(event, now: now, audio: &ignored)
    }

    /// Absender und Ziel in Textform: Rufzeichen aus der ID-Liste, wenn bekannt; sonst die Nummer
    private func apply(_ lc: DMRLinkControl, to i: Int) {
        calls[i].sourceID = lc.source
        calls[i].targetID = lc.destination
        calls[i].isGroup = !lc.isPrivateCall
        refreshNames(of: i)
    }

    private func refreshNames(of i: Int) {
        guard let sid = calls[i].sourceID, let tid = calls[i].targetID else { return }
        let db = DMRIDDatabase.shared
        if let e = db.lookup(sid) {
            calls[i].source = e.callsign
            calls[i].note = "ID \(sid)" + (e.description.isEmpty ? "" : " · " + e.description)
        } else {
            calls[i].source = "\(sid)"
            calls[i].note = ""
        }
        if !calls[i].alias.isEmpty { calls[i].note += (calls[i].note.isEmpty ? "" : " · ") + "Alias „\(calls[i].alias)“" }
        if calls[i].isGroup { calls[i].target = "TG \(tid)" }
        else { calls[i].target = db.lookup(tid)?.callsign ?? "ID \(tid)" }
    }

    /// Nach dem Laden der ID-Liste die schon angezeigten Gespräche neu beschriften
    public func refreshAllNames() { for i in calls.indices { refreshNames(of: i) } }

    private func start(slot: Int, colorCode: Int?, lc: DMRLinkControl?, now: Date) {
        finish(slot: slot, reason: .lost, now: now)
        var c = VoiceCall(start: now, mode: "DMR")
        c.slot = slot + 1
        c.colorCode = colorCode
        c.lateEntry = lc == nil
        calls.append(c)
        if calls.count > settings.keepCount {
            let removed = calls.count - settings.keepCount
            calls.removeFirst(removed)
            for s in 0..<2 { if let i = current[s] { current[s] = i - removed >= 0 ? i - removed : nil } }
        }
        current[slot] = calls.count - 1
        aliases[slot] = DMRTalkerAlias()
        lastVoice[slot] = now
        if let lc, lc.isCall { apply(lc, to: calls.count - 1) }
        updateVia(slot: slot)
    }

    private func updateVia(slot: Int) {
        guard let i = current[slot], calls.indices.contains(i) else { return }
        var parts = ["ZS \(slot + 1)"]
        if let cc = calls[i].colorCode { parts.append("CC \(cc)") }
        calls[i].via = parts.joined(separator: " · ")
    }

    private func ingest(_ event: DMREvent, now: Date, audio: inout [[UInt8]]) {
        switch event {
        case .callStart(let slot, let cc, let lc):
            start(slot: slot, colorCode: cc, lc: lc, now: now)
        case .linkControl(let slot, let lc):
            guard let i = current[slot], calls.indices.contains(i) else { return }
            if DMRTalkerAlias.isAlias(lc) {
                if aliases[slot].ingest(lc) {
                    calls[i].alias = aliases[slot].text
                    refreshNames(of: i)
                }
                return
            }
            guard lc.isCall else { return }
            apply(lc, to: i)
        case .voice(let burst):
            if current[burst.slot] == nil { start(slot: burst.slot, colorCode: burst.colorCode, lc: nil, now: now) }
            guard let i = current[burst.slot] else { return }
            lastVoice[burst.slot] = now
            if calls[i].colorCode == nil, let cc = burst.colorCode { calls[i].colorCode = cc; updateVia(slot: burst.slot) }
            calls[i].frames += burst.frames.count
            calls[i].ambe += burst.frames
            if isAudible(slot: burst.slot) { audio += burst.frames }
        case .callEnd(let slot, let lc, let lost):
            if let lc, lc.isCall, let i = current[slot], calls.indices.contains(i), calls[i].source.isEmpty { apply(lc, to: i) }
            finish(slot: slot, reason: lost ? .lost : .end, now: now)
        case .data:
            break
        case .lost:
            for slot in 0..<2 { finish(slot: slot, reason: .lost, now: now) }
        }
    }

    /// Gehört der Zeitschlitz zum Ton? AUTO: der zuerst aktive, bis dessen Gespräch endet
    private func isAudible(slot: Int) -> Bool {
        switch settings.audioSlot {
        case .slot1: audibleSlot = 0; return slot == 0
        case .slot2: audibleSlot = 1; return slot == 1
        case .auto:
            if audibleSlot == nil || current[audibleSlot!] == nil { audibleSlot = slot }
            return audibleSlot == slot
        }
    }

    private func finish(slot: Int, reason: VoiceCall.Ended, now: Date) {
        guard let i = current[slot], calls.indices.contains(i) else { current[slot] = nil; return }
        calls[i].endedBy = reason
        if calls[i].frames == 0 { calls.remove(at: i); for s in 0..<2 { if let j = current[s], j > i { current[s] = j - 1 } } }
        else if logEnabled { logger.append(Self.logLine(calls[i]) + "\n", now: now) }
        current[slot] = nil
        if audibleSlot == slot { audibleSlot = nil }
    }

    /// „08:15:02  2621234  → TG 262  ZS 2 · CC 1  12,4 s“
    nonisolated public static func logLine(_ c: VoiceCall) -> String {
        var line = utc.string(from: c.start) + "  " + (c.source.isEmpty ? "(Absender unbekannt)" : c.source)
        if !c.target.isEmpty { line += "  → \(c.target)" }
        if !c.via.isEmpty { line += "  \(c.via)" }
        if !c.isLive { line += String(format: "  %.1f s", c.seconds) }
        if !c.alias.isEmpty { line += "  Alias „\(c.alias)“" }
        if c.lateEntry { line += "  (später Einstieg)" }
        return line
    }
}
