// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation

// Farbthemes der Oberfläche als reine Daten (ohne SwiftUI, damit sie sich prüfen lassen: Kontrast aller Textfarben auf allen Hintergründen).
// Die Namen der Farben bleiben die des ursprünglichen Themes (`vfdGreen` = Haupttext/Normalzustand, `vfdCyan` = Hervorhebung/aktiv,
// `vfdAmber` = Messwerte und Frequenzen, `ledRed` = Alarm), auch wenn ein Theme sie anders einfärbt.

public struct RGB: Equatable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    /// Relative Leuchtdichte nach WCAG 2.x
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// Kontrastverhältnis zweier Farben (1 … 21)
    public func contrast(with other: RGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public func scaled(_ f: Double) -> RGB { RGB(min(1, r * f), min(1, g * f), min(1, b * f)) }
}

public struct ThemePalette: Equatable, Sendable {
    public var bgDeep, bgPanel, bgCard, borderSubtle, borderActive: RGB
    public var vfdAmber, vfdCyan, vfdGreen, ledRed, ledYellow: RGB
    public var textBright, textMuted, textDim: RGB
    /// Tastenkörper: Verlauf oben/unten im Ruhezustand und bei aktiver Taste (gedrückte Zustände werden daraus abgeleitet)
    public var keyTop, keyBottom, keySelectedTop, keySelectedBottom: RGB
    /// Wasserfall: Stützstellen (Lage 0 … 1, Farbe) des Verlaufs vom Hintergrund bis zum stärksten Signal
    public var waterfall: [(Double, RGB)]

    public static func == (a: ThemePalette, b: ThemePalette) -> Bool {
        a.bgDeep == b.bgDeep && a.vfdGreen == b.vfdGreen && a.keyTop == b.keyTop && a.waterfall.count == b.waterfall.count
    }

    /// Alle Vordergrundfarben, die auf Hintergründen stehen (für die Kontrastprüfung): Name, Farbe, Mindestkontrast
    public var foregrounds: [(String, RGB, Double)] {
        [("textBright", textBright, 10), ("textMuted", textMuted, 5), ("textDim", textDim, 2.6),
         ("vfdGreen", vfdGreen, 6), ("vfdCyan", vfdCyan, 6), ("vfdAmber", vfdAmber, 6), ("ledRed", ledRed, 4), ("ledYellow", ledYellow, 7)]
    }

    public var backgrounds: [(String, RGB)] { [("bgDeep", bgDeep), ("bgPanel", bgPanel), ("bgCard", bgCard)] }

    // gedrückte und aktive Tasten
    public var keyPressedTop: RGB { keyBottom.scaled(0.69) }
    public var keyPressedBottom: RGB { keyBottom.scaled(1.23) }
    public var keySelectedPressedTop: RGB { keySelectedBottom.scaled(0.8) }
    public var keySelectedPressedBottom: RGB { keySelectedTop.scaled(0.71) }
}

public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case night, amber, redNight, marine
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .night: return "Nacht"
        case .amber: return "Bernstein"
        case .redNight: return "Rotnacht"
        case .marine: return "Marine"
        }
    }

    public var detail: String {
        switch self {
        case .night: return "Das gewohnte Design: grünes und cyanfarbenes VFD-Leuchten auf Blauschwarz"
        case .amber: return "Einfarbig bernsteinfarben wie ein alter Datensichtschirm"
        case .redNight: return "Nur rote Töne: schont die Dunkeladaption in abgedunkelten Räumen"
        case .marine: return "Blauschwarz mit hellblauer Schrift und goldenen Messwerten"
        }
    }

    public var palette: ThemePalette {
        switch self {
        case .night:
            return ThemePalette(
                bgDeep: RGB(0.07, 0.08, 0.10), bgPanel: RGB(0.10, 0.11, 0.14), bgCard: RGB(0.13, 0.15, 0.19),
                borderSubtle: RGB(0.20, 0.24, 0.30), borderActive: RGB(0.00, 0.85, 1.00),
                vfdAmber: RGB(1.00, 0.72, 0.10), vfdCyan: RGB(0.00, 0.90, 1.00), vfdGreen: RGB(0.00, 0.95, 0.45),
                ledRed: RGB(1.00, 0.20, 0.30), ledYellow: RGB(1.00, 0.80, 0.00),
                textBright: RGB(0.95, 0.97, 1.00), textMuted: RGB(0.60, 0.65, 0.75), textDim: RGB(0.40, 0.45, 0.52),
                keyTop: RGB(0.255, 0.285, 0.345), keyBottom: RGB(0.130, 0.150, 0.190),
                keySelectedTop: RGB(0.060, 0.420, 0.490), keySelectedBottom: RGB(0.020, 0.200, 0.250),
                waterfall: [(0.00, RGB(0.07, 0.08, 0.10)), (0.20, RGB(0.05, 0.18, 0.40)), (0.40, RGB(0.00, 0.60, 0.85)), (0.55, RGB(0.00, 0.90, 1.00)),
                            (0.70, RGB(0.00, 0.95, 0.45)), (0.82, RGB(1.00, 0.72, 0.10)), (0.93, RGB(1.00, 0.20, 0.30)), (1.00, RGB(1.00, 0.95, 0.95))])
        case .amber:
            return ThemePalette(
                bgDeep: RGB(0.075, 0.055, 0.035), bgPanel: RGB(0.105, 0.078, 0.050), bgCard: RGB(0.140, 0.105, 0.068),
                borderSubtle: RGB(0.27, 0.20, 0.12), borderActive: RGB(1.00, 0.78, 0.25),
                vfdAmber: RGB(1.00, 0.84, 0.38), vfdCyan: RGB(1.00, 0.93, 0.65), vfdGreen: RGB(1.00, 0.69, 0.10),
                ledRed: RGB(1.00, 0.30, 0.20), ledYellow: RGB(1.00, 0.88, 0.25),
                textBright: RGB(1.00, 0.95, 0.85), textMuted: RGB(0.78, 0.64, 0.45), textDim: RGB(0.55, 0.44, 0.29),
                keyTop: RGB(0.360, 0.280, 0.180), keyBottom: RGB(0.170, 0.130, 0.085),
                keySelectedTop: RGB(0.520, 0.330, 0.040), keySelectedBottom: RGB(0.280, 0.160, 0.010),
                waterfall: [(0.00, RGB(0.075, 0.055, 0.035)), (0.20, RGB(0.25, 0.10, 0.00)), (0.40, RGB(0.60, 0.30, 0.00)), (0.60, RGB(1.00, 0.65, 0.00)),
                            (0.80, RGB(1.00, 0.85, 0.35)), (1.00, RGB(1.00, 0.97, 0.80))])
        case .redNight:
            return ThemePalette(
                bgDeep: RGB(0.045, 0.012, 0.012), bgPanel: RGB(0.075, 0.020, 0.020), bgCard: RGB(0.105, 0.030, 0.030),
                borderSubtle: RGB(0.25, 0.08, 0.08), borderActive: RGB(1.00, 0.25, 0.20),
                vfdAmber: RGB(1.00, 0.45, 0.20), vfdCyan: RGB(1.00, 0.66, 0.50), vfdGreen: RGB(1.00, 0.36, 0.28),
                ledRed: RGB(1.00, 0.12, 0.35), ledYellow: RGB(1.00, 0.58, 0.12),
                textBright: RGB(1.00, 0.80, 0.75), textMuted: RGB(0.80, 0.46, 0.43), textDim: RGB(0.52, 0.27, 0.25),
                keyTop: RGB(0.300, 0.120, 0.110), keyBottom: RGB(0.140, 0.050, 0.050),
                keySelectedTop: RGB(0.550, 0.100, 0.080), keySelectedBottom: RGB(0.280, 0.040, 0.040),
                waterfall: [(0.00, RGB(0.045, 0.012, 0.012)), (0.20, RGB(0.25, 0.02, 0.03)), (0.40, RGB(0.60, 0.05, 0.05)), (0.60, RGB(1.00, 0.20, 0.10)),
                            (0.80, RGB(1.00, 0.55, 0.25)), (1.00, RGB(1.00, 0.90, 0.80))])
        case .marine:
            return ThemePalette(
                bgDeep: RGB(0.040, 0.075, 0.120), bgPanel: RGB(0.060, 0.100, 0.160), bgCard: RGB(0.090, 0.140, 0.220),
                borderSubtle: RGB(0.17, 0.27, 0.40), borderActive: RGB(0.30, 0.75, 1.00),
                vfdAmber: RGB(1.00, 0.78, 0.30), vfdCyan: RGB(0.40, 0.80, 1.00), vfdGreen: RGB(0.60, 0.88, 1.00),
                ledRed: RGB(1.00, 0.35, 0.40), ledYellow: RGB(1.00, 0.85, 0.20),
                textBright: RGB(0.93, 0.97, 1.00), textMuted: RGB(0.58, 0.68, 0.80), textDim: RGB(0.40, 0.50, 0.62),
                keyTop: RGB(0.240, 0.310, 0.420), keyBottom: RGB(0.110, 0.160, 0.240),
                keySelectedTop: RGB(0.100, 0.380, 0.620), keySelectedBottom: RGB(0.040, 0.180, 0.340),
                waterfall: [(0.00, RGB(0.040, 0.075, 0.120)), (0.20, RGB(0.04, 0.15, 0.40)), (0.40, RGB(0.00, 0.45, 0.85)), (0.60, RGB(0.20, 0.80, 1.00)),
                            (0.80, RGB(0.80, 0.95, 1.00)), (0.92, RGB(1.00, 0.78, 0.30)), (1.00, RGB(1.00, 0.97, 0.90))])
        }
    }
}
