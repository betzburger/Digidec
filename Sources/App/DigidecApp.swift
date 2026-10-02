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

    init() {
        // Ignore SIGPIPE so a vanished rigctld socket never terminates the process
        signal(SIGPIPE, SIG_IGN)
        NSApplication.shared.setActivationPolicy(.regular)
        SnapshotHelper.installIfRequested()
    }

    var body: some Scene {
        // Einzelnes Fenster: ein zweiter Auftrag darf kein weiteres Fenster öffnen
        Window("Digidec", id: "main") {
            MainWindowView(state: state)
                .preferredColorScheme(.dark)
                .onAppear { state.startAudio() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appTermination) {
                Button("Digidec beenden") {
                    state.cleanup()
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
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
                        let wantMap = parts[1] == "karte"
                        if DigidecState.shared.isMapVisible(m) != wantMap { DigidecState.shared.toggleMap(m) }
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
        guard let window = NSApplication.shared.windows.first(where: { $0.contentView != nil && $0.canBecomeMain }) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.setContentSize(NSSize(width: 1400, height: 900))
        window.orderFrontRegardless()
        let id = CGWindowID(window.windowNumber)
        if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) {
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
