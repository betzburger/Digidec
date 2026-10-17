// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import SwiftCrossUI
import GtkBackend
@testable import DigidecCore

/// Entwurf des Linux-Frontends: GTK 4 über SwiftCrossUI, Instrumente mit Cairo. Zeigt Audio-Eingang, S-Meter, Abstimmanzeige und Wasserfall.
@main
struct DigidecLinuxApp: App {
    typealias Backend = GtkBackend

    @State var model = LiveModel()

    private func color(_ c: RGB) -> Color { Color(red: c.r, green: c.g, blue: c.b) }

    var body: some Scene {
        WindowGroup("Digidec \(AppVersion.short)") {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    CairoCanvas(minimumSize: (260, 150)) { cr, w, h in
                        drawSMeter(cr, w, h, db: model.levelDB, theme: model.theme)
                    }
                    CairoCanvas(minimumSize: (260, 150)) { cr, w, h in
                        drawVFD(cr, w, h, lines: [
                            ("Pegel", String(format: "%.1f dBFS", model.levelDB)),
                            ("Linie", model.peakHz > 0 ? String(format: "%.0f Hz", model.peakHz) : "—"),
                        ], theme: model.theme)
                    }
                }
                .frame(height: 160)
                CairoCanvas(minimumSize: (400, 200)) { cr, w, h in
                    drawWaterfall(cr, w, h, image: model.waterfall.image, binWidth: model.waterfall.binWidth,
                                  spectrum: model.waterfall.spectrum, peakHz: model.peakHz, theme: model.theme)
                }
                HStack(spacing: 10) {
                    Text("Eingang").foregroundColor(color(model.theme.textBright))
                    Picker(of: model.devices.map(\.name), selection: Binding(get: { model.selectedName }, set: { model.select(name: $0) }))
                    Spacer()
                    Text(model.statusText).foregroundColor(color(model.theme.textMuted))
                }
            }
            .padding(12)
            .background(color(model.theme.bgDeep))
        }
        .defaultSize(width: 920, height: 720)
    }
}
