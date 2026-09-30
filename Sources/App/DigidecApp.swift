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
