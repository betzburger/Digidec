import Foundation

/// Ein Audiogerät mit Eingangskanälen (z. B. Codec eines Funkgeräts, „VALHost 2ch“, „BlackHole 16ch“).
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    /// CoreAudio-UID. Bei USB-Geräten enthält sie die USB-Position und ändert sich beim Umstecken.
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

/// Gewählter Eingang. Funkgeräte werden über ihre Quelle gespeichert, nicht über die UID,
/// damit die Wahl ein Umstecken an einen anderen USB-Port übersteht.
public enum InputSelection: Equatable, Sendable {
    case radio(RadioSource)
    case device(uid: String)

    public var storageValue: String {
        switch self {
        case .radio(let r):       return "radio:\(r.rawValue)"
        case .device(let uid):    return "device:\(uid)"
        }
    }

    public init?(storageValue: String) {
        if storageValue.hasPrefix("radio:"), let r = RadioSource(rawValue: String(storageValue.dropFirst(6))) {
            self = .radio(r)
        } else if storageValue.hasPrefix("device:"), storageValue.count > 7 {
            self = .device(uid: String(storageValue.dropFirst(7)))
        } else {
            return nil
        }
    }
}

/// Aufgelöster Eingang: das konkrete Gerät und, falls es der Codec eines Funkgeräts ist, welches.
public struct ResolvedInput: Equatable, Sendable {
    public let device: AudioInputDevice
    public let radio: RadioSource?

    public init(device: AudioInputDevice, radio: RadioSource?) {
        self.device = device
        self.radio = radio
    }

    public var displayName: String {
        radio.map { "\($0.displayName) · \(device.name)" } ?? device.name
    }
}

public enum AudioDeviceSelection {
    /// Gleiche Erkennung virtueller Kabel wie in den Commandern (`listAvailableOutputDevices`).
    public static func isVirtualCable(name: String) -> Bool {
        let lower = name.lowercased()
        return ["blackhole", "cable", "loopback", "virtual", "soundflower", "valhost"].contains { lower.contains($0) }
    }

    /// Löst eine Auswahl auf.
    /// - `.radio`: zuerst `uidHint` (vom Commander im Auftrag frisch ermittelt), sonst Codec am Hub des Funkgeräts.
    ///   Ist das Funkgerät nicht angeschlossen: `nil` – bewusst kein Ausweichen auf eine andere Quelle.
    /// - `.device`: genau dieses Gerät; gehört es zu einem Funkgerät, wird das mit angegeben.
    /// - `nil` (noch nie gewählt): `defaultInput`.
    public static func resolve(_ selection: InputSelection?, uidHint: String? = nil,
                               devices: [AudioInputDevice], ports: [USBSerialPortInfo]) -> ResolvedInput? {
        switch selection {
        case .radio(let radio):
            if let uid = uidHint, let d = devices.first(where: { $0.id == uid }) {
                return ResolvedInput(device: d, radio: radio)
            }
            return RadioCodecLocator.codec(of: radio, devices: devices, ports: ports)
                .map { ResolvedInput(device: $0, radio: radio) }
        case .device(let uid):
            guard let d = devices.first(where: { $0.id == uid }) else { return nil }
            return ResolvedInput(device: d, radio: RadioCodecLocator.radio(owning: d, devices: devices, ports: ports))
        case nil:
            return defaultInput(devices: devices, ports: ports)
        }
    }

    /// Ohne gespeicherte Wahl: Codec eines angeschlossenen Funkgeräts (PCR-1500 vor FT-991A),
    /// sonst VALHost 2ch, sonst erstes virtuelles Kabel, sonst erstes Gerät.
    public static func defaultInput(devices: [AudioInputDevice], ports: [USBSerialPortInfo]) -> ResolvedInput? {
        for radio in RadioSource.allCases {
            if let codec = RadioCodecLocator.codec(of: radio, devices: devices, ports: ports) {
                return ResolvedInput(device: codec, radio: radio)
            }
        }
        let fallback = devices.first { $0.name.lowercased().contains("valhost") }
            ?? devices.first(where: \.isVirtualCable)
            ?? devices.first
        return fallback.map { ResolvedInput(device: $0, radio: nil) }
    }

    /// Was beim Wählen eines Geräts im Menü gespeichert wird: Codecs von Funkgeräten als Funkgerät.
    public static func selection(for device: AudioInputDevice, devices: [AudioInputDevice],
                                 ports: [USBSerialPortInfo]) -> InputSelection {
        if let radio = RadioCodecLocator.radio(owning: device, devices: devices, ports: ports) {
            return .radio(radio)
        }
        return .device(uid: device.id)
    }
}
