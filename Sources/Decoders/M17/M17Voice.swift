// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Codec2

// M17-Sprache: Codec2 (Bibliothek Codec2, LGPL-2.1, Vendor/Codec2). Ein Strom-Rahmen (40 ms) trägt 16 Byte Nutzlast:
//   Sprache 3200:       zwei Codec2-Rahmen zu je 64 Bit (160 Abtastwerte, 20 ms)
//   Sprache 1600 + Daten: ein Codec2-Rahmen mit 64 Bit (320 Abtastwerte, 40 ms) und 8 Byte frei verfügbare Daten

public final class M17Voice: @unchecked Sendable {
    private var c3200: OpaquePointer?
    private var c1600: OpaquePointer?

    public init?() {
        c3200 = codec2_create(Int32(CODEC2_MODE_3200))
        c1600 = codec2_create(Int32(CODEC2_MODE_1600))
        if c3200 == nil || c1600 == nil { return nil }
    }

    deinit {
        if let c3200 { codec2_destroy(c3200) }
        if let c1600 { codec2_destroy(c1600) }
    }

    /// Nutzlast (16 Byte) → Sprache (8 kHz, 16 Bit; 320 Abtastwerte)
    public func decode(payload: [UInt8], full: Bool) -> [Int16] {
        precondition(payload.count == 16)
        var out = [Int16](repeating: 0, count: 320)
        if full {
            for half in 0..<2 {
                let bytes = Array(payload[(half * 8)..<(half * 8 + 8)])
                var speech = [Int16](repeating: 0, count: 160)
                speech.withUnsafeMutableBufferPointer { s in bytes.withUnsafeBufferPointer { b in codec2_decode(c3200, s.baseAddress, b.baseAddress) } }
                out.replaceSubrange((half * 160)..<(half * 160 + 160), with: speech)
            }
        } else {
            let bytes = Array(payload[0..<8])
            out.withUnsafeMutableBufferPointer { s in bytes.withUnsafeBufferPointer { b in codec2_decode(c1600, s.baseAddress, b.baseAddress) } }
        }
        return out
    }

    /// Sprache (320 Abtastwerte, 8 kHz) → Nutzlast (16 Byte); bei 1600 sind die letzten 8 Byte `data`
    public func encode(speech: [Int16], full: Bool, data: [UInt8] = [UInt8](repeating: 0, count: 8)) -> [UInt8] {
        precondition(speech.count == 320)
        var out = [UInt8]()
        if full {
            for half in 0..<2 {
                var s = Array(speech[(half * 160)..<(half * 160 + 160)])
                var bytes = [UInt8](repeating: 0, count: 8)
                bytes.withUnsafeMutableBufferPointer { b in s.withUnsafeMutableBufferPointer { sp in codec2_encode(c3200, b.baseAddress, sp.baseAddress) } }
                out += bytes
            }
        } else {
            var s = speech
            var bytes = [UInt8](repeating: 0, count: 8)
            bytes.withUnsafeMutableBufferPointer { b in s.withUnsafeMutableBufferPointer { sp in codec2_encode(c1600, b.baseAddress, sp.baseAddress) } }
            out = bytes + data.prefix(8) + [UInt8](repeating: 0, count: max(0, 8 - data.count))
        }
        return out
    }
}
