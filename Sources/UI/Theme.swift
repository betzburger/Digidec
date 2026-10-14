// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit
import Observation

// MARK: - Farbthemes

extension Color {
    init(_ c: RGB) { self.init(red: c.r, green: c.g, blue: c.b) }
}

extension NSColor {
    convenience init(_ c: RGB) { self.init(red: c.r, green: c.g, blue: c.b, alpha: 1) }
}

/// Das gewählte Farbtheme. `@Observable`: jede Ansicht, die beim Aufbau eine Farbe aus `RadioTheme` liest, wird beim Wechsel neu gezeichnet.
/// Ansichten, die ihre Farben in einer Zeichenfläche (Canvas) oder in AppKit lesen, rufen dafür zusätzlich `ThemeModel.shared.theme` im Aufbau ab.
@Observable
public final class ThemeModel: @unchecked Sendable {
    nonisolated(unsafe) public static let shared = ThemeModel()
    public static let notification = Notification.Name("DigidecThemeChanged")
    private static let key = "appTheme"

    public var theme: AppTheme {
        didSet {
            guard theme != oldValue else { return }
            palette = theme.palette
            UserDefaults.standard.set(theme.rawValue, forKey: Self.key)
            WaterfallColorMap.install(stops: palette.waterfall.map { ($0.0, ($0.1.r, $0.1.g, $0.1.b)) })
            NotificationCenter.default.post(name: Self.notification, object: nil)
        }
    }
    public private(set) var palette: ThemePalette

    private init() {
        // DIGIDEC_THEME=amber|redNight|marine|night wählt das Theme für einen Lauf (Prüfhilfe), ohne die Einstellung zu ändern
        let env = ProcessInfo.processInfo.environment["DIGIDEC_THEME"].flatMap(AppTheme.init(rawValue:))
        let saved = UserDefaults.standard.string(forKey: Self.key).flatMap(AppTheme.init(rawValue:))
        let t = env ?? saved ?? .night
        theme = t
        palette = t.palette
        WaterfallColorMap.install(stops: t.palette.waterfall.map { ($0.0, ($0.1.r, $0.1.g, $0.1.b)) })
    }
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
