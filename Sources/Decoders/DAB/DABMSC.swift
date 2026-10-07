// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Sammelt die Symbole 4 … 75 eines Rahmens zu vier Hauptdienstkanal-Rahmen (CIF) zu je 55 296 weichen Bits
public final class DABCIFAssembler {
    /// Ein vollständiger CIF (864 Kapazitätseinheiten zu 64 Bits)
    public var onCIF: ((UnsafeBufferPointer<Int8>) -> Void)?
    private var buffer = [Int8](repeating: 0, count: DABMode1.cifBits)
    private static let symbolsPerCIF = 18

    public init() {}

    public func process(symbol: Int, bits: UnsafeBufferPointer<Int8>) {
        guard symbol >= 4 else { return }
        let index = (symbol - 4) % Self.symbolsPerCIF
        let offset = index * DABMode1.bitsPerSymbol
        for i in 0..<DABMode1.bitsPerSymbol { buffer[offset + i] = bits[i] }
        if index == Self.symbolsPerCIF - 1 {
            buffer.withUnsafeBufferPointer { onCIF?($0) }
        }
    }
}

/// Entpunktieren, Faltungsdecoder und Energieentwirrung eines Teilkanals (Abschnitt 11.3)
public final class DABProtectionDecoder {
    public let bitrate: Int
    private let viterbi = DABViterbi()
    /// Abschnitte (Anzahl 128er-Blöcke, Punktierungsmuster)
    fileprivate(set) var segments: [(count: Int, pattern: [UInt8])] = []
    private let prbs: [UInt8]
    private var input: [Int8]
    /// Zahl der Eingangswerte (Länge des Teilkanals in Bits)
    public let inputBits: Int

    public init?(subchannel: DABSubchannel) {
        let bitrate = subchannel.bitrate
        self.bitrate = bitrate
        guard bitrate > 0 else { return nil }
        let pi = { (n: Int) -> [UInt8] in DABTables.puncture[n - 1] }
        switch subchannel.protection {
        case .uep(let tableIndex):
            guard tableIndex < DABTables.uepIndex.count else { return nil }
            let level = DABTables.uepIndex[tableIndex].level
            guard let p = DABTables.uepProfiles.first(where: { $0.bitrate == bitrate && $0.level == level }) else { return nil }
            segments = [(p.l1, pi(p.pi1)), (p.l2, pi(p.pi2)), (p.l3, pi(p.pi3))]
            if p.pi4 > 0 { segments.append((p.l4, pi(p.pi4))) }
        case .eep(let b, let level):
            let l1: Int, l2: Int, p1: Int, p2: Int
            if !b {
                switch level {
                case 1: l1 = 6 * bitrate / 8 - 3; l2 = 3; p1 = 24; p2 = 23
                case 2:
                    if bitrate == 8 { l1 = 5; l2 = 1; p1 = 13; p2 = 12 } else { l1 = 2 * bitrate / 8 - 3; l2 = 4 * bitrate / 8 + 3; p1 = 14; p2 = 13 }
                case 3: l1 = 6 * bitrate / 8 - 3; l2 = 3; p1 = 8; p2 = 7
                case 4: l1 = 4 * bitrate / 8 - 3; l2 = 2 * bitrate / 8 + 3; p1 = 3; p2 = 2
                default: return nil
                }
            } else {
                l1 = 24 * bitrate / 32 - 3; l2 = 3
                switch level {
                case 1: p1 = 10; p2 = 9
                case 2: p1 = 6; p2 = 5
                case 3: p1 = 4; p2 = 3
                case 4: p1 = 2; p2 = 1
                default: return nil
                }
            }
            segments = [(l1, pi(p1)), (l2, pi(p2))]
        }
        prbs = DABTables.energyDispersal(count: 24 * bitrate)
        input = [Int8](repeating: 0, count: (24 * bitrate + 6) * 4)
        inputBits = subchannel.length * DABMode1.cuBits
        // Die Entpunktierung muss genau die Länge des Teilkanals verbrauchen, sonst ist die Tabelle für diese Kombination nicht verlässlich
        if consumed != inputBits { return nil }
    }

    /// Bits, die die Entpunktierung aus dem Teilkanal nimmt
    private var consumed: Int {
        var take = 0
        for seg in segments { for _ in 0..<seg.count { for j in 0..<128 where seg.pattern[j % 32] != 0 { take += 1 } } }
        for k in 0..<24 where DABTables.punctureTail[k] != 0 { take += 1 }
        return take
    }

    /// Ein zeitentschachtelter Teilkanal-Rahmen (`inputBits` weiche Bits) → 24 · Datenrate Bits (als Bytes gepackt)
    public func decode(_ soft: UnsafeBufferPointer<Int8>) -> [UInt8] {
        for i in 0..<input.count { input[i] = 0 }
        var take = 0, put = 0
        for seg in segments {
            for _ in 0..<seg.count {
                for j in 0..<128 {
                    if seg.pattern[j % 32] != 0 {
                        if take < soft.count { input[put] = soft[take] }
                        take += 1
                    }
                    put += 1
                }
            }
        }
        for k in 0..<24 {
            if DABTables.punctureTail[k] != 0 {
                if take < soft.count { input[put] = soft[take] }
                take += 1
            }
            put += 1
        }
        let n = 24 * bitrate
        let bits = input.withUnsafeBufferPointer { viterbi.decode(soft: $0, bitCount: n) }
        var bytes = [UInt8](repeating: 0, count: n / 8)
        for i in 0..<n { bytes[i / 8] |= (bits[i] ^ prbs[i]) << UInt8(7 - i % 8) }
        return bytes
    }
}

/// Zeitentschachtelung (16 CIF) und Dekodierung eines Teilkanals aus den CIF
public final class DABSubchannelDecoder {
    public let subchannel: DABSubchannel
    /// Ein Teilkanal-Rahmen (24 ms) mit 3 · Datenrate Bytes
    public var onFrame: (([UInt8]) -> Void)?
    private let protection: DABProtectionDecoder
    private var history: [[Int8]]
    private var index = 0
    private var filled = 0
    private let fragment: Int
    private var deinterleaved: [Int8]

    public init?(subchannel: DABSubchannel) {
        guard let p = DABProtectionDecoder(subchannel: subchannel) else { return nil }
        self.subchannel = subchannel
        protection = p
        fragment = subchannel.length * DABMode1.cuBits
        history = [[Int8]](repeating: [Int8](repeating: 0, count: fragment), count: 16)
        deinterleaved = [Int8](repeating: 0, count: fragment)
    }

    /// Ein CIF (alle 864 CU)
    public func process(cif: UnsafeBufferPointer<Int8>) {
        let start = subchannel.startAddress * DABMode1.cuBits
        guard start + fragment <= cif.count else { return }
        let map = DABTables.interleaveMap
        for i in 0..<fragment {
            deinterleaved[i] = history[(index + map[i & 15]) & 15][i]
            history[index][i] = cif[start + i]
        }
        index = (index + 1) & 15
        if filled < 16 { filled += 1; return }
        let frame = deinterleaved.withUnsafeBufferPointer { protection.decode($0) }
        onFrame?(frame)
    }
}

/// Reed-Solomon (120, 110) über GF(256), Polynom 0x11D, erste Nullstelle α⁰ (DAB+-Überrahmen)
final class DABReedSolomon {
    private var exp = [UInt8](repeating: 0, count: 512)
    private var log = [Int](repeating: 0, count: 256)
    private let roots = 10

    init() {
        var x = 1
        for i in 0..<255 {
            exp[i] = UInt8(x); log[x] = i
            x <<= 1
            if x & 0x100 != 0 { x ^= 0x11D }
        }
        for i in 255..<512 { exp[i] = exp[i - 255] }
    }

    @inline(__always) private func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        a == 0 || b == 0 ? 0 : exp[log[Int(a)] + log[Int(b)]]
    }

    /// Korrigiert `data` (120 Bytes) und gibt die Zahl der Korrekturen zurück, −1 wenn nicht korrigierbar
    func decode(_ data: inout [UInt8]) -> Int {
        let n = 120
        // Syndrome S_j = r(α^j)
        var s = [UInt8](repeating: 0, count: roots)
        var clean = true
        for j in 0..<roots {
            var acc: UInt8 = 0
            for i in 0..<n { acc = mul(acc, exp[j]) ^ data[i] }          // Horner, höchste Potenz zuerst
            s[j] = acc
            if acc != 0 { clean = false }
        }
        if clean { return 0 }
        // Berlekamp-Massey
        var lambda = [UInt8](repeating: 0, count: roots + 1); lambda[0] = 1
        var b = [UInt8](repeating: 0, count: roots + 1); b[0] = 1
        var l = 0, m = 1
        var bb: UInt8 = 1
        for r in 0..<roots {
            var d = s[r]
            if l >= 1 { for i in 1...l where i <= r { d ^= mul(lambda[i], s[r - i]) } }
            if d == 0 { m += 1; continue }
            let t = lambda
            let coef = mul(d, exp[255 - log[Int(bb)]])
            for i in 0..<(roots + 1 - m) { lambda[i + m] ^= mul(coef, b[i]) }
            if 2 * l <= r { l = r + 1 - l; b = t; bb = d; m = 1 } else { m += 1 }
        }
        if l > roots / 2 { return -1 }
        // Nullstellen suchen (Chien): Position p ↔ Potenz n−1−p
        var errPos = [Int]()
        for p in 0..<n {
            let power = n - 1 - p
            let xinv = exp[(255 - power) % 255]
            var v: UInt8 = 0
            var xp: UInt8 = 1
            for i in 0...l { v ^= mul(lambda[i], xp); xp = mul(xp, xinv) }
            if v == 0 { errPos.append(p) }
        }
        if errPos.count != l { return -1 }
        // Fehlerwerte nach Forney: Ω(x) = S(x)·Λ(x) mod x^roots
        var omega = [UInt8](repeating: 0, count: roots)
        for i in 0..<roots {
            var acc: UInt8 = 0
            for j in 0...min(i, l) { acc ^= mul(lambda[j], s[i - j]) }
            omega[i] = acc
        }
        for p in errPos {
            let power = n - 1 - p
            let xinv = exp[(255 - power) % 255]
            var num: UInt8 = 0
            var xp: UInt8 = 1
            for i in 0..<roots { num ^= mul(omega[i], xp); xp = mul(xp, xinv) }
            // Λ'(x): nur ungerade Potenzen
            var den: UInt8 = 0
            xp = 1
            var i = 1
            while i <= l {
                // Beitrag lambda[i] * i * x^(i-1); in Charakteristik 2 zählt nur ungerades i
                var xq: UInt8 = 1
                for _ in 0..<(i - 1) { xq = mul(xq, xinv) }
                if i % 2 == 1 { den ^= mul(lambda[i], xq) }
                i += 1
            }
            guard den != 0 else { return -1 }
            // Bei erster Nullstelle α⁰: e = X^(1−fcr) · Ω(X⁻¹)/Λ'(X⁻¹) mit fcr = 0 → X · …
            let x = exp[power % 255]
            let value = mul(mul(num, x), exp[255 - log[Int(den)]])
            data[p] ^= value
        }
        // Gegenprobe
        for j in 0..<roots {
            var acc: UInt8 = 0
            for i in 0..<n { acc = mul(acc, exp[j]) ^ data[i] }
            if acc != 0 { return -1 }
        }
        return errPos.count
    }
}

/// Format eines DAB+-Dienstes aus dem Kopf des Überrahmens
public struct DABAudioFormat: Equatable, Sendable {
    public var dacRate48k: Bool
    public var sbr: Bool
    public var stereo: Bool
    public var ps: Bool
    public var surround: Int

    public var codecName: String { sbr ? (ps ? "HE-AAC v2" : "HE-AAC") : "AAC-LC" }
    public var channelsText: String { (stereo || ps) ? "Stereo" : "Mono" }
    /// Abtastrate des AAC-Kerns (Hz)
    public var coreRate: Int { dacRate48k ? (sbr ? 24_000 : 48_000) : (sbr ? 16_000 : 32_000) }
    public var outputRate: Int { dacRate48k ? 48_000 : 32_000 }

    var coreRateIndex: Int {
        switch coreRate { case 16_000: return 8; case 24_000: return 6; case 32_000: return 5; default: return 3 }
    }
    var extensionRateIndex: Int { dacRate48k ? 3 : 5 }
    var coreChannelConfig: Int { (stereo && !ps) ? 2 : 1 }

    /// AudioSpecificConfig mit 960er-Transformation (und SBR/PS ausdrücklich angezeigt) für den AAC-Decoder
    var audioSpecificConfig: [UInt8] {
        var asc: [UInt8] = [UInt8(0b00010 << 3 | coreRateIndex >> 1), UInt8((coreRateIndex & 1) << 7 | coreChannelConfig << 3 | 0b100)]
        if sbr {
            asc.append(0x56)
            asc.append(0xE5)
            asc.append(UInt8(0x80 | (extensionRateIndex << 3)))
            if ps {
                asc[asc.count - 1] |= 0x05
                asc.append(0x48)
                asc.append(0x80)
            }
        }
        return asc
    }
}

/// DAB+: fünf Teilkanal-Rahmen (120 ms) zu einem Überrahmen, Feuercode, Reed-Solomon, Aufteilung in Audio-Zugriffseinheiten
public final class DABSuperframeDecoder {
    /// Eine Zugriffseinheit (ohne CRC) und das Format
    public var onAU: (([UInt8], DABAudioFormat) -> Void)?
    public var onFormat: ((DABAudioFormat) -> Void)?

    public private(set) var superframes = 0
    public private(set) var syncedSuperframes = 0
    public private(set) var correctedBytes = 0
    public private(set) var uncorrectable = 0
    public private(set) var badAUs = 0
    public private(set) var isSynced = false
    public private(set) var format: DABAudioFormat?

    private let rs = DABReedSolomon()
    private var frames: [[UInt8]] = []
    private var frameLength = 0

    public init() {}

    public func reset() { frames.removeAll(); isSynced = false }

    public func feed(frame: [UInt8]) {
        if frameLength != frame.count { frameLength = frame.count; frames.removeAll() }
        guard frameLength > 0, (5 * frameLength) % 120 == 0 else { return }
        frames.append(frame)
        if frames.count > 5 { frames.removeFirst(frames.count - 5) }
        guard frames.count == 5 else { return }
        var sf = frames.flatMap { $0 }
        let blocks = sf.count / 120
        // Reed-Solomon je Block (verschachtelt)
        var corrected = 0
        var failed = false
        var packet = [UInt8](repeating: 0, count: 120)
        for i in 0..<blocks {
            for pos in 0..<120 { packet[pos] = sf[pos * blocks + i] }
            let r = rs.decode(&packet)
            if r < 0 { failed = true } else if r > 0 {
                corrected += r
                for pos in 0..<120 { sf[pos * blocks + i] = packet[pos] }
            }
        }
        guard let parsed = parseHeader(sf) else {
            isSynced = false
            return                        // kein Takt: beim nächsten Rahmen mit verschobenem Fenster erneut versuchen
        }
        isSynced = true
        superframes += 1
        syncedSuperframes += 1
        if failed { uncorrectable += 1 }
        correctedBytes += corrected
        frames.removeAll()                 // den nächsten Überrahmen ganz neu sammeln
        if parsed.format != format { format = parsed.format; onFormat?(parsed.format) }
        let starts = parsed.starts
        for i in 0..<(starts.count - 1) {
            let au = Array(sf[starts[i]..<starts[i + 1]])
            guard au.count > 2 else { continue }
            let stored = UInt16(au[au.count - 2]) << 8 | UInt16(au[au.count - 1])
            let calc = DABCRC.crc16(Array(au[0..<(au.count - 2)]))
            if stored != calc { badAUs += 1; continue }
            onAU?(Array(au[0..<(au.count - 2)]), parsed.format)
        }
    }

    private func parseHeader(_ sf: [UInt8]) -> (format: DABAudioFormat, starts: [Int])? {
        guard sf.count > 12 else { return nil }
        if sf[3] == 0 && sf[4] == 0 { return nil }
        let stored = UInt16(sf[0]) << 8 | UInt16(sf[1])
        let calc = sf[2..<11].withUnsafeBufferPointer { DABCRC.fireCode($0) }
        guard stored == calc else { return nil }
        let f = DABAudioFormat(dacRate48k: sf[2] & 0x40 != 0, sbr: sf[2] & 0x20 != 0, stereo: sf[2] & 0x10 != 0, ps: sf[2] & 0x08 != 0, surround: Int(sf[2] & 0x07))
        let count = f.dacRate48k ? (f.sbr ? 3 : 6) : (f.sbr ? 2 : 4)
        var starts = [Int](repeating: 0, count: count + 1)
        starts[0] = f.dacRate48k ? (f.sbr ? 6 : 11) : (f.sbr ? 5 : 8)
        starts[count] = sf.count / 120 * 110
        starts[1] = Int(sf[3]) << 4 | Int(sf[4]) >> 4
        if count >= 3 { starts[2] = (Int(sf[4]) & 0x0F) << 8 | Int(sf[5]) }
        if count >= 4 { starts[3] = Int(sf[6]) << 4 | Int(sf[7]) >> 4 }
        if count == 6 {
            starts[4] = (Int(sf[7]) & 0x0F) << 8 | Int(sf[8])
            starts[5] = Int(sf[9]) << 4 | Int(sf[10]) >> 4
        }
        for i in 0..<count where starts[i] >= starts[i + 1] { return nil }
        return (f, starts)
    }
}
