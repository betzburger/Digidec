// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

// MARK: - SSTV Kanäle

/// Bekannte Amateurfunk- und Weltraum-SSTV-Frequenzen.
public enum SSTVChannel: String, CaseIterable, Identifiable, Codable, Sendable {
    case twenty = "20m"       // 14.230 MHz USB (Weltweiter Hauptkanal)
    case forty = "40m"        // 7.171 MHz LSB (Europa)
    case eighty = "80m"       // 3.730 MHz LSB (Europa)
    case ten = "10m"          // 28.680 MHz USB
    case iss = "iss"          // 145.800 MHz FM (ARISS Raumstation ISS)
    case two = "2m"           // 144.500 MHz FM (VHF Anrufkanal)
    case custom = "custom"    // Frei / Eigene Frequenz

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .twenty: return "20m (14,230 MHz USB)"
        case .forty:  return "40m (7,171 MHz LSB)"
        case .eighty: return "80m (3,730 MHz LSB)"
        case .ten:    return "10m (28,680 MHz USB)"
        case .iss:    return "ISS (145,800 MHz FM)"
        case .two:    return "2m (144,500 MHz FM)"
        case .custom: return "Frei / Eigene"
        }
    }

    public var shortLabel: String {
        switch self {
        case .twenty: return "20m"
        case .forty:  return "40m"
        case .eighty: return "80m"
        case .ten:    return "10m"
        case .iss:    return "ISS"
        case .two:    return "2m"
        case .custom: return "Frei"
        }
    }

    public var frequencyHz: Double? {
        switch self {
        case .twenty: return 14_230_000
        case .forty:  return 7_171_000
        case .eighty: return 3_730_000
        case .ten:    return 28_680_000
        case .iss:    return 145_800_000
        case .two:    return 144_500_000
        case .custom: return nil
        }
    }

    public var modulation: String {
        switch self {
        case .twenty, .ten: return "USB"
        case .forty, .eighty: return "LSB"
        case .iss, .two: return "FM"
        case .custom: return "SSB/FM"
        }
    }

    public var note: String {
        switch self {
        case .twenty: return "Weltweiter SSTV-Hauptanrufkanal (Martin 1 / Scottie 1)"
        case .forty:  return "Europa SSTV-Aktivität (Martin 1)"
        case .eighty: return "Abendrunde Europa (Martin 1)"
        case .ten:    return "Sporadic-E / Bandöffnungen"
        case .iss:    return "ARISS / Raumstation ISS Weltraum-Übertragungen (PD 120)"
        case .two:    return "Lokaler 2m UKW-SSTV-Anrufkanal (Robot 36 / Martin 1)"
        case .custom: return "Beliebige Empfangsfrequenz"
        }
    }
}

// MARK: - Gespeichertes Bild

public struct SSTVSavedImage: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let mode: SSTVMode
    public var fileURL: URL?
    public let cgImage: CGImage?
    public let width: Int
    public let height: Int

    public init(id: UUID = UUID(), timestamp: Date = Date(), mode: SSTVMode, fileURL: URL? = nil, cgImage: CGImage?, width: Int, height: Int) {
        self.id = id
        self.timestamp = timestamp
        self.mode = mode
        self.fileURL = fileURL
        self.cgImage = cgImage
        self.width = width
        self.height = height
    }

    public var filename: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return "sstv_\(fmt.string(from: timestamp))_\(mode.spec.shortName).png"
    }
}

// MARK: - SSTV Einstellungen

@MainActor
public final class SSTVSettingsStore: ObservableObject {
    public static let centerDefault: Double = 1750.0

    @Published public var channel: SSTVChannel { didSet { save() } }
    @Published public var manualMode: SSTVMode? { didSet { save() } }
    @Published public var autoSync: Bool { didSet { save() } }
    @Published public var autoSave: Bool { didSet { save() } }
    @Published public var slantPpm: Double { didSet { save() } }
    @Published public var centerHz: Double { didSet { save() } }

    @Published public var rigIsLSB: Bool?
    @Published public var rigDialHz: Int?

    public init() {
        let d = UserDefaults.standard
        channel = d.string(forKey: "sstvChannel").flatMap(SSTVChannel.init(rawValue:)) ?? .twenty
        if let modeRaw = d.string(forKey: "sstvManualMode"), let m = SSTVMode(rawValue: modeRaw) {
            manualMode = m
        } else {
            manualMode = nil
        }
        autoSync = d.object(forKey: "sstvAutoSync") as? Bool ?? true
        autoSave = d.object(forKey: "sstvAutoSave") as? Bool ?? true
        slantPpm = d.object(forKey: "sstvSlantPpm") as? Double ?? 0.0
        centerHz = d.object(forKey: "sstvCenterHz") as? Double ?? Self.centerDefault
    }

    public func setCenter(_ hz: Double) {
        centerHz = min(max(hz, 1200.0), 2400.0)
    }

    public func resetSlant() {
        slantPpm = 0.0
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(channel.rawValue, forKey: "sstvChannel")
        d.set(manualMode?.rawValue, forKey: "sstvManualMode")
        d.set(autoSync, forKey: "sstvAutoSync")
        d.set(autoSave, forKey: "sstvAutoSave")
        d.set(slantPpm, forKey: "sstvSlantPpm")
        d.set(centerHz, forKey: "sstvCenterHz")
    }
}

extension SSTVSettingsStore: TuningTarget {
    public var tones: (mark: Double, space: Double) {
        // Weiß (Mark = 2300 Hz), Schwarz (Space = 1500 Hz)
        (centerHz + 550.0, centerHz - 250.0)
    }
    public var markerBandwidth: Double { 1100.0 }
}

// MARK: - SSTV Decoder

/// Thread-sicherer SSTV-Decoder als 12-kHz-Audiosenke an der AudioPipeline.
public final class SSTVDecoder: @unchecked Sendable {
    public struct Output: Sendable {
        public var detectedMode: SSTVMode?
        public var currentLine: Int
        public var totalLines: Int
        public var isReceiving: Bool
        public var liveImage: CGImage?
        public var completedImages: [SSTVSavedImage]
        public var lostAtLine: Int?
    }

    private let pipeline: AudioPipeline
    private let engine = SSTVDecoderEngine()
    private var enabled: Bool = false

    private let lock = OSAllocatedUnfairLock()
    private var detectedModePending: SSTVMode?
    private var lastDecodedLine: Int = 0
    private var lastTotalLines: Int = 0
    private var isReceivingActive: Bool = false
    private var pendingLiveImage: CGImage?
    private var pendingCompleted: [SSTVSavedImage] = []
    private var lostAtLine: Int?

    public init(pipeline: AudioPipeline) {
        self.pipeline = pipeline

        engine.onModeDetected = { [weak self] mode in
            guard let self else { return }
            self.lock.withLockUnchecked {
                self.detectedModePending = mode
                self.isReceivingActive = true
            }
        }

        engine.onLineDecoded = { [weak self] line, total, cgImg in
            guard let self else { return }
            self.lock.withLockUnchecked {
                self.lastDecodedLine = line
                self.lastTotalLines = total
                self.isReceivingActive = (line < total)
                if let cgImg {
                    self.pendingLiveImage = cgImg
                }
            }
        }

        engine.onImageCompleted = { [weak self] cgImg, mode, date in
            guard let self else { return }
            let saved = SSTVSavedImage(
                timestamp: date,
                mode: mode,
                cgImage: cgImg,
                width: mode.spec.width,
                height: mode.spec.height
            )
            self.lock.withLockUnchecked {
                self.pendingCompleted.append(saved)
                self.isReceivingActive = false
            }
        }

        engine.onReceptionLost = { [weak self] line, total, cgImg in
            guard let self else { return }
            self.lock.withLockUnchecked {
                self.lastDecodedLine = line
                self.lastTotalLines = total
                self.isReceivingActive = false
                self.lostAtLine = line
                if let cgImg { self.pendingLiveImage = cgImg }
            }
        }

        pipeline.addSink(rate: SSTVFMDemodulator.sampleRate) { [weak self] samples in
            self?.consume(samples)
        }
    }

    public func setEnabled(_ on: Bool) {
        pipeline.perform { [self] in
            enabled = on
            if !on {
                engine.reset()
            }
        }
    }

    /// Decoder-Einstellungen. Nur geänderte Werte werden angewandt – insbesondere startet ein unveränderter
    /// manueller Modus den Empfang nicht neu (z. B. bei Rig-Frequenz-Updates oder Slant-Verstellung).
    public struct Config: Equatable, Sendable {
        public var slantPpm: Double
        public var manualMode: SSTVMode?
        public var autoSync: Bool
        public var centerHz: Double
    }

    private var appliedConfig: Config?

    public func configure(_ config: Config) {
        pipeline.perform { [self] in
            let previous = appliedConfig
            guard config != previous else { return }
            appliedConfig = config
            engine.slantPpm = config.slantPpm
            engine.autoSyncEnabled = config.autoSync
            engine.frequencyOffsetHz = config.centerHz - SSTVFMDemodulator.centerFreq
            if config.manualMode != previous?.manualMode {
                if let manual = config.manualMode {
                    engine.startManualMode(manual)
                } else if previous != nil {
                    engine.reset()
                }
            }
        }
    }

    public func reset() {
        pipeline.perform { [self] in
            engine.reset()
        }
    }

    public func takeOutput() -> Output {
        lock.withLockUnchecked {
            defer {
                detectedModePending = nil
                pendingLiveImage = nil
                pendingCompleted.removeAll()
                lostAtLine = nil
            }
            return Output(
                detectedMode: detectedModePending,
                currentLine: lastDecodedLine,
                totalLines: lastTotalLines,
                isReceiving: isReceivingActive,
                liveImage: pendingLiveImage,
                completedImages: pendingCompleted,
                lostAtLine: lostAtLine
            )
        }
    }

    private func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard enabled, !samples.isEmpty else { return }
        engine.process(audioSamples: Array(samples))
    }
}

// MARK: - SSTV Controller

@MainActor
public final class SSTVController: ObservableObject {
    public let decoder: SSTVDecoder
    public let settings: SSTVSettingsStore

    @Published public private(set) var liveImage: CGImage?
    @Published public private(set) var currentLine: Int = 0
    @Published public private(set) var totalLines: Int = 0
    @Published public private(set) var rxProgress: Double = 0.0
    @Published public private(set) var isReceiving: Bool = false
    @Published public private(set) var detectedMode: SSTVMode?
    @Published public private(set) var statusMessage: String = "Bereit für SSTV"
    @Published public private(set) var gallery: [SSTVSavedImage] = []
    @Published public private(set) var lastSaveError: String?

    public var sourceDescription: String?
    public var rigFrequencyHz: Int64?

    public static let maxGallery = 30
    public let directory: URL

    private var pollTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    public init(pipeline: AudioPipeline, settings: SSTVSettingsStore, directory: URL? = nil) {
        self.settings = settings
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Digidec/SSTV", isDirectory: true)

        decoder = SSTVDecoder(pipeline: pipeline)

        // Verzeichnis vorbereiten
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)

        // Einstellungen an Decoder weitergeben
        decoder.configure(Self.config(from: settings))

        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.decoder.configure(Self.config(from: self.settings))
            }
            .store(in: &cancellables)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
    }

    private static func config(from s: SSTVSettingsStore) -> SSTVDecoder.Config {
        SSTVDecoder.Config(slantPpm: s.slantPpm, manualMode: s.manualMode, autoSync: s.autoSync, centerHz: s.centerHz)
    }

    public func setActive(_ active: Bool) {
        decoder.setEnabled(active)
        if !active {
            isReceiving = false
        }
    }

    public func clearLiveImage() {
        liveImage = nil
        currentLine = 0
        totalLines = 0
        rxProgress = 0.0
        isReceiving = false
        detectedMode = nil
        decoder.reset()
        statusMessage = "Empfang zurückgesetzt"
    }

    public func saveCurrentImage() {
        guard let img = liveImage else { return }
        let mode = detectedMode ?? settings.manualMode ?? .m1
        var saved = SSTVSavedImage(
            mode: mode,
            cgImage: img,
            width: mode.spec.width,
            height: mode.spec.height
        )
        do {
            saved.fileURL = try Self.writePNG(saved, to: directory)
            gallery.insert(saved, at: 0)
            if gallery.count > Self.maxGallery {
                gallery.removeLast(gallery.count - Self.maxGallery)
            }
            statusMessage = "Bild gespeichert: \(saved.filename)"
            lastSaveError = nil
        } catch {
            lastSaveError = "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    public func removeFromGallery(_ img: SSTVSavedImage) {
        gallery.removeAll { $0.id == img.id }
        if let url = img.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func openFolderInFinder() {
        NSWorkspace.shared.open(directory)
    }

    private func poll() {
        let out = decoder.takeOutput()

        if let mode = out.detectedMode {
            detectedMode = mode
            statusMessage = "VIS erkannt: \(mode.spec.name) (\(mode.spec.width)×\(mode.spec.height))"
        }

        if out.totalLines > 0 {
            currentLine = out.currentLine
            totalLines = out.totalLines
            rxProgress = min(max(Double(currentLine) / Double(totalLines), 0.0), 1.0)
            isReceiving = out.isReceiving
            if isReceiving {
                let activeName = (detectedMode ?? settings.manualMode)?.spec.shortName ?? "SSTV"
                statusMessage = "Empfange \(activeName) · Zeile \(currentLine)/\(totalLines) (\(Int(rxProgress * 100))%)"
            }
        }

        if let live = out.liveImage {
            liveImage = live
        }

        if let line = out.lostAtLine {
            isReceiving = false
            statusMessage = "Signal verloren bei Zeile \(line)/\(out.totalLines) – Teilbild bleibt erhalten"
        }

        for var item in out.completedImages {
            if settings.autoSave {
                do {
                    item.fileURL = try Self.writePNG(item, to: directory)
                    lastSaveError = nil
                    statusMessage = "Bild empfangen & gespeichert: \(item.filename)"
                } catch {
                    lastSaveError = "Automatisches Speichern fehlgeschlagen: \(error.localizedDescription)"
                }
            } else {
                statusMessage = "Bild komplett empfangen (\(item.mode.spec.name))"
            }

            gallery.insert(item, at: 0)
            if gallery.count > Self.maxGallery {
                gallery.removeLast(gallery.count - Self.maxGallery)
            }
        }
    }

    // MARK: - PNG Export

    nonisolated public static func writePNG(_ item: SSTVSavedImage, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(item.filename)
        guard let cg = item.cgImage,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let comments = "Digidec SSTV Decoder · Modus: \(item.mode.spec.name) (\(item.width)x\(item.height))"
        let props: [CFString: Any] = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: comments]]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }
}
