// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Graw DFM-06, DFM-09, DFM-17 und PS-15: 2500 Symbole/s (Manchester, also 1250 Bit/s), GFSK.
// Rahmenaufbau, Hamming-Code und Auswertung der Pakete nach dfm09mod von zilog80 (radiosonde_auto_rx, GPL-3.0), siehe Vendor/Sonde/UPSTREAM_SONDE.md.
//
// Ein Rahmen hat 280 Bit: Kopf 0x45CF (16), Kanalblock (56), zwei Datenblöcke (je 104). Jedes Byte der Blöcke ist ein Hamming(8,4)-Wort,
// die Wörter sind über 7 bzw. 13 Spalten verschachtelt. Ein Kanalblock trägt 4 Bit Kennung und 24 Bit Wert (Seriennummer, Messwerte),
// ein Datenblock 48 Bit Nutzdaten und eine Paketnummer 0 … 8 (GPS-Zeit, Breite, Länge, Höhe, Geschwindigkeit, Datum).
// Es gibt keine Rahmenprüfsumme; Fehler fangen nur der Hamming-Code (ein Bitfehler je Wort) und Plausibilitätsprüfungen ab.

enum DFMFrame {
    static let headerBits = 16
    static let bodyBits = 264          // 56 + 104 + 104
    static let confOffset = 0
    static let dat1Offset = 56
    static let dat2Offset = 160
    /// Kopf 0x45CF als Rohsymbole (Manchester: 0 → „10“, 1 → „01“), +1 / −1
    static let headerSymbols: [Float] = Array("10011010100110010101101001010101").map { $0 == "1" ? 1 : -1 }
    static let symbolRate = 2500.0
    /// Dauer eines Rahmens in s (280 Bit = 560 Symbole)
    static let duration = 560.0 / symbolRate

    /// Manchester-Symbole → Bits (zweites Symbol größer als das erste: 1)
    static func bits(fromSymbols s: [Float]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: s.count / 2)
        for i in 0..<out.count { out[i] = s[2 * i + 1] >= s[2 * i] ? 1 : 0 }
        return out
    }
}

// MARK: - Hamming(8,4)

enum DFMHamming {
    /// Spalten von H: Syndrom eines Einzelbitfehlers an Stelle 0 … 7
    private static let syndromes: [UInt8] = [0x7, 0xB, 0xD, 0xE, 0x8, 0x4, 0x2, 0x1]
    private static let h: [[UInt8]] = [[0, 1, 1, 1, 1, 0, 0, 0],
                                       [1, 0, 1, 1, 0, 1, 0, 0],
                                       [1, 1, 0, 1, 0, 0, 1, 0],
                                       [1, 1, 1, 0, 0, 0, 0, 1]]
    private static let g: [[UInt8]] = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1],
                                       [0, 1, 1, 1], [1, 0, 1, 1], [1, 1, 0, 1], [1, 1, 1, 0]]

    /// Codewort (8 Bit) zu einem Halbbyte (4 Bit, höchstwertiges Bit zuerst)
    static func encode(_ nibble: UInt8) -> [UInt8] {
        let msg: [UInt8] = (0..<4).map { (nibble >> UInt8(3 - $0)) & 1 }
        return (0..<8).map { i in (0..<4).reduce(0) { $0 ^ (g[i][$1] & msg[$1]) } }
    }

    /// Wort prüfen und einen Bitfehler beheben. Rückgabe: 0 fehlerfrei, 1 … 8 behobener Fehler an Stelle (Rückgabe − 1), −1 nicht korrigierbar.
    static func check(_ code: inout [UInt8]) -> Int {
        var syn: UInt8 = 0
        for i in 0..<4 {
            var s: UInt8 = 0
            for j in 0..<8 { s ^= h[i][j] & code[j] }
            syn = (syn << 1) | s
        }
        if syn == 0 { return 0 }
        guard let j = syndromes.firstIndex(of: syn) else { return -1 }
        code[j] ^= 1
        return j + 1
    }

    /// Verschachtelte Bits (Zeilen zu je `columns` Bit, 8 Zeilen) → Wörter zu je 8 Bit
    static func deinterleave(_ bits: ArraySlice<UInt8>, columns l: Int) -> [UInt8] {
        let base = bits.startIndex
        var out = [UInt8](repeating: 0, count: 8 * l)
        for j in 0..<8 { for i in 0..<l { out[8 * i + j] = bits[base + l * j + i] } }
        return out
    }

    /// Umkehrung von `deinterleave` (für Testsignale)
    static func interleave(_ words: [UInt8], columns l: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 8 * l)
        for j in 0..<8 { for i in 0..<l { out[l * j + i] = words[8 * i + j] } }
        return out
    }

    /// Block mit `l` Wörtern decodieren: Nutzbits (4 je Wort) und Fehlerstand wie im Referenzdecoder
    /// (0: fehlerfrei, Maske der korrigierten Wörter, −1: mindestens ein Wort nicht korrigierbar)
    static func decode(_ bits: ArraySlice<UInt8>, columns l: Int) -> (data: [UInt8], errors: Int) {
        let words = deinterleave(bits, columns: l)
        var data = [UInt8](repeating: 0, count: 4 * l)
        var ret = 0
        for i in 0..<l {
            var w = Array(words[(8 * i)..<(8 * i + 8)])
            let e = check(&w)
            if e > 0 { ret |= 1 << i }
            if e < 0 { ret = -1 }
            for j in 0..<4 { data[4 * i + j] = w[j] }
        }
        return (data, ret)
    }
}

// MARK: - Auswertung der Blöcke

/// Sammelt die Blöcke der Rahmen einer Sonde und bildet daraus die Telemetrie
final class DFMDecoder {
    struct SerialChannel {
        var maxCh = 0
        var nulCh = 0
        var snCh = 0
        var chXbit = 0
        var snX: UInt32 = 0
        var chX: [UInt32] = [0, 0]
    }

    private var snc = SerialChannel()
    private var frnr = 0
    private var sondeTyp = 0
    private var sn6: UInt32 = 0
    private var sn: UInt32 = 0
    private var snOut = ""
    private var ptuOut = 0
    private var sensorType: Character = "T"
    private var rf = 220e3
    private var cfgchk = false
    private var cfgchk24 = [Bool](repeating: false, count: 9)
    private var meas24 = [Double](repeating: 0, count: 9)
    private var status = [Double](repeating: 0, count: 3)
    private var dfmType = ""
    private var posmode = 2
    private var jahr = 0, monat = 0, tag = 0, std = 0, min = 0
    private var sek = 0.0
    private var lat = 0.0, lon = 0.0, alt = 0.0, dir = 0.0, horiV = 0.0, vertV = 0.0
    private var dMSL = 0.0
    private var nSV = 0, nPRN = 0
    private var packetEC = [Int](repeating: -1, count: 9)
    private var packetTime = [Double](repeating: 0, count: 9)
    private var previousDiff = -1
    /// Zeit in Rahmenlängen (für die Frische der Pakete)
    private var frameCount = 0.0
    /// Das Signal des laufenden Rahmens lag mit umgekehrter Polarität an
    var inverted = false

    func reset() {
        snc = SerialChannel(); frnr = 0; sondeTyp = 0; sn6 = 0; sn = 0; snOut = ""; ptuOut = 0
        cfgchk = false; cfgchk24 = [Bool](repeating: false, count: 9); meas24 = [Double](repeating: 0, count: 9)
        packetEC = [Int](repeating: -1, count: 9); previousDiff = -1; posmode = 2
    }

    static func value(_ bits: [UInt8], _ start: Int, _ length: Int) -> UInt32 {
        var v: UInt32 = 0
        for j in 0..<length { v = (v << 1) | UInt32(bits[start + j] & 1) }
        return v
    }
    private func val(_ bits: [UInt8], _ start: Int, _ length: Int) -> Int { Int(Self.value(bits, start, length)) }

    /// Zahl der behobenen Bits aus der Fehlermaske
    static func bitErrors(_ ec: Int) -> Int { (0..<15).reduce(0) { $0 + ((ec >> $1) & 1) } }

    private func resetConfig() {
        cfgchk24 = [Bool](repeating: false, count: 9)
        cfgchk = false
        ptuOut = 0
        snOut = ""
    }

    // MARK: Kanalblock

    /// 7 Halbbyte: Kennung (1) und 24 Bit Wert
    func processConfig(_ conf: [UInt8], errors ec: Int) {
        let confId = val(conf, 0, 4)
        if confId > 4 && val(conf, 8, 20) == 0 { snc.nulCh = val(conf, 0, 8) }
        let dfm6 = (snc.nulCh & 0xF0) == 0x50 && (snc.nulCh & 0x0F) != 0
        if dfm6 { ptuOut = 6 }
        if dfm6 && (sondeTyp & 0xF) > 6 {
            sondeTyp = 0
            snc.maxCh = confId
            resetConfig()
        }
        if confId > 5 && confId > snc.maxCh && ec == 0 {
            if val(conf, 4, 4) == 0xC { snc.maxCh = confId }
        }
        if confId > 5 && (confId == (snc.nulCh >> 4) + 1 || confId == snc.maxCh) {
            let sn2Ch = val(conf, 0, 8)
            let snCh = (sn2Ch >> 4) & 0xF
            if (snc.nulCh & 0x58) == 0x58 {
                let s6 = UInt32(val(conf, 4, 24))
                if s6 == sn6 && s6 != 0 {
                    sondeTyp = 0x100 | snCh
                    ptuOut = 6
                    snOut = String(format: "%6X", sn6).trimmingCharacters(in: .whitespaces)
                } else {
                    sondeTyp = 0
                    resetConfig()
                }
                sn6 = s6
            } else if (sn2Ch & 0xF) == 0xC || (sn2Ch & 0xF) == 0x0 {
                let v = val(conf, 8, 20)
                let hl = v & 0xF
                if hl < 2 {
                    if snc.snCh != snCh {
                        snc.chXbit = 0
                        snc.chX = [0, 0]
                        resetConfig()
                    }
                    snc.snCh = snCh
                    snc.chX[hl] = UInt32((v >> 4) & 0xFFFF)
                    snc.chXbit |= 1 << hl
                    if snc.chXbit == 3 {
                        let number = (snc.chX[0] << 16) | snc.chX[1]
                        if number == snc.snX || snc.snX == 0 {
                            sondeTyp = 0x100 | snCh
                            sn = number
                            ptuOut = 0
                            if snCh == 0xA || snCh == 0xB || snCh == 0xC || snCh == 0xD { ptuOut = snCh }
                            if sn6 == 0 || (sondeTyp & 0xF) >= 0xA { snOut = String(sn) }
                        } else {
                            sondeTyp = 0
                            resetConfig()
                        }
                        snc.snX = number
                        snc.chXbit = 0
                    }
                }
            }
        }

        // DFM-17 mit Kennung 0xA: Seriennummern ab 23 Mio. und umgekehrte Polarität (wie im Referenzdecoder)
        let dfm17Ten = sn >= 23_000_000 && inverted
        if confId <= 8 && ec == 0 {
            cfgchk24[confId] = true
            let v = val(conf, 4, 24)
            meas24[confId] = Self.fl24(v)
            cfgchk = false
            if ptuOut >= 0x5 { cfgchk = (0...5).allSatisfy { cfgchk24[$0] } }
            if ptuOut >= 0x7 { cfgchk = cfgchk && cfgchk24[6] && cfgchk24[7] }
            if ptuOut >= 0x8 { cfgchk = cfgchk && cfgchk24[8] }
        }

        sensorType = "T"
        rf = 220e3
        if cfgchk {
            if ptuOut >= 0xD || (ptuOut >= 0xC && meas24[6] < 220e3) { sensorType = "P" }
            if ((ptuOut == 0xB || ptuOut == 0xC) && sensorType == "T") || ptuOut >= 0xD { rf = 332e3 }
            if ptuOut == 0xA && sensorType == "T" && dfm17Ten { rf = 332e3 }
            if ptuOut == 6 && (sondeTyp & 0xF) == 8 { sensorType = "P" }
            if ptuOut >= 0xA {
                let ofs = sensorType == "P" ? 2 : 0
                if confId == 0x5 + ofs { status[0] = Double(val(conf, 8, 16)) / 1000 }
                if confId == 0x6 + ofs { status[1] = Double(val(conf, 8, 16)) / 100 }
                if confId == 0x7 + ofs && rf > 300e3 { status[2] = Double(val(conf, 8, 16)) }
            } else {
                status = [0, 0, 0]
            }
        }

        switch sondeTyp & 0xF {
        case 0x6: dfmType = "DFM-06"
        case 0x7, 0x8: dfmType = sn6 != 0 ? "DFM-06P" : "PS-15"
        case 0xA: dfmType = "DFM-09"
        case 0xB: dfmType = "DFM-17"
        case 0xC: dfmType = sensorType == "P" ? "DFM-09P" : "DFM-17"
        case 0xD: dfmType = "DFM-17P"
        default: dfmType = sondeTyp == 0 ? "" : "DFM"
        }
    }

    private static func fl24(_ d: Int) -> Double {
        let p = (d >> 20) & 0xF
        let v = d & 0xFFFFF
        return Double(v) / Double(1 << p)
    }

    // MARK: Datenblock

    /// 13 Halbbyte: 48 Bit Nutzdaten und Paketnummer. Rückgabe: die Paketnummer, 8 = Ende einer Sekunde.
    @discardableResult
    func processData(_ d: [UInt8], errors ec: Int) -> Int {
        let id = val(d, 48, 4)
        guard id <= 8 else { return id }
        packetTime[id] = frameCount
        packetEC[id] = ec > 0 ? (Self.bitErrors(ec) > 4 ? -2 : Self.bitErrors(ec)) : ec

        if id == 0 {
            let mode = val(d, 16, 8)
            posmode = mode > 1 && mode < 5 ? mode : -1
            frnr = val(d, 24, 8)
        }
        func signed16(_ start: Int) -> Double { Double(Int16(truncatingIfNeeded: val(d, start, 16))) }
        func unsigned16(_ start: Int) -> Double { Double(val(d, start, 16) & 0xFFFF) }
        func signed32(_ start: Int) -> Double { Double(Int32(truncatingIfNeeded: Int(Self.value(d, start, 32)))) }

        if posmode <= 2 {
            switch id {
            case 1:
                sek = Double(val(d, 32, 16)) / 1000
                nPRN = (0..<32).reduce(0) { $0 + Int((Self.value(d, 0, 32) >> UInt32($1)) & 1) }
            case 2:
                lat = signed32(0) / 1e7
                horiV = signed16(32) / 100
            case 3:
                lon = signed32(0) / 1e7
                dir = unsigned16(32) / 100
            case 4:
                alt = signed32(0) / 100
                vertV = signed16(32) / 100
            case 5:
                dMSL = Double(Int16(truncatingIfNeeded: val(d, 0, 16))) / 100
            default: break
            }
        } else {   // posmode 3 und 4: andere Anordnung der Pakete
            switch id {
            case 0:
                sek = Double(val(d, 0, 16)) / 1000
                horiV = signed16(32) / 100
            case 1:
                lat = signed32(0) / 1e7
                dir = unsigned16(32) / 100
            case 2:
                lon = signed32(0) / 1e7
                vertV = signed16(32) / 100
            case 3:
                alt = signed32(0) / 100
            default: break
            }
        }
        if id == 8 {
            jahr = val(d, 0, 12)
            monat = val(d, 12, 4)
            tag = val(d, 16, 5)
            std = val(d, 21, 5)
            min = val(d, 26, 6)
            nSV = val(d, 32, 8)
        }
        return id
    }

    // MARK: Telemetrie

    /// Am Ende einer Sekunde (Paket 8): Telemetrie, wenn die Pakete 0 bis 4 und 8 frisch und ohne unkorrigierbare Fehler da sind
    func telemetry() -> SondeTelemetry? {
        defer { for i in 0..<9 { packetEC[i] = -1 } }
        for i in [0, 1, 2, 3, 4, 8] {
            guard packetEC[i] >= 0, packetTime[8] - packetTime[i] < 6.0 else { return nil }
        }
        guard !snOut.isEmpty else { return nil }
        guard (1..<13).contains(monat), (1...31).contains(tag), std < 24, min < 60, sek < 60, (2015...2099).contains(jahr),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        let secGPS = Self.secondsSince1980(year: jahr, month: monat, day: tag, hour: std, minute: min, second: Int(sek + 0.5))
        // Zähler im Rahmen und Sekunde müssen gleichmäßig laufen, sonst war Datum oder Zeit gestört
        let diff = ((secGPS & 0xFF) - frnr + 256) & 0xFF
        let consistent = diff == previousDiff
        previousDiff = diff
        guard consistent else { return nil }

        var t = SondeTelemetry(serial: "DFM-" + snOut, frame: secGPS)
        t.model = dfmType.isEmpty ? "DFM" : dfmType
        // 6.1.1980 00:00:00 UTC = 315 964 800 s nach dem Unix-Nullpunkt; DFM sendet UTC (Schaltsekunden schon abgezogen)
        t.time = Date(timeIntervalSince1970: TimeInterval(Self.secondsSince1980(year: jahr, month: monat, day: tag, hour: std, minute: min, second: Int(sek))) + 315_964_800 + (sek - Double(Int(sek))))
        t.latitude = lat
        t.longitude = lon
        t.altitude = alt
        t.speed = horiV
        t.heading = dir
        t.climb = vertV
        t.satellites = nSV > 0 ? nSV : (nPRN > 0 ? nPRN : nil)
        if ptuOut >= 0xA, status[0] > 0 { t.battery = status[0] }
        if cfgchk, ptuOut != 0 {
            let temp = temperature()
            if temp > -270 { t.temperature = temp }
        }
        return t
    }

    func countFrame() { frameCount += 1 }

    /// Hauptfühler: NTC mit Steinhart-Hart-Näherung aus den Messwerten 0, 3 und 4 (bei „P“-Sensoren 1, 5 und 6)
    private func temperature() -> Double {
        let p0 = 1.09698417e-03, p1 = 2.39564629e-04, p2 = 2.48821437e-06, p3 = 5.84354921e-08
        var f = meas24[0], f1 = meas24[3], f2 = meas24[4]
        if sensorType == "P" { f = meas24[1]; f1 = meas24[5]; f2 = meas24[6] }
        var t = 0.0
        let g = f2 / rf
        var r = (f - f1) / g
        if f * f1 * f2 == 0 { r = 0 }
        if r > 0 {
            let l = log(r)
            t = 1 / (p0 + p1 * l + p2 * l * l + p3 * l * l * l)
        }
        return t - 273.15
    }

    /// Sekunden seit dem 6.1.1980 (ohne Schaltsekunden; DFM sendet UTC)
    static func secondsSince1980(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Int {
        var y = year, m = month
        if m < 3 { y -= 1; m += 12 }
        let days = Int(365.25 * Double(y)) + Int(30.6001 * (Double(m) + 1)) + day - 723_263
        return days * 86_400 + hour * 3600 + minute * 60 + second
    }
}

// MARK: - Empfänger

/// Sondenempfänger für Graw DFM (2500 Bd) aus FM-Audio
public final class DFMReceiver: SondeReceiving {
    public var onTelemetry: ((SondeTelemetry) -> Void)?
    public private(set) var stats = SondeStats()
    public var level: Double { Double(demod.level) }
    public let sampleRate: Double

    private let demod: SymbolBurstDemodulator
    private let decoder = DFMDecoder()

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        demod = SymbolBurstDemodulator(sampleRate: sampleRate, symbolRate: DFMFrame.symbolRate, header: DFMFrame.headerSymbols,
                                       bodySymbols: DFMFrame.bodyBits * 2, threshold: 0.7, tolerance: 0.01)
        demod.onBurst = { [unowned self] burst in self.accept(burst) }
    }

    public func reset() {
        demod.reset()
        decoder.reset()
        stats = SondeStats()
    }

    public func resetStats() { stats = SondeStats() }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        demod.process(samples)
    }

    private func accept(_ burst: SymbolBurstDemodulator.Burst) {
        let bits = DFMFrame.bits(fromSymbols: burst.symbols)
        guard bits.count >= DFMFrame.bodyBits else { return }
        let conf = DFMHamming.decode(bits[DFMFrame.confOffset..<(DFMFrame.confOffset + 56)], columns: 7)
        let d1 = DFMHamming.decode(bits[DFMFrame.dat1Offset..<(DFMFrame.dat1Offset + 104)], columns: 13)
        let d2 = DFMHamming.decode(bits[DFMFrame.dat2Offset..<(DFMFrame.dat2Offset + 104)], columns: 13)
        let groups = [conf, d1, d2]
        let good = groups.filter { $0.errors >= 0 }.count
        // Ohne ein einziges lesbares Wort war es nur ein Zufallstreffer des Kopfes (Rauschen)
        guard good > 0 else { return }
        stats.headers += 1
        if good == 3 { stats.frames += 1 } else { stats.partial += 1 }
        let fixed = groups.reduce(0) { $0 + ($1.errors > 0 ? DFMDecoder.bitErrors($1.errors) : 0) }
        stats.corrected += fixed
        stats.lastFrameTime = burst.time

        decoder.inverted = burst.inverted
        decoder.countFrame()
        if conf.errors >= 0 { decoder.processConfig(conf.data, errors: conf.errors) }
        for d in [d1, d2] where d.errors >= 0 {
            if decoder.processData(d.data, errors: d.errors) == 8, var t = decoder.telemetry() {
                t.correctedBytes = good == 3 ? fixed : -1
                onTelemetry?(t)
            }
        }
    }
}
