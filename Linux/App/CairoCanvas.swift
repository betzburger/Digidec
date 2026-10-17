// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import SwiftCrossUI
import GtkBackend
import Gtk
import CGtkCairo

/// Schwacher Verweis auf das Widget für den Zeitgeber (nur auf dem Hauptfaden benutzt)
final class WeakWidget: @unchecked Sendable {
    weak var widget: DrawingArea?
    init(widget: DrawingArea) { self.widget = widget }
}

/// Zeichenfläche mit Cairo, das Gegenstück zu `Canvas` in SwiftUI: `draw` bekommt den Cairo-Kontext und die Größe in Punkten
/// und wird mit der gewählten Bildrate neu aufgerufen.
struct CairoCanvas: @MainActor GtkWidgetRepresentable {
    typealias GtkWidgetType = DrawingArea

    var framesPerSecond: Double = 30
    var minimumSize: (width: Int, height: Int) = (80, 60)
    var draw: @MainActor (_ cr: OpaquePointer, _ width: Double, _ height: Double) -> Void

    @MainActor
    final class Coordinator {
        var timer: Timer?
    }

    @MainActor
    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    func makeGtkWidget(context: Context) -> DrawingArea {
        let area = DrawingArea()
        area.setSizeRequest(width: minimumSize.width, height: minimumSize.height)
        area.expandHorizontally = true
        area.useExpandHorizontally = true
        area.expandVertically = true
        area.useExpandVertically = true
        let draw = self.draw
        area.setDrawFunc { cr, width, height in
            MainActor.assumeIsolated { draw(cr, Double(width), Double(height)) }
        }
        let weakArea = WeakWidget(widget: area)
        context.coordinator.timer = Timer.scheduledTimer(withTimeInterval: 1 / framesPerSecond, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let area = weakArea.widget { digidec_queue_draw(UnsafeMutableRawPointer(area.widgetPointer)) }
            }
        }
        return area
    }

    @MainActor
    func updateGtkWidget(_ gtkWidget: DrawingArea, context: Context) {
        digidec_queue_draw(UnsafeMutableRawPointer(gtkWidget.widgetPointer))
    }

    static func dismantleGtkWidget(_ gtkWidget: DrawingArea, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.timer?.invalidate() }
    }
}
