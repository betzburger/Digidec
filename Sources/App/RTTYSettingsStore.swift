import Foundation
import SwiftUI

/// Aktuelle RTTY-Einstellungen: Preset, eigene Parameter, Audio-Mittenfrequenz. Wird gespeichert.
/// Ab M5 liest der Decoder hieraus seine Konfiguration.
@MainActor
public final class RTTYSettingsStore: ObservableObject {
    public static let centerRange: ClosedRange<Double> = 100...3900
    public static let defaultCenter: Double = 1000

    @Published public private(set) var presetID: String
    @Published public var customParameters: RTTYParameters {
        didSet { save() }
    }
    /// Audio-Mittenfrequenz zwischen Mark und Space in Hz
    @Published public private(set) var centerHz: Double

    private enum Keys {
        static let preset = "rttyPresetID"
        static let custom = "rttyCustomParameters"
        static let center = "rttyCenterHz"
    }

    public init() {
        let d = UserDefaults.standard
        presetID = d.string(forKey: Keys.preset).flatMap { RTTYPreset.preset(id: $0)?.id } ?? "ham"
        customParameters = d.data(forKey: Keys.custom).flatMap { try? JSONDecoder().decode(RTTYParameters.self, from: $0) }
            ?? RTTYPreset.preset(id: "custom")!.parameters
        let c = d.double(forKey: Keys.center)
        centerHz = Self.centerRange.contains(c) ? c : Self.defaultCenter
    }

    public var preset: RTTYPreset { RTTYPreset.preset(id: presetID) ?? RTTYPreset.all[0] }

    /// Wirksame Parameter: Preset-Werte, beim Preset „Eigene“ die gespeicherten eigenen Werte
    public var parameters: RTTYParameters {
        presetID == "custom" ? customParameters : preset.parameters
    }

    public var tones: (mark: Double, space: Double) { parameters.tones(center: centerHz) }

    public func select(presetID id: String) {
        guard RTTYPreset.preset(id: id) != nil else { return }
        presetID = id
        save()
    }

    public func setCenter(_ hz: Double) {
        let half = parameters.shift / 2
        let lo = max(Self.centerRange.lowerBound, half + 20)
        let hi = min(Self.centerRange.upperBound, AudioPipeline.decoderSampleRate / 2 - half - 20)
        centerHz = (min(max(hz, lo), hi)).rounded()
        save()
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(presetID, forKey: Keys.preset)
        d.set(centerHz, forKey: Keys.center)
        if let data = try? JSONEncoder().encode(customParameters) {
            d.set(data, forKey: Keys.custom)
        }
    }
}
