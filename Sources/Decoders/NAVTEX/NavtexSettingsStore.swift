// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import SwiftUI

/// NAVTEX-Frequenzen (IMO): international 518 kHz (englisch), national 490 kHz, Kurzwelle 4209,5 kHz
public enum NavtexFrequency: String, CaseIterable, Identifiable, Codable, Sendable {
    case f518 = "518"
    case f490 = "490"
    case f4209 = "4209"

    public var id: String { rawValue }
    public var hz: Double {
        switch self {
        case .f518: return 518_000
        case .f490: return 490_000
        case .f4209: return 4_209_500
        }
    }
    public var label: String {
        switch self {
        case .f518: return "518 kHz"
        case .f490: return "490 kHz"
        case .f4209: return "4209,5"
        }
    }
    public var note: String {
        switch self {
        case .f518: return "international"
        case .f490: return "national"
        case .f4209: return "Kurzwelle"
        }
    }

    /// Dial in USB für eine NF-Mitte (Sender = Dial + Mitte)
    public func usbDial(center: Double) -> Double { hz - center }
}

/// Eine frei konfigurierbare NAVTEX-Empfangsfrequenz
public struct NavtexFrequencyItem: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var label: String
    public var hz: Double
    public var note: String

    public init(id: String = UUID().uuidString, label: String, hz: Double, note: String = "") {
        self.id = id
        self.label = label
        self.hz = hz
        self.note = note
    }

    public func usbDial(center: Double) -> Double { hz - center }

    public static let standardFrequencies: [NavtexFrequencyItem] = [
        NavtexFrequencyItem(id: "518", label: "518 kHz", hz: 518_000, note: "international (Englisch)"),
        NavtexFrequencyItem(id: "490", label: "490 kHz", hz: 490_000, note: "national (Landessprache)"),
        NavtexFrequencyItem(id: "4209", label: "4209,5", hz: 4_209_500, note: "Kurzwelle"),
        NavtexFrequencyItem(id: "424", label: "424 kHz", hz: 424_000, note: "Japan (national)")
    ]
}

/// Einstellungen des NAVTEX-Moduls. Mitte, Reverse (bezogen auf USB wie bei RTTY) und Seitenband-Korrektur.
@MainActor
public final class NavtexSettingsStore: ObservableObject {
    public static let centerRange: ClosedRange<Double> = 200...3800

    @Published public private(set) var centerHz: Double
    @Published public private(set) var manualCenterRevision = 0
    @Published public private(set) var frequencies: [NavtexFrequencyItem]
    @Published public var selectedFrequencyID: String { didSet { applySelectedFrequency(); save() } }
    @Published public var frequency: NavtexFrequency { didSet { save() } }
    /// Mark auf der tieferen HF (bezogen auf USB). fldigi-Standard: aus. Beim ersten Empfang zu bestätigen.
    @Published public var reverse: Bool { didSet { save() } }
    @Published public var afcOn: Bool { didSet { save() } }
    @Published public var ita2: Bool { didSet { save() } }
    @Published public var sidebandMode: SidebandMode { didSet { save() } }
    /// Eigener Maidenhead-Locator für die Stationssuche (fldigi: progdefaults.myLocator)
    @Published public var locator: String { didSet { save() } }
    /// Kehrlage laut Funkgerät (rigctld), nicht gespeichert
    @Published public var rigIsLSB: Bool?

    private enum Keys {
        static let center = "navtexCenterHz", freq = "navtexFrequency", reverse = "navtexReverse", afc = "navtexAFC"
        static let ita2 = "navtexITA2", sideband = "navtexSidebandMode", locator = "navtexLocator"
        static let customFreqs = "navtexCustomFrequencies", selectedFreqID = "navtexSelectedFreqID"
    }

    /// Einstellungen; `defaults` ist beim Mehrkanalbetrieb ein eigener Speicher je Kanal, damit ein Kanal die Einstellungen des Moduls nicht verändert
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        let c = d.double(forKey: Keys.center)
        centerHz = Self.centerRange.contains(c) ? c : 1000
        let loadedFreqs: [NavtexFrequencyItem]
        if let data = d.data(forKey: Keys.customFreqs),
           let list = try? JSONDecoder().decode([NavtexFrequencyItem].self, from: data), !list.isEmpty {
            loadedFreqs = list
        } else {
            loadedFreqs = NavtexFrequencyItem.standardFrequencies
        }
        let savedID = d.string(forKey: Keys.selectedFreqID)
        let initialID = loadedFreqs.first(where: { $0.id == savedID })?.id ?? loadedFreqs.first?.id ?? "518"
        frequencies = loadedFreqs
        selectedFrequencyID = initialID
        frequency = NavtexFrequency(rawValue: initialID) ?? .f518
        reverse = d.bool(forKey: Keys.reverse)
        afcOn = d.object(forKey: Keys.afc) as? Bool ?? true
        ita2 = d.bool(forKey: Keys.ita2)
        sidebandMode = d.string(forKey: Keys.sideband).flatMap(SidebandMode.init(rawValue:)) ?? .auto
        // Standort des Nutzers laut Commander-Projekt (Randersacker)
        locator = d.string(forKey: Keys.locator) ?? "JN49WS"
    }

    public var activeFrequencyItem: NavtexFrequencyItem {
        frequencies.first { $0.id == selectedFrequencyID } ?? frequencies[0]
    }

    public var activeFrequencyHz: Double {
        activeFrequencyItem.hz
    }

    public func selectFrequency(id: String) {
        guard frequencies.contains(where: { $0.id == id }) else { return }
        selectedFrequencyID = id
    }

    public func addFrequency(_ item: NavtexFrequencyItem) {
        frequencies.append(item)
        selectedFrequencyID = item.id
        save()
    }

    public func updateFrequency(_ item: NavtexFrequencyItem) {
        if let idx = frequencies.firstIndex(where: { $0.id == item.id }) {
            frequencies[idx] = item
            if selectedFrequencyID == item.id {
                applySelectedFrequency()
            }
            save()
        }
    }

    public func removeFrequency(id: String) {
        guard frequencies.count > 1 else { return }
        frequencies.removeAll { $0.id == id }
        if selectedFrequencyID == id {
            selectedFrequencyID = frequencies.first?.id ?? "518"
        }
        save()
    }

    public func resetFrequenciesToDefault() {
        frequencies = NavtexFrequencyItem.standardFrequencies
        if !frequencies.contains(where: { $0.id == selectedFrequencyID }) {
            selectedFrequencyID = "518"
        }
        save()
    }

    private func applySelectedFrequency() {
        if let f = NavtexFrequency(rawValue: activeFrequencyItem.id) {
            frequency = f
        }
    }

    public var effectiveLSB: Bool {
        switch sidebandMode {
        case .usb: return false
        case .lsb: return true
        case .auto: return rigIsLSB ?? false
        }
    }

    /// Umkehr für den Decoder nach Seitenband-Korrektur (fldigi: Rev xor LSB)
    public var decoderReverse: Bool { reverse != effectiveLSB }

    public var options: FldigiNavtexCore.Options {
        var o = FldigiNavtexCore.Options()
        o.reverse = decoderReverse
        o.afcOn = afcOn
        o.ita2 = ita2
        return o
    }

    public func setCenter(_ hz: Double) {
        centerHz = min(max(hz, Self.centerRange.lowerBound), Self.centerRange.upperBound).rounded()
        manualCenterRevision += 1
        save()
    }

    public func followAFC(_ hz: Double) {
        let c = min(max(hz, Self.centerRange.lowerBound), Self.centerRange.upperBound)
        guard abs(c - centerHz) >= 0.05 else { return }
        centerHz = c
        defaults.set(centerHz, forKey: Keys.center)
    }

    public func cycleSidebandMode() {
        let all = SidebandMode.allCases
        sidebandMode = all[(all.firstIndex(of: sidebandMode)! + 1) % all.count]
    }

    private func save() {
        let d = defaults
        d.set(selectedFrequencyID, forKey: Keys.selectedFreqID)
        if let data = try? JSONEncoder().encode(frequencies) {
            d.set(data, forKey: Keys.customFreqs)
        }
        d.set(centerHz, forKey: Keys.center)
        d.set(frequency.rawValue, forKey: Keys.freq)
        d.set(reverse, forKey: Keys.reverse)
        d.set(afcOn, forKey: Keys.afc)
        d.set(ita2, forKey: Keys.ita2)
        d.set(sidebandMode.rawValue, forKey: Keys.sideband)
        d.set(locator, forKey: Keys.locator)
    }
}

extension NavtexSettingsStore: TuningTarget {
    /// Mark = Mitte + 85 Hz (fldigi), bei Umkehr vertauscht
    public var tones: (mark: Double, space: Double) {
        let hi = centerHz + FldigiNavtexCore.deviation
        let lo = centerHz - FldigiNavtexCore.deviation
        return decoderReverse ? (lo, hi) : (hi, lo)
    }
    /// 2 × Hub + Baudrate
    public var markerBandwidth: Double { 2 * FldigiNavtexCore.deviation + 100 }
}
