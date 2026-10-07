// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Erzeugt M17-Aussendungen als Symbolfolge für Prüfstände: Vorspann, LSF-Rahmen, Strom-Rahmen (mit LICH-Anteilen des LSF), Ende.

public enum M17SignalGenerator {
    /// Ein Gespräch
    /// - Parameters:
    ///   - payloads: Nutzlast je Strom-Rahmen (16 Byte); die Rahmennummer zählt ab 0, der letzte Rahmen trägt das Ende-Bit
    ///   - withLSF: LSF-Rahmen vor dem Strom (sonst später Einstieg: der LSF kommt nur über die LICH-Anteile)
    ///   - withEnd: Ende-Rahmen (0x555D) am Schluss
    ///   - signature: 64 Byte; werden in vier weiteren Rahmen (Nummer 0x7FFC … 0x7FFF) nach der Nutzlast gesendet, der letzte trägt das Ende-Bit
    public static func call(lsf: M17LSF, payloads: [[UInt8]], withLSF: Bool = true, withEnd: Bool = true, preambles: Int = 1, firstFrameNumber: Int = 0, signature: [UInt8]? = nil) -> [Float] {
        var out: [Float] = []
        for _ in 0..<preambles { out += M17.preambleSymbols() }
        if withLSF { out += M17.lsfFrameSymbols(lsf) }
        let bytes = lsf.bytes
        for (i, payload) in payloads.enumerated() {
            let fn = (firstFrameNumber + i) & 0x7FFF
            let counter = fn % 6
            out += M17.streamFrameSymbols(lichChunk: Array(bytes[(counter * 5)..<(counter * 5 + 5)]), counter: counter, last: signature == nil && i == payloads.count - 1, frameNumber: fn, payload: payload)
        }
        if let signature {
            precondition(signature.count == 64)
            for k in 0..<4 {
                let counter = (firstFrameNumber + payloads.count + k) % 6
                out += M17.streamFrameSymbols(lichChunk: Array(bytes[(counter * 5)..<(counter * 5 + 5)]), counter: counter, last: k == 3, frameNumber: M17Signature.firstSignatureFrame + k, payload: Array(signature[(k * 16)..<(k * 16 + 16)]))
            }
        }
        if withEnd { out += M17.endSymbols() }
        return out
    }

    /// Eine BERT-Aussendung: Vorspann B, dann PRBS9-Rahmen (die Folge läuft über die Rahmen weiter), Ende
    /// - Parameters:
    ///   - skipFrames: Rahmen am Anfang, die nicht gesendet werden (später Einstieg: die Folge läuft für den Empfänger an einer beliebigen Stelle los)
    ///   - flipBits: Rahmennummer → Bitstellen, die vor dem Senden gekippt werden (bekannte Fehler)
    public static func bertCall(frames: Int, skipFrames: Int = 0, flipBits: [Int: [Int]] = [:], withEnd: Bool = true) -> [Float] {
        var out = M17.bertPreambleSymbols()
        var prbs = M17PRBS9()
        for n in 0..<(skipFrames + frames) {
            var bits = (0..<197).map { _ in prbs.next() }
            guard n >= skipFrames else { continue }
            for i in flipBits[n - skipFrames] ?? [] { bits[i] ^= 1 }
            out += M17.bertFrameSymbols(bits: bits)
        }
        if withEnd { out += M17.endSymbols() }
        return out
    }

    /// Eine Paket-Aussendung: Vorspann, LSF (Typ „Paket“), Paket-Rahmen. Nach dem letzten Rahmen folgt kein Schlusswort.
    /// - Parameter skipFrame: lässt einen Rahmen aus (Prüfstand für Übertragungsverluste)
    public static func packetCall(lsf: M17LSF, packet: M17Packet, preambles: Int = 1, skipFrame: Int? = nil, lsfRepeats: Int = 1) -> [Float] {
        var out: [Float] = []
        for _ in 0..<preambles { out += M17.preambleSymbols() }
        for _ in 0..<lsfRepeats { out += M17.lsfFrameSymbols(lsf) }
        for (i, f) in M17.packetFrames(of: packet).enumerated() where i != skipFrame { out += M17.packetFrameSymbols(f) }
        return out
    }
}
