// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// USB-Stick mit einem DVSI AMBE-3000R (ein Kanal), seriell mit 460800 Baud, 8N1, ohne Flusssteuerung.
///
/// Paket: `0x61`, Länge (2 Byte, ohne Kopf und Typ), Typ (0 Steuerung, 1 Kanalbits, 2 Sprache), Felder.
/// Sprache: Feld `0x00`, Zahl der Abtastwerte, dann 16 Bit je Wert (MSB zuerst, 8 kHz).
/// Kanalbits: Feld `0x01`, Zahl der Bits, dann die Bytes.
/// Die Raten-Parameter je Verfahren (AMBE+ für D-Star, AMBE+2 für DMR/YSF/NXDN) und die Konfigurationsfolge folgen xlxd/ambed (GPL-3.0, siehe THIRD_PARTY.md).
public final class AMBE3000Stick: VoiceDecoder, @unchecked Sendable {
    public static let baud = 460800

    public let path: String
    public private(set) var productID = ""
    public private(set) var firmware = ""

    public var name: String { "\(productID) (\(path))" }
    public var isHardware: Bool { true }

    private let port: SerialPort
    private let lock = NSLock()
    private var configured: VoiceProfile?

    private static let startByte: UInt8 = 0x61
    private static let ratePlus: [UInt8] = [0x01, 0x30, 0x07, 0x63, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x48]
    private static let ratePlus2: [UInt8] = [0x04, 0x31, 0x07, 0x54, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x6F, 0x48]

    public init(path: String) throws {
        self.path = path
        port = try SerialPort(path: path, baud: Self.baud)
        // Kein Soft-Reset und kein Auffüllen mit Nullen: danach antwortete dieser Stick nicht mehr
        port.flushInput()
        let identity = try readIdentity()
        guard identity.product.hasPrefix("AMBE30") else {
            throw VoiceError.protocolError("\(path): kein AMBE-3000 (\(identity.product))")
        }
        productID = identity.product
        firmware = identity.version
    }

    public func supports(_ profile: VoiceProfile) -> Bool { true }

    /// Serielle Anschlüsse, an denen ein solcher Stick hängen könnte (Namen unter /dev).
    public static func candidatePaths() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.SLAB_USBtoUART") || $0.hasPrefix("cu.usbmodem") }
            .sorted().map { "/dev/" + $0 }
    }

    // MARK: - Pakete

    private func send(type: UInt8, payload: [UInt8]) throws {
        let length = payload.count
        try port.write([Self.startByte, UInt8(length >> 8), UInt8(length & 0xFF), type] + payload)
    }

    /// Liest das nächste Paket (Typ, Nutzdaten). Bytes vor dem Startbyte werden verworfen.
    private func receive(timeout: TimeInterval = 0.5) throws -> (type: UInt8, payload: [UInt8]) {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let first = try port.read(count: 1, timeout: max(0.01, deadline.timeIntervalSinceNow))
            guard first[0] == Self.startByte else { continue }
            let header = try port.read(count: 3, timeout: max(0.05, deadline.timeIntervalSinceNow))
            let length = Int(header[0]) << 8 | Int(header[1])
            guard length < 1024 else { throw VoiceError.protocolError("Paketlänge \(length)") }
            let body = length > 0 ? try port.read(count: length, timeout: max(0.05, deadline.timeIntervalSinceNow)) : []
            return (header[2], body)
        }
    }

    // MARK: - Aufbau

    /// Je Abfrage ein eigenes Paket: zwei Felder in einem Paket ließen diesen Stick verstummen.
    private func query(field: UInt8) throws -> [UInt8] {
        try send(type: 0x00, payload: [field])
        let packet = try receive()
        guard packet.type == 0x00, packet.payload.first == field else { throw VoiceError.protocolError("Antwort auf Feld \(field)") }
        return Array(packet.payload.dropFirst().prefix { $0 != 0x00 })
    }

    private func readIdentity() throws -> (product: String, version: String) {
        let product = String(decoding: try query(field: 0x30), as: UTF8.self)
        let version = String(decoding: try query(field: 0x31), as: UTF8.self)
        return (product, version)
    }

    /// Stellt Kanal 0 auf das Verfahren ein (nur nötig, wenn es wechselt).
    private func configure(_ profile: VoiceProfile) throws {
        guard configured != profile else { return }
        let rate = profile == .dstar ? Self.ratePlus : Self.ratePlus2
        var payload: [UInt8] = [0x40,                       // Kanal 0
                                0x05, 0x00, 0x00,           // Codierer: Fehlerschutz nach Voreinstellung
                                0x06, 0x00, 0x00,           // Decodierer: ebenso
                                0x32, 0x00,                 // keine Kompandierung (lineares PCM)
                                0x0A] + rate
        payload += [0x15, 0x00, 0x00,                       // Kanalformat
                    0x16, 0x00, 0x00,                       // Sprachformat
                    0x4B, 0x00, 0x00,                       // Verstärkung 0 dB
                    0x0B, 0x03]                             // Codierer und Decodierer starten
        try send(type: 0x00, payload: payload)
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            let packet = try receive(timeout: max(0.05, deadline.timeIntervalSinceNow))
            guard packet.type == 0x00 else { continue }
            // Antwort endet mit dem Feld „Start“ (0x0B) und dem Ergebnis 0x00
            if packet.payload.count >= 2, packet.payload[packet.payload.count - 2] == 0x0B, packet.payload.last == 0x00 {
                configured = profile
                return
            }
        }
        throw VoiceError.timeout
    }

    // MARK: - Wandlung

    public func decode(_ frame: VoiceFrame, profile: VoiceProfile) throws -> [Int16] {
        lock.lock(); defer { lock.unlock() }
        try configure(profile)
        try send(type: 0x01, payload: [0x01, UInt8(VoiceFrame.byteCount * 8)] + frame.bytes)
        while true {
            let packet = try receive()
            guard packet.type == 0x02, packet.payload.count >= 2, packet.payload[0] == 0x00 else { continue }
            let count = Int(packet.payload[1])
            guard packet.payload.count >= 2 + count * 2 else { throw VoiceError.protocolError("Sprachpaket zu kurz") }
            return (0..<count).map { Int16(bitPattern: UInt16(packet.payload[2 + $0 * 2]) << 8 | UInt16(packet.payload[3 + $0 * 2])) }
        }
    }

    /// Codiert 160 Abtastwerte zu einem Sprachrahmen (für Prüfungen und spätere Sendefunktionen).
    public func encode(_ samples: [Int16], profile: VoiceProfile) throws -> VoiceFrame {
        precondition(samples.count == VoiceFrame.samplesPerFrame)
        lock.lock(); defer { lock.unlock() }
        try configure(profile)
        var payload: [UInt8] = [0x00, UInt8(samples.count)]
        for sample in samples {
            let value = UInt16(bitPattern: sample)
            payload.append(UInt8(value >> 8)); payload.append(UInt8(value & 0xFF))
        }
        try send(type: 0x02, payload: payload)
        while true {
            let packet = try receive()
            guard packet.type == 0x01, packet.payload.count >= 2 + VoiceFrame.byteCount, packet.payload[0] == 0x01 else { continue }
            guard let frame = VoiceFrame(bytes: Array(packet.payload[2..<2 + VoiceFrame.byteCount])) else {
                throw VoiceError.protocolError("Kanalpaket")
            }
            return frame
        }
    }
}
