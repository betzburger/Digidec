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
            VStack(spacing: 8) {
                CairoCanvas(minimumSize: (400, 56)) { cr, w, h in drawHeaderCanvas(cr, w, h, model: model) }
                .frame(height: 56)
                CairoCanvas(minimumSize: (400, 90),
                            draw: { cr, w, h in drawModuleBarCanvas(cr, w, h, model: model) },
                            onPress: { x, y in model.pressedModule = model.module(at: x, y) },
                            onRelease: { x, y in
                                if let m = model.module(at: x, y), m == model.pressedModule { model.selectedModule = m }
                                model.pressedModule = nil
                            },
                            onHover: { point in model.hoverModule = point.flatMap { model.module(at: $0.0, $0.1) } })
                    .frame(height: 100)
                HStack(spacing: 12) {
                    CairoCanvas(minimumSize: (300, 190)) { cr, w, h in
                        drawTuningCard(cr, w, h, db: model.levelDB, ballistics: model.ballistics, palette: model.theme)
                    }
                    CairoCanvas(minimumSize: (260, 190)) { cr, w, h in
                        drawVFD(cr, w, h, lines: [
                            ("Modul", model.selectedModule.displayName),
                            ("Pegel", String(format: "%.1f dBFS", model.levelDB)),
                            ("Linie", model.peakHz > 0 ? String(format: "%.0f Hz", model.peakHz) : "—"),
                        ], theme: model.theme)
                    }
                }
                .frame(height: 190)
                CairoCanvas(minimumSize: (400, 200)) { cr, w, h in
                    drawWaterfallCard(cr, w, h, image: model.waterfall.image, binWidth: model.waterfall.binWidth,
                                      spectrum: model.waterfall.spectrum, peakHz: model.peakHz, palette: model.theme)
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
        .defaultSize(width: 1000, height: 820)
    }
}
