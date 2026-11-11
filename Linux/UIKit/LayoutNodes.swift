// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Stapel, Rahmen, Abstände, Hintergründe und die übrigen Layoutknoten.
import Foundation
import CGtkCairo

// MARK: - Stapel

@MainActor
final class StackNode: Node {
    let axis: Axis
    let alignment: Alignment
    let spacing: CGFloat

    init(identity: Identity, axis: Axis, alignment: Alignment, spacing: CGFloat) {
        self.axis = axis; self.alignment = alignment; self.spacing = spacing
        super.init(identity: identity)
    }

    private var cross: Axis { axis == .horizontal ? .vertical : .horizontal }

    /// Größen der Kinder für einen Vorschlag (Verteilung wie SwiftUI: unflexible zuerst, Rest gleichmäßig)
    func childSizes(_ p: Proposal) -> [CGSize] {
        let n = children.count
        guard n > 0 else { return [] }
        var sizes = [CGSize](repeating: .zero, count: n)
        let totalSpacing = spacing * CGFloat(n - 1)
        guard let mainProposal = p.along(axis), mainProposal.isFinite else {
            for i in 0..<n { sizes[i] = children[i].size(for: p.with(axis, nil)) }
            return sizes
        }
        var lo = [CGFloat](repeating: 0, count: n), hi = lo
        for i in 0..<n {
            lo[i] = children[i].size(for: p.with(axis, 0)).along(axis)
            let h = children[i].size(for: p.with(axis, .infinity)).along(axis)
            hi[i] = h.isFinite ? h : .infinity
        }
        var remaining = mainProposal - totalSpacing
        let priorities = Set(children.map(\.layoutPriority)).sorted(by: >)
        var done = Set<Int>()
        for priority in priorities {
            var group = (0..<n).filter { children[$0].layoutPriority == priority }
            group.sort { (hi[$0] - lo[$0]) < (hi[$1] - lo[$1]) }
            let reserved = (0..<n).filter { children[$0].layoutPriority < priority && !done.contains($0) }.reduce(0) { $0 + lo[$1] }
            var left = group.count
            for (position, i) in group.enumerated() {
                // Ein Kind mit endlicher Wunschgröße bekommt sie, wenn die übrigen noch mit ihrer Mindestgröße Platz haben
                let laterMinimum = group[(position + 1)...].reduce(0) { $0 + lo[$1] }
                var share = max(0, (remaining - reserved) / CGFloat(left))
                if hi[i].isFinite { share = max(share, min(hi[i], remaining - reserved - laterMinimum)) }
                let s = children[i].size(for: p.with(axis, share))
                sizes[i] = s
                remaining -= s.along(axis)
                left -= 1
                done.insert(i)
            }
        }
        return sizes
    }

    override func computeSize(_ p: Proposal) -> CGSize {
        let sizes = childSizes(p)
        guard !sizes.isEmpty else { return .zero }
        let main = sizes.reduce(0) { $0 + $1.along(axis) } + spacing * CGFloat(sizes.count - 1)
        return CGSize.make(axis, main: main, cross: crossExtent(sizes))
    }

    private var usesBaseline: Bool { axis == .horizontal && alignment.vertical.isBaseline }

    private func crossExtent(_ sizes: [CGSize]) -> CGFloat {
        if usesBaseline {
            let baselines = zip(children, sizes).map { $1.height - ($0.firstBaseline.map { _ in 0 } ?? 0) }
            _ = baselines
            let ascent = zip(children, sizes).map { $0.firstBaseline ?? $1.height }.max() ?? 0
            return zip(children, sizes).map { (ascent - ($0.firstBaseline ?? $1.height)) + $1.height }.max() ?? 0
        }
        return sizes.map { $0.along(cross) }.max() ?? 0
    }

    override var firstBaseline: CGFloat? {
        if axis == .horizontal { return children.compactMap(\.firstBaseline).first }
        return children.first?.firstBaseline
    }

    override func placeChildren() {
        let sizes = childSizes(.fixed(frame.size))
        var position: CGFloat = axis == .horizontal ? frame.minX : frame.minY
        let ascent = usesBaseline ? (zip(children, sizes).map { $0.firstBaseline ?? $1.height }.max() ?? 0) : 0
        for (i, c) in children.enumerated() {
            let s = sizes[i]
            let free = (axis == .horizontal ? frame.height : frame.width) - s.along(cross)
            var crossOffset: CGFloat
            if axis == .horizontal {
                crossOffset = usesBaseline ? ascent - (c.firstBaseline ?? s.height) : alignment.vertical.offset(in: free)
                c.place(origin: CGPoint(x: position, y: frame.minY + crossOffset), size: s)
            } else {
                crossOffset = alignment.horizontal.offset(in: free)
                c.place(origin: CGPoint(x: frame.minX + crossOffset, y: position), size: s)
            }
            position += s.along(axis) + spacing
        }
    }
}

@MainActor
final class SpacerNode: Node {
    let minLength: CGFloat
    let axis: Axis?
    init(identity: Identity, minLength: CGFloat, axis: Axis?) { self.minLength = minLength; self.axis = axis; super.init(identity: identity) }
    /// Nimmt, was vorgeschlagen wird (mindestens `minLength`). Auf einen unendlichen Vorschlag antwortet er mit unendlicher Länge wie in
    /// SwiftUI: Daran misst der Stapel die Flexibilität. Mit der Mindestlänge galt er als starr, bekam nur einen Anteil statt des
    /// ganzen Rests, und Zeilen blieben in breiten Fenstern schmaler als das Fenster (Kopfzeile mittig statt Logo links).
    override func computeSize(_ p: Proposal) -> CGSize {
        func length(_ v: CGFloat?) -> CGFloat {
            guard let v else { return minLength }
            return v.isInfinite ? .infinity : max(minLength, v)
        }
        switch axis {
        case .horizontal?: return CGSize(width: length(p.width), height: 0)
        case .vertical?: return CGSize(width: 0, height: length(p.height))
        case nil: return CGSize(width: length(p.width), height: length(p.height))
        }
    }
}

// MARK: - Rahmen

@MainActor
final class FrameNode: WrapperNode {
    var width: CGFloat?, height: CGFloat?
    var minWidth: CGFloat?, idealWidth: CGFloat?, maxWidth: CGFloat?
    var minHeight: CGFloat?, idealHeight: CGFloat?, maxHeight: CGFloat?
    var alignment: Alignment = .center

    private func childProposal(_ p: Proposal) -> Proposal {
        func axis(_ proposed: CGFloat?, fixed: CGFloat?, min: CGFloat?, ideal: CGFloat?, max: CGFloat?) -> CGFloat? {
            if let fixed { return fixed }
            var v = proposed ?? ideal
            if var x = v {
                if let max, x > max { x = max }
                if let min, x < min { x = min }
                v = x
            }
            return v
        }
        return Proposal(width: axis(p.width, fixed: width, min: minWidth, ideal: idealWidth, max: maxWidth),
                        height: axis(p.height, fixed: height, min: minHeight, ideal: idealHeight, max: maxHeight))
    }

    override func computeSize(_ p: Proposal) -> CGSize {
        let cp = childProposal(p)
        let s = child?.size(for: cp) ?? .zero
        func result(_ v: CGFloat, proposed: CGFloat?, fixed: CGFloat?, min: CGFloat?, max: CGFloat?) -> CGFloat {
            if let fixed { return fixed }
            var r = v
            if let max, max.isInfinite, let proposed, proposed.isFinite { r = proposed }
            if let max, max.isFinite, r > max { r = max }
            if let min, r < min { r = min }
            if !r.isFinite { r = v.isFinite ? v : 0 }
            return r
        }
        return CGSize(width: result(s.width, proposed: p.width, fixed: width, min: minWidth, max: maxWidth),
                      height: result(s.height, proposed: p.height, fixed: height, min: minHeight, max: maxHeight))
    }

    override func placeChildren() {
        guard let child else { return }
        let cs = child.size(for: childProposal(.fixed(frame.size)))
        let dx = alignment.horizontal.offset(in: frame.width - cs.width)
        var dy = alignment.vertical.offset(in: frame.height - cs.height)
        if alignment.vertical.isBaseline, let b = child.firstBaseline { dy = min(dy, max(0, frame.height - cs.height)) ; _ = b }
        child.place(origin: CGPoint(x: frame.minX + dx, y: frame.minY + dy), size: cs)
    }
}

@MainActor
final class PaddingNode: WrapperNode {
    var insets: EdgeInsets = EdgeInsets()
    override func computeSize(_ p: Proposal) -> CGSize {
        let w = p.width.map { $0.isFinite ? max(0, $0 - insets.leading - insets.trailing) : $0 }
        let h = p.height.map { $0.isFinite ? max(0, $0 - insets.top - insets.bottom) : $0 }
        let s = child?.size(for: Proposal(width: w, height: h)) ?? .zero
        return CGSize(width: s.width + insets.leading + insets.trailing, height: s.height + insets.top + insets.bottom)
    }
    override var firstBaseline: CGFloat? { child?.firstBaseline.map { $0 + insets.top } }
    override func placeChildren() {
        guard let child else { return }
        let inner = CGSize(width: max(0, frame.width - insets.leading - insets.trailing), height: max(0, frame.height - insets.top - insets.bottom))
        child.place(origin: CGPoint(x: frame.minX + insets.leading, y: frame.minY + insets.top), size: child.size(for: .fixed(inner)))
    }
}

@MainActor
final class FixedSizeNode: WrapperNode {
    var horizontal = true, vertical = true
    override func computeSize(_ p: Proposal) -> CGSize {
        child?.size(for: Proposal(width: horizontal ? nil : p.width, height: vertical ? nil : p.height)) ?? .zero
    }
    override func placeChildren() {
        guard let child else { return }
        child.place(origin: frame.origin, size: child.size(for: Proposal(width: horizontal ? nil : frame.width, height: vertical ? nil : frame.height)))
    }
}

@MainActor
final class OffsetNode: WrapperNode {
    var dx: CGFloat = 0, dy: CGFloat = 0
    override func placeChildren() {
        guard let child else { return }
        child.place(origin: CGPoint(x: frame.minX + dx, y: frame.minY + dy), size: child.size(for: .fixed(frame.size)))
    }
}

@MainActor
final class PositionNode: WrapperNode {
    var x: CGFloat = 0, y: CGFloat = 0
    override func computeSize(_ p: Proposal) -> CGSize { CGSize(width: p.width ?? 10, height: p.height ?? 10) }
    override func placeChildren() {
        guard let child else { return }
        let s = child.size(for: .unspecified)
        child.place(origin: CGPoint(x: frame.minX + x - s.width / 2, y: frame.minY + y - s.height / 2), size: s)
    }
}

@MainActor
final class ZStackNode: Node {
    let alignment: Alignment
    init(identity: Identity, alignment: Alignment) { self.alignment = alignment; super.init(identity: identity) }
    override func computeSize(_ p: Proposal) -> CGSize {
        var w: CGFloat = 0, h: CGFloat = 0
        for c in children { let s = c.size(for: p); w = max(w, s.width); h = max(h, s.height) }
        return CGSize(width: w, height: h)
    }
    override func placeChildren() {
        for c in children {
            let s = c.size(for: .fixed(frame.size))
            c.place(origin: CGPoint(x: frame.minX + alignment.horizontal.offset(in: frame.width - s.width),
                                    y: frame.minY + alignment.vertical.offset(in: frame.height - s.height)), size: s)
        }
    }
}

/// `.background` und `.overlay`: Der Inhalt bestimmt die Größe, die Ebenen füllen seinen Rahmen
@MainActor
final class LayerNode: Node {
    let content: Node
    let layers: [Node]
    let behind: Bool
    let alignment: Alignment

    init(identity: Identity, content: Node, layers: [Node], behind: Bool, alignment: Alignment) {
        self.content = content; self.layers = layers; self.behind = behind; self.alignment = alignment
        super.init(identity: identity)
        children = behind ? layers + [content] : [content] + layers
    }
    override func computeSize(_ p: Proposal) -> CGSize { content.size(for: p) }
    override var firstBaseline: CGFloat? { content.firstBaseline }
    override func placeChildren() {
        content.place(origin: frame.origin, size: content.size(for: .fixed(frame.size)))
        for l in layers {
            let s = l.size(for: .fixed(frame.size))
            l.place(origin: CGPoint(x: frame.minX + alignment.horizontal.offset(in: frame.width - s.width),
                                    y: frame.minY + alignment.vertical.offset(in: frame.height - s.height)), size: s)
        }
    }
}

/// Reicht Größe und Platzierung durch, zeichnet aber mit Beschnitt, Deckkraft, Schatten oder Drehung
@MainActor
final class DecorNode: WrapperNode {
    enum Kind {
        case opacity(Double)
        case clip(cornerRadius: CGFloat)
        case clipPath((CGRect) -> Path)
        case shadow(color: Color, radius: CGFloat, x: CGFloat, y: CGFloat)
        case rotate(angle: Double)
        case scale(x: CGFloat, y: CGFloat)
        case blur(CGFloat)
        case hidden
        case ignoreHits
        case contentShape
    }
    let kind: Kind
    init(identity: Identity, child: Node?, kind: Kind) { self.kind = kind; super.init(identity: identity, child: child) }

    override var clipsHits: Bool { if case .clip = kind { return true }; if case .clipPath = kind { return true }; return false }

    override func hit(_ p: CGPoint, into chain: inout [Node]) {
        switch kind {
        case .ignoreHits, .hidden: return
        case .contentShape:
            if frame.contains(p) { child?.hit(p, into: &chain); chain.append(self) }  // macht den ganzen Rahmen treffbar
            else { child?.hit(p, into: &chain) }
        default: super.hit(p, into: &chain)
        }
    }

    override func draw(_ g: inout GraphicsContext, clip: CGRect) {
        guard let child else { return }
        let cr = g.cr
        switch kind {
        case .hidden, .ignoreHits, .contentShape:
            if case .hidden = kind { return }
            child.draw(&g, clip: clip)
        case .opacity(let a):
            if a >= 0.999 { child.draw(&g, clip: clip); return }
            g.drawOpacityGroup(alpha: a, bounds: child.subtreeBounds().intersection(clip.insetBy(dx: -1, dy: -1)).insetBy(dx: -1, dy: -1)) { inner in child.draw(&inner, clip: clip) }
        case .clip(let radius):
            cairo_save(cr)
            let shape = radius > 0 ? Path(roundedRect: frame, cornerRadius: radius) : Path(frame)
            g.clip(to: shape)
            child.draw(&g, clip: clip.intersection(frame))
            cairo_restore(cr)
        case .clipPath(let make):
            cairo_save(cr)
            g.clip(to: make(frame))
            child.draw(&g, clip: clip.intersection(frame))
            cairo_restore(cr)
        case .shadow(let color, let radius, let x, let y):
            g.drawShadow(color: color, radius: radius, x: x, y: y, bounds: child.subtreeBounds(), signature: child.appearanceSignature()) { inner in child.draw(&inner, clip: .infinite) }  // die Silhouette wird zwischengespeichert und muss vollständig sein
            child.draw(&g, clip: clip)
        case .rotate(let angle):
            cairo_save(cr)
            cairo_translate(cr, frame.midX, frame.midY)
            cairo_rotate(cr, angle)
            cairo_translate(cr, -frame.midX, -frame.midY)
            child.draw(&g, clip: .infinite)
            cairo_restore(cr)
        case .scale(let sx, let sy):
            cairo_save(cr)
            cairo_translate(cr, frame.midX, frame.midY)
            cairo_scale(cr, sx, sy)
            cairo_translate(cr, -frame.midX, -frame.midY)
            child.draw(&g, clip: .infinite)
            cairo_restore(cr)
        case .blur(let radius):
            g.drawLayer { inner in
                inner.addFilter(.blur(radius: radius))
                child.draw(&inner, clip: clip.insetBy(dx: -radius * 3, dy: -radius * 3))
            }
        }
    }
}

/// Knoten, die nur Rahmen vorgeben und Kinder zeichnen (z. B. Anker für Kennungen)
@MainActor
final class IDNode: WrapperNode {}
