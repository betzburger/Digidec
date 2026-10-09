// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - Testsignal HFDL (nur für Tests und Prüfstände)
//
// Sendet einen Rahmen wie ein HFDL-Sender: Vorlauf, A1, A2, M1, M2, 9 × T, dann Blöcke aus 30 Datensymbolen und T.
// Daten: Faltungscode (Rate 1/2, K = 7, bei 300 bit/s doppelt gesendet), verschachtelt, Gray-PSK, mit der Folge entwürfelt gesendet
// (also verwürfelt), Wurzel-Kosinus-Impuls (Roll-off 0,15). Ausgabe als USB-Audio (Träger 1440 Hz) oder als komplexes Basisband.

public enum HFDLSignalGenerator {
    private static let parity: [UInt8] = (0..<128).map { UInt8($0.nonzeroBitCount & 1) }

    /// Codebits (Rate 1/2) zu den Datenbits; Zustand beginnt bei 0
    static func convolve(_ bits: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(bits.count * 2)
        var s = 0
        for u in bits {
            let reg = (s << 1) | Int(u)
            out.append(parity[reg & 0x6D])
            out.append(parity[reg & 0x4F])
            s = reg & 63
        }
        return out
    }

    /// Umkehrung zu `HFDLInterleaver.deinterleave`: aus der Folge am Viterbi-Eingang die Sendefolge
    static func interleave(_ x: [UInt8], columns: Int, pushShift: Int) -> [UInt8] {
        let rows = HFDLInterleaver.rows
        // Stelle (Zeile, Spalte) für das i-te gesendete Bit beim Einschreiben
        var pushPos = [Int](repeating: 0, count: x.count)
        var row = 0, col = 0
        for i in 0..<x.count {
            pushPos[i] = row * columns + col
            row += 1
            if row == rows { row = 0; col += 1 }
            col -= pushShift
            if col < 0 { col += columns }
        }
        // Stelle beim Auslesen: das j-te Bit am Viterbi-Eingang steht dort
        var popIndex = [Int](repeating: 0, count: x.count)       // Tabellenstelle → j
        row = 0; col = 0
        for j in 0..<x.count {
            popIndex[row * columns + col] = j
            row = (row + HFDLInterleaver.popRowShift) % rows
            if row == 0 { col += 1 }
        }
        var y = [UInt8](repeating: 0, count: x.count)
        for i in 0..<x.count { y[i] = x[popIndex[pushPos[i]]] }
        return y
    }

    /// Symbole eines Rahmens (Vorlauf eingeschlossen) für `payload` in Betriebsart `modeIndex` (0…7)
    static func frameSymbols(payload: [UInt8], mode modeIndex: Int, prekey: Int = 448) -> [Cx] {
        let mode = HFDLPHY.modes[modeIndex]
        let bps = mode.bitsPerSymbol
        let viterbiLen = mode.dataSymbols * bps / (mode.codeRate == 4 ? 2 : 1)
        let nBits = viterbiLen / 2
        precondition(payload.count * 8 + 6 <= nBits, "Nutzlast zu lang für die Betriebsart")
        var bits = [UInt8](repeating: 0, count: nBits)
        for (i, byte) in payload.enumerated() { for k in 0..<8 { bits[8 * i + k] = (byte >> UInt8(k)) & 1 } }
        var coded = convolve(bits)
        if mode.codeRate == 4 { coded = coded.flatMap { [$0, $0] } }
        let columns = mode.dataSymbols * bps / HFDLInterleaver.rows
        let sent = interleave(coded, columns: columns, pushShift: mode.pushShift)
        let scr = HFDLPHY.scramblerBits(count: mode.dataSymbols)
        let mpsk = 1 << bps

        func bpsk(_ b: UInt8) -> Cx { Cx(b == 0 ? 1 : -1, 0) }
        var sym: [Cx] = []
        // Vorlauf: Wechselfolge, damit Takt und Träger einrasten
        for i in 0..<prekey { sym.append(Cx(i % 2 == 0 ? 1 : -1, 0)) }
        for b in HFDLPHY.aBits { sym.append(bpsk(b)) }
        for b in HFDLPHY.aBits { sym.append(bpsk(b)) }
        let m1 = HFDLPHY.m1Bits(modeIndex)
        for b in m1 { sym.append(bpsk(b)) }
        for j in 0..<15 { sym.append(bpsk(HFDLPHY.m1Base[(HFDLPHY.m1Shifts[modeIndex] + 127 + j) % 127])) }   // M2: Fortsetzung der Folge
        for _ in 0..<9 { for t in HFDLPHY.tSeq { sym.append(Cx(t, 0)) } }
        var t = 0
        for _ in 0..<mode.blocks {
            for _ in 0..<30 {
                var value = 0
                for j in 0..<bps { value = (value << 1) | Int(sent[t * bps + j]) }
                // Gray-Dekodierung: Symbol = gray_encode(Index)
                var idx = value
                var shift = value >> 1
                while shift > 0 { idx ^= shift; shift >>= 1 }
                var p = Cx.polar(Double(idx) * 2 * Double.pi / Double(mpsk))
                if scr[t] == 1 { p = Cx(-p.re, -p.im) }
                sym.append(p)
                t += 1
            }
            for v in HFDLPHY.tSeq { sym.append(Cx(v, 0)) }
        }
        return sym
    }

    /// Wurzel-Kosinus-Impuls (Roll-off α) bei `sps` Abtastwerten je Symbol, ±`span` Symbole
    static func rrc(alpha: Double, sps: Int, span: Int) -> [Double] {
        let n = 2 * span * sps + 1
        return (0..<n).map { i in
            let x = Double(i - span * sps) / Double(sps)
            if abs(x) < 1e-9 { return 1 - alpha + 4 * alpha / Double.pi }
            if abs(abs(x) - 1 / (4 * alpha)) < 1e-9 {
                return alpha / 2.0.squareRoot() * ((1 + 2 / Double.pi) * sin(Double.pi / (4 * alpha)) + (1 - 2 / Double.pi) * cos(Double.pi / (4 * alpha)))
            }
            let num = sin(Double.pi * x * (1 - alpha)) + 4 * alpha * x * cos(Double.pi * x * (1 + alpha))
            return num / (Double.pi * x * (1 - pow(4 * alpha * x, 2)))
        }
    }

    /// Komplexes Basisband bei 12 kHz (Signal um `offsetHz` verschoben, dazu Frequenzversatz `freqError`), Länge mit Stille davor und danach
    static func baseband(symbols: [Cx], offsetHz: Double = HFDLPHY.subcarrierHz, freqError: Double = 0, leadSeconds: Double = 0.5,
                                tailSeconds: Double = 0.5) -> [Cx] {
        let sps = 20                                      // 36 kHz
        let h = rrc(alpha: 0.15, sps: sps, span: 8)
        var up = [Cx](repeating: .zero, count: symbols.count * sps + h.count)
        for (i, s) in symbols.enumerated() { up[i * sps] = s }
        // Filtern (Faltung), danach auf 12 kHz verkleinern (÷ 3)
        var shaped = [Cx](repeating: .zero, count: up.count)
        for i in 0..<symbols.count {
            let s = up[i * sps]
            for (j, c) in h.enumerated() where i * sps + j < shaped.count {
                shaped[i * sps + j].re += s.re * c
                shaped[i * sps + j].im += s.im * c
            }
        }
        let delay = h.count / 2
        let n12 = (up.count - h.count) / 3
        var out = [Cx](repeating: .zero, count: n12)
        for i in 0..<n12 { out[i] = shaped[i * 3 + delay] }
        // Amplitude auf Spitze etwa 1
        let peak = max(out.map { $0.abs }.max() ?? 1, 1e-9)
        let lead = Int(leadSeconds * 12_000), tail = Int(tailSeconds * 12_000)
        var full = [Cx](repeating: .zero, count: lead + n12 + tail)
        let f = offsetHz + freqError
        for i in 0..<n12 {
            let v = out[i] * (0.5 / peak)
            let k = lead + i
            full[k] = v * Cx.polar(2 * Double.pi * f * Double(k) / 12_000)
        }
        return full
    }

    /// USB-Audio bei 12 kHz: Realteil des Basisbands, optional mit weißem Rauschen (Standardabweichung `noise`, bezogen auf Spitze 0,5)
    static func audio(symbols: [Cx], freqError: Double = 0, noise: Double = 0, seed: UInt64 = 1, leadSeconds: Double = 0.5,
                             tailSeconds: Double = 0.5) -> [Float] {
        let bb = baseband(symbols: symbols, freqError: freqError, leadSeconds: leadSeconds, tailSeconds: tailSeconds)
        var rng = SplitMix64(seed: seed)
        return bb.map { v in
            var x = v.re
            if noise > 0 { x += noise * rng.gaussian() }
            return Float(x)
        }
    }

    struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func gaussian() -> Double {
            let u1 = max(uniform(), 1e-12), u2 = uniform()
            return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }
    }

    // MARK: Prüf-PDUs

    /// CRC wie im HFDL: über `bytes`, Ergebnis klein-endian anhängen
    static func appendFCS(_ bytes: [UInt8]) -> [UInt8] {
        let c = HFDLCRC.crc(bytes[...])
        return bytes + [UInt8(c & 0xFF), UInt8(c >> 8)]
    }

    /// Abwärts-MPDU mit LPDU-Liste (jede LPDU ohne Prüfbytes; sie werden angehängt)
    public static func downlinkMPDU(station: Int, aircraft: Int, lpdus: [[UInt8]]) -> [UInt8] {
        var hdr: [UInt8] = [UInt8(1 | 2 | (lpdus.count << 2)), UInt8(station & 0x7F), UInt8(aircraft), 0, 0, 0]
        let bodies = lpdus.map { appendFCS($0) }
        hdr += bodies.map { UInt8($0.count - 1) }
        return appendFCS(hdr) + bodies.flatMap { $0 }
    }

    /// Squitter (SPDU) mit gültiger Prüfsumme, 66 Bytes
    public static func squitter(station: Int, frameIndex: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 64)
        b[0] = 0x02                                       // Version 0, RLS
        b[1] = UInt8(station & 0x7F) | 0x80
        b[2] = UInt8(frameIndex & 0xFF)
        b[3] = UInt8((frameIndex >> 8) & 0xF) | 0x10
        b[53] = UInt8(HFDLStations.tableVersion & 0xFF)
        b[54] = UInt8((HFDLStations.tableVersion >> 8) & 0xF)
        return appendFCS(b)
    }

    static func coordinateBits(_ deg: Double) -> UInt32 {
        UInt32(bitPattern: Int32((deg * Double(0x7FFFF) / 180).rounded())) & 0xFFFFF
    }

    /// LPDU „Daten“ mit HFNPDU Frequenzdaten (Flugnummer, Ort, Uhrzeit)
    public static func frequencyDataLPDU(flight: String, lat: Double, lon: Double, seconds: Int, station: Int = 4) -> [UInt8] {
        var b: [UInt8] = [0x0D, 0xFF, 0xD5]
        let id = Array(flight.utf8.prefix(6)) + [UInt8](repeating: 0x20, count: max(0, 6 - flight.count))
        b += id
        let la = coordinateBits(lat), lo = coordinateBits(lon)
        b.append(UInt8(la & 0xFF)); b.append(UInt8((la >> 8) & 0xFF)); b.append(UInt8((la >> 16) & 0xF) | UInt8((lo & 0xF) << 4))
        b.append(UInt8((lo >> 4) & 0xFF)); b.append(UInt8((lo >> 12) & 0xFF))
        let t = seconds / 2
        b.append(UInt8(t & 0xFF)); b.append(UInt8(t >> 8))
        // eine Station: hört auf Frequenzen 0 und 2, empfangen auf 0
        b += [UInt8(station), 0x01, 0x00, 0x00 | 0x50, 0x00, 0x00]
        return b
    }
}
