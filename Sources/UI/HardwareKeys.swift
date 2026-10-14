// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI

// MARK: - Maße

/// Einheitliche Maße aller Tasten, damit jede Oberfläche im selben Raster sitzt
public enum RadioMetrics {
    /// Höhe einer Taste im Feature-Block
    public static let keyHeight: CGFloat = 28
    /// Höhe einer Taste in Kopfzeilen und anderen engen Leisten
    public static let compactKeyHeight: CGFloat = 22
    /// Abstand zwischen Tasten (waagerecht wie senkrecht)
    public static let keySpacing: CGFloat = 6
    public static let keyCorner: CGFloat = 5
}

// MARK: - Umgebung

private struct ButtonFillsCellKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Wahr innerhalb eines `ButtonGrid`: die Taste füllt ihre Rasterzelle ganz aus
    var buttonFillsCell: Bool {
        get { self[ButtonFillsCellKey.self] }
        set { self[ButtonFillsCellKey.self] = newValue }
    }
}

// MARK: - Taste

/// Plastische Taste im Stil eines Messgeräts/Transceivers: Licht von oben, Kante, Schatten darunter.
/// Gedrückt sitzt sie tiefer, aktiv leuchtet sie in VFD-Cyan.
public struct ModeButtonStyle: ButtonStyle {
    public var isSelected: Bool
    public var compact: Bool

    public init(isSelected: Bool, compact: Bool = false) {
        self.isSelected = isSelected
        self.compact = compact
    }

    public func makeBody(configuration: Configuration) -> some View {
        HardwareKey(label: configuration.label, isPressed: configuration.isPressed, isSelected: isSelected, compact: compact)
    }
}

private struct HardwareKey<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let isSelected: Bool
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.buttonFillsCell) private var fillsCell
    @State private var isHovering = false

    var body: some View {
        label
            .font(.system(size: compact ? 9 : 11, weight: compact ? .bold : .semibold, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundColor(textColor)
            .shadow(color: isSelected ? RadioTheme.vfdCyan.opacity(0.5) : .black.opacity(0.7), radius: isSelected ? 2 : 0, y: isSelected ? 0 : 1)
            .padding(.horizontal, compact ? 8 : 8)
            .padding(.vertical, compact ? 3 : 5)
            .frame(minHeight: compact ? RadioMetrics.compactKeyHeight : RadioMetrics.keyHeight)
            .frame(maxWidth: fillsCell ? .infinity : nil, maxHeight: fillsCell ? .infinity : nil)
            .hardwareKeyFace(isSelected: isSelected, isPressed: isPressed, isHovering: isHovering && isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
            .offset(y: isPressed ? 1 : 0)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }

    private var textColor: Color {
        if isSelected { return RadioTheme.vfdCyan }
        return isHovering && isEnabled ? RadioTheme.textBright : RadioTheme.textMuted
    }
}

extension View {
    /// Tastenkörper: Verlauf, Kante, Lichtkante oben, Schatten unten; `isPressed` kehrt das Licht um
    func hardwareKeyFace(isSelected: Bool, isPressed: Bool = false, isHovering: Bool = false, corner: CGFloat = RadioMetrics.keyCorner) -> some View {
        modifier(HardwareKeyFace(isSelected: isSelected, isPressed: isPressed, isHovering: isHovering, corner: corner))
    }
}

struct HardwareKeyFace: ViewModifier {
    let isSelected: Bool
    let isPressed: Bool
    let isHovering: Bool
    let corner: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        content
            .background {
                shape.fill(LinearGradient(colors: faceColors, startPoint: .top, endPoint: .bottom))
                    .overlay { if isHovering { shape.fill(Color.white.opacity(0.06)) } }
            }
            .overlay {
                // Lichtkante oben, Schattenkante unten (gedrückt umgekehrt)
                shape.inset(by: 1)
                    .strokeBorder(LinearGradient(stops: bevelStops, startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .overlay {
                shape.strokeBorder(isSelected ? RadioTheme.vfdCyan.opacity(isPressed ? 0.7 : 0.95) : Color.black.opacity(0.75), lineWidth: 1)
            }
            .shadow(color: isSelected ? RadioTheme.vfdCyan.opacity(isPressed ? 0.15 : 0.38) : .clear, radius: 5)
            .shadow(color: .black.opacity(isPressed ? 0 : 0.55), radius: 2, x: 0, y: isPressed ? 0 : 2)
    }

    private var faceColors: [Color] {
        let p = ThemeModel.shared.palette
        switch (isSelected, isPressed) {
        case (false, false): return [Color(p.keyTop), Color(p.keyBottom)]
        case (false, true):  return [Color(p.keyPressedTop), Color(p.keyPressedBottom)]
        case (true, false):  return [Color(p.keySelectedTop), Color(p.keySelectedBottom)]
        case (true, true):   return [Color(p.keySelectedPressedTop), Color(p.keySelectedPressedBottom)]
        }
    }

    private var bevelStops: [Gradient.Stop] {
        let light = Color.white.opacity(isSelected ? 0.34 : 0.30)
        let dark = Color.black.opacity(0.32)
        return isPressed
            ? [.init(color: dark, location: 0), .init(color: .clear, location: 0.4), .init(color: .clear, location: 0.7), .init(color: light.opacity(0.5), location: 1)]
            : [.init(color: light, location: 0), .init(color: light.opacity(0.10), location: 0.3), .init(color: .clear, location: 0.6), .init(color: dark, location: 1)]
    }
}

extension View {
    /// Quadratische Symboltaste in fester Breite (füllt ihre Zelle wie in einem `ButtonGrid`)
    func fixedKey(width: CGFloat = 34, compact: Bool = false) -> some View {
        environment(\.buttonFillsCell, true)
            .frame(width: width, height: compact ? RadioMetrics.compactKeyHeight : RadioMetrics.keyHeight)
    }
}

// MARK: - Raster

enum ButtonGridColumns {
    /// Eine Zeile, jede Taste so breit wie die breiteste, linksbündig
    case row
    /// Eine Zeile über die ganze Breite des Blocks: alle Tasten gleich breit, Zeile beginnt und endet bündig
    case spread
    /// Feste Spaltenzahl; die Zellen füllen die ganze Breite des Blocks
    case fill(Int)
    /// Feste Zellbreite; so viele Spalten, wie in die Breite passen, der Rest bricht um
    case cell(CGFloat)
}

/// Setzt Tasten in ein gleichmäßiges Raster: alle Zellen gleich breit und gleich hoch (nach der größten Taste des Blocks)
struct ButtonGrid<Content: View>: View {
    typealias Columns = ButtonGridColumns

    var columns: Columns = .row
    var spacing: CGFloat = RadioMetrics.keySpacing
    @ViewBuilder var content: Content

    var body: some View {
        ButtonGridLayout(columns: columns, spacing: spacing) { content }
            .environment(\.buttonFillsCell, true)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(spreadsAcross ? 0 : 1)
    }

    private var spreadsAcross: Bool {
        switch columns { case .spread, .fill: return true; default: return false }
    }
}

struct ButtonGridLayout: Layout {
    var columns: ButtonGridColumns
    var spacing: CGFloat

    private struct Geometry { var cols: Int; var cellW: CGFloat; var cellH: CGFloat }

    private func geometry(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Geometry {
        let n = subviews.count
        guard n > 0 else { return Geometry(cols: 1, cellW: 0, cellH: 0) }
        var maxW: CGFloat = 0, maxH: CGFloat = RadioMetrics.compactKeyHeight
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            maxW = max(maxW, s.width); maxH = max(maxH, s.height)
        }
        let avail = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        switch columns {
        case .row:
            var w = maxW
            if let a = avail, CGFloat(n) * w + CGFloat(n - 1) * spacing > a { w = max(0, (a - CGFloat(n - 1) * spacing) / CGFloat(n)) }
            return Geometry(cols: n, cellW: w, cellH: maxH)
        case .spread:
            let w = avail.map { max(0, ($0 - CGFloat(n - 1) * spacing) / CGFloat(n)) } ?? maxW
            return Geometry(cols: n, cellW: w, cellH: maxH)
        case .fill(let c):
            let cols = max(1, c)
            let w = avail.map { max(0, ($0 - CGFloat(cols - 1) * spacing) / CGFloat(cols)) } ?? maxW
            return Geometry(cols: cols, cellW: w, cellH: maxH)
        case .cell(let w):
            let cols = avail.map { max(1, Int((($0 + spacing) / (w + spacing)).rounded(.down))) } ?? n
            return Geometry(cols: min(cols, n), cellW: w, cellH: maxH)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let g = geometry(proposal, subviews)
        guard !subviews.isEmpty else { return .zero }
        let used = min(subviews.count, g.cols)
        let rows = (subviews.count + g.cols - 1) / g.cols
        let fixedFill: Bool = { switch columns { case .fill, .spread: return true; default: return false } }()
        let cols = fixedFill ? g.cols : used
        return CGSize(width: CGFloat(cols) * g.cellW + CGFloat(cols - 1) * spacing,
                      height: CGFloat(rows) * g.cellH + CGFloat(rows - 1) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let g = geometry(ProposedViewSize(width: bounds.width, height: bounds.height), subviews)
        for (i, v) in subviews.enumerated() {
            let col = i % g.cols, row = i / g.cols
            v.place(at: CGPoint(x: bounds.minX + CGFloat(col) * (g.cellW + spacing), y: bounds.minY + CGFloat(row) * (g.cellH + spacing)),
                    anchor: .topLeading, proposal: ProposedViewSize(width: g.cellW, height: g.cellH))
        }
    }
}
