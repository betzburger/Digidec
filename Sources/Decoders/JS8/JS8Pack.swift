// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Rahmen packen: Gegenstück zu JS8Varicode.unpack, nur für Tests und die Gegenprobe (Digidec sendet nie).
// Nach Varicode aus JS8Call (C) 2018 Jordan Sherer KN4CRD, GPLv3.

extension JS8Varicode {
    private static func bits(_ value: UInt64, _ count: Int) -> [UInt8] {
        (0..<count).map { UInt8((value >> UInt64(count - 1 - $0)) & 1) }
    }

    private static func frame(_ bits: [UInt8]) -> String? {
        guard bits.count == 72 else { return nil }
        var out = ""
        for i in 0..<12 {
            var v = 0
            for j in 0..<6 { v = (v << 1) | Int(bits[i * 6 + j]) }
            out.append(frameAlphabet[v])
        }
        return out
    }

    static func alnumIndex(_ c: Character) -> Int? { alphanumeric.firstIndex(of: c) }

    /// 28-Bit-Wert eines Rufzeichens (oder einer Gruppe); nil, wenn es nicht passt. `portable` meldet „/P“.
    public static func packCallsign(_ value: String, portable: inout Bool) -> UInt32? {
        var call = value.uppercased().trimmingCharacters(in: .whitespaces)
        if let i = baseCalls.firstIndex(of: call) { return nbasecall + UInt32(i) + 1 }
        if call.hasSuffix("/P") {
            call = String(call.dropLast(2))
            portable = true
        }
        if call.hasPrefix("3DA0") { call = "3D0" + call.dropFirst(4) }
        if call.hasPrefix("3X"), let c = call.dropFirst(2).first, ("A"..."Z").contains(c) { call = "Q" + call.dropFirst(2) }
        guard call.count >= 2, call.count <= 6 else { return nil }
        var candidates = [call]
        switch call.count {
        case 2: candidates.append(" " + call + "   ")
        case 3: candidates += [" " + call + "  ", call + "   "]
        case 4: candidates += [" " + call + " ", call + "  "]
        case 5: candidates += [" " + call, call + " "]
        default: break
        }
        // Muster: ([0-9A-Z ])([0-9A-Z])([0-9])([A-Z ])([A-Z ])([A-Z ]); der letzte passende Kandidat gilt
        func matches(_ s: [Character]) -> Bool {
            guard s.count == 6 else { return false }
            func alnum(_ c: Character) -> Bool { ("0"..."9").contains(c) || ("A"..."Z").contains(c) }
            func letter(_ c: Character) -> Bool { ("A"..."Z").contains(c) || c == " " }
            return (alnum(s[0]) || s[0] == " ") && alnum(s[1]) && ("0"..."9").contains(s[2]) && letter(s[3]) && letter(s[4]) && letter(s[5])
        }
        guard let matched = candidates.map(Array.init).last(where: matches),
              let i0 = alnumIndex(matched[0]), let i1 = alnumIndex(matched[1]), let i2 = alnumIndex(matched[2]),
              let i3 = alnumIndex(matched[3]), let i4 = alnumIndex(matched[4]), let i5 = alnumIndex(matched[5]) else { return nil }
        var packed = UInt32(i0)
        packed = 36 * packed + UInt32(i1)
        packed = 10 * packed + UInt32(i2)
        packed = 27 * packed + UInt32(i3) - 10
        packed = 27 * packed + UInt32(i4) - 10
        packed = 27 * packed + UInt32(i5) - 10
        return packed
    }

    /// Rufzeichen mit Zusätzen für Heartbeat und Compound (50 Bit); 0, wenn es nicht passt
    public static func packAlphaNumeric50(_ value: String) -> UInt64 {
        var word = value.filter { alphanumeric.contains($0) }
        func insert(_ i: Int) {
            if word.count > i, Array(word)[i] != "/" { word.insert(" ", at: word.index(word.startIndex, offsetBy: i)) }
        }
        insert(3)
        insert(7)
        while word.count < 11 { word.append(" ") }
        let w = Array(word.prefix(11))
        guard let a = alnumIndex(w[0]), let b = alnumIndex(w[1]), let c = alnumIndex(w[2]), let e = alnumIndex(w[4]),
              let f = alnumIndex(w[5]), let g = alnumIndex(w[6]), let i = alnumIndex(w[8]), let j = alnumIndex(w[9]),
              let k = alnumIndex(w[10]) else { return 0 }
        let d38: UInt64 = 38 * 38 * 38
        var packed: UInt64 = 0
        packed += d38 * 2 * d38 * 2 * 38 * 38 * UInt64(a)
        packed += d38 * 2 * d38 * 2 * 38 * UInt64(b)
        packed += d38 * 2 * d38 * 2 * UInt64(c)
        packed += d38 * 2 * d38 * (w[3] == "/" ? 1 : 0)
        packed += d38 * 2 * 38 * 38 * UInt64(e)
        packed += d38 * 2 * 38 * UInt64(f)
        packed += d38 * 2 * UInt64(g)
        packed += d38 * (w[7] == "/" ? 1 : 0)
        packed += 38 * 38 * UInt64(i)
        packed += 38 * UInt64(j)
        packed += UInt64(k)
        return packed
    }

    /// Locator (4 Stellen) als 15-Bit-Wert, 32767 („leer“) bei ungültigem
    public static func packGrid(_ value: String) -> UInt32 {
        let g = Array(value.uppercased())
        guard g.count >= 4, ("A"..."R").contains(g[0]), ("A"..."R").contains(g[1]), g[2].isNumber, g[3].isNumber else { return nmaxgrid }
        func off(_ c: Character, _ base: Character) -> Int { Int(c.asciiValue!) - Int(base.asciiValue!) }
        let nlong = 180 - 20 * off(g[0], "A")
        let n20d = 2 * off(g[2], "0")
        let xminlong = 5.0 * (12.0 + 0.5)
        let dlong = Double(nlong - n20d) - xminlong / 60.0
        let nlat = -90 + 10 * off(g[1], "A") + off(g[3], "0")
        let xminlat = 2.5 * (12.0 + 0.5)
        let dlat = Double(nlat) + xminlat / 60.0
        let ilong = Int(dlong)
        let ilat = Int(dlat + 90)
        return UInt32(((ilong + 180) / 2) * 180 + ilat)
    }

    /// Heartbeat („HB“) oder, mit `cq` 0…7, CQ-Ruf („CQ CQ CQ“ … „CQ“), optional mit Locator
    public static func packHeartbeat(call: String, grid: String? = nil, cq: Int? = nil) -> String? {
        var extra = grid.map(packGrid) ?? nmaxgrid
        if cq != nil { extra |= 1 << 15 }
        return packCompound(kind: 0, call: call, extra: extra, bits3: UInt8(cq ?? 0))
    }

    /// Rufzeichen mit Zusatz (Art 1), optional mit Locator
    public static func packCompoundCall(_ call: String, grid: String? = nil) -> String? {
        packCompound(kind: 1, call: call, extra: grid.map(packGrid) ?? nmaxgrid, bits3: 0)
    }

    /// Rufzeichen mit Befehl und Zahl (Art 2); bei „ SNR“ und „ HEARTBEAT SNR“ gehört die SNR in den Rahmen
    public static func packCompoundDirected(_ call: String, command: Int, snr: Int? = nil) -> String? {
        var value: UInt32
        if snrCommands.contains(command), let snr {
            let n = UInt32(max(-30, min(snr, 31)) + 31)
            value = ((1 << 1) | (command == 29 ? 1 : 0)) << 6
            value += n & 63
        } else {
            value = UInt32(command & 127)
        }
        return packCompound(kind: 2, call: call, extra: nusergrid + value, bits3: 0)
    }

    private static func packCompound(kind: UInt8, call: String, extra: UInt32, bits3: UInt8) -> String? {
        let packedCall = packAlphaNumeric50(call)
        guard packedCall != 0 else { return nil }
        let packed11 = UInt64((extra & 0xFFE0) >> 5)
        let packed5 = UInt64(extra & 0x1F)
        let all = bits(UInt64(kind), 3) + bits(packedCall, 50) + bits(packed11, 11) + bits(packed5, 5) + bits(UInt64(bits3), 3)
        return frame(all)
    }

    /// Befehl an eine Station, z. B. „DL1ABC: DL2XYZ ACK“; `number` ist die Zahl (SNR bei Befehl 25 und 29)
    public static func packDirected(from: String, to: String, command: Int, number: Int? = nil) -> String? {
        var pf = false
        var pt = false
        guard let f = packCallsign(from, portable: &pf), let t = packCallsign(to, portable: &pt) else { return nil }
        let n = number.map { max(-30, min($0, 31)) + 31 } ?? 0
        let extra = (pf ? 128 : 0) + (pt ? 64 : 0) + n
        let all = bits(3, 3) + bits(UInt64(f), 28) + bits(UInt64(t), 28) + bits(UInt64(command % 32), 5) + bits(UInt64(extra), 8)
        return frame(all)
    }

    /// Alter Datenrahmen mit Huffman-Text (nur Zeichen der Tabelle); nil, wenn Zeichen fehlen
    public static func packHuffmanText(_ text: String) -> String? {
        let table = Dictionary(uniqueKeysWithValues: huffman.map { ($0.0, $0.1) })
        var content: [UInt8] = [1, 0]   // Datenrahmen, nicht komprimiert
        for ch in text.uppercased() {
            guard let code = table[String(ch)] else { return nil }
            let next = content + code.map { $0 == "1" ? UInt8(1) : 0 }
            if next.count > 71 { break }   // mindestens eine 0 zum Auffüllen muss bleiben
            content = next
        }
        // Auffüllen: eine 0, dann lauter 1
        var all = content
        var first = true
        while all.count < 72 { all.append(first ? 0 : 1); first = false }
        return frame(all)
    }
}
