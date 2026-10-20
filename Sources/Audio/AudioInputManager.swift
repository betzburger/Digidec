// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(CoreAudio)
import CoreAudio
#endif
import SwiftUI

/// Pegelanzeige in eigenem Objekt: nur das Messinstrument zeichnet mit 20 Hz neu, nicht das ganze Fenster
/// (gleiche Lehre wie in den Commandern, 0.19.4).
@MainActor
public final class LevelModel: ObservableObject {
    @Published public var level: AudioLevel = .silence
    /// Spitzenwert mit Haltezeit für die Anzeige
    @Published public var peakHoldDB: Float = AudioLevel.floorDB
    private var holdUntil = Date.distantPast

    func update(_ new: AudioLevel) {
        level = new
        let now = Date()
        if new.peakDB >= peakHoldDB || now > holdUntil {
            peakHoldDB = new.peakDB
            holdUntil = now.addingTimeInterval(1.5)
        }
    }
}

public enum AudioSourceKind: String, CaseIterable, Identifiable, Sendable {
    case audio, file, sdr
    public static let live: AudioSourceKind = .audio
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .audio: return "AUDIO"
        case .file: return "DATEI"
        case .sdr: return "SDR"
        }
    }
}

/// Audio-Eingang von Digidec: Live von einer virtuellen Soundkarte (Standard VALHost 2ch) oder aus einer Datei.
@MainActor
public final class AudioInputManager: ObservableObject {
    public let pipeline = AudioPipeline()
    public let levelModel = LevelModel()

    @Published public private(set) var devices: [AudioInputDevice] = []
    /// Gewählter Eingang: bei Aufträgen die Quelle des Commanders (nur für diese Sitzung), sonst die gespeicherte Wahl
    @Published public private(set) var selection: InputSelection?
    /// Tatsächlich benutztes Gerät; `nil`, wenn die gewählte Quelle nicht angeschlossen ist
    @Published public private(set) var activeInput: ResolvedInput?
    /// Codecs der angeschlossenen Funkgeräte, für das Gerätemenü
    @Published public private(set) var radioCodecs: [RadioSource: AudioInputDevice] = [:]
    @Published public var channelMode: ChannelMode {
        didSet {
            capture.channelMode = channelMode
            fileSource?.channelMode = channelMode
            UserDefaults.standard.set(channelMode.rawValue, forKey: Keys.channelMode)
        }
    }
    @Published public private(set) var sourceKind: AudioSourceKind = .audio
    @Published public private(set) var isRunning = false
    @Published public private(set) var statusText = "Audio-Eingang aus"
    @Published public private(set) var statusIsWarning = false
    @Published public private(set) var fileName: String?
    @Published public private(set) var fileProgress: Double = 0
    @Published public private(set) var isFilePlaying = false

    private enum Keys {
        static let selection = "audioInputSelection"
        static let channelMode = "audioInputChannelMode"
    }

    /// Eingebauter SDR-Empfänger (Quelle „SDR“); gesetzt vom Programmzustand
    public var sdr: SDRController? {
        didSet {
            sdr?.onStatus = { [weak self] running, text, warning in
                guard let self, self.sourceKind == .sdr else { return }
                self.isRunning = running
                self.setStatus(text, warning: warning)
            }
        }
    }

    private let capture: LiveAudioCapture
    private var fileSource: WAVFileSource?
    private var levelTimer: Timer?
    #if canImport(CoreAudio)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    #else
    private var deviceMonitor: Process?
    private var deviceDebounce: DispatchWorkItem?
    /// Erneuter Startversuch nach einem Abbruch des Ton-Servers (PipeWire/PulseAudio neu gestartet, Gerät weg)
    private var captureRetry: DispatchWorkItem?
    private var shuttingDown = false
    /// Neustart der Geräteüberwachung: Abstand wächst, wenn `pactl` gleich wieder endet (fehlt oder kein Ton-Server)
    private var monitorStarted = Date.distantPast
    private var monitorRestartDelay: TimeInterval = 3
    #endif
    private var ports: [USBSerialPortInfo] = []
    /// UID aus dem letzten Auftrag (vom Commander frisch ermittelt), gilt nur zusammen mit dessen Quelle
    private var uidHint: String?
    /// UID, auf der die Aufnahme gerade läuft oder startet
    private var captureUID: String?

    public init() {
        capture = LiveAudioCapture(pipeline: pipeline)
        channelMode = ChannelMode(rawValue: UserDefaults.standard.string(forKey: Keys.channelMode) ?? "") ?? .left
        capture.channelMode = channelMode

        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.levelModel.update(self.isRunning ? self.pipeline.level.take() : .silence)
            }
        }
        installDeviceListener()
        #if !canImport(CoreAudio)
        capture.onInterrupted = { [weak self] reason in
            Task { @MainActor in self?.captureInterrupted(reason) }
        }
        #endif
    }

    public var selectedDeviceUID: String? { activeInput?.device.id }

    /// Geräte, die keinem Funkgerät gehören (virtuelle Kabel, andere Soundkarten)
    public var otherDevices: [AudioInputDevice] {
        let codecIDs = Set(radioCodecs.values.map(\.id))
        return devices.filter { !codecIDs.contains($0.id) }
    }

    private var savedSelection: InputSelection? {
        UserDefaults.standard.string(forKey: Keys.selection).flatMap(InputSelection.init(storageValue:))
    }

    /// Kurzbeschreibung der Wandlung für die Statuszeile, z. B. „48 kHz → 8 kHz“
    public var rateDescription: String {
        let input = sourceKind == .file ? (fileSource?.sampleRate ?? 0) : LiveAudioCapture.captureSampleRate
        return "\(Self.kHz(input)) → \(Self.kHz(AudioPipeline.decoderSampleRate))"
    }

    // MARK: - Live-Eingang

    /// Programmstart ohne Auftrag: gespeicherte Wahl, sonst Codec eines angeschlossenen Funkgeräts.
    public func startLive() {
        leaveSDR()
        stopFile()
        fileSource = nil
        fileName = nil
        sourceKind = .audio
        selection = savedSelection
        uidHint = nil
        resolveAndStart(force: true)
    }

    /// Auftrag eines Commanders: dessen Funkgerät für diese Sitzung verwenden, die gespeicherte Wahl bleibt.
    public func apply(request: DecodeRequest) {
        if let radio = RadioSource(requestSource: request.source) {
            selection = .radio(radio)
            uidHint = request.deviceUID
        } else if let uid = request.deviceUID {
            selection = .device(uid: uid)
            uidHint = nil
        } else {
            return
        }
        leaveSDR()
        stopFile()
        fileSource = nil
        fileName = nil
        sourceKind = .audio
        resolveAndStart(force: false)
    }

    /// Wahl im Gerätemenü (wird gespeichert).
    public func select(radio: RadioSource) {
        store(.radio(radio))
    }

    public func select(device: AudioInputDevice) {
        store(AudioDeviceSelection.selection(for: device, devices: devices, ports: ports))
    }

    private func store(_ newSelection: InputSelection) {
        UserDefaults.standard.set(newSelection.storageValue, forKey: Keys.selection)
        leaveSDR()
        stopFile()
        fileSource = nil
        fileName = nil
        sourceKind = .audio
        selection = newSelection
        uidHint = nil
        resolveAndStart(force: false)
    }

    public func refreshDevices() {
        devices = AudioDeviceCatalog.inputDevices()
        ports = RadioCodecLocator.serialPorts()
        var codecs: [RadioSource: AudioInputDevice] = [:]
        for radio in RadioSource.allCases {
            codecs[radio] = RadioCodecLocator.codec(of: radio, devices: devices, ports: ports)
        }
        radioCodecs = codecs
    }

    /// Gerät zur aktuellen Wahl bestimmen und die Aufnahme (neu) starten, wenn es sich geändert hat.
    /// Wird auch bei jedem An- und Abstecken aufgerufen: So wird ein Funkgerät an einem anderen USB-Port wiedergefunden.
    private func resolveAndStart(force: Bool) {
        guard sourceKind == .audio else { return }
        refreshDevices()
        let resolved = AudioDeviceSelection.resolve(selection, uidHint: uidHint, devices: devices, ports: ports)
        // Ein Hinweis, der nicht (mehr) passt, darf die Hub-Suche nicht dauerhaft übersteuern
        if let hint = uidHint, resolved?.device.id != hint {
            uidHint = nil
        }
        activeInput = resolved

        guard let input = resolved else {
            if captureUID != nil {
                capture.stop()
                captureUID = nil
            }
            isRunning = false
            setStatus("\(missingSourceName) nicht angeschlossen – wartet", warning: true)
            return
        }
        if !force, input.device.id == captureUID, isRunning {
            return
        }

        #if canImport(AVFoundation)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            isRunning = false
            setStatus("Kein Mikrofonzugriff – Systemeinstellungen › Datenschutz › Mikrofon › Digidec erlauben", warning: true)
            return
        default:
            break
        }
        #endif

        let uid = input.device.id
        captureUID = uid
        isRunning = false
        setStatus("Starte \(input.displayName) …", warning: false)
        capture.start(deviceUID: uid) { [weak self] result in
            Task { @MainActor in
                guard let self, self.captureUID == uid, self.sourceKind == .audio else { return }
                switch result {
                case .success:
                    self.isRunning = true
                    self.setStatus("\(input.displayName) · \(self.rateDescription)", warning: false)
                case .failure(let error):
                    self.captureUID = nil
                    self.isRunning = false
                    self.setStatus(error.description, warning: true)
                    #if !canImport(CoreAudio)
                    self.scheduleCaptureRetry()
                    #endif
                }
            }
        }
    }

    private var missingSourceName: String {
        switch selection {
        case .radio(let r): return r.displayName
        case .device(let uid): return devices.first { $0.id == uid }?.name ?? "Gewähltes Audiogerät"
        case nil: return "Audiogerät"
        }
    }

    // MARK: - SDR

    /// Eingebauten SDR-Empfänger als Quelle wählen (HackRF, RTL-SDR, SDRplay): Digidec liest die I/Q-Daten selbst
    public func selectSDR() {
        guard let sdr else { return }
        captureUID = nil
        stopFile()
        fileSource = nil
        fileName = nil
        sourceKind = .sdr
        isRunning = false
        setStatus("SDR-Empfänger startet …", warning: false)
        sdr.settings.autoStart = true
        // Erst wenn die Aufnahme der Soundkarte beendet ist (sie hält am Ende die Pipeline an), den Empfänger starten
        capture.stop { [weak self] in
            Task { @MainActor in
                guard let self, self.sourceKind == .sdr else { return }
                self.sdr?.select()
            }
        }
    }

    /// Von der Quelle „SDR“ wechseln: das Gerät freigeben
    private func leaveSDR() {
        guard sourceKind == .sdr else { return }
        sdr?.deselect()
        sdr?.settings.autoStart = false
        isRunning = false
    }

    // MARK: - Datei

    public func openFile(_ url: URL) {
        leaveSDR()
        let source: WAVFileSource
        do {
            source = try WAVFileSource(url: url)
        } catch {
            setStatus("\(error)", warning: true)
            return
        }
        capture.stop()
        captureUID = nil
        fileSource?.stop()
        fileSource = source
        source.channelMode = channelMode
        sourceKind = .file
        fileName = url.lastPathComponent
        fileProgress = 0
        isRunning = false
        setStatus("\(url.lastPathComponent) · \(Self.duration(source.duration)) · \(rateDescription)", warning: false)
        playFile()
    }

    public func playFile() {
        guard let source = fileSource else { return }
        isFilePlaying = true
        isRunning = true
        source.start(into: pipeline, progress: { [weak self] p in
            Task { @MainActor in self?.fileProgress = p }
        }, finished: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isFilePlaying = false
                self.isRunning = false
                self.pipeline.stop()
            }
        })
    }

    public func stopFile() {
        guard let source = fileSource else { return }
        source.stop()
        pipeline.stop()
        isFilePlaying = false
        if sourceKind == .file {
            isRunning = false
        }
    }

    /// Zurück zum Audio-Eingang mit der zuletzt gültigen Wahl.
    public func switchToAudio() {
        leaveSDR()
        stopFile()
        fileSource = nil
        fileName = nil
        sourceKind = .audio
        resolveAndStart(force: true)
    }

    /// Abwärtskompatibler Alias für switchToAudio().
    public func switchToLive() {
        switchToAudio()
    }

    public func cleanup() {
        levelTimer?.invalidate()
        fileSource?.stop()
        #if !canImport(CoreAudio)
        shuttingDown = true
        captureRetry?.cancel()
        deviceMonitor?.terminate()
        deviceMonitor = nil
        #endif
        capture.stopSynchronously()
    }

    // MARK: - Hilfen

    private func setStatus(_ text: String, warning: Bool) {
        statusText = text
        statusIsWarning = warning
    }

    /// Geräte kommen und gehen (USB, Treiber-Neustart): Liste aktualisieren, bei Verlust melden.
    private func installDeviceListener() {
        #if canImport(CoreAudio)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.devicesChanged() }
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        #else
        // PulseAudio/PipeWire melden Änderungen der Quellen über `pactl subscribe`; mehrere Ereignisse in Folge zählen als eines.
        // Endet `pactl` (Ton-Server neu gestartet), wird es nach kurzer Pause neu gestartet und die Geräteliste neu gelesen.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["pactl", "subscribe"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // Dateiende: ohne Abmelden käme der Rückruf endlos mit leeren Daten
                handle.readabilityHandler = nil
                Task { @MainActor in self?.deviceMonitorEnded() }
                return
            }
            guard Self.isDeviceEvent(String(decoding: data, as: UTF8.self)) else { return }
            Task { @MainActor in self?.scheduleDevicesChanged() }
        }
        do { try process.run(); deviceMonitor = process; monitorStarted = Date() } catch { deviceMonitor = nil }
        #endif
    }

    #if !canImport(CoreAudio)
    /// Nur Änderungen an Quellen, Karten und dem Server zählen; „source-output“ sind Aufnahmeströme (auch Digidecs eigener)
    nonisolated static func isDeviceEvent(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            line.contains(" on source #") || line.contains(" on card #") || line.contains(" on server")
        }
    }

    private func deviceMonitorEnded() {
        deviceMonitor = nil
        guard !shuttingDown else { return }
        // Lief die Überwachung eine Weile, war es ein Neustart des Ton-Servers: bald wieder versuchen; sonst immer seltener
        monitorRestartDelay = Date().timeIntervalSince(monitorStarted) > 30 ? 3 : min(60, monitorRestartDelay * 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + monitorRestartDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shuttingDown, self.deviceMonitor == nil else { return }
                self.installDeviceListener()
                self.devicesChanged()
            }
        }
    }

    /// Der Lesefaden hat aufgehört (Ton-Server weg, Gerät entfernt): melden und neu verbinden
    private func captureInterrupted(_ reason: String) {
        guard !shuttingDown, sourceKind == .audio, captureUID != nil else { return }
        captureUID = nil
        isRunning = false
        setStatus("Audio-Eingang unterbrochen (\(reason)) – verbinde neu …", warning: true)
        scheduleCaptureRetry()
    }

    private func scheduleCaptureRetry() {
        captureRetry?.cancel()
        guard !shuttingDown else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shuttingDown, self.sourceKind == .audio, !self.isRunning, self.captureUID == nil else { return }
                self.resolveAndStart(force: true)
            }
        }
        captureRetry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    private func scheduleDevicesChanged() {
        deviceDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in Task { @MainActor in self?.devicesChanged() } }
        deviceDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
    #endif

    private func devicesChanged() {
        guard sourceKind == .audio else {
            refreshDevices()
            return
        }
        resolveAndStart(force: false)
    }

    static func kHz(_ rate: Double) -> String {
        let k = rate / 1000
        return k == k.rounded() ? String(format: "%.0f kHz", k) : String(format: "%.1f kHz", k).replacingOccurrences(of: ".", with: ",")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d min", s / 60, s % 60)
    }
}
