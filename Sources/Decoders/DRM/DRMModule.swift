// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os

// DRM30 (Digital Radio Mondiale auf Lang-, Mittel- und Kurzwelle): Modul. Der Empfänger liest Audio mit 48 kHz (USB-Audio mit etwa 12 kHz Breite, das Signal
// irgendwo zwischen 1 und 22 kHz), liefert Kanalparameter (FAC), Dienste (SDC), Audio und Radiotext; der Ton wird mit FAAD2 (DRM-Modus) decodiert.

// MARK: - Einstellungen

@MainActor
public final class DRMSettingsStore: ObservableObject {
    /// Sendefrequenz (Mitte des Kanals) in kHz
    @Published public var frequencyKHz: Double { didSet { UserDefaults.standard.set(frequencyKHz, forKey: "drmFrequencyKHz") } }
    /// Kurzkennung (0 … 3) des Dienstes, dessen Ton ausgegeben wird
    @Published public var service: Int { didSet { UserDefaults.standard.set(service, forKey: "drmService") } }
    @Published public var volume: Double { didSet { UserDefaults.standard.set(volume, forKey: "drmVolume") } }
    @Published public var muted: Bool { didSet { UserDefaults.standard.set(muted, forKey: "drmMuted") } }

    /// NF-Lage, bei der der Empfänger die Kanalmitte erwartet (USB-Dial = Sendefrequenz − 6 kHz): das Signal belegt dann 1 … 11 kHz
    public static let audioCenterHz = 6000.0

    public init() {
        let d = UserDefaults.standard
        let f = d.double(forKey: "drmFrequencyKHz")
        frequencyKHz = f >= 100 && f <= 30_000 ? f : 9_610
        let s = d.integer(forKey: "drmService")
        service = (0...3).contains(s) ? s : 0
        volume = d.object(forKey: "drmVolume") as? Double ?? 0.7
        muted = d.bool(forKey: "drmMuted")
    }
}

extension DRMSettingsStore: TuningTarget {
    public var centerHz: Double { DRMSettingsStore.audioCenterHz }
    public var tones: (mark: Double, space: Double) { (0, 0) }
    public var markerBandwidth: Double { 10_000 }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .band("DRM · OFDM 4,5 bis 20 kHz breit, Mitte bei \(Int(DRMSettingsStore.audioCenterHz / 1000)) kHz") }
}

// MARK: - Empfänger an der Pipeline

public final class DRMDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var status: DRMStatus
        public var inputDB: Double
        public var audioPeak: Double
        public var text: String
        public var audioDescription: String
        public var unsupportedReason: String
    }

    public static let sampleRate = 48_000.0

    private let pipeline: AudioPipeline
    private let receiver = DRMReceiver()
    private let player = DABPlayer()
    private var enabled = false
    private var meanSquare = 0.0
    private let lock = OSAllocatedUnfairLock()
    private var snapshot = DRMDecoder.Output(status: DRMStatus(), inputDB: -120, audioPeak: 0, text: "", audioDescription: "", unsupportedReason: "")
    private var aac: DRMAudioDecoder?
    private var xhe: DRMXHEDecoder?
    private var aacParam: DRMAudioParam?
    /// Gezählte Audiorahmen (der Empfänger kennt sie nicht; Statusmeldungen würden sie sonst zurücksetzen)
    private var audioGood = 0, audioBad = 0

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline
        receiver.onEvent = { [weak self] event in self?.handle(event) }
        pipeline.addSink(rate: Self.sampleRate) { [weak self] samples in self?.consume(samples) }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            if on != enabled { receiver.reset(); aac = nil; xhe = nil; aacParam = nil; audioGood = 0; audioBad = 0 }
            enabled = on
            if !on { player.stop(); lock.withLockUnchecked { snapshot.status = DRMStatus(); snapshot.text = ""; snapshot.audioDescription = ""; snapshot.unsupportedReason = "" } }
        }
    }

    public func setService(_ shortID: Int) { pipeline.perform { [self] in receiver.selectedService = shortID; aac = nil; xhe = nil; aacParam = nil } }

    public func setVolume(_ v: Double, muted: Bool) {
        player.volume = Float(v)
        player.muted = muted
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            var o = snapshot
            o.audioPeak = Double(player.takePeak())
            return o
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled else { return }
        var sum = 0.0
        for x in samples { sum += Double(x) * Double(x) }
        receiver.process(Array(samples))
        let block = samples.isEmpty ? 0 : sum / Double(samples.count)
        meanSquare += min(1.0, Double(samples.count) / (0.3 * Self.sampleRate)) * (block - meanSquare)
        let db = meanSquare > 1e-12 ? max(-120, 10 * log10(meanSquare)) : -120
        lock.withLockUnchecked { snapshot.inputDB = db }
    }

    private func handle(_ event: DRMEvent) {
        switch event {
        case .status(let s):
            lock.withLockUnchecked {
                snapshot.status = s
                snapshot.status.audioFramesGood = audioGood
                snapshot.status.audioFramesBad = audioBad
            }
        case .text(let t):
            lock.withLockUnchecked { snapshot.text = t }
        case .audio(let unit):
            if aacParam != unit.param {
                aac = nil; xhe = nil
                switch unit.param.coding {
                case .aac: aac = DRMAudioDecoder(param: unit.param)
                case .xheaac: xhe = DRMXHEDecoder(param: unit.param)
                default: break
                }
                aacParam = unit.param
            }
            if unit.param.coding == .xheaac { handleXHE(unit); return }
            guard let decoder = aac else {
                lock.withLockUnchecked { snapshot.unsupportedReason = "Audio-Codierung \(unit.param.coding.title) wird nicht unterstützt" }
                return
            }
            var pcm: [Float] = []
            var bad = 0
            for frame in unit.frames {
                if let p = decoder.decode(frame) { pcm += p } else {
                    bad += 1
                    pcm += [Float](repeating: 0, count: (unit.param.outputRate * 80 / 1000) * decoder.channels)
                }
            }
            lock.withLockUnchecked {
                audioGood += unit.frames.count - bad
                audioBad += bad
                snapshot.status.audioFramesGood = audioGood
                snapshot.status.audioFramesBad = audioBad
                snapshot.unsupportedReason = ""
                snapshot.audioDescription = describe(unit.param)
            }
            player.write(pcm, channels: decoder.channels, rate: decoder.outputRate)
        }
    }

    private func describe(_ p: DRMAudioParam) -> String {
        let rate = p.outputRate % 1000 == 0 ? "\(p.outputRate / 1000)" : String(format: "%.1f", Double(p.outputRate) / 1000)
        return "\(p.coding.title)\(p.sbr ? " + SBR" : "") · \(p.modeTitle) · \(rate) kHz"
    }

    private func handleXHE(_ unit: DRMAudioUnit) {
        guard let decoder = xhe else {
            lock.withLockUnchecked { snapshot.unsupportedReason = "xHE-AAC: Konfiguration nicht lesbar oder vom Systemdecoder nicht angenommen" }
            return
        }
        var pcm: [Float] = []
        var good = 0, bad = 0
        for au in unit.frames {
            if au.isEmpty { bad += 1; decoder.loss() }
            let out = decoder.decode(au)
            if !au.isEmpty { good += 1 }
            pcm += out
        }
        lock.withLockUnchecked {
            audioGood += good
            audioBad += bad
            snapshot.status.audioFramesGood = audioGood
            snapshot.status.audioFramesBad = audioBad
            snapshot.unsupportedReason = ""
            snapshot.audioDescription = describe(unit.param)
        }
        player.write(pcm, channels: decoder.channels, rate: decoder.outputRate)
    }
}

// MARK: - Controller

@MainActor
public final class DRMController: ObservableObject {
    public let decoder: DRMDecoder
    @Published public private(set) var status = DRMStatus()
    @Published public private(set) var inputDB = -120.0
    @Published public private(set) var audioPeak = 0.0
    @Published public private(set) var text = ""
    @Published public private(set) var audioDescription = ""
    @Published public private(set) var unsupportedReason = ""
    public var rigDescription: String?

    private let settings: DRMSettingsStore
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    public init(pipeline: AudioPipeline, settings: DRMSettingsStore) {
        self.settings = settings
        decoder = DRMDecoder(pipeline: pipeline)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        settings.$service.sink { [weak self] s in self?.decoder.setService(s) }.store(in: &cancellables)
        Publishers.CombineLatest(settings.$volume, settings.$muted).sink { [weak self] v, m in self?.decoder.setVolume(v, muted: m) }.store(in: &cancellables)
    }

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
        if active { decoder.setService(settings.service); decoder.setVolume(settings.volume, muted: settings.muted) }
    }

    private func poll() {
        let o = decoder.takeOutput()
        if o.status != status { status = o.status }
        if abs(o.inputDB - inputDB) >= 0.5 { inputDB = o.inputDB }
        audioPeak = max(o.audioPeak, audioPeak * 0.75)   // Spitzenwert kurz halten: der Ton kommt alle 0,4 s, die Abfrage alle 0,2 s
        if o.text != text { text = o.text }
        if o.audioDescription != audioDescription { audioDescription = o.audioDescription }
        if o.unsupportedReason != unsupportedReason { unsupportedReason = o.unsupportedReason }
    }

    /// Dienst, dessen Ton läuft (nach der Wahl in den Einstellungen, sonst der erste Audiodienst)
    public var currentService: DRMService? {
        status.services.first(where: { $0.shortID == settings.service }) ?? status.services.first(where: { $0.isAudio })
    }
}
