import Foundation

// MARK: - ACARS (ARINC 618): 2400 Bd MSK auf 1200/2400 Hz im AM-Audio

/// Ein Block aus dem Bitstrom, noch ungeprüft: Bytes ab nach SOH bis einschließlich ETX/ETB, dazu die zwei Prüfbytes
public struct ACARSBlock: Sendable {
    public var bytes: [UInt8]
    public var crc: (UInt8, UInt8)
    public var levelDB: Double
}

public enum ACARS {
    static let syn: UInt8 = 0x16
    static let soh: UInt8 = 0x01
    static let etx: UInt8 = 0x83      // ETX mit Paritätsbit
    static let etb: UInt8 = 0x97      // ETB mit Paritätsbit
    static let del: UInt8 = 0x7F

    /// CRC-16/KERMIT (reflektiert 0x8408, Startwert 0) über Block und Prüfbytes ergibt 0
    static let crcTable: [UInt16] = (0..<256).map { i -> UInt16 in
        var c = UInt16(i)
        for _ in 0..<8 { c = c & 1 == 1 ? (c >> 1) ^ 0x8408 : c >> 1 }
        return c
    }

    static func crc(_ bytes: [UInt8]) -> UInt16 {
        var c: UInt16 = 0
        for b in bytes { c = (c >> 8) ^ crcTable[Int((c ^ UInt16(b)) & 0xFF)] }
        return c
    }

    /// Ungerade Parität: jedes Zeichen hat eine ungerade Zahl gesetzter Bits (inklusive Paritätsbit)
    static func parityOK(_ b: UInt8) -> Bool { b.nonzeroBitCount & 1 == 1 }
}

// MARK: - Demodulator

/// MSK-Demodulator: VCO bei 1800 Hz, Mischer, angepasstes Filter, Takt- und Trägernachführung (PLL),
/// dann Suche nach der Synchronisation SYN SYN SOH und Lesen des Textblocks bis ETX/ETB und Prüfsumme
public final class ACARSDemodulator {
    public let sampleRate: Double
    private let filterLength: Int
    private static let oversample = 12
    private let matched: [Float]

    // MSK
    private var phase = 0.0
    private var clock = 0.0
    private var df = 0.0
    private var skip = 0                      // Zähler der Bits, Bit 0 = I/Q-Wechsel, Bit 1 = Polarität
    private var bufI: [Float]
    private var bufQ: [Float]
    private var index = 0
    private var levelSum = 0.0
    private var levelCount = 0
    private static let pllGain = 38e-4
    private static let pllCoefficient = 0.52

    // Rahmen
    private enum State { case waitSyn, syn2, soh, text, crc1, crc2, end }
    private var state = State.waitSyn
    private var bits: UInt8 = 0
    private var wanted = 8
    private var block: [UInt8] = []
    private var crcBytes: (UInt8, UInt8) = (0, 0)
    private var parityErrors = 0

    /// Hüllkurve des letzten Rahmens (dB, relativ)
    public private(set) var lastLevel = 0.0
    /// Zeit seit der letzten Synchronisation (für die Anzeige „DCD“)
    public private(set) var inFrame = false

    public init(sampleRate: Double = 12_000) {
        self.sampleRate = sampleRate
        filterLength = Int(sampleRate / 1200) + 1
        bufI = [Float](repeating: 0, count: filterLength)
        bufQ = [Float](repeating: 0, count: filterLength)
        let n = filterLength * Self.oversample + 1
        matched = (0..<n).map { i in
            let v = cosf(Float(2 * Double.pi * 600.0 / sampleRate / Double(Self.oversample) * (Double(i) - Double(n - 1) / 2)))
            return max(0, v)
        }
    }

    public func reset() {
        phase = 0; clock = 0; df = 0; skip = 0; index = 0
        bufI = [Float](repeating: 0, count: filterLength)
        bufQ = [Float](repeating: 0, count: filterLength)
        state = .waitSyn; wanted = 8; bits = 0; block.removeAll(); inFrame = false
    }

    /// Verarbeitet AM-Audio; `onBlock` für jeden vollständig gelesenen Block (Prüfung folgt im Aufrufer)
    public func process(_ samples: UnsafeBufferPointer<Float>, onBlock: (ACARSBlock) -> Void) {
        for x in samples {
            let s = 1800.0 / sampleRate * 2 * .pi + df
            phase += s
            if phase >= 2 * .pi { phase -= 2 * .pi }
            // Mischer
            bufI[index] = x * Float(cos(phase))
            bufQ[index] = -x * Float(sin(phase))
            index = (index + 1) % filterLength
            // Bittakt
            clock += s
            if clock >= 3 * .pi / 2 - s / 2 {
                clock -= 3 * .pi / 2
                var o = Self.oversample * Int(clock / s + 0.5)
                if o > Self.oversample { o = Self.oversample }
                var vr: Float = 0, vi: Float = 0
                for j in 0..<filterLength {
                    let h = matched[o + j * Self.oversample]
                    let k = (j + index) % filterLength
                    vr += h * bufI[k]
                    vi += h * bufQ[k]
                }
                let lvl = (vr * vr + vi * vi).squareRoot()
                vr /= lvl + 1e-8
                vi /= lvl + 1e-8
                levelSum += Double(lvl * lvl / 4)
                levelCount += 1
                var vo: Float, dphi: Float
                if skip & 1 != 0 {
                    vo = vi
                    dphi = vo >= 0 ? -vr : vr
                } else {
                    vo = vr
                    dphi = vo >= 0 ? vi : -vi
                }
                putBit((skip & 2 != 0 ? -vo : vo) > 0, onBlock: onBlock)
                skip += 1
                df = Self.pllCoefficient * df + (1 - Self.pllCoefficient) * Self.pllGain * Double(dphi)
            }
        }
    }

    private func putBit(_ one: Bool, onBlock: (ACARSBlock) -> Void) {
        bits >>= 1
        if one { bits |= 0x80 }
        wanted -= 1
        if wanted <= 0 { decode(onBlock: onBlock) }
    }

    private func resetFrame() {
        state = .waitSyn
        df = 0
        wanted = 1
        inFrame = false
    }

    private func decode(onBlock: (ACARSBlock) -> Void) {
        let r = bits
        switch state {
        case .waitSyn:
            if r == ACARS.syn { state = .syn2; wanted = 8; return }
            if r == ~ACARS.syn { skip ^= 2; state = .syn2; wanted = 8; return }
            wanted = 1
        case .syn2:
            if r == ACARS.syn { state = .soh; wanted = 8; return }
            if r == ~ACARS.syn { skip ^= 2; wanted = 8; return }
            resetFrame()
        case .soh:
            if r == ACARS.soh {
                block.removeAll(keepingCapacity: true)
                parityErrors = 0
                levelSum = 0
                levelCount = 0
                state = .text
                inFrame = true
                wanted = 8
                return
            }
            resetFrame()
        case .text:
            block.append(r)
            if !ACARS.parityOK(r) {
                parityErrors += 1
                if parityErrors > 4 { resetFrame(); return }
            }
            if r == ACARS.etx || r == ACARS.etb { state = .crc1; wanted = 8; return }
            if block.count > 20 && r == ACARS.del {
                // Textende verpasst: die letzten drei Bytes sind ETX und Prüfbytes
                guard block.count >= 4 else { resetFrame(); return }
                let n = block.count
                crcBytes = (block[n - 3], block[n - 2])
                block.removeLast(3)
                finish(onBlock: onBlock)
                return
            }
            if block.count > 240 { resetFrame(); return }
            wanted = 8
        case .crc1:
            crcBytes.0 = r
            state = .crc2
            wanted = 8
        case .crc2:
            crcBytes.1 = r
            finish(onBlock: onBlock)
        case .end:
            resetFrame()
            wanted = 8
        }
    }

    private func finish(onBlock: (ACARSBlock) -> Void) {
        let level = levelCount > 0 ? 10 * log10(levelSum / Double(levelCount) + 1e-20) : 0
        lastLevel = level
        onBlock(ACARSBlock(bytes: block, crc: crcBytes, levelDB: level))
        state = .end
        wanted = 8
        inFrame = false
    }
}

// MARK: - Nachricht

public struct ACARSMessage: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public var time: Date
    public var mode: Character
    /// Kennzeichen („D-AIXC“), Punkte als Füllung entfernt
    public var registration: String
    /// Quittung: Zeichen, „NAK“ oder nil
    public var ack: String
    /// Zwei-Zeichen-Label („H1“, „Q0“, „_d“)
    public var label: String
    public var blockID: Character
    /// Von Flugzeug (Block-ID Ziffer) oder zum Flugzeug (Buchstabe)
    public var isDownlink: Bool
    public var messageNumber: String?
    public var flightID: String?
    public var text: String
    /// Mitschrift endet mit ETB: Fortsetzung folgt
    public var continues: Bool
    public var parityErrors: Int
    /// Mit Hilfe der Prüfsumme korrigierte Bits
    public var corrected: Int
    public var levelDB: Double

    public static func == (a: ACARSMessage, b: ACARSMessage) -> Bool { a.id == b.id }

    /// Leere Meldung (Quittung, Link-Test): kein Text
    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public enum ACARSParser {
    /// Block prüfen (Parität, CRC, Korrektur), dann zerlegen. nil, wenn nicht rettbar.
    public static func parse(_ block: ACARSBlock, at time: Date = Date()) -> ACARSMessage? {
        var bytes = block.bytes
        guard bytes.count >= 13 else { return nil }
        // Textanfang (STX oder ETX) auf gültige Bitmuster zwingen: Funkstörungen treffen dieses Zeichen oft
        bytes[12] = (bytes[12] & 0x83) | 0x02
        var corrected = 0
        let crcCheck: ([UInt8]) -> Bool = { b in
            var c = ACARS.crc(b)
            c = (c >> 8) ^ ACARS.crcTable[Int((c ^ UInt16(block.crc.0)) & 0xFF)]
            c = (c >> 8) ^ ACARS.crcTable[Int((c ^ UInt16(block.crc.1)) & 0xFF)]
            return c == 0
        }
        var parityBad = bytes.indices.filter { !ACARS.parityOK(bytes[$0]) }
        if !crcCheck(bytes) {
            guard let fixed = repair(bytes, parityBad: parityBad, check: crcCheck) else { return nil }
            corrected = zip(bytes, fixed.bytes).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
            bytes = fixed.bytes
            parityBad = bytes.indices.filter { !ACARS.parityOK(bytes[$0]) }
        }
        guard parityBad.isEmpty else { return nil }
        let t = bytes.map { $0 & 0x7F }
        var k = 0
        let mode = Character(UnicodeScalar(t[k])); k += 1
        var reg = ""
        for _ in 0..<7 { if t[k] != 0x2E { reg.append(Character(UnicodeScalar(t[k]))) }; k += 1 }
        var ack = ""
        if t[k] == 0x15 { ack = "NAK" } else if t[k] != 0x15 { ack = String(UnicodeScalar(t[k])) }
        k += 1
        var label = String(UnicodeScalar(t[k])); k += 1
        label.append(t[k] == 0x7F ? "d" : Character(UnicodeScalar(t[k]))); k += 1
        let bid = Character(UnicodeScalar(t[k])); k += 1
        let down = bid.isNumber
        let bs = t[k]; k += 1
        let end = bytes.count - 1                     // letztes Byte: ETX oder ETB
        var number: String?, flight: String?
        var text = ""
        if bs != 0x03 {
            if down {
                var n = ""
                for _ in 0..<4 where k < end { n.append(Character(UnicodeScalar(t[k]))); k += 1 }
                var f = ""
                for _ in 0..<6 where k < end { f.append(Character(UnicodeScalar(t[k]))); k += 1 }
                number = n
                flight = f
            }
            while k < end {
                let c = t[k]
                if c == 0x0A { text.append("\n") } else if c == 0x0D { text += "" } else if c >= 0x20 { text.append(Character(UnicodeScalar(c))) }
                k += 1
            }
        }
        return ACARSMessage(time: time, mode: mode, registration: reg, ack: ack, label: label, blockID: bid, isDownlink: down,
                            messageNumber: number, flightID: flight?.trimmingCharacters(in: .whitespaces), text: text,
                            continues: bytes[end] == ACARS.etb, parityErrors: block.bytes.indices.filter { !ACARS.parityOK(block.bytes[$0]) }.count,
                            corrected: corrected, levelDB: block.levelDB)
    }

    /// Prüfsumme stimmt nicht: Bitfehler suchen. 1. Bits der Zeichen mit falscher Parität (je ein Bit), 2. ein Bit irgendwo,
    /// 3. zwei Bits im selben Zeichen (die Parität bleibt dabei richtig).
    static func repair(_ bytes: [UInt8], parityBad: [Int], check: ([UInt8]) -> Bool) -> (bytes: [UInt8], count: Int)? {
        var b = bytes
        if parityBad.count > 0 && parityBad.count <= 3 {
            func rec(_ i: Int) -> Bool {
                if i == parityBad.count { return check(b) }
                for bit in 0..<8 {
                    b[parityBad[i]] ^= 1 << UInt8(bit)
                    if rec(i + 1) { return true }
                    b[parityBad[i]] ^= 1 << UInt8(bit)
                }
                return false
            }
            if rec(0) { return (b, parityBad.count) }
            b = bytes
        }
        if parityBad.isEmpty {
            // Fehler in den Prüfbytes selbst: dann sind die Daten in Ordnung, nur die Prüfsumme nicht (nicht korrigierbar hier)
            for i in b.indices {
                for x in 0..<8 {
                    for y in (x + 1)..<8 {
                        b[i] ^= (1 << UInt8(x)) | (1 << UInt8(y))
                        if check(b) { return (b, 2) }
                        b[i] ^= (1 << UInt8(x)) | (1 << UInt8(y))
                    }
                }
            }
        }
        return nil
    }
}

/// Empfänger: Demodulator und Prüfung in einem
public final class ACARSReceiver {
    private let demod: ACARSDemodulator
    public init(sampleRate: Double = 12_000) { demod = ACARSDemodulator(sampleRate: sampleRate) }
    public var inFrame: Bool { demod.inFrame }
    public func reset() { demod.reset() }
    public func process(_ samples: UnsafeBufferPointer<Float>, now: Date = Date(), emit: (ACARSMessage) -> Void) {
        demod.process(samples) { blk in
            if let m = ACARSParser.parse(blk, at: now) { emit(m) }
        }
    }
}

// MARK: - Testsignal

/// Erzeugt ACARS-Blöcke als MSK-Audio (nur für Tests)
public enum ACARSSignalGenerator {
    /// Bytes eines Blocks: Vorspann, SYN SYN SOH, Text, Prüfbytes, DEL; ungerade Parität
    public static func block(mode: Character = "2", registration: String, ack: Character = "\u{15}", label: String, blockID: Character,
                             messageNumber: String = "M01A", flightID: String = "DLH123", text: String, downlink: Bool = true) -> [UInt8] {
        func par(_ b: UInt8) -> UInt8 { b.nonzeroBitCount & 1 == 1 ? b : b | 0x80 }
        var body: [UInt8] = []
        body.append(UInt8(mode.asciiValue ?? 0x32))
        let reg = String(repeating: ".", count: max(0, 7 - registration.count)) + registration
        body += reg.utf8.prefix(7)
        body.append(ack.asciiValue ?? 0x15)
        let lb = Array(label.utf8)
        body.append(lb[0])
        body.append(lb.count > 1 && lb[1] != 0x5F ? lb[1] : 0x7F)
        if label == "_d" { body[body.count - 2] = 0x5F; body[body.count - 1] = 0x7F }
        body.append(blockID.asciiValue ?? 0x31)
        let emptyBlock = text.isEmpty && !downlink
        if emptyBlock {
            // Meldung ohne Text: das Zeichen nach der Block-ID ist gleich das Ende (ETX)
        } else {
            body.append(0x02)
            if downlink { body += Array(messageNumber.utf8.prefix(4)); body += Array(flightID.padding(toLength: 6, withPad: " ", startingAt: 0).utf8) }
            body += Array(text.utf8)
        }
        var out = body.map(par)
        out.append(par(0x03))                                  // ETX: Paritätsbit ergibt 0x83 (bei leerer Meldung zugleich Textanfang)
        var c: UInt16 = 0
        for b in out { c = (c >> 8) ^ ACARS.crcTable[Int((c ^ UInt16(b)) & 0xFF)] }
        out.append(UInt8(c & 0xFF)); out.append(UInt8(c >> 8)); out.append(0x7F)
        return [0x2B, 0x2A, 0x16, 0x16, 0x01] + out
    }

    /// MSK-Audio als versetzte QPSK mit Halbsinus-Impulsen (so liest es der Demodulator): das Bit k (±1) moduliert abwechselnd
    /// die cos- und die sin-Komponente des 1800-Hz-Trägers, Impulsdauer zwei Bitzeiten, Versatz eine Bitzeit.
    public static func audio(blocks: [[UInt8]], sampleRate: Double = 12_000, amplitude: Float = 0.5, prekeyBits: Int = 160,
                             gapBits: Int = 400) -> [Float] {
        var bitsAll: [Int] = []
        for b in blocks {
            for _ in 0..<prekeyBits { bitsAll.append(1) }
            for byte in b { for k in 0..<8 { bitsAll.append(Int((byte >> UInt8(k)) & 1)) } }
            for _ in 0..<gapBits { bitsAll.append(1) }
        }
        let per = sampleRate / 2400                          // Abtastwerte je Bit
        let total = Int(Double(bitsAll.count + 2) * per)
        var out = [Float](repeating: 0, count: total)
        for (k, bit) in bitsAll.enumerated() {
            // Das Bit steckt im Vorzeichen, wechselnd je zwei Bitzeiten gespiegelt (so ist die Datenfolge gegen Dauerton codiert)
            let c: Float = (bit == 1 ? 1 : -1) * ((k / 2) % 2 == 0 ? 1 : -1)
            let start = Double(k) * per
            let n = Int(2 * per)
            for i in 0...n {
                let t = (Double(i) / Double(n))             // 0…1 über zwei Bitzeiten
                let pulse = Float(sin(Double.pi * t))
                let idx = Int(start.rounded()) + i
                guard idx < total else { break }
                let time = Double(idx) / sampleRate
                let carrier = k % 2 == 0 ? cos(2 * .pi * 1800 * time) : -sin(2 * .pi * 1800 * time)
                out[idx] += amplitude * c * pulse * Float(carrier)
            }
        }
        return out
    }
}
