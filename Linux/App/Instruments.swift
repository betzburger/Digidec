// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import CoreGraphics
import CGtkCairo
@testable import DigidecCore

// Zeichnen der Instrumente mit Cairo. Farben stammen aus dem gewählten Theme (`ThemePalette`) des Kerns, wie am Mac.

@MainActor
private func setColor(_ cr: OpaquePointer, _ c: RGB, _ alpha: Double = 1) {
    cairo_set_source_rgba(cr, c.r, c.g, c.b, alpha)
}

@MainActor
private func roundedRect(_ cr: OpaquePointer, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) {
    cairo_new_sub_path(cr)
    cairo_arc(cr, x + w - r, y + r, r, -Double.pi / 2, 0)
    cairo_arc(cr, x + w - r, y + h - r, r, 0, Double.pi / 2)
    cairo_arc(cr, x + r, y + h - r, r, Double.pi / 2, Double.pi)
    cairo_arc(cr, x + r, y + r, r, Double.pi, 3 * Double.pi / 2)
    cairo_close_path(cr)
}

@MainActor
private func text(_ cr: OpaquePointer, _ s: String, x: Double, y: Double, size: Double, bold: Bool = false, anchor: Double = 0.5) {
    cairo_select_font_face(cr, "monospace", CAIRO_FONT_SLANT_NORMAL, bold ? CAIRO_FONT_WEIGHT_BOLD : CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
    var extents = cairo_text_extents_t()
    cairo_text_extents(cr, s, &extents)
    cairo_move_to(cr, x - extents.width * anchor - extents.x_bearing * (1 - anchor), y)
    cairo_show_text(cr, s)
}

/// Karte mit Rahmen und Überschrift wie `radioCard` am Mac
@MainActor
func drawCard(_ cr: OpaquePointer, _ w: Double, _ h: Double, title: String, theme: ThemePalette) {
    roundedRect(cr, 1, 1, w - 2, h - 2, 8)
    setColor(cr, theme.bgCard)
    cairo_fill_preserve(cr)
    setColor(cr, theme.borderSubtle)
    cairo_set_line_width(cr, 1)
    cairo_stroke(cr)
    setColor(cr, theme.textMuted)
    text(cr, title.uppercased(), x: 12, y: 18, size: 10, bold: true, anchor: 0)
}

// MARK: - Analoges S-Meter

/// Stellung des Zeigers 0…1: S1 … S9 über die ersten 60 %, danach +60 dB über die restlichen 40 % (IARU: S9 = −46 dBFS, 6 dB je Stufe)
func sMeterFraction(db: Double) -> Double {
    if db <= -46 { return max(0, (9 + (db + 46) / 6 - 1) * 0.075) }
    return min(1, 0.6 + (db + 46) * (0.4 / 60))
}

func sMeterReading(db: Double) -> String {
    if db <= -46 { return "S" + String(max(0, min(9, Int((9 + (db + 46) / 6).rounded())))) }
    return "S9+" + String(Int(min(60, db + 46).rounded()))
}

@MainActor
func drawSMeter(_ cr: OpaquePointer, _ w: Double, _ h: Double, db: Double, theme: ThemePalette) {
    drawCard(cr, w, h, title: "S-Meter", theme: theme)
    let cx = w / 2, cy = h * 0.93
    let radius = min(w * 0.46, h * 0.80)
    func angle(_ f: Double) -> Double { (210 + 120 * f) * Double.pi / 180 }

    // beleuchtetes Skalenfeld
    cairo_save(cr)
    cairo_new_path(cr)
    cairo_move_to(cr, cx, cy)
    cairo_arc(cr, cx, cy, radius * 1.02, angle(-0.06), angle(1.06))
    cairo_close_path(cr)
    let glow = cairo_pattern_create_radial(cx, cy, radius * 0.2, cx, cy, radius * 1.05)
    cairo_pattern_add_color_stop_rgba(glow, 0, theme.vfdAmber.r, theme.vfdAmber.g, theme.vfdAmber.b, 0.10)
    cairo_pattern_add_color_stop_rgba(glow, 1, theme.vfdAmber.r, theme.vfdAmber.g, theme.vfdAmber.b, 0.28)
    cairo_set_source(cr, glow)
    cairo_fill(cr)
    cairo_pattern_destroy(glow)
    cairo_restore(cr)

    // Skala
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
    func tick(_ f: Double, long: Bool, red: Bool) {
        let a = angle(f), inner = radius * (long ? 0.86 : 0.91)
        setColor(cr, red ? theme.ledRed : theme.textBright)
        cairo_set_line_width(cr, long ? 2 : 1)
        cairo_move_to(cr, cx + cos(a) * inner, cy + sin(a) * inner)
        cairo_line_to(cr, cx + cos(a) * radius, cy + sin(a) * radius)
        cairo_stroke(cr)
    }
    for s in 1...9 {
        let f = Double(s - 1) * 0.075
        tick(f, long: s % 2 == 1, red: false)
        if s % 2 == 1 {
            setColor(cr, theme.textBright)
            let a = angle(f)
            text(cr, String(s), x: cx + cos(a) * radius * 0.76, y: cy + sin(a) * radius * 0.76 + 4, size: 11, bold: true)
        }
    }
    for plus in stride(from: 10, through: 60, by: 10) {
        let f = 0.6 + Double(plus) * (0.4 / 60)
        tick(f, long: plus % 20 == 0, red: true)
        if plus % 20 == 0 {
            setColor(cr, theme.ledRed)
            let a = angle(f)
            text(cr, "+\(plus)", x: cx + cos(a) * radius * 0.74, y: cy + sin(a) * radius * 0.74 + 4, size: 10, bold: true)
        }
    }
    // Bogen: weiß bis S9, rot darüber
    cairo_set_line_width(cr, 2)
    setColor(cr, theme.textBright)
    cairo_new_path(cr)
    cairo_arc(cr, cx, cy, radius, angle(0), angle(0.6))
    cairo_stroke(cr)
    setColor(cr, theme.ledRed)
    cairo_new_path(cr)
    cairo_arc(cr, cx, cy, radius, angle(0.6), angle(1))
    cairo_stroke(cr)

    // Zeiger mit Schatten
    let a = angle(sMeterFraction(db: db))
    let shadow = 3.0
    setColor(cr, RGB(0, 0, 0), 0.45)
    cairo_set_line_width(cr, 3)
    cairo_move_to(cr, cx + shadow, cy + shadow)
    cairo_line_to(cr, cx + cos(a) * radius * 0.97 + shadow, cy + sin(a) * radius * 0.97 + shadow)
    cairo_stroke(cr)
    setColor(cr, theme.ledRed)
    cairo_set_line_width(cr, 2.2)
    cairo_move_to(cr, cx, cy)
    cairo_line_to(cr, cx + cos(a) * radius * 0.97, cy + sin(a) * radius * 0.97)
    cairo_stroke(cr)
    setColor(cr, theme.bgDeep)
    cairo_new_path(cr)
    cairo_arc(cr, cx, cy, 7, 0, 2 * Double.pi)
    cairo_fill(cr)

    setColor(cr, theme.vfdAmber)
    text(cr, sMeterReading(db: db), x: w - 14, y: 20, size: 14, bold: true, anchor: 1)
}

// MARK: - VFD-Anzeige

@MainActor
func drawVFD(_ cr: OpaquePointer, _ w: Double, _ h: Double, lines: [(label: String, value: String)], theme: ThemePalette) {
    drawCard(cr, w, h, title: "Abstimmanzeige", theme: theme)
    roundedRect(cr, 10, 28, w - 20, h - 38, 5)
    setColor(cr, RGB(0.02, 0.03, 0.03))
    cairo_fill(cr)
    let rowHeight = (h - 38) / Double(max(1, lines.count))
    for (i, line) in lines.enumerated() {
        let baseline = 28 + rowHeight * (Double(i) + 0.68)
        setColor(cr, theme.vfdCyan, 0.55)
        text(cr, line.label.uppercased(), x: 20, y: baseline, size: 11, anchor: 0)
        // Leuchten: dieselbe Schrift erst breit und blass, dann scharf
        for (offset, alpha) in [(1.2, 0.18), (0.6, 0.30), (0.0, 1.0)] {
            setColor(cr, theme.vfdAmber, alpha)
            for (dx, dy) in (offset == 0 ? [(0.0, 0.0)] : [(-offset, 0.0), (offset, 0.0), (0.0, -offset), (0.0, offset)]) {
                text(cr, line.value, x: w - 20 + dx, y: baseline + dy, size: min(30, rowHeight * 0.7), bold: true, anchor: 1)
            }
        }
    }
}

// MARK: - Wasserfall

@MainActor
func drawWaterfall(_ cr: OpaquePointer, _ w: Double, _ h: Double, image: CGImage?, binWidth: Double, spectrum: [Float], peakHz: Double, theme: ThemePalette, card: Bool = true) {
    if card { drawCard(cr, w, h, title: "Wasserfall", theme: theme) }
    let left = card ? 10.0 : 0.0, top = card ? 28.0 : 0.0, right = card ? 10.0 : 0.0, axis = 20.0
    let areaW = w - left - right, areaH = h - top - axis - (card ? 8 : 0)
    guard areaW > 10, areaH > 10, let image, let data = image.dataProvider?.data else { return }
    let imageW = image.width, imageH = image.height

    // RGBA (Bytes R G B A) → Cairo ARGB32 (Bytes B G R A, vormultipliziert)
    var pixels = [UInt8](repeating: 0, count: imageW * imageH * 4)
    data.withUnsafeBytes { raw in
        let src = raw.bindMemory(to: UInt8.self)
        for i in 0..<(imageW * imageH) {
            pixels[4 * i] = src[4 * i + 2]; pixels[4 * i + 1] = src[4 * i + 1]; pixels[4 * i + 2] = src[4 * i]; pixels[4 * i + 3] = 255
        }
    }
    pixels.withUnsafeMutableBytes { buffer in
        guard let surface = cairo_image_surface_create_for_data(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), CAIRO_FORMAT_ARGB32,
                                                                Int32(imageW), Int32(imageH), Int32(imageW * 4)) else { return }
        cairo_save(cr)
        roundedRect(cr, left, top, areaW, areaH, 4)
        cairo_clip(cr)
        cairo_translate(cr, left, top)
        cairo_scale(cr, areaW / Double(imageW), areaH / Double(imageH))
        cairo_set_source_surface(cr, surface, 0, 0)
        cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_BILINEAR)
        cairo_paint(cr)
        cairo_restore(cr)
        cairo_surface_destroy(surface)
    }
    // Frequenzachse (Bereich 0 … Nyquist des Wasserfalls)
    let maxHz = binWidth * Double(imageW)
    setColor(cr, theme.textDim)
    let step = maxHz > 3000 ? 500.0 : 250.0
    var f = 0.0
    while f <= maxHz {
        let x = left + f / maxHz * areaW
        cairo_set_line_width(cr, 1)
        cairo_move_to(cr, x, top + areaH); cairo_line_to(cr, x, top + areaH + 4); cairo_stroke(cr)
        text(cr, String(Int(f)), x: x, y: top + areaH + 15, size: 10)
        f += step
    }
    // Marke an der stärksten Linie
    if peakHz > 0 {
        let x = left + peakHz / maxHz * areaW
        setColor(cr, theme.vfdAmber, 0.9)
        cairo_set_line_width(cr, 1)
        cairo_move_to(cr, x, top); cairo_line_to(cr, x, top + areaH); cairo_stroke(cr)
    }
}
