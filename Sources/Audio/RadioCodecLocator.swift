import Foundation
import IOKit
import IOKit.serial

/// Funkgeräte, deren eingebauten USB-Audio-Codec Digidec direkt liest.
public enum RadioSource: String, CaseIterable, Identifiable, Sendable {
    case pcr1500
    case ft991a

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pcr1500: return "IC-PCR1500"
        case .ft991a:  return "FT-991A"
        }
    }

    /// Wert des Parameters `source` im Auftrag (`digidec://decode?source=pcr1500`)
    public init?(requestSource: String?) {
        guard let s = requestSource?.lowercased(), let r = RadioSource(rawValue: s) else { return nil }
        self = r
    }
}

/// Serieller USB-Port laut IORegistry. Digidec öffnet diese Ports nie, es liest nur ihre Position am USB-Bus.
public struct USBSerialPortInfo: Sendable, Equatable {
    public let path: String
    public let usbSerialNumber: String?
    public let usbProductName: String?
    public let idProduct: Int?
    public let usbLocationID: UInt32?

    public init(path: String, usbSerialNumber: String?, usbProductName: String?, idProduct: Int?, usbLocationID: UInt32?) {
        self.path = path
        self.usbSerialNumber = usbSerialNumber
        self.usbProductName = usbProductName
        self.idProduct = idProduct
        self.usbLocationID = usbLocationID
    }
}

/// Findet den Audio-Codec eines Funkgeräts unabhängig vom USB-Port.
///
/// Beide Geräte haben einen eingebauten USB-Hub, an dem der Seriell-Wandler und der Burr-Brown-Codec
/// nebeneinander hängen (PCR-1500: CP2101 0x03114320 + Codec 0x03114310; FT-991A: CP2105 0x03112100 + Codec 0x03112200).
/// Der Seriell-Wandler ist eindeutig erkennbar, der Codec ist das Gerät am selben Hub.
/// Gleiche Logik wie `findPCR1500AudioCodec` / `findFT991AAudioCodec` in den Commandern.
public enum RadioCodecLocator {
    /// USB-Seriennummer, die Icom in den CP2101 des PCR-1500 schreibt (z. B. "IC-PCR1500 2301040")
    public static let pcr1500SerialPrefix = "IC-PCR1500"
    public static let cp2105ProductID = 0xEA70   // FT-991A: Silicon Labs CP2105 Dual UART
    public static let cp2101ProductID = 0xEA60   // PCR-1500: Silicon Labs CP2101

    // MARK: - Reine Logik (getestet)

    /// USB-Position des Seriell-Wandlers eines Funkgeräts.
    public static func portLocation(of radio: RadioSource, ports: [USBSerialPortInfo]) -> UInt32? {
        let candidates: [USBSerialPortInfo]
        switch radio {
        case .pcr1500:
            candidates = ports.filter { $0.usbSerialNumber?.hasPrefix(pcr1500SerialPrefix) == true }
        case .ft991a:
            candidates = ports.filter { port in
                guard port.usbSerialNumber?.hasPrefix(pcr1500SerialPrefix) != true,
                      port.idProduct != cp2101ProductID else { return false }
                return port.idProduct == cp2105ProductID || port.usbProductName?.contains("CP2105") == true
            }
        }
        return candidates
            .sorted { $0.path < $1.path }
            .lazy
            .compactMap { $0.usbLocationID ?? locationFromPortName($0.path) }
            .first
    }

    /// Codec des Funkgeräts unter den Audio-Eingängen, oder `nil`, wenn das Gerät nicht angeschlossen ist.
    public static func codec(of radio: RadioSource, devices: [AudioInputDevice], ports: [USBSerialPortInfo]) -> AudioInputDevice? {
        guard let portLoc = portLocation(of: radio, ports: ports) else { return nil }
        let hub = parentHubLocation(portLoc)
        return devices.first { device in
            guard let loc = locationFromCodecUID(device.id) else { return false }
            return loc != portLoc && parentHubLocation(loc) == hub
        }
    }

    /// Zu welchem Funkgerät gehört ein Audio-Eingang? (für die Beschriftung im Gerätemenü)
    public static func radio(owning device: AudioInputDevice, devices: [AudioInputDevice],
                             ports: [USBSerialPortInfo]) -> RadioSource? {
        RadioSource.allCases.first { codec(of: $0, devices: devices, ports: ports)?.id == device.id }
    }

    /// USB-Positionen haben je Hub-Ebene 4 Bit unter dem Bus-Byte; der übergeordnete Hub
    /// ist die Position mit gelöschter niedrigster belegter Ebene.
    public static func parentHubLocation(_ location: UInt32) -> UInt32 {
        var mask: UInt32 = 0xF
        for _ in 0..<6 {
            if location & mask != 0 { return location & ~mask }
            mask <<= 4
        }
        return location
    }

    /// "AppleUSBAudioEngine:Burr-Brown from TI:USB Audio CODEC:3114310:2" → 0x03114310; andere UIDs → nil
    public static func locationFromCodecUID(_ uid: String) -> UInt32? {
        guard uid.hasPrefix("AppleUSBAudioEngine:") else { return nil }
        let parts = uid.split(separator: ":")
        guard parts.count >= 2 else { return nil }
        return UInt32(parts[parts.count - 2], radix: 16)
    }

    /// Apples CP210x-Treiber benennt Ports nach der USB-Position, z. B. "/dev/cu.usbserial-3114320"
    public static func locationFromPortName(_ path: String) -> UInt32? {
        guard path.contains("usbserial-"), let suffix = path.split(separator: "-").last else { return nil }
        return UInt32(suffix, radix: 16)
    }

    // MARK: - IORegistry (nur lesen)

    public static func serialPorts() -> [USBSerialPortInfo] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        func search(_ service: io_object_t, _ key: String) -> Any? {
            IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
        }

        var ports: [USBSerialPortInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String else { continue }
            ports.append(USBSerialPortInfo(
                path: path,
                usbSerialNumber: search(service, "USB Serial Number") as? String,
                usbProductName: search(service, "USB Product Name") as? String,
                idProduct: (search(service, "idProduct") as? NSNumber)?.intValue,
                usbLocationID: (search(service, "locationID") as? NSNumber)?.uint32Value
            ))
        }
        return ports
    }
}
