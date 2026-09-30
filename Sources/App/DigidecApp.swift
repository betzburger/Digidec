import SwiftUI
import AppKit
import AVFoundation

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
        NSApplication.shared.activate(ignoringOtherApps: true)
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

        // Audio-Eingang von der virtuellen Soundkarte braucht die Mikrofon-Freigabe (TCC)
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                print("Digidec: Microphone permission granted: \(granted)")
            }
        }
    }

    var body: some Scene {
        // Einzelnes Fenster: ein zweiter Auftrag darf kein weiteres Fenster öffnen
        Window("Digidec", id: "main") {
            MainWindowView(state: state)
                .preferredColorScheme(.dark)
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
