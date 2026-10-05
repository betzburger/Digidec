// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os

// MARK: - Einstellungen

/// Einstellungen des MT63-Moduls (fldigi Modem/MT63/Rx). Mitte = Mittenfrequenz des Signals im NF.
@MainActor
public final class MT63SettingsStore: ObservableObject {
    public static let centerRange: ClosedRange<Double> = 200...3500

    @Published public private(set) var centerHz: Double
    /// Wird bei jedem Setzen von Hand erhöht, damit der Decoder die Mitte übernimmt
    @Published public private(set) var manualCenterRevision = 0
    @Published public var options: FldigiMT63Core.Options { didSet { save() } }

    public init() {
        let d = UserDefaults.standard
        let c = d.double(forKey: "mt63CenterHz")
        centerHz = Self.centerRange.contains(c) ? c : 1500
        options = d.data(forKey: "mt63Options").flatMap { try? JSONDecoder().decode(FldigiMT63Core.Options.self, from: $0) }
            ?? FldigiMT63Core.Options()
    }

    public func setCenter(_ hz: Double) {
        centerHz = min(max(hz, Self.centerRange.lowerBound), Self.centerRange.upperBound).rounded()
        manualCenterRevision += 1
        UserDefaults.standard.set(centerHz, forKey: "mt63CenterHz")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: "mt63Options")
        }
    }
}

extension MT63SettingsStore: TuningTarget {
    public var tones: (mark: Double, space: Double) { (centerHz, centerHz) }
    public var markerBandwidth: Double { Double(options.bandwidthHz) }
}

// MARK: - Decoder

/// MT63-Kern als 8-kHz-Senke an der Pipeline (Verarbeitungs-Queue)
public final class MT63Decoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var text: String
        public var status: FldigiMT63Core.Status?
    }

    private let pipeline: AudioPipeline
    private var core: FldigiMT63Core?
    private var enabled = false
    private let lock = OSAllocatedUnfairLock()
    private var pending: [UInt8] = []
    private var lastStatus: FldigiMT63Core.Status?

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addSink { [weak self] samples in self?.consume(samples) }
    }

    public func configure(options: FldigiMT63Core.Options, centerHz: Double) {
        pipeline.perform { [self] in
            if let core {
                if core.options != options { core.configure(options) }
            } else {
                core = FldigiMT63Core(options: options, centerHz: centerHz) { [weak self] byte in
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

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled, let core else { return }
        core.process(samples)
        let status = core.status
        lock.withLockUnchecked { lastStatus = status }
    }
}

// MARK: - Controller

/// Verbindet MT63-Einstellungen, Decoder, Anzeige und Log
@MainActor
public final class MT63Controller: ObservableObject, TextModeController {
    public let decoder: MT63Decoder
    public let textModel = ReceiveTextModel()
    public let logger = DecodeLogger(mode: "MT63")
    @Published public private(set) var status: FldigiMT63Core.Status?
    @Published public private(set) var lastCharacterDate: Date?
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "mt63LogEnabled"); if logEnabled { markSession() } }
    }
    /// Funkgerät und Frequenz für die Log-Kopfzeile
    public var rigDescription: String? {
        didSet { if rigDescription != oldValue { markSession() } }
    }

    private let settings: MT63SettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var appliedOptions: FldigiMT63Core.Options?
    private var appliedCenterRevision = -1

    public init(pipeline: AudioPipeline, settings: MT63SettingsStore) {
        self.settings = settings
        decoder = MT63Decoder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "mt63LogEnabled") as? Bool ?? true
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
        var h = "MT63-\(settings.options.label) · Mitte \(Int(settings.centerHz.rounded())) Hz"
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
        if let s = out.status { status = s }
    }
}
