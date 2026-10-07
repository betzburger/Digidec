// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Sender für Tests und Vorführung: baut die Bursts einer TETRA-Basisstation (Abwärtsstrecke, Dauersendung) mit Synchronisation,
// Systeminformation, Rufsignalisierung und Sprachverkehr und moduliert sie als π/4-DQPSK mit Wurzel-Kosinus-Filter (α = 0,35).

struct TETRABitWriter {
    var bits: [UInt8] = []
    mutating func put(_ value: Int, _ count: Int) {
        for i in stride(from: count - 1, through: 0, by: -1) { bits.append(UInt8((value >> i) & 1)) }
    }
    mutating func put(bits more: [UInt8]) { bits += more }
    var count: Int { bits.count }
}

public enum TETRAPDUBuilder {
    /// Auffüllen auf `count` Bits mit Nullen
    static func pad(_ bits: [UInt8], to count: Int) -> [UInt8] {
        bits.count >= count ? Array(bits.prefix(count)) : bits + [UInt8](repeating: 0, count: count - bits.count)
    }

    /// MAC-BROADCAST SYSINFO (124 Bits)
    public static func sysinfo(mainCarrier: Int, band: Int, offsetIndex: Int, duplex: Int, locationArea: Int, serviceDetails: Int, hyperframe: Int = 0) -> [UInt8] {
        var w = TETRABitWriter()
        w.put(2, 2); w.put(0, 2)
        w.put(mainCarrier, 12); w.put(band, 4); w.put(offsetIndex, 2); w.put(duplex, 3); w.put(0, 1)
        w.put(0, 2); w.put(5, 3); w.put(8, 4); w.put(8, 4); w.put(3, 4)
        w.put(0, 1); w.put(hyperframe, 16)
        w.put(0, 2); w.put(0, 20)                              // Optionsfeld, Zugangsparameter
        w.put(locationArea, 14); w.put(0, 16); w.put(serviceDetails, 12)
        return pad(w.bits, to: 124)
    }

    /// MAC-RESOURCE mit Adresse SSI + Gebrauchskennung (Gruppenruf) oder SSI, Kanalzuweisung optional, Inhalt = LLC BL-UDATA + CMCE
    static func resource(address: Int, usageMarker: Int?, allocation: (timeslotMask: Int, carrier: Int)?, tmSDU: [UInt8], total: Int = 124) -> [UInt8] {
        var w = TETRABitWriter()
        // Kopf, Länge in Oktetten später einsetzen
        var header = TETRABitWriter()
        header.put(0, 2)                                      // MAC-RESOURCE
        header.put(1, 1)                                      // Füllbits vorhanden
        header.put(0, 1)                                      // Lage der Zuteilung
        header.put(0, 2)                                      // Verschlüsselung aus
        header.put(0, 1)                                      // Zufallszugriff
        let lengthPlace = header.count
        header.put(0, 6)
        if let u = usageMarker { header.put(6, 3); header.put(address, 24); header.put(u, 6) } else { header.put(1, 3); header.put(address, 24) }
        header.put(0, 1)                                      // Leistungssteuerung
        header.put(0, 1)                                      // Zeitschlitzvergabe
        if let a = allocation {
            header.put(1, 1)
            header.put(0, 2); header.put(a.timeslotMask, 4); header.put(3, 2); header.put(0, 1); header.put(0, 1)
            header.put(a.carrier, 12); header.put(0, 1); header.put(1, 2)
        } else {
            header.put(0, 1)
        }
        w.bits = header.bits + tmSDU
        // Länge in Oktetten (aufgerundet, mit mindestens einem Füllbit)
        let octets = (w.bits.count + 1 + 7) / 8
        w.bits.append(1)
        while w.bits.count < octets * 8 { w.bits.append(0) }
        for i in 0..<6 { w.bits[lengthPlace + i] = UInt8((octets >> (5 - i)) & 1) }
        return pad(w.bits, to: total)
    }

    static func llcUData(_ mle: [UInt8]) -> [UInt8] { [0, 0, 1, 0] + mle }

    public static func dSetup(group: Int, usageMarker: Int, callID: Int, caller: Int, carrier: Int, timeslot: Int, encrypted: Bool = false) -> [UInt8] {
        var w = TETRABitWriter()
        w.put(2, 3)                                           // CMCE
        w.put(0x07, 5)
        w.put(callID, 14); w.put(5, 4); w.put(0, 1); w.put(0, 1)
        w.put((0 << 5) | ((encrypted ? 1 : 0) << 4) | (1 << 2), 8)   // Sprache, Verschlüsselung, Gruppenruf
        w.put(1, 2); w.put(0, 1); w.put(1, 4)
        w.put(1, 1); w.put(0, 1); w.put(0, 1); w.put(1, 1); w.put(1, 2); w.put(caller, 24)
        return resource(address: group, usageMarker: usageMarker, allocation: (1 << (4 - timeslot), carrier), tmSDU: llcUData(w.bits), total: 268)
    }

    public static func dTxGranted(group: Int, callID: Int, speaker: Int) -> [UInt8] {
        var w = TETRABitWriter()
        w.put(2, 3); w.put(0x0B, 5)
        w.put(callID, 14); w.put(3, 2); w.put(0, 1); w.put(0, 1); w.put(0, 1)
        w.put(1, 1); w.put(0, 1); w.put(1, 1); w.put(1, 2); w.put(speaker, 24)
        return resource(address: group, usageMarker: nil, allocation: nil, tmSDU: llcUData(w.bits))
    }

    public static func dRelease(group: Int, callID: Int, cause: Int = 1) -> [UInt8] {
        var w = TETRABitWriter()
        w.put(2, 3); w.put(0x06, 5)
        w.put(callID, 14); w.put(cause, 5); w.put(0, 1)
        return resource(address: group, usageMarker: nil, allocation: nil, tmSDU: llcUData(w.bits))
    }

    /// D-SDS-DATA mit einfachem Text (Protokoll 0x02, 8-Bit-Zeichen)
    public static func dSDSText(to: Int, from: Int, text: String) -> [UInt8] {
        resource(address: to, usageMarker: nil, allocation: nil, tmSDU: dSDSSDU(from: from, text: text), total: 268)
    }

    /// LLC-, MLE- und CMCE-Teil einer Textnachricht (ohne MAC-Kopf)
    static func dSDSSDU(from: Int, text: String) -> [UInt8] {
        let chars = text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }   // ISO 8859-1
        var w = TETRABitWriter()
        w.put(2, 3); w.put(0x0F, 5)
        w.put(1, 2); w.put(from, 24)
        w.put(3, 2)
        w.put(8 + 8 + 8 * chars.count, 11)
        w.put(0x02, 8)
        w.put(0, 1); w.put(1, 7)                              // Codierung: 8 Bit
        for c in chars { w.put(Int(c), 8) }
        return llcUData(w.bits)
    }

    public static func nullPDU() -> [UInt8] {
        var w = TETRABitWriter()
        w.put(0, 2); w.put(1, 1); w.put(0, 1); w.put(0, 2); w.put(0, 1); w.put(2, 6); w.put(0, 3)
        return pad(w.bits, to: 124)
    }
}

/// Baut Bursts aus Steuerblöcken und Sprachblöcken
public final class TETRABurstBuilder {
    public let mcc: Int, mnc: Int, colourCode: Int
    private let scrambler: UInt32
    private var phaseBits: [UInt8] = []

    public init(mcc: Int, mnc: Int, colourCode: Int) {
        self.mcc = mcc
        self.mnc = mnc
        self.colourCode = colourCode
        scrambler = TETRA.scramblerInit(mcc: mcc, mnc: mnc, colourCode: colourCode)
    }

    /// Steuerblock: Typ-1-Bits → CRC, Endbits, Faltung, Punktierung, Verschachtelung, Verwürfelung
    func encodeControl(_ type1: [UInt8], p: TETRALowerMAC.BlockParameters, scramblerInit: UInt32) -> [UInt8] {
        precondition(type1.count == p.type1)
        var t2 = type1 + TETRA.crcBits(for: type1)
        t2 += [0, 0, 0, 0]
        let mother = TETRA.ConvolutionalCode.control.encode(t2)
        let t3 = TETRA.Puncturer.rate2of3.puncture(mother, count: p.k)
        let t4 = TETRA.blockInterleave(t3, a: p.a)
        let seq = TETRA.scramblerBits(initial: scramblerInit, count: p.k)
        return zip(t4, seq).map { $0 ^ $1 }
    }

    func encodeAccess(_ info: UInt16) -> [UInt8] {
        let word = TETRA.rm3014Encode(info)
        let bits = (0..<30).map { UInt8((word >> UInt32(29 - $0)) & 1) }
        let seq = TETRA.scramblerBits(initial: scrambler, count: 30)
        return zip(bits, seq).map { $0 ^ $1 }
    }

    public static func accessInfo(header: Int, field1: Int, field2: Int) -> UInt16 {
        UInt16((header & 3) << 12 | (field1 & 0x3F) << 6 | (field2 & 0x3F))
    }

    static func syncPDU(time: TETRATime, mcc: Int, mnc: Int, cc: Int) -> [UInt8] {
        var w = TETRABitWriter()
        w.put(0, 4); w.put(cc, 6); w.put(time.tn - 1, 2); w.put(time.fn, 5); w.put(time.mn, 6)
        w.put(0, 2); w.put(0, 3); w.put(0, 1); w.put(0, 1); w.put(0, 1)
        w.put(mcc, 10); w.put(mnc, 14); w.put(0, 2); w.put(0, 2); w.put(0, 1)
        return w.bits
    }

    /// Phasenanpassungsbits (zwei Bits, EN 300 392-2 9.4.4.3.6): die Summe der Phasenschritte im Bereich wird ein Vielfaches von 2π
    private static func adjustment(_ bits: [UInt8], n1: Int, n2: Int) -> [UInt8] {
        var sum = 0
        for n in (n1 - 1)..<n2 {
            let a = bits[2 * n], b = bits[2 * n + 1]
            switch (a, b) {
            case (0, 0): sum += 1
            case (0, 1): sum += 3
            case (1, 1): sum -= 3
            default: sum -= 1
            }
        }
        var adj = -(sum % 8)
        if adj > 3 { adj -= 8 } else if adj < -3 { adj += 8 }
        switch adj {
        case 1: return [0, 0]
        case 3: return [0, 1]
        case -3: return [1, 1]
        default: return [1, 0]
        }
    }

    /// Synchronisationsburst: `sb2` sind 124 Typ-1-Bits
    public func syncBurst(time: TETRATime, sb2: [UInt8], aach: UInt16) -> [UInt8] {
        let sb1 = encodeControl(TETRABurstBuilder.syncPDU(time: time, mcc: mcc, mnc: mnc, cc: colourCode), p: TETRALowerMAC.sb1, scramblerInit: TETRA.defaultScramblerInit)
        let b2 = encodeControl(sb2, p: TETRALowerMAC.halfSlot, scramblerInit: scrambler)
        var burst = Array(TETRA.normalTrainingQ[10..<22]) + [0, 0] + TETRA.frequencyCorrection + sb1 + TETRA.syncTraining + encodeAccess(aach) + b2 + [0, 0] + Array(TETRA.normalTrainingQ[0..<10])
        let hc = TETRABurstBuilder.adjustment(burst, n1: 8, n2: 108)
        let hd = TETRABurstBuilder.adjustment(burst, n1: 109, n2: 249)
        burst[12] = hc[0]; burst[13] = hc[1]
        burst[498] = hd[0]; burst[499] = hd[1]
        return burst
    }

    private func normal(_ blk1: [UInt8], _ bbk: [UInt8], _ blk2: [UInt8], train: [UInt8]) -> [UInt8] {
        var burst = Array(TETRA.normalTrainingQ[10..<22]) + [0, 0] + blk1 + Array(bbk[0..<14]) + train + Array(bbk[14..<30]) + blk2 + [0, 0] + Array(TETRA.normalTrainingQ[0..<10])
        let ha = TETRABurstBuilder.adjustment(burst, n1: 8, n2: 122)
        let hb = TETRABurstBuilder.adjustment(burst, n1: 123, n2: 249)
        burst[12] = ha[0]; burst[13] = ha[1]
        burst[498] = hb[0]; burst[499] = hb[1]
        return burst
    }

    /// Normaler Burst mit zwei Halbschlitz-Steuerblöcken (Trainingsfolge 2); `nil` = Leerblock
    public func halfSlotBurst(block1: [UInt8], block2: [UInt8], aach: UInt16) -> [UInt8] {
        normal(encodeControl(block1, p: TETRALowerMAC.halfSlot, scramblerInit: scrambler), encodeAccess(aach),
               encodeControl(block2, p: TETRALowerMAC.halfSlot, scramblerInit: scrambler), train: TETRA.normalTrainingP)
    }

    /// Normaler Burst mit einem Vollschlitz-Steuerblock (268 Bits, Trainingsfolge 1)
    public func fullSlotBurst(block: [UInt8], aach: UInt16) -> [UInt8] {
        let bits = encodeControl(block, p: TETRALowerMAC.fullSlot, scramblerInit: scrambler)
        return normal(Array(bits[0..<216]), encodeAccess(aach), Array(bits[216..<432]), train: TETRA.normalTrainingN)
    }

    /// Sprachburst: zwei Rahmen zu 137 Bits (Trainingsfolge 1, Kanal TCH/S)
    public func speechBurst(frameA: [UInt8], frameB: [UInt8], aach: UInt16) -> [UInt8] {
        let coded = TETRASpeech.encodeBlock(frameA, frameB)
        let seq = TETRA.scramblerBits(initial: scrambler, count: 432)
        let t5 = zip(coded, seq).map { $0 ^ $1 }
        return normal(Array(t5[0..<216]), encodeAccess(aach), Array(t5[216..<432]), train: TETRA.normalTrainingN)
    }

    /// Sprachburst mit Blockraub in der ersten Hälfte: STCH (124 Typ-1-Bits) und ein Sprachrahmen; Trainingsfolge 2
    public func stolenSpeechBurst(stch: [UInt8], frame: [UInt8], aach: UInt16) -> [UInt8] {
        let first = encodeControl(stch, p: TETRALowerMAC.halfSlot, scramblerInit: scrambler)
        let coded = TETRASpeech.encodeHalf(frame)
        let seq = TETRA.scramblerBits(initial: scrambler, count: 216)
        let second = zip(coded, seq).map { $0 ^ $1 }
        return normal(first, encodeAccess(aach), second, train: TETRA.normalTrainingP)
    }
}

extension TETRASpeech {
    /// Ein Sprachrahmen → 216 Kanalbits der zweiten Hälfte bei Blockraub (verschachtelt, noch nicht verwürfelt)
    public static func encodeHalf(_ frame: [UInt8]) -> [UInt8] {
        let c0 = (0..<51).map { frame[class0[$0] - 1] }
        var c1 = (0..<56).map { frame[class1[$0] - 1] }
        var c2 = (0..<30).map { frame[class2[$0] - 1] }
        for i in 0..<4 { var p: UInt8 = 0; for t in crcTapsHalf[i] { p ^= c2[t - 1] }; c2.append(p) }
        c2 += [0, 0, 0, 0]
        c1 += []
        let mother = TETRA.ConvolutionalCode.speech.encode(c1 + c2)
        func puncture(_ m: [UInt8], table: [[Bool]], steps: Int) -> [UInt8] {
            var out = [UInt8]()
            for k in 0..<steps { for j in 0..<3 where table[j][k % 8] { out.append(m[k * 3 + j]) } }
            return out
        }
        let p1 = puncture(Array(mother[0..<168]), table: puncture1, steps: 56)
        let p2 = puncture(Array(mother[168...]), table: puncture2Half, steps: 38)
        return TETRA.blockInterleave(c0.map { $0 } + p1 + p2, a: 101)
    }
}

// MARK: - Modulation

public enum TETRAModulator {
    /// Dibits → Phasenschritt in Einheiten von π/4 (00: +1, 01: +3, 11: −3, 10: −1)
    static func phaseStep(_ a: UInt8, _ b: UInt8) -> Int {
        switch (a, b) {
        case (0, 0): return 1
        case (0, 1): return 3
        case (1, 1): return -3
        default: return -1
        }
    }

    /// RRC-Impuls als Tabelle: `res` Werte je Symbol über ±`span` Symbole
    static func rrcTable(beta: Double, res: Int, span: Int) -> [Double] {
        let n = 2 * span * res + 1
        var h = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let t = Double(k - span * res) / Double(res)
            if abs(t) < 1e-9 { h[k] = 1 - beta + 4 * beta / Double.pi }
            else if abs(abs(4 * beta * t) - 1) < 1e-6 { h[k] = beta / sqrt(2) * ((1 + 2 / Double.pi) * sin(Double.pi / (4 * beta)) + (1 - 2 / Double.pi) * cos(Double.pi / (4 * beta))) }
            else { h[k] = (sin(Double.pi * t * (1 - beta)) + 4 * beta * t * cos(Double.pi * t * (1 + beta))) / (Double.pi * t * (1 - pow(4 * beta * t, 2))) }
        }
        return h
    }

    /// Bits → I/Q bei der Abtastrate `sampleRate` (Mitte der Symbole bei Abtastwert `delay`); die Verschiebung `offsetHz` wird aufgemischt
    public static func modulate(bits: [UInt8], sampleRate: Double, offsetHz: Double = 0, startPhase: Int = 0, clockPPM: Double = 0) -> (i: [Float], q: [Float]) {
        let symbolCount = bits.count / 2
        // Symbole
        var phase = startPhase
        var symI = [Double](repeating: 0, count: symbolCount), symQ = symI
        for k in 0..<symbolCount {
            phase = (phase + phaseStep(bits[2 * k], bits[2 * k + 1])) & 7
            symI[k] = cos(Double(phase) * Double.pi / 4)
            symQ[k] = sin(Double(phase) * Double.pi / 4)
        }
        let span = 8, res = 64
        let table = rrcTable(beta: 0.35, res: res, span: span)
        let symbolRate = TETRA.symbolRate * (1 + clockPPM * 1e-6)
        let total = Int((Double(symbolCount + 2 * span) / symbolRate * sampleRate).rounded(.up))
        var outI = [Float](repeating: 0, count: total), outQ = outI
        for n in 0..<total {
            let t = Double(n) / sampleRate * symbolRate - Double(span)       // Zeit in Symbolen; Symbol k liegt bei t = k
            let k0 = Int(t.rounded(.down))
            var si = 0.0, sq = 0.0
            let lo = max(0, k0 - span + 1), hi = min(symbolCount - 1, k0 + span)
            if lo > hi { continue }
            for k in lo...hi {
                let x = (t - Double(k)) * Double(res) + Double(span * res)
                let ix = Int(x)
                if ix < 0 || ix + 1 >= table.count { continue }
                let f = x - Double(ix)
                let h = table[ix] * (1 - f) + table[ix + 1] * f
                si += symI[k] * h
                sq += symQ[k] * h
            }
            outI[n] = Float(si)
            outQ[n] = Float(sq)
        }
        if offsetHz != 0 {
            let w = 2 * Double.pi * offsetHz / sampleRate
            var re = 1.0, im = 0.0
            let sr = cos(w), sim = sin(w)
            for n in 0..<total {
                let a = Double(outI[n]), b = Double(outQ[n])
                outI[n] = Float(a * re - b * im)
                outQ[n] = Float(a * im + b * re)
                let nr = re * sr - im * sim
                im = re * sim + im * sr
                re = nr
                if n & 0xFFF == 0 { let m = sqrt(re * re + im * im); re /= m; im /= m }
            }
        }
        return (outI, outQ)
    }
}

// MARK: - Netz zum Ausprobieren

/// Eine Basisstation mit einem Träger: Dauersendung auf allen vier Zeitschlitzen, Sprachverkehr auf einem Schlitz
public final class TETRATestNetwork {
    public struct Config {
        public var mcc = 262, mnc = 99, colourCode = 7
        public var band = 4, mainCarrier = 1068, offsetIndex = 0
        public var group = 100601, speakers = [100701, 100702], callID = 113
        public var usageMarker = 51, trafficSlot = 2
        public var locationArea = 1
        public var encrypted = false
        /// Träger, auf den die Kanalzuweisung des Rufs verweist (nil = Hauptträger)
        public var allocationCarrier: Int?
        /// Dieser Träger sendet den Rufaufbau (Steuerkanal) und trägt den Verkehr
        public var controlChannel = true
        public var hostsTraffic = true
        public var text: String? = "Digidec Test"
        public init() {}
    }

    public let config: Config
    public let builder: TETRABurstBuilder
    /// Sprachrahmen (137 Bits), ein Ruf spielt sie der Reihe nach ab
    public var speech: [[UInt8]]
    private var speechPosition = 0
    public private(set) var time = TETRATime(tn: 1, fn: 1, mn: 1)

    public init(config: Config, speech: [[UInt8]]) {
        self.config = config
        self.speech = speech.isEmpty ? [[UInt8]](repeating: [UInt8](repeating: 0, count: 137), count: 2) : speech
        builder = TETRABurstBuilder(mcc: config.mcc, mnc: config.mnc, colourCode: config.colourCode)
    }

    /// Ablauf: Rahmen 1 setzt den Ruf auf, danach Sprache auf `trafficSlot`, im letzten Drittel Sprecherwechsel, am Ende Freigabe
    /// - Parameter frames: Zahl der TDMA-Rahmen insgesamt; `callStart`/`callEnd` in Rahmen
    public func bursts(frames: Int, callStart: Int = 3, callEnd: Int? = nil, stealEvery: Int = 0) -> [[UInt8]] {
        var out: [[UInt8]] = []
        let end = callEnd ?? frames - 3
        for f in 0..<frames {
            for tn in 1...4 {
                time.tn = tn
                let fn = time.fn
                let inCall = f >= callStart && f < end
                let traffic = inCall && config.hostsTraffic && tn == config.trafficSlot && fn != 18
                var aachField = TETRABurstBuilder.accessInfo(header: 0, field1: 0, field2: 0)
                if fn == 18 {
                    aachField = TETRABurstBuilder.accessInfo(header: 0, field1: 0, field2: 0)
                } else if traffic {
                    aachField = TETRABurstBuilder.accessInfo(header: 3, field1: config.usageMarker, field2: config.usageMarker)
                } else if tn == config.trafficSlot && inCall && config.hostsTraffic {
                    aachField = TETRABurstBuilder.accessInfo(header: 3, field1: 0, field2: 0)
                }
                if fn == 18 {
                    // Synchronisationsburst; Systeminformation in Schlitz 1, sonst Leerblock
                    let sb2 = tn == 1 ? TETRAPDUBuilder.sysinfo(mainCarrier: config.mainCarrier, band: config.band, offsetIndex: config.offsetIndex, duplex: 0, locationArea: config.locationArea, serviceDetails: 0b111101110101 & (config.encrypted ? ~0 : ~0b10) | (config.encrypted ? 0b10 : 0))
                                         : TETRAPDUBuilder.nullPDU()
                    out.append(builder.syncBurst(time: time, sb2: sb2, aach: aachField))
                } else if traffic {
                    if stealEvery > 0 && f % stealEvery == 0 {
                        // Signalisierung statt der ersten Sprachhälfte: Sprecherkennung wiederholen (späte Einsteiger)
                        let stch = TETRAPDUBuilder.dTxGranted(group: config.group, callID: config.callID, speaker: f >= (callStart + end) / 2 && config.speakers.count > 1 ? config.speakers[1] : config.speakers[0])
                        out.append(builder.stolenSpeechBurst(stch: stch, frame: nextFrame(), aach: aachField))
                    } else {
                        out.append(builder.speechBurst(frameA: nextFrame(), frameB: nextFrame(), aach: aachField))
                    }
                } else if tn == 1 && config.controlChannel {
                    // Steuerkanal: Rufaufbau und Sprecher in den ersten Rahmen des Rufs, Wiederholung für späte Einsteiger
                    var blocks: [[UInt8]] = [TETRAPDUBuilder.nullPDU(), TETRAPDUBuilder.nullPDU()]
                    if inCall && (f == callStart || (f - callStart) % 24 == 0) {
                        // Rufaufbau mit Kanalzuweisung braucht den Vollschlitz (SCH/F)
                        out.append(builder.fullSlotBurst(block: TETRAPDUBuilder.dSetup(group: config.group, usageMarker: config.usageMarker, callID: config.callID, caller: config.speakers[0], carrier: config.allocationCarrier ?? config.mainCarrier, timeslot: config.trafficSlot, encrypted: config.encrypted), aach: aachField))
                        time.advance()
                        continue
                    } else if inCall && f == callStart + 1 {
                        blocks[0] = TETRAPDUBuilder.dTxGranted(group: config.group, callID: config.callID, speaker: config.speakers[0])
                    } else if inCall && f == (callStart + end) / 2 && config.speakers.count > 1 {
                        blocks[0] = TETRAPDUBuilder.dTxGranted(group: config.group, callID: config.callID, speaker: config.speakers[1])
                    } else if f == end {
                        blocks[0] = TETRAPDUBuilder.dRelease(group: config.group, callID: config.callID)
                    } else if f == callStart - 1, let text = config.text {
                        // Kurznachricht: Vollschlitz
                        out.append(builder.fullSlotBurst(block: TETRAPDUBuilder.dSDSText(to: config.group, from: config.speakers[0], text: text), aach: aachField))
                        time.advance()
                        continue
                    }
                    out.append(builder.halfSlotBurst(block1: blocks[0], block2: blocks[1], aach: aachField))
                } else {
                    out.append(builder.halfSlotBurst(block1: TETRAPDUBuilder.nullPDU(), block2: TETRAPDUBuilder.nullPDU(), aach: aachField))
                }
                time.advance()
            }
        }
        return out
    }

    private func nextFrame() -> [UInt8] {
        defer { speechPosition = (speechPosition + 1) % speech.count }
        return speech[speechPosition]
    }
}
