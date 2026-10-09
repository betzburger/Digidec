// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

/// Farbcodierung eines SSTV-Modus
public enum SSTVColorEncoding: String, Sendable, Codable {
    case gbr    // Martin, Scottie (Grün, Blau, Rot sequentiell)
    case rgb    // Wraase SC2 (Rot, Grün, Blau sequentiell)
    case yuv    // Robot, PD (Luminanz Y und Farbdifferenzen R-Y / B-Y)
}

/// Bildanteil, den ein Zeilenabschnitt überträgt.
public enum SSTVComponent: Sendable, Equatable {
    case green, blue, red
    case luma           // Y (bei PD: Y der ersten Zeile des Paares)
    case luma2          // Y der zweiten Zeile eines PD-Paares
    case chromaV        // R-Y
    case chromaU        // B-Y
    case chromaAlt      // Robot 36: abwechselnd R-Y / B-Y (Zeilenparität steht im Trennimpuls)
    case parityProbe    // Robot 36: Trennimpuls (1500 Hz = gerade Zeile / R-Y, 2300 Hz = ungerade Zeile / B-Y)
}

/// Ein Abschnitt der Zeile. `start` ist relativ zum **Ende des 1200-Hz-Syncimpulses** (negativ = davor,
/// z. B. bei Scottie, wo Grün und Blau vor dem Sync liegen).
public struct SSTVSegment: Sendable, Equatable {
    public let component: SSTVComponent
    public let start: Double
    public let duration: Double
}

/// Spezifikation eines Slow-Scan-Television (SSTV) Modus
public struct SSTVModeSpec: Sendable, Equatable {
    public let mode: SSTVMode
    public let name: String
    public let shortName: String
    public let visCode: UInt8
    public let width: Int
    public let height: Int
    public let lineTime: Double       // Abstand zwischen zwei Syncimpulsen in Sekunden (PD: je Zeilenpaar)
    public let syncTime: Double       // Dauer des 1200-Hz-Synctakts in Sekunden
    public let linesPerSync: Int      // Bildzeilen je Syncimpuls (PD: 2, sonst 1)
    public let colorEncoding: SSTVColorEncoding
    public let segments: [SSTVSegment]
    public let transmissionTime: Double // Gesamtdauer des Bildes in Sekunden

    /// Zeitpunkt des frühesten Abschnitts relativ zum Sync-Ende (≤ 0 oder knapp darüber).
    public var earliestOffset: Double { min(0, segments.map(\.start).min() ?? 0) }
    /// Zeitpunkt, an dem der letzte Abschnitt nach dem Sync-Ende endet.
    public var latestEnd: Double { segments.map { $0.start + $0.duration }.max() ?? 0 }
    /// Syncimpuls liegt am Zeilenanfang (alle Modi außer Scottie).
    public var syncAtLineStart: Bool { earliestOffset >= 0 }

    fileprivate init(
        mode: SSTVMode, name: String, shortName: String, visCode: UInt8,
        width: Int, height: Int, lineTime: Double, syncTime: Double,
        linesPerSync: Int = 1, colorEncoding: SSTVColorEncoding, segments: [SSTVSegment]
    ) {
        self.mode = mode
        self.name = name
        self.shortName = shortName
        self.visCode = visCode
        self.width = width
        self.height = height
        self.lineTime = lineTime
        self.syncTime = syncTime
        self.linesPerSync = linesPerSync
        self.colorEncoding = colorEncoding
        self.segments = segments
        self.transmissionTime = lineTime * Double(height / linesPerSync)
    }
}

/// Unterstützte SSTV-Betriebsarten im Amateurfunk
public enum SSTVMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case m1     // Martin 1 (Europäischer Standard, 320x256 GBR)
    case m2     // Martin 2 (Schneller, 320x256 GBR)
    case s1     // Scottie 1 (Nordamerika/UK Standard, 320x256 GBR)
    case s2     // Scottie 2 (Schneller, 320x256 GBR)
    case sdx    // Scottie DX (Hohe Qualität für DX, 320x256 GBR)
    case r36    // Robot 36 (Sehr schnell, VHF / ISS, 320x240 YUV)
    case r72    // Robot 72 (Farb-Robot, 320x240 YUV)
    case pd120  // PD 120 (ARISS / ISS Weltraumstations-Standard, 640x496 YUV)
    case pd90   // PD 90 (320x256 YUV)
    case pd180  // PD 180 (640x496 YUV)
    case w180   // Wraase SC2 180 (320x256 RGB)

    public var id: String { rawValue }

    public var spec: SSTVModeSpec { Self.specs[self]! }

    /// Ermittelt den SSTV-Modus anhand des empfangenen 7-Bit VIS-Codes
    public static func from(visCode: UInt8) -> SSTVMode? {
        let clean = visCode & 0x7F
        return allCases.first { $0.spec.visCode == clean }
    }

    // MARK: - Spezifikationstabelle (Quellen: Martin-/Scottie-/Robot-/PD-/Wraase-Originalspezifikationen)

    private static let specs: [SSTVMode: SSTVModeSpec] = {
        func seg(_ c: SSTVComponent, _ start: Double, _ duration: Double) -> SSTVSegment {
            SSTVSegment(component: c, start: start, duration: duration)
        }

        /// Martin: Sync, Porch, G, Sep, B, Sep, R, Sep
        func martin(_ m: SSTVMode, _ name: String, _ short: String, vis: UInt8, scan: Double) -> SSTVModeSpec {
            let sync = 0.004862, sep = 0.000572
            let g = sep
            let b = g + scan + sep
            let r = b + scan + sep
            return SSTVModeSpec(
                mode: m, name: name, shortName: short, visCode: vis, width: 320, height: 256,
                lineTime: sync + sep + 3 * (scan + sep), syncTime: sync, colorEncoding: .gbr,
                segments: [seg(.green, g, scan), seg(.blue, b, scan), seg(.red, r, scan)])
        }

        /// Scottie: Sep, G, Sep, B, Sync, Porch, R – Sync liegt also vor dem Rotkanal.
        func scottie(_ m: SSTVMode, _ name: String, _ short: String, vis: UInt8, scan: Double) -> SSTVModeSpec {
            let sync = 0.009, sep = 0.0015
            let b = -sync - scan
            let g = b - sep - scan
            let r = sep
            return SSTVModeSpec(
                mode: m, name: name, shortName: short, visCode: vis, width: 320, height: 256,
                lineTime: 3 * scan + 2 * sep + sync + sep, syncTime: sync, colorEncoding: .gbr,
                segments: [seg(.green, g, scan), seg(.blue, b, scan), seg(.red, r, scan)])
        }

        /// PD: Sync, Porch, Y(n), R-Y, B-Y, Y(n+1) – ein Syncimpuls je Zeilenpaar.
        func pd(_ m: SSTVMode, _ name: String, _ short: String, vis: UInt8, width: Int, height: Int, scan: Double) -> SSTVModeSpec {
            let sync = 0.020, porch = 0.00208
            return SSTVModeSpec(
                mode: m, name: name, shortName: short, visCode: vis, width: width, height: height,
                lineTime: sync + porch + 4 * scan, syncTime: sync, linesPerSync: 2, colorEncoding: .yuv,
                segments: [
                    seg(.luma, porch, scan), seg(.chromaV, porch + scan, scan),
                    seg(.chromaU, porch + 2 * scan, scan), seg(.luma2, porch + 3 * scan, scan),
                ])
        }

        let robot36 = SSTVModeSpec(
            mode: .r36, name: "Robot 36", shortName: "R36", visCode: 0x08, width: 320, height: 240,
            lineTime: 0.150, syncTime: 0.009, colorEncoding: .yuv,
            segments: [
                seg(.luma, 0.003, 0.088),
                seg(.parityProbe, 0.091, 0.0045),
                seg(.chromaAlt, 0.097, 0.044),
            ])

        let robot72 = SSTVModeSpec(
            mode: .r72, name: "Robot 72", shortName: "R72", visCode: 0x0C, width: 320, height: 240,
            lineTime: 0.300, syncTime: 0.009, colorEncoding: .yuv,
            segments: [
                seg(.luma, 0.003, 0.138),
                seg(.chromaV, 0.147, 0.069),
                seg(.chromaU, 0.222, 0.069),
            ])

        // Wraase SC2-180: Sync, Porch, R, G, B (ohne Trennimpulse), je Kanal 235 ms
        let wraase = SSTVModeSpec(
            mode: .w180, name: "Wraase SC2 180", shortName: "W180", visCode: 0x37, width: 320, height: 256,
            lineTime: 0.0055225 + 0.0005 + 3 * 0.235, syncTime: 0.0055225, colorEncoding: .rgb,
            segments: [seg(.red, 0.0005, 0.235), seg(.green, 0.0005 + 0.235, 0.235), seg(.blue, 0.0005 + 0.47, 0.235)])

        return [
            .m1: martin(.m1, "Martin 1", "M1", vis: 0x2C, scan: 320 * 0.0004576),
            .m2: martin(.m2, "Martin 2", "M2", vis: 0x28, scan: 320 * 0.0002288),
            .s1: scottie(.s1, "Scottie 1", "S1", vis: 0x3C, scan: 320 * 0.000432),
            .s2: scottie(.s2, "Scottie 2", "S2", vis: 0x38, scan: 320 * 0.0002752),
            .sdx: scottie(.sdx, "Scottie DX", "SDX", vis: 0x4C, scan: 320 * 0.00108),
            .r36: robot36,
            .r72: robot72,
            .pd90: pd(.pd90, "PD 90", "PD90", vis: 0x63, width: 320, height: 256, scan: 320 * 0.000532),
            .pd120: pd(.pd120, "PD 120", "PD120", vis: 0x5F, width: 640, height: 496, scan: 640 * 0.00019),
            .pd180: pd(.pd180, "PD 180", "PD180", vis: 0x60, width: 640, height: 496, scan: 640 * 0.000286),
            .w180: wraase,
        ]
    }()
}
