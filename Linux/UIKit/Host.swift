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
    /// Vollständiges Neuzeichnen angefordert (jede Änderung, deren Ausmaß unbekannt ist)
    var needsDraw = true { didSet { if needsDraw { fullRedraw = true } } }
    private var fullRedraw = true
    /// Bereich, der seit dem letzten Zeichnen ungültig wurde (nur Teilauffrischungen); `.null` = keiner
    private var pendingDamage: [CGRect] = []
    private static let diffDamage = ProcessInfo.processInfo.environment["DIGIDEC_NO_DIFF"] == nil
    private static let partialAllowed = ProcessInfo.processInfo.environment["DIGIDEC_FULL_REDRAW"] == nil
    /// Rand um geänderte Ansichten für Schatten und Leuchten, die über den Rahmen hinausragen
    private static let damageMargin: CGFloat = 40
    private var shownTooltipRect = CGRect.null
    /// Gleitende Kosten (Sekunden) von Auffrischen und Zeichnen; daraus ergibt sich, wie oft Live-Änderungen höchstens umgesetzt werden
    private var drawCost: TimeInterval = 0
    private var refreshCost: TimeInterval = 0
    private var lastDirtyRefresh = Date.distantPast
    var timelineIntervals: [Identity: TimeInterval] = [:]
    var timelineDue: [Identity: Date] = [:]
    var dirty = Set<Identity>()
    var compositeIndex: [Identity: CompositeNode] = [:]
    private var lastResolve = Date.distantPast
    private var frameTimes: [TimeInterval] = []
    var lastScriptCommand = ""
    private var verifiedFrames = 0
    private var verifyMismatches = 0
    private var damageArea = 0.0
    private var damageRects: [String: Int] = [:]
    private var frameWindowStart = Date()

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
    /// GTK zeichnet gerade (in `drawRetained`); Änderungen an echten Widgets warten bis zum nächsten Takt
    var isDrawing = false
    var fieldSyncPending = false

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
    func invalidate(_ id: Identity) { dirty.insert(id) }

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

    /// Das Fenster ist zerstört: GTK-Zeiger vergessen und den Ansichtsbaum samt Abonnements freigeben,
    /// damit kein Rückruf mehr ein zerstörtes Widget erreicht und beobachtete Objekte nichts mehr auslösen
    func shutdown() {
        window = nil
        drawingArea = nil
        fixed = nil
        fields.removeAll()
        fieldSpecs.removeAll()
        fieldHolders.removeAll()
        overlays.removeAll()
        hovered.removeAll()
        pressedNode = nil
        rootNode = nil
        compositeIndex.removeAll()
        dirty.removeAll()
        timelineIntervals.removeAll()
        timelineDue.removeAll()
        shortcuts.removeAll()
        store.removeAll()
        closeHandler = nil
    }

    /// Zeitgeber (16 ms): Hauptschlange bedienen, aufgelöste Änderungen und Zeitleisten verarbeiten
    func tick() {
        for hook in tickHooks { hook() }
        if tickCount == 5, ProcessInfo.processInfo.environment["DIGIDEC_TRACE_MAP"] != nil { FileHandle.standardError.write(Data("hooks \(tickHooks.count)\n".utf8)) }
        tickCount += 1
        if tickCount % 120 == 0, ProcessInfo.processInfo.environment["DIGIDEC_TRACE"] != nil { FileHandle.standardError.write(Data("tick \(tickCount) hooks \(tickHooks.count)\n".utf8)) }
        let t = Date()
        RunLoop.main.run(mode: .default, before: .distantPast)
        if ProcessInfo.processInfo.environment["DIGIDEC_TRACE"] != nil, Date().timeIntervalSince(t) > 0.05 { FileHandle.standardError.write(Data(String(format: "RunLoop %.0f ms\n", Date().timeIntervalSince(t) * 1000).utf8)) }
        let now = Date()
        if needsResolve { resolveAndLayout(); needsDraw = true }
        else {
            for (id, due) in timelineDue where now >= due { dirty.insert(id); timelineDue[id] = now.addingTimeInterval(timelineIntervals[id] ?? 1) }
            if !dirty.isEmpty, now.timeIntervalSince(lastDirtyRefresh) >= refreshThrottle {
                lastDirtyRefresh = now
                refreshDirty()
                refreshCost = refreshCost * 0.8 + Date().timeIntervalSince(now) * 0.2
            }
        }
        if fieldSyncPending { syncFields() }
        if let due = tooltipDue, now >= due, let tip = tooltip { tooltipDue = nil; addDamage(tooltipRect(tip)) }
        if needsDraw || !pendingDamage.isEmpty, let area = drawingArea {
            needsDraw = false
            dg_queue_draw(area)
        }
    }

    /// Kürzester Abstand zwischen zwei Auffrischungen: Bis 12 ms Gesamtkosten läuft alles ungebremst; wird es teurer, bleibt
    /// mindestens die Hälfte der Zeit frei für Eingaben (höchstens 120 ms)
    private var refreshThrottle: TimeInterval {
        let cost = drawCost + refreshCost
        return cost > 0.012 ? min(0.12, cost * 2) : 0
    }

    /// Löst nur die als geändert gemeldeten Ansichten neu auf; ändert sich dabei eine Größe, wird neu platziert (ohne neu aufzulösen)
    private func refreshDirty() {
        let ids = dirty
        dirty.removeAll()
        var relayout = false
        for id in ids {
            guard let node = compositeIndex[id] else { continue }
            let result = node.refresh()
            if !result.stable { relayout = true }
            else if Self.diffDamage { addDamage(old: result.previous, new: node.children) }
            else { for n in result.previous + node.children { addDamage(n.subtreeBounds()) } }
            node.walk { if let c = $0 as? CompositeNode { compositeIndex[c.identity] = c } }
        }
        if relayout, let root = rootNode {
            root.clearSizeCaches()
            root.place(origin: .zero, size: size)
            for layer in overlays { layout(layer) }
            needsDraw = true
        }
        syncFields()
    }

    /// Meldet einen Bereich als geändert (samt Rand für Schatten). Rechtecke, die sich berühren oder zusammen kaum mehr Fläche
    /// brauchen als einzeln, werden vereinigt; weit auseinanderliegende bleiben getrennt.
    func addDamage(_ rect: CGRect) {
        guard !rect.isNull, rect.width > 0 || rect.height > 0 else { return }
        var r = rect.insetBy(dx: -Self.damageMargin, dy: -Self.damageMargin)
        var merged = true
        while merged {
            merged = false
            for (i, e) in pendingDamage.enumerated() {
                let u = e.union(r)
                if e.intersects(r) || u.width * u.height <= 1.3 * (e.width * e.height + r.width * r.height) {
                    r = u; pendingDamage.remove(at: i); merged = true; break
                }
            }
        }
        pendingDamage.append(r)
        if pendingDamage.count > 12 { pendingDamage = [pendingDamage.dropFirst().reduce(pendingDamage[0]) { $0.union($1) }] }
    }

    // MARK: Zeichnen

    func draw(cr: OpaquePointer, width: Int, height: Int) {
        let drawStart = Date()
        defer { if traceFrames { traceFrame(Date().timeIntervalSince(drawStart)) } }
        let newSize = CGSize(width: width, height: height)
        if newSize != size || rootNode == nil {
            size = newSize
            resolveAndLayout()
        }
        prepareDrawBounds()
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

    /// Zeichnen in die dauerhaft gehaltene Fläche des Fensters: nur der ungültige Bereich wird neu gemalt
    func drawRetained(cr: OpaquePointer, width: Int, height: Int, fresh: Bool) {
        let drawStart = Date()
        isDrawing = true
        defer {
            isDrawing = false
            let seconds = Date().timeIntervalSince(drawStart)
            drawCost = drawCost * 0.8 + seconds * 0.2
            if traceFrames { traceFrame(seconds) }
        }
        let newSize = CGSize(width: width, height: height)
        if newSize != size || rootNode == nil {
            size = newSize
            resolveAndLayout()
            fullRedraw = true
        }
        if fresh || !overlays.isEmpty || !Self.partialAllowed { fullRedraw = true }
        let bounds = CGRect(origin: .zero, size: size)
        let regions: [CGRect] = fullRedraw ? [bounds] : pendingDamage.map { $0.integral.intersection(bounds) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        fullRedraw = false
        pendingDamage = []
        guard !regions.isEmpty else { return }
        paint(cr: cr, regions: regions, bounds: bounds, remember: true)
        if Self.verifyDamage, !(regions.count == 1 && regions[0] == bounds) { verify(cr: cr, regions: regions) }
    }

    private func prepareDrawBounds() {
        Node.drawBounds.removeAll(keepingCapacity: true)
        rootNode?.buildDrawBounds()
        for layer in overlays { layer.node?.buildDrawBounds() }
    }

    private func paint(cr: OpaquePointer, regions: [CGRect], bounds: CGRect, remember: Bool) {
        prepareDrawBounds()
        var g = GraphicsContext(cairo: cr, size: size)
        for region in regions {
            if remember, traceFrames { damageArea += Double(region.width * region.height) / Double(max(1, size.width * size.height)); damageRects[String(format: "%.0f,%.0f %.0fx%.0f", region.minX, region.minY, region.width, region.height), default: 0] += 1 }
            cairo_save(cr)
            cairo_rectangle(cr, region.minX, region.minY, region.width, region.height)
            cairo_clip(cr)
            cairo_set_source_rgba(cr, background.red, background.green, background.blue, 1)
            cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE)
            cairo_paint(cr)
            cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
            rootNode?.draw(&g, clip: region.insetBy(dx: -Self.damageMargin, dy: -Self.damageMargin))
            if region == bounds {
                for layer in overlays {
                    if layer.modal { g.fill(Path(bounds), with: .color(Color(white: 0, opacity: 0.45))) }
                    if let node = layer.node {
                        g.drawShadow(color: Color(white: 0, opacity: 0.5), radius: 12, x: 0, y: 4, bounds: node.frame) { inner in
                            inner.fill(Path(roundedRect: node.frame, cornerRadius: 8), with: .color(background.opacity(1)))
                        }
                        node.draw(&g, clip: bounds)
                    }
                }
            }
            cairo_restore(cr)
        }
        if remember { shownTooltipRect = .null }
        if let tip = tooltip, tooltipDue == nil {
            let rect = tooltipRect(tip)
            if remember { shownTooltipRect = rect }
            // Nur dort malen, wo darunter gerade neu gezeichnet wurde: sonst addiert sich der durchscheinende Rand von Bild zu Bild
            let touched = regions.filter { $0.intersects(rect.insetBy(dx: -2, dy: -2)) }
            if !touched.isEmpty {
                cairo_save(cr)
                for r in touched { cairo_rectangle(cr, r.minX, r.minY, r.width, r.height) }
                cairo_clip(cr)
                drawTooltip(&g, tip)
                cairo_restore(cr)
            }
        }
    }

    /// Selbstprüfung (`DIGIDEC_VERIFY_DAMAGE`): zeichnet das Bild zusätzlich vollständig und meldet Abweichungen vom Teilbild
    private static let verifyDamage = ProcessInfo.processInfo.environment["DIGIDEC_VERIFY_DAMAGE"] != nil
    private func verify(cr: OpaquePointer, regions: [CGRect]) {
        let target = cairo_get_target(cr)!
        cairo_surface_flush(target)
        guard let a = cairo_image_surface_get_data(target) else { return }
        let w = Int(cairo_image_surface_get_width(target)), h = Int(cairo_image_surface_get_height(target)), stride = Int(cairo_image_surface_get_stride(target))
        var sx = 1.0, sy = 1.0
        cairo_surface_get_device_scale(target, &sx, &sy)
        guard let scratch = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(w), Int32(h)) else { return }
        defer { cairo_surface_destroy(scratch) }
        cairo_surface_set_device_scale(scratch, sx, sy)
        let scr = cairo_create(scratch)!
        paint(cr: scr, regions: [CGRect(origin: .zero, size: size)], bounds: CGRect(origin: .zero, size: size), remember: false)
        cairo_destroy(scr)
        cairo_surface_flush(scratch)
        guard let b = cairo_image_surface_get_data(scratch) else { return }
        // Ein zweites Vollbild zeigt, welche Pixel von Bild zu Bild schwanken (Canvas mit Zufall oder Uhr): die zählen nicht
        let scratch2 = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(w), Int32(h))!
        defer { cairo_surface_destroy(scratch2) }
        cairo_surface_set_device_scale(scratch2, sx, sy)
        let scr2 = cairo_create(scratch2)!
        paint(cr: scr2, regions: [CGRect(origin: .zero, size: size)], bounds: CGRect(origin: .zero, size: size), remember: false)
        cairo_destroy(scr2)
        cairo_surface_flush(scratch2)
        guard let c = cairo_image_surface_get_data(scratch2) else { return }
        verifiedFrames += 1
        if verifiedFrames % 200 == 0 { FileHandle.standardError.write(Data("VERIFY \(verifiedFrames) Teilbilder geprüft, \(verifyMismatches) mit Abweichung\n".utf8)) }
        var count = 0, minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
        for y in 0..<h {
            let ra = a + y * stride, rb = b + y * stride, rc = c + y * stride
            for x in 0..<w {
                let i = x * 4
                let differs = abs(Int(ra[i]) - Int(rb[i])) > 8 || abs(Int(ra[i + 1]) - Int(rb[i + 1])) > 8 || abs(Int(ra[i + 2]) - Int(rb[i + 2])) > 8
                let stable = abs(Int(rb[i]) - Int(rc[i])) <= 3 && abs(Int(rb[i + 1]) - Int(rc[i + 1])) <= 3 && abs(Int(rb[i + 2]) - Int(rc[i + 2])) <= 3
                if differs && stable { count += 1; minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y) }
            }
        }
        if count > 0 {
            verifyMismatches += 1
            if verifyMismatches <= 2 {
                let p = CGPoint(x: Double(minX) / sx + 0.5, y: Double(minY) / sy + 0.5)
                var found: [String] = []
                var nodes: [Node] = []
                rootNode?.walk { n in if n.frame.insetBy(dx: -2, dy: -2).contains(p) { nodes.append(n) } }
                nodes.sort { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                found = nodes.prefix(6).map { "\(type(of: $0)) \($0.frame)" + (($0 as? TextNode).map { " „\($0.spec.text)“ \($0.spec.font.size)pt" } ?? "") }
                FileHandle.standardError.write(Data("VERIFY-Knoten bei \(p), letzter Skriptbefehl: \(lastScriptCommand):\n  \(found.joined(separator: "\n  "))\n".utf8))
                let i = minY * stride + minX * 4
                FileHandle.standardError.write(Data("  Teilbild \(a[i]),\(a[i+1]),\(a[i+2]) Vollbild \(b[i]),\(b[i+1]),\(b[i+2])\n".utf8))
            }
            let r = { (v: Int, s: Double) in Int(Double(v) / s) }
            FileHandle.standardError.write(Data("VERIFY \(count) px abweichend in (\(r(minX, sx)),\(r(minY, sy))–\(r(maxX, sx)),\(r(maxY, sy))), neu gezeichnet: \(regions.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" })\n".utf8))
        }
    }

    private var traceFrames: Bool { Self.frameTrace }
    private static let frameTrace = ProcessInfo.processInfo.environment["DIGIDEC_TRACE_FRAMES"] != nil
    private func traceFrame(_ seconds: TimeInterval) {
        frameTimes.append(seconds)
        let now = Date()
        if now.timeIntervalSince(frameWindowStart) >= 2 {
            let sorted = frameTimes.sorted()
            let avg = frameTimes.reduce(0, +) / Double(frameTimes.count)
            FileHandle.standardError.write(Data(String(format: "frames %d in 2 s, draw avg %.1f ms, p95 %.1f ms, max %.1f ms\n", frameTimes.count, avg * 1000, sorted[Int(Double(sorted.count - 1) * 0.95)] * 1000, (sorted.last ?? 0) * 1000).utf8))
            if shapeProfile {
                var total = 0.0
                for (_, v) in shapeProfileData { total += v.0 }
                FileHandle.standardError.write(Data(String(format: "shapes total %.0f ms per 2 s\n", total).utf8))
                for (k, v) in shapeProfileData.sorted(by: { $0.value.0 > $1.value.0 }).prefix(10) { FileHandle.standardError.write(Data(String(format: "  %7.1f ms  %5d calls  %@\n", v.0, v.1, k).utf8)) }
                shapeProfileData.removeAll()
            }
            FileHandle.standardError.write(Data(String(format: "  damage avg %.0f %% of window\n", damageArea / Double(frameTimes.count) * 100).utf8))
            for (k, v) in damageRects.sorted(by: { $0.value > $1.value }).prefix(5) { FileHandle.standardError.write(Data("    \(v)x \(k)\n".utf8)) }
            damageArea = 0; damageRects.removeAll()
            frameTimes.removeAll(keepingCapacity: true)
            frameWindowStart = now
        }
    }

    private func tooltipSpec(_ tip: (text: String, at: CGPoint)) -> TextSpec {
        TextSpec(text: tip.text, font: .system(size: 11), color: Color(white: 0.95), lineLimit: nil, tracking: 0, minScale: 1, alignment: .leading, underline: false, strikethrough: false)
    }

    private func tooltipRect(_ tip: (text: String, at: CGPoint)) -> CGRect {
        let m = TextEngine.measure(tooltipSpec(tip), width: 360)
        return CGRect(x: min(tip.at.x + 12, size.width - m.size.width - 16), y: min(tip.at.y + 18, size.height - m.size.height - 12), width: m.size.width + 12, height: m.size.height + 8)
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
        // Handler ändern ihren Zustand über @State & Co. und melden damit selbst, was neu gezeichnet werden muss
        for n in nodes { n.handlers?.motion?(p) }
        for (id, n) in hovered where now[id] == nil { n.handlers?.hover?(false) }
        for (id, n) in now where hovered[id] == nil { n.handlers?.hover?(true) }
        hovered = now
        // Hilfetext nach kurzer Ruhe; neu zeichnen nur, wenn einer zu sehen war
        if !shownTooltipRect.isNull { addDamage(shownTooltipRect); shownTooltipRect = .null }
        tooltip = nil
        if let help = nodes.first(where: { $0.handlers?.help != nil })?.handlers?.help, pressedNode == nil, overlays.isEmpty {
            tooltip = (help, p)
            tooltipDue = Date().addingTimeInterval(0.7)
        } else { tooltipDue = nil }
        if let target = pressedNode, let drag = target.handlers?.drag, let start = dragStart {
            if !dragActive, hypot(p.x - start.x, p.y - start.y) >= drag.minimumDistance { dragActive = true }
            if dragActive { drag.changed?(DragValue(location: p, startLocation: start)) }
        }
        if !overlays.isEmpty { needsDraw = true }
    }

    func pointerLeft() {
        for (_, n) in hovered { n.handlers?.hover?(false) }
        hovered.removeAll()
        if !shownTooltipRect.isNull { addDamage(shownTooltipRect); shownTooltipRect = .null }
        tooltip = nil
    }

    func pressed(_ p: CGPoint, button: Int) {
        pointer = p
        if !shownTooltipRect.isNull { addDamage(shownTooltipRect); shownTooltipRect = .null }
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
