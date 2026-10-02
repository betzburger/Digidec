import Foundation
import Combine
import SwiftUI
import os

// MARK: - Einstellungen

/// Einstellungen des MFSK-Moduls (MFSK, DominoEX, Thor aus fldigi). Mitte = Mitte des Tonfeldes im NF.
@MainActor
public final class MFSKSettingsStore: ObservableObject {
    public static let centerRange: ClosedRange<Double> = 200...3500

    @Published public private(set) var centerHz: Double
    /// Wird bei jedem Setzen von Hand erhöht, damit der Decoder die Mitte übernimmt
    @Published public private(set) var manualCenterRevision = 0
    @Published public var options: FldigiMFSKCore.Options { didSet { save() } }

    public init() {
        let d = UserDefaults.standard
        let c = d.double(forKey: "mfskCenterHz")
        centerHz = Self.centerRange.contains(c) ? c : 1500
        options = d.data(forKey: "mfskOptions").flatMap { try? JSONDecoder().decode(FldigiMFSKCore.Options.self, from: $0) }
            ?? FldigiMFSKCore.Options()
    }

    public func setCenter(_ hz: Double) {
        centerHz = min(max(hz, Self.centerRange.lowerBound), Self.centerRange.upperBound).rounded()
        manualCenterRevision += 1
        UserDefaults.standard.set(centerHz, forKey: "mfskCenterHz")
    }

    /// Die Automatik (AFC) hat die Mitte verschoben (Anzeige folgt, kein neuer Auftrag an den Decoder)
    func autoMoved(to hz: Double) {
        centerHz = min(max(hz, Self.centerRange.lowerBound), Self.centerRange.upperBound).rounded()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: "mfskOptions")
        }
    }
}

extension MFSKSettingsStore: TuningTarget {
    public var tones: (mark: Double, space: Double) { (centerHz, centerHz) }
    public var markerBandwidth: Double { options.mode.bandwidthHz }
}

// MARK: - Decoder

/// MFSK-Kern als Senke an der Pipeline. Die Betriebsarten brauchen 8000, 11025, 12000 oder 16000 Hz: vier Senken, es arbeitet die passende.
public final class MFSKDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var text: String
        public var status: FldigiMFSKCore.Status?
    }

    private let pipeline: AudioPipeline
    private var core: FldigiMFSKCore?
    private var enabled = false
    private let lock = OSAllocatedUnfairLock()
    private var pending: [UInt8] = []
    private var lastStatus: FldigiMFSKCore.Status?
    /// Mitte, die der Decoder gerade benutzt (AFC verschiebt sie)
    private var centerNow: Double?

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addSink(rate: 8_000) { [weak self] samples in self?.consume(samples, rate: 8_000) }
        pipeline.addSink(rate: 11_025) { [weak self] samples in self?.consume(samples, rate: 11_025) }
        pipeline.addSink(rate: 12_000) { [weak self] samples in self?.consume(samples, rate: 12_000) }
        pipeline.addSink(rate: 16_000) { [weak self] samples in self?.consume(samples, rate: 16_000) }
    }

    public func configure(options: FldigiMFSKCore.Options, centerHz: Double) {
        pipeline.perform { [self] in
            if let core {
                if core.options != options { core.configure(options) }
            } else {
                core = FldigiMFSKCore(options: options, centerHz: centerHz) { [weak self] byte in
                    self?.lock.withLockUnchecked { self?.pending.append(byte) }
                }
            }
        }
    }

    public func setCenter(_ hz: Double) {
        pipeline.perform { [self] in core?.setCenter(hz) }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in enabled = on }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer { pending.removeAll() }
            return Output(text: PSKDecoder.text(from: pending), status: lastStatus)
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>, rate: Double) {
        guard enabled, let core, core.options.mode.sampleRate == rate else { return }
        core.process(samples)
        let status = core.status
        lock.withLockUnchecked { lastStatus = status }
    }
}

// MARK: - Controller

/// Verbindet MFSK-Einstellungen, Decoder, Anzeige und Log
@MainActor
public final class MFSKController: ObservableObject, TextModeController {
    public let decoder: MFSKDecoder
    public let textModel = ReceiveTextModel()
    public let logger = DecodeLogger(mode: "MFSK")
    @Published public private(set) var status: FldigiMFSKCore.Status?
    @Published public private(set) var lastCharacterDate: Date?
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "mfskLogEnabled"); if logEnabled { markSession() } }
    }
    /// Funkgerät und Frequenz für die Log-Kopfzeile
    public var rigDescription: String? {
        didSet { if rigDescription != oldValue { markSession() } }
    }

    private let settings: MFSKSettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var appliedOptions: FldigiMFSKCore.Options?
    private var appliedCenterRevision = -1

    public init(pipeline: AudioPipeline, settings: MFSKSettingsStore) {
        self.settings = settings
        decoder = MFSKDecoder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "mfskLogEnabled") as? Bool ?? true
        decoder.configure(options: settings.options, centerHz: settings.centerHz)
        appliedOptions = settings.options
        markSession()
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
    }

    public func clearText() {
        textModel.clear()
    }

    public func markSession() {
        var h = "\(settings.options.mode.displayName.uppercased()) · Mitte \(Int(settings.centerHz.rounded())) Hz\(settings.options.reverse ? " · REV" : "")"
        if let rig = rigDescription { h += " · \(rig)" }
        logger.markSession(h)
    }

    private func settingsChanged() {
        let o = settings.options
        if o != appliedOptions {
            appliedOptions = o
            decoder.configure(options: o, centerHz: settings.centerHz)
            markSession()
        }
        if settings.manualCenterRevision != appliedCenterRevision {
            appliedCenterRevision = settings.manualCenterRevision
            decoder.setCenter(settings.centerHz)
            markSession()
        }
    }

    private func poll() {
        let out = decoder.takeOutput()
        if !out.text.isEmpty {
            textModel.append(out.text)
            if logEnabled { logger.append(out.text) }
            lastCharacterDate = Date()
        }
        if let s = out.status {
            status = s
            // MFSK-AFC verschiebt die Mitte: Anzeige folgt
            if settings.options.afc, settings.options.mode.family == .mfsk, abs(s.centerHz - settings.centerHz) >= 1 {
                settings.autoMoved(to: s.centerHz)
            }
        }
    }
}
