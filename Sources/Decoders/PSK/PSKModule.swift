// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os

// MARK: - Bänder

/// PSK31-Anruffrequenzen (Dial, USB). Die Signale liegen 0 … 3 kHz darüber; mit Mitte 1000 Hz sind die Frequenzen
/// die üblichen „14,070 + 1,0“. Frei = Funkgerät wird nicht abgestimmt.
public enum PSKBand: String, CaseIterable, Identifiable, Codable, Sendable {
    case free = "frei"
    case m160 = "160m", m80 = "80m", m40 = "40m", m30 = "30m", m20 = "20m", m17 = "17m", m15 = "15m", m12 = "12m", m10 = "10m"

    public var id: String { rawValue }

    public var dialHz: Int? {
        switch self {
        case .free: return nil
        case .m160: return 1_838_000
        case .m80:  return 3_580_000
        case .m40:  return 7_040_000
        case .m30:  return 10_142_000
        case .m20:  return 14_070_000
        case .m17:  return 18_100_000
        case .m15:  return 21_070_000
        case .m12:  return 24_920_000
        case .m10:  return 28_120_000
        }
    }
}

// MARK: - Einstellungen

/// Einstellungen des PSK-Moduls (fldigi Modem/PSK/Rx). Mitte = Trägerfrequenz im NF.
@MainActor
public final class PSKSettingsStore: ObservableObject {
    public static let centerRange: ClosedRange<Double> = 200...3500

    @Published public private(set) var centerHz: Double
    /// Wird bei jedem Setzen von Hand erhöht (nicht bei der AFC), damit der Decoder die Mitte übernimmt
    @Published public private(set) var manualCenterRevision = 0
    @Published public var options: FldigiPSKCore.Options { didSet { save() } }
    @Published public var band: PSKBand { didSet { save() } }

    public init() {
        let d = UserDefaults.standard
        let c = d.double(forKey: "pskCenterHz")
        centerHz = Self.centerRange.contains(c) ? c : 1000
        options = d.data(forKey: "pskOptions").flatMap { try? JSONDecoder().decode(FldigiPSKCore.Options.self, from: $0) }
            ?? FldigiPSKCore.Options()
        band = d.string(forKey: "pskBand").flatMap(PSKBand.init(rawValue:)) ?? .free
    }

    public func setCenter(_ hz: Double) {
        centerHz = min(max(hz, Self.centerRange.lowerBound), Self.centerRange.upperBound).rounded()
        manualCenterRevision += 1
        UserDefaults.standard.set(centerHz, forKey: "pskCenterHz")
    }

    /// Die AFC hat die Frequenz verschoben (Anzeige folgt, Decoder behält seinen Wert)
    func afcMoved(to hz: Double) {
        centerHz = hz
    }

    private func save() {
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: "pskOptions")
        }
        UserDefaults.standard.set(band.rawValue, forKey: "pskBand")
    }
}

extension PSKSettingsStore: TuningTarget {
    public var tones: (mark: Double, space: Double) { (centerHz, centerHz) }
    /// Ein PSK-Träger belegt etwa die Symbolrate (31,25 Hz bei PSK31)
    public var markerBandwidth: Double { options.mode.baud }
}

// MARK: - Decoder

/// PSK-Kern als Senke an der Pipeline (Verarbeitungs-Queue): 8 kHz, für 8PSK 16 kHz
public final class PSKDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var text: String
        public var status: FldigiPSKCore.Status?
        public var scope: [(phase: Double, amplitude: Double)]
    }

    private let pipeline: AudioPipeline
    private var core: FldigiPSKCore?
    private var enabled = false
    private var samplesSinceScope = 0
    private let lock = OSAllocatedUnfairLock()
    private var pending: [UInt8] = []
    private var lastStatus: FldigiPSKCore.Status?
    private var lastScope: [(phase: Double, amplitude: Double)] = []

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        pipeline.addSink(rate: 8_000) { [weak self] samples in self?.consume(samples, rate: 8_000) }
        pipeline.addSink(rate: 16_000) { [weak self] samples in self?.consume(samples, rate: 16_000) }
    }

    /// Betriebsart oder Optionen ändern; ein neuer Modus legt den Decoder neu an
    public func configure(options: FldigiPSKCore.Options, centerHz: Double) {
        pipeline.perform { [self] in
            if let core, core.options.mode == options.mode {
                if core.options != options { core.configure(options) }
            } else {
                core = nil           // fldigi: nur ein Exemplar gleichzeitig
                core = FldigiPSKCore(options: options, centerHz: centerHz) { [weak self] byte in
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
            return Output(text: Self.text(from: pending), status: lastStatus, scope: lastScope)
        }
    }

    /// PSK-Varicode liefert 8-Bit-Zeichen (Latin-1/Zeichensatz des Senders); CR+LF → Zeilenumbruch, Steuerzeichen außer Tab fallen weg
    static func text(from bytes: [UInt8]) -> String {
        var s = ""
        for b in bytes {
            switch b {
            case 0x0D: continue                      // CR: LF folgt meist
            case 0x0A: s.append("\n")
            case 0x09: s.append("\t")
            case 0x20...0x7E: s.append(Character(UnicodeScalar(b)))
            case 0xA0...0xFF: s.append(Character(UnicodeScalar(b)))   // Latin-1
            default: continue
            }
        }
        return s
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>, rate: Double) {
        guard enabled, let core, core.options.mode.sampleRate == rate else { return }
        core.process(samples)
        let status = core.status
        samplesSinceScope += samples.count
        var scope: [(phase: Double, amplitude: Double)]?
        if samplesSinceScope >= Int(rate / 5) {               // 5 × je Sekunde
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

/// Verbindet PSK-Einstellungen, Decoder, Anzeige und Log
@MainActor
public final class PSKController: ObservableObject, TextModeController {
    public let decoder: PSKDecoder
    public let textModel = ReceiveTextModel()
    public let logger = DecodeLogger(mode: "PSK")
    @Published public private(set) var status: FldigiPSKCore.Status?
    @Published public private(set) var scope: [(phase: Double, amplitude: Double)] = []
    @Published public private(set) var lastCharacterDate: Date?
    @Published public var logEnabled: Bool {
        didSet { UserDefaults.standard.set(logEnabled, forKey: "pskLogEnabled"); if logEnabled { markSession() } }
    }
    /// Funkgerät und Frequenz für die Log-Kopfzeile
    public var rigDescription: String? {
        didSet { if rigDescription != oldValue { markSession() } }
    }

    private let settings: PSKSettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var appliedOptions: FldigiPSKCore.Options?
    private var appliedCenterRevision = -1

    public init(pipeline: AudioPipeline, settings: PSKSettingsStore) {
        self.settings = settings
        decoder = PSKDecoder(pipeline: pipeline)
        logEnabled = UserDefaults.standard.object(forKey: "pskLogEnabled") as? Bool ?? true
        decoder.configure(options: settings.options, centerHz: settings.centerHz)
        appliedOptions = settings.options
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
        var h = "\(settings.options.mode.displayName) · Mitte \(Int(settings.centerHz.rounded())) Hz"
        h += settings.options.afc ? " · AFC" : " · AFC aus"
        if settings.options.reverse { h += " · REV" }
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
        if !out.text.isEmpty {
            textModel.append(out.text)
            if logEnabled { logger.append(out.text) }
            lastCharacterDate = Date()
        }
        if let s = out.status {
            status = s
            // AFC: Anzeige (Wasserfall-Marker) folgt der nachgeführten Frequenz
            if settings.options.afc, abs(s.centerHz - settings.centerHz) >= 0.5, appliedCenterRevision == settings.manualCenterRevision {
                settings.afcMoved(to: s.centerHz.rounded())
            }
        }
        if !out.scope.isEmpty { scope = out.scope }
    }
}
