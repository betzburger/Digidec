// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Bitpuffer und „Slicer“: Pulse und Lücken eines Pakets werden nach der Modulationsart des Geräts (PPM, PWM, PCM, Manchester …)
// zu Bits in Zeilen. Eine Zeile ist ein Telegramm; viele Sensoren senden es mehrfach hintereinander (je eine Zeile).
// Die Verfahren und Grenzwerte folgen rtl_433 (`pulse_slicer.c`, `bitbuffer.c`, GPL-2.0-oder-später).

// MARK: - Bitpuffer

public struct BitBuffer: Sendable {
    public static let maxRows = 50
    public var rows: [[UInt8]] = []
    public var bitsPerRow: [Int] = []
    public var syncsBeforeRow: [Int] = []

    public init() {}

    public var numRows: Int { rows.count }
    public var isEmpty: Bool { rows.isEmpty }

    public mutating func clear() { self = BitBuffer() }

    private mutating func ensureFirstRow() {
        if rows.isEmpty { rows = [[]]; bitsPerRow = [0]; syncsBeforeRow = [0] }
    }

    public mutating func addBit(_ bit: Int) {
        ensureFirstRow()
        let r = rows.count - 1
        let n = bitsPerRow[r]
        guard n < 65_535 else { return }
        if n % 8 == 0 { rows[r].append(0) }
        if bit != 0 { rows[r][n / 8] |= UInt8(0x80 >> (n % 8)) }
        bitsPerRow[r] = n + 1
    }

    public mutating func addRow() {
        ensureFirstRow()
        if rows.count < BitBuffer.maxRows {
            rows.append([]); bitsPerRow.append(0); syncsBeforeRow.append(0)
        } else {
            bitsPerRow[rows.count - 1] = 0
            rows[rows.count - 1] = []
        }
    }

    public mutating func addSync() {
        ensureFirstRow()
        if bitsPerRow[rows.count - 1] > 0 { addRow() }
        syncsBeforeRow[rows.count - 1] += 1
    }

    /// Alle Bits umkehren (ungenutzte Bits im letzten Byte bleiben null)
    public mutating func invert() {
        for r in 0..<rows.count where bitsPerRow[r] > 0 {
            for c in 0..<rows[r].count { rows[r][c] = ~rows[r][c] }
            let lastBits = (bitsPerRow[r] - 1) % 8 + 1
            rows[r][rows[r].count - 1] &= UInt8(truncatingIfNeeded: 0xFF00 >> lastBits)
        }
    }

    /// `len` Bits ab Bitposition `pos` einer Zeile, linksbündig in Bytes (Rest null)
    public func extractBytes(row: Int, pos: Int, len: Int) -> [UInt8] {
        guard len > 0, rows.indices.contains(row) else { return [] }
        let bits = rows[row]
        let nBytes = (len + 7) / 8
        var out = [UInt8](repeating: 0, count: nBytes)
        for i in 0..<len {
            let src = pos + i
            if src / 8 < bits.count, (bits[src / 8] >> UInt8(7 - src % 8)) & 1 == 1 { out[i / 8] |= UInt8(0x80 >> (i % 8)) }
        }
        return out
    }

    public func bit(row: Int, at index: Int) -> Int {
        guard rows.indices.contains(row), index >= 0, index / 8 < rows[row].count else { return 0 }
        return Int((rows[row][index / 8] >> UInt8(7 - index % 8)) & 1)
    }

    /// Erste Stelle ab `start`, an der das Muster beginnt; sonst die Länge der Zeile
    public func search(row: Int, start: Int, pattern: [UInt8], patternBits: Int) -> Int {
        let len = bitsPerRow[row]
        var ipos = start, ppos = 0
        func patternBit(_ i: Int) -> Int { Int((pattern[i / 8] >> UInt8(7 - i % 8)) & 1) }
        while ipos < len && ppos < patternBits {
            if bit(row: row, at: ipos) == patternBit(ppos) {
                ppos += 1; ipos += 1
                if ppos == patternBits { return ipos - patternBits }
            } else {
                ipos -= ppos
                ipos += 1
                ppos = 0
            }
        }
        return len
    }

    /// Manchester-Dekodierung ab `start` (IEEE 802.3: 01 = 1, 10 = 0 – wie im Vorbild wird das zweite Bit übernommen); gibt die Endposition zurück
    public func manchesterDecode(row: Int, start: Int, into out: inout BitBuffer, max: Int = 0) -> Int {
        var len = bitsPerRow[row]
        var ipos = start
        if max > 0 && len > start + max * 2 { len = start + max * 2 }
        while ipos < len {
            let b1 = bit(row: row, at: ipos); ipos += 1
            let b2 = bit(row: row, at: ipos); ipos += 1
            if b1 == b2 { break }
            out.addBit(b2)
        }
        return ipos
    }

    /// Differenzielle Manchester-Dekodierung (Takt aus dem ersten langen Puls)
    public func differentialManchesterDecode(row: Int, start: Int, into out: inout BitBuffer, max: Int = 0) -> Int {
        var len = bitsPerRow[row]
        var ipos = start
        var b1 = 0, b2 = 0
        if max > 0 && len > start + max * 2 { len = start + max * 2 }
        while ipos < len {
            b1 = bit(row: row, at: ipos); ipos += 1
            b2 = bit(row: row, at: ipos); ipos += 1
            let b3 = bit(row: row, at: ipos)
            if b1 != b2 {
                if b2 != b3 {
                    out.addBit(0)
                } else {
                    b2 = b1
                    ipos -= 1
                    break
                }
            } else {
                b2 = 1 - b1
                ipos -= 2
                break
            }
        }
        while ipos < len {
            b1 = bit(row: row, at: ipos); ipos += 1
            if b1 == b2 { break }
            b2 = bit(row: row, at: ipos); ipos += 1
            out.addBit(b1 == b2 ? 1 : 0)
        }
        return ipos
    }

    public func compareRows(_ a: Int, _ b: Int, maxBits: Int = 0) -> Bool {
        if maxBits == 0 || bitsPerRow[a] < maxBits || bitsPerRow[b] < maxBits {
            return bitsPerRow[a] == bitsPerRow[b] && rows[a].prefix((bitsPerRow[a] + 7) / 8) == rows[b].prefix((bitsPerRow[b] + 7) / 8)
        }
        let full = maxBits / 8
        if Array(rows[a].prefix(full)) != Array(rows[b].prefix(full)) { return false }
        if maxBits % 8 == 0 { return true }
        let mask = UInt8(truncatingIfNeeded: 0xFF00 >> (maxBits & 7))
        return rows[a][full] & mask == rows[b][full] & mask
    }

    public func countRepeats(row: Int, maxBits: Int = 0) -> Int { (0..<numRows).filter { compareRows(row, $0, maxBits: maxBits) }.count }

    /// Zeile, die mindestens `minRepeats` mal (ganz gleich) vorkommt und mindestens `minBits` lang ist; sonst −1
    public func findRepeatedRow(minRepeats: Int, minBits: Int) -> Int {
        for i in 0..<numRows where bitsPerRow[i] >= minBits && countRepeats(row: i) >= minRepeats { return i }
        return -1
    }

    public func findRepeatedPrefix(minRepeats: Int, minBits: Int) -> Int {
        for i in 0..<numRows where bitsPerRow[i] >= minBits && countRepeats(row: i, maxBits: minBits) >= minRepeats { return i }
        return -1
    }

    /// Bitfolge im Textformat des Vorbilds (`{40}aabbccdd/…`), für Prüfungen
    public static func parse(_ code: String) -> BitBuffer {
        var bits = BitBuffer()
        var width = -1
        var chars = Array(code)
        var i = 0
        func setWidth(_ w: Int) {
            guard bits.numRows > 0 else { return }
            let r = bits.numRows - 1
            let want = min(w, 65_535)
            if bits.bitsPerRow[r] > want {
                bits.bitsPerRow[r] = want
                bits.rows[r] = Array(bits.rows[r].prefix((want + 7) / 8))
                if want % 8 != 0, !bits.rows[r].isEmpty { bits.rows[r][bits.rows[r].count - 1] &= UInt8(truncatingIfNeeded: 0xFF00 >> (want % 8)) }
            } else {
                while bits.bitsPerRow[r] < want { bits.addBit(0) }
            }
        }
        chars.append("\0")
        while chars[i] != "\0" {
            let c = chars[i]
            if c == " " { i += 1; continue }
            if c == "0", chars[i + 1] == "x" || chars[i + 1] == "X" { i += 2; continue }
            if c == "{" {
                if width >= 0 { setWidth(width) }
                if bits.numRows > 0 { bits.addRow() }
                var j = i + 1
                var digits = ""
                while chars[j] != "}" && chars[j] != "\0" { digits.append(chars[j]); j += 1 }
                width = Int(digits.trimmingCharacters(in: .whitespaces)) ?? 0
                if chars[j] == "\0" { break }
                i = j + 1
                continue
            }
            if c == "/" {
                if width >= 0 { setWidth(width); width = -1 }
                bits.addRow()
                i += 1
                continue
            }
            guard let v = c.hexDigitValue else { i += 1; continue }
            for s in stride(from: 3, through: 0, by: -1) { bits.addBit((v >> s) & 1) }
            i += 1
        }
        if width >= 0 { setWidth(width) }
        return bits
    }
}

// MARK: - Modulation

public enum SensorModulation: Sendable {
    case ookPPM, ookPWM, ookPCM, ookManchesterZeroBit, ookDMC, ookOSV1
    case fskPCM, fskPWM, fskManchesterZeroBit

    public var isFSK: Bool {
        switch self {
        case .fskPCM, .fskPWM, .fskManchesterZeroBit: return true
        default: return false
        }
    }
}

/// Zeitangaben eines Geräts in Mikrosekunden (wie `r_device` im Vorbild)
public struct SlicerTiming: Sendable {
    public var modulation: SensorModulation
    public var shortWidth: Double = 0
    public var longWidth: Double = 0
    public var resetLimit: Double = 0
    public var gapLimit: Double = 0
    public var syncWidth: Double = 0
    public var tolerance: Double = 0

    public init(_ modulation: SensorModulation, short: Double = 0, long: Double = 0, reset: Double = 0, gap: Double = 0, sync: Double = 0, tolerance: Double = 0) {
        self.modulation = modulation
        shortWidth = short; longWidth = long; resetLimit = reset; gapLimit = gap; syncWidth = sync; self.tolerance = tolerance
    }
}

public enum PulseSlicer {
    /// Umgerechnete Grenzen in Abtastwerten; `nil`, wenn eine Angabe bei dieser Abtastrate auf null rundet
    private struct Limits {
        var short: Int, long: Int, reset: Int, gap: Int, sync: Int, tolerance: Int
        init?(_ t: SlicerTiming, sampleRate: Int) {
            let spu = Float(sampleRate) / 1.0e6
            func conv(_ us: Double) -> Int { Int(Float(us) * spu) }
            short = conv(t.shortWidth); long = conv(t.longWidth); reset = conv(t.resetLimit)
            gap = conv(t.gapLimit); sync = conv(t.syncWidth); tolerance = conv(t.tolerance)
            if (t.shortWidth > 0 && short <= 0) || (t.longWidth > 0 && long <= 0) || (t.resetLimit > 0 && reset <= 0)
                || (t.gapLimit > 0 && gap <= 0) || (t.syncWidth > 0 && sync <= 0) || (t.tolerance > 0 && tolerance <= 0) { return nil }
        }
    }

    /// Zerlegt ein Paket nach der Modulationsart; jedes vollständige Telegramm (Ende durch lange Pause oder Paketende) wird an `emit` gegeben
    public static func slice(_ p: PulseData, timing t: SlicerTiming, emit: (BitBuffer) -> Void) {
        switch t.modulation {
        case .ookPPM: ppm(p, t, emit)
        case .ookPWM, .fskPWM: pwm(p, t, emit)
        case .ookPCM, .fskPCM: pcm(p, t, emit)
        case .ookManchesterZeroBit, .fskManchesterZeroBit: manchesterZeroBit(p, t, emit)
        case .ookDMC: dmc(p, t, emit)
        case .ookOSV1: osv1(p, t, emit)
        }
    }

    // MARK: PCM (NRZ und RZ)

    static func pcm(_ p: PulseData, _ t: SlicerTiming, _ emit: (BitBuffer) -> Void) {
        guard let l = Limits(t, sampleRate: p.sampleRate) else { return }
        let sShort = l.short, sLong = l.long, sReset = l.reset, sGap = l.gap
        var tolerance = l.tolerance
        var fShort: Float = t.shortWidth > 0 ? 1.0 / (Float(t.shortWidth) * Float(p.sampleRate) / 1.0e6) : 0
        var fLong: Float = t.longWidth > 0 ? 1.0 / (Float(t.longWidth) * Float(p.sampleRate) / 1.0e6) : 0
        var bits = BitBuffer()
        let gapLimit = sGap != 0 ? sGap : sReset
        let maxZeros = sLong > 0 ? gapLimit / sLong : 0
        if tolerance <= 0 { tolerance = sLong / 4 }

        var minCount = sShort == sLong ? 12 : 4
        var preambleLen = 0
        // RZ
        var n = 0
        while sShort != sLong && n < p.numPulses {
            var sWidth = 0, lWidth = 0, count = 0
            while n < p.numPulses
                    && p.pulse[n] >= sShort - tolerance && p.pulse[n] <= sShort + tolerance
                    && p.pulse[n] + p.gap[n] >= sLong - tolerance && p.pulse[n] + p.gap[n] <= sLong + tolerance {
                sWidth += p.pulse[n]
                lWidth += p.pulse[n] + p.gap[n]
                count += 1
                n += 1
            }
            if count >= minCount {
                fLong = Float(count) / Float(lWidth)
                fShort = Float(count) / Float(sWidth)
                minCount = count
                preambleLen = count
            }
            n += 1
        }
        // RZ-Bits irgendwo innerhalb der Toleranz
        var rzsWidth = 0, rzlWidth = 0, rzCount = 0
        if preambleLen == 0 && sShort != sLong {
            for k in 0..<p.numPulses
                where p.pulse[k] >= sShort - tolerance && p.pulse[k] <= sShort + tolerance
                    && p.pulse[k] + p.gap[k] >= sLong - tolerance && p.pulse[k] + p.gap[k] <= sLong + tolerance {
                rzsWidth += p.pulse[k]
                rzlWidth += p.pulse[k] + p.gap[k]
                rzCount += 1
            }
        }
        if rzCount > 8 {
            fLong = Float(rzCount) / Float(rzlWidth)
            fShort = Float(rzCount) / Float(rzsWidth)
        }
        // NRZ
        n = 0
        while sShort == sLong && n < p.numPulses {
            var width = 0, count = 0
            while n < p.numPulses && Int(Float(p.pulse[n]) * fShort + 0.5) == 1 && Int(Float(p.gap[n]) * fLong + 0.5) == 1 {
                width += p.pulse[n] + p.gap[n]
                count += 2
                n += 1
            }
            if count >= minCount {
                fShort = Float(count) / Float(width)
                fLong = fShort
                minCount = count
                preambleLen = count
            }
            n += 1
        }
        // NRZ: Puls oder Lücke der Länge 1 oder 2 innerhalb der Toleranz irgendwo
        var nrzWidth = 0, nrzCount = 0
        if preambleLen == 0 && sShort == sLong {
            for k in 0..<p.numPulses {
                if p.pulse[k] >= sShort - tolerance && p.pulse[k] <= sShort + tolerance { nrzWidth += p.pulse[k]; nrzCount += 1 }
                if p.pulse[k] >= 2 * sShort - tolerance && p.pulse[k] <= 2 * sShort + tolerance { nrzWidth += p.pulse[k]; nrzCount += 2 }
                if p.gap[k] >= sLong - tolerance && p.gap[k] <= sLong + tolerance { nrzWidth += p.gap[k]; nrzCount += 1 }
                if p.gap[k] >= 2 * sLong - tolerance && p.gap[k] <= 2 * sLong + tolerance { nrzWidth += p.gap[k]; nrzCount += 2 }
            }
        }
        if nrzCount > 20 {
            fShort = Float(nrzCount) / Float(nrzWidth)
            fLong = fShort
        }

        for k in 0..<p.numPulses {
            let highs = Int(Float(p.pulse[k]) * fShort + 0.5)
            var lows = Int(Float(p.gap[k] + sShort - sLong) * fLong + 0.5)
            for _ in 0..<max(0, highs) { bits.addBit(1) }
            lows = min(lows, maxZeros)
            for _ in 0..<max(0, lows) { bits.addBit(0) }

            if sShort != sLong && abs(p.pulse[k] - sShort) > tolerance {
                bits.clear()
            } else if p.gap[k] > gapLimit && p.gap[k] <= sReset {
                bits.addRow()
            }
            if (k == p.numPulses - 1 || p.gap[k] > sReset) && (bits.numRows > 0 && (bits.bitsPerRow[0] > 0 || bits.numRows > 1)) {
                emit(bits)
                bits.clear()
            }
        }
    }

    // MARK: PPM (Information in der Lücke)

    static func ppm(_ p: PulseData, _ t: SlicerTiming, _ emit: (BitBuffer) -> Void) {
        guard let l = Limits(t, sampleRate: p.sampleRate) else { return }
        var bits = BitBuffer()
        let zeroL: Int, zeroU: Int, oneL: Int, oneU: Int
        var syncL = 0, syncU = 0
        if l.tolerance > 0 {
            zeroL = l.short - l.tolerance; zeroU = l.short + l.tolerance
            oneL = l.long - l.tolerance; oneU = l.long + l.tolerance
            if l.sync > 0 { syncL = l.sync - l.tolerance; syncU = l.sync + l.tolerance }
        } else {
            zeroL = 0
            zeroU = (l.short + l.long) / 2 + 1
            oneL = zeroU - 1
            oneU = l.gap != 0 ? l.gap : l.reset
        }
        for n in 0..<p.numPulses {
            let g = p.gap[n]
            if g > zeroL && g < zeroU {
                bits.addBit(0)
            } else if g > oneL && g < oneU {
                bits.addBit(1)
            } else if g > syncL && g < syncU {
                bits.addSync()
            } else if g < l.reset {
                bits.addRow()
            }
            if (n == p.numPulses - 1 || g >= l.reset) && bits.numRows > 0 && (bits.bitsPerRow[0] > 0 || bits.numRows > 1) {
                emit(bits)
                bits.clear()
            }
        }
    }

    // MARK: PWM (Information in der Pulsbreite)

    static func pwm(_ p: PulseData, _ t: SlicerTiming, _ emit: (BitBuffer) -> Void) {
        guard let l = Limits(t, sampleRate: p.sampleRate) else { return }
        var bits = BitBuffer()
        let oneL: Int, oneU: Int, zeroL: Int, zeroU: Int
        var syncL = 0, syncU = 0
        if l.tolerance > 0 {
            oneL = l.short - l.tolerance; oneU = l.short + l.tolerance
            zeroL = l.long - l.tolerance; zeroU = l.long + l.tolerance
            if l.sync > 0 { syncL = l.sync - l.tolerance; syncU = l.sync + l.tolerance }
        } else if l.sync <= 0 {
            oneL = 0; oneU = (l.short + l.long) / 2 + 1
            zeroL = oneU - 1; zeroU = Int.max
        } else if l.sync < l.short {
            syncL = 0; syncU = (l.sync + l.short) / 2 + 1
            oneL = syncU - 1; oneU = (l.short + l.long) / 2 + 1
            zeroL = oneU - 1; zeroU = Int.max
        } else if l.sync < l.long {
            oneL = 0; oneU = (l.short + l.sync) / 2 + 1
            syncL = oneU - 1; syncU = (l.sync + l.long) / 2 + 1
            zeroL = syncU - 1; zeroU = Int.max
        } else {
            oneL = 0; oneU = (l.short + l.long) / 2 + 1
            zeroL = oneU - 1; zeroU = (l.long + l.sync) / 2 + 1
            syncL = zeroU - 1; syncU = Int.max
        }
        for n in 0..<p.numPulses {
            let w = p.pulse[n]
            if w > oneL && w < oneU {
                bits.addBit(1)
            } else if w > zeroL && w < zeroU {
                bits.addBit(0)
            } else if w > syncL && w < syncU {
                bits.addSync()
            } else if w <= oneL {
                // zu kurze Störpulse überspringen
            } else {
                bits.addRow()
            }
            if (n == p.numPulses - 1 || p.gap[n] > l.reset) && bits.numRows > 0 {
                emit(bits)
                bits.clear()
            } else if l.gap > 0 && p.gap[n] > l.gap && bits.numRows > 0 && bits.bitsPerRow[bits.numRows - 1] > 0 {
                bits.addRow()
            }
        }
    }

    // MARK: Manchester (Null-Bit zuerst)

    static func manchesterZeroBit(_ p: PulseData, _ t: SlicerTiming, _ emit: (BitBuffer) -> Void) {
        guard let l = Limits(t, sampleRate: p.sampleRate) else { return }
        var bits = BitBuffer()
        var timeSinceLast = 0
        let shortF = Double(l.short)
        bits.addBit(0)                                       // Die erste steigende Flanke zählt immer als Null
        for n in 0..<p.numPulses {
            if l.tolerance > 0
                && (p.pulse[n] < l.short - l.tolerance || p.pulse[n] > l.short * 2 + l.tolerance
                    || p.gap[n] < l.short - l.tolerance || p.gap[n] > l.short * 2 + l.tolerance) {
                if Double(p.pulse[n]) > shortF * 1.5 && p.pulse[n] <= l.short * 2 + l.tolerance { bits.addBit(1) }
                bits.addRow()
                bits.addBit(0)
                timeSinceLast = 0
            } else if Double(p.pulse[n] + timeSinceLast) > shortF * 1.5 {
                bits.addBit(1)
                timeSinceLast = 0
            } else {
                timeSinceLast += p.pulse[n]
            }
            if (n == p.numPulses - 1 || p.gap[n] > l.reset) && bits.numRows > 0 {
                emit(bits)
                bits.clear()
                bits.addBit(0)
                timeSinceLast = 0
            } else if Double(p.gap[n] + timeSinceLast) > shortF * 1.5 {
                bits.addBit(0)
                timeSinceLast = 0
            } else {
                timeSinceLast += p.gap[n]
            }
        }
    }

    // MARK: DMC (Differenzielle Manchester-Kodierung nach Pulsbreiten)

    static func dmc(_ p: PulseData, _ t: SlicerTiming, _ emit: (BitBuffer) -> Void) {
        guard let l = Limits(t, sampleRate: p.sampleRate) else { return }
        var bits = BitBuffer()
        func symbol(_ n: Int) -> Int { n % 2 == 0 ? p.pulse[n / 2] : p.gap[n / 2] }
        var n = 0
        let total = p.numPulses * 2
        while n < total {
            var s = symbol(n)
            if abs(s - l.short) < l.tolerance {
                bits.addBit(1)
                n += 1
                s = n < total ? symbol(n) : 0
                if abs(s - l.short) > l.tolerance {
                    if s >= l.reset - l.tolerance {
                        n -= 1                               // am Ende folgt keine zweite kurze Lücke
                    } else if bits.numRows > 0 && bits.bitsPerRow[bits.numRows - 1] > 0 {
                        bits.addRow()
                    }
                }
            } else if abs(s - l.long) < l.tolerance {
                bits.addBit(0)
            } else if s >= l.reset - l.tolerance && bits.numRows > 0 {
                emit(bits)
                bits.clear()
            }
            n += 1
        }
    }

    // MARK: Oregon Scientific v1

    static func osv1(_ p: PulseData, _ t: SlicerTiming, _ emit: (BitBuffer) -> Void) {
        guard let l = Limits(t, sampleRate: p.sampleRate) else { return }
        var preamble = 0
        var manbit = 0
        var bits = BitBuffer()
        let halfMin = l.short / 2, halfMax = l.short * 3 / 2
        let syncMin = 2 * halfMax
        var n = 0
        while n < p.numPulses {
            if p.pulse[n] > halfMin && p.gap[n] > halfMin {
                preamble += 1
                if p.gap[n] > halfMax { break }
            } else { return }
            n += 1
        }
        guard preamble == 12 else { return }
        n += 1
        guard n < p.numPulses, p.pulse[n] >= syncMin, p.gap[n] >= syncMin else { return }
        // Die Lücke nach dem Synchronimpuls kann schon ein Datenbit sein
        if p.gap[n] > p.pulse[n] {
            manbit ^= 1
            if manbit != 0 { bits.addBit(0) }
        }
        n += 1
        while n < p.numPulses {
            manbit ^= 1
            if manbit != 0 { bits.addBit(1) }
            if p.pulse[n] > halfMax {
                manbit ^= 1
                if manbit != 0 { bits.addBit(1) }
            }
            if (n == p.numPulses - 1 || p.gap[n] > l.reset) && bits.numRows > 0 {
                emit(bits)
                return
            }
            manbit ^= 1
            if manbit != 0 { bits.addBit(0) }
            if p.gap[n] > halfMax {
                manbit ^= 1
                if manbit != 0 { bits.addBit(0) }
            }
            n += 1
        }
    }
}
