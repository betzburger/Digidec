// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Stapel-Ansichten und die Layout-Modifikatoren (frame, padding, background …).
import Foundation

private struct StackAxisKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue: Axis? = nil }
extension EnvironmentValues {
    var stackAxis: Axis? { get { self[StackAxisKey.self] } set { self[StackAxisKey.self] = newValue } }
}

// MARK: - Stapel

public struct VStack<Content: View> {
    let alignment: HorizontalAlignment, spacing: CGFloat?, content: Content
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment; self.spacing = spacing; self.content = content()
    }
    @MainActor func makeNodes(_ r: Resolver) -> [Node] {
        let node = StackNode(identity: r.identity, axis: .vertical, alignment: Alignment(horizontal: alignment, vertical: .center), spacing: spacing ?? 8)
        let saved = r.env.stackAxis
        r.env.stackAxis = .vertical
        node.children = r.resolve(content, key: 0)
        r.env.stackAxis = saved
        return [node]
    }
}

public struct HStack<Content: View> {
    let alignment: VerticalAlignment, spacing: CGFloat?, content: Content
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment; self.spacing = spacing; self.content = content()
    }
    @MainActor func makeNodes(_ r: Resolver) -> [Node] {
        let node = StackNode(identity: r.identity, axis: .horizontal, alignment: Alignment(horizontal: .center, vertical: alignment), spacing: spacing ?? 8)
        let saved = r.env.stackAxis
        r.env.stackAxis = .horizontal
        node.children = r.resolve(content, key: 0)
        r.env.stackAxis = saved
        return [node]
    }
}

public typealias LazyVStack = VStack
public typealias LazyHStack = HStack

public struct ZStack<Content: View> {
    let alignment: Alignment, content: Content
    public init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) { self.alignment = alignment; self.content = content() }
    @MainActor func makeNodes(_ r: Resolver) -> [Node] {
        let node = ZStackNode(identity: r.identity, alignment: alignment)
        node.children = r.resolve(content, key: 0)
        return [node]
    }
}

public struct Spacer {
    let minLength: CGFloat?
    public init(minLength: CGFloat? = nil) { self.minLength = minLength }
    @MainActor func makeNodes(_ r: Resolver) -> [Node] { [SpacerNode(identity: r.identity, minLength: minLength ?? 8, axis: r.env.stackAxis)] }
}

// MARK: - Allgemeine Modifikatoren

struct Modified<Content: View> {
    let content: Content
    let make: @MainActor (Resolver, Node) -> Node
    @MainActor func makeNodes(_ r: Resolver) -> [Node] { [make(r, r.content(content))] }
}

nonisolated extension View {
    func modify(_ make: @escaping @MainActor (Resolver, Node) -> Node) -> some View { Modified(content: self, make: make) }

    public func frame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        modify { r, child in
            let n = FrameNode(identity: r.identity, child: child)
            n.width = width; n.height = height; n.alignment = alignment
            return n
        }
    }

    public func frame(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
                      minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        modify { r, child in
            let n = FrameNode(identity: r.identity, child: child)
            n.minWidth = minWidth; n.idealWidth = idealWidth; n.maxWidth = maxWidth
            n.minHeight = minHeight; n.idealHeight = idealHeight; n.maxHeight = maxHeight
            n.alignment = alignment
            return n
        }
    }

    public func padding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> some View {
        let l = length ?? 8
        return modify { r, child in
            let n = PaddingNode(identity: r.identity, child: child)
            n.insets = EdgeInsets(top: edges.contains(.top) ? l : 0, leading: edges.contains(.leading) ? l : 0,
                                  bottom: edges.contains(.bottom) ? l : 0, trailing: edges.contains(.trailing) ? l : 0)
            return n
        }
    }

    public func padding(_ length: CGFloat) -> some View { padding(.all, length) }

    public func padding(_ insets: EdgeInsets) -> some View {
        modify { r, child in
            let n = PaddingNode(identity: r.identity, child: child)
            n.insets = insets
            return n
        }
    }

    public func fixedSize(horizontal: Bool = true, vertical: Bool = true) -> some View {
        modify { r, child in
            let n = FixedSizeNode(identity: r.identity, child: child)
            n.horizontal = horizontal; n.vertical = vertical
            return n
        }
    }

    public func layoutPriority(_ priority: Double) -> some View {
        modify { r, child in
            let n = IDNode(identity: r.identity, child: child)
            n.layoutPriority = priority
            return n
        }
    }

    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> some View {
        modify { r, child in
            let n = OffsetNode(identity: r.identity, child: child)
            n.dx = x; n.dy = y
            return n
        }
    }

    public func position(x: CGFloat, y: CGFloat) -> some View {
        modify { r, child in
            let n = PositionNode(identity: r.identity, child: child)
            n.x = x; n.y = y
            return n
        }
    }

    public func opacity(_ value: Double) -> some View { modify { r, c in DecorNode(identity: r.identity, child: c, kind: .opacity(value)) } }
    public func clipped() -> some View { modify { r, c in DecorNode(identity: r.identity, child: c, kind: .clip(cornerRadius: 0)) } }
    public func cornerRadius(_ radius: CGFloat) -> some View { modify { r, c in DecorNode(identity: r.identity, child: c, kind: .clip(cornerRadius: radius)) } }
    public func clipShape<S: Shape>(_ shape: S) -> some View {
        modify { r, c in DecorNode(identity: r.identity, child: c, kind: .clipPath({ rect in shape.path(in: rect) })) }
    }
    public func shadow(color: Color = Color(white: 0, opacity: 0.33), radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some View {
        modify { r, c in DecorNode(identity: r.identity, child: c, kind: .shadow(color: color, radius: radius, x: x, y: y)) }
    }
    public func rotationEffect(_ angle: Angle) -> some View { modify { r, c in DecorNode(identity: r.identity, child: c, kind: .rotate(angle: angle.radians)) } }
    public func scaleEffect(_ scale: CGFloat) -> some View { modify { r, c in DecorNode(identity: r.identity, child: c, kind: .scale(x: scale, y: scale)) } }
    public func blur(radius: CGFloat) -> some View { modify { r, c in DecorNode(identity: r.identity, child: c, kind: .blur(radius)) } }
    public func hidden() -> some View { modify { r, c in DecorNode(identity: r.identity, child: c, kind: .hidden) } }
    public func allowsHitTesting(_ enabled: Bool) -> some View {
        modify { r, c in enabled ? c : DecorNode(identity: r.identity, child: c, kind: .ignoreHits) }
    }
    public func contentShape<S: Shape>(_ shape: S) -> some View { modify { r, c in DecorNode(identity: r.identity, child: c, kind: .contentShape) } }
    public func ignoresSafeArea(_ regions: Edge.Set = .all) -> some View { self }
    public func zIndex(_ value: Double) -> some View { self }
    public func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View { self }
    public func transition(_ t: AnyTransition) -> some View { self }
    public func accessibilityLabel(_ label: String) -> some View { self }
    public func accessibilityHidden(_ hidden: Bool) -> some View { self }
    public func drawingGroup() -> some View { self }
    public func compositingGroup() -> some View { self }
    public func id<ID: Hashable>(_ id: ID) -> some View {
        modify { r, c in
            let n = IDNode(identity: r.identity, child: c)
            n.explicitID = AnyHashable(id)
            return n
        }
    }

    public func background<B: View>(alignment: Alignment = .center, @ViewBuilder _ background: () -> B) -> some View {
        let b = background()
        return modify { r, child in LayerNode(identity: r.identity, content: child, layers: [r.content(b, key: 1)], behind: true, alignment: alignment) }
    }

    public func background<B: View>(_ background: B, alignment: Alignment = .center) -> some View {
        modify { r, child in LayerNode(identity: r.identity, content: child, layers: [r.content(background, key: 1)], behind: true, alignment: alignment) }
    }

    public func overlay<B: View>(alignment: Alignment = .center, @ViewBuilder _ overlay: () -> B) -> some View {
        let o = overlay()
        return modify { r, child in LayerNode(identity: r.identity, content: child, layers: [r.content(o, key: 1)], behind: false, alignment: alignment) }
    }

    public func overlay<B: View>(_ overlay: B, alignment: Alignment = .center) -> some View {
        modify { r, child in LayerNode(identity: r.identity, content: child, layers: [r.content(overlay, key: 1)], behind: false, alignment: alignment) }
    }

    public func aspectRatio(_ ratio: CGFloat? = nil, contentMode: ContentMode) -> some View {
        modify { r, child in AspectNode(identity: r.identity, child: child, ratio: ratio, mode: contentMode) }
    }
    public func scaledToFit() -> some View { aspectRatio(nil, contentMode: .fit) }
    public func scaledToFill() -> some View { aspectRatio(nil, contentMode: .fill) }
}

public enum ContentMode: Sendable { case fit, fill }
public struct Animation: Sendable { public static let `default` = Animation(), easeInOut = Animation(), linear = Animation(); public static func easeInOut(duration: Double) -> Animation { Animation() }; public static func linear(duration: Double) -> Animation { Animation() } }
public struct AnyTransition: Sendable { public static let opacity = AnyTransition(), slide = AnyTransition(), identity = AnyTransition(); public static func move(edge: Edge) -> AnyTransition { AnyTransition() } }
@MainActor public func withAnimation<R>(_ animation: Animation? = nil, _ body: () throws -> R) rethrows -> R { try body() }

@MainActor
final class AspectNode: WrapperNode {
    let ratio: CGFloat?
    let mode: ContentMode
    init(identity: Identity, child: Node, ratio: CGFloat?, mode: ContentMode) { self.ratio = ratio; self.mode = mode; super.init(identity: identity, child: child) }

    private func fitted(_ p: Proposal) -> CGSize {
        let ideal = child?.size(for: .unspecified) ?? .zero
        let r = ratio ?? (ideal.height > 0 ? ideal.width / ideal.height : 1)
        let pw = p.width.flatMap { $0.isFinite ? $0 : nil }, ph = p.height.flatMap { $0.isFinite ? $0 : nil }
        switch (pw, ph) {
        case (nil, nil): return CGSize(width: ideal.width, height: ideal.width / max(r, 0.001))
        case (let w?, nil): return CGSize(width: w, height: w / r)
        case (nil, let h?): return CGSize(width: h * r, height: h)
        case (let w?, let h?):
            let byW = CGSize(width: w, height: w / r), byH = CGSize(width: h * r, height: h)
            return mode == .fit ? (byW.height <= h ? byW : byH) : (byW.height >= h ? byW : byH)
        }
    }
    override func computeSize(_ p: Proposal) -> CGSize { fitted(p) }
    override func placeChildren() { child?.place(origin: frame.origin, size: frame.size) }
}

// MARK: - Divider

public struct Divider {
    public init() {}
    @MainActor func makeNodes(_ r: Resolver) -> [Node] {
        [DividerNode(identity: r.identity, axis: r.env.stackAxis == .horizontal ? .vertical : .horizontal)]
    }
}

@MainActor
final class DividerNode: Node {
    let axis: Axis
    init(identity: Identity, axis: Axis) { self.axis = axis; super.init(identity: identity) }
    override func computeSize(_ p: Proposal) -> CGSize {
        axis == .horizontal ? CGSize(width: p.width.flatMap { $0.isFinite ? $0 : nil } ?? 0, height: 1)
                            : CGSize(width: 1, height: p.height.flatMap { $0.isFinite ? $0 : nil } ?? 0)
    }
    override func draw(_ g: inout GraphicsContext, clip: CGRect) {
        let color = Color(white: 1, opacity: 0.18)
        g.fill(Path(frame), with: .color(color))
    }
}

// Konformitäten als Erweiterung, damit die Typen nicht auf den Hauptakteur isoliert werden (wie in SwiftUI)
extension VStack: PrimitiveView {}
extension HStack: PrimitiveView {}
extension ZStack: PrimitiveView {}
extension Spacer: PrimitiveView {}
extension Modified: PrimitiveView {}
extension Divider: PrimitiveView {}
