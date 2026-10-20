// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Menü des Hauptfensters unter Linux (Gegenstück zur Menüleiste am Mac): Über Digidec, Sprache, Beenden.
import Foundation
import Glibc
import SwiftUI
@testable import DigidecCore

@MainActor
enum AppMenu {
    /// Nach dem Beenden neu starten (Sprachwechsel)
    private(set) static var restartRequested = false

    private static var appLanguage: String { UserDefaults.standard.string(forKey: "AppLanguage") ?? "system" }

    /// Aktionen der Anwendung; Tastenkürzel wie am Mac mit Strg statt Befehlstaste
    static func registerActions(manager: WindowManager) {
        LinuxApplication.addAction("about") { _ in
            manager.open(id: "main")
            DigidecState.shared.showAbout = true
        }
        LinuxApplication.addAction("quit", accelerator: "<Control>q") { _ in LinuxApplication.quit() }
        LinuxApplication.addAction("language", state: appLanguage) { value in
            guard let value, value != appLanguage else { return }
            UserDefaults.standard.set(value, forKey: "AppLanguage")
            askForRestart(language: value, manager: manager)
        }
    }

    static func install(on window: UnsafeMutableRawPointer, manager: WindowManager) {
        let menu = LinuxMenu()
        menu.section { $0.item(String(localized: "Über Digidec"), action: "app.about") }
        menu.section { section in
            section.submenu("Sprache / Language") { languages in
                languages.item("System", action: "app.language::system")
                languages.item("Deutsch", action: "app.language::de")
                languages.item("English", action: "app.language::en")
            }
        }
        menu.section { $0.item(String(localized: "Digidec beenden"), action: "app.quit") }
        menu.install(on: window, tooltip: String(localized: "Menü"))
    }

    /// Die Texte werden beim Start geladen: ein Sprachwechsel wirkt nach einem Neustart
    private static func askForRestart(language: String, manager: WindowManager) {
        guard let window = manager.window("main") else { return }
        let english = language == "en" || (language == "system" && LinuxStrings.environmentLanguage == "en")
        LinuxApplication.confirm(
            window: window,
            message: english ? "Language Changed" : "Sprache geändert",
            detail: english ? "Digidec shows the new language after a restart. Restart now?"
                            : "Digidec zeigt die neue Sprache nach einem Neustart. Jetzt neu starten?",
            confirm: english ? "Restart Now" : "Jetzt neu starten",
            cancel: english ? "Later" : "Später"
        ) { restart in
            guard restart else { return }
            restartRequested = true
            LinuxApplication.quit()
        }
    }

    /// Ersetzt den Prozess durch einen frischen Start desselben Programms (nach `cleanup()`); Aufträge (URLs) werden nicht wiederholt
    static func relaunch() {
        let arguments = [CommandLine.arguments.first ?? "digidec"] + CommandLine.arguments.dropFirst().filter { !$0.contains("://") }
        var cArguments = arguments.map { strdup($0) } + [nil]
        execv("/proc/self/exe", &cArguments)
        // Nur bei Fehlschlag erreicht
        FileHandle.standardError.write(Data("Neustart fehlgeschlagen: \(String(cString: strerror(errno)))\n".utf8))
    }
}
