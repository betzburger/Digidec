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
    var timelineIntervals: [Identity: TimeInterval] = [:]
    var timelineDue: [Identity: Date] = [:]
    var dirty = Set<Identity>()
    var compositeIndex: [Identity: CompositeNode] = [:]
    private var lastResolve = Date.distantPast

    // Eingabe
    var pointer = CGPoint.zero
    var hovered: [Identity: Node] = [:]
    var pressedNode: Node?
    var dragStart: CGPoint?
    var dragActive = false
    var tooltip: (text: String, at: CGPoint)?
    var tooltipDue: Date?
    var shortcuts: [(key: Character, command: Bool, enabled: Bool, action: () -> Void)] = []
    var overlays: [OverlayLayer] = []
    var presentations: [Identity: UUID] = [:]

    // Eigene Textfelder
    var fieldSpecs: [Identity: NativeFieldSpec] = [:]
    var fields: [Identity: NativeField] = [:]

    var windowManager: WindowManager?
    var tickCount = 0
    var closeHandler: (() -> Void)?

    public init(title: String, background: Color, root: @escaping () -> any View) {
        self.title = title
        self.background = background
        rootView = root
    }

    // MARK: Auffrischen

    func setNeedsResolve() { needsResolve = true; needsDraw = true }
    func setNeedsDraw() { needsDraw = true }

    func registerTimeline(identity: Identity, interval: TimeInterval) {
        timelineIntervals[identity] = interval
        if timelineDue[identity] == nil { timelineDue[identity] = Date().addingTimeInterval(interval) }
    }

    /// Die Ansicht mit dieser Identität neu auflösen (nur ihren Teilbaum)
    func invalidate(_ id: Identity) { dirty.insert(id); needsDraw = true }

    func registerShortcut(key: Character, command: Bool, enabled: Bool, action: @escaping () -> Void) { shortcuts.append((Character(String(key).lowercased()), command, enabled, action)) }

    func resolveAndLayout() {
        let trace = ProcessInfo.processInfo.environment["DIGIDEC_TRACE"] != nil
        let t0 = Date()
        timelineIntervals.removeAll()
        shortcuts.removeAll()
        dirty.removeAll()
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
        let t1 = Date()
        node.place(origin: .zero, size: size)
        for layer in overlays { layout(layer) }
        // Erst nach dem Platzieren aufräumen: Inhalte in GeometryReader werden erst beim Platzieren aufgelöst
        store.sweep()
        rootNode = node
        if trace { var count = 0; node.walk { _ in count += 1 }; FileHandle.standardError.write(Data(String(format: "resolve %.0f ms, layout %.0f ms, %d Knoten\n", t1.timeIntervalSince(t0) * 1000, Date().timeIntervalSince(t1) * 1000, count).utf8)) }
        needsResolve = false
        lastResolve = Date()
        timelineDue = timelineDue.filter { timelineIntervals[$0.key] != nil }
        compositeIndex.removeAll(keepingCapacity: true)
        node.walk { if let c = $0 as? CompositeNode { compositeIndex[c.identity] = c } }
        for layer in overlays { layer.node?.walk { if let c = $0 as? CompositeNode { compositeIndex[c.identity] = c } } }
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
        for hook in tickHooks { hook() }
        if tickCount == 5, ProcessInfo.processInfo.environment["DIGIDEC_TRACE_MAP"] != nil { FileHandle.standardError.write(Data("hooks \(tickHooks.count)\n".utf8)) }
        tickCount += 1
        if tickCount % 120 == 0, ProcessInfo.processInfo.environment["DIGIDEC_TRACE"] != nil { FileHandle.standardError.write(Data("tick \(tickCount) hooks \(tickHooks.count)\n".utf8)) }
        let t = Date()
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        if ProcessInfo.processInfo.environment["DIGIDEC_TRACE"] != nil, Date().timeIntervalSince(t) > 0.05 { FileHandle.standardError.write(Data(String(format: "RunLoop %.0f ms\n", Date().timeIntervalSince(t) * 1000).utf8)) }
        let now = Date()
        if needsResolve { resolveAndLayout(); needsDraw = true }
        else {
            for (id, due) in timelineDue where now >= due { dirty.insert(id); timelineDue[id] = now.addingTimeInterval(timelineIntervals[id] ?? 1) }
            if !dirty.isEmpty { refreshDirty() }
        }
        if let due = tooltipDue, now >= due, let hit = tooltip { _ = hit; tooltipDue = nil; needsDraw = true }
        if needsDraw, let area = drawingArea {
            needsDraw = false
            dg_queue_draw(area)
        }
    }

    /// Löst nur die als geändert gemeldeten Ansichten neu auf; ändert sich dabei eine Größe, wird neu platziert (ohne neu aufzulösen)
    private func refreshDirty() {
        let ids = dirty
        dirty.removeAll()
        var relayout = false
        for id in ids {
            guard let node = compositeIndex[id] else { continue }
            if !node.refresh() { relayout = true }
            node.walk { if let c = $0 as? CompositeNode { compositeIndex[c.identity] = c } }
        }
        if relayout, let root = rootNode {
            root.clearSizeCaches()
            root.place(origin: .zero, size: size)
            for layer in overlays { layout(layer) }
        }
        syncFields()
        needsDraw = true
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

    func scrolled(_ p: CGPoint, dx: CGFloat, dy: CGFloat, state: Int = 0) -> Bool {
        if let hook = rawScrollHook, hook(dx, dy, state) { return true }
        for n in chain(at: p) { if let s = n.handlers?.scroll, s(dx, dy) { return true } }
        return false
    }

    func keyPressed(_ key: Character, command: Bool) -> Bool {
        let lower = Character(String(key).lowercased())
        for s in shortcuts where s.key == lower && s.command == command && s.enabled {
            s.action()
            return true
        }
        if key == "\u{1b}", let last = overlays.last { last.onDismiss(); return true }
        return false
    }

    // MARK: Ebenen

    /// Zeigt ein Aufklappmenü am Punkt
    func presentMenu(rows: [MenuRow], at point: CGPoint) {
        let layer = OverlayLayer(anchor: CGRect(origin: point, size: .zero), modal: false, placement: .topLeading, makeView: { EmptyView() }, onDismiss: { })
        layer.makeView = { MenuPopupView(rows: rows, dismiss: { [unowned self] in self.dismiss(layer.id) }) }
        layer.onDismiss = { [unowned self] in self.dismiss(layer.id) }
        present(layer)
    }

    func present(_ layer: OverlayLayer) {
        overlays.append(layer)
        setNeedsResolve()
    }

    func dismiss(_ id: UUID) {
        overlays.removeAll { $0.id == id }
        setNeedsResolve()
    }
}

extension UIHost {
    /// Zeichnet die Oberfläche in eine PNG-Datei (ohne sichtbares Fenster): für Prüfungen und Schnappschüsse
    /// Zeichnet einmal ohne Ausgabe (hält Kartenkacheln und Ähnliches in Gang, wenn kein Fenster gemalt wird)
    public func drawOffscreen(size: CGSize) {
        guard let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(size.width), Int32(size.height)) else { return }
        defer { cairo_surface_destroy(surface) }
        let cr = cairo_create(surface)!
        defer { cairo_destroy(cr) }
        draw(cr: cr, width: Int(size.width), height: Int(size.height))
    }

    @discardableResult
    public func snapshot(to path: String, size: CGSize? = nil) -> Bool {
        let target = size ?? self.size
        self.size = target
        guard let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(target.width), Int32(target.height)) else { return false }
        defer { cairo_surface_destroy(surface) }
        let cr = cairo_create(surface)!
        defer { cairo_destroy(cr) }
        resolveAndLayout()
        draw(cr: cr, width: Int(target.width), height: Int(target.height))
        return cairo_surface_write_to_png(surface, path) == CAIRO_STATUS_SUCCESS
    }
}

/// Wird bei jedem Takt der Oberfläche auf dem Hauptfaden aufgerufen (für Arbeit, die Hintergrundfäden übergeben haben)
nonisolated(unsafe) public var tickHooks: [() -> Void] = []
