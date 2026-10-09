// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// xHE-AAC (USAC) in DRM30 nach ETSI ES 201 980 V4.1.2, Abschnitt 5.3:
//  - Überrahmen: 2 Byte Kopf (Grenzenzahl, Pufferstand, CRC-8), Nutzlast mit lückenlos aneinandergereihten Audiorahmen, hinten das Verzeichnis der Rahmengrenzen
//  - Audiorahmen: USAC-Zugriffseinheit plus CRC-16
//  - Konfiguration: die gekürzte „xHE-AAC Static Config“ aus dem SDC (Typ 9) wird in die übliche UsacConfig (AudioSpecificConfig, Objekttyp 42) umgeschrieben,
//    die der Decoder erwartet.

// MARK: - Bits

struct DRMBitReader {
    let bits: [UInt8]
    var pos = 0
    var failed = false
    init(bytes: [UInt8]) { bits = bytes.flatMap { b in (0..<8).map { UInt8((b >> UInt8(7 - $0)) & 1) } } }
    var remaining: Int { bits.count - pos }
    mutating func read(_ n: Int) -> Int {
        guard n >= 0, pos + n <= bits.count else { failed = true; pos = bits.count; return 0 }
        var v = 0
        for _ in 0..<n { v = (v << 1) | Int(bits[pos]); pos += 1 }
        return v
    }
    /// escapedValue(n1, n2, n3) nach ISO/IEC 23003-3
    mutating func escaped(_ n1: Int, _ n2: Int, _ n3: Int) -> Int {
        var v = read(n1)
        if v == (1 << n1) - 1 {
            let v2 = read(n2)
            v += v2
            if v2 == (1 << n2) - 1 { v += read(n3) }
        }
        return v
    }
}

struct DRMBitWriter {
    var bits: [UInt8] = []
    mutating func write(_ value: Int, _ n: Int) { bits += DRMCRC.bits(value, n) }
    mutating func escaped(_ value: Int, _ n1: Int, _ n2: Int, _ n3: Int) {
        let m1 = (1 << n1) - 1, m2 = (1 << n2) - 1
        if value < m1 { write(value, n1); return }
        write(m1, n1)
        if value - m1 < m2 { write(value - m1, n2); return }
        write(m2, n2)
        write(value - m1 - m2, n3)
    }
    func bytes() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for (i, b) in bits.enumerated() where b != 0 { out[i / 8] |= UInt8(0x80 >> (i % 8)) }
        return out
    }
}

// MARK: - Konfiguration

public struct DRMXHEConfig: Equatable, Sendable {
    public struct Sbr: Equatable, Sendable {
        public var harmonic = false, interTES = false, pvc = false
        public var startFreq = 0, stopFreq = 0
        /// dflt_freq_scale (2), dflt_alter_scale (1), dflt_noise_bands (2)
        public var scale: [Int]?
        /// dflt_limiter_bands (2), dflt_limiter_gains (2), dflt_interpol_freq (1), dflt_smoothing_mode (1)
        public var limiter: [Int]?
        public init() {}
    }
    public struct Mps: Equatable, Sendable {
        public var freqRes = 0, fixedGainDMX = 0
        /// 0 aus, 3 Transient Steering Decorrelator (ISO-Wert von bsTempShapeConfig)
        public var tempShape = 0
        public var highRateMode = 0, phaseCoding = 0
        public var ottBandsPhase: Int?
        public var residualBands = 0, pseudoLr = 0
        public init() {}
    }
    public struct Ext: Equatable, Sendable {
        public var type = 0
        public var defaultLength: Int?
        public var payloadFrag = false
        public var config: [UInt8] = []
        public init() {}
    }
    public struct ConfigExt: Equatable, Sendable {
        public var type = 0
        public var payload: [UInt8] = []
        public init() {}
    }

    /// ISO-Zählung (1: 1024 ohne SBR, 2: 768 mit 8:3, 3: 1024 mit 2:1, 4: 1024 mit 4:1); DRM zählt um eins niedriger
    public var coreSbrFrameLengthIndex = 1
    public var channelPair = false
    public var noiseFilling = false
    public var sbr: Sbr?
    public var stereoConfigIndex = 0
    public var mps: Mps?
    public var extElements: [Ext] = []
    public var configExtensions: [ConfigExt]?

    public init() {}

    /// 0 kein SBR, 1 4:1, 2 2:1, 3 8:3
    public var sbrRatioIndex: Int { [0, 0, 3, 2, 1][min(max(coreSbrFrameLengthIndex, 0), 4)] }
    /// Samples je Kanal und Zugriffseinheit am Ausgang
    public var granule: Int { [0, 1024, 2048, 2048, 4096][min(max(coreSbrFrameLengthIndex, 0), 4)] }

    // MARK: DRM-Kurzform lesen und schreiben

    /// Aus dem Feld „codec specific config“ des SDC (Typ 9). `stereo`: Betriebsart „Stereo“ (sonst Mono).
    public init?(drm bytes: [UInt8], stereo: Bool) {
        var r = DRMBitReader(bytes: bytes)
        let drmIndex = r.read(2)
        coreSbrFrameLengthIndex = drmIndex + 1
        channelPair = stereo
        noiseFilling = r.read(1) == 1
        if sbrRatioIndex > 0 {
            sbr = Self.readSbr(&r)
            if stereo { stereoConfigIndex = r.read(2) }
        }
        if stereoConfigIndex > 0 {
            var m = Mps()
            m.freqRes = r.read(3)
            m.fixedGainDMX = r.read(3)
            m.tempShape = r.read(1) == 1 ? 3 : 0
            m.highRateMode = r.read(1)
            m.phaseCoding = r.read(1)
            if r.read(1) == 1 { m.ottBandsPhase = r.read(5) }
            if stereoConfigIndex > 1 { m.residualBands = r.read(5); m.pseudoLr = r.read(1) }
            mps = m
        }
        let numExt = r.escaped(2, 4, 8)
        guard numExt <= 8 else { return nil }
        for _ in 0..<numExt { extElements.append(Self.readExt(&r)) }
        if r.read(1) == 1 { configExtensions = Self.readConfigExtensions(&r) }
        if r.failed { return nil }
    }

    /// Umkehrung (für Prüfungen und den Sender); nil, wenn die Konfiguration in der DRM-Kurzform nicht darstellbar ist
    public func drmBytes() -> [UInt8]? {
        guard (1...4).contains(coreSbrFrameLengthIndex), (sbrRatioIndex > 0) == (sbr != nil), (stereoConfigIndex > 0) == (mps != nil) else { return nil }
        if let m = mps, m.tempShape != 0, m.tempShape != 3 { return nil }
        var w = DRMBitWriter()
        w.write(coreSbrFrameLengthIndex - 1, 2)
        w.write(noiseFilling ? 1 : 0, 1)
        if let s = sbr {
            Self.writeSbr(&w, s)
            if channelPair { w.write(stereoConfigIndex, 2) }
        }
        if let m = mps {
            w.write(m.freqRes, 3); w.write(m.fixedGainDMX, 3); w.write(m.tempShape == 3 ? 1 : 0, 1)
            w.write(m.highRateMode, 1); w.write(m.phaseCoding, 1)
            if let o = m.ottBandsPhase { w.write(1, 1); w.write(o, 5) } else { w.write(0, 1) }
            if stereoConfigIndex > 1 { w.write(m.residualBands, 5); w.write(m.pseudoLr, 1) }
        }
        w.escaped(extElements.count, 2, 4, 8)
        for e in extElements { Self.writeExt(&w, e) }
        if let c = configExtensions { w.write(1, 1); Self.writeConfigExtensions(&w, c) } else { w.write(0, 1) }
        return w.bytes()
    }

    // MARK: Standard-UsacConfig lesen und schreiben (Reihenfolge der Elemente: Hauptelement, dann Erweiterungen)

    /// AudioSpecificConfig (Objekttyp 42) für den Decoder; `sampleRate` ist die Ausgabe-Abtastrate (SDC-Feld „audio sampling rate“)
    public func audioSpecificConfig(sampleRate: Int) -> [UInt8] {
        var w = DRMBitWriter()
        w.write(31, 5); w.write(42 - 32, 6)
        let asc = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
        if let i = asc.firstIndex(of: sampleRate) { w.write(i, 4) } else { w.write(15, 4); w.write(sampleRate, 24) }
        w.write(channelPair ? 2 : 1, 4)
        // Der Systemdecoder kennt nur die klassische Tabelle (Index 0 bis 12) und den Ausnahmewert, nicht die erweiterten Einträge (z. B. 9,6 kHz): dafür den Ausnahmewert schreiben
        if let i = asc.firstIndex(of: sampleRate) { w.write(i, 5) } else { w.write(31, 5); w.write(sampleRate, 24) }
        w.write(coreSbrFrameLengthIndex, 3)
        w.write(channelPair ? 2 : 1, 5)
        w.escaped(extElements.count, 4, 8, 16)           // numElements − 1 = Hauptelement + Erweiterungen − 1
        w.write(channelPair ? 1 : 0, 2)
        w.write(0, 1)                                    // tw_mdct
        w.write(noiseFilling ? 1 : 0, 1)
        if let s = sbr {
            Self.writeSbr(&w, s)
            if channelPair { w.write(stereoConfigIndex, 2) }
        }
        if let m = mps {
            w.write(m.freqRes, 3); w.write(m.fixedGainDMX, 3); w.write(m.tempShape, 2); w.write(0, 2)   // bsDecorrConfig = 0
            w.write(m.highRateMode, 1); w.write(m.phaseCoding, 1)
            if let o = m.ottBandsPhase { w.write(1, 1); w.write(o, 5) } else { w.write(0, 1) }
            if stereoConfigIndex > 1 { w.write(m.residualBands, 5); w.write(m.pseudoLr, 1) }
        }
        for e in extElements { w.write(3, 2); Self.writeExt(&w, e) }
        if let c = configExtensions { w.write(1, 1); Self.writeConfigExtensions(&w, c) } else { w.write(0, 1) }
        return w.bytes()
    }

    /// AudioSpecificConfig mit UsacConfig lesen (Hauptelement zuerst; weitere Erweiterungen danach). Für Prüfungen. Erweiterungselemente vor dem Hauptelement
    /// (z. B. „Audio Preroll“ in MP4-Dateien) werden verworfen, `dropped` zählt sie.
    public static func parse(audioSpecificConfig bytes: [UInt8]) -> (config: DRMXHEConfig, sampleRate: Int, dropped: Int)? {
        var r = DRMBitReader(bytes: bytes)
        guard r.read(5) == 31, r.read(6) == 10 else { return nil }
        let sfi = r.read(4)
        let asc = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
        var rate = sfi == 15 ? r.read(24) : (sfi < asc.count ? asc[sfi] : 0)
        _ = r.read(4)
        let usacIndex = r.read(5)
        let usacRates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350, 0, 0, 0,
                         57_600, 51_200, 40_000, 38_400, 34_150, 28_800, 25_600, 20_000, 19_200, 17_075, 14_400, 12_800, 9_600]
        if usacIndex == 31 { rate = r.read(24) } else if usacIndex < usacRates.count, usacRates[usacIndex] != 0 { rate = usacRates[usacIndex] }
        var c = DRMXHEConfig()
        c.coreSbrFrameLengthIndex = r.read(3)
        let channelIndex = r.read(5)
        guard (1...2).contains(channelIndex), (1...4).contains(c.coreSbrFrameLengthIndex) else { return nil }
        c.channelPair = channelIndex == 2
        let count = r.escaped(4, 8, 16) + 1
        guard count <= 16 else { return nil }
        var mainSeen = false, dropped = 0
        for _ in 0..<count {
            let type = r.read(2)
            if type == 3 {
                let e = readExt(&r)
                if mainSeen { c.extElements.append(e) } else { dropped += 1 }
            } else if type == 0 || type == 1, !mainSeen {
                mainSeen = true
                guard (type == 1) == c.channelPair else { return nil }
                _ = r.read(1)
                c.noiseFilling = r.read(1) == 1
                if c.sbrRatioIndex > 0 {
                    c.sbr = readSbr(&r)
                    if c.channelPair { c.stereoConfigIndex = r.read(2) }
                }
                if c.stereoConfigIndex > 0 {
                    var m = Mps()
                    m.freqRes = r.read(3); m.fixedGainDMX = r.read(3); m.tempShape = r.read(2); _ = r.read(2)
                    m.highRateMode = r.read(1); m.phaseCoding = r.read(1)
                    if r.read(1) == 1 { m.ottBandsPhase = r.read(5) }
                    if c.stereoConfigIndex > 1 { m.residualBands = r.read(5); m.pseudoLr = r.read(1) }
                    if m.tempShape == 2 { _ = r.read(1) }
                    c.mps = m
                }
            } else { return nil }
        }
        if r.read(1) == 1 { c.configExtensions = readConfigExtensions(&r) }
        return r.failed ? nil : (c, rate, dropped)
    }

    // MARK: Teilstücke

    private static func readSbr(_ r: inout DRMBitReader) -> Sbr {
        var s = Sbr()
        s.harmonic = r.read(1) == 1; s.interTES = r.read(1) == 1; s.pvc = r.read(1) == 1
        s.startFreq = r.read(4); s.stopFreq = r.read(4)
        let extra1 = r.read(1) == 1, extra2 = r.read(1) == 1
        if extra1 { s.scale = [r.read(2), r.read(1), r.read(2)] }
        if extra2 { s.limiter = [r.read(2), r.read(2), r.read(1), r.read(1)] }
        return s
    }

    private static func writeSbr(_ w: inout DRMBitWriter, _ s: Sbr) {
        w.write(s.harmonic ? 1 : 0, 1); w.write(s.interTES ? 1 : 0, 1); w.write(s.pvc ? 1 : 0, 1)
        w.write(s.startFreq, 4); w.write(s.stopFreq, 4)
        w.write(s.scale != nil ? 1 : 0, 1); w.write(s.limiter != nil ? 1 : 0, 1)
        if let a = s.scale { w.write(a[0], 2); w.write(a[1], 1); w.write(a[2], 2) }
        if let a = s.limiter { w.write(a[0], 2); w.write(a[1], 2); w.write(a[2], 1); w.write(a[3], 1) }
    }

    private static func readExt(_ r: inout DRMBitReader) -> Ext {
        var e = Ext()
        e.type = r.escaped(4, 8, 16)
        let length = r.escaped(4, 8, 16)
        if r.read(1) == 1 { e.defaultLength = r.escaped(8, 16, 0) + 1 }
        e.payloadFrag = r.read(1) == 1
        if length <= r.remaining / 8 { e.config = (0..<length).map { _ in UInt8(r.read(8)) } } else { r.failed = true }
        return e
    }

    private static func writeExt(_ w: inout DRMBitWriter, _ e: Ext) {
        w.escaped(e.type, 4, 8, 16)
        w.escaped(e.config.count, 4, 8, 16)
        if let d = e.defaultLength { w.write(1, 1); w.escaped(d - 1, 8, 16, 0) } else { w.write(0, 1) }
        w.write(e.payloadFrag ? 1 : 0, 1)
        for b in e.config { w.write(Int(b), 8) }
    }

    private static func readConfigExtensions(_ r: inout DRMBitReader) -> [ConfigExt] {
        let n = r.escaped(2, 4, 8) + 1
        var list: [ConfigExt] = []
        for _ in 0..<min(n, 16) {
            var c = ConfigExt()
            c.type = r.escaped(4, 8, 16)
            let length = r.escaped(4, 8, 16)
            if length <= r.remaining / 8 { c.payload = (0..<length).map { _ in UInt8(r.read(8)) } } else { r.failed = true; break }
            list.append(c)
        }
        return list
    }

    private static func writeConfigExtensions(_ w: inout DRMBitWriter, _ list: [ConfigExt]) {
        w.escaped(list.count - 1, 2, 4, 8)
        for c in list {
            w.escaped(c.type, 4, 8, 16)
            w.escaped(c.payload.count, 4, 8, 16)
            for b in c.payload { w.write(Int(b), 8) }
        }
    }
}

// MARK: - Überrahmen

/// Zerlegt die xHE-AAC-Überrahmen eines Stroms in Audiorahmen. Rahmen laufen über Überrahmen hinweg; der Zustand muss deshalb mitgeführt werden.
public final class DRMXHEFramer {
    public struct Result: Sendable {
        /// Zugriffseinheiten ohne CRC; leer = Rahmen fehlerhaft oder verloren
        public var units: [[UInt8]] = []
        public var headerOK = true
    }

    /// Bytes ab dem ältesten noch nicht abgeschlossenen Rahmenbeginn; `starts` sind absolute Positionen, `base` die absolute Position von `buffer[0]`
    private var buffer: [UInt8] = []
    private var base = 0
    private var starts: [Int] = []
    private var synced = false

    public init() {}

    public func reset() { buffer.removeAll(); starts.removeAll(); base = 0; synced = false }

    /// Ein Überrahmen (ohne die Textnachricht am Ende). `valid` = der Kanaldecoder meldet den Rahmen als brauchbar.
    public func feed(_ data: [UInt8]) -> Result {
        var result = Result()
        guard data.count >= 2 else { reset(); result.headerOK = false; return result }
        let count = Int(data[0] >> 4)
        let crcOK = DRMCRC.compute(DRMCRC.bits(Int(data[0]), 8)[...], degree: 8) == Int(data[1])
        guard crcOK, 2 + 2 * count <= data.count else {
            // Der Kopf ist unbrauchbar: Zustand verwerfen, die laufenden Rahmen sind verloren
            result.headerOK = false
            if synced { result.units.append([]) }
            reset()
            return result
        }
        let payloadEnd = data.count - 2 * count
        let payload = Array(data[2..<payloadEnd])
        // Verzeichnis: letztes Element = erste Grenze
        var borders: [Int] = []
        for k in 0..<count {
            let off = data.count - 2 * (k + 1)
            let v = (Int(data[off]) << 8) | Int(data[off + 1])
            borders.append(v >> 4)
        }
        let payloadBase = base + buffer.count
        var absolute: [Int] = []
        for b in borders {
            if b == 0xFFF { absolute.append(payloadBase - 1) } else if b == 0xFFE { absolute.append(payloadBase - 2) } else if b < payload.count { absolute.append(payloadBase + b) } else {
                result.headerOK = false; reset(); return result
            }
        }
        buffer += payload
        if !synced, absolute.isEmpty { buffer.removeAll(); base = payloadBase + payload.count; return result }
        if !synced {
            // erster Rahmenbeginn: davor liegende Bytes gehören zu einem unvollständigen Rahmen
            let first = absolute[0]
            if first < base { absolute.removeFirst() }
            guard let f = absolute.first else { buffer.removeAll(); base = payloadBase + payload.count; return result }
            let cut = f - base
            buffer.removeFirst(min(max(cut, 0), buffer.count)); base += cut
            synced = true
        }
        starts += absolute
        // abgeschlossene Rahmen: zwischen aufeinanderfolgenden Beginnen
        while starts.count >= 2 {
            let a = starts[0] - base, b = starts[1] - base
            guard a >= 0, b > a + 2, b <= buffer.count else { starts.removeFirst(); if a < 0 { result.units.append([]) }; continue }
            let frame = Array(buffer[a..<b])
            let body = Array(frame.dropLast(2))
            let crc = (Int(frame[frame.count - 2]) << 8) | Int(frame[frame.count - 1])
            let good = DRMCRC.compute(body.flatMap { DRMCRC.bits(Int($0), 8) }[...], degree: 16) == crc
            result.units.append(good ? body : [])
            starts.removeFirst()
        }
        // Bytes vor dem ältesten offenen Beginn wegwerfen
        if let s = starts.first {
            let cut = s - base
            if cut > 0 { buffer.removeFirst(min(cut, buffer.count)); base += cut }
        }
        return result
    }
}

/// Gegenstück für Prüfungen und den Testsender: packt Zugriffseinheiten in Überrahmen fester Größe
public final class DRMXHEPacker {
    private var queue: [[UInt8]] = []
    private var partial: [UInt8] = []
    private var delayed: Int?
    public var bitReservoirLevel = 4

    public init() {}

    public var queuedBytes: Int { queue.reduce(0) { $0 + $1.count + 2 } + partial.count }

    public func add(accessUnit au: [UInt8]) {
        let crc = DRMCRC.compute(au.flatMap { DRMCRC.bits(Int($0), 8) }[...], degree: 16)
        queue.append(au + [UInt8(crc >> 8), UInt8(crc & 0xFF)])
    }

    /// Ein Überrahmen mit `size` Byte; nil, wenn nicht genug Rahmen vorliegen
    public func pack(size: Int) -> [UInt8]? {
        var entries: [Int] = []
        if let d = delayed { entries.append(d); delayed = nil }
        var payload: [UInt8] = []
        var capacity = size - 2 - 2 * entries.count
        func take(_ n: Int) {
            let k = min(n, partial.count)
            payload += partial.prefix(k)
            partial.removeFirst(k)
        }
        take(capacity)
        var delayedNext: Int?
        while payload.count < capacity {
            if !partial.isEmpty { take(capacity - payload.count); continue }
            guard !queue.isEmpty else { return nil }
            let free = capacity - payload.count
            if free >= 3 {
                entries.append(payload.count)
                capacity -= 2
                partial = queue.removeFirst()
                take(capacity - payload.count)
            } else {
                // Platz für höchstens zwei Byte: der nächste Rahmen beginnt hier, sein Eintrag steht im folgenden Überrahmen
                delayedNext = free == 1 ? 0xFFF : 0xFFE
                partial = queue.removeFirst()
                take(free)
            }
        }
        delayed = delayedNext
        let b = entries.count
        guard b <= 15 else { return nil }
        let head = (b << 4) | bitReservoirLevel
        let crc = DRMCRC.compute(DRMCRC.bits(head, 8)[...], degree: 8)
        var out: [UInt8] = [UInt8(head), UInt8(crc)] + payload
        for e in entries.reversed() {
            let v = (e << 4) | b
            out += [UInt8(v >> 8), UInt8(v & 0xFF)]
        }
        return out
    }
}
