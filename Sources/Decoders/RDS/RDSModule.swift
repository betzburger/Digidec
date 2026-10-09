// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Combine
import SwiftUI
import os

// MARK: - Einstellungen

/// Ein gemerkter Sender der Schnellauswahl
public struct RDSFavorite: Codable, Equatable, Identifiable, Sendable {
    public var frequencyHz: Double
    /// Programmname (PS) zur Zeit des Merkens, später vom Empfang nachgeführt; leer, solange keiner bekannt war
    public var name: String
    public var id: Int { Int((frequencyHz / 1000).rounded()) }

    public init(frequencyHz: Double, name: String) {
        self.frequencyHz = frequencyHz
        self.name = name
    }

    /// Beschriftung wie „104,4 ANTENNE“
    public var title: String {
        let f = String(format: "%.1f", frequencyHz / 1e6).replacingOccurrences(of: ".", with: ",")
        return name.isEmpty ? f : "\(f) \(name)"
    }
}

@MainActor
public final class RDSSettingsStore: ObservableObject {
    @Published public var frequencyHz: Double {
        didSet {
            UserDefaults.standard.set(frequencyHz, forKey: "rdsFrequencyHz")
        }
    }
    @Published public var selectedPreset: String {
        didSet {
            UserDefaults.standard.set(selectedPreset, forKey: "rdsPreset")
        }
    }

    /// Eigene Schnellauswahl, nach Frequenz sortiert (UserDefaults „rdsFavorites“ als JSON)
    @Published public private(set) var favorites: [RDSFavorite] {
        didSet {
            if let data = try? JSONEncoder().encode(favorites) { UserDefaults.standard.set(data, forKey: "rdsFavorites") }
        }
    }

    public init() {
        if let data = UserDefaults.standard.data(forKey: "rdsFavorites"), let list = try? JSONDecoder().decode([RDSFavorite].self, from: data) {
            favorites = list.filter { (87_500_000...108_000_000).contains($0.frequencyHz) }.sorted { $0.frequencyHz < $1.frequencyHz }
        } else {
            favorites = []
        }
        let savedFreq = UserDefaults.standard.double(forKey: "rdsFrequencyHz")
        frequencyHz = (87_500_000...108_000_000).contains(savedFreq) ? savedFreq : 98_000_000
        selectedPreset = UserDefaults.standard.string(forKey: "rdsPreset") ?? "98.0"
    }

    /// Frequenz ist gemerkt (auf 50 kHz genau, das Raster ist 100 kHz)
    public func favorite(at hz: Double) -> RDSFavorite? {
        favorites.first { abs($0.frequencyHz - hz) < 50_000 }
    }

    /// Sender merken oder, wenn schon gemerkt, den Namen auffrischen
    public func addFavorite(frequencyHz hz: Double, name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        let f = (hz / 100_000).rounded() * 100_000
        if let i = favorites.firstIndex(where: { abs($0.frequencyHz - f) < 50_000 }) {
            if !clean.isEmpty, favorites[i].name != clean { favorites[i].name = clean }
            return
        }
        favorites.append(RDSFavorite(frequencyHz: f, name: clean))
        favorites.sort { $0.frequencyHz < $1.frequencyHz }
    }

    public func removeFavorite(frequencyHz hz: Double) {
        favorites.removeAll { abs($0.frequencyHz - hz) < 50_000 }
    }

    public static let standardPresets: [(name: String, freqHz: Double)] = [
        ("87,6 MHz", 87_600_000),
        ("89,5 MHz", 89_500_000),
        ("90,9 MHz", 90_900_000),
        ("92,4 MHz", 92_400_000),
        ("94,4 MHz", 94_400_000),
        ("96,0 MHz", 96_000_000),
        ("98,0 MHz", 98_000_000),
        ("99,3 MHz", 99_300_000),
        ("100,6 MHz", 100_600_000),
        ("102,0 MHz", 102_000_000),
        ("104,0 MHz", 104_000_000),
        ("105,7 MHz", 105_700_000),
        ("107,9 MHz", 107_900_000)
    ]
}

extension RDSSettingsStore: TuningTarget {
    public var centerHz: Double { 0 }
    public var tones: (mark: Double, space: Double) { (0, 0) }
    public var markerBandwidth: Double { 200_000 }
    public func setCenter(_ hz: Double) {}
    public var markerStyle: WaterfallMarkerStyle { .band("RDS · UKW-Rundfunk WFM") }
}

// MARK: - Controller

@MainActor
public final class RDSController: ObservableObject {
    @Published public private(set) var info = RDSInfo()
    @Published public private(set) var stats = RDSStreamDecoder.Stats()
    @Published public private(set) var metrics = RDSDemodulator.Metrics()
    @Published public private(set) var signalDB: Float = -90

    public let settings: RDSSettingsStore
    public let demodulator = RDSDemodulator()
    public let decoder = RDSDecoder()

    private let activeState = OSAllocatedUnfairLock(initialState: false)
    private var timer: Timer?

    public init(settings: RDSSettingsStore) {
        self.settings = settings
        decoder.tunedMHz = settings.frequencyHz / 1e6
        // Die Gruppen werden auf dem Faden des Empfängers ausgewertet; die Oberfläche holt sich den Stand zehnmal je Sekunde
        let decoder = self.decoder
        let framer = demodulator.streamDecoder
        demodulator.streamDecoder.onGroup = { group in
            decoder.handle(group, quality: framer.currentStats.quality)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    public func setActive(_ active: Bool) {
        activeState.withLock { $0 = active }
        if !active { clear() }
    }

    nonisolated public func feedDiscriminator(samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        guard activeState.withLock({ $0 }) else { return }
        demodulator.process(mpx: samples, sampleRate: sampleRate)
    }

    public func updateSignal(db: Float) {
        signalDB = db
    }

    public func tune(frequencyHz: Double) {
        let clamped = max(87_500_000, min(108_000_000, frequencyHz))
        settings.frequencyHz = clamped
        clear()
    }

    public func step(mhz: Double) {
        tune(frequencyHz: settings.frequencyHz + mhz * 1e6)
    }

    /// Sender auf der eingestellten Frequenz in die Schnellauswahl legen (mit dem Programmnamen, wenn er schon gelesen ist) oder wieder entfernen
    public func toggleFavorite() {
        let f = settings.frequencyHz
        if settings.favorite(at: f) != nil {
            settings.removeFavorite(frequencyHz: f)
        } else {
            settings.addFavorite(frequencyHz: f, name: decoder.snapshot.programService)
        }
    }

    public func clear() {
        demodulator.reset()
        decoder.reset()
        decoder.tunedMHz = settings.frequencyHz / 1e6
        info = RDSInfo()
        stats = RDSStreamDecoder.Stats()
        metrics = RDSDemodulator.Metrics()
    }

    /// Stand von Demodulator und Decoder übernehmen (läuft im Zehntelsekundentakt; Tests rufen es von Hand)
    public func refresh() {
        let i = decoder.snapshot
        if i != info { info = i }
        // Der Name eines gemerkten Senders folgt dem Empfang (erst ganz, wenn alle acht Zeichen gesichert sind)
        if i.programServiceComplete, !i.programService.isEmpty, let fav = settings.favorite(at: settings.frequencyHz), fav.name != i.programService {
            settings.addFavorite(frequencyHz: settings.frequencyHz, name: i.programService)
        }
        stats = demodulator.streamDecoder.currentStats
        let m = demodulator.currentMetrics
        if m != metrics { metrics = m }
    }
}
