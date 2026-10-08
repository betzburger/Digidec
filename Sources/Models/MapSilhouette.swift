// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import CoreGraphics

/// Umriss eines Fahrzeugs von oben für die Karte. Die Umrisse sind Vielecke in einem Quadrat von −1 … +1 (x nach rechts, y nach unten),
/// der Bug zeigt nach oben (Norden); die Oberfläche dreht sie um den Kurs. Mehrere Vielecke ergeben eine Form (Flügel, Triebwerke, Rotor).
public enum MapSilhouette: String, CaseIterable, Sendable {
    // Flugzeuge
    case airliner, heavy, bizjet, lightProp, helicopter, glider, drone, balloon, fighter, groundVehicle

    /// Deutsche Bezeichnung für Auswahltext und Legende
    public var label: String {
        switch self {
        case .airliner:      return "Verkehrsflugzeug"
        case .heavy:         return "Großraumflugzeug"
        case .bizjet:        return "Geschäftsreiseflugzeug"
        case .lightProp:     return "Kleinflugzeug"
        case .helicopter:    return "Hubschrauber"
        case .glider:        return "Segelflugzeug"
        case .drone:         return "Drohne"
        case .balloon:       return "Ballon"
        case .fighter:       return "Hochleistungsflugzeug"
        case .groundVehicle: return "Fahrzeug am Boden"
        }
    }

    /// Kantenlänge des Quadrats in Punkten bei normaler Darstellung (größere Fahrzeuge erscheinen größer)
    public var size: CGFloat {
        switch self {
        case .airliner:      return 24
        case .heavy:         return 29
        case .bizjet:        return 19
        case .lightProp:     return 18
        case .helicopter:    return 22
        case .glider:        return 25
        case .drone:         return 15
        case .balloon:       return 17
        case .fighter:       return 21
        case .groundVehicle: return 12
        }
    }

    /// Vielecke des Umrisses
    public var contours: [[CGPoint]] { Self.table[self] ?? [] }

    // MARK: Bausteine

    /// Rechte Hälfte (vom Bug zum Heck, jeweils auf der Mittelachse beginnend und endend) zu einem symmetrischen Vieleck spiegeln
    static func mirrored(_ right: [(Double, Double)]) -> [CGPoint] {
        let r = right.map { CGPoint(x: $0.0, y: $0.1) }
        let left = r.dropFirst().dropLast().reversed().map { CGPoint(x: -$0.x, y: $0.y) }
        return r + left
    }

    /// Rechteck mit Mittelpunkt, Länge entlang x, Breite entlang y, gedreht um `degrees`
    static func bar(cx: Double, cy: Double, length: Double, width: Double, degrees: Double = 0) -> [CGPoint] {
        let a = degrees * .pi / 180
        let c = cos(a), s = sin(a)
        return [(-length / 2, -width / 2), (length / 2, -width / 2), (length / 2, width / 2), (-length / 2, width / 2)]
            .map { CGPoint(x: cx + $0.0 * c - $0.1 * s, y: cy + $0.0 * s + $0.1 * c) }
    }

    /// Regelmäßiges Vieleck (Rotorscheibe, Ballon)
    static func polygon(cx: Double, cy: Double, radius: Double, sides: Int) -> [CGPoint] {
        (0..<sides).map { i in
            let a = 2 * Double.pi * Double(i) / Double(sides)
            return CGPoint(x: cx + radius * cos(a), y: cy + radius * sin(a))
        }
    }

    private static let table: [MapSilhouette: [[CGPoint]]] = [
        // Rumpf schlank, Flügel stark gepfeilt, Höhen- und Seitenleitwerk
        .airliner: [mirrored([(0, -1), (0.05, -0.93), (0.065, -0.78), (0.07, -0.55), (0.07, -0.14), (0.95, 0.30), (0.95, 0.43), (0.07, 0.12),
                              (0.065, 0.60), (0.34, 0.86), (0.34, 0.96), (0.045, 0.84), (0.025, 0.99), (0, 1)])],
        // breiterer Rumpf, größere Spannweite, vier Triebwerke unter den Flügeln
        .heavy: [mirrored([(0, -1), (0.07, -0.93), (0.1, -0.75), (0.1, -0.2), (1.0, 0.26), (1.0, 0.42), (0.1, 0.14), (0.09, 0.62), (0.36, 0.86),
                           (0.36, 0.97), (0.06, 0.86), (0.03, 1.0), (0, 1)]),
                 bar(cx: 0.30, cy: 0.12, length: 0.22, width: 0.09, degrees: 90), bar(cx: -0.30, cy: 0.12, length: 0.22, width: 0.09, degrees: 90),
                 bar(cx: 0.58, cy: 0.23, length: 0.20, width: 0.09, degrees: 90), bar(cx: -0.58, cy: 0.23, length: 0.20, width: 0.09, degrees: 90)],
        // kurzer Rumpf, Flügel weit hinten, Triebwerke am Heck
        .bizjet: [mirrored([(0, -1), (0.045, -0.9), (0.06, -0.7), (0.06, -0.1), (0.72, 0.34), (0.72, 0.46), (0.06, 0.28), (0.06, 0.62), (0.3, 0.84),
                            (0.3, 0.93), (0.04, 0.84), (0.02, 1.0), (0, 1)]),
                  bar(cx: 0.14, cy: 0.52, length: 0.34, width: 0.1, degrees: 90), bar(cx: -0.14, cy: 0.52, length: 0.34, width: 0.1, degrees: 90)],
        // gerader Flügel von gleicher Tiefe, kleines Leitwerk, Propellerkreis am Bug
        .lightProp: [mirrored([(0, -0.97), (0.055, -0.93), (0.065, -0.75), (0.065, -0.40), (0.96, -0.38), (0.96, -0.10), (0.065, -0.04), (0.055, 0.50),
                               (0.36, 0.68), (0.36, 0.86), (0.04, 0.84), (0, 1.0)]),
                     bar(cx: 0, cy: -1.0, length: 0.62, width: 0.07)],
        // Rumpf, Heckausleger, Heckrotor und zwei gekreuzte Rotorblätter
        .helicopter: [mirrored([(0, -0.6), (0.14, -0.5), (0.2, -0.2), (0.15, 0.2), (0.05, 0.34), (0.045, 0.82), (0.0, 0.86)]),
                      bar(cx: 0, cy: 0.9, length: 0.3, width: 0.06, degrees: 90),
                      bar(cx: 0, cy: -0.1, length: 1.9, width: 0.07, degrees: 35), bar(cx: 0, cy: -0.1, length: 1.9, width: 0.07, degrees: -35)],
        // sehr lange, schmale Flügel
        .glider: [mirrored([(0, -0.95), (0.035, -0.88), (0.04, -0.4), (1.0, -0.27), (1.0, -0.15), (0.04, -0.11), (0.03, 0.6), (0.3, 0.77), (0.3, 0.85),
                            (0.03, 0.8), (0, 0.95)])],
        // vier Arme mit Rotorscheiben
        .drone: [bar(cx: 0, cy: 0, length: 1.5, width: 0.12, degrees: 45), bar(cx: 0, cy: 0, length: 1.5, width: 0.12, degrees: -45),
                 bar(cx: 0, cy: 0, length: 0.4, width: 0.4),
                 polygon(cx: 0.53, cy: -0.53, radius: 0.27, sides: 8), polygon(cx: -0.53, cy: -0.53, radius: 0.27, sides: 8),
                 polygon(cx: 0.53, cy: 0.53, radius: 0.27, sides: 8), polygon(cx: -0.53, cy: 0.53, radius: 0.27, sides: 8)],
        // Hülle, Gondel, zwei Leinen
        .balloon: [polygon(cx: 0, cy: -0.28, radius: 0.62, sides: 20), bar(cx: 0, cy: 0.62, length: 0.22, width: 0.22),
                   bar(cx: 0.12, cy: 0.38, length: 0.4, width: 0.04, degrees: 70), bar(cx: -0.12, cy: 0.38, length: 0.4, width: 0.04, degrees: -70)],
        // Deltaflügel
        .fighter: [mirrored([(0, -1), (0.04, -0.82), (0.07, -0.4), (0.88, 0.52), (0.88, 0.74), (0.13, 0.62), (0.1, 0.86), (0.26, 0.96), (0.0, 0.9)])],
        // kleines Rechteck mit abgeschrägter Front
        .groundVehicle: [mirrored([(0, -0.8), (0.3, -0.7), (0.38, -0.4), (0.38, 0.7), (0.3, 0.8), (0, 0.8)])],
    ]
}

// MARK: - Klassifizierung der Flugzeuge

public enum AircraftClass {
    /// ICAO-Typkürzel einzelner Hubschrauber (Doc 8643, Auswahl der häufigen Baumuster)
    static let helicopters: Set<String> = [
        "EC20", "EC25", "EC30", "EC35", "EC45", "EC55", "EC75", "EC120", "EC130", "EC135", "EC145", "EC155", "H135", "H145", "H160", "H175", "H225",
        "AS32", "AS35", "AS50", "AS55", "AS65", "AS3B", "SA34", "SA36", "SA31", "SA33", "B06", "B06T", "B105", "B212", "B214", "B222", "B230", "B407",
        "B412", "B427", "B429", "B430", "B47G", "B47J", "B505", "BK17", "BU20", "R22", "R44", "R66", "H500", "H269", "H369", "HU30", "A109", "A119",
        "A139", "A169", "A189", "AW09", "S61", "S64", "S65", "S70", "S76", "S92", "S300", "H60", "H47", "H53", "H64", "H1", "NH90", "MI8", "MI17",
        "MI24", "MI26", "KA32", "KA52", "LYNX", "PUMA", "EXPL", "MD52", "MD60", "MD90",
    ]
    /// Vierstrahlige und andere Großraumflugzeuge
    static let heavies: Set<String> = [
        "A388", "A380", "A342", "A343", "A345", "A346", "A3ST", "A306", "A30B", "A310", "A332", "A333", "A338", "A339", "A359", "A35K", "B741", "B742",
        "B743", "B744", "B748", "B74S", "BLCF", "B762", "B763", "B764", "B772", "B773", "B77L", "B77W", "B778", "B779", "B788", "B789", "B78X", "DC10",
        "MD11", "L101", "IL96", "IL86", "IL76", "C5M", "C17", "A400", "AN12", "AN22", "AN24", "A124", "A225", "B52", "K35R", "KC10", "E3CF", "E6", "VC10",
    ]
    static let bizjets: Set<String> = [
        "C25A", "C25B", "C25C", "C25M", "C500", "C501", "C510", "C525", "C526", "C550", "C551", "C560", "C56X", "C650", "C680", "C68A", "C700", "C750",
        "CL30", "CL35", "CL60", "GL5T", "GL6T", "GL7T", "GLF2", "GLF3", "GLF4", "GLF5", "GLF6", "GALX", "G150", "G200", "G280", "FA10", "FA20", "FA50",
        "FA5X", "FA6X", "FA7X", "FA8X", "F900", "F2TH", "E50P", "E55P", "LJ23", "LJ24", "LJ25", "LJ28", "LJ31", "LJ35", "LJ40", "LJ45", "LJ55", "LJ60",
        "LJ70", "LJ75", "H25A", "H25B", "H25C", "HDJT", "HA4T", "BE40", "PRM1", "SF50", "EA50", "ASTR", "WW24", "MU30", "PC24",
    ]
    static let lightProps: Set<String> = [
        "C150", "C152", "C162", "C170", "C172", "C175", "C177", "C180", "C182", "C185", "C188", "C195", "C206", "C207", "C208", "C210", "C337", "C402",
        "C414", "C421", "PA11", "PA12", "PA18", "PA20", "PA22", "PA24", "PA25", "PA27", "PA28", "PA30", "PA31", "PA32", "PA34", "PA38", "PA44", "PA46",
        "PA60", "P28A", "P28B", "P28R", "P32R", "P46T", "SR20", "SR22", "S22T", "DA20", "DA40", "DA42", "DA62", "DV20", "BE19", "BE23", "BE24", "BE33",
        "BE35", "BE36", "BE55", "BE58", "BE60", "BE76", "BE9L", "TB10", "TB20", "TB21", "TOBA", "AA5", "M20P", "M20T", "RV6", "RV7", "RV8", "RV9",
        "RV10", "G115", "G120", "AT3T", "AT5T", "AT8T", "C42", "AC11", "AC50", "SIRA", "EV97", "ULAC", "TRIN", "RALL", "COYT", "ROBN", "DR40", "CH7A",
        "CH7B", "PC6T", "PC9", "SW4", "DHC2", "DHC3", "DHC6", "BN2P", "BN2T", "TBM7", "TBM8", "TBM9", "PC12", "B190", "BE20",
    ]
    static let fighters: Set<String> = [
        "F16", "F15", "F18", "FA18", "F22", "F35", "F5", "F4", "F14", "F111", "EUFI", "TORN", "RFAL", "GRIP", "M346", "T38", "MIG2", "MG29", "MG31",
        "SU27", "SU30", "SU34", "SU35", "SU57", "A10", "A4", "AMX", "HAWK", "L39", "L159", "EF2K", "TYPH", "J39", "MIR2", "M2K", "JAGR", "TUCA", "T6",
    ]

    /// Welcher Umriss zu einem Flugzeug passt: erst das Typkürzel (genau), dann die Kategorie aus der Kennungsmeldung, zuletzt Geschwindigkeit und Höhe
    public static func classify(category: Int?, typeCode: Int?, icaoType: String?, groundSpeedKn: Double? = nil, altitudeFt: Int? = nil, onGround: Bool? = nil) -> MapSilhouette {
        if let t = icaoType?.uppercased(), !t.isEmpty {
            if helicopters.contains(t) { return .helicopter }
            if heavies.contains(t) { return .heavy }
            if bizjets.contains(t) { return .bizjet }
            if lightProps.contains(t) { return .lightProp }
            if fighters.contains(t) { return .fighter }
            if t == "GLID" || t == "ULAC" { return .glider }
        }
        if let tc = typeCode, let c = category, c != 0 {
            switch (tc, c) {
            case (4, 1): return .lightProp
            case (4, 2): return .bizjet
            case (4, 3), (4, 4): return .airliner
            case (4, 5): return .heavy
            case (4, 6): return .fighter
            case (4, 7): return .helicopter
            case (3, 1), (3, 4): return .glider
            case (3, 2): return .balloon
            case (3, 3): return .glider
            case (3, 6): return .drone
            case (2, 1), (2, 2), (2, 3), (2, 4), (2, 5): return .groundVehicle
            default: break
            }
        }
        if onGround == true, let v = groundSpeedKn, v < 3, icaoType == nil, typeCode == 2 { return .groundVehicle }
        // ohne Angabe: schnell oder hoch → Verkehrsflugzeug, langsam und niedrig → Kleinflugzeug
        if let v = groundSpeedKn, let a = altitudeFt {
            if v < 130 && a < 8_000 { return .lightProp }
        } else if let v = groundSpeedKn, v < 90 {
            return .lightProp
        }
        return .airliner
    }
}
