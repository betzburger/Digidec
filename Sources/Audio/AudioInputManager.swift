import Foundation
import AVFoundation
import CoreAudio
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
    case live, file
    public var id: String { rawValue }
    public var label: String { self == .live ? "LIVE" : "DATEI" }
}

/// Audio-Eingang von Digidec: Live von einer virtuellen Soundkarte (Standard VALHost 2ch) oder aus einer Datei.
@MainActor
public final class AudioInputManager: ObservableObject {
    public let pipeline = AudioPipeline()
    public let levelModel = LevelModel()

    @Published public private(set) var devices: [AudioInputDevice] = []
    @Published public private(set) var selectedDeviceUID: String?
    @Published public var channelMode: ChannelMode {
        didSet {
            capture.channelMode = channelMode
            fileSource?.channelMode = channelMode
            UserDefaults.standard.set(channelMode.rawValue, forKey: Keys.channelMode)
        }
    }
    @Published public private(set) var sourceKind: AudioSourceKind = .live
    @Published public private(set) var isRunning = false
    @Published public private(set) var statusText = "Audio-Eingang aus"
    @Published public private(set) var statusIsWarning = false
    @Published public private(set) var fileName: String?
    @Published public private(set) var fileProgress: Double = 0
    @Published public private(set) var isFilePlaying = false

    private enum Keys {
        static let deviceUID = "audioInputDeviceUID"
        static let channelMode = "audioInputChannelMode"
    }

    private let capture: LiveAudioCapture
    private var fileSource: WAVFileSource?
    private var levelTimer: Timer?
    private var deviceListener: AudioObjectPropertyListenerBlock?

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
    }

    public var selectedDevice: AudioInputDevice? {
        devices.first { $0.id == selectedDeviceUID }
    }

    /// Kurzbeschreibung der Wandlung für die Statuszeile, z. B. „48 kHz → 8 kHz“
    public var rateDescription: String {
        let input = sourceKind == .file ? (fileSource?.sampleRate ?? 0) : LiveAudioCapture.captureSampleRate
        return "\(Self.kHz(input)) → \(Self.kHz(AudioPipeline.decoderSampleRate))"
    }

    // MARK: - Live-Eingang

    /// Beim Programmstart und bei Aufträgen: bevorzugtes Gerät wählen und Aufnahme starten.
    public func startLive(requestedUID: String? = nil) {
        refreshDevices()
        let saved = UserDefaults.standard.string(forKey: Keys.deviceUID)
        guard let device = AudioDeviceSelection.preferred(from: devices, requestedUID: requestedUID, savedUID: saved) else {
            setStatus("Kein Audiogerät mit Eingang gefunden", warning: true)
            return
        }
        var note: String?
        if let requestedUID, requestedUID != device.id {
            note = "Gerät aus Auftrag nicht gefunden"
        }
        select(device: device, persist: requestedUID == nil, note: note)
    }

    public func select(device: AudioInputDevice) {
        select(device: device, persist: true, note: nil)
    }

    private func select(device: AudioInputDevice, persist: Bool, note: String?) {
        stopFile()
        sourceKind = .live
        selectedDeviceUID = device.id
        if persist {
            UserDefaults.standard.set(device.id, forKey: Keys.deviceUID)
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            isRunning = false
            setStatus("Kein Mikrofonzugriff – Systemeinstellungen › Datenschutz › Mikrofon › Digidec erlauben", warning: true)
            return
        default:
            break
        }

        setStatus("Starte \(device.name) …", warning: false)
        capture.start(deviceUID: device.id) { [weak self] result in
            Task { @MainActor in
                guard let self, self.selectedDeviceUID == device.id, self.sourceKind == .live else { return }
                switch result {
                case .success:
                    self.isRunning = true
                    let base = "\(device.name) · \(self.rateDescription)"
                    self.setStatus(note.map { "\($0) – \(base)" } ?? base, warning: note != nil)
                case .failure(let error):
                    self.isRunning = false
                    self.setStatus(error.description, warning: true)
                }
            }
        }
    }

    public func refreshDevices() {
        devices = AudioDeviceCatalog.inputDevices()
    }

    // MARK: - Datei

    public func openFile(_ url: URL) {
        let source: WAVFileSource
        do {
            source = try WAVFileSource(url: url)
        } catch {
            setStatus("\(error)", warning: true)
            return
        }
        capture.stop()
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

    /// Zurück zum Live-Eingang mit dem zuletzt gewählten Gerät.
    public func switchToLive() {
        stopFile()
        fileSource = nil
        fileName = nil
        startLive()
    }

    public func cleanup() {
        levelTimer?.invalidate()
        fileSource?.stop()
        capture.stopSynchronously()
    }

    // MARK: - Hilfen

    private func setStatus(_ text: String, warning: Bool) {
        statusText = text
        statusIsWarning = warning
    }

    /// Geräte kommen und gehen (USB, Treiber-Neustart): Liste aktualisieren, bei Verlust melden.
    private func installDeviceListener() {
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
    }

    private func devicesChanged() {
        refreshDevices()
        guard sourceKind == .live, let uid = selectedDeviceUID else { return }
        if !devices.contains(where: { $0.id == uid }) {
            capture.stop()
            isRunning = false
            setStatus("Audiogerät getrennt", warning: true)
        } else if !isRunning, let device = selectedDevice {
            // Gerät ist zurück (z. B. nach Neustart von coreaudiod)
            select(device: device, persist: false, note: nil)
        }
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
