// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import SwiftUI           // unter Linux der Nachbau des Zeichenteils (Linux/Shims/SwiftUI)
import CGtkCairo
@testable import DigidecCore

// Kopfzeile, Modulleiste und Karten im Stil der Mac-Oberfläche (Maße und Farben aus RadioTheme / RadioCardModifier / HardwareKeys).

private func themeColor(_ c: RGB, _ opacity: Double = 1) -> Color { Color(red: c.r, green: c.g, blue: c.b, opacity: opacity) }

/// Karte wie `radioCard`: Titel in Großbuchstaben darüber (10 pt, fett, Abstand 1,2), darunter Fläche mit Rand. Liefert den Innenraum.
@MainActor
func drawRadioCard(_ ctx: inout GraphicsContext, size: CGSize, title: String?, palette p: ThemePalette) -> CGRect {
    var top: CGFloat = 0
    if let title {
        ctx.draw(Text(title.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(themeColor(p.textDim)).tracking(1.2),
                 at: CGPoint(x: 4, y: 8), anchor: .leading)
        top = 22
    }
    let card = CGRect(x: 0.5, y: top + 0.5, width: size.width - 1, height: size.height - top - 1)
    let shape = Path(roundedRect: card, cornerRadius: 8)
    ctx.fill(shape, with: .color(themeColor(p.bgCard)))
    ctx.stroke(shape, with: .color(themeColor(p.borderSubtle)), lineWidth: 1)
    return card.insetBy(dx: 10, dy: 10)
}

@MainActor
func drawHeader(_ ctx: inout GraphicsContext, size: CGSize, palette p: ThemePalette, utc: String) {
    // Logo: fünf Balken wie ein Spektrum
    let heights: [CGFloat] = [8, 15, 22, 13, 7]
    for (i, h) in heights.enumerated() {
        let x = 6 + CGFloat(i) * 5
        ctx.fill(Path(roundedRect: CGRect(x: x, y: 30 - h / 2, width: 3, height: h), cornerRadius: 1), with: .color(themeColor(p.textBright)))
    }
    ctx.draw(Text("DIGIDEC").font(.system(size: 13, weight: .heavy, design: .monospaced)).foregroundColor(themeColor(p.textBright)), at: CGPoint(x: 36, y: 22), anchor: .leading)
    ctx.draw(Text(AppVersion.string).font(.system(size: 8, weight: .regular, design: .monospaced)).foregroundColor(themeColor(p.textDim)), at: CGPoint(x: 100, y: 22), anchor: .leading)
    ctx.draw(Text("DIGITAL MODE DECODER").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(themeColor(p.textMuted)).tracking(0.8), at: CGPoint(x: 36, y: 38), anchor: .leading)
    ctx.draw(Text(utc + " UTC").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(themeColor(p.vfdAmber)),
             at: CGPoint(x: size.width - 8, y: 30), anchor: .trailing)
}

/// Eine Zeile der Modulleiste (HF oder VHF/UHF): farbiger Strich und Bezeichnung links, gleich breite Tasten, bei Platzmangel umbrochen.
struct ModuleBarLayout {
    var rects: [(module: DecoderModuleInfo, rect: CGRect)] = []
    var height: CGFloat = 0
}

@MainActor
func drawModuleBar(_ ctx: inout GraphicsContext, size: CGSize, palette p: ThemePalette, selected: DecoderModuleInfo, hover: DecoderModuleInfo?, pressed: DecoderModuleInfo?) -> ModuleBarLayout {
    var layout = ModuleBarLayout()
    let keyH = HardwareKeyPainter.keyHeight, spacing: CGFloat = 6, labelW: CGFloat = 62
    var y: CGFloat = 0
    for band in DecoderModuleInfo.Band.allCases {
        let modules = band.modules
        // Strich und Bezeichnung
        ctx.fill(Path(CGRect(x: 0, y: y + 2, width: 3, height: keyH - 4)), with: .color(themeColor(p.vfdAmber)))
        ctx.draw(Text(band.title.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(themeColor(p.vfdAmber)).tracking(0.8),
                 at: CGPoint(x: 10, y: y + keyH / 2), anchor: .leading)
        let keyW = modules.map { HardwareKeyPainter.width(for: $0.displayName, compact: false) }.max() ?? 60
        let perRow = max(1, Int((size.width - labelW + spacing) / (keyW + spacing)))
        for (i, module) in modules.enumerated() {
            let col = i % perRow, row = i / perRow
            let rect = CGRect(x: labelW + CGFloat(col) * (keyW + spacing), y: y + CGFloat(row) * (keyH + spacing), width: keyW, height: keyH)
            var key = HardwareKeyPainter(label: module.displayName, isSelected: module == selected, palette: p)
            key.isHovering = module == hover
            key.isPressed = module == pressed
            ctx.drawLayer { l in
                l.translateBy(x: rect.minX, y: rect.minY)
                key.draw(&l, size: rect.size)
            }
            layout.rects.append((module, rect))
        }
        let rows = (modules.count + perRow - 1) / perRow
        y += CGFloat(rows) * (keyH + spacing) + 4
    }
    layout.height = y
    return layout
}

/// Karte „Abstimmanzeige“ mit dem S-Meter
@MainActor
func drawTuningCard(_ cr: OpaquePointer, _ w: Double, _ h: Double, db: Double, ballistics: NeedleBallistics, palette p: ThemePalette) {
    var ctx = GraphicsContext(cairo: cr, size: CGSize(width: w, height: h))
    let inner = drawRadioCard(&ctx, size: CGSize(width: w, height: h), title: "Abstimmanzeige", palette: p)
    cairo_save(cr)
    cairo_translate(cr, inner.minX, inner.minY)
    drawOriginalSMeter(cr, inner.width, inner.height, db: db, lit: true, ballistics: ballistics, canvas: CGSize(width: w, height: h))
    cairo_restore(cr)
}

@MainActor
func drawWaterfallCard(_ cr: OpaquePointer, _ w: Double, _ h: Double, image: CGImage?, binWidth: Double, spectrum: [Float], peakHz: Double, palette p: ThemePalette) {
    var ctx = GraphicsContext(cairo: cr, size: CGSize(width: w, height: h))
    let inner = drawRadioCard(&ctx, size: CGSize(width: w, height: h), title: "Wasserfall", palette: p)
    cairo_save(cr)
    cairo_translate(cr, inner.minX, inner.minY)
    drawWaterfall(cr, inner.width, inner.height, image: image, binWidth: binWidth, spectrum: spectrum, peakHz: peakHz, theme: p, card: false)
    cairo_restore(cr)
}

@MainActor
func drawHeaderCanvas(_ cr: OpaquePointer, _ w: Double, _ h: Double, palette: ThemePalette) {
    var ctx = GraphicsContext(cairo: cr, size: CGSize(width: w, height: h))
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    f.timeZone = TimeZone(identifier: "UTC")
    drawHeader(&ctx, size: CGSize(width: w, height: h), palette: palette, utc: f.string(from: Date()))
}

/// Zeichnet die Modulleiste; liefert die Tastenflächen mit der Kennung des Moduls
@MainActor
func drawModuleBarCanvas(_ cr: OpaquePointer, _ w: Double, _ h: Double, selected: DecoderModuleInfo, hover: String?, pressed: String?, palette: ThemePalette) -> [(id: String, rect: CGRect)] {
    var ctx = GraphicsContext(cairo: cr, size: CGSize(width: w, height: h))
    return drawModuleBar(&ctx, size: CGSize(width: w, height: h), palette: palette, selected: selected,
                         hover: hover.flatMap(DecoderModuleInfo.init(rawValue:)), pressed: pressed.flatMap(DecoderModuleInfo.init(rawValue:)))
        .rects.map { ($0.module.rawValue, $0.rect) }
}
