// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Zeichnet eine Taste im Stil von `HardwareKeyFace` (Sources/UI/HardwareKeys.swift): Verlauf, Lichtkante oben, Schattenkante unten,
// Rand, Schein bei Auswahl. Gleiche Maße und Farben wie dort; die SwiftUI-Fassung bleibt für die Mac-Oberfläche.
import SwiftUI

struct HardwareKeyPainter {
    let label: String
    let isSelected: Bool
    var isPressed = false
    var isHovering = false
    var compact = false
    var corner: CGFloat = 5
    var palette: ThemePalette = ThemeModel.shared.palette

    static let keyHeight: CGFloat = 28
    static let compactKeyHeight: CGFloat = 22

    /// Breite einer Taste mit diesem Text (Schriftbreite der Einzelziffer mal Zeichenzahl plus Ränder)
    static func width(for label: String, compact: Bool) -> CGFloat {
        CGFloat(label.count) * (compact ? 5.6 : 6.7) + 16
    }

    func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let p = palette
        let rect = CGRect(origin: .zero, size: size)
        let shape = Path(roundedRect: rect, cornerRadius: corner)
        let offsetY: CGFloat = isPressed ? 1 : 0

        ctx.drawLayer { l in
            l.translateBy(x: 0, y: offsetY)
            // Schatten: Schein bei Auswahl, darunter dunkler Wurf nach unten
            if isSelected {
                l.drawLayer { s in
                    s.addFilter(.blur(radius: 2.5))
                    s.fill(shape, with: .color(Color(p.vfdCyan).opacity(isPressed ? 0.15 : 0.38)))
                }
            }
            if !isPressed {
                l.drawLayer { s in
                    s.translateBy(x: 0, y: 2)
                    s.addFilter(.blur(radius: 1))
                    s.fill(shape, with: .color(.black.opacity(0.55)))
                }
            }
            // Tastenkörper
            l.fill(shape, with: .linearGradient(Gradient(colors: faceColors), startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
            if isHovering { l.fill(shape, with: .color(Color.white.opacity(0.06))) }
            // Lichtkante oben, Schattenkante unten (gedrückt umgekehrt): Rand innen, 1 pt von der Kante
            let bevel = Path(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerRadius: max(0, corner - 1.5))
            l.stroke(bevel, with: .linearGradient(Gradient(stops: bevelStops), startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)), lineWidth: 1)
            // Außenrand
            let border = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: max(0, corner - 0.5))
            l.stroke(border, with: .color(isSelected ? Color(p.vfdCyan).opacity(isPressed ? 0.7 : 0.95) : Color.black.opacity(0.75)), lineWidth: 1)
            // Beschriftung mit Schein bzw. Schlagschatten
            let font = Font.system(size: compact ? 9 : 11, weight: compact ? .bold : .semibold, design: .monospaced)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            if isSelected {
                l.drawLayer { g in
                    g.addFilter(.blur(radius: 1))
                    g.draw(Text(label).font(font).foregroundColor(Color(p.vfdCyan).opacity(0.5)), at: center)
                }
            } else {
                l.draw(Text(label).font(font).foregroundColor(Color.black.opacity(0.7)), at: CGPoint(x: center.x, y: center.y + 1))
            }
            l.draw(Text(label).font(font).foregroundColor(textColor), at: center)
        }
    }

    private var textColor: Color {
        if isSelected { return Color(palette.vfdCyan) }
        return isHovering ? Color(palette.textBright) : Color(palette.textMuted)
    }

    private var faceColors: [Color] {
        let p = palette
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
