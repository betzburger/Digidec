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
    public static func call(lsf: M17LSF, payloads: [[UInt8]], withLSF: Bool = true, withEnd: Bool = true, preambles: Int = 1, firstFrameNumber: Int = 0) -> [Float] {
        var out: [Float] = []
        for _ in 0..<preambles { out += M17.preambleSymbols() }
        if withLSF { out += M17.lsfFrameSymbols(lsf) }
        let bytes = lsf.bytes
        for (i, payload) in payloads.enumerated() {
            let fn = (firstFrameNumber + i) & 0x7FFF
            let counter = fn % 6
            out += M17.streamFrameSymbols(lichChunk: Array(bytes[(counter * 5)..<(counter * 5 + 5)]), counter: counter, last: i == payloads.count - 1, frameNumber: fn, payload: payload)
        }
        if withEnd { out += M17.endSymbols() }
        return out
    }
}
