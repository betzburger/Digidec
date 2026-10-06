// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Farbverlauf des Wasserfalls im RadioTheme: Hintergrund (bgDeep) → Blau → Cyan → Grün → Amber → Rot → Weiß.
public enum WaterfallColorMap {
    /// 256 Einträge, je 0xAABBGGRR (Byte-Reihenfolge RGBA im Speicher, little endian)
    public static let lut: [UInt32] = {
        let stops: [(Double, (Double, Double, Double))] = [
            (0.00, (0.07, 0.08, 0.10)),   // RadioTheme.bgDeep
            (0.20, (0.05, 0.18, 0.40)),
            (0.40, (0.00, 0.60, 0.85)),
            (0.55, (0.00, 0.90, 1.00)),   // vfdCyan
            (0.70, (0.00, 0.95, 0.45)),   // vfdGreen
            (0.82, (1.00, 0.72, 0.10)),   // vfdAmber
            (0.93, (1.00, 0.20, 0.30)),   // ledRed
            (1.00, (1.00, 0.95, 0.95))
        ]
        return (0..<256).map { i in
            let x = Double(i) / 255
            let upper = stops.firstIndex { $0.0 >= x } ?? stops.count - 1
            let lower = max(0, upper - 1)
            let (x0, c0) = stops[lower]
            let (x1, c1) = stops[upper]
            let t = x1 > x0 ? (x - x0) / (x1 - x0) : 0
            func ch(_ a: Double, _ b: Double) -> UInt32 { UInt32(((a + (b - a) * t) * 255).rounded()) }
            let r = ch(c0.0, c1.0), g = ch(c0.1, c1.1), b = ch(c0.2, c1.2)
            return 0xFF00_0000 | (b << 16) | (g << 8) | r
        }
    }()

    /// dB-Wert → Index 0…255: `floorDB` wird dunkel, `floorDB + rangeDB` voll ausgesteuert.
    @inline(__always)
    public static func index(db: Float, floorDB: Float, rangeDB: Float) -> Int {
        let v = (db - floorDB) / rangeDB
        return Int(max(0, min(255, v * 255)))
    }
}
