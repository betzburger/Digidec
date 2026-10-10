// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Minimale, robuste WebSocket Frame-Kodierung und -Dekodierung nach RFC 6455
public enum WebSocketFrame {
    public enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    /// Erzeugt einen Server-Frame (Server maskiert ausgehende Frames gemäß RFC 6455 nicht)
    public static func makeFrame(opcode: Opcode, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode.rawValue) // FIN bit = 1
        let length = payload.count
        if length <= 125 {
            frame.append(UInt8(length))
        } else if length <= 65535 {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            var len = UInt64(length).bigEndian
            frame.append(Data(bytes: &len, count: 8))
        }
        frame.append(payload)
        return frame
    }

    /// Hilfsfunktion für Text-Frames
    public static func makeTextFrame(_ string: String) -> Data {
        makeFrame(opcode: .text, payload: Data(string.utf8))
    }

    /// Hilfsfunktion für Binär-Frames (z. B. FFT-Bins oder PCM Audio)
    public static func makeBinaryFrame(_ data: Data) -> Data {
        makeFrame(opcode: .binary, payload: data)
    }

    public struct ParsedFrame {
        public let opcode: Opcode
        public let payload: Data
        public let consumedBytes: Int
    }

    /// Liest einen eingehenden Client-Frame aus einem Datenpuffer (Client-Frames sind nach RFC 6455 maskiert)
    public static func parseClientFrame(from data: Data) -> ParsedFrame? {
        guard data.count >= 2 else { return nil }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]

        guard let opcode = Opcode(rawValue: b0 & 0x0F) else { return nil }
        let isMasked = (b1 & 0x80) != 0
        var payloadLen = UInt64(b1 & 0x7F)
        var offset = 2

        if payloadLen == 126 {
            guard data.count >= offset + 2 else { return nil }
            let high = UInt64(data[data.startIndex + offset])
            let low = UInt64(data[data.startIndex + offset + 1])
            payloadLen = (high << 8) | low
            offset += 2
        } else if payloadLen == 127 {
            guard data.count >= offset + 8 else { return nil }
            payloadLen = 0
            for i in 0..<8 {
                payloadLen = (payloadLen << 8) | UInt64(data[data.startIndex + offset + i])
            }
            offset += 8
        }

        var maskKey: [UInt8] = [0, 0, 0, 0]
        if isMasked {
            guard data.count >= offset + 4 else { return nil }
            for i in 0..<4 {
                maskKey[i] = data[data.startIndex + offset + i]
            }
            offset += 4
        }

        let totalExpected = offset + Int(payloadLen)
        guard data.count >= totalExpected else { return nil }

        let rawPayload = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + totalExpected))
        var unmasked = Data(count: rawPayload.count)
        if isMasked {
            rawPayload.withUnsafeBytes { rawPtr in
                unmasked.withUnsafeMutableBytes { outPtr in
                    let raw = rawPtr.bindMemory(to: UInt8.self)
                    let out = outPtr.bindMemory(to: UInt8.self)
                    for i in 0..<raw.count {
                        out[i] = raw[i] ^ maskKey[i % 4]
                    }
                }
            }
        } else {
            unmasked = rawPayload
        }

        return ParsedFrame(opcode: opcode, payload: unmasked, consumedBytes: totalExpected)
    }
}
