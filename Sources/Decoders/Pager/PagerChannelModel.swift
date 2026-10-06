// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Nachbildung eines UKW-Funkkanals und Testmeldungen für Funkruf (POCSAG): nur für Logiktests und Tools/PagerBench.
// Kette: Bitstrom → FM-Modulator (Hub 4,5 kHz) → Rauschen und Zwischenfrequenzfilter → Diskriminator → NF-Kette des Empfängers
// (Entzerrung, Kopplungs-Hochpass, Sprachband, Rauschsperre, Knackser) mit 48 kHz Abtastrate.

// MARK: - Zufall

struct PagerRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    mutating func gauss() -> Double {
        let u1 = max(Double.random(in: 0..<1, using: &self), 1e-12), u2 = Double.random(in: 0..<1, using: &self)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

// MARK: - Filter

struct PagerBiquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1 = 0.0, z2 = 0.0
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
    static func lowpass(_ fc: Double, chRate: Double, q: Double = 0.7071) -> PagerBiquad {
        let w = 2 * Double.pi * fc / chRate, c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al
        return PagerBiquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0, a1: -2 * c / a0, a2: (1 - al) / a0)
    }
    static func highpass(_ fc: Double, chRate: Double, q: Double = 0.7071) -> PagerBiquad {
        let w = 2 * Double.pi * fc / chRate, c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al
        return PagerBiquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - al) / a0)
    }
    /// Einpoliger Tiefpass (Entzerrung, 6 dB/Oktave), Verstärkung 1 bei Gleichspannung
    static func onePoleLow(_ fc: Double, chRate: Double) -> PagerBiquad {
        let a = exp(-2 * Double.pi * fc / chRate)
        return PagerBiquad(b0: 1 - a, b1: 0, b2: 0, a1: -a, a2: 0)
    }
    /// Einpoliger Hochpass (Kopplungskondensator)
    static func onePoleHigh(_ fc: Double, chRate: Double) -> PagerBiquad {
        let a = exp(-2 * Double.pi * fc / chRate)
        return PagerBiquad(b0: (1 + a) / 2, b1: -(1 + a) / 2, b2: 0, a1: -a, a2: 0)
    }
}

// MARK: - Kanalmodell

struct PagerRadioChannel {
    var name: String
    /// Rauschabstand in der Zwischenfrequenzbandbreite (nil = rauschfrei)
    var snrDB: Double?
    /// Ablage der Trägerfrequenz in Hz (Fehlabstimmung)
    var offsetHz = 0.0
    /// NF-Kette
    enum Audio { case flat, deemph2k, deemph300, ac30, ac150, ac300, voiceBand, deemph300ac300 }
    var audio: Audio = .flat
    var hubHz = 4500.0
    /// Zwischenfrequenzbandbreite in Hz
    var ifBandwidth = 12_000.0
    /// Maximale Amplitude im Audio (Vollaussteuerung = 1)
    var level = 0.3
    /// Taktfehler des Senders
    var baudError = 0.0
    /// Rauschsperre: ohne Träger genau Stille (statt Rauschen), Öffnen nach 60 ms, Schließen nach 100 ms
    var squelch = false
    /// Frequenzdrift während der Aussendung in Hz (linear)
    var driftHz = 0.0
    /// Knackser (Zündfunken o. ä.) je Sekunde, Spitze in Hub-Einheiten
    var impulsesPerSecond = 0.0
    /// Rauschen oder Stille vor der Aussendung in Sekunden
    var leadSeconds = 0.6
    /// Abtastrate der Aufnahme (die App wandelt von der Quellrate)
    var recordRate = 48_000.0
}

let pagerChannelRate = 48_000.0
private let chRate = pagerChannelRate

func pagerFMAudio(bits: [UInt8], baud: Int, channel: PagerRadioChannel, lead: Int, tail: Int, rng: inout PagerRNG) -> [Float] {
    let perBit = chRate / (Double(baud) * (1 + channel.baudError))
    // Bitstrom → NRZ mit leicht gerundeten Flanken (Senderfilter ≈ 0,8 × Baudrate)
    var nrz: [Double] = [Double](repeating: 0, count: lead)
    var acc = 0.0
    for b in bits {
        acc += perBit
        // Bit 1 = tiefere Frequenz (POCSAG: 0 = höhere Frequenz)
        let v: Double = b == 1 ? -1 : 1
        while acc >= 1 { nrz.append(v); acc -= 1 }
    }
    nrz += [Double](repeating: 0, count: tail)
    var txLP = PagerBiquad.lowpass(0.9 * Double(baud), chRate: chRate)
    let shaped = nrz.map { txLP.process($0) }

    // FM-Modulator im komplexen Basisband
    var phase = 0.0
    var re = [Double](repeating: 0, count: shaped.count), im = re
    let carrierOn = nrz.map { _ in 1.0 }
    _ = carrierOn
    // Sender schaltet den Träger erst mit dem Vorspann ein: davor und danach Rauschen allein
    let onStart = lead, onEnd = nrz.count - tail
    var sigma = 0.0
    if let snr = channel.snrDB {
        // Signalleistung 1, Rauschleistung in `ifBandwidth` = 1/SNR → gesamt (48 kHz) mit Faktor chRate/ifBandwidth
        sigma = (chRate / channel.ifBandwidth / pow(10, snr / 10) / 2).squareRoot()
    }
    let ramp = channel.driftHz / Double(max(1, onEnd - onStart))
    for i in shaped.indices {
        let drift = i >= onStart ? ramp * Double(min(i, onEnd) - onStart) : 0
        phase += 2 * .pi * (channel.hubHz * shaped[i] + channel.offsetHz + drift) / chRate
        let on = i >= onStart && i < onEnd
        let amp = on ? 1.0 : 0.0
        re[i] = amp * cos(phase) + sigma * rng.gauss()
        im[i] = amp * sin(phase) + sigma * rng.gauss()
    }
    // Zwischenfrequenzfilter (komplexes Tiefpassfilter 4. Ordnung, Grenzfrequenz = halbe Bandbreite)
    var f1r = PagerBiquad.lowpass(channel.ifBandwidth / 2, chRate: chRate), f2r = f1r, f1i = f1r, f2i = f1r
    for i in re.indices {
        re[i] = f2r.process(f1r.process(re[i]))
        im[i] = f2i.process(f1i.process(im[i]))
    }
    // Diskriminator
    var out = [Double](repeating: 0, count: re.count)
    var pr = re[0], pi_ = im[0]
    for i in 1..<re.count {
        let cr = re[i] * pr + im[i] * pi_, ci = im[i] * pr - re[i] * pi_
        out[i] = atan2(ci, cr) * chRate / (2 * .pi) / channel.hubHz     // ±1 = ±Hub
        pr = re[i]; pi_ = im[i]
    }
    // NF-Kette des Empfängers
    var chain: [PagerBiquad] = []
    switch channel.audio {
    case .flat: break
    case .deemph2k: chain = [.onePoleLow(2122, chRate: chRate)]
    case .deemph300: chain = [.onePoleLow(300, chRate: chRate)]
    case .ac30: chain = [.onePoleHigh(30, chRate: chRate)]
    case .ac150: chain = [.onePoleHigh(150, chRate: chRate)]
    case .ac300: chain = [.onePoleHigh(300, chRate: chRate)]
    case .deemph300ac300: chain = [.onePoleLow(300, chRate: chRate), .onePoleHigh(300, chRate: chRate)]
    case .voiceBand: chain = [.highpass(300, chRate: chRate), .highpass(300, chRate: chRate), .lowpass(3000, chRate: chRate), .onePoleLow(1000, chRate: chRate)]
    }
    var y = out
    for i in y.indices {
        var v = y[i]
        for k in chain.indices { v = chain[k].process(v) }
        y[i] = v
    }
    // Pegel: Spitze des Nutzsignals (innerhalb der Aussendung) auf `level`
    let carrierRange = onStart..<onEnd
    let peak = max(carrierRange.map { abs(y[$0]) }.max() ?? 1, 1e-9)
    let norm = channel.level / (channel.audio == .flat ? 1.0 : peak)
    var res = y.map { max(-1, min(1, $0 * norm)) }
    // Knackser
    if channel.impulsesPerSecond > 0 {
        let n = Int(channel.impulsesPerSecond * Double(res.count) / chRate)
        for _ in 0..<n {
            let at = Int.random(in: 0..<res.count, using: &rng)
            let v = (Bool.random(using: &rng) ? 1.0 : -1.0) * channel.level * 3
            for k in 0..<12 where at + k < res.count { res[at + k] += v * exp(-Double(k) / 3) }
        }
    }
    // Rauschsperre: außerhalb des Trägers Stille
    if channel.squelch {
        let open = max(0, onStart + Int(0.06 * chRate)), close = min(res.count, onEnd + Int(0.1 * chRate))
        for i in res.indices where i < open || i >= close { res[i] = 0 }
    }
    return res.map { Float(max(-1, min(1, $0))) }
}

// MARK: - Meldungen

struct PagerTestMessage: Equatable, Hashable {
    var ric: Int
    var function: Int
    var text: String
    /// nur beim Empfang: korrigierte Bits und unlesbare Codewörter
    var corrected = 0
    var damaged = 0
    static func == (a: PagerTestMessage, b: PagerTestMessage) -> Bool { a.ric == b.ric && a.function == b.function && a.text == b.text }
    func hash(into h: inout Hasher) { h.combine(ric); h.combine(function); h.combine(text) }
}

private let pagerTestWords = ["DAPNET", "Test", "Alarm", "Wetter", "Sturm", "Hamburg", "Wuerzburg", "Berlin", "Kanal", "Antenne", "Rufzeichen", "Sendeplan", "Relais", "DB0WUE", "DL1ABC", "DM5XY", "Frequenz", "Daten", "Pager", "Nachricht", "Zeit", "Einsatz", "Bereitschaft", "Probe", "OK", "QSL", "73", "Gruss"]

func pagerRandomMessage(_ rng: inout PagerRNG, numeric: Bool = false) -> PagerTestMessage {
    let ric = Int.random(in: 1000...2_000_000, using: &rng)
    if numeric {
        let n = Int.random(in: 6...20, using: &rng)
        let digits = Array("0123456789")
        return PagerTestMessage(ric: ric, function: 0, text: String((0..<n).map { _ in digits[Int.random(in: 0..<10, using: &rng)] }))
    }
    var t = ""
    let target = Int.random(in: 20...70, using: &rng)
    while t.count < target { t += (t.isEmpty ? "" : " ") + pagerTestWords[Int.random(in: 0..<pagerTestWords.count, using: &rng)] }
    return PagerTestMessage(ric: ric, function: 3, text: t)
}

/// Bitstrom einer Aussendung mit mehreren Meldungen in gemeinsamen Stapeln: Vorspann, Synchronwort, 16 Codewörter je Stapel
func pagerTransmissionBits(_ msgs: [PagerTestMessage], preamble: Int = 576) -> [UInt8] {
    var batch: [UInt32] = []                           // aktueller Stapel (bis 16 Wörter)
    var batches: [[UInt32]] = []
    func push(_ w: UInt32) {
        batch.append(w)
        if batch.count == 16 { batches.append(batch); batch = [] }
    }
    for m in msgs {
        // Wörter der Meldung
        var data: [UInt32] = []
        var bits: [UInt8] = []
        if m.function == 0 {
            for ch in m.text { let n = POCSAG.numericTable.firstIndex(of: ch) ?? 3; for k in stride(from: 3, through: 0, by: -1) { bits.append(UInt8((n >> k) & 1)) } }
        } else {
            for u in m.text.utf8 { for k in 0..<7 { bits.append((u >> UInt8(k)) & 1) } }
        }
        // Auffüllen: Ziffernnachrichten mit Leerzeichen-Halbbyte, Klartext mit Nullbits (NUL)
        let spaceNibble = POCSAG.numericTable.firstIndex(of: " ") ?? 3
        while bits.count % 20 != 0 {
            if m.function == 0 { for k in stride(from: 3, through: 0, by: -1) { bits.append(UInt8((spaceNibble >> k) & 1)) } } else { bits.append(0) }
        }
        for w in stride(from: 0, to: bits.count, by: 20) {
            var v: UInt32 = 1 << 20
            for k in 0..<20 { v |= UInt32(bits[w + k]) << UInt32(19 - k) }
            data.append(v)
        }
        let frame = m.ric & 7
        // Position im Stapel: Adresswort gehört in Rahmen `frame` (Wort 2·frame oder 2·frame+1)
        while batch.count < frame * 2 { push(POCSAG.idle) }
        if batch.count > frame * 2 + 1 { while !batch.isEmpty { push(POCSAG.idle) }; while batch.count < frame * 2 { push(POCSAG.idle) } }
        push(PagerBCH.encode((UInt32((m.ric >> 3) & 0x3FFFF) << 2) | UInt32(m.function & 3)))
        for d in data { push(PagerBCH.encode(d)) }
    }
    while !batch.isEmpty { push(POCSAG.idle) }
    var out: [UInt8] = []
    for i in 0..<preamble { out.append(i & 1 == 0 ? 1 : 0) }
    for b in batches {
        for k in stride(from: 31, through: 0, by: -1) { out.append(UInt8((POCSAG.sync >> UInt32(k)) & 1)) }
        for w in b { for k in stride(from: 31, through: 0, by: -1) { out.append(UInt8((w >> UInt32(k)) & 1)) } }
    }
    return out
}

