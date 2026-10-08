// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// RDS-Prüfsignale für Logiktests und Prüfstand: Gruppen nach EN 50067 und deren Modulation auf den 57-kHz-Unterträger.
public enum RDSSignalGenerator {
    // MARK: Gruppen

    private static func b(_ type: Int, versionB: Bool = false, tp: Bool, pty: Int, low: Int = 0) -> UInt16 {
        UInt16((type << 12) | ((versionB ? 1 : 0) << 11) | ((tp ? 1 : 0) << 10) | ((pty & 0x1F) << 5) | (low & 0x1F))
    }

    private static func group(_ pi: UInt16, _ bData: UInt16, _ cData: UInt16, _ dData: UInt16, versionB: Bool = false) -> RDSGroup {
        RDSGroup(blockA: RDSBlock(data: pi, offset: .a), blockB: RDSBlock(data: bData, offset: .b),
                 blockC: RDSBlock(data: cData, offset: versionB ? .cPrime : .c), blockD: RDSBlock(data: dData, offset: .d))
    }

    /// Zeichen als RDS-Code (ASCII und die Umlaute des RDS-Zeichensatzes)
    public static func code(_ ch: Character) -> UInt8 {
        switch ch {
        case "ä": return 0x91
        case "ö": return 0x97
        case "ü": return 0x99
        case "Ä": return 0xD1
        case "Ö": return 0xD7
        case "Ü": return 0xD9
        case "ß": return 0x8D
        default: return ch.asciiValue ?? 0x20
        }
    }

    /// Gruppen 0A: Programmname (4 Segmente), Verkehrsfunk-Kennungen, Alternativfrequenzen (Methode A) und Decoder-Kennungen
    public static func makeGroup0A(pi: UInt16, ps: String, tp: Bool = true, ta: Bool = false, pty: Int = 10, afMHz: [Double] = [98.0],
                                   music: Bool = true, stereo: Bool = false, dynamicPTY: Bool = false, compressed: Bool = false,
                                   artificialHead: Bool = false) -> [RDSGroup] {
        let chars = Array((ps + "        ").prefix(8)).map(code)
        // AF-Liste: Zählcode 224 + n, dann n Frequenzcodes; mit Füllcode 205 auf gerade Länge
        var tokens: [UInt8] = []
        if !afMHz.isEmpty {
            tokens.append(UInt8(224 + min(afMHz.count, 25)))
            for f in afMHz.prefix(25) { tokens.append(UInt8(max(1, min(204, Int(((f - 87.5) * 10).rounded()))))) }
        }
        while tokens.count < 8 { tokens.append(205) }
        var out: [RDSGroup] = []
        for seg in 0..<4 {
            var di = 0
            switch seg {
            case 0: di = dynamicPTY ? 1 : 0
            case 1: di = compressed ? 1 : 0
            case 2: di = artificialHead ? 1 : 0
            default: di = stereo ? 1 : 0
            }
            let low = ((ta ? 1 : 0) << 4) | ((music ? 1 : 0) << 3) | (di << 2) | seg
            let c = (UInt16(tokens[2 * seg]) << 8) | UInt16(tokens[2 * seg + 1])
            let d = (UInt16(chars[2 * seg]) << 8) | UInt16(chars[2 * seg + 1])
            out.append(group(pi, b(0, tp: tp, pty: pty, low: low), c, d))
        }
        return out
    }

    /// Gruppen 2A: Radiotext; eine kürzere Nachricht endet mit dem Wagenrücklauf 0x0D
    public static func makeGroup2A(pi: UInt16, text: String, tp: Bool = true, pty: Int = 10, textAB: Bool = false) -> [RDSGroup] {
        var bytes = text.prefix(64).map(code)
        if bytes.count < 64 { bytes.append(0x0D) }
        let segCount = min(16, (bytes.count + 3) / 4)
        while bytes.count < segCount * 4 { bytes.append(0x20) }
        return (0..<segCount).map { seg in
            let c = (UInt16(bytes[4 * seg]) << 8) | UInt16(bytes[4 * seg + 1])
            let d = (UInt16(bytes[4 * seg + 2]) << 8) | UInt16(bytes[4 * seg + 3])
            return group(pi, b(2, tp: tp, pty: pty, low: ((textAB ? 1 : 0) << 4) | seg), c, d)
        }
    }

    /// Gruppe 4A: Uhrzeit (UTC) mit örtlichem Versatz in halben Stunden
    public static func makeGroup4A(pi: UInt16, date: Date, offsetHalfHours: Int = 2) -> RDSGroup {
        let unix = date.timeIntervalSince1970
        let days = Int((unix / 86_400).rounded(.down))
        let mjd = UInt32(days + 40_587)
        let daySecs = Int(unix - Double(days) * 86_400)
        let hour = daySecs / 3600
        let minute = (daySecs % 3600) / 60
        let bData = b(4, tp: true, pty: 10, low: Int((mjd >> 15) & 0x03))
        let cData = UInt16(((mjd & 0x7FFF) << 1) | UInt32((hour >> 4) & 1))
        let sign = offsetHalfHours < 0 ? 1 : 0
        let dData = UInt16(((hour & 0x0F) << 12) | ((minute & 0x3F) << 6) | (sign << 5) | (abs(offsetHalfHours) & 0x1F))
        return group(pi, bData, cData, dData)
    }

    /// Gruppe 1A: Erweiterter Ländercode (Variante 0) oder Sprachkennung (Variante 3)
    public static func makeGroup1A(pi: UInt16, ecc: UInt8? = nil, language: UInt8? = nil) -> RDSGroup {
        if let language {
            return group(pi, b(1, tp: true, pty: 10), UInt16(3 << 12) | UInt16(language), 0)
        }
        return group(pi, b(1, tp: true, pty: 10), UInt16(ecc ?? 0xE0), 0)
    }

    /// Gruppen 10A: Programmtyp-Name (8 Zeichen in zwei Segmenten)
    public static func makeGroup10A(pi: UInt16, name: String) -> [RDSGroup] {
        let chars = Array((name + "        ").prefix(8)).map(code)
        return (0..<2).map { seg in
            let c = (UInt16(chars[4 * seg]) << 8) | UInt16(chars[4 * seg + 1])
            let d = (UInt16(chars[4 * seg + 2]) << 8) | UInt16(chars[4 * seg + 3])
            return group(pi, b(10, tp: true, pty: 10, low: seg), c, d)
        }
    }

    /// Gruppe 3A: kündigt eine Zusatzanwendung (ODA) an. Für RT+ ist die Anwendungskennung 0x4BD7.
    public static func makeGroup3A(pi: UInt16, groupTypeCode: Int, message: UInt16 = 0, applicationID: UInt16 = 0x4BD7) -> RDSGroup {
        group(pi, b(3, tp: true, pty: 10, low: groupTypeCode), message, applicationID)
    }

    /// RT+ Gruppe (z. B. 11A): zwei Markierungen (Typ, Anfang, Länge) im Radiotext. Typ 1 = Titel, 4 = Interpret.
    public static func makeRTPlus(pi: UInt16, groupType: Int = 11, toggle: Bool = false, running: Bool = true,
                                  tag1: (type: Int, start: Int, length: Int), tag2: (type: Int, start: Int, length: Int)) -> RDSGroup {
        let low = ((toggle ? 1 : 0) << 4) | ((running ? 1 : 0) << 3) | ((tag1.type >> 3) & 0x07)
        // Die Länge steht als Anzahl − 1 im Telegramm
        let c = UInt16(((tag1.type & 0x07) << 13) | ((tag1.start & 0x3F) << 7) | (((tag1.length - 1) & 0x3F) << 1) | ((tag2.type >> 5) & 1))
        let d = UInt16(((tag2.type & 0x1F) << 11) | ((tag2.start & 0x3F) << 5) | ((tag2.length - 1) & 0x1F))
        return group(pi, b(groupType, tp: true, pty: 10, low: low), c, d)
    }

    // MARK: Bits und Modulation

    /// Bitstrom (vor der differentiellen Codierung), jeder Block mit Prüfwort und Offset
    public static func bits(of groups: [RDSGroup]) -> [Int] {
        var raw: [Int] = []
        for g in groups {
            for blk in g.blocks {
                guard let blk else { continue }
                let w = RDSSyndrome.encodeBlock(data: blk.data, offset: blk.offset)
                for i in (0..<26).reversed() { raw.append(Int((w >> UInt32(i)) & 1)) }
            }
        }
        return raw
    }

    /// Multiplexsignal nur mit dem RDS-Unterträger: differentielle Codierung, Biphase (Manchester) mit 1187,5 Bit/s, Bandbegrenzung auf 2,4 kHz,
    /// Träger bei 57 kHz (+ `carrierOffsetHz`). `clockPPM` verstimmt den Bittakt gegen den Träger (Sender und Empfänger laufen nie genau gleich).
    public static func modulate(groups: [RDSGroup], sampleRate: Double = 480_000, amplitude: Float = 0.027, carrierOffsetHz: Double = 0,
                                clockPPM: Double = 0, startPhase: Double = 0.6) -> [Float] {
        modulate(bits: bits(of: groups), sampleRate: sampleRate, amplitude: amplitude, carrierOffsetHz: carrierOffsetHz, clockPPM: clockPPM, startPhase: startPhase)
    }

    public static func modulate(bits rawBits: [Int], sampleRate: Double = 480_000, amplitude: Float = 0.027, carrierOffsetHz: Double = 0,
                                clockPPM: Double = 0, startPhase: Double = 0.6) -> [Float] {
        var diff: [Int] = []
        var prev = 0
        for bit in rawBits { prev ^= bit; diff.append(prev) }
        let bitRate = 1187.5 * (1 + clockPPM * 1e-6)
        let n = Int(Double(diff.count) / bitRate * sampleRate)
        var base = [Float](repeating: 0, count: n)
        for m in 0..<n {
            let pos = Double(m) / sampleRate * bitRate
            let k = Int(pos)
            guard k < diff.count else { break }
            let u = pos - Double(k)
            let s: Float = diff[k] == 1 ? 1 : -1
            base[m] = u < 0.5 ? s : -s
        }
        // Bandbegrenzung (Sendefilter); lineare Phase, Verzögerung wird ausgeglichen
        let taps = SDRFilterDesign.lowpass(taps: Int(sampleRate / 1187.5 * 3) | 1, cutoff: 2_400 / sampleRate, attenuationDB: 50)
        let fir = StreamFIR(taps: taps)
        var filtered: [Float] = []
        fir.process(base + [Float](repeating: 0, count: taps.count), into: &filtered)
        let delay = Int(fir.groupDelaySamples)
        var out = [Float](repeating: 0, count: n)
        let w = 2 * Double.pi * (57_000 + carrierOffsetHz) / sampleRate
        for m in 0..<n {
            let v = m + delay < filtered.count ? filtered[m + delay] : 0
            out[m] = amplitude * v * Float(cos(w * Double(m) + startPhase))
        }
        return out
    }
}
