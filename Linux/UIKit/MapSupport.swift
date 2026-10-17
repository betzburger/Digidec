// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Bausteine für die Kartenansicht: Kachelbilder, Mausrad, Zeichnen in eine PNG-Datei.
import Foundation
import CoreGraphics
import ImageIO
import CGtkCairo

/// Fertig umgerechnetes Rasterbild (Cairo-Fläche) für häufig gezeichnete Kacheln
public final class RasterTile: @unchecked Sendable {
    let surface: OpaquePointer
    public let width: Int, height: Int

    /// Dekodiert Bytes eines PNG- oder JPEG-Bildes (z. B. einer Kartenkachel); nil bei Fehler
    /// Umrechnung der Farben beim Dekodieren
    public enum Style: Sendable { case plain, night }

    /// Nachtdarstellung einer hellen Karte: Helligkeit umkehren, Farbton behalten (dunkle Fläche, helle Schrift)
    @inline(__always)
    private static func nightColor(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (UInt8, UInt8, UInt8) {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let mx = max(rf, gf, bf), mn = min(rf, gf, bf)
        let l = (mx + mn) / 2, d = mx - mn
        var h = 0.0, sat = 0.0
        if d > 1e-9 {
            sat = d / (1 - abs(2 * l - 1))
            if mx == rf { h = ((gf - bf) / d).truncatingRemainder(dividingBy: 6) } else if mx == gf { h = (bf - rf) / d + 2 } else { h = (rf - gf) / d + 4 }
            if h < 0 { h += 6 }
        }
        let nl = 0.09 + 0.40 * pow(1 - l, 1.15)
        let ns = min(1, sat * 0.75)
        let c = (1 - abs(2 * nl - 1)) * ns
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = nl - c / 2
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(h) {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        return (UInt8(min(255, (r1 + m) * 255)), UInt8(min(255, (g1 + m) * 255)), UInt8(min(255, (b1 + m) * 255)))
    }

    public init?(data: Data, style: Style = .plain) {
        let path = NSTemporaryDirectory() + "digidec-tile-\(UInt64.random(in: 0...UInt64.max)).img"
        guard (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return nil }
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let bytes = image.dataProvider?.data else { return nil }
        let w = image.width, h = image.height
        guard w > 0, h > 0, let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(w), Int32(h)) else { return nil }
        let stride = Int(cairo_image_surface_get_stride(surface))
        let dst = cairo_image_surface_get_data(surface)!
        let bpp = image.bitsPerPixel / 8
        bytes.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<w {
                    let o = y * image.bytesPerRow + x * bpp
                    let a: UInt8 = bpp >= 4 ? src[o + 3] : 255
                    let af = UInt16(a)
                    var r = src[o], g = bpp == 1 ? src[o] : src[o + 1], b = bpp == 1 ? src[o] : src[o + 2]
                    if style == .night { (r, g, b) = Self.nightColor(r, g, b) }
                    let d = dst + y * stride + x * 4
                    d[0] = UInt8(UInt16(b) * af / 255); d[1] = UInt8(UInt16(g) * af / 255); d[2] = UInt8(UInt16(r) * af / 255); d[3] = a
                }
            }
        }
        cairo_surface_mark_dirty(surface)
        self.surface = surface; width = w; height = h
    }

    deinit { cairo_surface_destroy(surface) }
}

extension GraphicsContext {
    /// Zeichnet (einen Ausschnitt von) `tile` in `rect`; `source` in Bildpunkten des Rasterbilds (nil = ganz)
    public func draw(tile: RasterTile, in rect: CGRect, source: CGRect? = nil, opacity: Double = 1) {
        cairo_save(cr)
        cairo_rectangle(cr, rect.minX, rect.minY, rect.width, rect.height)
        cairo_clip(cr)
        let src = source ?? CGRect(x: 0, y: 0, width: tile.width, height: tile.height)
        cairo_translate(cr, rect.minX, rect.minY)
        cairo_scale(cr, rect.width / src.width, rect.height / src.height)
        cairo_set_source_surface(cr, tile.surface, -src.minX, -src.minY)
        cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_BILINEAR)
        cairo_pattern_set_extend(cairo_get_source(cr), CAIRO_EXTEND_PAD)
        if opacity < 1 { cairo_paint_with_alpha(cr, opacity) } else { cairo_paint(cr) }
        cairo_restore(cr)
    }
}

/// Zeichnet mit `draw` in ein Bild und schreibt es als PNG; true bei Erfolg
@MainActor
public func renderPNG(size: CGSize, to path: String, draw: (inout GraphicsContext) -> Void) -> Bool {
    guard let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(size.width), Int32(size.height)) else { return false }
    defer { cairo_surface_destroy(surface) }
    let cr = cairo_create(surface)!
    defer { cairo_destroy(cr) }
    var context = GraphicsContext(cairo: cr, size: size)
    draw(&context)
    return cairo_surface_write_to_png(surface, path) == CAIRO_STATUS_SUCCESS
}

nonisolated extension View {
    /// Mausrad über der Ansicht: `delta` > 0 = vom Benutzer weg (hineinzoomen), Rückgabe true = verbraucht
    public func onScrollWheel(perform action: @escaping (_ delta: CGFloat, _ shift: Bool) -> Void) -> some View {
        modify { r, child in
            let n = IDNode(identity: r.identity, child: child)
            n.handlers = Handlers(scroll: { _, dy in action(-dy, false); return true })
            return n
        }
    }
}
