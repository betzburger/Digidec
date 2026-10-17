// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Die SF-Symbole, die Digidec verwendet, als Linienzeichnungen mit Cairo (die Symbolschrift von Apple gibt es unter Linux nicht).
import Foundation

@MainActor
enum Icons {
    static func draw(_ name: String, in rect: CGRect, color: Color, g: inout GraphicsContext) {
        let side = min(rect.width, rect.height)
        let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side).insetBy(dx: side * 0.08, dy: side * 0.08)
        let lw = max(1, side * 0.085)
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + box.width * x, y: box.minY + box.height * y) }
        func line(_ pts: CGPoint...) -> Path { var p = Path(); p.move(to: pts[0]); for q in pts.dropFirst() { p.addLine(to: q) }; return p }
        func polygon(_ pts: CGPoint...) -> Path { var p = line(pts[0]); for q in pts.dropFirst() { p.addLine(to: q) }; p.closeSubpath(); return p }
        func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
            Path(roundedRect: CGRect(x: box.minX + box.width * x, y: box.minY + box.height * y, width: box.width * w, height: box.height * h), cornerRadius: box.width * r)
        }
        func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: box.minX + box.width * (cx - r), y: box.minY + box.height * (cy - r), width: box.width * 2 * r, height: box.height * 2 * r))
        }
        func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ a0: Double, _ a1: Double) -> Path {
            var p = Path()
            p.addArc(center: P(cx, cy), radius: box.width * r, startAngle: .degrees(a0), endAngle: .degrees(a1), clockwise: true)
            return p
        }
        let style = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
        let ink = GraphicsContext.Shading.color(color)
        func stroke(_ p: Path) { g.stroke(p, with: ink, style: style) }
        func fill(_ p: Path) { g.fill(p, with: ink) }
        func arrowHead(_ tip: CGPoint, dx: CGFloat, dy: CGFloat) {
            // Pfeilspitze an `tip`, Richtung (dx, dy) normiert
            let l = hypot(dx, dy), ux = dx / l, uy = dy / l, s = box.width * 0.22
            stroke(line(CGPoint(x: tip.x - ux * s - uy * s, y: tip.y - uy * s + ux * s), tip, CGPoint(x: tip.x - ux * s + uy * s, y: tip.y - uy * s - ux * s)))
        }

        switch name {
        case "plus": stroke(line(P(0.5, 0.12), P(0.5, 0.88))); stroke(line(P(0.12, 0.5), P(0.88, 0.5)))
        case "minus": stroke(line(P(0.12, 0.5), P(0.88, 0.5)))
        case "xmark": stroke(line(P(0.18, 0.18), P(0.82, 0.82))); stroke(line(P(0.82, 0.18), P(0.18, 0.82)))
        case "checkmark": stroke(line(P(0.14, 0.55), P(0.40, 0.80), P(0.86, 0.22)))
        case "trash":
            stroke(line(P(0.12, 0.24), P(0.88, 0.24))); stroke(line(P(0.36, 0.24), P(0.36, 0.12), P(0.64, 0.12), P(0.64, 0.24)))
            stroke(line(P(0.22, 0.24), P(0.28, 0.88), P(0.72, 0.88), P(0.78, 0.24))); stroke(line(P(0.42, 0.40), P(0.42, 0.72))); stroke(line(P(0.58, 0.40), P(0.58, 0.72)))
        case "folder", "folder.badge.plus":
            stroke(polygon(P(0.08, 0.24), P(0.38, 0.24), P(0.48, 0.34), P(0.92, 0.34), P(0.92, 0.80), P(0.08, 0.80)))
            if name.hasSuffix("plus") { stroke(line(P(0.62, 0.50), P(0.62, 0.70))); stroke(line(P(0.52, 0.60), P(0.72, 0.60))) }
        case "doc.on.doc": stroke(rrect(0.30, 0.08, 0.60, 0.68, 0.06)); stroke(line(P(0.20, 0.30), P(0.20, 0.92), P(0.66, 0.92)))
        case "chevron.up.chevron.down": stroke(line(P(0.28, 0.36), P(0.5, 0.14), P(0.72, 0.36))); stroke(line(P(0.28, 0.64), P(0.5, 0.86), P(0.72, 0.64)))
        case "chevron.down": stroke(line(P(0.2, 0.36), P(0.5, 0.66), P(0.8, 0.36)))
        case "chevron.up": stroke(line(P(0.2, 0.64), P(0.5, 0.34), P(0.8, 0.64)))
        case "chevron.right": stroke(line(P(0.36, 0.2), P(0.66, 0.5), P(0.36, 0.8)))
        case "chevron.left": stroke(line(P(0.64, 0.2), P(0.34, 0.5), P(0.64, 0.8)))
        case "chevron.left.forwardslash.chevron.right":
            stroke(line(P(0.28, 0.28), P(0.08, 0.5), P(0.28, 0.72))); stroke(line(P(0.72, 0.28), P(0.92, 0.5), P(0.72, 0.72))); stroke(line(P(0.56, 0.2), P(0.44, 0.8)))
        case "arrow.up": stroke(line(P(0.5, 0.88), P(0.5, 0.14))); arrowHead(P(0.5, 0.12), dx: 0, dy: -1)
        case "arrow.down": stroke(line(P(0.5, 0.12), P(0.5, 0.86))); arrowHead(P(0.5, 0.88), dx: 0, dy: 1)
        case "arrow.left.arrow.right":
            stroke(line(P(0.12, 0.34), P(0.88, 0.34))); arrowHead(P(0.9, 0.34), dx: 1, dy: 0)
            stroke(line(P(0.88, 0.68), P(0.12, 0.68))); arrowHead(P(0.1, 0.68), dx: -1, dy: 0)
        case "arrow.up.arrow.down":
            stroke(line(P(0.32, 0.88), P(0.32, 0.14))); arrowHead(P(0.32, 0.12), dx: 0, dy: -1)
            stroke(line(P(0.68, 0.12), P(0.68, 0.86))); arrowHead(P(0.68, 0.88), dx: 0, dy: 1)
        case "arrow.left.and.right", "arrow.left.and.right.righttriangle.left.righttriangle.right":
            stroke(line(P(0.14, 0.5), P(0.86, 0.5))); arrowHead(P(0.88, 0.5), dx: 1, dy: 0); arrowHead(P(0.12, 0.5), dx: -1, dy: 0)
        case "arrow.clockwise", "arrow.counterclockwise":
            let cw = name == "arrow.clockwise"
            stroke(arc(0.5, 0.5, 0.36, cw ? 40 : 140, cw ? 330 : -150))
            let tip = cw ? P(0.5 + 0.36 * cos(.pi * 40 / 180) , 0.5 + 0.36 * sin(.pi * 40 / 180)) : P(0.5 + 0.36 * cos(.pi * 140 / 180), 0.5 + 0.36 * sin(.pi * 140 / 180))
            arrowHead(tip, dx: cw ? -0.3 : 0.3, dy: 1)
        case "arrow.up.right.square", "arrow.up.forward.square":
            stroke(line(P(0.52, 0.18), P(0.14, 0.18), P(0.14, 0.86), P(0.82, 0.86), P(0.82, 0.48))); stroke(line(P(0.44, 0.56), P(0.88, 0.12))); arrowHead(P(0.9, 0.1), dx: 1, dy: -1)
        case "square.and.arrow.down":
            stroke(line(P(0.34, 0.40), P(0.16, 0.40), P(0.16, 0.88), P(0.84, 0.88), P(0.84, 0.40), P(0.66, 0.40))); stroke(line(P(0.5, 0.10), P(0.5, 0.62))); arrowHead(P(0.5, 0.64), dx: 0, dy: 1)
        case "exclamationmark.triangle.fill":
            fill(polygon(P(0.5, 0.10), P(0.94, 0.86), P(0.06, 0.86)))
            g.stroke(line(P(0.5, 0.36), P(0.5, 0.60)), with: .color(Color(white: 0, opacity: 0.8)), style: StrokeStyle(lineWidth: lw, lineCap: .round)); g.fill(circle(0.5, 0.73, 0.045), with: .color(Color(white: 0, opacity: 0.8)))
        case "info.circle": stroke(circle(0.5, 0.5, 0.40)); stroke(line(P(0.5, 0.46), P(0.5, 0.70))); fill(circle(0.5, 0.31, 0.04))
        case "xmark.circle": stroke(circle(0.5, 0.5, 0.40)); stroke(line(P(0.34, 0.34), P(0.66, 0.66))); stroke(line(P(0.66, 0.34), P(0.34, 0.66)))
        case "stop.circle.fill": fill(circle(0.5, 0.5, 0.42)); g.fill(rrect(0.36, 0.36, 0.28, 0.28, 0.04), with: .color(Color(white: 0, opacity: 0.75)))
        case "record.circle": stroke(circle(0.5, 0.5, 0.40)); fill(circle(0.5, 0.5, 0.22))
        case "record.circle.fill": fill(circle(0.5, 0.5, 0.42)); g.fill(circle(0.5, 0.5, 0.22), with: .color(Color(white: 0, opacity: 0.55)))
        case "waveform.circle": stroke(circle(0.5, 0.5, 0.40)); for (i, h) in [0.12, 0.24, 0.16, 0.28, 0.1].enumerated() { let x = 0.28 + 0.11 * CGFloat(i); stroke(line(P(x, 0.5 - h), P(x, 0.5 + h))) }
        case "play.fill": fill(polygon(P(0.22, 0.12), P(0.88, 0.5), P(0.22, 0.88)))
        case "forward.end.fill": fill(polygon(P(0.10, 0.20), P(0.66, 0.5), P(0.10, 0.80))); fill(rrect(0.72, 0.20, 0.14, 0.60, 0.02))
        case "speaker.fill", "speaker.wave.2.fill":
            fill(polygon(P(0.08, 0.38), P(0.28, 0.38), P(0.50, 0.18), P(0.50, 0.82), P(0.28, 0.62), P(0.08, 0.62)))
            if name.contains("wave") { stroke(arc(0.50, 0.5, 0.18, -50, 50)); stroke(arc(0.50, 0.5, 0.32, -50, 50)) }
        case "camera": stroke(rrect(0.06, 0.26, 0.88, 0.62, 0.08)); stroke(line(P(0.30, 0.26), P(0.38, 0.12), P(0.62, 0.12), P(0.70, 0.26))); stroke(circle(0.5, 0.57, 0.17))
        case "photo.on.rectangle.angled": stroke(rrect(0.10, 0.22, 0.80, 0.62, 0.06)); stroke(line(P(0.14, 0.76), P(0.38, 0.50), P(0.54, 0.66), P(0.68, 0.52), P(0.86, 0.72))); fill(circle(0.70, 0.38, 0.06))
        case "pencil": stroke(polygon(P(0.14, 0.86), P(0.18, 0.64), P(0.68, 0.14), P(0.86, 0.32), P(0.36, 0.82)))
        case "paperclip": stroke(line(P(0.70, 0.30), P(0.36, 0.64), P(0.30, 0.82), P(0.50, 0.86), P(0.84, 0.50), P(0.74, 0.14), P(0.32, 0.22), P(0.16, 0.60)))
        case "sparkles", "wand.and.stars": fill(polygon(P(0.40, 0.12), P(0.48, 0.40), P(0.76, 0.48), P(0.48, 0.56), P(0.40, 0.84), P(0.32, 0.56), P(0.04, 0.48), P(0.32, 0.40))); fill(polygon(P(0.78, 0.10), P(0.82, 0.22), P(0.94, 0.26), P(0.82, 0.30), P(0.78, 0.42), P(0.74, 0.30), P(0.62, 0.26), P(0.74, 0.22)))
        case "paintpalette": stroke(circle(0.5, 0.5, 0.40)); for (x, y) in [(0.34, 0.38), (0.5, 0.28), (0.66, 0.38), (0.30, 0.58)] { fill(circle(CGFloat(x), CGFloat(y), 0.05)) }
        case "map": stroke(polygon(P(0.08, 0.20), P(0.36, 0.12), P(0.64, 0.20), P(0.92, 0.12), P(0.92, 0.80), P(0.64, 0.88), P(0.36, 0.80), P(0.08, 0.88))); stroke(line(P(0.36, 0.12), P(0.36, 0.80))); stroke(line(P(0.64, 0.20), P(0.64, 0.88)))
        case "location.north.fill": fill(polygon(P(0.5, 0.08), P(0.86, 0.90), P(0.5, 0.70), P(0.14, 0.90)))
        case "house", "house.fill":
            let roof = polygon(P(0.5, 0.10), P(0.94, 0.50), P(0.82, 0.50), P(0.82, 0.88), P(0.18, 0.88), P(0.18, 0.50), P(0.06, 0.50))
            name.hasSuffix("fill") ? fill(roof) : stroke(roof)
        case "gearshape":
            stroke(circle(0.5, 0.5, 0.18))
            for i in 0..<8 { let a = Double(i) * .pi / 4; stroke(line(P(0.5 + 0.30 * CGFloat(cos(a)), 0.5 + 0.30 * CGFloat(sin(a))), P(0.5 + 0.42 * CGFloat(cos(a)), 0.5 + 0.42 * CGFloat(sin(a))))) }
            stroke(circle(0.5, 0.5, 0.31))
        case "slider.horizontal.3":
            for (y, x) in [(0.22, 0.62), (0.5, 0.34), (0.78, 0.7)] { stroke(line(P(0.08, CGFloat(y)), P(0.92, CGFloat(y)))); g.fill(circle(CGFloat(x), CGFloat(y), 0.09), with: ink) }
        case "line.3.horizontal.decrease": stroke(line(P(0.08, 0.26), P(0.92, 0.26))); stroke(line(P(0.22, 0.5), P(0.78, 0.5))); stroke(line(P(0.38, 0.74), P(0.62, 0.74)))
        case "text.alignleft": for (i, w) in [0.84, 0.56, 0.84, 0.4].enumerated() { let y = 0.2 + 0.2 * CGFloat(i); stroke(line(P(0.08, y), P(0.08 + w, y))) }
        case "clock", "clock.badge.checkmark": stroke(circle(0.5, 0.5, 0.40)); stroke(line(P(0.5, 0.26), P(0.5, 0.5), P(0.68, 0.6)))
        case "bolt.horizontal": fill(polygon(P(0.58, 0.06), P(0.22, 0.56), P(0.46, 0.56), P(0.38, 0.94), P(0.78, 0.40), P(0.54, 0.40)))
        case "ferry", "ferry.fill":
            let hull = polygon(P(0.06, 0.62), P(0.94, 0.62), P(0.80, 0.86), P(0.20, 0.86))
            name.hasSuffix("fill") ? fill(hull) : stroke(hull)
            stroke(rrect(0.22, 0.34, 0.56, 0.22, 0.03)); stroke(line(P(0.5, 0.34), P(0.5, 0.14), P(0.62, 0.14)))
        case "airplane": fill(polygon(P(0.50, 0.04), P(0.58, 0.34), P(0.96, 0.60), P(0.96, 0.70), P(0.58, 0.58), P(0.56, 0.80), P(0.70, 0.90), P(0.70, 0.96), P(0.50, 0.90), P(0.30, 0.96), P(0.30, 0.90), P(0.44, 0.80), P(0.42, 0.58), P(0.04, 0.70), P(0.04, 0.60), P(0.42, 0.34)))
        case "antenna.radiowaves.left.and.right", "dot.radiowaves.left.and.right":
            fill(circle(0.5, 0.5, 0.07))
            stroke(arc(0.5, 0.5, 0.22, -45, 45)); stroke(arc(0.5, 0.5, 0.40, -45, 45)); stroke(arc(0.5, 0.5, 0.22, 135, 225)); stroke(arc(0.5, 0.5, 0.40, 135, 225))
            if name.hasPrefix("antenna") { stroke(line(P(0.5, 0.57), P(0.5, 0.92))) }
        case "waveform.badge.magnifyingglass": for (i, h) in [0.10, 0.22, 0.16, 0.26].enumerated() { let x = 0.12 + 0.12 * CGFloat(i); stroke(line(P(x, 0.4 - h), P(x, 0.4 + h))) }; stroke(circle(0.66, 0.62, 0.16)); stroke(line(P(0.78, 0.74), P(0.92, 0.88)))
        case "point.topleft.down.to.point.bottomright.curvepath":
            fill(circle(0.16, 0.18, 0.07)); fill(circle(0.84, 0.82, 0.07)); var p = Path(); p.move(to: P(0.16, 0.18)); p.addCurve(to: P(0.84, 0.82), control1: P(0.90, 0.10), control2: P(0.10, 0.90)); stroke(p)
        case "square.grid.3x1.below.line.grid.1x2":
            for i in 0..<3 { stroke(rrect(0.08 + 0.30 * CGFloat(i), 0.12, 0.24, 0.28, 0.03)) }; stroke(rrect(0.08, 0.56, 0.38, 0.32, 0.03)); stroke(rrect(0.54, 0.56, 0.38, 0.32, 0.03))
        case "dots": for i in 0..<3 { fill(circle(0.2 + 0.3 * CGFloat(i), 0.5, 0.07)) }
        case "star.fill": fill(polygon(P(0.5, 0.06), P(0.62, 0.38), P(0.96, 0.40), P(0.70, 0.60), P(0.79, 0.94), P(0.5, 0.74), P(0.21, 0.94), P(0.30, 0.60), P(0.04, 0.40), P(0.38, 0.38)))
        case "magnifyingglass": stroke(circle(0.44, 0.44, 0.30)); stroke(line(P(0.66, 0.66), P(0.92, 0.92)))
        case "lock.fill", "lock": stroke(rrect(0.2, 0.44, 0.6, 0.44, 0.06)); stroke(arc(0.5, 0.44, 0.2, 180, 360))
        default: stroke(rrect(0.14, 0.14, 0.72, 0.72, 0.1))
        }
    }
}
