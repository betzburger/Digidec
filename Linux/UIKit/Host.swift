// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Der Host verbindet den Ansichtsbaum mit einem GTK-Fenster: Auflösen, Vermessen, Zeichnen, Zeigerereignisse, Zeitgeber, Kurzbefehle.
import Foundation
import CGtkCairo
import CDigidecGtk

/// Zusätzliche Ebene über der Oberfläche (Menüs, Blätter, Hilfetexte)
@MainActor
final class OverlayLayer {
    let id = UUID()
    var makeView: () -> any View
    var anchor: CGRect
    var modal: Bool
    var placement: Placement
    var onDismiss: () -> Void
    var node: Node?
    var anchorProvider: (() -> CGRect)?
    enum Placement { case below, centered, topLeading, pointer }
    init(anchor: CGRect, modal: Bool, placement: Placement, makeView: @escaping () -> any View, onDismiss: @escaping () -> Void) {
        self.anchor = anchor; self.modal = modal; self.placement = placement; self.makeView = makeView; self.onDismiss = onDismiss
    }
}

@MainActor
public final class UIHost {
    let store = StateStore()
    var rootView: () -> any View
    var rootNode: Node?
    var size = CGSize(width: 1280, height: 860)
    var background = Color(white: 0.08)
    var title = ""

    // GTK
    var window: UnsafeMutableRawPointer?
    var drawingArea: UnsafeMutableRawPointer?
    var fixed: UnsafeMutableRawPointer?
    var fieldHolders: [FieldHolder] = []
    var needsResolve = true
    var needsDraw = true
    var timelineIntervals: [TimeInterval] = []
    private var lastResolve = Date.distantPast
    private var nextTimelineDue = Date.distantFuture

    // Eingabe
    var pointer = CGPoint.zero
    var hovered: [Identity: Node] = [:]
    var pressedNode: Node?
    var dragStart: CGPoint?
    var dragActive = false
    var tooltip: (text: String, at: CGPoint)?
    var tooltipDue: Date?
    var shortcuts: [(key: Character, command: Bool, enabled: Bool, node: Node)] = []
    var overlays: [OverlayLayer] = []
    var presentations: [Identity: UUID] = [:]

    // Eigene Textfelder
    var fieldSpecs: [Identity: NativeFieldSpec] = [:]
    var fields: [Identity: NativeField] = [:]

    var windowManager: WindowManager?
    var closeHandler: (() -> Void)?

    public init(title: String, background: Color, root: @escaping () -> any View) {
        self.title = title
        self.background = background
        rootView = root
    }

    // MARK: Auffrischen

    func setNeedsResolve() { needsResolve = true; needsDraw = true }
    func setNeedsDraw() { needsDraw = true }

    func registerTimeline(interval: TimeInterval) { timelineIntervals.append(interval) }

    func registerShortcut(key: Character, command: Bool, enabled: Bool, node: Node) { shortcuts.append((Character(String(key).lowercased()), command, enabled, node)) }

    func resolveAndLayout() {
        timelineIntervals.removeAll()
        shortcuts.removeAll()
        fieldSpecs.removeAll()
        store.epoch += 1
        let resolver = Resolver(store: store, host: self)
        resolver.env.host = self
        resolver.env.openWindow = OpenWindowAction { [weak self] id in self?.windowManager?.open(id: id) }
        let view = rootView()
        let node = resolver.resolveSingle(view, key: "root")
        // Ebenen neu auflösen
        for layer in overlays {
            let r = Resolver(store: store, host: self)
            r.env = resolver.env
            r.identity = Identity.root.child("overlay").child(layer.id)
            layer.node = r.resolveSingle(layer.makeView(), key: 0)
        }
        store.sweep()
        node.place(origin: .zero, size: size)
        for layer in overlays { layout(layer) }
        rootNode = node
        needsResolve = false
        lastResolve = Date()
        if let shortest = timelineIntervals.min() { nextTimelineDue = Date().addingTimeInterval(shortest) } else { nextTimelineDue = .distantFuture }
        syncFields()
    }

    private func layout(_ layer: OverlayLayer) {
        guard let node = layer.node else { return }
        let maxW = size.width - 16, maxH = size.height - 16
        let s = node.size(for: Proposal(width: nil, height: nil))
        let fitted = CGSize(width: min(s.width, maxW), height: min(s.height, maxH))
        var origin: CGPoint
        switch layer.placement {
        case .centered: origin = CGPoint(x: (size.width - fitted.width) / 2, y: max(24, (size.height - fitted.height) / 3))
        case .below:
            origin = CGPoint(x: layer.anchor.minX, y: layer.anchor.maxY + 2)
            if origin.y + fitted.height > size.height - 8 { origin.y = max(8, layer.anchor.minY - fitted.height - 2) }
        case .topLeading: origin = layer.anchor.origin
        case .pointer: origin = CGPoint(x: layer.anchor.minX + 10, y: layer.anchor.minY + 16)
        }
        origin.x = min(max(8, origin.x), max(8, size.width - fitted.width - 8))
        node.place(origin: origin, size: node.size(for: .fixed(fitted)))
    }

    /// Zeitgeber (16 ms): Hauptschlange bedienen, aufgelöste Änderungen und Zeitleisten verarbeiten
    func tick() {
        RunLoop.main.run(mode: .default, before: Date())
        let now = Date()
        if needsResolve || now >= nextTimelineDue { resolveAndLayout(); needsDraw = true }
        if let due = tooltipDue, now >= due, let hit = tooltip { _ = hit; tooltipDue = nil; needsDraw = true }
        if needsDraw, let area = drawingArea {
            needsDraw = false
            dg_queue_draw(area)
        }
    }

    // MARK: Zeichnen

    func draw(cr: OpaquePointer, width: Int, height: Int) {
        let newSize = CGSize(width: width, height: height)
        if newSize != size || rootNode == nil {
            size = newSize
            resolveAndLayout()
        }
        var g = GraphicsContext(cairo: cr, size: size)
        cairo_set_source_rgba(cr, background.red, background.green, background.blue, 1)
        cairo_paint(cr)
        guard let root = rootNode else { return }
        let all = CGRect(origin: .zero, size: size)
        root.draw(&g, clip: all)
        for layer in overlays {
            if layer.modal { g.fill(Path(all), with: .color(Color(white: 0, opacity: 0.45))) }
            if let node = layer.node {
                // Schatten und Rahmen des Menüs/Blattes
                g.drawShadow(color: Color(white: 0, opacity: 0.5), radius: 12, x: 0, y: 4) { inner in
                    inner.fill(Path(roundedRect: node.frame, cornerRadius: 8), with: .color(background.opacity(1)))
                }
                node.draw(&g, clip: all)
            }
        }
        if let tip = tooltip, tooltipDue == nil { drawTooltip(&g, tip) }
    }

    private func drawTooltip(_ g: inout GraphicsContext, _ tip: (text: String, at: CGPoint)) {
        var env = EnvironmentValues()
        env.font = .system(size: 11)
        let spec = TextSpec(text: tip.text, font: .system(size: 11), color: Color(white: 0.95), lineLimit: nil, tracking: 0, minScale: 1, alignment: .leading, underline: false, strikethrough: false)
        let m = TextEngine.measure(spec, width: 360)
        let box = CGRect(x: min(tip.at.x + 12, size.width - m.size.width - 16), y: min(tip.at.y + 18, size.height - m.size.height - 12), width: m.size.width + 12, height: m.size.height + 8)
        g.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(Color(white: 0.16)))
        g.stroke(Path(roundedRect: box, cornerRadius: 4), with: .color(Color(white: 1, opacity: 0.2)), lineWidth: 1)
        TextEngine.draw(spec, in: CGRect(x: box.minX + 6, y: box.minY + 4, width: m.size.width, height: m.size.height), cr: g.cr)
    }

    // MARK: Ereignisse

    private func chain(at p: CGPoint) -> [Node] {
        var result: [Node] = []
        for layer in overlays.reversed() {
            layer.node?.hit(p, into: &result)
            if !result.isEmpty || layer.modal { return result }
        }
        rootNode?.hit(p, into: &result)
        return result
    }

    func pointerMoved(_ p: CGPoint) {
        pointer = p
        let nodes = chain(at: p)
        var now: [Identity: Node] = [:]
        for n in nodes where n.handlers?.hover != nil { now[n.identity] = n }
        for n in nodes { n.handlers?.motion?(p) }
        for (id, n) in hovered where now[id] == nil { n.handlers?.hover?(false) }
        for (id, n) in now where hovered[id] == nil { n.handlers?.hover?(true) }
        hovered = now
        // Hilfetext nach kurzer Ruhe
        tooltip = nil
        if let help = nodes.first(where: { $0.handlers?.help != nil })?.handlers?.help, pressedNode == nil, overlays.isEmpty {
            tooltip = (help, p)
            tooltipDue = Date().addingTimeInterval(0.7)
        } else { tooltipDue = nil }
        if let target = pressedNode, let drag = target.handlers?.drag, let start = dragStart {
            if !dragActive, hypot(p.x - start.x, p.y - start.y) >= drag.minimumDistance { dragActive = true }
            if dragActive { drag.changed?(DragValue(location: p, startLocation: start)) }
        }
        needsDraw = true
    }

    func pointerLeft() {
        for (_, n) in hovered { n.handlers?.hover?(false) }
        hovered.removeAll()
        tooltip = nil
        needsDraw = true
    }

    func pressed(_ p: CGPoint, button: Int) {
        pointer = p
        tooltip = nil
        let nodes = chain(at: p)
        if let top = overlays.last, !(top.node?.frame.contains(p) ?? false) {
            if !top.modal { top.onDismiss() }
            return
        }
        guard button == 1 else { if button == 3, let n = nodes.first(where: { $0.contextMenu != nil }) { n.contextMenu?(p) }; return }
        guard let target = nodes.first(where: { $0.handlers?.tap != nil || $0.handlers?.press != nil || $0.handlers?.drag != nil }), target.enabled else { return }
        pressedNode = target
        dragStart = p
        dragActive = false
        target.handlers?.press?(true)
        if let drag = target.handlers?.drag, drag.minimumDistance == 0 { dragActive = true; drag.changed?(DragValue(location: p, startLocation: p)) }
    }

    private func overlayContains(_ p: CGPoint) -> Bool { overlays.contains { $0.node?.frame.contains(p) ?? false } }

    func released(_ p: CGPoint, button: Int) {
        guard button == 1, let target = pressedNode else { return }
        pressedNode = nil
        target.handlers?.press?(false)
        if dragActive, let drag = target.handlers?.drag, let start = dragStart {
            drag.ended?(DragValue(location: p, startLocation: start))
        } else if target.frame.contains(p) {
            target.handlers?.tap?()
        }
        dragStart = nil
        dragActive = false
        setNeedsResolve()
    }

    func scrolled(_ p: CGPoint, dx: CGFloat, dy: CGFloat) -> Bool {
        for n in chain(at: p) { if let s = n.handlers?.scroll, s(dx, dy) { return true } }
        return false
    }

    func keyPressed(_ key: Character, command: Bool) -> Bool {
        let lower = Character(String(key).lowercased())
        for s in shortcuts where s.key == lower && s.command == command && s.enabled {
            s.node.handlers?.tap?()
            return true
        }
        if key == "\u{1b}", let last = overlays.last { last.onDismiss(); return true }
        return false
    }

    // MARK: Ebenen

    func present(_ layer: OverlayLayer) {
        overlays.append(layer)
        setNeedsResolve()
    }

    func dismiss(_ id: UUID) {
        overlays.removeAll { $0.id == id }
        setNeedsResolve()
    }
}
