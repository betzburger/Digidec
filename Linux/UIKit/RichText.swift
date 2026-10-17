// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Textfläche für fortlaufend wachsenden Text mit Farben je Abschnitt: hängt an, folgt dem Ende, scrollt mit dem Rad, markiert mit der Maus
// und kopiert. Gegenstück zu NSTextView in der Mac-Oberfläche.
import Foundation
import CGtkCairo

public final class RichTextBuffer {
    public struct Run { public var range: Range<Int>; public var color: Color; public var size: CGFloat; public var weight: Font.Weight; public var tag: Bool }

    public private(set) var text = ""
    public private(set) var runs: [Run] = []
    /// Auswahl in Zeichen (UTF-8-Bytes)
    public var selection: Range<Int>?
    public var scrollOffset: CGFloat = 0
    public var followsEnd = true
    var revision = 0
    public var family = "Noto Sans Mono,Adwaita Mono,monospace"
    weak var node: RichTextNode?

    /// Markiert die Stelle und rollt sie ins Bild
    @MainActor public func reveal(range: Range<Int>) { node?.reveal(range: range) }

    public init() {}

    public func append(_ s: String, color: Color, size: CGFloat, weight: Font.Weight = .regular, tag: Bool = false) {
        guard !s.isEmpty else { return }
        let start = text.utf8.count
        text += s
        runs.append(Run(range: start..<(start + s.utf8.count), color: color, size: size, weight: weight, tag: tag))
        revision &+= 1
    }

    public func clear() { text = ""; runs = []; selection = nil; scrollOffset = 0; followsEnd = true; revision &+= 1 }

    /// Farben der Abschnitte nach einem Themewechsel neu setzen
    public func recolor(_ transform: (Run) -> Color) {
        runs = runs.map { var r = $0; r.color = transform(r); return r }
        revision &+= 1
    }

    public var selectedText: String? {
        guard let selection, selection.count > 0 else { return nil }
        let bytes = Array(text.utf8)
        return String(decoding: bytes[selection], as: UTF8.self)
    }
}

public struct RichTextView {
    let buffer: RichTextBuffer
    var inset: CGFloat = 8
    var onMenu: ((RichTextBuffer) -> [(title: String, action: () -> Void)])?
    public init(buffer: RichTextBuffer, inset: CGFloat = 8, onMenu: ((RichTextBuffer) -> [(title: String, action: () -> Void)])? = nil) {
        self.buffer = buffer; self.inset = inset; self.onMenu = onMenu
    }
}

extension RichTextView: PrimitiveView {
    @MainActor func makeNodes(_ r: Resolver) -> [Node] {
        let node = RichTextNode(identity: r.identity, buffer: buffer, inset: inset, host: r.host)
        buffer.node = node
        if let host = r.host {
            let buffer = self.buffer, menu = onMenu
            node.contextMenu = { [weak node] point in
                guard let node else { return }
                var rows: [MenuRow] = (menu?(buffer) ?? []).map { item in MenuRow(title: item.title, action: item.action) }
                if buffer.selectedText != nil {
                    rows.append(MenuRow(title: "", separator: true))
                    rows.append(MenuRow(title: "Kopieren", action: { node.copySelection() }))
                }
                host.presentMenu(rows: rows, at: point)
            }
            host.registerShortcut(key: "c", command: true, enabled: buffer.selectedText != nil, action: { [weak node] in node?.copySelection() })
        }
        return [node]
    }
}

@MainActor
final class RichTextNode: Node {
    let buffer: RichTextBuffer
    let inset: CGFloat
    weak var host: UIHost?
    private var layout: OpaquePointer?
    private var layoutRevision = -1
    private var layoutWidth: CGFloat = -1
    private var contentHeight: CGFloat = 0
    private var dragAnchor: Int?

    init(identity: Identity, buffer: RichTextBuffer, inset: CGFloat, host: UIHost?) {
        self.buffer = buffer; self.inset = inset; self.host = host
        super.init(identity: identity)
        handlers = Handlers(drag: DragHandler(minimumDistance: 0, changed: { [unowned self] v in self.drag(v) }, ended: { _ in }),
                            scroll: { [unowned self] _, dy in self.wheel(dy) })
    }

    override var clipsHits: Bool { true }

    override func computeSize(_ p: Proposal) -> CGSize {
        CGSize(width: p.width.flatMap { $0.isFinite ? $0 : nil } ?? 200, height: p.height.flatMap { $0.isFinite ? $0 : nil } ?? 100)
    }

    // MARK: Layout

    private func ensureLayout(width: CGFloat, cr: OpaquePointer?) {
        let w = max(10, width - 2 * inset)
        if layout != nil, layoutRevision == buffer.revision, layoutWidth == w { return }
        if let old = layout { g_object_unref(UnsafeMutableRawPointer(old)) }
        let measure = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1)!
        let context = cairo_create(measure)!
        defer { cairo_destroy(context); cairo_surface_destroy(measure) }
        let layout = pango_cairo_create_layout(context)!
        let desc = pango_font_description_new()!
        pango_font_description_set_family(desc, buffer.family)
        pango_font_description_set_absolute_size(desc, 13 * Double(PANGO_SCALE))
        pango_layout_set_font_description(layout, desc)
        pango_font_description_free(desc)
        pango_layout_set_text(layout, buffer.text, -1)
        pango_layout_set_width(layout, Int32(w * CGFloat(PANGO_SCALE)))
        pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR)
        let attrs = pango_attr_list_new()!
        for run in buffer.runs {
            func span(_ a: UnsafeMutablePointer<PangoAttribute>?) {
                guard let a else { return }
                a.pointee.start_index = UInt32(run.range.lowerBound); a.pointee.end_index = UInt32(run.range.upperBound)
                pango_attr_list_insert(attrs, a)
            }
            span(pango_attr_foreground_new(UInt16(run.color.red * 65535), UInt16(run.color.green * 65535), UInt16(run.color.blue * 65535)))
            span(pango_attr_size_new_absolute(Int32(run.size * CGFloat(PANGO_SCALE))))
            span(pango_attr_weight_new(PangoWeight(rawValue: UInt32(run.weight.rawValue))))
            span(pango_attr_line_height_new_absolute(Int32((run.size * 1.3).rounded() * CGFloat(PANGO_SCALE))))
        }
        pango_layout_set_attributes(layout, attrs)
        pango_attr_list_unref(attrs)
        self.layout = layout
        layoutRevision = buffer.revision
        layoutWidth = w
        var pw: Int32 = 0, ph: Int32 = 0
        pango_layout_get_size(layout, &pw, &ph)
        contentHeight = CGFloat(ph) / CGFloat(PANGO_SCALE) + 2 * inset
    }

    private func clampedOffset() -> CGFloat {
        let maxOffset = max(0, contentHeight - frame.height)
        if buffer.followsEnd { buffer.scrollOffset = maxOffset }
        buffer.scrollOffset = min(max(0, buffer.scrollOffset), maxOffset)
        return buffer.scrollOffset
    }

    private func wheel(_ dy: CGFloat) -> Bool {
        let maxOffset = max(0, contentHeight - frame.height)
        guard maxOffset > 0 else { return false }
        buffer.scrollOffset = min(max(0, buffer.scrollOffset + dy), maxOffset)
        buffer.followsEnd = buffer.scrollOffset >= maxOffset - 2
        host?.setNeedsDraw()
        return true
    }

    // MARK: Auswahl

    private func index(at p: CGPoint) -> Int? {
        guard let layout else { return nil }
        let x = (p.x - frame.minX - inset) * CGFloat(PANGO_SCALE)
        let y = (p.y - frame.minY - inset + buffer.scrollOffset) * CGFloat(PANGO_SCALE)
        var idx: Int32 = 0, trailing: Int32 = 0
        pango_layout_xy_to_index(layout, Int32(x), Int32(y), &idx, &trailing)
        return Int(idx) + (trailing > 0 ? 1 : 0)
    }

    private func drag(_ v: DragValue) {
        guard let i = index(at: v.location), let start = index(at: v.startLocation) else { return }
        let lo = min(start, i), hi = max(start, i)
        buffer.selection = lo == hi ? nil : lo..<hi
        host?.setNeedsDraw()
    }

    func copySelection() {
        if let t = buffer.selectedText { clipboardHook(t) }
    }

    // MARK: Zeichnen

    override func draw(_ g: inout GraphicsContext, clip: CGRect) {
        let cr = g.cr
        ensureLayout(width: frame.width, cr: cr)
        guard let layout else { return }
        let offset = clampedOffset()
        cairo_save(cr)
        cairo_rectangle(cr, frame.minX, frame.minY, frame.width, frame.height)
        cairo_clip(cr)
        let origin = CGPoint(x: frame.minX + inset, y: frame.minY + inset - offset)
        if let sel = buffer.selection {
            cairo_set_source_rgba(cr, 0.25, 0.55, 1, 0.45)
            let iter = pango_layout_get_iter(layout)!
            repeat {
                guard let line = pango_layout_iter_get_line_readonly(iter) else { continue }
                let start = Int(line.pointee.start_index), end = start + Int(line.pointee.length)
                if end < sel.lowerBound || start > sel.upperBound { continue }
                var ranges: UnsafeMutablePointer<Int32>?
                var count: Int32 = 0
                pango_layout_line_get_x_ranges(line, Int32(max(sel.lowerBound, start)), Int32(min(sel.upperBound, end)), &ranges, &count)
                var y0: Int32 = 0, y1: Int32 = 0
                pango_layout_iter_get_line_yrange(iter, &y0, &y1)
                if let ranges {
                    for k in 0..<Int(count) {
                        let x0 = CGFloat(ranges[2 * k]) / CGFloat(PANGO_SCALE), x1 = CGFloat(ranges[2 * k + 1]) / CGFloat(PANGO_SCALE)
                        cairo_rectangle(cr, origin.x + x0, origin.y + CGFloat(y0) / CGFloat(PANGO_SCALE), x1 - x0, CGFloat(y1 - y0) / CGFloat(PANGO_SCALE))
                        cairo_fill(cr)
                    }
                    g_free(ranges)
                }
            } while pango_layout_iter_next_line(iter) != 0
            pango_layout_iter_free(iter)
        }
        cairo_move_to(cr, origin.x, origin.y)
        pango_cairo_show_layout(cr, layout)
        cairo_restore(cr)
        // Rollbalken
        if contentHeight > frame.height + 1 {
            let h = max(24, frame.height * frame.height / contentHeight)
            let y = frame.minY + (frame.height - h) * (offset / max(1, contentHeight - frame.height))
            g.fill(Path(roundedRect: CGRect(x: frame.maxX - 6, y: y + 1, width: 4, height: h - 2), cornerRadius: 2), with: .color(Color(white: 1, opacity: 0.28)))
        }
    }

    /// Markiert und zeigt die Stelle (für „Rohmeldung zeigen“)
    func reveal(range: Range<Int>) {
        buffer.selection = range
        guard let layout else { return }
        var pos = PangoRectangle()
        pango_layout_index_to_pos(layout, Int32(range.lowerBound), &pos)
        buffer.followsEnd = false
        buffer.scrollOffset = max(0, CGFloat(pos.y) / CGFloat(PANGO_SCALE) - frame.height / 3)
        host?.setNeedsDraw()
    }
}
