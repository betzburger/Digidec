// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import SwiftUI

/// Aktuelle RTTY-Einstellungen: Preset, eigene Parameter, Reverse je Preset, Empfangsoptionen, Mittenfrequenz.
/// Alles wird gespeichert. Der `RTTYController` gibt Änderungen an den Decoder weiter.
@MainActor
public final class RTTYSettingsStore: ObservableObject {
    public static let centerRange: ClosedRange<Double> = 100...3900
    public static let defaultCenter: Double = 1000

    @Published public private(set) var presetID: String
    @Published public private(set) var customParameters: RTTYParameters
    /// Reverse-Schalter je Preset (Umschalten per REV-Knopf, ohne das Preset zu verlassen)
    @Published public private(set) var reverseByPreset: [String: Bool]
    @Published public var options: RTTYDecodeOptions {
        didSet { save() }
    }
    /// Audio-Mittenfrequenz zwischen Mark und Space in Hz (von Hand oder durch die AFC)
    @Published public private(set) var centerHz: Double
    /// Erhöht sich bei jeder Mittenwahl von Hand oder per Auftrag – nicht bei AFC-Nachführung
    @Published public private(set) var manualCenterRevision = 0
    /// Gewählte DWD-Sendefrequenz je Preset ("dwd-kw", "dwd-lw") in Hz; ohne Eintrag gilt die Automatik (Tageszeit)
    @Published public private(set) var dwdFrequencyHz: [String: Double]
    /// Seitenband: automatisch aus rigctld oder von Hand
    @Published public var sidebandMode: SidebandMode {
        didSet { save() }
    }
    /// Kehrlage laut Funkgerät (rigctld), `nil` = unbekannt. Wird nicht gespeichert.
    @Published public var rigIsLSB: Bool?

    private enum Keys {
        static let preset = "rttyPresetID"
        static let custom = "rttyCustomParameters"
        static let center = "rttyCenterHz"
        // „2“: ab 0.7.0 ist Reverse auf USB bezogen (DWD-Presets tragen reverse = true); alte Schalterstände verworfen
        static let reverse = "rttyReverseByPreset2"
        static let options = "rttyDecodeOptions"
        static let sideband = "rttySidebandMode"
        static let dwdFrequency = "rttyDwdFrequencyHz"
    }

    /// Einstellungen; `defaults` ist beim Mehrkanalbetrieb ein eigener Speicher je Kanal, damit ein Kanal die Einstellungen des Moduls nicht verändert
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        presetID = d.string(forKey: Keys.preset).flatMap { RTTYPreset.preset(id: $0)?.id } ?? "ham"
        customParameters = d.data(forKey: Keys.custom).flatMap { try? JSONDecoder().decode(RTTYParameters.self, from: $0) }
            ?? RTTYPreset.preset(id: "custom")!.parameters
        reverseByPreset = (d.dictionary(forKey: Keys.reverse) as? [String: Bool]) ?? [:]
        options = d.data(forKey: Keys.options).flatMap { try? JSONDecoder().decode(RTTYDecodeOptions.self, from: $0) }
            ?? RTTYDecodeOptions()
        let c = d.double(forKey: Keys.center)
        // Werte über 2.200 Hz oder unter 300 Hz stammen von extremem AFC-Drift / Klickfehler
        // und würden das Signal an den Rand von 2,4/2,7-kHz-SSB-Filtern drücken → Standard 1.000 Hz
        centerHz = (Self.centerRange.contains(c) && (300...2200).contains(c)) ? c : Self.defaultCenter
        sidebandMode = d.string(forKey: Keys.sideband).flatMap(SidebandMode.init(rawValue:)) ?? .auto
        dwdFrequencyHz = (d.dictionary(forKey: Keys.dwdFrequency) as? [String: Double]) ?? [:]
        d.removeObject(forKey: "rttyReverseByPreset")
    }

    public var preset: RTTYPreset { RTTYPreset.preset(id: presetID) ?? RTTYPreset.all[0] }

    /// Parameter des Presets ohne Reverse-Schalter (beim Preset „Eigene“ die eigenen Werte)
    public var baseParameters: RTTYParameters {
        presetID == "custom" ? customParameters : preset.parameters
    }

    /// Wirksame Parameter inklusive Reverse-Schalter
    public var parameters: RTTYParameters {
        var p = baseParameters
        if presetID != "custom", let r = reverseByPreset[presetID] {
            p.reverse = r
        }
        return p
    }

    public var isReversed: Bool { parameters.reverse }

    /// Wirksames Seitenband: von Hand gewählt oder vom Funkgerät; unbekannt gilt als USB
    public var effectiveLSB: Bool {
        switch sidebandMode {
        case .usb: return false
        case .lsb: return true
        case .auto: return rigIsLSB ?? false
        }
    }

    /// Parameter für den Decoder und die Marker: Reverse nach Seitenband-Korrektur (fldigi: Rev xor LSB)
    public var decoderParameters: RTTYParameters {
        var p = parameters
        p.reverse = p.reverse != effectiveLSB
        return p
    }

    /// Mark/Space im NF, wie sie tatsächlich ankommen (nach Seitenband-Korrektur)
    public var tones: (mark: Double, space: Double) { decoderParameters.tones(center: centerHz) }

    public func cycleSidebandMode() {
        let all = SidebandMode.allCases
        sidebandMode = all[(all.firstIndex(of: sidebandMode)! + 1) % all.count]
    }

    public func select(presetID id: String) {
        guard RTTYPreset.preset(id: id) != nil else { return }
        presetID = id
        if !Self.centerRange.contains(centerHz) || centerHz > 1800 {
            centerHz = Self.defaultCenter
        }
        save()
    }

    /// Setzt die Audio-Mittenfrequenz auf den optimalen Standardwert (1.000 Hz) zurück
    public func resetCenter() {
        centerHz = Self.defaultCenter
        manualCenterRevision += 1
        save()
    }

    /// DWD-Sendefrequenz für ein Preset wählen (nil = Automatik nach Tageszeit). Das Preset wird dabei nicht gewechselt.
    public func selectDWDFrequency(_ hz: Double?, presetID id: String) {
        guard id == "dwd-kw" || id == "dwd-lw" else { return }
        dwdFrequencyHz[id] = hz
        defaults.set(dwdFrequencyHz, forKey: Keys.dwdFrequency)
    }

    /// Gewählte DWD-Frequenz des aktuellen Presets (nil = Automatik oder kein DWD-Preset)
    public var selectedDWDFrequencyHz: Double? { dwdFrequencyHz[presetID] }

    public func toggleReverse() {
        if presetID == "custom" {
            customParameters.reverse.toggle()
        } else {
            reverseByPreset[presetID] = !isReversed
        }
        save()
    }

    /// Übertragungsparameter ändern (Einstellungsdialog). Bei einem festen Preset wird dessen Kopie
    /// als „Eigene“ gespeichert und ausgewählt – die festen Presets bleiben unverändert.
    public func update(parameters p: RTTYParameters) {
        guard p != parameters else { return }
        customParameters = p
        presetID = "custom"
        setCenter(centerHz)
        save()
    }

    /// Eigene Parameter auf die Werte eines festen Presets setzen
    public func copyToCustom(from id: String) {
        guard let preset = RTTYPreset.preset(id: id) else { return }
        customParameters = preset.parameters
        save()
    }

    /// Mitte von Hand (Klick im Wasserfall) oder per Auftrag: begrenzt und auf ganze Hz gerundet.
    public func setCenter(_ hz: Double) {
        centerHz = clampCenter(hz).rounded()
        manualCenterRevision += 1
        save()
    }

    /// Mitte aus der AFC des Decoders: nicht gerundet, kein Rücksetzen des Decoders.
    /// Live-AFC-Drift wird nicht in UserDefaults gespeichert, um die VFO-Abstimmfrequenz stabil zu halten.
    public func followAFC(_ hz: Double) {
        let c = clampCenter(hz)
        guard abs(c - centerHz) >= 0.05 else { return }
        centerHz = c
    }

    private func clampCenter(_ hz: Double) -> Double {
        let half = parameters.shift / 2
        let lo = max(Self.centerRange.lowerBound, half + 20)
        let hi = min(Self.centerRange.upperBound, AudioPipeline.decoderSampleRate / 2 - half - 20)
        return min(max(hz, lo), hi)
    }

    private func save() {
        let d = defaults
        d.set(presetID, forKey: Keys.preset)
        d.set(centerHz, forKey: Keys.center)
        d.set(reverseByPreset, forKey: Keys.reverse)
        if let data = try? JSONEncoder().encode(customParameters) {
            d.set(data, forKey: Keys.custom)
        }
        if let data = try? JSONEncoder().encode(options) {
            d.set(data, forKey: Keys.options)
        }
        d.set(sidebandMode.rawValue, forKey: Keys.sideband)
    }
}
