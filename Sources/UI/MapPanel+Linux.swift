// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Linux: Platzhalter der Karte, bis die OpenStreetMap-Karte steht (siehe OSMMap).
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

struct MapPanel: View {
    let content: MapContent
    @ObservedObject var home: HomeLocation
    @Binding var selection: String?
    var legend: String? = nil
    var accessory: AnyView? = nil
    var detailAction: MapDetailAction? = nil
    var snapshotName: String = "Karte"
    var keepZoomOnSelect = false

    init(content: MapContent, home: HomeLocation, selection: Binding<String?> = .constant(nil), legend: String? = nil, accessory: AnyView? = nil,
         detailAction: MapDetailAction? = nil, snapshotName: String = "Karte", keepZoomOnSelect: Bool = false) {
        self.content = content; self.home = home; self._selection = selection; self.legend = legend; self.accessory = accessory
        self.detailAction = detailAction; self.snapshotName = snapshotName; self.keepZoomOnSelect = keepZoomOnSelect
    }

    var body: some View {
        Text("Karte")
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(RadioTheme.textDim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RadioTheme.bgDeep)
    }
}

enum MapAppearance: String, CaseIterable, Identifiable {
    case standard, hybrid, imagery
    var id: String { rawValue }
    var title: String { self == .standard ? "KARTE" : (self == .hybrid ? "HYBRID" : "SAT") }
}
#endif
