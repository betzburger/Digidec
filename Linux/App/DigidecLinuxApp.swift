// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import SwiftCrossUI
import GtkBackend
@testable import DigidecCore

/// Linux-Frontend: GTK 4 über SwiftCrossUI, Instrumente und Tasten mit Cairo im Stil der Mac-Oberfläche.
@main
struct DigidecLinuxApp: App {
    typealias Backend = GtkBackend

    @State var model = AppModel()

    var body: some Scene {
        WindowGroup("Digidec \(AppVersion.short)") {
            MainView(model: model)
                .task { model.startIfNeeded() }
        }
        .defaultSize(width: 1280, height: 860)
    }
}
