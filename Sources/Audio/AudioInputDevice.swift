import Foundation

/// Ein Audiogerät mit Eingangskanälen (z. B. „VALHost 2ch“, „BlackHole 16ch“, USB-Codec).
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    /// CoreAudio-UID, bleibt über Neustarts gleich
    public let id: String
    public let name: String
    public let inputChannels: Int
    public let nominalSampleRate: Double
    public let isVirtualCable: Bool

    public init(id: String, name: String, inputChannels: Int, nominalSampleRate: Double, isVirtualCable: Bool) {
        self.id = id
        self.name = name
        self.inputChannels = inputChannels
        self.nominalSampleRate = nominalSampleRate
        self.isVirtualCable = isVirtualCable
    }
}

public enum AudioDeviceSelection {
    /// Standardgerät laut PLAN.md, Abschnitt 12: der eigene Loopback-Treiber VALDriver.
    public static let defaultDeviceName = "VALHost 2ch"

    /// Gleiche Erkennung virtueller Kabel wie in den Commandern (`listAvailableOutputDevices`).
    public static func isVirtualCable(name: String) -> Bool {
        let lower = name.lowercased()
        return ["blackhole", "cable", "loopback", "virtual", "soundflower", "valhost"].contains { lower.contains($0) }
    }

    /// Reihenfolge: Gerät aus dem Auftrag → zuletzt gewähltes Gerät → VALHost 2ch → erstes virtuelles Kabel → erstes Gerät.
    public static func preferred(from devices: [AudioInputDevice], requestedUID: String? = nil,
                                 savedUID: String? = nil) -> AudioInputDevice? {
        if let uid = requestedUID, let d = devices.first(where: { $0.id == uid }) { return d }
        if let uid = savedUID, let d = devices.first(where: { $0.id == uid }) { return d }
        if let d = devices.first(where: { $0.name.lowercased().contains("valhost") }) { return d }
        if let d = devices.first(where: \.isVirtualCable) { return d }
        return devices.first
    }
}
