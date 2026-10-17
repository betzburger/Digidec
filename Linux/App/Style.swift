// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import CGtkCairo
@testable import DigidecCore

/// Stil der Standard-GTK-Bedienelemente (Textfelder, Regler, Auswahl) im Look des Themes. Wird einmal beim Start geladen.
@MainActor
enum GtkStyle {
    private static var provider: OpaquePointer?

    static func install(palette p: ThemePalette) {
        func hex(_ c: RGB, _ a: Double = 1) -> String {
            "rgba(\(Int(c.r * 255)), \(Int(c.g * 255)), \(Int(c.b * 255)), \(a))"
        }
        let css = """
        window, .background { background-color: \(hex(p.bgDeep)); color: \(hex(p.textBright)); }
        entry, text { background-color: \(hex(p.bgDeep)); color: \(hex(p.vfdCyan)); caret-color: \(hex(p.vfdAmber));
            font-family: "Noto Sans Mono", monospace; font-size: 11px; min-height: 22px; border-radius: 5px; border: 1px solid \(hex(p.borderSubtle));
            box-shadow: inset 0 1px 2px rgba(0,0,0,0.6); padding: 0 6px; }
        entry:focus-within { border-color: \(hex(p.vfdCyan, 0.8)); }
        entry selection, text selection { background-color: \(hex(p.vfdAmber, 0.45)); color: \(hex(p.textBright)); }
        scale trough { background-color: \(hex(p.bgDeep)); min-height: 4px; border-radius: 2px; border: 1px solid \(hex(p.borderSubtle)); }
        scale highlight { background-color: \(hex(p.vfdCyan, 0.8)); border-radius: 2px; }
        scale slider { background-image: linear-gradient(to bottom, \(hex(p.keyTop)), \(hex(p.keyBottom))); border: 1px solid rgba(0,0,0,0.75);
            border-radius: 6px; min-width: 14px; min-height: 14px; box-shadow: 0 1px 2px rgba(0,0,0,0.6); }
        button { background-image: linear-gradient(to bottom, \(hex(p.keyTop)), \(hex(p.keyBottom))); color: \(hex(p.textMuted));
            border: 1px solid rgba(0,0,0,0.75); border-radius: 5px; font-family: "Noto Sans Mono", monospace; font-size: 11px; }
        popover, popover contents { background-color: \(hex(p.bgPanel)); color: \(hex(p.textBright)); }
        label { color: \(hex(p.textBright)); }
        """
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, css)
        if let display = gdk_display_get_default() {
            gtk_style_context_add_provider_for_display(display, OpaquePointer(provider), UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
        }
        self.provider = OpaquePointer(provider)
    }
}
