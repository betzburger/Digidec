// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Auswahl und Menüs: Picker (Menü und segmentiert), Menu, Kontextmenü und das Aufklappmenü selbst.
import Foundation
import CGtkCairo

// MARK: - Menüzeilen

struct MenuRow {
    var title: String
    var selected = false
    var enabled = true
    var separator = false
    var action: () -> Void = {}
}

@MainActor
func menuRows(from nodes: [Node]) -> [MenuRow] {
    var rows: [MenuRow] = []
    func firstText(_ n: Node) -> String? {
        if let t = n as? TextNode { return t.spec.text }
        for c in n.children { if let s = firstText(c) { return s } }
        return nil
    }
    func visit(_ n: Node) {
        if n is DividerNode { rows.append(MenuRow(title: "", separator: true)); return }
        if let b = n as? ButtonNode {
            rows.append(MenuRow(title: firstText(b) ?? "", enabled: b.enabled, action: { b.handlers?.tap?() }))
            return
        }
        for c in n.children { visit(c) }
    }
    nodes.forEach(visit)
    return rows
}

struct MenuPopupView: PrimitiveView {
    let rows: [MenuRow]
    let dismiss: () -> Void
    func makeNodes(_ r: Resolver) -> [Node] { [MenuPopupNode(identity: r.identity, rows: rows, dismiss: dismiss, host: r.host)] }
}

@MainActor
final class MenuPopupNode: Node {
    let rows: [MenuRow]
    let dismiss: () -> Void
    weak var host: UIHost?
    var hoverIndex: Int?
    static let rowHeight: CGFloat = 22

    init(identity: Identity, rows: [MenuRow], dismiss: @escaping () -> Void, host: UIHost?) {
        self.rows = rows; self.dismiss = dismiss; self.host = host
        super.init(identity: identity)
        handlers = Handlers(tap: { [unowned self] in self.activate() }, motion: { [unowned self] p in
            let i = self.index(at: p)
            if i != self.hoverIndex { self.hoverIndex = i; self.host?.setNeedsDraw() }
        })
    }

    private func rowTop(_ i: Int) -> CGFloat { rows[0..<i].reduce(0) { $0 + ($1.separator ? 9 : Self.rowHeight) } }

    private func index(at p: CGPoint) -> Int? {
        let y = p.y - frame.minY - 4
        guard y >= 0 else { return nil }
        for (i, row) in rows.enumerated() where !row.separator {
            let top = rowTop(i)
            if y >= top && y < top + Self.rowHeight { return i }
        }
        return nil
    }

    private func activate() {
        guard let host, let i = index(at: host.pointer), rows[i].enabled else { return }
        dismiss()
        rows[i].action()
    }

    override func computeSize(_ p: Proposal) -> CGSize {
        var spec = TextSpec(text: "", font: .system(size: 13), color: .white, lineLimit: 1, tracking: 0, minScale: 1, alignment: .leading, underline: false, strikethrough: false)
        var width: CGFloat = 80
        for row in rows where !row.separator { spec.text = row.title; width = max(width, TextEngine.measure(spec, width: nil).size.width + 40) }
        return CGSize(width: width, height: rowTop(rows.count) + 8)
    }

    override func draw(_ g: inout GraphicsContext, clip: CGRect) {
        let panel = Path(roundedRect: frame, cornerRadius: 8)
        g.fill(panel, with: .color(Color(white: 0.17)))
        g.stroke(panel, with: .color(Color(white: 1, opacity: 0.16)), lineWidth: 1)
        for (i, row) in rows.enumerated() {
            let y = frame.minY + 4 + rowTop(i)
            if row.separator { g.fill(Path(CGRect(x: frame.minX + 8, y: y + 4, width: frame.width - 16, height: 1)), with: .color(Color(white: 1, opacity: 0.14))); continue }
            let area = CGRect(x: frame.minX + 4, y: y, width: frame.width - 8, height: Self.rowHeight)
            if hoverIndex == i && row.enabled { g.fill(Path(roundedRect: area, cornerRadius: 4), with: .color(Color.accentColor)) }
            let spec = TextSpec(text: row.title, font: .system(size: 13), color: row.enabled ? Color.white : Color(white: 1, opacity: 0.4), lineLimit: 1, tracking: 0, minScale: 1, alignment: .leading, underline: false, strikethrough: false)
            let m = TextEngine.measure(spec, width: nil)
            TextEngine.draw(spec, in: CGRect(x: area.minX + 22, y: area.midY - m.size.height / 2, width: area.width - 28, height: m.size.height), cr: g.cr)
            if row.selected { Icons.draw("checkmark", in: CGRect(x: area.minX + 5, y: area.midY - 6, width: 12, height: 12), color: .white, g: &g) }
        }
    }
}

// MARK: - Menu

public struct MenuStyleKind: Sendable { public static let borderlessButton = MenuStyleKind(), button = MenuStyleKind(), automatic = MenuStyleKind() }
public struct MenuIndicatorVisibility: Sendable { public static let hidden = MenuIndicatorVisibility(), visible = MenuIndicatorVisibility(), automatic = MenuIndicatorVisibility() }
extension View {
    public func menuStyle(_ style: MenuStyleKind) -> some View { transformEnvironment { $0.plainMenu = true } }
    public func menuIndicator(_ v: MenuIndicatorVisibility) -> some View { self }
}
private struct PlainMenuKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue = false }
extension EnvironmentValues { var plainMenu: Bool { get { self[PlainMenuKey.self] } set { self[PlainMenuKey.self] = newValue } } }

public struct Menu<Label: View, Content: View>: PrimitiveView {
    let label: Label
    let content: Content
    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) { self.content = content(); self.label = label() }
    public init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) where Label == Text { self.content = content(); label = Text(title) }
    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) where Label == Text { self.content = content(); label = Text(title) }

    func makeNodes(_ r: Resolver) -> [Node] {
        let plain = r.env.plainMenu
        let rowsNodes = r.resolve(content, key: 1)
        let host = r.host
        let enabled = r.env.isEnabled
        let style: AnyButtonStyle
        if plain { style = AnyButtonStyle(PlainButtonStyle()) } else if let s = r.env.buttonStyle { style = s } else { style = AnyButtonStyle(DefaultButtonStyle()) }
        let body = style.make(ButtonStyleConfiguration(label: .init(view: label), isPressed: false))
        let node = ButtonNode(identity: r.identity, child: r.content(AnyView(body), key: 0))
        node.enabled = enabled
        let rows = menuRows(from: rowsNodes)
        node.handlers = Handlers(tap: { [unowned node] in
            guard enabled, let host else { return }
            let id = UUID()
            let layer = OverlayLayer(anchor: node.frame, modal: false, placement: .below, makeView: { MenuPopupView(rows: rows, dismiss: { host.overlays.removeAll { $0.id == id }; host.setNeedsResolve() }) }, onDismiss: { })
            layer.onDismiss = { [unowned host] in host.dismiss(layer.id) }
            host.present(layer)
        })
        return [node]
    }
}

// MARK: - Picker

public struct PickerStyleKind: Sendable, Equatable {
    let id: Int
    public static let menu = PickerStyleKind(id: 0), segmented = PickerStyleKind(id: 1), automatic = PickerStyleKind(id: 0), inline = PickerStyleKind(id: 0), radioGroup = PickerStyleKind(id: 0)
}
private struct PickerStyleKey: EnvironmentKey { nonisolated(unsafe) static var defaultValue = PickerStyleKind.menu }
extension EnvironmentValues { var pickerStyleKind: PickerStyleKind { get { self[PickerStyleKey.self] } set { self[PickerStyleKey.self] = newValue } } }
extension View { public func pickerStyle(_ style: PickerStyleKind) -> some View { transformEnvironment { $0.pickerStyleKind = style } } }

private func normalized(_ value: Any) -> AnyHashable? {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional { return mirror.children.first.flatMap { normalized($0.value) } }
    return value as? AnyHashable
}

public struct Picker<Label: View, SelectionValue: Hashable, Content: View>: PrimitiveView {
    let label: Label
    let selection: Binding<SelectionValue>
    let content: Content

    public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.selection = selection; self.content = content(); self.label = label()
    }
    public init(_ title: LocalizedStringKey, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) where Label == Text {
        self.selection = selection; self.content = content(); label = Text(title)
    }
    public init<S: StringProtocol>(_ title: S, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) where Label == Text {
        self.selection = selection; self.content = content(); label = Text(title)
    }

    func makeNodes(_ r: Resolver) -> [Node] {
        let options = r.resolve(content, key: 1)
        func firstText(_ n: Node) -> String? {
            if let t = n as? TextNode { return t.spec.text }
            for c in n.children { if let s = firstText(c) { return s } }
            return nil
        }
        var entries: [(tag: AnyHashable?, title: String)] = []
        func collect(_ n: Node) {
            if let tag = n.explicitID { entries.append((tag, firstText(n) ?? "")); return }
            for c in n.children { collect(c) }
        }
        options.forEach(collect)
        let current = normalized(selection.wrappedValue)
        let binding = selection
        let host = r.host
        let enabled = r.env.isEnabled
        let apply: (AnyHashable?) -> Void = { tag in
            // Der gespeicherte Wert hat den Typ von `SelectionValue` oder sein Optional
            if let t = tag?.base as? SelectionValue { binding.wrappedValue = t }
            else if let t = tag { if let opt = Optional(t.base) as? SelectionValue { binding.wrappedValue = opt } }
        }

        if r.env.pickerStyleKind == .segmented {
            let node = SegmentedNode(identity: r.identity, titles: entries.map(\.title), selected: entries.firstIndex { $0.tag == current }, host: host)
            node.enabled = enabled
            node.handlers = Handlers(tap: { [unowned node] in
                guard enabled, let i = node.segment(at: host?.pointer ?? .zero) else { return }
                apply(entries[i].tag)
            })
            return [node]
        }

        let selectedTitle = entries.first { $0.tag == current }?.title ?? ""
        let face = AnyView(HStack(spacing: 6) { Text(selectedTitle); Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)) })
        let style = r.env.plainMenu ? AnyButtonStyle(PlainButtonStyle()) : AnyButtonStyle(DefaultButtonStyle())
        let node = ButtonNode(identity: r.identity, child: r.content(AnyView(style.make(ButtonStyleConfiguration(label: .init(view: face), isPressed: false))), key: 0))
        node.enabled = enabled
        let rows = entries.map { e in MenuRow(title: e.title, selected: e.tag == current, action: { apply(e.tag) }) }
        node.handlers = Handlers(tap: { [unowned node] in
            guard enabled, let host else { return }
            let layer = OverlayLayer(anchor: node.frame, modal: false, placement: .below, makeView: { MenuPopupView(rows: rows, dismiss: { }) }, onDismiss: { })
            layer.makeView = { MenuPopupView(rows: rows, dismiss: { [unowned host] in host.dismiss(layer.id) }) }
            layer.onDismiss = { [unowned host] in host.dismiss(layer.id) }
            host.present(layer)
        })
        return [node]
    }
}

@MainActor
final class SegmentedNode: Node {
    let titles: [String]
    let selected: Int?
    weak var host: UIHost?
    init(identity: Identity, titles: [String], selected: Int?, host: UIHost?) { self.titles = titles; self.selected = selected; self.host = host; super.init(identity: identity) }

    private func segmentWidths(_ total: CGFloat?) -> [CGFloat] {
        let spec = { (t: String) in TextSpec(text: t, font: .system(size: 11), color: .white, lineLimit: 1, tracking: 0, minScale: 1, alignment: .leading, underline: false, strikethrough: false) }
        let natural = titles.map { TextEngine.measure(spec($0), width: nil).size.width + 20 }
        guard let total, total.isFinite, !titles.isEmpty else { return natural }
        let each = total / CGFloat(titles.count)
        return titles.map { _ in each }
    }

    override func computeSize(_ p: Proposal) -> CGSize {
        let widths = segmentWidths(p.width)
        return CGSize(width: widths.reduce(0, +), height: 22)
    }

    func segment(at pt: CGPoint) -> Int? {
        var x = frame.minX
        for (i, w) in segmentWidths(frame.width).enumerated() {
            if pt.x >= x && pt.x < x + w { return i }
            x += w
        }
        return nil
    }

    override func draw(_ g: inout GraphicsContext, clip: CGRect) {
        let outer = Path(roundedRect: frame, cornerRadius: 6)
        g.fill(outer, with: .color(Color(white: 0, opacity: 0.35)))
        g.stroke(outer, with: .color(Color(white: 1, opacity: 0.14)), lineWidth: 1)
        var x = frame.minX
        for (i, w) in segmentWidths(frame.width).enumerated() {
            let rect = CGRect(x: x, y: frame.minY, width: w, height: frame.height)
            if selected == i { g.fill(Path(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: 4), with: .linearGradient(Gradient(colors: [Color(white: 0.5), Color(white: 0.38)]), startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY))) }
            let spec = TextSpec(text: titles[i], font: .system(size: 11, weight: selected == i ? .semibold : .regular), color: .white, lineLimit: 1, tracking: 0, minScale: 1, alignment: .center, underline: false, strikethrough: false)
            let m = TextEngine.measure(spec, width: nil)
            TextEngine.draw(spec, in: CGRect(x: rect.minX + 4, y: rect.midY - m.size.height / 2, width: rect.width - 8, height: m.size.height), cr: g.cr)
            x += w
        }
    }
}

// MARK: - Kontextmenü

extension View {
    public func contextMenu<M: View>(@ViewBuilder menuItems: () -> M) -> some View {
        let items = menuItems()
        return modify { r, child in
            let n = IDNode(identity: r.identity, child: child)
            let rowNodes = r.resolve(items, key: 2)
            let rows = menuRows(from: rowNodes)
            guard let host = r.host else { return n }
            n.contextMenu = { point in
                let layer = OverlayLayer(anchor: CGRect(origin: point, size: .zero), modal: false, placement: .topLeading, makeView: { MenuPopupView(rows: rows, dismiss: { }) }, onDismiss: { })
                layer.makeView = { MenuPopupView(rows: rows, dismiss: { [unowned host] in host.dismiss(layer.id) }) }
                layer.onDismiss = { [unowned host] in host.dismiss(layer.id) }
                host.present(layer)
            }
            n.handlers = n.handlers ?? Handlers()
            return n
        }
    }
}
