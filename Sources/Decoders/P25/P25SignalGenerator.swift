// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Sendeseite von P25 Phase 1 für Tests und Prüfstände: Einheiten (HDU, LDU1, LDU2, TDU, TDULC) zu Symbolen (Pegel ±1, ±3); das Audio
// entsteht mit `FourFSKModulator` bei 4800 Symbolen/s.

public enum P25SignalGenerator {
    /// 88 Nutzbits (u0 … u3 je 12, u4 … u6 je 11, u7 7 Bit) → 144 Bit der Funkstrecke (Golay, Hamming, Verwürfelung, Verschachtelung)
    public static func imbeAir(info: [UInt8]) -> [UInt8] {
        precondition(info.count == 88)
        func value(_ from: Int, _ n: Int) -> Int { info[from..<(from + n)].reduce(0) { ($0 << 1) | Int($1 & 1) } }
        var u: [Int] = []
        var p = 0
        for n in [12, 12, 12, 12, 11, 11, 11, 7] { u.append(value(p, n)); p += n }
        // Verwürfelungsfolge aus u0
        var pr = [Int](repeating: 0, count: 115)
        pr[0] = (16 * u[0]) & 0xFFFF
        for i in 1..<115 { pr[i] = (173 * pr[i - 1] + 13849) & 0xFFFF }
        let m = pr.map { UInt8($0 >> 15) }
        var fr = [[UInt8]](repeating: [UInt8](repeating: 0, count: 23), count: 8)
        var offset = 1
        for i in 0..<4 {
            let cw = Golay.encode23(u[i])
            for j in 0..<23 {
                let bit = UInt8((cw >> j) & 1)
                fr[i][j] = i == 0 ? bit : bit ^ m[offset + (22 - j)]
            }
            if i > 0 { offset += 23 }
        }
        for i in 4...6 {
            let data = u[i]
            var block = data << 4
            for (k, mask) in [0x7f08, 0x78e4, 0x66d2, 0x55b1].enumerated() where ((block & mask & ~0xF).nonzeroBitCount & 1) != 0 { block |= 1 << (3 - k) }
            for j in 0..<15 { fr[i][j] = UInt8((block >> j) & 1) ^ m[offset + (14 - j)] }
            offset += 15
        }
        for j in 0..<7 { fr[7][j] = UInt8((u[7] >> j) & 1) }
        return P25IMBE.air(fromVectors: fr)
    }

    private static func dibits(_ bits: [UInt8]) -> [UInt8] {
        stride(from: 0, to: bits.count - 1, by: 2).map { (bits[$0] << 1) | bits[$0 + 1] }
    }

    private static func bits(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (n - 1 - $0)) & 1) } }

    /// Inhaltsdibits (ohne Statussymbole) → Pegel mit eingefügten Statussymbolen (Rahmenende = Statussymbol)
    private static func levels(content: [UInt8]) -> [Float] {
        var out: [Float] = []
        for (k, d) in content.enumerated() {
            if k > 0 && k % 35 == 0 { out.append(FourFSK.level(ofDibit: 1)) }
            out.append(FourFSK.level(ofDibit: d))
        }
        out.append(FourFSK.level(ofDibit: 1))
        return out
    }

    private static func header(nac: Int, duid: P25.DUID) -> [UInt8] {
        let fs = P25.fs.map { UInt8($0 > 0 ? 1 : 3) }
        var nid = P25Codes.bchEncode((nac << 4) | duid.rawValue)
        nid.append(0)                                                           // Paritätsbit
        return fs + dibits(nid)
    }

    private static func hexWords(_ bits: [UInt8]) -> [UInt8] {
        stride(from: 0, to: bits.count, by: 6).map { UInt8(bits[$0..<($0 + 6)].reduce(0) { ($0 << 1) | Int($1) }) }
    }

    private static func hammingDibits(_ words: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        for w in words {
            let hex = bits(Int(w), 6)
            out += dibits(hex + P25Codes.hammingParity(hex))
        }
        return out
    }

    /// LDU1 (mit Linksteuerung) oder LDU2 (mit Verschlüsselungsdaten): 864 Symbole
    /// - Parameters:
    ///   - frames: neun IMBE-Rahmen (je 18 Byte)
    ///   - payloadBits: 72 Bit LC (LDU1) oder 96 Bit MI, Algorithmus, Schlüssel (LDU2)
    public static func ldu(first: Bool, nac: Int, frames: [[UInt8]], payloadBits: [UInt8]) -> [Float] {
        precondition(frames.count == 9 && frames.allSatisfy { $0.count == 18 })
        let rs = first ? P25RS.rs24_12_13 : P25RS.rs24_16_9
        precondition(payloadBits.count == rs.k * 6)
        let data = hexWords(payloadBits)
        let words = data + rs.parity(of: data)
        var content = header(nac: nac, duid: first ? .ldu1 : .ldu2)
        for i in 0..<9 {
            content += dibits(P25IMBE.bits(fromBytes: frames[i]))
            if (1...6).contains(i) { content += hammingDibits(words[((i - 1) * 4)..<((i - 1) * 4 + 4)]) }
            if i == 7 { content += [UInt8](repeating: 0, count: 16) }
        }
        return levels(content: content)
    }

    public static func hdu(nac: Int, mi: [UInt8], mfid: Int, algorithm: Int, keyID: Int, group: Int) -> [Float] {
        precondition(mi.count == 72)
        let payload = mi + bits(mfid, 8) + bits(algorithm, 8) + bits(keyID, 16) + bits(group, 16)
        let data = hexWords(payload)
        let words = data + P25RS.rs36_20_17.parity(of: data)
        var content = header(nac: nac, duid: .hdu)
        for w in words {
            content += dibits(bits(Int(w), 6) + P25Codes.golayParity(Int(w), dataBits: 6))
        }
        content += [UInt8](repeating: 0, count: 5)
        return levels(content: content)
    }

    public static func tdu(nac: Int) -> [Float] {
        levels(content: header(nac: nac, duid: .tdu) + [UInt8](repeating: 0, count: 14))
    }

    public static func tdulc(nac: Int, lc: [UInt8]) -> [Float] {
        precondition(lc.count == 72)
        let data = hexWords(lc)
        let words = data + P25RS.rs24_12_13.parity(of: data)
        let stream = words.flatMap { bits(Int($0), 6) }
        var content = header(nac: nac, duid: .tdulc)
        for w in 0..<12 {
            let v = stream[(w * 12)..<(w * 12 + 12)].reduce(0) { ($0 << 1) | Int($1) }
            content += dibits(bits(v, 12) + P25Codes.golayParity(v, dataBits: 12))
        }
        content += [UInt8](repeating: 0, count: 10)
        return levels(content: content)
    }

    /// Linksteuerung „Gruppenruf“ (72 Bit)
    public static func groupCallLC(group: Int, source: Int, emergency: Bool = false, encrypted: Bool = false, mfid: Int = 0) -> [UInt8] {
        let svc = (emergency ? 0x80 : 0) | (encrypted ? 0x40 : 0)
        return bits(0x00, 8) + bits(mfid, 8) + bits(svc, 8) + bits(0, 8) + bits(group, 16) + bits(source, 24)
    }

    public static func unitCallLC(target: Int, source: Int) -> [UInt8] {
        bits(0x03, 8) + bits(0, 8) + bits(0, 8) + bits(target, 24) + bits(source, 24)
    }

    /// Ein Gespräch: HDU, abwechselnd LDU1 und LDU2 (je neun Sprachrahmen), zum Schluss TDU oder TDULC
    /// - Parameter frames: IMBE-Rahmen (je 18 Byte); ein Vielfaches von 18 wird verwendet (der Rest mit dem letzten aufgefüllt)
    public static func call(nac: Int, group: Int, source: Int, frames: [[UInt8]], algorithm: Int = 0x80, keyID: Int = 0, mi: [UInt8]? = nil,
                            emergency: Bool = false, mfid: Int = 0 /* im HDU */, withHeader: Bool = true, ending: P25.DUID? = .tdu) -> [Float] {
        var padded = frames
        while padded.isEmpty || padded.count % 18 != 0 { padded.append(padded.last ?? [UInt8](repeating: 0, count: 18)) }
        let miBits = mi ?? [UInt8](repeating: 0, count: 72)
        var out: [Float] = []
        if withHeader { out += hdu(nac: nac, mi: miBits, mfid: mfid, algorithm: algorithm, keyID: keyID, group: group) }
        let essBits = miBits + bits(algorithm, 8) + bits(keyID, 16)
        let lc = groupCallLC(group: group, source: source, emergency: emergency, encrypted: algorithm != 0x80)
        for u in 0..<(padded.count / 9) {
            let slice = Array(padded[(u * 9)..<(u * 9 + 9)])
            out += u % 2 == 0 ? ldu(first: true, nac: nac, frames: slice, payloadBits: lc) : ldu(first: false, nac: nac, frames: slice, payloadBits: essBits)
        }
        switch ending {
        case .tdu?: out += tdu(nac: nac)
        case .tdulc?: out += tdulc(nac: nac, lc: lc)
        default: break
        }
        return out
    }
}
