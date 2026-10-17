// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// LazyVGrid mit GridItem (feste, flexible und anpassende Spalten).
import Foundation

public struct GridItem: Sendable {
    public enum Size: Sendable {
        case fixed(CGFloat)
        case flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity)
        case adaptive(minimum: CGFloat, maximum: CGFloat = .infinity)
    }
    public var size: Size
    public var spacing: CGFloat?
    public var alignment: Alignment?
    public init(_ size: Size = .flexible(), spacing: CGFloat? = nil, alignment: Alignment? = nil) { self.size = size; self.spacing = spacing; self.alignment = alignment }
}

struct GridColumnsLayout: Layout {
    let columns: [GridItem]
    let hSpacing: CGFloat
    let vSpacing: CGFloat

    /// Spaltenbreiten für die verfügbare Breite
    private func widths(_ available: CGFloat?) -> [CGFloat] {
        var expanded: [(min: CGFloat, max: CGFloat, fixed: CGFloat?)] = []
        for item in columns {
            switch item.size {
            case .fixed(let w): expanded.append((w, w, w))
            case .flexible(let lo, let hi): expanded.append((lo, hi, nil))
            case .adaptive(let lo, _):
                if let available, available.isFinite {
                    let count = max(1, Int(((available + hSpacing) / (lo + hSpacing)).rounded(.down)))
                    for _ in 0..<count { expanded.append((lo, .infinity, nil)) }
                } else { expanded.append((lo, lo, lo)) }
            }
        }
        guard let available, available.isFinite else { return expanded.map { $0.fixed ?? $0.min } }
        let spacing = hSpacing * CGFloat(max(0, expanded.count - 1))
        let fixedTotal = expanded.compactMap(\.fixed).reduce(0, +)
        let flexCount = expanded.filter { $0.fixed == nil }.count
        let share = flexCount > 0 ? max(0, (available - spacing - fixedTotal) / CGFloat(flexCount)) : 0
        return expanded.map { $0.fixed ?? min($0.max, max($0.min, share)) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = widths(proposal.width)
        guard !w.isEmpty, !subviews.isEmpty else { return .zero }
        var height: CGFloat = 0, rowHeight: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            rowHeight = max(rowHeight, v.sizeThatFits(ProposedViewSize(width: w[i % w.count], height: nil)).height)
            if i % w.count == w.count - 1 || i == subviews.count - 1 { height += rowHeight + vSpacing; rowHeight = 0 }
        }
        return CGSize(width: w.reduce(0, +) + hSpacing * CGFloat(w.count - 1), height: max(0, height - vSpacing))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = widths(bounds.width)
        guard !w.isEmpty else { return }
        var y = bounds.minY
        var i = 0
        while i < subviews.count {
            let rowItems = Array(i..<min(i + w.count, subviews.count))
            let rowHeight = rowItems.map { subviews[$0].sizeThatFits(ProposedViewSize(width: w[$0 % w.count], height: nil)).height }.max() ?? 0
            var x = bounds.minX
            for j in rowItems {
                subviews[j].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: w[j % w.count], height: rowHeight))
                x += w[j % w.count] + hSpacing
            }
            y += rowHeight + vSpacing
            i += w.count
        }
    }
}

public struct LazyVGrid<Content: View>: View {
    let columns: [GridItem]
    let spacing: CGFloat
    let content: Content
    public init(columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.columns = columns; self.spacing = spacing ?? 8; self.content = content()
    }
    public var body: some View {
        LayoutView(layout: GridColumnsLayout(columns: columns, hSpacing: columns.first?.spacing ?? spacing, vSpacing: spacing), content: content)
    }
}

public typealias Grid = LazyVGrid<AnyView>

// MARK: - Section

public struct Section<Header: View, Content: View>: View {
    let header: Header, content: Content
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) { self.header = header(); self.content = content() }
    public init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) where Header == Text { header = Text(title); self.content = content() }
    public init(@ViewBuilder content: () -> Content) where Header == EmptyView { header = EmptyView(); self.content = content() }
    public var body: some View { VStack(alignment: .leading, spacing: 4) { header; content } }
}
