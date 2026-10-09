// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Sendeseite von VDL Mode 2 für Tests und Prüfstände: AVLC-Rahmen → Bitstopfen → Reed-Solomon → Verschachtelung →
// Verwürfelung → D8PSK mit Wurzel-Kosinus-Impulsform (α = 0,6). Kein Sender: erzeugt nur Abtastwerte.

public enum VDL2SignalGenerator {
    // MARK: Rahmen

    /// Rahmenprüfsumme (CRC-16/X-25, kleinendig) anhängen
    public static func withFCS(_ body: [UInt8]) -> [UInt8] {
        let c = ~VDL2.crc16(body[...], initial: 0xFFFF)
        return body + [UInt8(c & 0xFF), UInt8(c >> 8)]
    }

    /// Informationsrahmen (Nummern 0 … 7), Prüfsumme inbegriffen
    public static func informationFrame(destination: VDL2Address, source: VDL2Address, sendSeq: Int = 0, recvSeq: Int = 0, poll: Bool = false,
                                        payload: [UInt8]) -> [UInt8] {
        let lcf = UInt8((sendSeq & 7) << 1 | (poll ? 0x10 : 0) | (recvSeq & 7) << 5)
        return withFCS(destination.bytes(last: false) + source.bytes(last: true) + [lcf] + payload)
    }

    /// Nicht nummerierter Rahmen (`mfunc` = Befehlsbits ohne das Poll-Bit, z. B. 0x2B für XID)
    public static func unnumberedFrame(destination: VDL2Address, source: VDL2Address, mfunc: Int, poll: Bool = false, payload: [UInt8] = []) -> [UInt8] {
        let lcf = UInt8(3 | (mfunc & 0x3B) << 2 | (poll ? 0x10 : 0))
        return withFCS(destination.bytes(last: false) + source.bytes(last: true) + [lcf] + payload)
    }

    /// Überwachungsrahmen: 0 = RR, 1 = RNR, 2 = REJ, 3 = SREJ
    public static func supervisoryFrame(destination: VDL2Address, source: VDL2Address, function: Int, recvSeq: Int = 0, poll: Bool = false) -> [UInt8] {
        let lcf = UInt8(1 | (function & 3) << 2 | (poll ? 0x10 : 0) | (recvSeq & 7) << 5)
        return withFCS(destination.bytes(last: false) + source.bytes(last: true) + [lcf])
    }

    /// ACARS im Informationsrahmen: FF FF 01, Kopf, Text mit Paritätsbit, Prüfsumme und DEL
    public static func acarsPayload(mode: Character = "2", registration: String, ack: Character = "!", label: String, blockID: Character,
                                    messageNumber: String = "M01A", flight: String = "LH1234", text: String, continues: Bool = false) -> [UInt8] {
        func odd(_ b: UInt8) -> UInt8 { b.nonzeroBitCount & 1 == 1 ? b & 0x7F : b | 0x80 }
        var raw: [UInt8] = []
        raw.append(mode.asciiValue ?? 0x32)
        let reg = Array(registration.utf8.suffix(7))
        raw += [UInt8](repeating: 0x2E, count: 7 - reg.count) + reg
        raw.append(ack.asciiValue ?? 0x21)
        let l = Array(label.utf8)
        raw += [l.first ?? 0x48, l.count > 1 ? l[1] : 0x31]
        raw.append(blockID.asciiValue ?? 0x31)
        let down = blockID.isNumber
        raw.append(0x02)
        if down {
            raw += Array((messageNumber + "    ").utf8.prefix(4))
            raw += Array((flight + "      ").utf8.prefix(6))
        }
        raw += Array(text.utf8.map { $0 == 0x0A ? 0x0A : $0 })
        raw.append(continues ? 0x17 : 0x03)
        var block = raw.map(odd)
        let crc = ACARS.crc(block)
        block += [UInt8(crc & 0xFF), UInt8(crc >> 8), 0x7F]
        return [0xFF, 0xFF, 0x01] + block
    }

    // MARK: Bitstrom eines Bursts

    /// Rahmen (mit Prüfsumme) → Bits des Bursts hinter der Präambel: Kopf, Daten, Prüfbytes; verwürfelt, auf volle Symbole aufgefüllt
    public static func burstBits(frames: [[UInt8]], padding: UInt8 = 0) -> [UInt8] {
        // HDLC-Strom: Flagge, Rahmen mit Bitstopfen, Flagge …
        var stream: [UInt8] = []
        func flag() { stream += [0, 1, 1, 1, 1, 1, 1, 0] }
        flag()
        for f in frames {
            var ones = 0
            for byte in f {
                for j in 0..<8 {
                    let b = (byte >> UInt8(j)) & 1
                    stream.append(b)
                    if b == 1 { ones += 1; if ones == 5 { stream.append(0); ones = 0 } } else { ones = 0 }
                }
            }
            flag()
        }
        let dataLength = stream.count
        let dataOctets = (dataLength + 7) / 8
        while stream.count < dataOctets * 8 { stream.append(0) }
        let data: [UInt8] = (0..<dataOctets).map { i in (0..<8).reduce(UInt8(0)) { $0 | (stream[i * 8 + $1] << UInt8($1)) } }
        // Blöcke
        var numBlocks = dataOctets / VDL2.rsK
        var fecOctets = numBlocks * (VDL2.rsN - VDL2.rsK)
        var lastBlock = dataOctets % VDL2.rsK
        if lastBlock != 0 { numBlocks += 1 }
        fecOctets += VDL2.fecOctetCount(lastBlockLength: lastBlock)
        if lastBlock == 0 { lastBlock = VDL2.rsK }
        precondition(fecOctets > 0, "Rahmen zu kurz")
        var table = [[UInt8]](repeating: [UInt8](repeating: 0, count: VDL2.rsN), count: numBlocks)
        for r in 0..<numBlocks {
            let from = r * VDL2.rsK
            let n = r == numBlocks - 1 ? lastBlock : VDL2.rsK
            for c in 0..<n { table[r][c] = data[from + c] }
            let par = ReedSolomon.shared.parity(of: Array(table[r][0..<VDL2.rsK]))
            for c in 0..<(VDL2.rsN - VDL2.rsK) { table[r][VDL2.rsK + c] = par[c] }
        }
        let interleavedData = VDL2.interleave(table, rows: numBlocks, fillWidth: VDL2.rsK, offset: 0, count: dataOctets)
        let fecRows = VDL2.fecOctetCount(lastBlockLength: lastBlock) == 0 ? numBlocks - 1 : numBlocks
        let interleavedFEC = VDL2.interleave(table, rows: fecRows, fillWidth: VDL2.rsN - VDL2.rsK, offset: VDL2.rsK, count: fecOctets)
        // Kopf
        let lengthField = VDL2.reverse(UInt32(dataLength), bits: VDL2.lengthBits)
        let word22 = lengthField << UInt32(VDL2.headerFECBits)
        let header = word22 | VDL2.headerCheck(word22)
        var bits: [UInt8] = (0..<VDL2.headerBits).map { UInt8((header >> UInt32(VDL2.headerBits - 1 - $0)) & 1) }
        for byte in interleavedData + interleavedFEC { for j in 0..<8 { bits.append((byte >> UInt8(j)) & 1) } }
        while bits.count % 3 != 0 { bits.append(padding & 1) }
        var lfsr = VDL2.scramblerStart
        VDL2.scramble(&bits, from: 0, to: bits.count, state: &lfsr)
        return bits
    }

    // MARK: Modulation

    private static let gray: [UInt8] = [0, 1, 3, 2, 6, 7, 5, 4]
    private static let preamblePhase: [Double] = [0, 3, -3, 1, 1, 2, 0, 4, -3, 4, -2, 3, 1, -2, -3, 0].map { $0 * Double.pi / 4 }

    /// Phasen aller Symbole eines Bursts (Präambel, dann Differenzphasen)
    public static func symbolPhases(bits: [UInt8]) -> [Double] {
        var phases = preamblePhase
        var phase = preamblePhase.last!
        var inverse = [Int](repeating: 0, count: 8)
        for (i, g) in gray.enumerated() { inverse[Int(g)] = i }
        var i = 0
        while i + 2 < bits.count {
            let v = Int(bits[i]) << 2 | Int(bits[i + 1]) << 1 | Int(bits[i + 2])
            phase += Double(inverse[v]) * Double.pi / 4
            phases.append(phase)
            i += 3
        }
        return phases
    }

    /// Wurzel-Kosinus-Impuls (α) bei t Symboldauern
    static func rrc(_ t: Double, alpha: Double = 0.6) -> Double {
        if abs(t) < 1e-9 { return 1 - alpha + 4 * alpha / Double.pi }
        if abs(abs(t) - 1 / (4 * alpha)) < 1e-9 {
            return alpha / 2.0.squareRoot() * ((1 + 2 / Double.pi) * sin(Double.pi / (4 * alpha)) + (1 - 2 / Double.pi) * cos(Double.pi / (4 * alpha)))
        }
        let a = sin(Double.pi * t * (1 - alpha)) + 4 * alpha * t * cos(Double.pi * t * (1 + alpha))
        let b = Double.pi * t * (1 - pow(4 * alpha * t, 2))
        return a / b
    }

    public struct Burst {
        public var bits: [UInt8]
        /// Frequenz gegenüber der Mitte des Eingangs (Hz)
        public var offsetHz: Double
        /// Beginn im Strom (Sekunden)
        public var start: Double
        public var amplitude: Double
        /// Fehler der Symboltaktes in ppm
        public var clockPPM: Double
        /// Anfangsphase (rad)
        public var phase: Double
        public init(bits: [UInt8], offsetHz: Double = 0, start: Double = 0.002, amplitude: Double = 0.5, clockPPM: Double = 0, phase: Double = 0.4) {
            self.bits = bits; self.offsetHz = offsetHz; self.start = start; self.amplitude = amplitude; self.clockPPM = clockPPM; self.phase = phase
        }
    }

    /// I/Q-Strom (komplex, ±1) aus mehreren Bursts mit weißem Rauschen (Standardabweichung je Achse `noise`)
    public static func render(_ bursts: [Burst], sampleRate: Double, duration: Double, noise: Double = 0, seed: UInt64 = 1) -> (i: [Float], q: [Float]) {
        let n = Int(duration * sampleRate)
        var re = [Double](repeating: 0, count: n), im = [Double](repeating: 0, count: n)
        for b in bursts {
            let phases = symbolPhases(bits: b.bits)
            let symbolTime = 1 / (VDL2.symbolRate * (1 + b.clockPPM * 1e-6))
            let span = 5                                                // Symbole je Seite
            let first = Int(b.start * sampleRate)
            let last = min(n - 1, first + Int((Double(phases.count + 2 * span) * symbolTime) * sampleRate))
            guard first < n else { continue }
            for s in first...last {
                let t = Double(s) / sampleRate - b.start - Double(span) * symbolTime      // Zeit ab dem ersten Symbol (Mitte)
                let k0 = Int((t / symbolTime).rounded())
                var sr = 0.0, si = 0.0
                for k in (k0 - span)...(k0 + span) where k >= 0 && k < phases.count {
                    let g = rrc(t / symbolTime - Double(k))
                    sr += g * cos(phases[k]); si += g * sin(phases[k])
                }
                // Mischen auf die Kanallage
                let w = 2 * Double.pi * b.offsetHz * (Double(s) / sampleRate) + b.phase
                let cr = cos(w), ci = sin(w)
                re[s] += b.amplitude * (sr * cr - si * ci)
                im[s] += b.amplitude * (sr * ci + si * cr)
            }
        }
        var rng = seed &* 6364136223846793005 &+ 1442695040888963407
        func gaussian() -> Double {
            func uniform() -> Double {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                return (Double(rng >> 11) + 0.5) / 9007199254740992.0
            }
            return (-2 * log(uniform())).squareRoot() * cos(2 * Double.pi * uniform())
        }
        var oi = [Float](repeating: 0, count: n), oq = [Float](repeating: 0, count: n)
        for s in 0..<n {
            oi[s] = Float(re[s] + (noise > 0 ? noise * gaussian() : 0))
            oq[s] = Float(im[s] + (noise > 0 ? noise * gaussian() : 0))
        }
        return (oi, oq)
    }
}
