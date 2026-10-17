// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Nachbau des Zeichenteils von SwiftUI (Canvas, GraphicsContext, Path, Color, Gradient, Text) auf Cairo, nur Linux.
// Zweck: Die Zeichencodes der Instrumente (z. B. `SMeterPainter`) bleiben für macOS und Linux derselbe Quelltext.
@_exported import Foundation
@_exported import CoreGraphics

public struct Color: Sendable, Hashable {
    public var red: Double, green: Double, blue: Double, alpha: Double

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; alpha = opacity
    }

    public init(white: Double, opacity: Double = 1) { self.init(red: white, green: white, blue: white, opacity: opacity) }

    public func opacity(_ value: Double) -> Color { Color(red: red, green: green, blue: blue, opacity: alpha * value) }

    public static let black = Color(red: 0, green: 0, blue: 0)
    public static let white = Color(red: 1, green: 1, blue: 1)
    public static let clear = Color(red: 0, green: 0, blue: 0, opacity: 0)
    public static let gray = Color(red: 0.55, green: 0.55, blue: 0.57)
    public static let red = Color(red: 1, green: 0.23, blue: 0.19)
    public static let green = Color(red: 0.20, green: 0.78, blue: 0.35)
    public static let blue = Color(red: 0, green: 0.48, blue: 1)
    public static let yellow = Color(red: 1, green: 0.8, blue: 0)
    public static let orange = Color(red: 1, green: 0.58, blue: 0)
    public static let primary = Color(white: 1)
    public static let secondary = Color(white: 1, opacity: 0.55)
    public static let accentColor = Color(red: 0.04, green: 0.52, blue: 1)
    public static let cyan = Color(red: 0.2, green: 0.8, blue: 0.95)
    public static let purple = Color(red: 0.69, green: 0.32, blue: 0.87)
    public static let pink = Color(red: 1, green: 0.18, blue: 0.33)
    public static let brown = Color(red: 0.64, green: 0.52, blue: 0.37)
    public static let mint = Color(red: 0, green: 0.78, blue: 0.75)
    public static let teal = Color(red: 0.19, green: 0.69, blue: 0.78)
    public static let indigo = Color(red: 0.35, green: 0.34, blue: 0.84)
}

public struct Gradient: Sendable {
    public struct Stop: Sendable {
        public var color: Color
        public var location: Double
        public init(color: Color, location: Double) { self.color = color; self.location = location }
    }

    public var stops: [Stop]
    public init(stops: [Stop]) { self.stops = stops }
    public init(colors: [Color]) {
        let n = max(1, colors.count - 1)
        stops = colors.enumerated().map { Stop(color: $1, location: Double($0) / Double(n)) }
    }
}

public struct UnitPoint: Sendable, Hashable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let zero = UnitPoint(x: 0, y: 0)
    public static let center = UnitPoint(x: 0.5, y: 0.5)
    public static let leading = UnitPoint(x: 0, y: 0.5)
    public static let trailing = UnitPoint(x: 1, y: 0.5)
    public static let top = UnitPoint(x: 0.5, y: 0)
    public static let bottom = UnitPoint(x: 0.5, y: 1)
    public static let topLeading = UnitPoint(x: 0, y: 0)
    public static let topTrailing = UnitPoint(x: 1, y: 0)
    public static let bottomLeading = UnitPoint(x: 0, y: 1)
    public static let bottomTrailing = UnitPoint(x: 1, y: 1)
}

public struct Angle: Sendable, Hashable {
    public var radians: Double
    public init(radians: Double) { self.radians = radians }
    public init(degrees: Double) { radians = degrees * .pi / 180 }
    public var degrees: Double { radians * 180 / .pi }
    public static func degrees(_ d: Double) -> Angle { Angle(degrees: d) }
    public static func radians(_ r: Double) -> Angle { Angle(radians: r) }
}

public struct StrokeStyle: Sendable {
    public var lineWidth: CGFloat
    public var lineCap: CGLineCap
    public var lineJoin: CGLineJoin
    public var dash: [CGFloat]
    public init(lineWidth: CGFloat = 1, lineCap: CGLineCap = .butt, lineJoin: CGLineJoin = .miter, miterLimit: CGFloat = 10, dash: [CGFloat] = [], dashPhase: CGFloat = 0) {
        self.lineWidth = lineWidth; self.lineCap = lineCap; self.lineJoin = lineJoin; self.dash = dash
    }
}

// MARK: - Path

public struct Path: Sendable {
    public enum Element: Sendable {
        case move(CGPoint), line(CGPoint), quad(to: CGPoint, control: CGPoint)
        case curve(to: CGPoint, c1: CGPoint, c2: CGPoint), close
        case rect(CGRect), ellipse(CGRect)
        case arc(center: CGPoint, radius: CGFloat, start: Double, end: Double, clockwise: Bool)
    }

    public private(set) var elements: [Element] = []
    public init() {}
    public init(_ rect: CGRect) { elements = [.rect(rect)] }
    public init(ellipseIn rect: CGRect) { elements = [.ellipse(rect)] }
    public init(roundedRect rect: CGRect, cornerRadius: CGFloat) {
        let r = min(cornerRadius, rect.width / 2, rect.height / 2)
        elements = [
            .move(CGPoint(x: rect.minX + r, y: rect.minY)), .line(CGPoint(x: rect.maxX - r, y: rect.minY)),
            .arc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, start: -.pi / 2, end: 0, clockwise: true),
            .line(CGPoint(x: rect.maxX, y: rect.maxY - r)),
            .arc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, start: 0, end: .pi / 2, clockwise: true),
            .line(CGPoint(x: rect.minX + r, y: rect.maxY)),
            .arc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, start: .pi / 2, end: .pi, clockwise: true),
            .line(CGPoint(x: rect.minX, y: rect.minY + r)),
            .arc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, start: .pi, end: 3 * .pi / 2, clockwise: true),
            .close,
        ]
    }

    public mutating func move(to p: CGPoint) { elements.append(.move(p)) }
    public mutating func addLine(to p: CGPoint) { elements.append(.line(p)) }
    public mutating func addQuadCurve(to p: CGPoint, control: CGPoint) { elements.append(.quad(to: p, control: control)) }
    public mutating func addCurve(to p: CGPoint, control1: CGPoint, control2: CGPoint) { elements.append(.curve(to: p, c1: control1, c2: control2)) }
    public mutating func addRect(_ rect: CGRect) { elements.append(.rect(rect)) }
    public mutating func addEllipse(in rect: CGRect) { elements.append(.ellipse(rect)) }
    public mutating func addArc(center: CGPoint, radius: CGFloat, startAngle: Angle, endAngle: Angle, clockwise: Bool) {
        elements.append(.arc(center: center, radius: radius, start: startAngle.radians, end: endAngle.radians, clockwise: clockwise))
    }
    public mutating func closeSubpath() { elements.append(.close) }
    public var isEmpty: Bool { elements.isEmpty }
    public mutating func addRoundedRect(in rect: CGRect, cornerSize: CGSize) { elements += Path(roundedRect: rect, cornerRadius: min(cornerSize.width, cornerSize.height)).elements }
    public mutating func addPath(_ path: Path) { elements += path.elements }
    public func applying(_ t: CGAffineTransform) -> Path {
        var p = Path()
        func map(_ pt: CGPoint) -> CGPoint { pt.applying(t) }
        for e in elements {
            switch e {
            case .move(let a): p.elements.append(.move(map(a)))
            case .line(let a): p.elements.append(.line(map(a)))
            case .quad(let a, let c): p.elements.append(.quad(to: map(a), control: map(c)))
            case .curve(let a, let c1, let c2): p.elements.append(.curve(to: map(a), c1: map(c1), c2: map(c2)))
            case .close: p.elements.append(.close)
            case .rect(let r): p.elements.append(.rect(r.applying(t)))
            case .ellipse(let r): p.elements.append(.ellipse(r.applying(t)))
            case .arc(let c, let r, let s, let e2, let cw): p.elements.append(.arc(center: map(c), radius: r * CGFloat(t.a), start: s, end: e2, clockwise: cw))
            }
        }
        return p
    }
}
