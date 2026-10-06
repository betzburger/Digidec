// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os

// VOR/ILS: Modul. Der Empfänger liest AM-demoduliertes Audio (48 kHz) vom SDR-Programm und zeigt bei einem VOR die Peilung
// (Radial) und die Kennung, bei einem ILS-Sender die Ablage (DDM aus 90 und 150 Hz) und die Kennung.

// MARK: - Einstellungen

public enum ILSKind: String, CaseIterable, Identifiable, Sendable {
    case localizer, glideslope
    public var id: String { rawValue }
    public var title: String { self == .localizer ? "LANDEKURS" : "GLEITWEG" }
    /// DDM bei Vollausschlag der Anzeige (150 µA)
    public var fullScaleDDM: Double { self == .localizer ? 0.155 : 0.175 }
}

@MainActor
public final class NavSettingsStore: ObservableObject {
    /// Eichung der Peilung (Grad), wird zur gemessenen Peilung addiert
    @Published public var bearingOffset: Double { didSet { UserDefaults.standard.set(bearingOffset, forKey: "navBearingOffset") } }
    @Published public var ilsKind: ILSKind { didSet { UserDefaults.standard.set(ilsKind.rawValue, forKey: "navILSKind") } }

    public init() {
        let d = UserDefaults.standard
        bearingOffset = d.object(forKey: "navBearingOffset") as? Double ?? 0
        ilsKind = d.string(forKey: "navILSKind").flatMap(ILSKind.init(rawValue:)) ?? .localizer
    }
}

extension NavSettingsStore: TuningTarget {
    public var centerHz: Double { 2400 }
    public var tones: (mark: Double, space: Double) { (0, 0) }
    public var markerBandwidth: Double { 4800 }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .band("VOR/ILS · AM-Audio 48 kHz") }
}

// MARK: - Empfänger an der Pipeline

public final class NavDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var vor: VORReading?
        public var ils: ILSReading?
        public var idents: [String]
        public var inputDB: Double
        public var identLevel: Double
    }

    private let pipeline: AudioPipeline
    private let receiver = NavReceiver()
    private var enabled = false
    private let lock = OSAllocatedUnfairLock()
    private var pendingIdents: [String] = []
    private var snapshot = (vor: nil as VORReading?, ils: nil as ILSReading?, inputDB: -120.0, identLevel: 0.0)

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        receiver.onIdent = { [weak self] text in self?.lock.withLockUnchecked { self?.pendingIdents.append(text) } }
        receiver.onBlock = { [weak self] in
            guard let self else { return }
            let s = (receiver.vor, receiver.ils, receiver.inputDB, receiver.identLevel)
            lock.withLockUnchecked { snapshot = s }
        }
        pipeline.addSink(rate: NavAudio.sampleRate) { [weak self] samples in self?.consume(samples) }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            if on != enabled { receiver.reset() }
            enabled = on
            if !on { lock.withLockUnchecked { pendingIdents.removeAll(); snapshot = (nil, nil, -120, 0) } }
        }
    }

    public func reset() {
        pipeline.perform { [self] in
            receiver.reset()
            lock.withLockUnchecked { pendingIdents.removeAll(); snapshot = (nil, nil, -120, 0) }
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pendingIdents.removeAll() }
            return Output(vor: snapshot.vor, ils: snapshot.ils, idents: pendingIdents, inputDB: snapshot.inputDB, identLevel: snapshot.identLevel)
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled else { return }
        receiver.process(samples)
    }
}

// MARK: - Diagnose und Auswertung

public enum NavMode: Equatable, Sendable { case none, vor, ils }

public enum NavDiagnosis {
    public static let silenceDB = -70.0

    public struct Result: Equatable, Sendable {
        public var ok: Bool
        public var title: String
        public var advice: String
    }

    public static func assess(inputDB: Double, mode: NavMode, vor: VORReading?, secondsWithoutSignal: Double) -> Result {
        if inputDB < silenceDB {
            return Result(ok: false, title: "Kein Audio", advice: "Am Eingang kommt kein Signal an. Das SDR-Programm muss AM-Audio (48 kHz) an Digidec ausgeben.")
        }
        switch mode {
        case .vor: return Result(ok: true, title: "VOR-Signal wird empfangen", advice: "")
        case .ils: return Result(ok: true, title: "ILS-Signal wird empfangen", advice: "")
        case .none:
            if secondsWithoutSignal < 5 { return Result(ok: true, title: "Suche …", advice: "") }
            var advice = "Kein VOR- oder ILS-Signal erkannt. AM-Demodulation (nicht USB oder FM) mit 48 kHz Audio; für ein VOR muss die AM-Bandbreite mindestens 25 kHz betragen (der 9960-Hz-Hilfsträger liegt sonst außerhalb), der AGC darf nicht pumpen."
            if let v = vor, v.deviationHz < 300, v.variableLevel > 0.001 { advice += " Der 30-Hz-Ton ist da, der Hilfsträger fehlt: Filter zu schmal?" }
            return Result(ok: false, title: "Warten auf VOR/ILS", advice: advice)
        }
    }
}

public enum NavFormat {
    public static func bearingText(_ degrees: Double) -> String { String(format: "%05.1f°", degrees).replacingOccurrences(of: ".", with: ",") }

    /// DDM → Hinweis zur Flugrichtung
    public static func ilsAdvice(ddm: Double, kind: ILSKind) -> String {
        if abs(ddm) < 0.0025 { return kind == .localizer ? "auf der Mittellinie" : "auf dem Gleitpfad" }
        switch kind {
        case .localizer: return ddm > 0 ? "links der Mittellinie (nach rechts fliegen)" : "rechts der Mittellinie (nach links fliegen)"
        case .glideslope: return ddm > 0 ? "über dem Gleitpfad (nach unten fliegen)" : "unter dem Gleitpfad (nach oben fliegen)"
        }
    }
}

// MARK: - Controller

@MainActor
public final class NavController: ObservableObject {
    public let decoder: NavDecoder
    public let logger = DecodeLogger(mode: "VOR")
    public let recorder: InputRecorder
    @Published public private(set) var mode = NavMode.none
    @Published public private(set) var vor: VORReading?
    @Published public private(set) var ils: ILSReading?
    @Published public private(set) var inputDB = -120.0
    @Published public private(set) var identLevel = 0.0
    @Published public private(set) var ident = ""
    @Published public private(set) var identConfirmed = false
    @Published public private(set) var identHistory: [String] = []
    /// Verlauf der geeichten Peilung (Zeit, Grad), alle halbe Sekunde, höchstens 240 Werte
    @Published public private(set) var bearingHistory: [(Date, Double)] = []
    @Published public private(set) var ddmHistory: [(Date, Double)] = []
    @Published public private(set) var identEnvelope: [Double] = []
    @Published public var logEnabled: Bool { didSet { UserDefaults.standard.set(logEnabled, forKey: "navLogEnabled") } }
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var lastRecording: URL?
    public var rigDescription: String?

    private let settings: NavSettingsStore
    private var timer: Timer?
    private var lastSignal = Date()
    private var lastSample = Date.distantPast
    private var lastLog = Date.distantPast
    private var active = false

    nonisolated static let utc: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public init(pipeline: AudioPipeline, settings: NavSettingsStore) {
        self.settings = settings
        decoder = NavDecoder(pipeline: pipeline)
        recorder = InputRecorder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "navLogEnabled") as? Bool ?? true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func setActive(_ on: Bool) {
        active = on
        decoder.setEnabled(on)
        if !on { mode = .none }
    }

    public func clear() {
        decoder.reset()
        mode = .none; vor = nil; ils = nil
        ident = ""; identConfirmed = false; identHistory.removeAll()
        bearingHistory.removeAll(); ddmHistory.removeAll()
    }

    public func toggleRecording() {
        if isRecording {
            lastRecording = recorder.stop()
            isRecording = false
            return
        }
        let name = InputRecorder.fileName(frequencyHz: nil, mode: nil, preset: "vor", prefix: "VOR")
        recorder.start(url: InputRecorder.directory.appendingPathComponent(name))
        isRecording = true
        recordingDuration = 0
    }

    /// Eichung: die Station ist von hier aus auf dem bekannten Radial `known` (Grad, magnetisch) zu empfangen
    public func calibrate(knownBearing known: Double) {
        guard let raw = vor?.bearing, vor?.isValid == true else { return }
        var offset = (known - raw).truncatingRemainder(dividingBy: 360)
        if offset > 180 { offset -= 360 } else if offset < -180 { offset += 360 }
        settings.bearingOffset = offset
        bearingHistory.removeAll()
    }

    /// Geeichte Peilung zur Anzeige (0 … 360°)
    public var bearing: Double? {
        guard let raw = vor?.bearing else { return nil }
        return Self.corrected(raw, offset: settings.bearingOffset)
    }

    nonisolated static func corrected(_ raw: Double, offset: Double) -> Double {
        var b = (raw + offset).truncatingRemainder(dividingBy: 360)
        if b < 0 { b += 360 }
        return b
    }

    public var diagnosis: NavDiagnosis.Result {
        NavDiagnosis.assess(inputDB: inputDB, mode: mode, vor: vor, secondsWithoutSignal: Date().timeIntervalSince(lastSignal))
    }

    public var ilsDeflection: Double { (ils?.ddm ?? 0) / settings.ilsKind.fullScaleDDM }

    // MARK: Verarbeitung

    private func poll() {
        guard active else { return }
        let out = decoder.takeOutput()
        let now = Date()
        if abs(out.inputDB - inputDB) >= 0.5 { inputDB = out.inputDB }
        identLevel = out.identLevel
        vor = out.vor
        ils = out.ils
        let newMode: NavMode = out.vor?.isValid == true ? .vor : out.ils?.isValid == true ? .ils : .none
        if newMode != .none { lastSignal = now }
        if newMode != mode, newMode != .none || now.timeIntervalSince(lastSignal) > 3 { mode = newMode }
        if now.timeIntervalSince(lastSample) >= 0.5 {
            lastSample = now
            if mode == .vor, let b = bearing {
                bearingHistory.append((now, b))
                if bearingHistory.count > 240 { bearingHistory.removeFirst(bearingHistory.count - 240) }
            } else if mode == .ils, let i = out.ils {
                ddmHistory.append((now, i.ddm))
                if ddmHistory.count > 240 { ddmHistory.removeFirst(ddmHistory.count - 240) }
            }
            identEnvelope.append(out.identLevel)
            if identEnvelope.count > 240 { identEnvelope.removeFirst(identEnvelope.count - 240) }
        }
        for text in out.idents { ingestIdent(text, now: now) }
        if logEnabled, mode != .none, now.timeIntervalSince(lastLog) >= 30 {
            lastLog = now
            logger.append(Self.logLine(mode: mode, bearing: bearing, vor: vor, ils: ils, ident: ident, kind: settings.ilsKind, time: now), now: now)
        }
        if isRecording { recordingDuration = recorder.duration }
    }

    /// Eine gelesene Kennung aufnehmen: bestätigt, wenn sie zweimal hintereinander gleich gelesen wurde
    public func ingestIdent(_ text: String, now: Date = Date()) {
        identConfirmed = (text == ident)
        ident = text
        identHistory.append(text)
        if identHistory.count > 20 { identHistory.removeFirst(identHistory.count - 20) }
        if logEnabled { logger.append(Self.utc.string(from: now) + "  Kennung \(text)" + (identConfirmed ? " (bestätigt)" : "") + "\n", now: now) }
    }

    /// „08:15:02  VOR  Peilung 177,0° (roh 155,0°)  Hub 478 Hz  Kennung TRC“
    nonisolated public static func logLine(mode: NavMode, bearing: Double?, vor: VORReading?, ils: ILSReading?, ident: String, kind: ILSKind, time: Date) -> String {
        var s = utc.string(from: time)
        switch mode {
        case .vor:
            s += "  VOR  Peilung " + NavFormat.bearingText(bearing ?? 0)
            if let v = vor { s += String(format: " (roh %@)  Hub %.0f Hz  Kohärenz %.2f", NavFormat.bearingText(v.bearing), v.deviationHz, v.coherence) }
        case .ils:
            s += "  ILS \(kind.title)  " + String(format: "DDM %+.3f  90 Hz %.1f %%  150 Hz %.1f %%", ils?.ddm ?? 0, (ils?.level90 ?? 0) * 100, (ils?.level150 ?? 0) * 100)
        case .none:
            s += "  kein Signal"
        }
        if !ident.isEmpty { s += "  Kennung \(ident)" }
        return s + "\n"
    }
}
