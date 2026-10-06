// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// VDL Mode 2 (VHF Digital Link, ICAO Annex 10): Datenfunk zwischen Flugzeug und Boden auf 136,725 … 136,975 MHz, D8PSK mit 10 500 Symbolen/s
// (31,5 kbit/s). Aufbau eines Bursts nach dem Vorbild dumpvdl2 (Tomasz Lemiech SP5WWP, GPL-3.0) und ICAO Doc 9776:
//
//   Präambel (16 Symbole) → Kopf (3 + 17 + 5 Bit: Reserviert, Länge in Bit (LSB zuerst), Hamming-Prüfung) → Daten und Reed-Solomon-Prüfbytes
//   Alles ab dem Kopf wird mit einem Schieberegister (x¹⁵ + x + 1, Startwert 0x6959) verwürfelt.
//   Die Daten (AVLC-Rahmen mit Flaggen 0x7E und Bitstopfen) sind in Blöcke zu je 249 Byte geteilt, je Block 6 Prüfbytes RS(255,249),
//   verschachtelt (Zeilen = Blöcke); letzte Blöcke haben weniger Prüfbytes (Rest als Auslöschungen).

public enum VDL2 {
    public static let symbolRate = 10_500.0
    public static let samplesPerSymbol = 10
    public static let bitsPerSymbol = 3
    public static let preambleSymbols = 16
    public static let rsN = 255
    public static let rsK = 249
    static let lengthBits = 17
    static let headerFECBits = 5
    static let headerBits = 3 + lengthBits + headerFECBits
    static let maxFrameLength = 0x3FFF
    static let maxFrameLengthCorrected = 0x1FFF
    static let scramblerStart: UInt16 = 0x6959

    /// Die Sprechfunkkanäle der Funkdienste in Europa; 136,975 MHz ist der gemeinsame Signalisierungskanal (CSC)
    public static let europeanChannels: [Double] = [136_725_000, 136_775_000, 136_825_000, 136_875_000, 136_925_000, 136_975_000]
    public static let commonSignallingChannel = 136_975_000.0

    // MARK: Hilfen

    static func reverse(_ v: UInt32, bits: Int) -> UInt32 {
        var r: UInt32 = 0
        for i in 0..<bits where (v >> UInt32(i)) & 1 == 1 { r |= 1 << UInt32(bits - 1 - i) }
        return r
    }

    /// CRC-16/KERMIT-Tabelle (reflektiert 0x8408), wie in ACARS und im AVLC-Rahmenprüfwert
    static let crcTable: [UInt16] = ACARS.crcTable

    static func crc16(_ bytes: ArraySlice<UInt8>, initial: UInt16) -> UInt16 {
        var c = initial
        for b in bytes { c = (c >> 8) ^ crcTable[Int((c ^ UInt16(b)) & 0xFF)] }
        return c
    }

    static let goodFCS: UInt16 = 0xF0B8

    // MARK: Kopf (Hamming-Code, 5 Prüfbits)

    private static let H: [UInt32] = [0b0000000011111111111110000, 0b0011111100001111111101000, 0b1100011100110000111100100,
                                      0b1101101101010011001100010, 0b0110100111100101010100001]
    private static let syndromeTable: [UInt32] = [
        0b0000000000000000000000000, 0b0000000000000000000000001, 0b0000000000000000000000010, 0b0100000000000000000000100,
        0b0000000000000000000000100, 0b0100000000000000000000010, 0b1000000000000000000000000, 0b0100000000000000000000000,
        0b0000000000000000000001000, 0b0010000000000000000000000, 0b0001000000000000000000000, 0b0000100000000000000000000,
        0b0000010000000000000000000, 0b1000100000000000000000000, 0b0000001000000000000000000, 0b0000000100000000000000000,
        0b0000000000000000000010000, 0b0000000010000000000000000, 0b0100000000100000000000000, 0b0000000001000000000000000,
        0b0100000001000000000000000, 0b0000000000100000000000000, 0b0000000000010000000000000, 0b1000000010000000000000000,
        0b0000000000001000000000000, 0b0000000000000100000000000, 0b0000000000000010000000000, 0b0000000000000001000000000,
        0b0000000000000000100000000, 0b0000000000000000010000000, 0b0000000000000000001000000, 0b0000000000000000000100000,
    ]
    private static let syndromeWeight: [Int] = [0, 1, 1, 2, 1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 2, 1, 2, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1]

    private static func parity(_ v: UInt32) -> UInt32 { UInt32(v.nonzeroBitCount & 1) }

    /// Prüfbits zu den oberen 20 Bit des Kopfes (für den Sender und Tests)
    static func headerCheck(_ word: UInt32) -> UInt32 {
        var fec: UInt32 = 0
        for (i, row) in H.enumerated() { fec |= parity(row & word) << UInt32(headerFECBits - 1 - i) }
        return fec
    }

    /// Kopf (25 Bit, erste drei Bit sind das Reservesymbol) prüfen und korrigieren; liefert das Wort und das Gewicht des Fehlers
    static func decodeHeader(_ raw: UInt32) -> (word: UInt32, syndrome: Int)? {
        var r = raw & ((1 << UInt32(lengthBits + headerFECBits)) - 1)       // Bits des Reservesymbols auf 0 zwingen
        var syndrome = 0
        for (i, row) in H.enumerated() { syndrome |= Int(parity(r & row)) << (headerFECBits - 1 - i) }
        r ^= syndromeTable[syndrome]
        guard r & ((1 << UInt32(lengthBits + headerFECBits)) - 1) == r else { return nil }
        return (r, syndrome)
    }

    static func headerErrorWeight(syndrome: Int) -> Int { syndromeWeight[syndrome] }

    // MARK: Verwürfelung

    /// Schieberegister x¹⁵ + x + 1; verwürfelt oder entwürfelt (gleiche Operation) die Bits in `bits[from..<to]`, `state` läuft weiter
    static func scramble(_ bits: inout [UInt8], from: Int, to: Int, state: inout UInt16) {
        guard from < to else { return }
        for i in from..<to {
            let bit = UInt8(((state >> 0) ^ (state >> 14)) & 1)
            state = (state >> 1) | (UInt16(bit) << 14)
            bits[i] ^= bit
        }
    }

    // MARK: Verschachtelung

    static func fecOctetCount(lastBlockLength len: Int) -> Int {
        if len < 3 { return 0 }
        if len < 31 { return 2 }
        if len < 68 { return 4 }
        return 6
    }

    /// Wie `deinterleave` des Vorbilds: Spalte für Spalte über die Zeilen schreiben
    static func deinterleave(_ input: [UInt8], rows: Int, cols: Int, into out: inout [[UInt8]], fillWidth: Int, offset: Int) -> Bool {
        guard rows > 0, cols > 0, fillWidth > 0 else { return false }
        let len = input.count
        var lastRowLen = len % fillWidth
        if lastRowLen == 0 { lastRowLen = fillWidth }
        guard fillWidth + offset <= cols, len <= rows * fillWidth else { return false }
        if rows > 1 && len - lastRowLen < (rows - 1) * fillWidth { return false }
        var row = 0, col = offset
        lastRowLen += offset
        for i in 0..<len {
            if row == rows - 1 && col >= lastRowLen {
                out[row][col] = 0
                row = 0
                col += 1
            }
            guard col < cols else { return false }
            out[row][col] = input[i]
            row += 1
            if row == rows { row = 0; col += 1 }
        }
        return true
    }

    /// Verschachtelung für den Sender (Umkehrung): Daten und Prüfbytes je Block in zwei Folgen
    static func interleave(_ blocks: [[UInt8]], rows: Int, fillWidth: Int, offset: Int, count: Int) -> [UInt8] {
        // Gleiche Schreibreihenfolge wie `deinterleave`, nur gelesen
        var out = [UInt8]()
        var row = 0, col = offset
        var lastRowLen = count % fillWidth
        if lastRowLen == 0 { lastRowLen = fillWidth }
        lastRowLen += offset
        var i = 0
        while i < count {
            if row == rows - 1 && col >= lastRowLen { row = 0; col += 1 }
            out.append(blocks[row][col])
            row += 1
            if row == rows { row = 0; col += 1 }
            i += 1
        }
        return out
    }

    // MARK: Bitstopfen und Flaggen (HDLC)

    /// Nächster Rahmen aus dem Bitstrom (Flaggen 0x7E, nach fünf Einsen ein Nullbit eingefügt); `nil`, wenn der Strom ungültig ist.
    /// Rückgabe: die Bits des Rahmens und ob danach noch Bits folgen.
    static func nextFrame(_ bits: [UInt8], position: inout Int) -> (bits: [UInt8], more: Bool)? {
        restart: while true {
            var ones = 0
            var out: [UInt8] = []
            var i = position
            while i < bits.count {
                let b = bits[i]
                if b == 0 && ones == 5 {                  // gestopftes Nullbit
                    ones = 0
                    i += 1; position += 1
                    continue
                } else if b == 1 {
                    ones += 1
                    if ones > 6 { return nil }            // sieben Einsen
                }
                out.append(b)
                if b == 0 {
                    if ones == 6 {                        // Flagge
                        let j = out.count - 1
                        if j == 7 {                       // erste Flagge: übergehen und neu beginnen
                            position += 1
                            continue restart
                        }
                        if j < 7 { return nil }
                        out.removeLast(8)                 // Flagge entfernen
                        position += 1
                        return (out, position < bits.count)
                    }
                    ones = 0
                }
                i += 1; position += 1
            }
            return (out, position < bits.count)
        }
    }

    // MARK: Burst-Decoder

    /// Zustand der Burst-Decodierung eines Kanals: Kopf, dann Daten
    public struct Header: Sendable {
        public var dataLength = 0
        public var dataOctets = 0
        public var numBlocks = 0
        public var fecOctets = 0
        public var lastBlockOctets = 0
        public var requestedBits = 0
        public var syndrome = 0
    }

    /// Kopf aus den ersten Bits (bereits entwürfelt) auswerten
    static func parseHeader(_ bits: [UInt8], at start: Int) -> Header? {
        guard start + headerBits <= bits.count else { return nil }
        var word: UInt32 = 0
        for i in 0..<headerBits { word = (word << 1) | UInt32(bits[start + i] & 1) }
        guard let (decoded, syndrome) = decodeHeader(word) else { return nil }
        let dataLength = Int(reverse((decoded >> UInt32(headerFECBits)) & ((1 << UInt32(lengthBits)) - 1), bits: lengthBits))
        if (syndrome != 0 && dataLength > maxFrameLengthCorrected) || dataLength > maxFrameLength { return nil }
        var h = Header()
        h.syndrome = syndrome
        h.dataLength = dataLength
        h.dataOctets = (dataLength + 7) / 8
        h.numBlocks = h.dataOctets / rsK
        h.fecOctets = h.numBlocks * (rsN - rsK)
        h.lastBlockOctets = h.dataOctets % rsK
        if h.lastBlockOctets != 0 { h.numBlocks += 1 }
        h.fecOctets += fecOctetCount(lastBlockLength: h.lastBlockOctets)
        if h.lastBlockOctets == 0 { h.lastBlockOctets = 249 }
        if h.fecOctets == 0 { return nil }
        h.requestedBits = 8 * (h.dataOctets + h.fecOctets)
        return h
    }

    static func readLSBFirst(_ bits: [UInt8], at start: Int, count: Int) -> [UInt8]? {
        guard start + count * 8 <= bits.count else { return nil }
        return (0..<count).map { i in (0..<8).reduce(UInt8(0)) { $0 | ((bits[start + i * 8 + $1] & 1) << UInt8($1)) } }
    }

    /// Daten eines Bursts (entwürfelte Bits ab `start`, das Ende des Kopfes) prüfen und in AVLC-Rahmen zerlegen.
    /// Rückgabe: Rahmen (mit Prüfsumme am Ende) und die Zahl der Reed-Solomon-Korrekturen; `nil` bei Fehlern.
    static func decodeData(_ bits: [UInt8], at start: Int, header h: Header) -> (frames: [[UInt8]], corrections: Int)? {
        guard let data = readLSBFirst(bits, at: start, count: h.dataOctets),
              let fec = readLSBFirst(bits, at: start + h.dataOctets * 8, count: h.fecOctets) else { return nil }
        var table = [[UInt8]](repeating: [UInt8](repeating: 0, count: rsN), count: h.numBlocks)
        guard deinterleave(data, rows: h.numBlocks, cols: rsN, into: &table, fillWidth: rsK, offset: 0) else { return nil }
        var fecRows = h.numBlocks
        if fecOctetCount(lastBlockLength: h.lastBlockOctets) == 0 { fecRows -= 1 }
        guard deinterleave(fec, rows: fecRows, cols: rsN, into: &table, fillWidth: rsN - rsK, offset: rsK) else { return nil }
        var corrections = 0
        var stream: [UInt8] = []
        for r in 0..<h.numBlocks {
            var fecOctets = rsN - rsK
            if r == h.numBlocks - 1 { fecOctets = fecOctetCount(lastBlockLength: h.lastBlockOctets) }
            let ret = ReedSolomon.shared.verify(&table[r], parityOctets: fecOctets)
            if ret < 0 { return nil }
            if ret > 0 { corrections += ret - (rsN - rsK - fecOctets) }
            let n = r == h.numBlocks - 1 ? h.lastBlockOctets : rsK
            for byte in table[r][0..<n] { for j in 0..<8 { stream.append((byte >> UInt8(j)) & 1) } }
        }
        if h.dataLength < stream.count { stream.removeLast(stream.count - h.dataLength) }
        var frames: [[UInt8]] = []
        var pos = 0
        while true {
            guard let (frameBits, more) = nextFrame(stream, position: &pos), frameBits.count % 8 == 0 else {
                return frames.isEmpty ? nil : (frames, corrections)     // bereits gelesene Rahmen behalten
            }
            frames.append(stride(from: 0, to: frameBits.count, by: 8).map { i in (0..<8).reduce(UInt8(0)) { $0 | ((frameBits[i + $1] & 1) << UInt8($1)) } })
            if !more { break }
        }
        return (frames, corrections)
    }
}

// MARK: - Reed-Solomon RS(255,249) über GF(256), Polynom 0x187, erste Wurzel 120

/// Nach dem Vorbild von libfec (Phil Karn KA9Q, LGPL): Berlekamp-Massey mit Auslöschungen, Chien-Suche und Forney
public final class ReedSolomon: @unchecked Sendable {
    public static let shared = ReedSolomon()
    static let nn = 255, nroots = 6, fcr = 120, prim = 1
    private var alphaTo = [Int](repeating: 0, count: 256)
    private var indexOf = [Int](repeating: 0, count: 256)
    private var genpoly = [Int](repeating: 0, count: 7)
    private let iprim: Int

    private func modnn(_ x: Int) -> Int {
        var x = x
        while x >= Self.nn { x -= Self.nn; x = (x >> 8) + (x & Self.nn) }
        return x
    }

    init() {
        indexOf[0] = 255
        alphaTo[255] = 0
        var sr = 1
        for i in 0..<255 {
            indexOf[sr] = i
            alphaTo[i] = sr
            sr <<= 1
            if sr & 0x100 != 0 { sr ^= 0x187 }
            sr &= 0xFF
        }
        var ip = 1
        while ip % Self.prim != 0 { ip += Self.nn }
        iprim = ip / Self.prim
        genpoly[0] = 1
        var root = Self.fcr * Self.prim
        for i in 0..<Self.nroots {
            genpoly[i + 1] = 1
            var j = i
            while j > 0 {
                if genpoly[j] != 0 {
                    genpoly[j] = genpoly[j - 1] ^ alphaTo[modnn(indexOf[genpoly[j]] + root)]
                } else {
                    genpoly[j] = genpoly[j - 1]
                }
                j -= 1
            }
            genpoly[0] = alphaTo[modnn(indexOf[genpoly[0]] + root)]
            root += Self.prim
        }
        for i in 0...Self.nroots { genpoly[i] = indexOf[genpoly[i]] }
    }

    /// Prüfbytes (6) zu 249 Datenbytes
    public func parity(of data: [UInt8]) -> [UInt8] {
        precondition(data.count == 249)
        var par = [Int](repeating: 0, count: Self.nroots)
        for d in data {
            let feedback = indexOf[Int(d) ^ par[0]]
            if feedback != 255 {
                for j in 1..<Self.nroots { par[j] ^= alphaTo[modnn(feedback + genpoly[Self.nroots - j])] }
            }
            par.removeFirst()
            par.append(feedback != 255 ? alphaTo[modnn(feedback + genpoly[0])] : 0)
        }
        return par.map { UInt8($0) }
    }

    /// Prüft und korrigiert einen Block; bei verkürzter Prüfung (weniger als 6 Prüfbytes) sind die fehlenden Bytes Auslöschungen.
    /// Rückgabe: Zahl der korrigierten Stellen (inklusive Auslöschungen), −1 = nicht korrigierbar
    public func verify(_ block: inout [UInt8], parityOctets: Int) -> Int {
        if parityOctets == 0 { return 0 }
        let erasureCount = 255 - 249 - parityOctets
        var erasures = (0..<max(0, erasureCount)).map { 249 + parityOctets + $0 }
        return decode(&block, erasures: &erasures)
    }

    func decode(_ data: inout [UInt8], erasures: inout [Int]) -> Int {
        let nn = Self.nn, nroots = Self.nroots, fcr = Self.fcr, prim = Self.prim
        let a0 = nn
        var lambda = [Int](repeating: 0, count: nroots + 1)
        var s = [Int](repeating: 0, count: nroots)
        var b = [Int](repeating: 0, count: nroots + 1)
        var t = [Int](repeating: 0, count: nroots + 1)
        var omega = [Int](repeating: 0, count: nroots + 1)
        var root = [Int](repeating: 0, count: nroots)
        var reg = [Int](repeating: 0, count: nroots + 1)
        var loc = [Int](repeating: 0, count: nroots)
        for i in 0..<nroots { s[i] = Int(data[0]) }
        for j in 1..<nn {
            for i in 0..<nroots {
                if s[i] == 0 { s[i] = Int(data[j]) } else { s[i] = Int(data[j]) ^ alphaTo[modnn(indexOf[s[i]] + (fcr + i) * prim)] }
            }
        }
        var synError = 0
        for i in 0..<nroots { synError |= s[i]; s[i] = indexOf[s[i]] }
        if synError == 0 { return 0 }
        lambda[0] = 1
        let noEras = erasures.count
        if noEras > 0 {
            lambda[1] = alphaTo[modnn(prim * (nn - 1 - erasures[0]))]
            if noEras > 1 {
                for i in 1..<noEras {
                    let u = modnn(prim * (nn - 1 - erasures[i]))
                    var j = i + 1
                    while j > 0 {
                        let tmp = indexOf[lambda[j - 1]]
                        if tmp != a0 { lambda[j] ^= alphaTo[modnn(u + tmp)] }
                        j -= 1
                    }
                }
            }
        }
        for i in 0..<(nroots + 1) { b[i] = indexOf[lambda[i]] }
        var r = noEras, el = noEras
        while true {
            r += 1
            if r > nroots { break }
            var discr = 0
            for i in 0..<r where lambda[i] != 0 && s[r - i - 1] != a0 { discr ^= alphaTo[modnn(indexOf[lambda[i]] + s[r - i - 1])] }
            discr = indexOf[discr]
            if discr == a0 {
                for i in stride(from: nroots, to: 0, by: -1) { b[i] = b[i - 1] }
                b[0] = a0
            } else {
                t[0] = lambda[0]
                for i in 0..<nroots { t[i + 1] = b[i] != a0 ? lambda[i + 1] ^ alphaTo[modnn(discr + b[i])] : lambda[i + 1] }
                if 2 * el <= r + noEras - 1 {
                    el = r + noEras - el
                    for i in 0...nroots { b[i] = lambda[i] == 0 ? a0 : modnn(indexOf[lambda[i]] - discr + nn) }
                } else {
                    for i in stride(from: nroots, to: 0, by: -1) { b[i] = b[i - 1] }
                    b[0] = a0
                }
                lambda = t
            }
        }
        var degLambda = 0
        for i in 0..<(nroots + 1) {
            lambda[i] = indexOf[lambda[i]]
            if lambda[i] != a0 { degLambda = i }
        }
        for i in 1...nroots { reg[i] = lambda[i] }
        var count = 0
        var k = iprim - 1
        var i = 1
        while i <= nn {
            var q = 1
            var j = degLambda
            while j > 0 {
                if reg[j] != a0 {
                    reg[j] = modnn(reg[j] + j)
                    q ^= alphaTo[reg[j]]
                }
                j -= 1
            }
            if q == 0 {
                root[count] = i
                loc[count] = k
                count += 1
                if count == degLambda { break }
            }
            i += 1
            k = modnn(k + iprim)
        }
        if degLambda != count { return -1 }
        let degOmega = degLambda - 1
        if degOmega >= 0 {
            for i in 0...degOmega {
                var tmp = 0
                var j = i
                while j >= 0 {
                    if s[i - j] != a0 && lambda[j] != a0 { tmp ^= alphaTo[modnn(s[i - j] + lambda[j])] }
                    j -= 1
                }
                omega[i] = indexOf[tmp]
            }
        }
        var j = count - 1
        while j >= 0 {
            var num1 = 0
            var i = degOmega
            while i >= 0 {
                if omega[i] != a0 { num1 ^= alphaTo[modnn(omega[i] + i * root[j])] }
                i -= 1
            }
            let num2 = alphaTo[modnn(root[j] * (fcr - 1) + nn)]
            var den = 0
            i = min(degLambda, nroots - 1) & ~1
            while i >= 0 {
                if lambda[i + 1] != a0 { den ^= alphaTo[modnn(lambda[i + 1] + i * root[j])] }
                i -= 2
            }
            if num1 != 0 && loc[j] >= 0 && den != 0 {
                data[loc[j]] ^= UInt8(alphaTo[modnn(indexOf[num1] + indexOf[num2] + nn - indexOf[den])])
            }
            j -= 1
        }
        return count
    }
}

// MARK: - AVLC

public struct VDL2Address: Equatable, Hashable, Sendable {
    /// 28 Bit: Adresse (24), Art (3), Zustand (1)
    public let raw: UInt32
    public init(raw: UInt32) { self.raw = raw & 0x0FFF_FFFF }
    public var address: UInt32 { raw & 0xFF_FFFF }
    public var type: Int { Int((raw >> 24) & 7) }
    /// Bei der Quelladresse: Befehl (0) oder Antwort (1); bei der Zieladresse: Flugzeug in der Luft (0) oder am Boden (1)
    public var status: Int { Int((raw >> 27) & 1) }
    public var text: String { String(format: "%06X", address) }
    public var isAircraft: Bool { type == 1 }
    public var isGroundStation: Bool { type == 4 || type == 5 }
    public var isBroadcast: Bool { type == 7 }
    public var typeText: String { ["reserviert", "Flugzeug", "reserviert", "reserviert", "Bodenstation", "Bodenstation", "reserviert", "alle Stationen"][type] }

    /// Vier Byte im Rahmen: 7 Bit je Byte, das niedrigste Bit ist das Endekennzeichen; Reihenfolge umgekehrt
    static func parse(_ b: ArraySlice<UInt8>) -> VDL2Address {
        let i = b.startIndex
        let v = UInt32(b[i] >> 1) | (UInt32(b[i + 1]) << 6) | (UInt32(b[i + 2]) << 13) | (UInt32(b[i + 3] & 0xFE) << 20)
        return VDL2Address(raw: VDL2.reverse(v, bits: 28))
    }

    /// Umkehrung von `parse`: sieben Bit je Byte, im niedrigsten Bit das Erweiterungskennzeichen (nur im vierten Byte 1, wenn `last`)
    func bytes(last: Bool) -> [UInt8] {
        let v = VDL2.reverse(raw, bits: 28)
        return (0..<4).map { UInt8((v >> UInt32(7 * $0)) & 0x7F) << 1 | ($0 == 3 && last ? 1 : 0) }
    }
}

public struct AVLCFrame: Identifiable, Sendable {
    public enum Kind: Sendable { case information, supervisory, unnumbered }
    public let id = UUID()
    public var time: Date
    public var frequency: Double
    public var source: VDL2Address
    public var destination: VDL2Address
    public var kind: Kind
    /// Kurzbeschreibung des Rahmens („I“, „RR“, „XID“, „UI“ …)
    public var command: String
    public var poll: Bool
    public var payload: [UInt8]
    /// ACARS-Nachricht (Rahmen mit Kennung FF FF 01)
    public var acars: ACARSMessage?
    public var levelDB: Double
    public var noiseDB: Double
    public var ppm: Double
    public var fecCorrections: Int
    public var length: Int
    /// Abschluss eines Datenpakets nach X.25 (ATN, CLNP …): nicht ausgewertet
    public var isX25: Bool { kind == .information && acars == nil && !payload.isEmpty }

    public var isDownlink: Bool { source.isAircraft }
}

public enum AVLC {
    static let supervisory = ["RR", "RNR", "REJ", "SREJ"]
    static let unnumbered: [Int: String] = [0x00: "UI", 0x03: "DM", 0x10: "DISC", 0x18: "UA", 0x21: "FRMR", 0x2B: "XID", 0x38: "TEST"]

    /// Rahmen prüfen (Prüfsumme) und zerlegen; `nil`, wenn die Prüfsumme nicht stimmt oder der Rahmen zu kurz ist
    public static func parse(_ frame: [UInt8], time: Date, frequency: Double, levelDB: Double, noiseDB: Double, ppm: Double, corrections: Int) -> AVLCFrame? {
        guard frame.count >= 11, VDL2.crc16(frame[...], initial: 0xFFFF) == VDL2.goodFCS else { return nil }
        let body = Array(frame.dropLast(2))
        let dst = VDL2Address.parse(body[0..<4])
        let src = VDL2Address.parse(body[4..<8])
        let lcf = Int(body[8])
        var payload = Array(body[9...])
        var kind = AVLCFrame.Kind.information
        var command = "I"
        var poll = false
        if lcf & 1 == 0 {
            poll = (lcf >> 4) & 1 == 1
        } else if lcf & 3 == 1 {
            kind = .supervisory
            command = supervisory[(lcf >> 2) & 3]
            poll = (lcf >> 4) & 1 == 1
        } else {
            kind = .unnumbered
            // Das Poll-Bit (Bit 4 des Steuerbytes) liegt mitten im Befehlsfeld und wird ausmaskiert
            command = unnumbered[((lcf >> 2) & 0x3F) & 0x3B] ?? String(format: "U%02X", ((lcf >> 2) & 0x3F) & 0x3B)
            poll = (lcf >> 4) & 1 == 1
        }
        var acars: ACARSMessage?
        if kind == .information, payload.count > 3, payload[0] == 0xFF, payload[1] == 0xFF, payload[2] == 0x01 {
            acars = parseACARS(Array(payload[3...]), time: time, levelDB: levelDB)
            if acars != nil { payload = Array(payload[3...]) }
        }
        return AVLCFrame(time: time, frequency: frequency, source: src, destination: dst, kind: kind, command: command, poll: poll, payload: payload,
                         acars: acars, levelDB: levelDB, noiseDB: noiseDB, ppm: ppm, fecCorrections: corrections, length: frame.count)
    }

    /// ACARS im AVLC: Modus, Kennzeichen (7), Quittung, Label (2), Block-ID, STX, Text, ETX/ETB, Prüfsumme (2), DEL; Zeichen mit Paritätsbit
    static func parseACARS(_ buf: [UInt8], time: Date, levelDB: Double) -> ACARSMessage? {
        guard buf.count >= 16, buf[buf.count - 1] == 0x7F else { return nil }
        var len = buf.count - 1
        let crcOK = ACARS.crc(Array(buf[0..<len])) == 0
        len -= 2
        guard crcOK else { return nil }
        let t = buf[0..<len].map { $0 & 0x7F }
        guard let last = t.last, last == 0x03 || last == 0x17 else { return nil }
        let end = t.count - 1
        var k = 0
        let mode = Character(UnicodeScalar(t[k])); k += 1
        var reg = ""
        for _ in 0..<7 { if t[k] != 0x2E { reg.append(Character(UnicodeScalar(t[k]))) }; k += 1 }
        var ack = ""
        ack = t[k] == 0x15 ? "NAK" : String(UnicodeScalar(t[k]))
        k += 1
        var label = String(UnicodeScalar(t[k])); k += 1
        label.append(t[k] == 0x7F ? "d" : Character(UnicodeScalar(t[k]))); k += 1
        let bid: Character = t[k] == 0 ? " " : Character(UnicodeScalar(t[k])); k += 1
        let down = bid.isNumber
        var text = ""
        var number: String?, flight: String?
        if k < end {
            guard t[k] == 0x02 else { return nil }
            k += 1
            if down {
                guard end - k >= 10 else { return nil }
                number = String(decoding: t[k..<(k + 4)], as: UTF8.self)
                flight = String(decoding: t[(k + 4)..<(k + 10)], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                k += 10
            }
            while k < end {
                let c = t[k]
                if c == 0x0A { text.append("\n") } else if c == 0x0D { text += "" } else if c == 0 { text.append(".") } else if c >= 0x20 { text.append(Character(UnicodeScalar(c))) }
                k += 1
            }
        } else if down { return nil }
        return ACARSMessage(time: time, mode: mode, registration: reg, ack: ack, label: label, blockID: bid, isDownlink: down, messageNumber: number,
                            flightID: flight, text: text, continues: last == 0x17, parityErrors: 0, corrected: 0, levelDB: levelDB)
    }
}
