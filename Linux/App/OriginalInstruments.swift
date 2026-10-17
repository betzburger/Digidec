// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import SwiftUI           // unter Linux der Nachbau des Zeichenteils (Linux/Shims/SwiftUI), kein echtes SwiftUI
import CGtkCairo
@testable import DigidecCore

/// Das S-Meter mit dem Zeichencode des Originals (`SMeterPainter`), unverändert, auf Cairo.
@MainActor
func drawOriginalSMeter(_ cr: OpaquePointer, _ width: Double, _ height: Double, db: Double, lit: Bool, ballistics: NeedleBallistics, canvas: CGSize? = nil) {
    // wie `.aspectRatio(1.75, contentMode: .fit)` am Mac
    let w = min(width, height * 1.75), h = w / 1.75
    cairo_save(cr)
    cairo_translate(cr, (width - w) / 2, (height - h) / 2)
    // Die Zeichenfläche des Kontexts ist das ganze Widget: Zwischenebenen (Weichzeichner, Beschnitt) brauchen den vollen Bereich
    var ctx = GraphicsContext(cairo: cr, size: canvas ?? CGSize(width: width, height: height))
    let needle = ballistics.step(target: SDRSMeterScale.fraction(db: db), now: Date())
    SMeterPainter(size: CGSize(width: w, height: h), needle: needle, lit: lit).draw(&ctx)
    cairo_restore(cr)
}
