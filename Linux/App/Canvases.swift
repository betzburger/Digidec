// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import SwiftUI           // unter Linux der Nachbau des Zeichenteils (Linux/Shims/SwiftUI)
import CGtkCairo
@testable import DigidecCore

// Zeichenfunktionen der Modulansichten (Cairo über den GraphicsContext-Nachbau). Kein SwiftCrossUI in dieser Datei.

private func themeColor(_ c: RGB, _ opacity: Double = 1) -> Color { Color(red: c.r, green: c.g, blue: c.b, opacity: opacity) }

// MARK: - Tastenraster

struct KeyItem {
    var id: String
    var label: String
    var isSelected: Bool
}

enum KeyColumns {
    /// Feste Spaltenzahl, Zellen füllen die Breite
    case fill(Int)
    /// Eine Zeile über die ganze Breite
    case spread
    /// Eine Zeile, jede Taste so breit wie ihr Text (linksbündig)
    case row
}

enum KeyGridMetrics {
    static let spacing: CGFloat = 6

    static func rows(count: Int, columns: KeyColumns) -> Int {
        switch columns {
        case .fill(let n): return max(1, (count + n - 1) / max(1, n))
        case .spread, .row: return 1
        }
    }

    static func height(count: Int, columns: KeyColumns, compact: Bool) -> CGFloat {
        let keyH = compact ? HardwareKeyPainter.compactKeyHeight : HardwareKeyPainter.keyHeight
        let rows = CGFloat(rows(count: count, columns: columns))
        return rows * keyH + (rows - 1) * spacing
    }
}

@MainActor
func drawKeyGrid(_ cr: OpaquePointer, _ w: Double, _ h: Double, items: [KeyItem], columns: KeyColumns, compact: Bool,
                 hover: String?, pressed: String?, palette p: ThemePalette) -> [(id: String, rect: CGRect)] {
    var ctx = GraphicsContext(cairo: cr, size: CGSize(width: w, height: h))
    let keyH = compact ? HardwareKeyPainter.compactKeyHeight : HardwareKeyPainter.keyHeight
    let spacing = KeyGridMetrics.spacing
    var rects: [(id: String, rect: CGRect)] = []
    let n = items.count
    guard n > 0 else { return [] }
    var cellW: CGFloat
    var perRow: Int
    switch columns {
    case .fill(let c):
        perRow = max(1, c)
        cellW = (CGFloat(w) - CGFloat(perRow - 1) * spacing) / CGFloat(perRow)
    case .spread:
        perRow = n
        cellW = (CGFloat(w) - CGFloat(n - 1) * spacing) / CGFloat(n)
    case .row:
        perRow = n
        cellW = items.map { HardwareKeyPainter.width(for: $0.label, compact: compact) }.max() ?? 40
    }
    for (i, item) in items.enumerated() {
        let col = i % perRow, row = i / perRow
        let rect = CGRect(x: CGFloat(col) * (cellW + spacing), y: CGFloat(row) * (keyH + spacing), width: cellW, height: keyH)
        var key = HardwareKeyPainter(label: item.label, isSelected: item.isSelected, palette: p)
        key.compact = compact
        key.isHovering = item.id == hover
        key.isPressed = item.id == pressed
        ctx.drawLayer { l in
            l.translateBy(x: rect.minX, y: rect.minY)
            key.draw(&l, size: rect.size)
        }
        rects.append((item.id, rect))
    }
    return rects
}

// MARK: - FT8-Tabelle

/// Tabelle wie WSJT-X: UTC · dB · DT · Freq · DX · Meldung · km. Die neuesten Zeilen stehen unten; es werden so viele gezeigt, wie passen.
@MainActor
func drawFT8Table(_ cr: OpaquePointer, _ w: Double, _ h: Double, entries: [FT8Entry], palette p: ThemePalette) {
    var ctx = GraphicsContext(cairo: cr, size: CGSize(width: w, height: h))
    let shape = Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 6)
    ctx.fill(shape, with: .color(themeColor(p.bgDeep)))

    let pad: CGFloat = 6, lineH: CGFloat = 17, headH: CGFloat = 16
    let widths: [CGFloat] = [48, 28, 34, 40, 24]          // UTC, dB, DT, Freq, DX
    let kmW: CGFloat = 50
    let gap: CGFloat = 8
    var xs: [CGFloat] = []
    var x = pad
    for width in widths { xs.append(x); x += width + gap }
    let messageX = x
    let kmRight = CGFloat(w) - pad
    let headerFont = Font.system(size: 9, weight: .bold, design: .monospaced)
    func header(_ s: String, _ x: CGFloat, _ width: CGFloat, _ anchor: UnitPoint) {
        let ax = anchor == .trailing ? x + width : (anchor == .center ? x + width / 2 : x)
        ctx.draw(Text(s).font(headerFont).foregroundColor(themeColor(p.textDim)), at: CGPoint(x: ax, y: pad + headH / 2), anchor: anchor)
    }
    header("UTC", xs[0], widths[0], .leading); header("dB", xs[1], widths[1], .trailing); header("DT", xs[2], widths[2], .trailing)
    header("Freq", xs[3], widths[3], .trailing); header("DX", xs[4], widths[4], .center)
    ctx.draw(Text("Meldung").font(headerFont).foregroundColor(themeColor(p.textDim)), at: CGPoint(x: messageX, y: pad + headH / 2), anchor: .leading)
    ctx.draw(Text("km").font(headerFont).foregroundColor(themeColor(p.textDim)), at: CGPoint(x: kmRight, y: pad + headH / 2), anchor: .trailing)

    let capacity = max(0, Int((CGFloat(h) - pad * 2 - headH) / lineH))
    let shown = Array(entries.suffix(capacity))
    var y = pad + headH
    for (i, e) in shown.enumerated() {
        let d = e.decode
        if i > 0, shown[i - 1].decode.cycleStart != d.cycleStart {
            ctx.fill(Path(CGRect(x: pad, y: y - 0.5, width: CGFloat(w) - 2 * pad, height: 1)), with: .color(themeColor(p.borderSubtle)))
        }
        let c: RGB = e.mentionsMe ? p.ledRed : d.isUncertain ? p.textDim : d.message.isCQ ? p.vfdGreen : p.vfdCyan
        let font = Font.system(size: 11, weight: d.message.isCQ ? .bold : .medium, design: .monospaced)
        let mid = y + lineH / 2
        func cell(_ s: String, _ x: CGFloat, _ width: CGFloat, _ anchor: UnitPoint) {
            let ax = anchor == .trailing ? x + width : (anchor == .center ? x + width / 2 : x)
            ctx.draw(Text(s).font(font).foregroundColor(themeColor(c)), at: CGPoint(x: ax, y: mid), anchor: anchor)
        }
        cell(FT8Controller.utc.string(from: d.cycleStart), xs[0], widths[0], .leading)
        cell(String(format: "%+d", d.snrDB), xs[1], widths[1], .trailing)
        cell(String(format: "%.1f", d.dt), xs[2], widths[2], .trailing)
        cell("\(Int(d.freqHz.rounded()))", xs[3], widths[3], .trailing)
        cell(e.dxcc?.flag ?? "", xs[4], widths[4], .center)
        // Meldung bis vor die km-Spalte beschneiden (wie `lineLimit(1)` am Mac)
        let messageWidth = max(0, kmRight - kmW - gap - messageX)
        ctx.drawLayer { l in
            l.clip(to: Path(CGRect(x: messageX, y: y, width: messageWidth, height: lineH)))
            l.draw(Text(d.text + (d.isUncertain ? " ?" : "")).font(font).foregroundColor(themeColor(c)), at: CGPoint(x: messageX, y: mid), anchor: .leading)
        }
        if let km = e.km { cell(String(format: "%.0f", km), kmRight - kmW, kmW, .trailing) }
        y += lineH
    }
}

// MARK: - Zyklus

@MainActor
func drawFT8Cycle(_ cr: OpaquePointer, _ w: Double, _ h: Double, busy: Bool, palette p: ThemePalette) {
    var ctx = GraphicsContext(cairo: cr, size: CGSize(width: w, height: h))
    let t = Date().timeIntervalSince1970
    let inCycle = t.truncatingRemainder(dividingBy: FT8Core.cycleSeconds)
    let accent = inCycle >= 13.2 ? p.vfdAmber : p.vfdGreen
    ctx.draw(Text(String(format: "%02.0f", inCycle.rounded(.down))).font(.system(size: 22, weight: .black, design: .monospaced)).foregroundColor(themeColor(accent)),
             at: CGPoint(x: 0, y: 14), anchor: .leading)
    let barX: CGFloat = 46, barW = CGFloat(w) - barX
    ctx.fill(Path(roundedRect: CGRect(x: barX, y: 5, width: barW, height: 6), cornerRadius: 2), with: .color(themeColor(p.bgDeep)))
    ctx.fill(Path(roundedRect: CGRect(x: barX, y: 5, width: max(2, barW * inCycle / FT8Core.cycleSeconds), height: 6), cornerRadius: 2), with: .color(themeColor(accent)))
    ctx.draw(Text(busy ? "DECODIERT …" : "EMPFANG · Decodieren bei 14,6 s").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(themeColor(p.textDim)),
             at: CGPoint(x: barX, y: 24), anchor: .leading)
}

@MainActor
func drawReadouts(_ cr: OpaquePointer, _ w: Double, _ h: Double, items: [(String, String)], palette p: ThemePalette) {
    var ctx = GraphicsContext(cairo: cr, size: CGSize(width: w, height: h))
    guard !items.isEmpty else { return }
    let cell = CGFloat(w) / CGFloat(items.count)
    for (i, item) in items.enumerated() {
        let x = CGFloat(i) * cell
        let label = Text(item.0).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundColor(themeColor(p.textDim))
        ctx.draw(label, at: CGPoint(x: x, y: h / 2), anchor: .leading)
        ctx.draw(Text(item.1).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(themeColor(p.vfdCyan)),
                 at: CGPoint(x: x + CGFloat(item.0.count) * 6 + 8, y: h / 2), anchor: .leading)
    }
}

// MARK: - S-Meter-Karteninhalt

/// Inhalt der Karte „Abstimmanzeige“ im Stil von `AnalogSMeterPanel`: Instrument, darunter Messwert bzw. „KEIN SDR-EMPFANG“
@MainActor
func drawSMeterPanel(_ cr: OpaquePointer, _ w: Double, _ h: Double, db: Double, live: Bool, readingText: String, ballistics: NeedleBallistics, palette p: ThemePalette) {
    let footer: CGFloat = 18
    cairo_save(cr)
    drawOriginalSMeter(cr, w, h - footer - 6, db: db, lit: live, ballistics: ballistics, canvas: CGSize(width: w, height: h))
    cairo_restore(cr)
    var ctx = GraphicsContext(cairo: cr, size: CGSize(width: w, height: h))
    if live {
        ctx.draw(Text(readingText).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundColor(themeColor(p.vfdAmber)), at: CGPoint(x: 0, y: h - 9), anchor: .leading)
    } else {
        ctx.draw(Text("KEIN SDR-EMPFANG").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(themeColor(p.textDim)).tracking(1.0),
                 at: CGPoint(x: 0, y: h - 9), anchor: .leading)
    }
}

// MARK: - Wasserfall (Entwurf)

@MainActor
func drawFT8Waterfall(_ cr: OpaquePointer, _ w: Double, _ h: Double, image: CGImage?, binWidth: Double, rxHz: Double, minHz: Double, maxHz: Double, palette p: ThemePalette) {
    drawWaterfall(cr, w, h, image: image, binWidth: binWidth, spectrum: [], peakHz: 0, theme: p, card: false)
    // Empfangsfrequenz (Ton von rx bis rx + 50 Hz) und Grenzen des Suchbereichs
    guard let image else { return }
    let axis = 20.0
    let areaH = h - axis
    let maxAxis = binWidth * Double(image.width)
    func x(_ f: Double) -> Double { f / maxAxis * w }
    var ctx = GraphicsContext(cairo: cr, size: CGSize(width: w, height: h))
    ctx.fill(Path(CGRect(x: x(rxHz), y: 0, width: max(2, x(rxHz + 50) - x(rxHz)), height: areaH)), with: .color(themeColor(p.vfdAmber, 0.22)))
    for f in [minHz, maxHz] {
        ctx.fill(Path(CGRect(x: x(f), y: 0, width: 1, height: areaH)), with: .color(themeColor(p.textDim, 0.6)))
    }
}
