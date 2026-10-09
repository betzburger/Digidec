// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Sendeseite von dPMR für Tests und Prüfstände: Steuerkanäle, Sprachrahmen und Kanalcode zu Symbolen (Pegel ±1, ±3); das Audio entsteht
// mit `FourFSKModulator` bei 2400 Symbolen/s.

public enum DPMRSignalGenerator {
    /// Ein Überrahmen: FS2, CCH, 4 TCH, CC, CCH, 4 TCH (12 + 372 Symbole).
    /// - Parameters:
    ///   - frames: acht Sprachrahmen (je 9 Byte, wie vom Empfänger geliefert)
    ///   - firstFrameNumber: Rahmennummer des ersten Nutzrahmens (0 oder 2); der zweite trägt die folgende
    ///   - idPart: je Nutzrahmen 12 Bit der Kennung
    public static func superframe(frames: [[UInt8]], firstFrameNumber: Int, idParts: (Int, Int), colorCode: Int, mode: Int = 0, version: Int = 0,
                                  emergency: Bool = false, slowData: (Int, Int) = (0, 0)) -> [Float] {
        precondition(frames.count == 8 && frames.allSatisfy { $0.count == 9 })
        let cch0 = DPMRCCH.encode(frameNumber: firstFrameNumber & 3, idPart: idParts.0, mode: mode, version: version, emergency: emergency, slowData: slowData.0)
        let cch1 = DPMRCCH.encode(frameNumber: (firstFrameNumber + 1) & 3, idPart: idParts.1, mode: mode, version: version, emergency: emergency, slowData: slowData.1)
        var out = DPMRSymbols.levels(ofPattern: DPMR.fs2)
        out += DPMRSymbols.levels(ofBits: cch0)
        for k in 0..<4 { out += DPMRSymbols.levels(ofBits: AMBEHalfRate.bits(fromBytes: frames[k])) }
        out += DPMRSymbols.levels(ofBits: DPMR.bits(ofColorCode: colorCode))
        out += DPMRSymbols.levels(ofBits: cch1)
        for k in 4..<8 { out += DPMRSymbols.levels(ofBits: AMBEHalfRate.bits(fromBytes: frames[k])) }
        return out
    }

    /// Ein Gespräch: Überrahmen im Wechsel von gerufener (Rahmen 0, 1) und rufender (2, 3) Kennung; danach das Ende (FS3)
    /// - Parameter frames: Sprachrahmen, je acht je Überrahmen (der Rest wird mit dem letzten aufgefüllt)
    public static func call(called: String, calling: String, colorCode: Int, frames: [[UInt8]], mode: Int = 0, version: Int = 0, emergency: Bool = false,
                            withHeader: Bool = true, withEnd: Bool = true) -> [Float] {
        guard let a = DPMR.idValue(called), let b = DPMR.idValue(calling) else { preconditionFailure("Kennung ungültig") }
        var padded = frames
        while padded.isEmpty || padded.count % 8 != 0 { padded.append(padded.last ?? [UInt8](repeating: 0, count: 9)) }
        var out: [Float] = []
        // Vorspann: Kopfrahmen mit FS1 und Kanalcode (die Sendung beginnt nie mit dem ersten Überrahmen, und die Impulsform braucht Anlauf)
        if withHeader { out += DPMRSymbols.levels(ofPattern: DPMR.fs1) + DPMRSymbols.levels(ofBits: DPMR.bits(ofColorCode: colorCode)) + [Float](repeating: 0, count: 12) }
        for sf in 0..<(padded.count / 8) {
            let part = sf % 2                                    // 0: gerufen, 1: rufend
            let id = part == 0 ? a : b
            out += superframe(frames: Array(padded[(sf * 8)..<(sf * 8 + 8)]), firstFrameNumber: part * 2, idParts: (Int(id >> 12), Int(id & 0xFFF)),
                              colorCode: colorCode, mode: mode, version: version, emergency: emergency)
        }
        if withEnd { out += DPMRSymbols.levels(ofPattern: DPMR.fs3) + [Float](repeating: 0, count: 24) }
        return out
    }
}
