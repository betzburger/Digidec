// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// M17 Paketmodus: nach dem LSF (Typ „Paket“) folgen Rahmen mit dem Synchronwort 0x75FF. Jeder trägt 25 Byte, ein Ende-Bit und einen
// 5-Bit-Zähler (Nummer des Rahmens, im letzten Rahmen die Zahl der gültigen Byte). Faltungscode K=5 über 206 Bit, Punktierung P3 (7 von 8).
// Das Paket beginnt mit dem Protokollbyte (0x05 = SMS, UTF-8 mit Endnull) und endet mit der CRC-16 (Polynom 0x5935, höchstes Byte zuerst).

public struct M17PacketFrame: Equatable, Sendable {
    /// 25 Byte Nutzdaten (im letzten Rahmen sind nur die ersten `counter` Byte gültig)
    public var data: [UInt8]
    public var isLast: Bool
    /// Rahmen: laufende Nummer 0 … 31; letzter Rahmen: Zahl der gültigen Byte 1 … 25
    public var counter: Int
    public var errorRate: Float

    public init(data: [UInt8], isLast: Bool, counter: Int, errorRate: Float = 0) {
        self.data = data
        self.isLast = isLast
        self.counter = counter
        self.errorRate = errorRate
    }
}

/// Ein vollständig empfangenes Paket
public struct M17Packet: Equatable, Sendable {
    /// Protokollbyte plus Nutzdaten, ohne die CRC
    public var data: [UInt8]
    public var crcOK: Bool
    /// Zahl der Rahmen
    public var frames: Int

    public init(data: [UInt8], crcOK: Bool, frames: Int) {
        self.data = data
        self.crcOK = crcOK
        self.frames = frames
    }

    public var protocolID: Int { data.first.map(Int.init) ?? 0 }
    public var payload: [UInt8] { Array(data.dropFirst()) }

    public var protocolName: String {
        switch protocolID {
        case 0: return "RAW"
        case 1: return "AX.25"
        case 2: return "APRS"
        case 3: return "6LoWPAN"
        case 4: return "IPv4"
        case 5: return "SMS"
        case 6: return "Winlink"
        default: return String(format: "Protokoll 0x%02X", protocolID)
        }
    }

    /// Text, wenn die Nutzdaten welcher sind (SMS und APRS immer; RAW nur bei lesbarem UTF-8): ohne Endnull und Steuerzeichen
    public var text: String? {
        guard [0, 2, 5].contains(protocolID), !payload.isEmpty else { return nil }
        var bytes = payload
        if let zero = bytes.firstIndex(of: 0) { bytes = Array(bytes[..<zero]) }
        guard !bytes.isEmpty, let s = String(bytes: bytes, encoding: .utf8) else { return nil }
        let printable = s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F || $0 == "\n" || $0 == "\r" || $0 == "\t" }
        guard printable else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ein Satz für Liste und Protokoll: „SMS „Hallo““, „IPv4 84 Byte“; fehlerhafte CRC wird vermerkt
    public var summary: String {
        var s = protocolName
        if let text { s += " „\(text)“" } else { s += " \(payload.count) Byte" }
        if !crcOK { s += " (CRC falsch)" }
        return s
    }

    /// Pakete ab Rohbytes (Protokoll, Nutzdaten, CRC): `nil`, wenn zu kurz
    public static func parse(_ bytes: [UInt8], frames: Int) -> M17Packet? {
        guard bytes.count >= 3 else { return nil }
        let body = Array(bytes.dropLast(2))
        let crc = (UInt16(bytes[bytes.count - 2]) << 8) | UInt16(bytes[bytes.count - 1])
        return M17Packet(data: body, crcOK: M17.crc16(body) == crc, frames: frames)
    }

    /// Rohbytes zum Senden (Prüfstände): Daten plus CRC
    public var wireBytes: [UInt8] {
        let crc = M17.crc16(data)
        return data + [UInt8(crc >> 8), UInt8(crc & 0xFF)]
    }
}

extension M17 {
    /// P3 (Paket): 8 Einträge, nur der letzte fehlt (420 → 368 Bit)
    static let puncture3: [Bool] = (0..<8).map { $0 != 7 }

    public static let packetBytesPerFrame = 25

    /// Paket-Rahmen aus den 368 Bit hinter dem Synchronwort (184 Symbole)
    public static func decodePacketFrame(_ symbols: ArraySlice<Float>) -> M17PacketFrame? {
        let soft = deliver(symbols)
        guard soft.count == payloadBits else { return nil }
        let decoded = viterbi(soft[0..<368], pattern: puncture3, coded: 420)
        guard decoded.bits.count == 206 else { return nil }
        let last = decoded.bits[200] == 1
        let counter = value(ofBits: decoded.bits[201..<206])
        if last && !(1...packetBytesPerFrame).contains(counter) { return nil }
        return M17PacketFrame(data: bytes(ofBits: decoded.bits[0..<200]), isLast: last, counter: counter, errorRate: decoded.errorRate)
    }

    /// Symbole eines Paket-Rahmens mit Synchronwort (Prüfstände)
    public static func packetFrameSymbols(_ frame: M17PacketFrame) -> [Float] {
        precondition(frame.data.count == packetBytesPerFrame && (0...31).contains(frame.counter))
        var bits = self.bits(ofBytes: frame.data)
        bits.append(frame.isLast ? 1 : 0)
        bits += (0..<5).map { UInt8((frame.counter >> (4 - $0)) & 1) }
        let coded = ConvK5.encode(bits + [0, 0, 0, 0])
        return SyncKind.packet.levels + symbols(ofPayloadBits: puncture(coded, pattern: puncture3))
    }

    /// Rahmen eines Pakets (Daten plus CRC in 25-Byte-Stücken; Rest mit Nullen aufgefüllt)
    public static func packetFrames(of packet: M17Packet) -> [M17PacketFrame] {
        let wire = packet.wireBytes
        var frames: [M17PacketFrame] = []
        var i = 0
        while i < wire.count {
            let rest = wire.count - i
            let chunk = Array(wire[i..<min(i + packetBytesPerFrame, wire.count)])
            let padded = chunk + [UInt8](repeating: 0, count: packetBytesPerFrame - chunk.count)
            // Passt der Rest genau in 25 Byte, ist dieser Rahmen der letzte mit 25 gültigen Byte
            if rest <= packetBytesPerFrame { frames.append(M17PacketFrame(data: padded, isLast: true, counter: rest)) }
            else { frames.append(M17PacketFrame(data: padded, isLast: false, counter: frames.count)) }
            i += packetBytesPerFrame
        }
        return frames
    }
}

/// Setzt Paket-Rahmen zum Paket zusammen
struct M17PacketAssembler {
    private var bytes: [UInt8] = []
    private var expected = 0
    private var broken = false
    private(set) var frameCount = 0

    mutating func reset() { self = M17PacketAssembler() }

    /// Nimmt einen Rahmen auf; liefert das fertige Paket (oder `nil`, wenn es noch weitergeht oder Rahmen fehlen)
    mutating func add(_ f: M17PacketFrame) -> (packet: M17Packet?, finished: Bool) {
        frameCount += 1
        if f.isLast {
            defer { reset() }
            guard !broken, frameCount > 0, expected == frameCount - 1 else { return (nil, true) }
            bytes += f.data.prefix(f.counter)
            return (M17Packet.parse(bytes, frames: frameCount), true)
        }
        if f.counter != expected { broken = true }
        expected = f.counter + 1
        if !broken { bytes += f.data }
        if frameCount > 40 { reset() }
        return (nil, false)
    }
}
