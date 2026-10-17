// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import Observation

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
