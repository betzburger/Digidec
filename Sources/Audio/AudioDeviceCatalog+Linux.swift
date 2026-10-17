// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
#if !canImport(CoreAudio)
import Foundation
import os

/// Liest die Audio-Eingänge von PulseAudio/PipeWire (`pactl`). Die „UID“ ist der Name der Quelle.
public enum AudioDeviceCatalog {
    /// USB-Position (Format wie unter macOS: Bus-Byte, dann ein Halbbyte je Hub-Ebene) je Quelle, soweit bekannt
    static let usbLocations = OSAllocatedUnfairLock<[String: UInt32]>(initialState: [:])

    public static func inputDevices() -> [AudioInputDevice] {
        guard let data = run(["--format=json", "list", "sources"]),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        var locations: [String: UInt32] = [:]
        let devices: [AudioInputDevice] = list.compactMap { source in
            guard let name = source["name"] as? String, !name.hasSuffix(".monitor") else { return nil }
            let spec = source["sample_specification"] as? String ?? ""
            let channels = firstNumber(in: spec, before: "ch") ?? 0
            guard channels > 0 else { return nil }
            let properties = source["properties"] as? [String: Any] ?? [:]
            if let sysfs = properties["sysfs.path"] as? String, let location = usbLocation(sysfsPath: sysfs) { locations[name] = location }
            let description = source["description"] as? String ?? "Audiogerät"
            return AudioInputDevice(id: name, name: description, inputChannels: channels,
                                    nominalSampleRate: Double(firstNumber(in: spec, before: "Hz") ?? 48_000),
                                    isVirtualCable: AudioDeviceSelection.isVirtualCable(name: description))
        }
        usbLocations.withLock { $0 = locations }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// „/devices/…/usb5/5-1/5-1.2/5-1.2:1.0/sound/card3“ → Bus 5, Ports 1.2 → 0x05120000
    static func usbLocation(sysfsPath: String) -> UInt32? {
        guard let component = sysfsPath.split(separator: "/").last(where: { part in
            let bits = part.split(separator: "-")
            return bits.count == 2 && bits[0].allSatisfy(\.isNumber) && bits[1].allSatisfy { $0.isNumber || $0 == "." }
        }) else { return nil }
        let bits = component.split(separator: "-")
        guard let bus = UInt32(bits[0]) else { return nil }
        return usbLocation(bus: bus, ports: bits[1].split(separator: ".").compactMap { UInt32($0) })
    }

    static func usbLocation(bus: UInt32, ports: [UInt32]) -> UInt32? {
        guard !ports.isEmpty, ports.count <= 5, ports.allSatisfy({ $0 < 16 }), bus < 256 else { return nil }
        var location = bus << 24
        for (index, port) in ports.enumerated() { location |= port << UInt32(20 - 4 * index) }
        return location
    }

    private static func firstNumber(in text: String, before unit: String) -> Int? {
        guard let range = text.range(of: unit) else { return nil }
        let digits = text[..<range.lowerBound].reversed().prefix { $0.isNumber }
        return Int(String(digits.reversed()))
    }

    private static func run(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["pactl"] + arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
#endif
