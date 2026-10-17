// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Farbthemes

extension Color {
    init(_ c: RGB) { self.init(red: c.r, green: c.g, blue: c.b) }
}

extension NSColor {
    convenience init(_ c: RGB) { self.init(red: c.r, green: c.g, blue: c.b, alpha: 1) }
}

/// Farben der Oberfläche; folgen dem gewählten Theme (`ThemeModel`)
public struct RadioTheme {
    private static var p: ThemePalette { ThemeModel.shared.palette }

    public static var bgDeep: Color        { Color(p.bgDeep) }
    public static var bgPanel: Color       { Color(p.bgPanel) }
    public static var bgCard: Color        { Color(p.bgCard) }
    public static var borderSubtle: Color  { Color(p.borderSubtle) }
    public static var borderActive: Color  { Color(p.borderActive) }

    public static var vfdAmber: Color      { Color(p.vfdAmber) }
    public static var vfdCyan: Color       { Color(p.vfdCyan) }
    public static var vfdGreen: Color      { Color(p.vfdGreen) }
    public static var ledRed: Color        { Color(p.ledRed) }
    public static var ledYellow: Color     { Color(p.ledYellow) }

    public static var textBright: Color    { Color(p.textBright) }
    public static var textLight: Color     { textBright }
    public static var textMuted: Color     { Color(p.textMuted) }
    public static var textDim: Color       { Color(p.textDim) }
}

public struct RadioBox<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(10)
            .background(RadioTheme.bgCard)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(RadioTheme.borderSubtle, lineWidth: 1)
            )
    }
}

public struct RadioCardModifier: ViewModifier {
    public var title: String? = nil
    /// Bedienelement rechts neben dem Titel (z. B. Umschalter)
    public var accessory: AnyView? = nil

    public func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = title {
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(title))
                        .textCase(.uppercase)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(RadioTheme.textDim)
                        .tracking(1.2)
                        .lineLimit(1)
                    if let accessory {
                        Spacer(minLength: 0)
                        accessory
                    }
                }
                .padding(.horizontal, 4)
            }
            content
                .padding(10)
                .background(RadioTheme.bgCard)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(RadioTheme.borderSubtle, lineWidth: 1)
                )
        }
    }
}

public extension View {
    func radioCard(title: String? = nil, accessory: AnyView? = nil) -> some View {
        modifier(RadioCardModifier(title: title, accessory: accessory))
    }
}
