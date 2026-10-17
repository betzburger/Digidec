// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Observation
import SwiftCrossUI
@testable import DigidecCore

/// Zustand des Frontend-Entwurfs: Audio-Eingang → Pipeline → Wasserfall, dazu Pegel und stärkste Frequenz.
@MainActor
@Observable
final class LiveModel {
    var devices: [AudioInputDevice]
    var selectedName: String?
    var statusText = "Kein Eingang gewählt"
    /// Geglätteter Pegel in dBFS
    var levelDB = -120.0
    /// Frequenz der stärksten Spektrallinie in Hz
    var peakHz = 0.0
    var theme: ThemePalette = ThemeModel.shared.palette

    let pipeline = AudioPipeline()
    let waterfall: WaterfallModel
    private let capture: LiveAudioCapture
    @ObservationIgnored private var timer: Timer?

    init() {
        devices = AudioDeviceCatalog.inputDevices()
        capture = LiveAudioCapture(pipeline: pipeline)
        waterfall = WaterfallModel(pipeline: pipeline)
        // Standard: erste echte Quelle, die kein Mono-Rückfall ist
        if let first = devices.first(where: { $0.inputChannels >= 2 }) ?? devices.first { select(name: first.name) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func select(name: String?) {
        selectedName = name
        guard let name, let device = devices.first(where: { $0.name == name }) else { return }
        statusText = "Starte \(device.name) …"
        capture.start(deviceUID: device.id) { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success: self?.statusText = "\(device.name) · \(Int(device.nominalSampleRate / 1000)) kHz"
                case .failure(let error): self?.statusText = error.description
                }
            }
        }
    }

    private func tick() {
        let level = pipeline.level.take()
        let db = Double(level.rmsDB)
        levelDB = db > levelDB ? db : max(db, levelDB - 1.5)   // schneller Anstieg, langsames Abklingen
        let spectrum = waterfall.spectrum
        if let peak = spectrum.indices.max(by: { spectrum[$0] < spectrum[$1] }), spectrum[peak] > waterfall.noiseFloor + 6 {
            peakHz = Double(peak) * waterfall.binWidth
        }
    }
}
