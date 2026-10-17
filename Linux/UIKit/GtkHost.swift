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

    public init() {}

    public func register(id: String, title: String, size: CGSize, content: @escaping () -> any View) {
        windows[id] = (title, size, content)
    }

    func open(id: String) {
        if let host = open[id], let window = host.window { dg_window_present(window); return }
        guard let entry = windows[id], let app else { return }
        let host = UIHost(title: entry.title, background: background, root: entry.make)
        host.windowManager = self
        open[id] = host
        host.createWindow(app: app, size: entry.size) { [weak self] in self?.open[id] = nil }
    }
}

@MainActor private func host(from u: UnsafeMutableRawPointer?) -> UIHost { Unmanaged<UIHost>.fromOpaque(u!).takeUnretainedValue() }

extension UIHost {
    func createWindow(app: UnsafeMutableRawPointer, size: CGSize, onClose: @escaping () -> Void = {}) {
        self.size = size
        var callbacks = DGCallbacks()
        callbacks.draw = { u, cr, w, h in MainActor.assumeIsolated { host(from: u).draw(cr: cr!, width: Int(w), height: Int(h)) } }
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
        dg_window_present(w.window)
        if let script = ProcessInfo.processInfo.environment["DIGIDEC_SCRIPT"] { runScript(script) }
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
                    exit(ok ? 0 : 1)
                }
            }
        }
    }
}

// MARK: - Anwendung

@MainActor
public enum LinuxApplication {
    nonisolated(unsafe) static var context: (WindowManager, String, () -> Void)?

    /// Startet GTK mit dem Hauptfenster und läuft, bis alle Fenster geschlossen sind
    public static func run(id: String, manager: WindowManager, onStart: @escaping () -> Void = {}) -> Int32 {
        context = (manager, id, onStart)
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
            MainActor.assumeIsolated {
                guard let (manager, id, onStart) = LinuxApplication.context else { return }
                onStart()
                manager.open(id: id)
            }
        }, nil)!
        manager.app = app
        return dg_app_run(app)
    }

    public static func installStyle(_ css: String) { dg_install_css(css) }
}


extension UIHost {
    /// Entwicklungshilfe: `DIGIDEC_SCRIPT=<Datei>` spielt Zeilen ab (ein Befehl je Zeile, `#` beginnt einen Kommentar):
    /// `wait <s>`, `move x y`, `click x y`, `rclick x y`, `drag x1 y1 x2 y2`, `scroll x y dy`, `key <Zeichen>`, `shot <Datei.png> [Breite Höhe]`, `quit`.
    /// Die Oberfläche wird dabei ohne sichtbares Fenster gezeichnet; so lassen sich Bedienabläufe prüfen.
    func runScript(_ path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write(Data("Skript nicht lesbar: \(path)\n".utf8)); return
        }
        var commands = text.split(whereSeparator: \.isNewline).map { String($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
        var waitUntil = Date()
        let env = ProcessInfo.processInfo.environment
        let size = CGSize(width: Double(env["DIGIDEC_SNAPSHOT_WIDTH"] ?? "") ?? 1500, height: Double(env["DIGIDEC_SNAPSHOT_HEIGHT"] ?? "") ?? 960)
        self.size = size
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [self] timer in
            MainActor.assumeIsolated {
                drawOffscreen(size: size)
                guard Date() >= waitUntil, !commands.isEmpty else { return }
                let parts = commands.removeFirst().split(separator: " ").map(String.init)
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
                case "quit": exit(0)
                default: FileHandle.standardError.write(Data("Unbekannter Befehl: \(parts.joined(separator: " "))\n".utf8))
                }
                if commands.isEmpty && (parts.first != "wait") { timer.invalidate(); exit(0) }
            }
        }
    }
}
