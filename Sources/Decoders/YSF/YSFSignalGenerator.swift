// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Erzeugt YSF-Rahmen (V/D-Modus 2) als Symbolfolge für Prüfstände: Kopf, Kommunikationsrahmen mit Sprache, Abschluss.

public enum YSFSignalGenerator {
    private static func padded(_ text: String, _ length: Int) -> [UInt8] {
        var b = Array(text.utf8.prefix(length))
        while b.count < length { b.append(0x20) }
        return b
    }

    private static func bitsMSB(_ bytes: [UInt8]) -> [UInt8] { bytes.flatMap { b in (0..<8).map { UInt8((b >> UInt8(7 - $0)) & 1) } } }

    private static func levels(fromBits bits: [UInt8]) -> [Float] {
        stride(from: 0, to: bits.count, by: 2).map { FourFSK.level(ofDibit: (bits[$0] << 1) | bits[$0 + 1]) }
    }

    /// 100 Symbole für einen Datenkanal von V/D-Modus 2 (10 Byte)
    static func vd2Channel(_ bytes: [UInt8]) -> [Float] {
        let clear = bitsMSB(bytes)
        let sent = (0..<80).map { clear[$0] ^ YSF.whitening[$0] }
        let withCRC = sent + YaesuCRC.checkBits(for: sent)
        let conv = ConvK5.encode(withCRC + [0, 0, 0, 0])
        return YSFInterleave.interleave(levels(fromBits: conv), columns: 20, rows: 5)
    }

    /// 180 Symbole für einen Datenkanal von Kopf und Abschluss (20 Byte)
    static func fullChannel(_ bytes: [UInt8]) -> [Float] {
        let clear = bitsMSB(bytes)
        let sent = (0..<160).map { clear[$0] ^ YSF.whitening[$0] }
        let withCRC = sent + YaesuCRC.checkBits(for: sent)
        let conv = ConvK5.encode(withCRC + [0, 0, 0, 0])
        return YSFInterleave.interleave(levels(fromBits: conv), columns: 20, rows: 9)
    }

    /// Kopf oder Abschluss: Rufzeichen in zwei Kanälen
    public static func headerFrame(fi: Int, fn: Int = 0, ft: Int = 6, destination: String, source: String, uplink: String, downlink: String) -> [Float] {
        let fich = YSFFich(fi: fi, cs: 2, cm: 0, bn: 0, bt: 0, fn: fn, ft: ft, mr: 2, viaRepeater: false, dt: 2, squelchEnabled: false, squelchCode: 0)
        let a = fullChannel(padded(destination, 10) + padded(source, 10))
        let b = fullChannel(padded(uplink, 10) + padded(downlink, 10))
        var payload: [Float] = []
        for chunk in 0..<10 {
            let src = chunk % 2 == 0 ? a : b
            let part = chunk / 2
            payload += src[(part * 36)..<(part * 36 + 36)]
        }
        return YSF.syncLevels + fich.symbols() + payload
    }

    /// Kommunikationsrahmen: fünf Sprachrahmen (je 49 Nutzbits) und ein Datenkanal (Rufzeichen je nach Rahmennummer)
    public static func voiceFrame(fn: Int, ft: Int = 6, data49: [[UInt8]], dch: [UInt8]) -> [Float] {
        precondition(data49.count == 5)
        let fich = YSFFich(fi: 1, cs: 2, cm: 0, bn: 0, bt: 0, fn: fn, ft: ft, mr: 2, viaRepeater: false, dt: 2, squelchEnabled: false, squelchCode: 0)
        let channel = vd2Channel(dch)
        var payload: [Float] = []
        for i in 0..<5 { payload += channel[(i * 20)..<(i * 20 + 20)]; payload += YSFVoice.symbols(forData49: data49[i]) }
        return YSF.syncLevels + fich.symbols() + payload
    }

    /// Eine ganze Aussendung: Kopf, `voiceFrames` Kommunikationsrahmen (Rufzeichen kreisen durch die Rahmennummern), Abschluss
    public static func transmission(destination: String = "CQCQCQ", source: String, uplink: String = "", downlink: String = "", data49: (Int) -> [[UInt8]], voiceFrames: Int) -> [Float] {
        var symbols = headerFrame(fi: 0, destination: destination, source: source, uplink: uplink, downlink: downlink)
        for n in 0..<voiceFrames {
            let fn = n % 7
            let dch: [UInt8]
            switch fn {
            case 0: dch = padded(destination, 10)
            case 1: dch = padded(source, 10)
            case 2: dch = padded(uplink, 10)
            case 3: dch = padded(downlink, 10)
            default: dch = padded("", 10)
            }
            symbols += voiceFrame(fn: fn, data49: data49(n), dch: dch)
        }
        symbols += headerFrame(fi: 2, fn: voiceFrames % 7, destination: destination, source: source, uplink: uplink, downlink: downlink)
        return symbols
    }
}
