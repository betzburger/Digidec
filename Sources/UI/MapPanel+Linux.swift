// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Linux: gemeinsame Typen der Karte (die Ansicht selbst steht in OSMMap.swift).
#if !canImport(MapKit)
import SwiftUI

extension MapTone {
    var color: Color {
        switch self {
        case .normal:    return RadioTheme.vfdGreen
        case .info:      return RadioTheme.vfdCyan
        case .highlight: return RadioTheme.vfdAmber
        case .alert:     return RadioTheme.ledRed
        case .dim:       return RadioTheme.textDim
        case .weather:   return Color(red: 0.45, green: 0.72, blue: 1.0)
        }
    }
}

struct MapDetailAction {
    var title: String
    var help: String
    var systemImage: String
    var applies: (MapMarker) -> Bool
    var perform: (MapMarker) -> Void
}

enum MapAppearance: String, CaseIterable, Identifiable {
    case standard, hybrid, imagery
    var id: String { rawValue }
    var title: String { self == .standard ? "KARTE" : (self == .hybrid ? "HYBRID" : "SAT") }
}
#endif
