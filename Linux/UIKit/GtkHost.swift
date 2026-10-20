// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// GTK-Anbindung des Hosts über die C-Schicht CDigidecGtk: Fenster, Zeichenfläche, Zeiger, Zeitgeber und eigene Eingabefelder.
import Foundation
import CDigidecGtk

// MARK: - Eigene Eingabefelder

@MainActor
final class NativeField {
    let widget: UnsafeMutableRawPointer
    var spec: NativeFieldSpec
    var updating = false
    let multiline: Bool
    init(widget: UnsafeMutableRawPointer, spec: NativeFieldSpec, multiline: Bool) { self.widget = widget; self.spec = spec; self.multiline = multiline }

    var text: String {
        guard let c = dg_field_get_text(widget, multiline ? 1 : 0) else { return "" }
        defer { dg_free(c) }
        return String(cString: c)
    }
}

extension UIHost {
    func syncFields() {
        // Während GTK zeichnet (snapshot), dürfen keine Widgets eingehängt oder verschoben werden: im nächsten Takt nachholen
        if isDrawing { fieldSyncPending = true; return }
        fieldSyncPending = false
        guard let fixed else { return }
        for (id, field) in fields where fieldSpecs[id] == nil {
            dg_field_remove(fixed, field.widget)
            fields[id] = nil
        }
        for (id, spec) in fieldSpecs {
            let field: NativeField
            let isNew: Bool
            if let existing = fields[id] { field = existing; isNew = false } else { field = makeField(spec); fields[id] = field; isNew = true }
            field.spec = spec
            dg_field_place(fixed, field.widget, spec.frame.minX, spec.frame.minY, Int32(spec.frame.width), Int32(spec.frame.height), isNew ? 1 : 0)
            dg_field_set_enabled(field.widget, spec.enabled ? 1 : 0)
            let wanted = spec.text.wrappedValue
            if field.text != wanted {
                field.updating = true
                dg_field_set_text(field.widget, field.multiline ? 1 : 0, wanted)
                field.updating = false
            }
        }
    }

    private func makeField(_ spec: NativeFieldSpec) -> NativeField {
        let holder = FieldHolder()
        let user = Unmanaged.passUnretained(holder).toOpaque()
        let changed: @convention(c) (UnsafeMutableRawPointer?) -> Void = { u in
            MainActor.assumeIsolated {
                guard let f = Unmanaged<FieldHolder>.fromOpaque(u!).takeUnretainedValue().field, !f.updating else { return }
                f.spec.text.wrappedValue = f.text
            }
        }
        let activate: @convention(c) (UnsafeMutableRawPointer?) -> Void = { u in
            MainActor.assumeIsolated { Unmanaged<FieldHolder>.fromOpaque(u!).takeUnretainedValue().field?.spec.submit?() }
        }
        let widget: UnsafeMutableRawPointer
        if spec.multiline {
            widget = dg_textview_new(spec.font.family.components(separatedBy: ",")[0], Double(spec.font.size), changed, user)
        } else {
            let alignment: Double = spec.alignment == .leading ? 0 : (spec.alignment == .center ? 0.5 : 1)
            widget = dg_entry_new(spec.placeholder, spec.secure ? 1 : 0, alignment, spec.font.family.components(separatedBy: ",")[0], Double(spec.font.size),
                                  spec.style == .plain ? 1 : 0, changed, activate, user)
        }
        let field = NativeField(widget: widget, spec: spec, multiline: spec.multiline)
        holder.field = field
        fieldHolders.append(holder)
        return field
    }
}

@MainActor
final class FieldHolder { var field: NativeField? }

// MARK: - Fenster

@MainActor
public final class WindowManager {
    var windows: [String: (title: String, size: CGSize, make: () -> any View)] = [:]
    var open: [String: UIHost] = [:]
    var app: UnsafeMutableRawPointer?
    public var background = Color(white: 0.08)
    /// Wird nach dem Anlegen eines Fensters aufgerufen (Kennung, GTK-Fenster): für Kopfleiste und Menü
    public var onWindowCreated: ((String, UnsafeMutableRawPointer) -> Void)?

    public init() {}

    public func register(id: String, title: String, size: CGSize, content: @escaping () -> any View) {
        windows[id] = (title, size, content)
    }

    public func open(id: String) {
        if let host = open[id], let window = host.window { dg_window_present(window); return }
        guard let entry = windows[id], let app else { return }
        let host = UIHost(title: entry.title, background: background, root: entry.make)
        host.windowManager = self
        open[id] = host
        host.createWindow(app: app, size: entry.size, configure: { [weak self] window in self?.onWindowCreated?(id, window) }) { [weak self, weak host] in
            host?.shutdown()
            self?.open[id] = nil
        }
    }

    /// GTK-Fenster einer offenen Kennung (für Dialoge)
    public func window(_ id: String) -> UnsafeMutableRawPointer? { open[id]?.window ?? open.values.first?.window }
}

@MainActor private func host(from u: UnsafeMutableRawPointer?) -> UIHost { Unmanaged<UIHost>.fromOpaque(u!).takeUnretainedValue() }

extension UIHost {
    /// Legt das GTK-Fenster an; `configure` läuft vor dem Anzeigen (Kopfleiste und Ähnliches lassen sich danach nicht mehr setzen)
    func createWindow(app: UnsafeMutableRawPointer, size: CGSize, configure: (UnsafeMutableRawPointer) -> Void = { _ in }, onClose: @escaping () -> Void = {}) {
        self.size = size
        var callbacks = DGCallbacks()
        callbacks.draw = { u, cr, w, h, fresh in MainActor.assumeIsolated { host(from: u).drawRetained(cr: cr!, width: Int(w), height: Int(h), fresh: fresh != 0) } }
        callbacks.pressed = { u, button, x, y in
            MainActor.assumeIsolated {
                let h = host(from: u)
                if let area = h.drawingArea { dg_field_focus(area) }
                h.pressed(CGPoint(x: x, y: y), button: Int(button))
            }
        }
        callbacks.released = { u, button, x, y in MainActor.assumeIsolated { host(from: u).released(CGPoint(x: x, y: y), button: Int(button)) } }
        callbacks.motion = { u, x, y in MainActor.assumeIsolated { host(from: u).pointerMoved(CGPoint(x: x, y: y)) } }
        callbacks.leave = { u in MainActor.assumeIsolated { host(from: u).pointerLeft() } }
        callbacks.scroll = { u, dx, dy, state in
            MainActor.assumeIsolated { let h = host(from: u); return h.scrolled(h.pointer, dx: CGFloat(dx) * 40, dy: CGFloat(dy) * 40, state: Int(state)) ? 1 : 0 }
        }
        callbacks.key = { u, keyval, state, codepoint in
            MainActor.assumeIsolated {
                guard let scalar = Unicode.Scalar(codepoint) else { return 0 }
                return host(from: u).keyPressed(Character(scalar), command: (state & 4) != 0) ? 1 : 0
            }
        }
        callbacks.closed = { u in MainActor.assumeIsolated { host(from: u).closeHandler?() } }
        callbacks.tick = { u in MainActor.assumeIsolated { host(from: u).tick() } }
        closeHandler = onClose
        let w = dg_window_new(app, title, Int32(size.width), Int32(size.height), &callbacks, Unmanaged.passUnretained(self).toOpaque())
        window = w.window
        drawingArea = w.area
        fixed = w.fixed
        if let window = w.window { configure(window) }
        dg_window_present(w.window)
        // Das Skript läuft einmal, im ersten Fenster (weitere Fenster öffnet es selbst mit `open`)
        if let script = ProcessInfo.processInfo.environment["DIGIDEC_SCRIPT"], !UIHost.scriptStarted { UIHost.scriptStarted = true; runScript(script) }
        // Entwicklungshilfe: DIGIDEC_SNAPSHOT=<Datei.png> schreibt nach DIGIDEC_SNAPSHOT_AFTER Sekunden (Standard 8) ein Bild der Oberfläche und beendet das Programm
        if let path = ProcessInfo.processInfo.environment["DIGIDEC_SNAPSHOT"], windowManager?.open.count ?? 0 <= 1 {
            let delay = Double(ProcessInfo.processInfo.environment["DIGIDEC_SNAPSHOT_AFTER"] ?? "") ?? 8
            let width = Double(ProcessInfo.processInfo.environment["DIGIDEC_SNAPSHOT_WIDTH"] ?? "") ?? Double(size.width)
            let height = Double(ProcessInfo.processInfo.environment["DIGIDEC_SNAPSHOT_HEIGHT"] ?? "") ?? Double(size.height)
            let offscreen = CGSize(width: width, height: height)
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] _ in MainActor.assumeIsolated { drawOffscreen(size: offscreen) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                MainActor.assumeIsolated {
                    let ok = snapshot(to: path, size: CGSize(width: width, height: height))
                    FileHandle.standardError.write(Data((ok ? "Schnappschuss: \(path)\n" : "Schnappschuss fehlgeschlagen\n").utf8))
                    LinuxApplication.terminate(ok ? 0 : 1)
                }
            }
        }
    }
}

// MARK: - Anwendung

@MainActor
public enum LinuxApplication {
    nonisolated(unsafe) static var context: (manager: WindowManager, id: String, urlWindow: String, onStart: () -> Void, onOpen: (URL) -> Void)?
    nonisolated(unsafe) public private(set) static var started = false
    nonisolated(unsafe) static var app: UnsafeMutableRawPointer?
    nonisolated(unsafe) static var actions: [Int: (String?) -> Void] = [:]

    /// Startet GTK mit dem Fenster `id` und läuft, bis alle Fenster geschlossen sind oder `quit()` gerufen wird.
    /// Eine Instanz je Sitzung: Ein zweiter Start reicht seine Argumente (`digidec://…`) an die laufende Instanz weiter (`onOpen`).
    /// `urlWindow`: Fenster, das ein Auftrag nach vorn holt (wie am Mac das Hauptfenster)
    public static func run(id: String, manager: WindowManager, arguments: [String] = CommandLine.arguments, urlWindow: String = "main",
                           onStart: @escaping () -> Void = {}, onOpen: @escaping (URL) -> Void = { _ in }) -> Int32 {
        context = (manager, id, urlWindow, onStart, onOpen)
        clipboardHook = { [weak manager] text in
            if let window = manager?.open.values.first?.window { dg_clipboard_set(window, text) }
        }
        fileDialogHook = { [weak manager] title, save, folder, name in
            guard let window = manager?.open["main"]?.window ?? manager?.open.values.first?.window,
                  let c = dg_file_dialog(window, title, save ? 1 : 0, folder ? 1 : 0, name) else { return nil }
            defer { dg_free(c) }
            return String(cString: c)
        }
        let app = dg_app_new("de.betz.digidec", { _ in
            MainActor.assumeIsolated { LinuxApplication.startIfNeeded() }
        }, { _, uri in
            MainActor.assumeIsolated {
                guard let uri, let url = URL(string: String(cString: uri)), let context = LinuxApplication.context else { return }
                LinuxApplication.startIfNeeded(window: context.urlWindow)
                context.onOpen(url)
            }
        }, nil)!
        manager.app = app
        self.app = app
        // GTK bekommt nur Programmname und Aufträge (URLs, Dateien); Schalter wie `-schlüssel wert` gehören den UserDefaults
        var forwarded = Array(arguments.prefix(1))
        var rest = arguments.dropFirst()[...]
        while let argument = rest.first {
            rest = rest.dropFirst()
            if argument.hasPrefix("-") { if !rest.isEmpty, !(rest.first!.hasPrefix("-")) { rest = rest.dropFirst() }; continue }
            forwarded.append(argument)
        }
        var cArguments = forwarded.map { strdup($0) }
        defer { cArguments.forEach { free($0) } }
        return cArguments.withUnsafeMutableBufferPointer { dg_app_run(app, Int32($0.count), $0.baseAddress) }
    }

    /// Erster Start: Fenster öffnen (ohne Angabe das Startfenster); jeder weitere Aufruf holt es nach vorn
    private static func startIfNeeded(window: String? = nil) {
        guard let context else { return }
        if !started { started = true; context.onStart() }
        context.manager.open(id: window ?? context.id)
    }

    /// Beendet die Hauptschleife; `run` kehrt danach zurück
    public static func quit() { if let app { dg_app_quit(app) } }

    /// Beendet den Prozess, ohne die statischen C++-Objekte der Decoder abzubauen: Hintergrundfäden (Stationslisten laden,
    /// Decoder) können sie in diesem Moment noch benutzen, `exit()` würde sie unter ihnen zerstören. Einstellungen werden vorher gesichert.
    public static func terminate(_ status: Int32) -> Never {
        UserDefaults.standard.synchronize()
        fflush(nil)
        _exit(status)
    }

    /// Aktion `app.<name>` (für Menü und Tastenkürzel). Mit `state` ist es eine Auswahl, `handler` bekommt den gewählten Wert.
    public static func addAction(_ name: String, accelerator: String? = nil, state: String? = nil, handler: @escaping (String?) -> Void) {
        guard let app else { return }
        // Schlüssel ab 1, damit der Zeiger nie NULL ist
        let key = actions.count + 1
        actions[key] = handler
        dg_app_add_action(app, name, accelerator, state, { user, value in
            MainActor.assumeIsolated {
                LinuxApplication.actions[Int(bitPattern: user)]?(value.map { String(cString: $0) })
            }
        }, UnsafeMutableRawPointer(bitPattern: key))
    }

    public static func installStyle(_ css: String) { dg_install_css(css) }

    /// Rückfrage mit zwei Knöpfen am Fenster; `handler(true)` für den ersten Knopf
    public static func confirm(window: UnsafeMutableRawPointer, message: String, detail: String, confirm: String, cancel: String,
                               handler: @escaping (Bool) -> Void) {
        let box = Unmanaged.passRetained(ConfirmBox(handler)).toOpaque()
        dg_alert(window, message, detail, confirm, cancel, { user, choice in
            MainActor.assumeIsolated {
                let box = Unmanaged<ConfirmBox>.fromOpaque(user!).takeRetainedValue()
                box.handler(choice == 0)
            }
        }, box)
    }
}

/// Menü aus Einträgen, Abschnitten und Untermenüs (GMenu)
@MainActor
public final class LinuxMenu {
    let pointer: UnsafeMutableRawPointer
    public init() { pointer = dg_menu_new() }
    public func item(_ label: String, action: String) { dg_menu_append(pointer, label, action) }
    public func section(_ build: (LinuxMenu) -> Void) { let s = LinuxMenu(); build(s); dg_menu_append_section(pointer, s.pointer) }
    public func submenu(_ label: String, _ build: (LinuxMenu) -> Void) { let s = LinuxMenu(); build(s); dg_menu_append_submenu(pointer, label, s.pointer) }
    /// Kopfleiste mit diesem Menü an das Fenster hängen (übernimmt das Menü; danach nicht weiter verwenden)
    public func install(on window: UnsafeMutableRawPointer, tooltip: String) { dg_window_set_menu(window, pointer, tooltip) }
}

private final class ConfirmBox {
    let handler: (Bool) -> Void
    init(_ handler: @escaping (Bool) -> Void) { self.handler = handler }
}


extension UIHost {
    nonisolated(unsafe) static var scriptStarted = false

    /// Entwicklungshilfe: `DIGIDEC_SCRIPT=<Datei>` spielt Zeilen ab (ein Befehl je Zeile, `#` beginnt einen Kommentar):
    /// `wait <s>`, `move x y`, `click x y`, `rclick x y`, `drag x1 y1 x2 y2`, `scroll x y dy`, `key <Zeichen>`, `shot <Datei.png> [Breite Höhe]`,
    /// `open <Fenster>`, `close <Fenster>` (Kennung wie „assistant“; echte GTK-Fenster), `quit`.
    /// Die Oberfläche wird dabei ohne sichtbares Fenster gezeichnet; so lassen sich Bedienabläufe prüfen.
    func runScript(_ path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write(Data("Skript nicht lesbar: \(path)\n".utf8)); return
        }
        var commands = text.split(whereSeparator: \.isNewline).map { String($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
        var waitUntil = Date()
        let env = ProcessInfo.processInfo.environment
        let size = CGSize(width: Double(env["DIGIDEC_SNAPSHOT_WIDTH"] ?? "") ?? 1500, height: Double(env["DIGIDEC_SNAPSHOT_HEIGHT"] ?? "") ?? 960)
        // DIGIDEC_SCRIPT_LIVE: Ereignisse laufen im echten Fenster (mit seinem eigenen Zeichenweg) statt in einer Offscreen-Fläche
        let live = env["DIGIDEC_SCRIPT_LIVE"] != nil
        if !live { self.size = size }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [self] timer in
            MainActor.assumeIsolated {
                if !live { drawOffscreen(size: size) }
                guard Date() >= waitUntil, !commands.isEmpty else { return }
                let line = commands.removeFirst()
                lastScriptCommand = line
                let parts = line.split(separator: " ").map(String.init)
                func number(_ i: Int) -> CGFloat { i < parts.count ? CGFloat(Double(parts[i]) ?? 0) : 0 }
                switch parts.first ?? "" {
                case "wait": waitUntil = Date().addingTimeInterval(Double(number(1)))
                case "move": pointerMoved(CGPoint(x: number(1), y: number(2)))
                case "click":
                    let p = CGPoint(x: number(1), y: number(2))
                    pointerMoved(p); pressed(p, button: 1); released(p, button: 1)
                case "rclick":
                    let p = CGPoint(x: number(1), y: number(2))
                    pointerMoved(p); pressed(p, button: 3); released(p, button: 3)
                case "drag":
                    let a = CGPoint(x: number(1), y: number(2)), b = CGPoint(x: number(3), y: number(4))
                    pointerMoved(a); pressed(a, button: 1)
                    for i in 1...8 { pointerMoved(CGPoint(x: a.x + (b.x - a.x) * CGFloat(i) / 8, y: a.y + (b.y - a.y) * CGFloat(i) / 8)) }
                    released(b, button: 1)
                case "scroll":
                    let p = CGPoint(x: number(1), y: number(2))
                    pointerMoved(p); _ = scrolled(p, dx: 0, dy: number(3))
                case "key": if let c = parts.dropFirst().first?.first { _ = keyPressed(c, command: false) }
                case "shot":
                    let out = parts.count > 1 ? parts[1] : "shot.png"
                    let ok = snapshot(to: out, size: parts.count > 3 ? CGSize(width: number(2), height: number(3)) : size)
                    FileHandle.standardError.write(Data((ok ? "Schnappschuss: \(out)\n" : "Schnappschuss fehlgeschlagen\n").utf8))
                case "open": if parts.count > 1 { windowManager?.open(id: parts[1]) }
                case "close": if parts.count > 1, let window = windowManager?.open[parts[1]]?.window { dg_window_close(window) }
                case "quit": LinuxApplication.terminate(0)
                default: FileHandle.standardError.write(Data("Unbekannter Befehl: \(parts.joined(separator: " "))\n".utf8))
                }
                if commands.isEmpty && (parts.first != "wait") { timer.invalidate(); LinuxApplication.terminate(0) }
            }
        }
    }
}
