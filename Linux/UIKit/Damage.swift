// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Schadensermittlung: Nach dem Neuaufbau einer Ansicht werden alter und neuer Teilbaum verglichen; neu gezeichnet wird nur,
// was sich sichtbar geändert hat. Knoten, deren Aussehen sich nicht sicher vergleichen lässt, gelten als geändert.
import Foundation
import CoreGraphics

private func hashShading(_ shading: GraphicsContext.Shading, into h: inout Hasher) {
    switch shading {
    case .color(let c): h.combine(0); h.combine(c)
    case .linearGradient(let g, let a, let b):
        h.combine(1); hashGradient(g, into: &h); h.combine(a.x); h.combine(a.y); h.combine(b.x); h.combine(b.y)
    case .radialGradient(let g, let c, let r0, let r1):
        h.combine(2); hashGradient(g, into: &h); h.combine(c.x); h.combine(c.y); h.combine(r0); h.combine(r1)
    }
}

private func hashGradient(_ g: Gradient, into h: inout Hasher) {
    for s in g.stops { h.combine(s.color); h.combine(s.location) }
}

private func hashPath(_ path: Path, into h: inout Hasher) {
    func point(_ p: CGPoint) { h.combine(p.x); h.combine(p.y) }
    func rect(_ r: CGRect) { h.combine(r.minX); h.combine(r.minY); h.combine(r.width); h.combine(r.height) }
    for e in path.elements {
        switch e {
        case .move(let p): h.combine(0); point(p)
        case .line(let p): h.combine(1); point(p)
        case .quad(let p, let c): h.combine(2); point(p); point(c)
        case .curve(let p, let c1, let c2): h.combine(3); point(p); point(c1); point(c2)
        case .close: h.combine(4)
        case .rect(let r): h.combine(5); rect(r)
        case .ellipse(let r): h.combine(6); rect(r)
        case .arc(let c, let r, let s, let e, let cw): h.combine(7); point(c); h.combine(r); h.combine(s); h.combine(e); h.combine(cw)
        }
    }
}

extension Node {
    /// Erweitert die Grenzen `r` (Rahmen samt Kindern) um das, was dieser Knoten über sie hinaus zeichnet. Vorher lag pauschal
    /// ein Rand von 40 pt um jede Änderung; der zog Nachbarn mit ins Neuzeichnen (beim Wasserfall Werkzeugleiste und Abstimmfeld).
    /// Die Werte folgen den Zeichenroutinen: `drawShadow` malt bis 3 σ mit σ = Radius/2 (also 1,5 × Radius) zuzüglich Versatz.
    func inkBounds(_ r: CGRect) -> CGRect {
        guard !r.isNull else { return r }
        switch self {
        case let n as DecorNode:
            switch n.kind {
            case .shadow(_, let radius, let x, let y):
                let spread = abs(radius) * 1.5 + 2
                return r.union(r.offsetBy(dx: x, dy: y).insetBy(dx: -spread, dy: -spread))
            case .blur(let radius):
                let spread = abs(radius) * 1.5 + 2
                return r.insetBy(dx: -spread, dy: -spread)
            case .clip, .clipPath:
                return r.intersection(n.frame.insetBy(dx: -1, dy: -1))
            case .rotate:
                // Drehung um die Mitte des Rahmens: Kreis um die Mitte, der alle Ecken enthält
                let c = CGPoint(x: n.frame.midX, y: n.frame.midY)
                let reach = [r.minX, r.maxX].flatMap { x in [r.minY, r.maxY].map { y in hypot(x - c.x, y - c.y) } }.max() ?? 0
                return r.union(CGRect(x: c.x - reach, y: c.y - reach, width: 2 * reach, height: 2 * reach)).insetBy(dx: -1, dy: -1)
            case .scale(let sx, let sy):
                let c = CGPoint(x: n.frame.midX, y: n.frame.midY), ax = max(1, abs(sx)), ay = max(1, abs(sy))
                let scaled = CGRect(x: c.x + (r.minX - c.x) * ax, y: c.y + (r.minY - c.y) * ay, width: r.width * ax, height: r.height * ay)
                return r.union(scaled).insetBy(dx: -1, dy: -1)
            default:
                return r
            }
        case let n as ShapeNode:
            // Striche liegen mittig auf dem Umriss (nach innen versetzte bleiben im Rahmen); Kantenglättung 1 pt
            guard n.stroke != nil, !n.inset else { return r.insetBy(dx: -1, dy: -1) }
            let half = (n.strokeStyle?.lineWidth ?? n.lineWidth) / 2 + 1
            return r.insetBy(dx: -half, dy: -half)
        case let n as TextNode:
            // Glyphen dürfen über die Zeilenbox ragen (Unterlängen, Akzente, Kursive)
            let over = max(2, n.spec.font.size * 0.25)
            return r.insetBy(dx: -over, dy: -over)
        default:
            return r
        }
    }

    /// Fasst alles zusammen, was dieser Knoten selbst (ohne Kinder) zum Bild beiträgt; `false`, wenn das nicht sicher bekannt ist
    func ownSignature(_ h: inout Hasher, shown: Bool, origin: CGPoint = .zero) -> Bool {
        switch self {
        case is StackNode, is SpacerNode, is FrameNode, is PaddingNode, is FixedSizeNode, is OffsetNode, is PositionNode,
             is ZStackNode, is LayerNode, is IDNode, is GroupNode, is CompositeNode, is AspectNode, is ButtonNode, is GeometryNode, is PureLayoutNode:
            return true
        case let n as TextNode:
            h.combine(n.spec)
            return true
        case let n as RichTextNode:
            // Der alte Knoten zählt mit dem Stand, den er zuletzt gezeigt hat; der neue mit dem aktuellen
            h.combine(shown ? (n.drawnSignature ?? n.signature()) : n.signature())
            return true
        case let n as SliderNode:
            h.combine(n.value); h.combine(n.range.lowerBound); h.combine(n.range.upperBound); h.combine(n.step); h.combine(n.tint)
            return true
        case is TextFieldNode, is MaskNode:
            // Eingabefeld: ein eigenes GTK-Widget, auf der Fläche zeichnet der Knoten nichts. Maske: zeichnet nur ihre Kinder
            // (Inhalt und Maskenform), die einzeln verglichen werden; ihre Lage steckt im Rahmen.
            return true
        case let n as DividerNode:
            h.combine(n.axis == .horizontal)
            return true
        case let n as ShapeNode:
            h.combine(String(describing: type(of: n.shape)))
            let rect = n.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            hashPath(n.shape.path(in: rect), into: &h)
            if let fill = n.fill { h.combine(1); hashShading(fill.shading(in: rect), into: &h) } else { h.combine(0) }
            if let stroke = n.stroke { h.combine(1); hashShading(stroke.shading(in: rect), into: &h) } else { h.combine(0) }
            h.combine(n.lineWidth); h.combine(n.inset)
            if let s = n.strokeStyle { h.combine(s.lineWidth); h.combine(s.lineCap.rawValue); h.combine(s.lineJoin.rawValue); h.combine(s.dash) }
            return true
        case let n as ImageNode:
            switch n.source {
            case .symbol(let name): h.combine(name)
            case .bitmap(let image): h.combine(ObjectIdentifier(image))
            }
            h.combine(n.resizable); h.combine(n.nearest); h.combine(n.color); h.combine(n.fontSize)
            return true
        case let n as DecorNode:
            switch n.kind {
            case .opacity(let a): h.combine(0); h.combine(a)
            case .clip(let r): h.combine(1); h.combine(r)
            case .clipPath: return false
            case .shadow(let c, let r, let x, let y): h.combine(3); h.combine(c); h.combine(r); h.combine(x); h.combine(y)
            case .rotate(let a): h.combine(4); h.combine(a)
            case .scale(let x, let y): h.combine(5); h.combine(x); h.combine(y)
            case .blur(let r): h.combine(6); h.combine(r)
            case .hidden: h.combine(7)
            case .ignoreHits: h.combine(8)
            case .contentShape: h.combine(9)
            }
            return true
        default:
            return false
        }
    }
}

extension Node {
    /// Fingerabdruck des Aussehens dieses Teilbaums, unabhängig von seiner Lage (Koordinaten relativ zu seiner Oberkante links);
    /// nil, wenn ein Knoten darin nicht sicher vergleichbar ist
    func appearanceSignature() -> Int? {
        var h = Hasher()
        guard hashAppearance(&h, origin: frame.origin) else { return nil }
        return h.finalize()
    }

    private func hashAppearance(_ h: inout Hasher, origin: CGPoint) -> Bool {
        h.combine(ObjectIdentifier(type(of: self)))
        h.combine(frame.minX - origin.x); h.combine(frame.minY - origin.y); h.combine(frame.width); h.combine(frame.height)
        h.combine(enabled)
        guard ownSignature(&h, shown: false, origin: origin) else { return false }
        h.combine(children.count)
        for c in children where !c.hashAppearance(&h, origin: origin) { return false }
        return true
    }
}

extension UIHost {
    /// Meldet als Schaden, was sich zwischen den beiden Knotenlisten (gleiche Stelle im Baum) sichtbar unterscheidet
    func addDamage(old: [Node], new: [Node]) {
        guard old.count == new.count else {
            if UIHost.damageTrace, let n = (old + new).max(by: { $0.subtreeBounds().width * $0.subtreeBounds().height < $1.subtreeBounds().width * $1.subtreeBounds().height }) { UIHost.traceReason("Anzahl \(old.count)→\(new.count) bei \(type(of: n)) \(n.subtreeBounds().size)") }
            for n in old + new { addDamage(n.subtreeBounds()) }
            return
        }
        for (o, n) in zip(old, new) {
            if o === n { continue }
            var ho = Hasher(), hn = Hasher()
            let comparable = type(of: o) == type(of: n) && o.frame == n.frame && o.enabled == n.enabled && o.ownSignature(&ho, shown: true) && n.ownSignature(&hn, shown: false)
            if comparable && ho.finalize() == hn.finalize() {
                addDamage(old: o.children, new: n.children)
            } else {
                if UIHost.damageTrace {
                    let why = type(of: o) != type(of: n) ? "Typ \(type(of: o))→\(type(of: n))" : (o.frame != n.frame ? "Rahmen \(type(of: o)) \(o.frame)→\(n.frame)" : (comparable ? "Inhalt \(type(of: o))" : "unbekannt \(type(of: o))"))
                    UIHost.traceReason(why + " Fläche \(Int(o.subtreeBounds().width))x\(Int(o.subtreeBounds().height))")
                }
                addDamage(o.subtreeBounds()); addDamage(n.subtreeBounds())
            }
        }
    }
}

extension UIHost {
    static let damageTrace = ProcessInfo.processInfo.environment["DIGIDEC_TRACE_DAMAGE"] != nil
    nonisolated(unsafe) private static var reasons: [String: Int] = [:]
    nonisolated(unsafe) private static var lastReport = Date()
    static func traceReason(_ s: String) {
        reasons[s, default: 0] += 1
        if Date().timeIntervalSince(lastReport) > 3 {
            lastReport = Date()
            for (k, v) in reasons.sorted(by: { $0.value > $1.value }).prefix(12) { FileHandle.standardError.write(Data("  \(v)x \(k)\n".utf8)) }
            FileHandle.standardError.write(Data("---\n".utf8))
            reasons.removeAll()
        }
    }
}
