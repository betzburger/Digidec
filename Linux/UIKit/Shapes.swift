// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Formen, Füllungen, Verläufe und Farbe als Ansicht.
import Foundation

// MARK: - ShapeStyle

public protocol ShapeStyle {
    @MainActor func shading(in rect: CGRect) -> GraphicsContext.Shading
}

extension Color: ShapeStyle {
    public func shading(in rect: CGRect) -> GraphicsContext.Shading { .color(self) }
}

public struct LinearGradient {
    public var gradient: Gradient
    public var startPoint: UnitPoint, endPoint: UnitPoint
    public init(gradient: Gradient, startPoint: UnitPoint, endPoint: UnitPoint) { self.gradient = gradient; self.startPoint = startPoint; self.endPoint = endPoint }
    public init(colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint) { self.init(gradient: Gradient(colors: colors), startPoint: startPoint, endPoint: endPoint) }
    public init(stops: [Gradient.Stop], startPoint: UnitPoint, endPoint: UnitPoint) { self.init(gradient: Gradient(stops: stops), startPoint: startPoint, endPoint: endPoint) }
    public func shading(in rect: CGRect) -> GraphicsContext.Shading {
        .linearGradient(gradient, startPoint: CGPoint(x: rect.minX + rect.width * startPoint.x, y: rect.minY + rect.height * startPoint.y),
                        endPoint: CGPoint(x: rect.minX + rect.width * endPoint.x, y: rect.minY + rect.height * endPoint.y))
    }
    @MainActor func makeNodes(_ r: Resolver) -> [Node] { [ShapeNode(identity: r.identity, shape: Rectangle(), fill: self, stroke: nil, lineWidth: 0)] }
}

public struct RadialGradient {
    public var gradient: Gradient
    public var center: UnitPoint
    public var startRadius: CGFloat, endRadius: CGFloat
    public init(gradient: Gradient, center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) {
        self.gradient = gradient; self.center = center; self.startRadius = startRadius; self.endRadius = endRadius
    }
    public init(colors: [Color], center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) { self.init(gradient: Gradient(colors: colors), center: center, startRadius: startRadius, endRadius: endRadius) }
    public func shading(in rect: CGRect) -> GraphicsContext.Shading {
        .radialGradient(gradient, center: CGPoint(x: rect.minX + rect.width * center.x, y: rect.minY + rect.height * center.y), startRadius: startRadius, endRadius: endRadius)
    }
    @MainActor func makeNodes(_ r: Resolver) -> [Node] { [ShapeNode(identity: r.identity, shape: Rectangle(), fill: self, stroke: nil, lineWidth: 0)] }
}

// MARK: - Color als Ansicht

extension Color: PrimitiveView {
    @MainActor func makeNodes(_ r: Resolver) -> [Node] { [ShapeNode(identity: r.identity, shape: Rectangle(), fill: self, stroke: nil, lineWidth: 0)] }
}

// MARK: - Shape

public protocol Shape: View {
    func path(in rect: CGRect) -> Path
}

nonisolated extension Shape {
    public func fill<S: ShapeStyle>(_ style: S) -> some View { ShapeView(shape: self, fill: style, stroke: nil as Color?, lineWidth: 0) }
    public func fill() -> some View { ShapeView(shape: self, fill: Color?.none, stroke: nil as Color?, lineWidth: 0, useForeground: true) }
    public func stroke<S: ShapeStyle>(_ style: S, lineWidth: CGFloat = 1) -> some View { ShapeView(shape: self, fill: nil as Color?, stroke: style, lineWidth: lineWidth) }
    public func stroke<S: ShapeStyle>(_ style: S, style strokeStyle: StrokeStyle) -> some View { ShapeView(shape: self, fill: nil as Color?, stroke: style, lineWidth: strokeStyle.lineWidth, strokeStyle: strokeStyle) }
    public func stroke(lineWidth: CGFloat = 1) -> some View { ShapeView(shape: self, fill: nil as Color?, stroke: Color?.none, lineWidth: lineWidth, useForeground: true) }
    public func strokeBorder<S: ShapeStyle>(_ style: S, lineWidth: CGFloat = 1) -> some View { ShapeView(shape: self, fill: nil as Color?, stroke: style, lineWidth: lineWidth, inset: true) }
    public func strokeBorder<S: ShapeStyle>(_ style: S, style strokeStyle: StrokeStyle) -> some View { ShapeView(shape: self, fill: nil as Color?, stroke: style, lineWidth: strokeStyle.lineWidth, strokeStyle: strokeStyle, inset: true) }
    public func inset(by amount: CGFloat) -> some Shape { InsetShape(base: self, amount: amount) }
    public func trim(from: CGFloat = 0, to: CGFloat = 1) -> some Shape { self }
}

struct InsetShape<Base: Shape> {
    let base: Base
    let amount: CGFloat
    func path(in rect: CGRect) -> Path { base.path(in: rect.insetBy(dx: amount, dy: amount)) }
    var body: Never { fatalError() }
}

nonisolated extension Shape {
    /// Formen sind als Ansicht mit der Vordergrundfarbe gefüllt
    @MainActor func makeShapeNodes(_ r: Resolver) -> [Node] { [ShapeNode(identity: r.identity, shape: self, fill: r.env.foregroundColor ?? Color.primary, stroke: nil, lineWidth: 0)] }
}

public struct Rectangle {
    public init() {}
    public func path(in rect: CGRect) -> Path { Path(rect) }
    @MainActor func makeNodes(_ r: Resolver) -> [Node] { makeShapeNodes(r) }
}

public struct RoundedRectangle {
    public enum Style: Sendable { case circular, continuous }
    public var cornerRadius: CGFloat
    public init(cornerRadius: CGFloat, style: Style = .circular) { self.cornerRadius = cornerRadius }
    public func path(in rect: CGRect) -> Path { Path(roundedRect: rect, cornerRadius: cornerRadius) }
    @MainActor func makeNodes(_ r: Resolver) -> [Node] { makeShapeNodes(r) }
}

public struct Circle {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        let d = min(rect.width, rect.height)
        return Path(ellipseIn: CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d))
    }
    @MainActor func makeNodes(_ r: Resolver) -> [Node] { makeShapeNodes(r) }
}

public struct Ellipse {
    public init() {}
    public func path(in rect: CGRect) -> Path { Path(ellipseIn: rect) }
    @MainActor func makeNodes(_ r: Resolver) -> [Node] { makeShapeNodes(r) }
}

public struct Capsule {
    public init() {}
    public func path(in rect: CGRect) -> Path { Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2) }
    @MainActor func makeNodes(_ r: Resolver) -> [Node] { makeShapeNodes(r) }
}

extension Path: Shape, PrimitiveView {
    public func path(in rect: CGRect) -> Path { self }
    @MainActor func makeNodes(_ r: Resolver) -> [Node] { makeShapeNodes(r) }
    public init(_ build: (inout Path) -> Void) { self.init(); build(&self) }
}

/// Eine Form mit Füllung und/oder Strich als Ansicht
struct ShapeView<S: Shape, F: ShapeStyle, T: ShapeStyle> {
    let shape: S
    let fill: F?
    let stroke: T?
    let lineWidth: CGFloat
    var strokeStyle: StrokeStyle?
    var inset = false
    var useForeground = false

    @MainActor func makeNodes(_ r: Resolver) -> [Node] {
        let foreground = r.env.foregroundColor ?? Color.primary
        let n = ShapeNode(identity: r.identity, shape: shape, fill: useForeground ? nil : fill, stroke: stroke, lineWidth: lineWidth)
        if useForeground { if fill == nil && stroke == nil { n.stroke = foreground } else { n.fill = foreground } }
        n.strokeStyle = strokeStyle
        n.inset = inset
        return [n]
    }
}

nonisolated(unsafe) let shapeProfile = ProcessInfo.processInfo.environment["DIGIDEC_TRACE_SHAPES"] != nil
nonisolated(unsafe) var shapeProfileData: [String: (Double, Int)] = [:]

/// Knoten für Formen: füllt den vorgeschlagenen Platz (ohne Vorschlag 10 × 10 wie in SwiftUI nicht ganz, aber ausreichend)
@MainActor
final class ShapeNode: Node {
    let shape: any Shape
    var fill: (any ShapeStyle)?
    var stroke: (any ShapeStyle)?
    var lineWidth: CGFloat
    var strokeStyle: StrokeStyle?
    var inset = false

    init(identity: Identity, shape: any Shape, fill: (any ShapeStyle)?, stroke: (any ShapeStyle)?, lineWidth: CGFloat) {
        self.shape = shape; self.fill = fill; self.stroke = stroke; self.lineWidth = lineWidth
        super.init(identity: identity)
    }

    override func computeSize(_ p: Proposal) -> CGSize {
        CGSize(width: p.width.flatMap { $0.isFinite ? $0 : nil } ?? 10, height: p.height.flatMap { $0.isFinite ? $0 : nil } ?? 10)
    }

    override func draw(_ g: inout GraphicsContext, clip: CGRect) {
        if shapeProfile {
            let t0 = DispatchTime.now().uptimeNanoseconds
            drawShape(&g)
            let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            let key = String(format: "%@ %.0fx%.0f fill=%@ stroke=%@ lw=%.1f", String(describing: type(of: shape)), frame.width, frame.height, fill.map { String(describing: type(of: $0)) } ?? "-", stroke.map { String(describing: type(of: $0)) } ?? "-", lineWidth)
            shapeProfileData[key, default: (0, 0)].0 += dt
            shapeProfileData[key, default: (0, 0)].1 += 1
        } else { drawShape(&g) }
    }

    private func drawShape(_ g: inout GraphicsContext) {
        let rect = frame
        if let fill { g.fill(shape.path(in: rect), with: fill.shading(in: rect)) }
        if let stroke {
            let drawRect = inset ? rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2) : rect
            let path = shape.path(in: drawRect)
            if let strokeStyle { g.stroke(path, with: stroke.shading(in: rect), style: strokeStyle) } else { g.stroke(path, with: stroke.shading(in: rect), lineWidth: lineWidth) }
        }
    }
}

extension Optional: ShapeStyle where Wrapped: ShapeStyle {
    public func shading(in rect: CGRect) -> GraphicsContext.Shading { self?.shading(in: rect) ?? .color(.clear) }
}

public struct StrokeBorderPlaceholder {}

// Konformitäten als Erweiterung, damit die Typen nicht auf den Hauptakteur isoliert werden (wie in SwiftUI)
extension LinearGradient: ShapeStyle, PrimitiveView {}
extension RadialGradient: ShapeStyle, PrimitiveView {}
extension InsetShape: Shape {}
extension Rectangle: Shape, PrimitiveView {}
extension RoundedRectangle: Shape, PrimitiveView {}
extension Circle: Shape, PrimitiveView {}
extension Ellipse: Shape, PrimitiveView {}
extension Capsule: Shape, PrimitiveView {}
extension ShapeView: PrimitiveView {}
