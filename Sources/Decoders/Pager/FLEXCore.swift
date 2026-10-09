// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// MARK: - FLEX (Motorola, 1600/3200 Baud, 2 oder 4 Pegel)

/// FLEX-Empfänger: Symbole aus dem Diskriminator-Audio, Synchronisation (Sync 1 → FIW → Sync 2 → Daten), BCH-Prüfung,
/// Entschachteln der vier Phasen A–D, Adress-, Vektor- und Nachrichtenwörter.
///
/// Aufbau der Übertragung (je Rahmen 1,875 s): 32 Bit Bitsynchronisation (1010…), Synchronwort `A` + Marker `0xA6C6AAAA` + `~A`
/// (A legt Baudrate und Pegelzahl fest), Rahmeninformationswort (FIW, 32 Bit), 25 ms Sync 2, dann 11 Blöcke × 8 Codewörter je Phase.
public final class FLEXReceiver {
    public let sampleRate: Double

    static let syncMarker: UInt32 = 0xA6C6_AAAA
    static let phaseWords = 88
    static let bcd = Array("0123456789 U -][")

    private enum State { case sync1, fiw, sync2, data }
    private enum PageType: Int { case secure = 0, shortInstruction, tone, standardNumeric, specialNumeric, alphanumeric, binary, numberedNumeric }

    // Symbolerkennung
    private var sampleLast = 0.0
    private var locked = false
    private var phase = 0.0                       // 0…1 je Symbolzeit
    private var baud = 1600.0
    private var symbolCount = 0
    private var envelopeSum = 0.0
    private var envelopeCount = 0
    private var envelope = 0.0
    private var zero = 0.0
    private var lockBuffer: UInt64 = 0
    private var symCount = [0, 0, 0, 0]
    private var timeout = 0
    private var nonConsecutive = 0

    // Zustandsmaschine
    private var state = State.sync1
    private var syncBuffer: UInt64 = 0
    private var polarity = 0                       // 1 = invertiert
    private var syncBaud = 1600
    private var syncLevels = 2
    private var fiwCount = 0
    private var fiwRaw: UInt32 = 0
    private var cycle = 0
    private var frame = 0
    private var sync2Count = 0
    private var dataCount = 0
    private var phases: [[UInt32]] = Array(repeating: Array(repeating: 0, count: phaseWords), count: 4)
    private var idleCount = [0, 0, 0, 0]
    private var phaseToggle = 0
    private var dataBitCounter = 0
    /// Gruppenrufe: Gruppenadresse 2 029 568 … 2 029 583; die Mitglieder meldet eine „Kurzanweisung“ vorher
    private struct Group { var members: [Int] = []; var frame = 0; var cycle = 0 }
    private var groups: [Int: Group] = [:]
    static let groupBase = 2_029_568

    /// Wird nach einer Rahmenübertragung gesetzt (für die Anzeige)
    public private(set) var isSynced = false
    public private(set) var level = 0.0

    public init(sampleRate: Double = 24_000) {
        self.sampleRate = sampleRate
    }

    public func reset() {
        locked = false
        state = .sync1
        phase = 0
        baud = 1600
        lockBuffer = 0
        syncBuffer = 0
        isSynced = false
        envelope = 0
        symCount = [0, 0, 0, 0]
        groups.removeAll()
    }

    public func process(_ block: UnsafeBufferPointer<Float>, now: Date = Date(), emit: (PagerMessage) -> Void) {
        for x in block { demodulate(Double(x), now: now, emit: emit) }
        isSynced = state != .sync1
    }

    // MARK: Symbole

    /// Ein Abtastwert; liefert true am Ende einer Symbolzeit
    private func buildSymbol(_ raw: Double) -> Bool {
        var sample = raw
        // Gleichanteil im Vorspann schätzen
        if state == .sync1 { zero = (zero * (sampleRate * 0.01) + sample) / (sampleRate * 0.01 + 1) }
        sample -= zero
        if locked {
            if state == .sync1 {
                envelopeSum += abs(sample)
                envelopeCount += 1
                envelope = envelopeSum / Double(envelopeCount)
            }
        } else {
            envelope = 0
            envelopeSum = 0
            envelopeCount = 0
            baud = 1600
            timeout = 0
            nonConsecutive = 0
            state = .sync1
        }
        // Mittlere 80 % der Symbolzeit auswerten
        if phase > 0.1 && phase < 0.9 {
            if sample > 0 {
                if sample > envelope * 0.667 { symCount[3] += 1 } else { symCount[2] += 1 }
            } else {
                if sample < -envelope * 0.667 { symCount[0] += 1 } else { symCount[1] += 1 }
            }
        }
        // Nulldurchgang: Takt nachführen
        if (sampleLast < 0 && sample >= 0) || (sampleLast >= 0 && sample < 0) {
            let error = phase < 0.5 ? phase : phase - 1
            phase -= error * (locked ? 0.045 : 0.05)
            if phase > 0.1 && phase < 0.9 {
                nonConsecutive += 1
                if nonConsecutive > 20 && locked { locked = false }
            } else {
                nonConsecutive = 0
            }
            timeout = 0
        }
        sampleLast = sample
        phase += baud / sampleRate
        if phase > 1 {
            phase -= 1
            return true
        }
        return false
    }

    private func demodulate(_ sample: Double, now: Date, emit: (PagerMessage) -> Void) {
        guard buildSymbol(sample) else { return }
        nonConsecutive = 0
        symbolCount += 1
        // häufigstes Symbol dieser Symbolzeit
        var best = 0, bestCount = 0
        for j in 0..<4 where symCount[j] > bestCount { best = j; bestCount = symCount[j] }
        symCount = [0, 0, 0, 0]
        if locked {
            handleSymbol(best, now: now, emit: emit)
        } else {
            // Verriegelung: die äußeren Pegel wechseln einander ab (Vorspann 1010…)
            lockBuffer = (lockBuffer << 2) | UInt64(best ^ 1)
            let pattern = lockBuffer ^ 0x6666_6666_6666_6666
            let mask = (UInt64(1) << 48) - 1
            if pattern & mask == 0 || (~pattern) & mask == 0 {
                locked = true
                lockBuffer = 0
                symbolCount = 0
            }
        }
        timeout += 1
        if timeout > 100 { locked = false }
    }

    // MARK: Zustandsmaschine

    private func handleSymbol(_ sym: Int, now: Date, emit: (PagerMessage) -> Void) {
        let rectified = polarity == 1 ? 3 - sym : sym
        switch state {
        case .sync1:
            syncBuffer = (syncBuffer << 1) | (sym < 2 ? 1 : 0)
            var code = Self.syncCheck(syncBuffer)
            if code != 0 { polarity = 0 } else {
                code = Self.syncCheck(~syncBuffer)
                if code != 0 { polarity = 1 }
            }
            if code != 0, let mode = Self.mode(for: code) {
                syncBaud = mode.baud
                syncLevels = mode.levels
                state = .fiw
            }
            fiwCount = 0
            fiwRaw = 0
        case .fiw:
            fiwCount += 1
            if fiwCount >= 16 { fiwRaw = (fiwRaw >> 1) | (rectified > 1 ? 0x8000_0000 : 0) }
            if fiwCount == 48 {
                if decodeFIW() {
                    sync2Count = 0
                    baud = Double(syncBaud)
                    state = .sync2
                } else {
                    state = .sync1
                }
            }
        case .sync2:
            sync2Count += 1
            if sync2Count == syncBaud * 25 / 1000 {
                dataCount = 0
                clearPhases()
                state = .data
            }
        case .data:
            let idle = readData(rectified)
            dataCount += 1
            if dataCount == syncBaud * 1760 / 1000 || idle {
                decodeData(now: now, emit: emit)
                baud = 1600
                state = .sync1
                dataCount = 0
            }
        }
    }

    /// 64-Bit-Synchronisation `AAAA : marker : ~AAAA`: Marker mit weniger als vier Fehlern, Außencode ebenso
    static func syncCheck(_ buf: UInt64) -> Int {
        let marker = UInt32((buf & 0x0000_FFFF_FFFF_0000) >> 16)
        let high = UInt16((buf & 0xFFFF_0000_0000_0000) >> 48)
        let low = ~UInt16(buf & 0xFFFF)
        if (marker ^ syncMarker).nonzeroBitCount < 4 && (low ^ high).nonzeroBitCount < 4 { return Int(high) }
        return 0
    }

    static func mode(for code: Int) -> (baud: Int, levels: Int)? {
        let modes: [(Int, Int, Int)] = [(0x870C, 1600, 2), (0xB068, 1600, 4), (0x7B18, 3200, 2), (0xDEA0, 3200, 4), (0x4C7C, 3200, 4)]
        for m in modes where (m.0 ^ code).nonzeroBitCount < 4 { return (m.1, m.2) }
        return nil
    }

    // MARK: BCH

    /// FLEX-Wörter kommen mit dem zuerst gesendeten Bit niederwertig an: umdrehen, prüfen, zurückdrehen
    static func fix(_ word: UInt32) -> UInt32? {
        let rev = reverse(word)
        guard let f = PagerBCH.correct(rev) else { return nil }
        return reverse(f.word)
    }

    static func reverse(_ w: UInt32) -> UInt32 {
        var x = w, r: UInt32 = 0
        for _ in 0..<32 { r = (r << 1) | (x & 1); x >>= 1 }
        return r
    }

    private func decodeFIW() -> Bool {
        guard let fiw = Self.fix(fiwRaw) else { return false }
        let w = fiw & 0x1F_FFFF
        var checksum = (w & 0xF) + ((w >> 4) & 0xF) + ((w >> 8) & 0xF) + ((w >> 12) & 0xF) + ((w >> 16) & 0xF) + ((w >> 20) & 1)
        checksum &= 0xF
        guard checksum == 0xF else { return false }
        cycle = Int((w >> 4) & 0xF)
        frame = Int((w >> 8) & 0x7F)
        // Gruppen, deren Rahmen schon vorbei ist (Meldung verpasst), verwerfen
        for (bit, g) in groups {
            var expired = false
            if cycle == g.cycle { expired = g.frame < frame }
            else if cycle == 0 { expired = g.cycle == 15 }
            else if cycle == 15 && g.cycle == 0 { expired = false }
            else if g.cycle < cycle { expired = true }
            if expired { groups[bit] = nil }
        }
        return true
    }

    // MARK: Daten

    private func clearPhases() {
        for p in 0..<4 { for i in 0..<Self.phaseWords { phases[p][i] = 0 } }
        idleCount = [0, 0, 0, 0]
        phaseToggle = 0
        dataBitCounter = 0
    }

    private func readData(_ sym: Int) -> Bool {
        let bitA = sym > 1
        let bitB = syncLevels == 4 && (sym == 1 || sym == 2)
        if syncBaud == 1600 { phaseToggle = 0 }
        let idx = ((dataBitCounter >> 5) & 0xFFF8) | (dataBitCounter & 7)
        if idx >= Self.phaseWords {
            return true
        }
        func push(_ p: Int, _ b: Bool) { phases[p][idx] = (phases[p][idx] >> 1) | (b ? 0x8000_0000 : 0) }
        func checkIdle(_ p: Int) {
            if dataBitCounter & 0xFF == 0xFF, phases[p][idx] == 0 || phases[p][idx] == 0xFFFF_FFFF { idleCount[p] += 1 }
        }
        if phaseToggle == 0 {
            push(0, bitA); push(1, bitB)
            phaseToggle = 1
            checkIdle(0); checkIdle(1)
        } else {
            push(2, bitA); push(3, bitB)
            phaseToggle = 0
            checkIdle(2); checkIdle(3)
        }
        if syncBaud == 1600 || phaseToggle == 0 { dataBitCounter += 1 }
        // Alle aktiven Phasen leer: Rahmen zu Ende
        if syncBaud == 1600 {
            return syncLevels == 2 ? idleCount[0] > 0 : (idleCount[0] > 0 && idleCount[1] > 0)
        }
        return syncLevels == 2 ? (idleCount[0] > 0 && idleCount[2] > 0) : idleCount.allSatisfy { $0 > 0 }
    }

    private func decodeData(now: Date, emit: (PagerMessage) -> Void) {
        let active: [Int]
        if syncBaud == 1600 { active = syncLevels == 2 ? [0] : [0, 1] } else { active = syncLevels == 2 ? [0, 2] : [0, 1, 2, 3] }
        for p in active { decodePhase(p, now: now, emit: emit) }
    }

    private func decodePhase(_ p: Int, now: Date, emit: (PagerMessage) -> Void) {
        var words = phases[p]
        for i in 0..<Self.phaseWords {
            guard let f = Self.fix(words[i]) else { return }      // Ein unlesbares Wort: Phase verwerfen
            words[i] = f & 0x1F_FFFF
        }
        let biw = words[0]
        if biw == 0 || biw == 0x1F_FFFF { return }
        let voffset = Int((biw >> 10) & 0x3F)
        let aoffset = Int((biw >> 8) & 3) + 1
        if voffset < aoffset || voffset + (voffset - aoffset) > Self.phaseWords { return }
        let phaseName = ["A", "B", "C", "D"][p]
        var i = aoffset
        while i < voffset {
            defer { i += 1 }
            let j = voffset + i - aoffset
            if j >= Self.phaseWords { continue }
            let aw1 = words[i]
            if aw1 == 0 || aw1 == 0x1F_FFFF { continue }
            let longAddress = aw1 < 0x8001 || aw1 > 0x1E0000
            let capcode = Int(aw1) - 0x8000
            if capcode < 0 || capcode > 4_297_068_542 { continue }
            let viw = words[j]
            let type = PageType(rawValue: Int((viw >> 4) & 7)) ?? .secure
            var mw1 = Int((viw >> 7) & 0x7F)
            let len = Int((viw >> 14) & 0x7F)
            if type == .shortInstruction {
                // Dieses Gerät hört auf Gruppenruf `groupbit` im Rahmen `assigned`
                let assigned = Int((viw >> 10) & 0x7F)
                let bit = Int((viw >> 17) & 0x7F)
                guard bit < 16 else { continue }
                var g = groups[bit] ?? Group()
                if g.members.count < 999, !g.members.contains(capcode) { g.members.append(capcode) }
                g.frame = assigned
                g.cycle = assigned > frame ? cycle : (cycle + 1) % 16
                groups[bit] = g
                continue
            }
            var mw2 = mw1 + (len - 1)
            if mw1 == 0 && mw2 == 0 { continue }
            let detail = String(format: "%02d.%03d %@", cycle, frame, phaseName)
            let name = "FLEX \(syncBaud)" + (syncLevels == 4 ? "/4" : "")
            switch type {
            case .alphanumeric, .secure:
                if mw1 >= Self.phaseWords || mw2 >= Self.phaseWords { continue }
                let frag = Int((words[mw1] >> 11) & 3)
                let cont = Int((words[mw1] >> 10) & 1)
                let flag = cont == 1 ? "F" : (frag == 3 ? "K" : "C")
                mw1 += 1
                var chars: [UInt8] = []
                if mw1 <= mw2 {
                    for k in mw1...mw2 {
                        let dw = words[k]
                        if k > mw1 || frag != 3 { let c = UInt8(dw & 0x7F); if c != 3 { chars.append(c) } }
                        let c1 = UInt8((dw >> 7) & 0x7F); if c1 != 3 { chars.append(c1) }
                        let c2 = UInt8((dw >> 14) & 0x7F); if c2 != 3 { chars.append(c2) }
                    }
                }
                var text = ""
                for c in chars {
                    if let s = POCSAG.printable(c) { text += s } else if c != 0 { text += "·" }
                }
                let groupBit = capcode - Self.groupBase
                if (0..<16).contains(groupBit), let g = groups[groupBit], !g.members.isEmpty {
                    // Gruppenruf: dieselbe Meldung für jedes angemeldete Gerät
                    for member in g.members {
                        emit(PagerMessage(time: now, protocolName: name, address: member, function: type.rawValue, numeric: "", alpha: text,
                                          detail: detail + " " + flag + " Gruppe"))
                    }
                    groups[groupBit] = nil
                } else {
                    emit(PagerMessage(time: now, protocolName: name, address: capcode, function: type.rawValue, numeric: "", alpha: text,
                                      detail: detail + " " + flag))
                }
            case .standardNumeric, .specialNumeric, .numberedNumeric:
                if let digits = numeric(words, j, long: longAddress, type: type) {
                    emit(PagerMessage(time: now, protocolName: name, address: capcode, function: type.rawValue, numeric: digits, alpha: "", detail: detail))
                }
            case .tone:
                emit(PagerMessage(time: now, protocolName: name, address: capcode, function: type.rawValue, numeric: "", alpha: "", detail: detail))
            case .binary:
                mw2 = min(mw2, Self.phaseWords - 1)
                continue
            default:
                continue
            }
        }
    }

    /// Ziffern einer Numerik-Meldung (4 Bit je Ziffer, niederwertiges Bit zuerst, Füllzeichen 0xC entfällt)
    private func numeric(_ w: [UInt32], _ j: Int, long: Bool, type: PageType) -> String? {
        guard j >= 0, j < Self.phaseWords else { return nil }
        var w1 = Int(w[j] >> 7)
        var w2 = w1 >> 7
        w1 &= 0x7F
        w2 = (w2 & 7) + w1
        if w1 >= Self.phaseWords || w2 >= Self.phaseWords || (long && j + 1 >= Self.phaseWords) { return nil }
        var dw: UInt32
        if !long {
            dw = w[w1]
            w1 += 1
            w2 += 1
        } else {
            dw = w[j + 1]
        }
        var digit: UInt8 = 0
        var count = 4 + (type == .numberedNumeric ? 10 : 2)
        var out = ""
        var i = w1
        while i <= w2 {
            for _ in 0..<21 {
                digit = (digit >> 1) & 0x0F
                if dw & 1 != 0 { digit ^= 0x08 }
                dw >>= 1
                count -= 1
                if count == 0 {
                    if digit != 0x0C { out.append(Self.bcd[Int(digit)]) }
                    count = 4
                }
            }
            if i < w2, i < Self.phaseWords { dw = w[i] }
            i += 1
        }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }
}

// MARK: - Testsignal

/// Erzeugt FLEX-Rahmen (1600 Baud, 2 Pegel, Phase A) aus Meldungen, nur für Tests
public enum FLEXSignalGenerator {
    /// Codewort in FLEX-Bitordnung: 21 Datenbits niederwertig (zuerst gesendet), BCH und Parität dahinter
    static func word(_ data21: UInt32) -> UInt32 {
        var rev: UInt32 = 0
        for i in 0..<21 where data21 & (1 << UInt32(i)) != 0 { rev |= 1 << UInt32(20 - i) }
        return FLEXReceiver.reverse(PagerBCH.encode(rev))
    }

    /// Symbolfolge (true = hoher Pegel) für einen Rahmen mit Alphanumerik-Meldungen (Adresse, Text)
    public static func frame(messages: [(capcode: Int, text: String)], cycle: Int = 3, frameNumber: Int = 17) -> [Bool] {
        // Wörter der Phase A: 0 = BIW, dann Adressen, Vektoren, dann Nachrichtenwörter
        let n = messages.count
        var addresses: [UInt32] = [], vectors: [UInt32] = [], texts: [[UInt32]] = []
        for m in messages {
            addresses.append(UInt32(m.capcode + 0x8000))
            var bytes = Array(m.text.utf8)
            // erstes Textwort: unterstes Zeichen entfällt (frag = 3), also zwei Zeichen im ersten Wort
            var ws: [UInt32] = []
            let head: UInt32 = (3 << 11)                        // frag = 3, cont = 0
            ws.append(head)
            var first = true
            while !bytes.isEmpty || first {
                var w: UInt32 = 0
                let c1 = bytes.isEmpty ? 3 : bytes.removeFirst()
                let c2 = bytes.isEmpty ? 3 : bytes.removeFirst()
                if first { w = (UInt32(c1) << 7) | (UInt32(c2) << 14) } else {
                    let c0 = c1
                    let c1b = c2
                    let c2b = bytes.isEmpty ? 3 : bytes.removeFirst()
                    w = UInt32(c0) | (UInt32(c1b) << 7) | (UInt32(c2b) << 14)
                }
                ws.append(w)
                first = false
            }
            texts.append(ws)
        }
        let voffset = 1 + n + 1                                   // BIW + Adressen
        var idxMsg = voffset + n
        var words = [UInt32](repeating: 0, count: FLEXReceiver.phaseWords)
        for i in 0..<n {
            words[1 + i] = addresses[i]
            let mw1 = idxMsg
            let len = texts[i].count
            vectors.append((5 << 4) | (UInt32(mw1) << 7) | (UInt32(len) << 14))
            words[voffset + i] = vectors[i]
            for (k, w) in texts[i].enumerated() { words[mw1 + k] = w }
            idxMsg += len
        }
        words[0] = (UInt32(voffset) << 10) | (0 << 8)               // Adressen ab Wort 1
        // aoffset = ((biw >> 8) & 3) + 1 = 1; voffset wie berechnet
        let encoded = words.map { word($0) }
        // Verschachteln: Bit n eines Blocks gehört zu Wort (n & 7), Bit-Nr. (n >> 3)
        var dataBits: [Bool] = []
        for b in 0..<11 {
            for nn in 0..<256 {
                let w = encoded[b * 8 + (nn & 7)]
                dataBits.append((w >> UInt32(nn >> 3)) & 1 == 1)
            }
        }
        var out: [Bool] = []
        // Bitsynchronisation 1010…
        for i in 0..<64 { out.append(i & 1 == 0) }
        // Synchronwörter (invertiert: eine 1 ist der tiefe Pegel)
        let a = UInt64(0x870C)
        let sync = (a << 48) | (UInt64(FLEXReceiver.syncMarker) << 16) | (~a & 0xFFFF)
        for i in stride(from: 63, through: 0, by: -1) { out.append(!((sync >> UInt64(i)) & 1 == 1)) }
        // 16 Füllsymbole
        for i in 0..<16 { out.append(i & 1 == 0) }
        // FIW: Zyklus, Rahmen, Prüfsumme
        var fiw: UInt32 = (UInt32(cycle) << 4) | (UInt32(frameNumber) << 8)
        var sum: UInt32 = ((fiw >> 4) & 0xF) + ((fiw >> 8) & 0xF) + ((fiw >> 12) & 0xF) + ((fiw >> 16) & 0xF) + ((fiw >> 20) & 1)
        sum &= 0xF
        fiw |= (0xF &- sum) & 0xF
        let fw = word(fiw)
        for k in 0..<32 { out.append((fw >> UInt32(k)) & 1 == 1) }
        // Sync 2: 25 ms = 40 Symbole
        for i in 0..<40 { out.append(i & 1 == 0) }
        out += dataBits
        return out
    }

    /// Basisband-Audio (±amplitude) mit leicht gerundeten Flanken
    public static func audio(symbols: [Bool], baud: Double = 1600, sampleRate: Double = 24_000, amplitude: Float = 0.5,
                             inverted: Bool = false, lead: Double = 0.3, tail: Double = 0.5) -> [Float] {
        var out = [Float](repeating: 0, count: Int(lead * sampleRate))
        let per = sampleRate / baud
        var acc = 0.0
        var lp: Float = 0
        let k = Float(1 - exp(-2 * .pi * 1.2 * baud / sampleRate))
        for s in symbols {
            let level: Float = (s != inverted) ? amplitude : -amplitude
            acc += per
            while acc >= 1 {
                lp += k * (level - lp)
                out.append(lp)
                acc -= 1
            }
        }
        out += [Float](repeating: 0, count: Int(tail * sampleRate))
        return out
    }
}
