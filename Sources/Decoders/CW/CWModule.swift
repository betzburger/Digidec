// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os

// MARK: - Einstellungen

/// Einstellungen des CW-Moduls (fldigi Modem/CW/Rx). Mitte = Tonhöhe im NF.
@MainActor
public final class CWSettingsStore: ObservableObject {
    public static let centerRange: ClosedRange<Double> = 200...3500
    public static let bandwidths = [50, 100, 150, 250, 500]

    @Published public private(set) var centerHz: Double
    @Published public private(set) var manualCenterRevision = 0
    @Published public var options: FldigiCWCore.Options { didSet { save() } }

    public init() {
        let d = UserDefaults.standard
        let c = d.double(forKey: "cwCenterHz")
        centerHz = Self.centerRange.contains(c) ? c : 700
        options = d.data(forKey: "cwOptions").flatMap { try? JSONDecoder().decode(FldigiCWCore.Options.self, from: $0) }
            ?? FldigiCWCore.Options()
    }

    /// Wirksame Filterbandbreite (beim Matched Filter 2 × WpM wie fldigi)
    public var effectiveBandwidth: Double {
        options.matchedFilter ? Double(2 * options.speedWPM) : Double(options.bandwidthHz)
    }

    public func setCenter(_ hz: Double) {
        centerHz = min(max(hz, Self.centerRange.lowerBound), Self.centerRange.upperBound).rounded()
        manualCenterRevision += 1
        UserDefaults.standard.set(centerHz, forKey: "cwCenterHz")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: "cwOptions")
        }
    }
}

extension CWSettingsStore: TuningTarget {
    public var tones: (mark: Double, space: Double) { (centerHz, centerHz) }
    public var markerBandwidth: Double { effectiveBandwidth }
}

// MARK: - Decoder

/// CW-Kern als 8-kHz-Senke an der Pipeline (Verarbeitungs-Queue)
public final class CWDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var segments: [TextSegment]   // decoded = Prosign
        public var status: FldigiCWCore.Status?
        public var scope: [Double]
    }

    private let pipeline: AudioPipeline
    private var core: FldigiCWCore?
    private var enabled = false
    private var samplesSinceScope = 0
    private let lock = OSAllocatedUnfairLock()
    private var pending: [TextSegment] = []
    private var lastStatus: FldigiCWCore.Status?
    private var lastScope: [Double] = []

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addSink { [weak self] samples in self?.consume(samples) }
    }

    public func configure(options: FldigiCWCore.Options, centerHz: Double) {
        pipeline.perform { [self] in
            if let core {
                if core.options != options { core.configure(options) }
                core.setCenter(centerHz)
            } else {
                core = FldigiCWCore(options: options, centerHz: centerHz) { [weak self] text, prosign in
                    self?.lock.withLockUnchecked {
                        guard let self else { return }
                        if let last = self.pending.last, last.decoded == prosign {
                            self.pending[self.pending.count - 1].text += text
                        } else {
                            self.pending.append(TextSegment(text, decoded: prosign))
                        }
                    }
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
            return Output(segments: pending, status: lastStatus, scope: lastScope)
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled, let core else { return }
        core.process(samples)
        let status = core.status
        samplesSinceScope += samples.count
        var scope: [Double]?
        if samplesSinceScope >= 1600 {               // 5 × je Sekunde
            samplesSinceScope = 0
            scope = core.scope()
        }
        lock.withLockUnchecked {
            lastStatus = status
            if let scope { lastScope = scope }
        }
    }
}

// MARK: - Controller

/// Verbindet CW-Einstellungen, Decoder, Anzeige und Log
@MainActor
public final class CWController: ObservableObject {
    public let decoder: CWDecoder
    public let textModel = ReceiveTextModel()
    public let logger = DecodeLogger(mode: "CW")
    @Published public private(set) var status: FldigiCWCore.Status?
    @Published public private(set) var scope: [Double] = []
    @Published public private(set) var lastCharacterDate: Date?
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "cwLogEnabled"); if logEnabled { markSession() } }
    }
    /// Funkgerät und Frequenz für die Log-Kopfzeile
    public var rigDescription: String? {
        didSet { if rigDescription != oldValue { markSession() } }
    }

    private let settings: CWSettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var appliedOptions: FldigiCWCore.Options?
    private var appliedCenterRevision = -1

    public init(pipeline: AudioPipeline, settings: CWSettingsStore) {
        self.settings = settings
        decoder = CWDecoder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "cwLogEnabled") as? Bool ?? true
        decoder.configure(options: settings.options, centerHz: settings.centerHz)
        markSession()
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
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
        var h = "CW · Ton \(Int(settings.centerHz.rounded())) Hz · Filter \(Int(settings.effectiveBandwidth)) Hz"
        h += " · Start \(settings.options.speedWPM) WpM"
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
        }
    }

    private func poll() {
        let out = decoder.takeOutput()
        for seg in out.segments {
            // Prosigns („<BT>“) in Amber
            textModel.append(seg.text, decoded: seg.decoded)
            if logEnabled { logger.append(seg.text) }
            lastCharacterDate = Date()
        }
        if let s = out.status { status = s }
        if !out.scope.isEmpty { scope = out.scope }
    }
}
