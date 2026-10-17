// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Canvas, TimelineView und GeometryReader.
import Foundation
import CGtkCairo

public struct Canvas {
    let renderer: (inout GraphicsContext, CGSize) -> Void
    public init(opaque: Bool = false, rendersAsynchronously: Bool = false, renderer: @escaping (inout GraphicsContext, CGSize) -> Void) { self.renderer = renderer }
    @MainActor func makeNodes(_ r: Resolver) -> [Node] { [CanvasNode(identity: r.identity, renderer: renderer)] }
}

@MainActor
final class CanvasNode: Node {
    let renderer: (inout GraphicsContext, CGSize) -> Void
    init(identity: Identity, renderer: @escaping (inout GraphicsContext, CGSize) -> Void) { self.renderer = renderer; super.init(identity: identity) }
    override func computeSize(_ p: Proposal) -> CGSize {
        CGSize(width: p.width.flatMap { $0.isFinite ? $0 : nil } ?? 10, height: p.height.flatMap { $0.isFinite ? $0 : nil } ?? 10)
    }
    override func draw(_ g: inout GraphicsContext, clip: CGRect) {
        let cr = g.cr
        cairo_save(cr)
        cairo_rectangle(cr, frame.minX, frame.minY, frame.width, frame.height)
        cairo_clip(cr)
        cairo_translate(cr, frame.minX, frame.minY)
        var inner = GraphicsContext(cairo: cr, size: g.canvasSize)
        renderer(&inner, frame.size)
        cairo_restore(cr)
    }
}

// MARK: - TimelineView

public struct TimelineViewDefaultContext { public var date: Date }

public struct TimelineSchedule {
    let interval: TimeInterval
    public static var animation: TimelineSchedule { TimelineSchedule(interval: 1.0 / 30) }
    public static func animation(minimumInterval: TimeInterval? = nil, paused: Bool = false) -> TimelineSchedule { TimelineSchedule(interval: max(minimumInterval ?? 1.0 / 30, 1.0 / 60)) }
    public static func periodic(from start: Date, by interval: TimeInterval) -> TimelineSchedule { TimelineSchedule(interval: interval) }
    public static var everyMinute: TimelineSchedule { TimelineSchedule(interval: 60) }
}

public struct TimelineView<Content: View> {
    let schedule: TimelineSchedule
    let content: (TimelineViewDefaultContext) -> Content
    public init(_ schedule: TimelineSchedule, @ViewBuilder content: @escaping (TimelineViewDefaultContext) -> Content) {
        self.schedule = schedule; self.content = content
    }
    @MainActor func makeNodes(_ r: Resolver) -> [Node] {
        r.host?.registerTimeline(interval: schedule.interval)
        return r.resolve(content(TimelineViewDefaultContext(date: Date())), key: 0)
    }
}

extension Date {
    /// Zeitpunkt des Aufrufs (SwiftUI: `.now`)
    public static var now: Date { Date() }
}

// MARK: - GeometryReader

public struct GeometryProxy {
    public let size: CGSize
    public let origin: CGPoint
    public var safeAreaInsets: EdgeInsets { EdgeInsets() }
    public func frame(in space: CoordinateSpace) -> CGRect {
        switch space {
        case .global: return CGRect(origin: origin, size: size)
        case .local: return CGRect(origin: .zero, size: size)
        }
    }
}

public enum CoordinateSpace { case local, global }

public struct GeometryReader<Content: View> {
    let content: (GeometryProxy) -> Content
    public init(@ViewBuilder content: @escaping (GeometryProxy) -> Content) { self.content = content }

    @MainActor func makeNodes(_ r: Resolver) -> [Node] {
        let node = GeometryNode(identity: r.identity)
        let identity = r.identity, env = r.env, content = self.content
        node.build = { [unowned r] size, origin in
            let savedIdentity = r.identity, savedEnv = r.env
            r.identity = identity; r.env = env
            defer { r.identity = savedIdentity; r.env = savedEnv }
            return r.resolveSingle(content(GeometryProxy(size: size, origin: origin)), key: 0)
        }
        return [node]
    }
}

@MainActor
final class GeometryNode: Node {
    var build: ((CGSize, CGPoint) -> Node)?
    override func computeSize(_ p: Proposal) -> CGSize {
        CGSize(width: p.width.flatMap { $0.isFinite ? $0 : nil } ?? 10, height: p.height.flatMap { $0.isFinite ? $0 : nil } ?? 10)
    }
    override func place(origin: CGPoint, size: CGSize) {
        frame = CGRect(origin: origin, size: size)
        if let child = build?(size, origin) {
            children = [child]
            child.place(origin: origin, size: child.size(for: .fixed(size)))
        }
    }
    override func placeChildren() {}
}

// Konformitäten als Erweiterung, damit die Typen nicht auf den Hauptakteur isoliert werden (wie in SwiftUI)
extension Canvas: PrimitiveView {}
extension TimelineView: PrimitiveView {}
extension GeometryReader: PrimitiveView {}
