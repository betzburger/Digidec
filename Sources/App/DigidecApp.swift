// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    /// Aufträge der Hauptprogramme (`digidec://decode?...`). macOS startet Digidec bei Bedarf
    /// und liefert die URL hier ab, ohne ein zusätzliches Fenster zu öffnen.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            DigidecState.shared.handle(url: url)
        }
        bringMainWindowToFront()
    }

    /// Seit macOS 14 ist die Aktivierung kooperativ: `activate(ignoringOtherApps:)` wird ignoriert,
    /// wenn Digidec bereits läuft. Deshalb das Fenster ausdrücklich nach vorne holen.
    private func bringMainWindowToFront() {
        NSApplication.shared.unhide(nil)
        NSApplication.shared.activate()
        for window in NSApplication.shared.windows where window.canBecomeMain {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DigidecState.shared.cleanup()
    }
}

@main
struct DigidecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var state = DigidecState.shared

    @AppStorage("AppLanguage") private var appLanguage: String = "system"

    private var activeLocale: Locale {
        switch appLanguage {
        case "de":
            return Locale(identifier: "de_DE")
        case "en":
            return Locale(identifier: "en_US")
        default:
            return Locale.autoupdatingCurrent
        }
    }

    init() {
        // Ignore SIGPIPE so a vanished rigctld socket never terminates the process
        signal(SIGPIPE, SIG_IGN)
        NSApplication.shared.setActivationPolicy(.regular)
        SnapshotHelper.installIfRequested()
        LocalVoiceHook.install()

        // Sync AppleLanguages to AppLanguage if set
        if let langs = UserDefaults.standard.stringArray(forKey: "AppleLanguages"), let first = langs.first {
            if first.hasPrefix("en") && UserDefaults.standard.string(forKey: "AppLanguage") == nil {
                UserDefaults.standard.set("en", forKey: "AppLanguage")
            } else if first.hasPrefix("de") && UserDefaults.standard.string(forKey: "AppLanguage") == nil {
                UserDefaults.standard.set("de", forKey: "AppLanguage")
            }
        }
    }

    var body: some Scene {
        // Einzelnes Fenster: ein zweiter Auftrag darf kein weiteres Fenster öffnen
        Window("Digidec", id: "main") {
            MainWindowView(state: state)
                .preferredColorScheme(.dark)
                .environment(\.locale, activeLocale)
                .id(appLanguage)
                .onAppear { state.startAudio() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 860)
        .windowResizability(.contentMinSize)
        // Schiffsdaten aus dem Netz (Foto, Baujahr, technische Daten) zum Schiff, das in der AIS-Karte oder -Liste gewählt wurde
        Window("Schiffsdaten", id: "ship-info") {
            ShipInfoWindow(controller: state.aisController, settings: state.ais, home: state.home)
                .environment(\.locale, activeLocale)
        }
        .defaultSize(width: 560, height: 780)
        .windowResizability(.contentMinSize)
        // Flugzeugdaten aus dem Netz (Foto, Typ, Betreiber, Strecke) zum Flugzeug, das in der ADS-B-Liste oder -Karte gewählt wurde
        Window("Flugzeugdaten", id: "aircraft-info") {
            AircraftInfoWindow(controller: state.adsbController, settings: state.adsb, home: state.home)
                .environment(\.locale, activeLocale)
        }
        .defaultSize(width: 560, height: 820)
        .windowResizability(.contentMinSize)
        // Rufzeichen bei QRZ.com nachschlagen: die Seite wird erst auf Knopfdruck von qrz.com geladen
        Window("QRZ.com", id: "qrz") {
            QRZWindow(lookup: QRZLookup.shared)
                .environment(\.locale, activeLocale)
        }
        .defaultSize(width: 980, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            QRZCommands()
            CommandGroup(replacing: .appInfo) {
                Button("Über Digidec") { state.showAbout = true }
            }
            CommandMenu("Sprache / Language") {
                Button {
                    setLanguage("system")
                } label: {
                    Text(appLanguage == "system" ? "✓ System (Automatisch)" : "   System (Automatisch)")
                }
                Button {
                    setLanguage("de")
                } label: {
                    Text(appLanguage == "de" ? "✓ Deutsch" : "   Deutsch")
                }
                Button {
                    setLanguage("en")
                } label: {
                    Text(appLanguage == "en" ? "✓ English" : "   English")
                }
            }
            CommandGroup(replacing: .appTermination) {
                Button("Digidec beenden") {
                    state.cleanup()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }

    private func setLanguage(_ lang: String) {
        appLanguage = lang
        if lang == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()

        let isEn = (lang == "en" || (lang == "system" && (Locale.current.language.languageCode?.identifier == "en" || Locale.preferredLanguages.first?.hasPrefix("en") == true)))
        let alert = NSAlert()
        alert.messageText = isEn ? "Language Changed" : "Sprache geändert"
        alert.informativeText = isEn
            ? "The interface language has been changed. A restart is recommended to update menus and window titles. Would you like to restart now?"
            : "Die Sprache der Benutzeroberfläche wurde umgestellt. Ein Neustart wird empfohlen, um auch Menüs und Fenstertitel vollständig anzupassen. Jetzt neu starten?"
        alert.addButton(withTitle: isEn ? "Restart Now" : "Jetzt neu starten")
        alert.addButton(withTitle: isEn ? "Later" : "Später")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            relaunchApp()
        }
    }

    private func relaunchApp() {
        state.cleanup()
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

/// Entwicklungshilfe: DIGIDEC_SNAPSHOT=/Pfad/bild.png [DIGIDEC_SNAPSHOT_DELAY=Sekunden] speichert das Hauptfenster
/// (mit Karte) als PNG und beendet das Programm. Für Prüfungen ohne Bildschirmaufnahme-Freigabe.
@MainActor
enum SnapshotHelper {
    static func installIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["DIGIDEC_SNAPSHOT"] else { return }
        let delay = Double(env["DIGIDEC_SNAPSHOT_DELAY"] ?? "") ?? 20
        let steps = (env["DIGIDEC_SNAPSHOT_STEPS"] ?? "").split(separator: ",").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            capture(to: path)
            // weitere Bilder: „modul:karte“ je Schritt, Dateiname mit Nummer
            var n = 1
            @MainActor func next() {
                guard n <= steps.count else { NSApplication.shared.terminate(nil); return }
                let parts = steps[n - 1].split(separator: ":").map(String.init)
                if let m = DecoderModuleInfo(rawValue: parts[0]) {
                    DigidecState.shared.select(module: m)
                    if parts.count > 1 {
                        let layout: MapLayout = parts[1] == "karte" ? .map : parts[1] == "beide" ? .split : .list
                        DigidecState.shared.setMapLayout(layout, for: m)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    MainActor.assumeIsolated {
                        capture(to: path.replacingOccurrences(of: ".png", with: "_\(n).png"))
                        n += 1
                        next()
                    }
                }
            }
            next()
        }
    }

    static func capture(to path: String) {
        let wanted = ProcessInfo.processInfo.environment["DIGIDEC_SNAPSHOT_WINDOW"]
        guard let window = NSApplication.shared.windows.first(where: { $0.contentView != nil && $0.canBecomeMain && (wanted == nil || $0.title == wanted) }) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if wanted == nil {
            // DIGIDEC_SNAPSHOT_SIZE=1920x1080 prüft das Layout in der Größe, die jeder Bildschirm hergibt
            let size = (ProcessInfo.processInfo.environment["DIGIDEC_SNAPSHOT_SIZE"] ?? "").split(separator: "x").compactMap { Double($0) }
            window.setContentSize(size.count == 2 ? NSSize(width: size[0], height: size[1]) : NSSize(width: 1400, height: 900))
        }
        window.orderFrontRegardless()
        let id = CGWindowID(window.windowNumber)
        if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]), img.width > 1000 {
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        } else if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            // Ersatz, wenn das Fenster nicht sichtbar ist (Bildschirm gesperrt): Inhalt ohne Karte
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
