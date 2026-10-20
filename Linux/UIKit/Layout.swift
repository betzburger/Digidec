// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// ViewModifier und das Layout-Protokoll (eigene Anordnungen wie ButtonGridLayout, FlowLayout).
import Foundation

// MARK: - ViewModifier

@MainActor
public protocol ViewModifier {
    associatedtype Body: View
    typealias Content = _ViewModifier_Content<Self>
    @ViewBuilder func body(content: Content) -> Body
}

public struct _ViewModifier_Content<M> {
    let view: any View
    @MainActor func makeNodes(_ r: Resolver) -> [Node] { r.resolve(view, key: 0) }
}

struct ModifiedContent<Content: View, M: ViewModifier> {
    let content: Content
    let modifier: M
    @MainActor func makeNodes(_ r: Resolver) -> [Node] {
        r.resolve(modifier.body(content: _ViewModifier_Content<M>(view: content)), key: 0)
    }
}

nonisolated extension View {
    public func modifier<M: ViewModifier>(_ modifier: M) -> some View { ModifiedContent(content: self, modifier: modifier) }
}

// MARK: - Layout

public struct ProposedViewSize: Equatable, Sendable {
    public var width: CGFloat?
    public var height: CGFloat?
    public init(width: CGFloat?, height: CGFloat?) { self.width = width; self.height = height }
    public init(_ size: CGSize) { width = size.width; height = size.height }
    public static let zero = ProposedViewSize(width: 0, height: 0)
    public static let unspecified = ProposedViewSize(width: nil, height: nil)
    public static let infinity = ProposedViewSize(width: .infinity, height: .infinity)
    public func replacingUnspecifiedDimensions(by size: CGSize = CGSize(width: 10, height: 10)) -> CGSize { CGSize(width: width ?? size.width, height: height ?? size.height) }
    var proposal: Proposal { Proposal(width: width, height: height) }
}

public struct UnitPointAnchor {}

@MainActor
public struct LayoutSubview {
    let node: Node
    public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { node.size(for: proposal.proposal) }
    public func place(at position: CGPoint, anchor: UnitPoint = .topLeading, proposal: ProposedViewSize) {
        let size = node.size(for: proposal.proposal)
        node.place(origin: CGPoint(x: position.x - size.width * anchor.x, y: position.y - size.height * anchor.y), size: size)
    }
    public var priority: Double { node.layoutPriority }
    public var dimensions: ViewDimensions { ViewDimensions(size: node.size(for: .unspecified)) }
}

public struct ViewDimensions {
    let size: CGSize
    public var width: CGFloat { size.width }
    public var height: CGFloat { size.height }
}

public struct LayoutSubviews: RandomAccessCollection {
    let items: [LayoutSubview]
    public var startIndex: Int { 0 }
    public var endIndex: Int { items.count }
    public subscript(position: Int) -> LayoutSubview { items[position] }
}

@MainActor
public protocol Layout: Animatable_ {
    associatedtype Cache = Void
    typealias Subviews = LayoutSubviews
    func makeCache(subviews: Subviews) -> Cache
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache)
}

public protocol Animatable_ {}

extension Layout where Cache == Void {
    public func makeCache(subviews: Subviews) -> Cache { () }
}

extension Layout {
    public func callAsFunction<Content: View>(@ViewBuilder _ content: () -> Content) -> some View { LayoutView(layout: self, content: content()) }
}

struct LayoutView<L: Layout, Content: View> {
    let layout: L
    let content: Content
    @MainActor func makeNodes(_ r: Resolver) -> [Node] {
        let node = CustomLayoutNode(identity: r.identity, layout: layout)
        node.children = r.resolve(content, key: 0)
        return [node]
    }
}

/// Knoten, die nur Kinder anordnen und selbst nichts zeichnen (für den Bildvergleich)
protocol PureLayoutNode {}

@MainActor
final class CustomLayoutNode<L: Layout>: Node, PureLayoutNode {
    let layout: L
    init(identity: Identity, layout: L) { self.layout = layout; super.init(identity: identity) }
    private var subviews: LayoutSubviews { LayoutSubviews(items: children.map { LayoutSubview(node: $0) }) }
    override func computeSize(_ p: Proposal) -> CGSize {
        var cache = layout.makeCache(subviews: subviews)
        return layout.sizeThatFits(proposal: ProposedViewSize(width: p.width, height: p.height), subviews: subviews, cache: &cache)
    }
    override func placeChildren() {
        var cache = layout.makeCache(subviews: subviews)
        layout.placeSubviews(in: frame, proposal: ProposedViewSize(frame.size), subviews: subviews, cache: &cache)
    }
}

// Konformitäten als Erweiterung, damit die Typen nicht auf den Hauptakteur isoliert werden (wie in SwiftUI)
extension _ViewModifier_Content: PrimitiveView {}
extension ModifiedContent: PrimitiveView {}
extension LayoutView: PrimitiveView {}
