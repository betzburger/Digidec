// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// ScrollView und ScrollViewReader.
import Foundation
import CGtkCairo

public typealias UnitPointAlias = UnitPoint

/// Verbindung zwischen ScrollViewReader und dem Rollknoten darin
@MainActor
final class ScrollProxyBox {
    var scrollIdentity: Identity?
    var store: StateStore?
    var host: UIHost?
}

private struct ScrollProxyKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue: ScrollProxyBox? = nil }
extension EnvironmentValues { var scrollProxy: ScrollProxyBox? { get { self[ScrollProxyKey.self] } set { self[ScrollProxyKey.self] = newValue } } }

@MainActor
public struct ScrollViewProxy {
    let box: ScrollProxyBox
    public func scrollTo<ID: Hashable>(_ id: ID, anchor: UnitPoint? = nil) {
        guard let identity = box.scrollIdentity, let store = box.store else { return }
        store.interaction[identity, default: [:]]["pendingScroll"] = (AnyHashable(id), anchor ?? UnitPoint(x: 0.5, y: 0.5))
        box.host?.setNeedsResolve()
    }
}

public struct ScrollViewReader<Content: View> {
    let content: (ScrollViewProxy) -> Content
    public init(@ViewBuilder content: @escaping (ScrollViewProxy) -> Content) { self.content = content }
    @MainActor func makeNodes(_ r: Resolver) -> [Node] {
        let box = ScrollProxyBox()
        box.store = r.store
        box.host = r.host
        let saved = r.env.scrollProxy
        r.env.scrollProxy = box
        defer { r.env.scrollProxy = saved }
        return r.resolve(content(ScrollViewProxy(box: box)), key: 0)
    }
}

public struct ScrollView<Content: View> {
    let axes: Axis.Set
    let content: Content
    public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) { self.axes = axes; self.content = content() }

    @MainActor func makeNodes(_ r: Resolver) -> [Node] {
        let node = ScrollNode(identity: r.identity, axes: axes, store: r.store, host: r.host)
        node.children = [r.content(content)]
        r.env.scrollProxy?.scrollIdentity = r.identity
        r.store.touchInteraction(r.identity)
        return [node]
    }
}

@MainActor
final class ScrollNode: Node {
    let axes: Axis.Set
    let store: StateStore
    weak var host: UIHost?
    private var contentSize: CGSize = .zero
    private(set) var offset = CGPoint.zero

    init(identity: Identity, axes: Axis.Set, store: StateStore, host: UIHost?) {
        self.axes = axes; self.store = store; self.host = host
        super.init(identity: identity)
        offset = (store.interaction[identity]?["offset"] as? CGPoint) ?? .zero
        handlers = Handlers(scroll: { [unowned self] dx, dy in self.scrollBy(dx: dx, dy: dy) })
    }

    override var clipsHits: Bool { true }

    private var vertical: Bool { axes.contains(.vertical) }
    private var horizontal: Bool { axes.contains(.horizontal) }

    override func computeSize(_ p: Proposal) -> CGSize {
        let content = children[0].size(for: Proposal(width: horizontal ? nil : p.width, height: vertical ? nil : p.height))
        let w = (p.width.flatMap { $0.isFinite ? $0 : nil }) ?? content.width
        let h = (p.height.flatMap { $0.isFinite ? $0 : nil }) ?? content.height
        return CGSize(width: horizontal ? w : min(w, max(content.width, p.width.flatMap { $0.isFinite ? $0 : nil } ?? content.width)), height: vertical ? h : h)
    }

    override func placeChildren() {
        let child = children[0]
        var cs = child.size(for: Proposal(width: horizontal ? nil : frame.width, height: vertical ? nil : frame.height))
        if vertical { cs.width = max(cs.width, horizontal ? cs.width : frame.width) }
        if horizontal { cs.height = max(cs.height, frame.height) }
        contentSize = cs
        if let (id, anchor) = store.interaction[identity]?["pendingScroll"] as? (AnyHashable, UnitPoint) {
            store.interaction[identity]?["pendingScroll"] = nil
            child.place(origin: CGPoint(x: frame.minX - offset.x, y: frame.minY - offset.y), size: cs)
            if let target = find(id, in: child) {
                let rel = CGPoint(x: target.frame.minX - (frame.minX - offset.x), y: target.frame.minY - (frame.minY - offset.y))
                if vertical { offset.y = rel.y - (frame.height - target.frame.height) * anchor.y }
                if horizontal { offset.x = rel.x - (frame.width - target.frame.width) * anchor.x }
            }
        }
        clampOffset()
        child.place(origin: CGPoint(x: frame.minX - offset.x, y: frame.minY - offset.y), size: cs)
        store.interaction[identity, default: [:]]["offset"] = offset
    }

    private func find(_ id: AnyHashable, in node: Node) -> Node? {
        if node.explicitID == id { return node }
        for c in node.children { if let f = find(id, in: c) { return f } }
        return nil
    }

    private func clampOffset() {
        offset.y = vertical ? min(max(0, offset.y), max(0, contentSize.height - frame.height)) : 0
        offset.x = horizontal ? min(max(0, offset.x), max(0, contentSize.width - frame.width)) : 0
    }

    func scrollBy(dx: CGFloat, dy: CGFloat) -> Bool {
        let before = offset
        offset.y += dy; offset.x += dx
        clampOffset()
        guard offset != before else { return false }
        store.interaction[identity, default: [:]]["offset"] = offset
        children[0].place(origin: CGPoint(x: frame.minX - offset.x, y: frame.minY - offset.y), size: contentSize)
        host?.setNeedsDraw()
        return true
    }

    override func draw(_ g: inout GraphicsContext, clip: CGRect) {
        let cr = g.cr
        cairo_save(cr)
        cairo_rectangle(cr, frame.minX, frame.minY, frame.width, frame.height)
        cairo_clip(cr)
        children[0].draw(&g, clip: clip.intersection(frame))
        cairo_restore(cr)
        // Rollbalken
        if vertical, contentSize.height > frame.height + 1 {
            let h = max(24, frame.height * frame.height / contentSize.height)
            let y = frame.minY + (frame.height - h) * (offset.y / max(1, contentSize.height - frame.height))
            g.fill(Path(roundedRect: CGRect(x: frame.maxX - 6, y: y + 1, width: 4, height: h - 2), cornerRadius: 2), with: .color(Color(white: 1, opacity: 0.28)))
        }
        if horizontal, contentSize.width > frame.width + 1 {
            let w = max(24, frame.width * frame.width / contentSize.width)
            let x = frame.minX + (frame.width - w) * (offset.x / max(1, contentSize.width - frame.width))
            g.fill(Path(roundedRect: CGRect(x: x + 1, y: frame.maxY - 6, width: w - 2, height: 4), cornerRadius: 2), with: .color(Color(white: 1, opacity: 0.28)))
        }
    }
}

// Konformitäten als Erweiterung, damit die Typen nicht auf den Hauptakteur isoliert werden (wie in SwiftUI)
extension ScrollViewReader: PrimitiveView {}
extension ScrollView: PrimitiveView {}
