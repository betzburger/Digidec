// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Programmstart unter Linux: öffnet das Hauptfenster mit der Oberfläche des Originals (MainWindowView) auf GTK 4.
import Foundation
import Glibc
import CDigidecGtk
import SwiftUI
@testable import DigidecCore

signal(SIGPIPE, SIG_IGN)

// Entwicklungshilfe: `kill -USR1 <pid>` schreibt den Aufrufstapel des Hauptfadens nach stderr (für hängende Oberflächen)
signal(SIGUSR1) { _ in dg_dump_stack() }

MainActor.assumeIsolated {
    LocalVoiceHook.install()
    localizationHook = { LinuxStrings.translate($0) }
    openURLHook = { PlatformOpener.open($0) }

    // Den Programmzustand (Audio, Decoder, Web-Server) erst in der Hauptinstanz anlegen: Ein zweiter Aufruf reicht nur
    // seine URLs an die laufende Instanz weiter und endet sofort
    var state: DigidecState { DigidecState.shared }
    let manager = WindowManager()
    manager.background = Color(red: ThemeModel.shared.palette.bgDeep.r, green: ThemeModel.shared.palette.bgDeep.g, blue: ThemeModel.shared.palette.bgDeep.b)

    manager.register(id: "main", title: "Digidec", size: CGSize(width: 1280, height: 860)) {
        MainWindowView(state: state).onAppear { state.startAudio() }
    }
    manager.register(id: "ship-info", title: String(localized: "Schiffsdaten"), size: CGSize(width: 560, height: 780)) {
        ShipInfoWindow(controller: state.aisController, settings: state.ais, home: state.home)
    }
    manager.register(id: "aircraft-info", title: String(localized: "Flugzeugdaten"), size: CGSize(width: 560, height: 820)) {
        AircraftInfoWindow(controller: state.adsbController, settings: state.adsb, home: state.home)
    }
    manager.register(id: "assistant", title: String(localized: "KI-Assistent"), size: CGSize(width: 560, height: 760)) {
        AssistantWindow(model: state.assistant)
    }
    manager.onWindowCreated = { id, window in
        if id == "main" { AppMenu.install(on: window, manager: manager) }
    }

    let status = LinuxApplication.run(id: ProcessInfo.processInfo.environment["DIGIDEC_START_WINDOW"] ?? "main", manager: manager,
                                      onStart: { GtkStyle.install(); AppMenu.registerActions(manager: manager) },
                                      onOpen: { url in state.handle(url: url) })
    // Wie `applicationWillTerminate` am Mac: Aufnahmen abschließen, Geräte schließen, Web-Server beenden
    if LinuxApplication.started { state.cleanup() }
    if AppMenu.restartRequested { AppMenu.relaunch() }
    LinuxApplication.terminate(status)
}
