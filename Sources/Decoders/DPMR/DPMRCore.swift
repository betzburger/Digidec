// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// dPMR (digital Private Mobile Radio, ETSI TS 102 658, Stufe 1, FDMA 6,25 kHz): 4FSK mit 2400 Symbolen/s (Pegel ±1, ±3 wie DMR),
// Sprache mit dem AMBE+2-Codec wie DMR/YSF (72 Kanalbits je 20 ms, gleiche Bitreihenfolge).
//
// Aufbau der Sprachübertragung (Betriebsart 1): Nutzrahmen zu 80 ms (192 Symbole). Ein Nutzrahmen besteht aus einem Steuerkanal CCH
// (36 Symbole = 72 Bit) und vier Sprachrahmen TCH (je 36 Symbole), davor steht abwechselnd das Synchronwort FS2 (12 Symbole) oder der
// Kanalcode CC (12 Symbole, 24 Bit). Der Empfänger liest nach jedem FS2 zwei Nutzrahmen zu 372 Symbolen:
//   CCH₀, TCH₀ … TCH₃, CC, CCH₁, TCH₄ … TCH₇ (acht Sprachrahmen = 160 ms).
// Der CCH trägt 48 Bit (Rahmennummer 2, Teil der Kennung 12, Betriebsart 3, Version 2, Format 2, Notruf 1, Reserve 1, Langsamdaten 18,
// CRC-7): sechs Hamming-Wörter (12,8), 6×12 verschachtelt, mit x⁹ + x⁵ + 1 verwürfelt (Startwert alle Einsen).
// Die Kennung (24 Bit) kommt aus je zwei Nutzrahmen: Rahmen 0 und 1 tragen die gerufene Kennung, 2 und 3 die rufende.

public enum DPMR {
    public static let baud = 2400.0
    public static let syncSymbols = 12
    public static let superframeSymbols = 372
    /// Pegelmuster der Synchronwörter ('1' = positiver, '3' = negativer äußerer Pegel), wie in ETSI TS 102 658
    public static let fs1 = patternSigns("111333331133131131111313")
    public static let fs2 = patternSigns("113333131331")
    public static let fs3 = patternSigns("133131333311")
    public static let fs4 = patternSigns("333111113311313313333131")

    static func patternSigns(_ s: String) -> [Float] { s.map { $0 == "1" ? 1 : -1 } }

    /// Normierte Korrelation (−1 … +1) von 12 weichen Symbolen mit einem Muster
    public static func correlation(_ symbols: ArraySlice<Float>, _ pattern: [Float]) -> Float {
        guard symbols.count == pattern.count else { return 0 }
        var sum: Float = 0
        for (s, p) in zip(symbols, pattern) { sum += max(-3, min(3, s)) * p }
        return sum / (3 * Float(pattern.count))
    }

    /// 64 Kanalcodes (24 Bit, MSB zuerst als Dibits mit lauter äußeren Pegeln): Farbcode 0 … 63
    public static let colorCodeWords: [UInt32] = [
        0x575F77, 0x577577, 0x57DD75, 0x57F775, 0x55577D, 0x557D7D, 0x55D57F, 0x55FF7F, 0x5F555F, 0x5F7F5F, 0x5FD75D, 0x5FFD5D, 0x5D5D55, 0x5D7755, 0x5DDF57, 0x5DF557,
        0x775DD7, 0x7777D7, 0x77DFD5, 0x77F5D5, 0x7555DD, 0x757FDD, 0x75D7DF, 0x75FDDF, 0x7F57FF, 0x7F7DFF, 0x7FD5FD, 0x7FFFFD, 0x7D5FF5, 0x7D75F5, 0x7DDDF7, 0x7DF7F7,
        0xD755F7, 0xD77FF7, 0xD7D7F5, 0xD7FDF5, 0xD55DFD, 0xD577FD, 0xD5DFFF, 0xD5F5FF, 0xDF5FDF, 0xDF75DF, 0xDFDDDD, 0xDFF7DD, 0xDD57D5, 0xDD7DD5, 0xDDD5D7, 0xDDFFD7,
        0xF75757, 0xF77D57, 0xF7D555, 0xF7FF55, 0xF55F5D, 0xF5755D, 0xF5DD5F, 0xF5F75F, 0xFF5D7F, 0xFF777F, 0xFFDF7D, 0xFFF57D, 0xFD5575, 0xFD7F75, 0xFDD777, 0xFDFD77,
    ]

    /// Farbcode aus den 24 Bit des Kanalcodes; jedes zweite Bit (das niedrige jedes Dibits) ist immer 1 und wird deshalb erzwungen
    public static func colorCode(ofBits bits: [UInt8]) -> Int? {
        guard bits.count == 24 else { return nil }
        let word = bits.reduce(UInt32(0)) { ($0 << 1) | UInt32($1 & 1) } | 0x555555
        return colorCodeWords.firstIndex(of: word)
    }

    public static func bits(ofColorCode code: Int) -> [UInt8] {
        let w = colorCodeWords[code & 63]
        return (0..<24).map { UInt8((w >> UInt32(23 - $0)) & 1) }
    }

    /// Kennung (24 Bit Luftschnittstelle) → sieben Zeichen: die ersten drei Stellen zur Basis 10, die letzten vier zur Basis 11 (10 = „*“)
    public static func idText(_ id: UInt32) -> String {
        var v = id
        var out = ""
        for w: UInt32 in [1_464_100, 146_410, 14_641, 1_331, 121, 11, 1] {
            let d = v / w
            v %= w
            out.append(d == 10 ? "*" : Character(UnicodeScalar(UInt8(48 + min(d, 9)))))
        }
        return out
    }

    /// Umkehrung für Prüfstände: sieben Zeichen → Kennung; `nil` bei ungültigem Text
    public static func idValue(_ text: String) -> UInt32? {
        let chars = Array(text)
        guard chars.count == 7 else { return nil }
        var v: UInt32 = 0
        for (c, w) in zip(chars, [1_464_100, 146_410, 14_641, 1_331, 121, 11, 1] as [UInt32]) {
            if c == "*" { v += 10 * w } else if let d = c.wholeNumberValue, d < 10 { v += UInt32(d) * w } else { return nil }
        }
        return v < (1 << 24) ? v : nil
    }
}

// MARK: - Codes

public enum DPMRCodes {
    /// Verwürfelung x⁹ + x⁵ + 1 (Startwert alle Einsen); Verwürfeln und Entwürfeln sind dasselbe
    public static func scramble(_ bits: [UInt8], initial: UInt16 = 0x1FF) -> [UInt8] {
        var s = (0..<9).map { UInt8((initial >> UInt16($0)) & 1) }
        return bits.map { b in
            let out = (b ^ s[0]) & 1
            let t = s[4] ^ s[0]
            for i in 0..<8 { s[i] = s[i + 1] }
            s[8] = t
            return out
        }
    }

    /// 6×12: zeilenweise lesen, spaltenweise ausgeben (Empfang); die Umkehrung sendet
    public static func deinterleave(_ bits: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 72)
        for i in 0..<12 { for j in 0..<6 { out[j * 12 + i] = bits[i * 6 + j] } }
        return out
    }

    public static func interleave(_ bits: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 72)
        for i in 0..<12 { for j in 0..<6 { out[i * 6 + j] = bits[j * 12 + i] } }
        return out
    }

    // Hamming (12,8): systematisch, vier Prüfbits; Einzelbitfehler werden korrigiert
    private static let generatorParity: [[UInt8]] = [
        [1, 1, 1, 0], [0, 1, 1, 1], [1, 0, 1, 0], [0, 1, 0, 1], [1, 0, 1, 1], [1, 1, 0, 0], [0, 1, 1, 0], [0, 0, 1, 1],
    ]
    private static let checkRows: [[UInt8]] = [
        [1, 0, 1, 0, 1, 1, 0, 0, 1, 0, 0, 0],
        [1, 1, 0, 1, 0, 1, 1, 0, 0, 1, 0, 0],
        [1, 1, 1, 0, 1, 0, 1, 1, 0, 0, 1, 0],
        [0, 1, 0, 1, 1, 0, 0, 1, 0, 0, 0, 1],
    ]
    /// Syndrom → Bitstelle (0 … 11), −1 = nicht korrigierbar
    private static let correction: [Int] = {
        var t = [Int](repeating: -1, count: 16)
        let pairs: [(Int, Int)] = [(0b1110, 0), (0b0111, 1), (0b1010, 2), (0b0101, 3), (0b1011, 4), (0b1100, 5), (0b0110, 6), (0b0011, 7), (0b1000, 8), (0b0100, 9), (0b0010, 10), (0b0001, 11)]
        for (s, p) in pairs { t[s] = p }
        return t
    }()

    public static func hammingEncode(_ data: [UInt8]) -> [UInt8] {
        var out = data
        for p in 0..<4 {
            var parity: UInt8 = 0
            for i in 0..<8 where generatorParity[i][p] == 1 { parity ^= data[i] }
            out.append(parity)
        }
        return out
    }

    /// 12 Bit → 8 Datenbits; `correctable` ist falsch bei nicht korrigierbarem Fehler, `corrected` bei einem korrigierten Bit
    public static func hammingDecode(_ word: [UInt8]) -> (data: [UInt8], correctable: Bool, corrected: Bool) {
        var r = word
        var syndrome = 0
        for row in 0..<4 {
            var p: UInt8 = 0
            for i in 0..<12 where checkRows[row][i] == 1 { p ^= r[i] }
            syndrome |= Int(p) << (3 - row)
        }
        var corrected = false
        if syndrome != 0 {
            let pos = correction[syndrome]
            if pos < 0 { return (Array(r[0..<8]), false, false) }
            r[pos] ^= 1
            corrected = true
        }
        return (Array(r[0..<8]), true, corrected)
    }

    /// CRC-7 mit x⁷ + x³ + 1 (Anfangswert 0, höchstwertiges Bit zuerst)
    public static func crc7(_ bits: ArraySlice<UInt8>) -> UInt8 {
        var reg: UInt8 = 0
        for b in bits {
            if ((reg >> 6) & 1) ^ (b & 1) != 0 { reg = ((reg << 1) ^ 0x09) & 0x7F } else { reg = (reg << 1) & 0x7F }
        }
        return reg
    }
}

// MARK: - Steuerkanal

public struct DPMRCCH: Equatable, Sendable {
    public var frameNumber: Int
    /// 12 Bit eines Teils der Kennung
    public var idPart: Int
    public var mode: Int
    public var version: Int
    public var format: Int
    public var emergency: Bool
    public var slowData: Int
    /// CRC über die ersten 41 Bit stimmt
    public var crcOK: Bool
    /// Die beiden ersten Hamming-Wörter (Rahmennummer und Kennung) waren lesbar
    public var idReadable: Bool
    /// Das erste Hamming-Wort (Rahmennummer) war lesbar
    public var numberReadable: Bool
    /// Alle sechs Wörter lesbar
    public var allReadable: Bool

    /// Rahmennummer und Kennung sind verwertbar: nur mit stimmender Prüfsumme (die Hamming-Wörter allein erkennen Zufallsdaten nicht)
    public var idUsable: Bool { crcOK }
    public var numberUsable: Bool { crcOK }
    /// Verwürfelung („Scrambler“, herstellerspezifisch): Version 3
    public var isScrambled: Bool { version == 3 }
    /// Sprachbetrieb: Betriebsart 0, 1 und 5
    public var carriesVoice: Bool { mode == 0 || mode == 1 || mode == 5 }

    /// 72 Bit des Kanals (wie empfangen) → Steuerinformation
    public static func decode(_ raw: [UInt8]) -> DPMRCCH {
        precondition(raw.count == 72)
        let descrambled = DPMRCodes.scramble(raw)
        let words = DPMRCodes.deinterleave(descrambled)
        var data: [UInt8] = []
        var readable = [Bool]()
        for w in 0..<6 {
            let r = DPMRCodes.hammingDecode(Array(words[(w * 12)..<(w * 12 + 12)]))
            data += r.data
            readable.append(r.correctable)
        }
        func value(_ from: Int, _ count: Int) -> Int { data[from..<(from + count)].reduce(0) { ($0 << 1) | Int($1) } }
        let crc = Int(DPMRCodes.crc7(data[0..<41]))
        return DPMRCCH(frameNumber: value(0, 2), idPart: value(2, 12), mode: value(14, 3), version: value(17, 2), format: value(19, 2),
                       emergency: data[21] == 1, slowData: value(23, 18), crcOK: crc == value(41, 7),
                       idReadable: readable[0] && readable[1], numberReadable: readable[0], allReadable: !readable.contains(false))
    }

    /// Steuerinformation → 72 Bit des Kanals (für Prüfstände)
    public static func encode(frameNumber: Int, idPart: Int, mode: Int = 0, version: Int = 0, format: Int = 0, emergency: Bool = false, slowData: Int = 0) -> [UInt8] {
        func bits(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (n - 1 - $0)) & 1) } }
        var data = bits(frameNumber, 2) + bits(idPart, 12) + bits(mode, 3) + bits(version, 2) + bits(format, 2) + [emergency ? 1 : 0, 0] + bits(slowData, 18)
        data += bits(Int(DPMRCodes.crc7(data[0..<41])), 7)
        var words: [UInt8] = []
        for w in 0..<6 { words += DPMRCodes.hammingEncode(Array(data[(w * 8)..<(w * 8 + 8)])) }
        return DPMRCodes.scramble(DPMRCodes.interleave(words))
    }
}

// MARK: - Symbole und Bits

public enum DPMRSymbols {
    /// Je Symbol zwei Bits (oberes zuerst) aus den weichen Werten
    public static func bits(_ symbols: ArraySlice<Float>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(symbols.count * 2)
        for s in symbols {
            let d = FourFSK.dibit(ofLevel: s)
            out.append((d >> 1) & 1); out.append(d & 1)
        }
        return out
    }

    /// Bits (paarweise) → Symbolpegel
    public static func levels(ofBits bits: [UInt8]) -> [Float] {
        stride(from: 0, to: bits.count - 1, by: 2).map { FourFSK.level(ofDibit: (bits[$0] << 1) | bits[$0 + 1]) }
    }

    public static func levels(ofPattern p: [Float]) -> [Float] { p.map { $0 * 3 } }
}

// MARK: - Diagnose

public enum DPMRDiagnosis {
    public enum Severity: Int, Sendable { case ok, waiting, problem }

    public struct Result: Equatable, Sendable {
        public var severity: Severity
        public var title: String
        public var advice: String
    }

    public static let silenceDB = -70.0

    public static func assess(inputDB: Double, stats: DPMRFramerStats, locked: Bool) -> Result {
        if inputDB < silenceDB {
            return Result(severity: .problem, title: "Kein Audio", advice: "Am Eingang kommt kein Signal an. dPMR braucht das unbearbeitete FM-Diskriminator-Audio (Packet/Daten-Ausgang des Funkgeräts oder SDR-Programm mit FM-Audio ohne Entzerrung und ohne Hochpass).")
        }
        if locked {
            if stats.voiceFrames > 20, Double(stats.cleanFrames) / Double(stats.voiceFrames) < 0.2 {
                return Result(severity: .waiting, title: "Signal schwach oder verrauscht", advice: "Die Sprachrahmen haben viele Bitfehler (der Sprachdecoder glättet das, es kann aber rauschen oder knacken). Ein stärkeres Signal oder genaueres Abstimmen hilft.")
            }
            return Result(severity: .ok, title: "dPMR-Signal wird empfangen", advice: "")
        }
        if stats.calls > 0 { return Result(severity: .ok, title: "Warten auf die nächste Aussendung", advice: "") }
        return Result(severity: .waiting, title: "Warten auf dPMR", advice: "Noch keine dPMR-Synchronisation. Das Audio muss die 4FSK-Daten mit 2400 Symbolen/s unverfälscht enthalten (nicht das fertig demodulierte Sprach-Audio); der Funkkanal ist nur 6,25 kHz breit, im SDR-Programm also FM mit schmalem Filter.")
    }
}
