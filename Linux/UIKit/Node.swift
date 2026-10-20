// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Knotenbaum: Aus den Ansichtswerten entsteht ein Baum aus `Node`. Jeder Knoten kann seine Größe für einen Vorschlag nennen,
// sich samt Kindern platzieren und zeichnen. Das Vorgehen entspricht SwiftUI: Der Elternknoten schlägt eine Größe vor, das Kind antwortet.
import Foundation
import CGtkCairo

// MARK: - Layouttypen

public struct EdgeInsets: Equatable {
    public var top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat
    public init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
        self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
    }
    public init(_ all: CGFloat) { self.init(top: all, leading: all, bottom: all, trailing: all) }
}

public enum Edge: Int8, Sendable {
    case top, leading, bottom, trailing
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let top = Set(rawValue: 1), leading = Set(rawValue: 2), bottom = Set(rawValue: 4), trailing = Set(rawValue: 8)
        public static let horizontal: Set = [.leading, .trailing]
        public static let vertical: Set = [.top, .bottom]
        public static let all: Set = [.top, .leading, .bottom, .trailing]
    }
}

public enum Axis: Sendable {
    case horizontal, vertical
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let horizontal = Set(rawValue: 1), vertical = Set(rawValue: 2)
    }
}

public struct HorizontalAlignment: Equatable, Sendable {
    let id: Int
    public static let leading = HorizontalAlignment(id: 0)
    public static let center = HorizontalAlignment(id: 1)
    public static let trailing = HorizontalAlignment(id: 2)
    func offset(in free: CGFloat) -> CGFloat { id == 0 ? 0 : (id == 1 ? free / 2 : free) }
}

public struct VerticalAlignment: Equatable, Sendable {
    let id: Int
    public static let top = VerticalAlignment(id: 0)
    public static let center = VerticalAlignment(id: 1)
    public static let bottom = VerticalAlignment(id: 2)
    public static let firstTextBaseline = VerticalAlignment(id: 3)
    public static let lastTextBaseline = VerticalAlignment(id: 4)
    func offset(in free: CGFloat) -> CGFloat { id == 0 ? 0 : (id == 1 ? free / 2 : free) }
    var isBaseline: Bool { id >= 3 }
}

public struct Alignment: Equatable, Sendable {
    public var horizontal: HorizontalAlignment
    public var vertical: VerticalAlignment
    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment) { self.horizontal = horizontal; self.vertical = vertical }
    public static let center = Alignment(horizontal: .center, vertical: .center)
    public static let leading = Alignment(horizontal: .leading, vertical: .center)
    public static let trailing = Alignment(horizontal: .trailing, vertical: .center)
    public static let top = Alignment(horizontal: .center, vertical: .top)
    public static let bottom = Alignment(horizontal: .center, vertical: .bottom)
    public static let topLeading = Alignment(horizontal: .leading, vertical: .top)
    public static let topTrailing = Alignment(horizontal: .trailing, vertical: .top)
    public static let bottomLeading = Alignment(horizontal: .leading, vertical: .bottom)
    public static let bottomTrailing = Alignment(horizontal: .trailing, vertical: .bottom)
}

/// Vorschlag des Elternknotens; `nil` = ideale Größe, `.infinity` = so groß wie möglich
struct Proposal: Hashable {
    var width: CGFloat?
    var height: CGFloat?
    static let unspecified = Proposal(width: nil, height: nil)
    static func fixed(_ s: CGSize) -> Proposal { Proposal(width: s.width, height: s.height) }
    func with(_ axis: Axis, _ v: CGFloat?) -> Proposal {
        axis == .horizontal ? Proposal(width: v, height: height) : Proposal(width: width, height: v)
    }
    func along(_ axis: Axis) -> CGFloat? { axis == .horizontal ? width : height }
}

extension CGSize {
    func along(_ axis: Axis) -> CGFloat { axis == .horizontal ? width : height }
    static func make(_ axis: Axis, main: CGFloat, cross: CGFloat) -> CGSize {
        axis == .horizontal ? CGSize(width: main, height: cross) : CGSize(width: cross, height: main)
    }
}

extension CGFloat {
    var finite: CGFloat { isFinite ? self : 0 }
}

// MARK: - Knoten

/// Behandler für Zeigerereignisse eines Knotens
struct Handlers {
    var tap: (() -> Void)?
    var press: ((Bool) -> Void)?          // true beim Drücken, false beim Loslassen
    var hover: ((Bool) -> Void)?
    var drag: DragHandler?
    var scroll: ((CGFloat, CGFloat) -> Bool)?
    var motion: ((CGPoint) -> Void)?
    var help: String?
    var keyboardShortcut: (key: Character, command: Bool)?
}

struct DragHandler {
    var minimumDistance: CGFloat = 0
    var changed: ((DragValue) -> Void)?
    var ended: ((DragValue) -> Void)?
}

public struct DragValue {
    public var location: CGPoint
    public var startLocation: CGPoint
    public var translation: CGSize { CGSize(width: location.x - startLocation.x, height: location.y - startLocation.y) }
}

@MainActor
class Node {
    let identity: Identity
    var children: [Node] = []
    var frame: CGRect = .zero
    var handlers: Handlers?
    var enabled = true
    var layoutPriority: Double = 0
    /// Kennung für `ScrollViewReader.scrollTo` und `.id()`
    var explicitID: AnyHashable?
    /// Kontextmenü (Rechtsklick)
    var contextMenu: ((CGPoint) -> Void)?
    private var sizeCache: [Proposal: CGSize] = [:]

    init(identity: Identity) { self.identity = identity }

    final func size(for proposal: Proposal) -> CGSize {
        if let s = sizeCache[proposal] { return s }
        let s = computeSize(proposal)
        sizeCache[proposal] = s
        return s
    }

    func computeSize(_ proposal: Proposal) -> CGSize { .zero }

    /// Verwirft die gemerkten Größen dieses Knotens und aller Nachfahren (nach einer Änderung von Inhalten)
    final func clearSizeCaches() {
        sizeCache.removeAll(keepingCapacity: true)
        for c in children { c.clearSizeCaches() }
    }

    /// Ort des ersten Textgrundlinie ab Oberkante (für `firstTextBaseline`), nil = Unterkante
    var firstBaseline: CGFloat? { children.first?.firstBaseline }

    /// Setzt den Rahmen (absolute Koordinaten) und platziert die Kinder
    func place(origin: CGPoint, size: CGSize) {
        frame = CGRect(origin: origin, size: size)
        placeChildren()
    }

    func placeChildren() {
        for c in children { c.place(origin: frame.origin, size: c.size(for: .fixed(frame.size))) }
    }

    func draw(_ g: inout GraphicsContext, clip: CGRect) {
        drawChildren(&g, clip: clip)
    }

    final func drawChildren(_ g: inout GraphicsContext, clip: CGRect) {
        for c in children {
            // Kinder dürfen über den Rahmen ihres Elternknotens hinausragen: ausgesondert wird nach den Grenzen des ganzen Teilbaums
            let b = Node.drawBounds[ObjectIdentifier(c)] ?? c.frame
            if b.intersects(clip) || b.isEmpty { c.draw(&g, clip: clip) }
        }
    }

    /// Grenzen der Teilbäume für das Aussondern beim Zeichnen; wird vor jedem Zeichnen neu aufgebaut
    nonisolated(unsafe) static var drawBounds: [ObjectIdentifier: CGRect] = [:]

    @discardableResult
    final func buildDrawBounds() -> CGRect {
        var r = frame
        for c in children { let b = c.buildDrawBounds(); if !b.isEmpty { r = r.isEmpty ? b : r.union(b) } }
        Node.drawBounds[ObjectIdentifier(self)] = r
        return r
    }

    /// Umschließendes Rechteck dieses Knotens und aller Nachfahren (Kinder dürfen über den Rahmen hinausragen)
    final func subtreeBounds() -> CGRect {
        var r = frame
        for c in children { let b = c.subtreeBounds(); if !b.isEmpty { r = r.isEmpty ? b : r.union(b) } }
        return r
    }

    /// Alle Knoten an einem Punkt, der tiefste zuerst
    func hit(_ p: CGPoint, into chain: inout [Node]) {
        guard frame.contains(p) || frame.isEmpty && false else {
            // Kinder dürfen außerhalb des eigenen Rahmens liegen (z. B. versetzte Ansichten); nur beschneidende Knoten sperren
            if !clipsHits { for c in children.reversed() { c.hit(p, into: &chain) } }
            return
        }
        for c in children.reversed() { c.hit(p, into: &chain) }
        if handlers != nil { chain.append(self) }
    }

    var clipsHits: Bool { false }

    /// Ruft `body` für diesen Knoten und alle Nachfahren auf
    final func walk(_ body: (Node) -> Void) {
        body(self)
        for c in children { c.walk(body) }
    }
}

/// Knoten, der nur sein erstes Kind weiterreicht (Grundlage für Modifikatoren)
@MainActor
class WrapperNode: Node {
    var child: Node? { children.first }
    init(identity: Identity, child: Node?) {
        super.init(identity: identity)
        if let child { children = [child] }
    }
    override func computeSize(_ proposal: Proposal) -> CGSize { child?.size(for: proposal) ?? .zero }
}

/// Knoten einer zusammengesetzten Ansicht (mit Körper). Er kann seinen Inhalt allein neu auflösen, wenn sich Zustand oder
/// beobachtete Objekte ändern, ohne dass der ganze Baum neu aufgebaut wird.
@MainActor
final class CompositeNode: Node {
    var rebuild: (() -> [Node])?
    var lastProposal = Proposal.unspecified

    override func computeSize(_ p: Proposal) -> CGSize {
        lastProposal = p
        if children.count == 1 { return children[0].size(for: p) }
        var w: CGFloat = 0, h: CGFloat = 0
        for c in children { let s = c.size(for: p); w = max(w, s.width); h += s.height }
        return CGSize(width: w, height: h)
    }

    override var firstBaseline: CGFloat? { children.first?.firstBaseline }

    override func placeChildren() {
        if children.count == 1 { children[0].place(origin: frame.origin, size: children[0].size(for: .fixed(frame.size))); return }
        var y = frame.minY
        for c in children {
            let s = c.size(for: .fixed(frame.size))
            c.place(origin: CGPoint(x: frame.minX + (frame.width - s.width) / 2, y: y), size: s)
            y += s.height
        }
    }

    /// Löst den Inhalt neu auf; `stable` ist wahr, wenn die Größe gleich blieb (dann genügt Neuplatzieren und Zeichnen).
    /// `previous` sind die bisherigen Kinder, für den Vergleich zwischen altem und neuem Bild.
    func refresh() -> (stable: Bool, previous: [Node]) {
        guard let rebuild else { return (true, children) }
        let old = frame.size
        let previous = children
        children = rebuild()
        clearSizeCaches()
        let new = size(for: lastProposal)
        if new == old { placeChildren(); return (true, previous) }
        return (false, previous)
    }
}

/// Mehrere Wurzeln einer Ansicht zusammen, wenn eine Ansicht mehrere Knoten liefert (z. B. TupleView als Körper)
@MainActor
final class GroupNode: Node {}

// MARK: - Auflösung

@MainActor
final class Resolver {
    let store: StateStore
    weak var host: UIHost?
    var identity = Identity.root
    var env = EnvironmentValues()
    /// Auflösungsrunde (zum Aufräumen des Zustandsspeichers)
    var invalidate: () -> Void = {}

    init(store: StateStore, host: UIHost?) {
        self.store = store
        self.host = host
    }

    func resolve<V: View, K: Hashable>(_ view: V, key: K) -> [Node] {
        let saved = identity
        identity = identity.child(key)
        defer { identity = saved }
        return resolveHere(view)
    }

    func resolveSingle<V: View, K: Hashable>(_ view: V, key: K) -> Node {
        let nodes = resolve(view, key: key)
        if nodes.count == 1 { return nodes[0] }
        let g = GroupNode(identity: identity.child(key).child("group"))
        g.children = nodes
        return GroupStack.wrap(g, identity: identity.child(key))
    }

    private func resolveHere<V: View>(_ view: V) -> [Node] {
        if let p = view as? any PrimitiveView {
            attachDynamicProperties(view)
            return p.makeNodes(self)
        }
        let node = CompositeNode(identity: identity)
        let savedIdentity = identity, savedEnv = env
        node.rebuild = { [self] in
            let outerIdentity = identity, outerEnv = env
            identity = savedIdentity; env = savedEnv
            defer { identity = outerIdentity; env = outerEnv }
            attachDynamicProperties(view)
            return resolve(view.body, key: 0)
        }
        node.children = node.rebuild!()
        return [node]
    }

    /// Ein Knoten, der sich allein neu auflösen kann (für Grundansichten mit eigenem Zustand wie Button und TimelineView)
    func refreshable(_ make: @escaping () -> [Node]) -> [Node] {
        let node = CompositeNode(identity: identity)
        let savedIdentity = identity, savedEnv = env
        node.rebuild = { [self] in
            let outerIdentity = identity, outerEnv = env
            identity = savedIdentity; env = savedEnv
            defer { identity = outerIdentity; env = outerEnv }
            return make()
        }
        node.children = node.rebuild!()
        return [node]
    }

    /// Ansichtstypen ohne Eigenschaftshüllen (@State & Co.): Für sie lohnt die Reflexion nicht, die Felder eines Typs sind fest
    nonisolated(unsafe) private static var withoutDynamicProperties = Set<ObjectIdentifier>()

    private func attachDynamicProperties<V: View>(_ view: V) {
        let typeKey = ObjectIdentifier(V.self)
        if Resolver.withoutDynamicProperties.contains(typeKey) { return }
        let id = identity
        let context = AttachContext(store: store, identity: id, environment: env, invalidate: { [weak self] in self?.host?.invalidate(id) })
        var index = 0
        for child in Mirror(reflecting: view).children {
            if let p = child.value as? any DynamicProperty {
                p.attach(context, index: index)
                index += 1
            }
        }
        if index == 0 { Resolver.withoutDynamicProperties.insert(typeKey) }
    }

    /// Hilfsfunktion für Modifikatoren: Kind auflösen und als einzelnen Knoten liefern (mehrere werden gestapelt)
    func content<V: View>(_ view: V, key: Int = 0) -> Node { resolveSingle(view, key: key) }
}

/// Mehrere Knoten ohne Stapel (Körper mit mehreren Wurzeln) verhalten sich wie ein VStack ohne Abstand
@MainActor
enum GroupStack {
    static func wrap(_ g: GroupNode, identity: Identity) -> Node {
        let s = StackNode(identity: identity, axis: .vertical, alignment: .center, spacing: 0)
        s.children = g.children
        return s
    }
}
