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
    }
}

// MARK: - Anwendung

@MainActor
public enum LinuxApplication {
    nonisolated(unsafe) static var context: (WindowManager, String, () -> Void)?

    /// Startet GTK mit dem Hauptfenster und läuft, bis alle Fenster geschlossen sind
    public static func run(id: String, manager: WindowManager, onStart: @escaping () -> Void = {}) -> Int32 {
        context = (manager, id, onStart)
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
