// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// LZHUF (LZSS mit adaptivem Huffman-Code, Haruyasu Yoshizaki 1988, nach Haruhiko Okumura), wie Winlink und FBB es für Nachrichten benutzen.
/// Winlink-Fassung („B2“): zwei Byte CRC-16 (XMODEM, Little Endian) über den Rest, vier Byte Länge der Klartext-Daten (Little Endian), dann der Bitstrom.
/// Nur Decodierung (Digidec liest Nachrichten, es sendet keine).
public enum LZHUF {
    public struct Result: Sendable {
        public var data: [UInt8]
        /// Prüfsumme stimmt (nur bei `crc16: true`; sonst immer wahr)
        public var checksumOK: Bool
        /// Alle angekündigten Bytes wurden gewonnen
        public var complete: Bool
    }

    static let n = 2048                 // Ringpuffer
    static let f = 60                   // Vorschau
    static let threshold = 2
    static let numChar = 256 - threshold + f   // 314
    static let t = numChar * 2 - 1      // 627
    static let r = t - 1                // Wurzel
    static let maxFreq = 0x8000

    // Obere 6 Bit der Position: Code (links ausgerichtet, 8 Bit) und Länge, aus denen die Nachschlagetabellen für das Decodieren entstehen
    private static let pCode: [UInt8] = [
        0x00, 0x20, 0x30, 0x40, 0x50, 0x58, 0x60, 0x68, 0x70, 0x78, 0x80, 0x88, 0x90, 0x94, 0x98, 0x9C,
        0xA0, 0xA4, 0xA8, 0xAC, 0xB0, 0xB4, 0xB8, 0xBC, 0xC0, 0xC2, 0xC4, 0xC6, 0xC8, 0xCA, 0xCC, 0xCE,
        0xD0, 0xD2, 0xD4, 0xD6, 0xD8, 0xDA, 0xDC, 0xDE, 0xE0, 0xE2, 0xE4, 0xE6, 0xE8, 0xEA, 0xEC, 0xEE,
        0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF]
    private static let pLen: [UInt8] = [
        3, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6,
        6, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
        8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8]

    /// Nachschlagetabellen für die obersten 8 Bit des Positionscodes: Wert der oberen 6 Bit und Codelänge
    private static let decodeTables: (code: [UInt8], length: [UInt8]) = {
        var code = [UInt8](repeating: 0, count: 256)
        var length = [UInt8](repeating: 0, count: 256)
        for v in 0..<64 {
            let start = Int(pCode[v]), count = 1 << (8 - Int(pLen[v]))
            for k in 0..<count {
                code[start + k] = UInt8(v)
                length[start + k] = pLen[v]
            }
        }
        return (code, length)
    }()

    /// CRC-16/XMODEM (Polynom 0x1021, Anfangswert 0), Tabelle
    private static let crcTable: [UInt16] = (0..<256).map { i -> UInt16 in
        var c = UInt16(i) << 8
        for _ in 0..<8 { c = c & 0x8000 != 0 ? (c << 1) ^ 0x1021 : c << 1 }
        return c
    }

    /// Prüfsumme wie in Winlink: XMODEM-CRC über die Bytes und zwei Nullbytes
    public static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var sum: UInt16 = 0
        for b in bytes { sum = (sum << 8) ^ crcTable[Int(sum >> 8)] ^ UInt16(b) }
        for _ in 0..<2 { sum = (sum << 8) ^ crcTable[Int(sum >> 8)] }
        return sum
    }

    /// Entpackt `input`. `crc16: true` = Winlink (B2): zwei Byte Prüfsumme vorweg. nil bei zu kurzem Kopf.
    public static func decode(_ input: [UInt8], crc16 withCRC: Bool = true, maxSize: Int = 4 << 20) -> Result? {
        let headerLength = withCRC ? 6 : 4
        guard input.count >= headerLength else { return nil }
        var pos = 0
        var expectedCRC: UInt16 = 0
        if withCRC {
            expectedCRC = UInt16(input[0]) | UInt16(input[1]) << 8
            pos = 2
        }
        let checksumOK = !withCRC || crc16(input[2...]) == expectedCRC
        let size = Int(input[pos]) | Int(input[pos + 1]) << 8 | Int(input[pos + 2]) << 16 | Int(input[pos + 3]) << 24
        pos += 4
        guard size >= 0, size <= maxSize else { return nil }

        var d = Decoder(input: input, position: pos)
        let out = d.run(size: size)
        return Result(data: out, checksumOK: checksumOK, complete: out.count == size && !d.overrun)
    }

    /// Nur für Testsignale: ein gültiger LZHUF-Strom, der jedes Byte als Einzelzeichen kodiert (keine Treffer im Wörterbuch, daher kaum kleiner)
    public static func encodeLiterals(_ input: [UInt8], crc16 withCRC: Bool = true) -> [UInt8] {
        var d = Decoder(input: [], position: 0)
        var body: [UInt8] = []
        for k in 0..<4 { body.append(UInt8((input.count >> (8 * k)) & 0xFF)) }
        var acc = 0, count = 0
        for byte in input {
            let (code, length) = d.encodeChar(Int(byte))
            for k in 0..<length {
                acc = acc << 1 | ((code >> (15 - k)) & 1)
                count += 1
                if count == 8 { body.append(UInt8(acc)); acc = 0; count = 0 }
            }
        }
        if count > 0 { body.append(UInt8(acc << (8 - count))) }
        guard withCRC else { return body }
        let sum = crc16(body[...])
        return [UInt8(sum & 0xFF), UInt8(sum >> 8)] + body
    }

    // MARK: Decoder

    private struct Decoder {
        var freq = [Int](repeating: 0, count: LZHUF.t + 1)
        var prnt = [Int](repeating: 0, count: LZHUF.t + LZHUF.numChar)
        var son = [Int](repeating: 0, count: LZHUF.t)
        var text = [UInt8](repeating: 0x20, count: LZHUF.n + LZHUF.f - 1)
        let input: [UInt8]
        var position: Int
        var bitBuffer = 0
        var bitCount = 0
        /// Es wurde über das Ende der Eingabe hinaus gelesen (abgeschnittene Daten)
        var overrun = false

        init(input: [UInt8], position: Int) {
            self.input = input
            self.position = position
            let t = LZHUF.t, nc = LZHUF.numChar, root = LZHUF.r
            for i in 0..<nc {
                freq[i] = 1
                son[i] = i + t
                prnt[i + t] = i
            }
            var i = 0, j = nc
            while j <= root {
                freq[j] = freq[i] + freq[i + 1]
                son[j] = i
                prnt[i] = j
                prnt[i + 1] = j
                i += 2
                j += 1
            }
            freq[t] = 0xFFFF
            prnt[root] = 0
        }

        mutating func bit() -> Int {
            if bitCount == 0 {
                if position < input.count {
                    bitBuffer = Int(input[position])
                    position += 1
                } else {
                    overrun = true
                    bitBuffer = 0
                }
                bitCount = 8
            }
            bitCount -= 1
            return (bitBuffer >> bitCount) & 1
        }

        mutating func byte() -> Int {
            var v = 0
            for _ in 0..<8 { v = v << 1 | bit() }
            return v
        }

        mutating func reconstruct() {
            let t = LZHUF.t, nc = LZHUF.numChar
            var j = 0
            for i in 0..<t where son[i] >= t {
                freq[j] = (freq[i] + 1) / 2
                son[j] = son[i]
                j += 1
            }
            var i = 0
            j = nc
            while j < t {
                let f = freq[i] + freq[i + 1]
                freq[j] = f
                var k = j - 1
                while f < freq[k] { k -= 1 }
                k += 1
                let l = j - k
                if l > 0 {
                    for m in stride(from: l - 1, through: 0, by: -1) {
                        freq[k + 1 + m] = freq[k + m]
                        son[k + 1 + m] = son[k + m]
                    }
                }
                freq[k] = f
                son[k] = i
                i += 2
                j += 1
            }
            for i in 0..<t {
                let k = son[i]
                if k >= t {
                    prnt[k] = i
                } else {
                    prnt[k] = i
                    prnt[k + 1] = i
                }
            }
        }

        mutating func update(_ symbol: Int) {
            if freq[LZHUF.r] == LZHUF.maxFreq { reconstruct() }
            var c = prnt[symbol + LZHUF.t]
            repeat {
                freq[c] += 1
                let k = freq[c]
                if k > freq[c + 1] {
                    var l = c + 1
                    while k > freq[l + 1] { l += 1 }
                    freq[c] = freq[l]
                    freq[l] = k
                    let i = son[c]
                    prnt[i] = l
                    if i < LZHUF.t { prnt[i + 1] = l }
                    let j = son[l]
                    son[l] = i
                    prnt[j] = c
                    if j < LZHUF.t { prnt[j + 1] = c }
                    son[c] = j
                    c = l
                }
                c = prnt[c]
            } while c != 0
        }

        mutating func decodeChar() -> Int {
            var c = son[LZHUF.r]
            while c < LZHUF.t { c = son[c + bit()] }
            c -= LZHUF.t
            update(c)
            return c
        }

        /// Zeichen als Huffman-Code (oberste Bits zuerst, 16 Bit linksbündig) und Länge; danach Baum nachführen
        mutating func encodeChar(_ c: Int) -> (code: Int, length: Int) {
            var code = 0, length = 0
            var k = prnt[c + LZHUF.t]
            repeat {
                code >>= 1
                if k & 1 == 1 { code += 0x8000 }
                length += 1
                k = prnt[k]
            } while k != LZHUF.r
            update(c)
            return (code, length)
        }

        mutating func decodePosition() -> Int {
            var i = byte()
            let upper = Int(LZHUF.decodeTables.code[i]) << 6
            var extra = Int(LZHUF.decodeTables.length[i]) - 2
            while extra > 0 {
                i = i << 1 | bit()
                extra -= 1
            }
            return upper | (i & 0x3F)
        }

        mutating func run(size: Int) -> [UInt8] {
            var out: [UInt8] = []
            out.reserveCapacity(size)
            var ring = LZHUF.n - LZHUF.f
            let mask = LZHUF.n - 1
            while out.count < size && !overrun {
                let c = decodeChar()
                if c < 256 {
                    out.append(UInt8(c))
                    text[ring] = UInt8(c)
                    ring = (ring + 1) & mask
                } else {
                    let start = (ring - decodePosition() - 1) & mask
                    let length = c - 255 + LZHUF.threshold
                    for k in 0..<length {
                        let b = text[(start + k) & mask]
                        out.append(b)
                        text[ring] = b
                        ring = (ring + 1) & mask
                        if out.count == size { break }
                    }
                }
            }
            return out
        }
    }
}
