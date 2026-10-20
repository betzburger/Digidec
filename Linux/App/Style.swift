// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import SwiftUI
@testable import DigidecCore

/// Stil der echten GTK-Elemente, die über die Zeichenfläche gelegt werden (Eingabefelder), im Look des Themes
@MainActor
enum GtkStyle {
    static func install() {
        let p = ThemeModel.shared.palette
        func rgba(_ c: RGB, _ a: Double = 1) -> String { "rgba(\(Int(c.r * 255)), \(Int(c.g * 255)), \(Int(c.b * 255)), \(a))" }
        let css = """
        window { background-color: \(rgba(p.bgDeep)); color: \(rgba(p.textBright)); }
        entry.digidec-entry { background-color: \(rgba(p.bgDeep)); color: \(rgba(p.vfdCyan)); caret-color: \(rgba(p.vfdAmber));
            min-height: 20px; padding: 0 6px; border-radius: 5px; border: 1px solid \(rgba(p.borderSubtle));
            box-shadow: inset 0 1px 2px rgba(0,0,0,0.6); }
        entry.digidec-entry:focus-within { border-color: \(rgba(p.vfdCyan, 0.8)); }
        entry.digidec-entry-plain { background: transparent; color: \(rgba(p.vfdCyan)); caret-color: \(rgba(p.vfdAmber)); border: none; box-shadow: none; min-height: 18px; padding: 0 2px; }
        entry selection, textview selection { background-color: \(rgba(p.vfdAmber, 0.45)); color: \(rgba(p.textBright)); }
        textview.digidec-editor, textview.digidec-editor text { background-color: \(rgba(p.bgDeep)); color: \(rgba(p.vfdGreen)); }
        scrolledwindow { border: 1px solid \(rgba(p.borderSubtle)); border-radius: 5px; }
        headerbar.digidec-headerbar { background: \(rgba(p.bgDeep)); color: \(rgba(p.textBright)); box-shadow: inset 0 -1px \(rgba(p.borderSubtle));
            min-height: 30px; padding: 0 4px; }
        headerbar.digidec-headerbar:backdrop { color: \(rgba(p.textBright, 0.6)); }
        headerbar.digidec-headerbar button { color: \(rgba(p.vfdAmber)); background: transparent; border: none; box-shadow: none; }
        headerbar.digidec-headerbar button:hover { background: \(rgba(p.vfdAmber, 0.12)); }
        """
        LinuxApplication.installStyle(css)
    }
}
