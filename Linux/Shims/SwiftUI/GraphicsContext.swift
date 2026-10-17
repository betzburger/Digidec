// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// GraphicsContext auf Cairo (nur Linux), siehe Graphics.swift
import Foundation
import CoreGraphics
import CGtkCairo

public struct GraphicsContext {
    public enum Shading {
        case color(Color)
        case linearGradient(Gradient, startPoint: CGPoint, endPoint: CGPoint)
        case radialGradient(Gradient, center: CGPoint, startRadius: CGFloat, endRadius: CGFloat)
    }

    public struct Filter {
        let blur: CGFloat
        public static func blur(radius: CGFloat) -> Filter { Filter(blur: radius) }
    }

    let cr: OpaquePointer
    /// Zeichenfläche in Punkten (für Zwischenebenen)
    let canvasSize: CGSize
    var pendingBlur: CGFloat = 0

    /// `cr`: Cairo-Kontext, `size`: Größe der Zeichenfläche in Punkten
    public init(cairo cr: OpaquePointer, size: CGSize) {
        self.cr = cr
        canvasSize = size
    }

    // MARK: Pfade und Farben

    private func apply(_ path: Path) {
        cairo_new_path(cr)
        var current = CGPoint.zero
        for element in path.elements {
            switch element {
            case .move(let p): cairo_move_to(cr, p.x, p.y); current = p
            case .line(let p): cairo_line_to(cr, p.x, p.y); current = p
            case .quad(let p, let c):
                // quadratisch → kubisch
                cairo_curve_to(cr, current.x + 2.0 / 3 * (c.x - current.x), current.y + 2.0 / 3 * (c.y - current.y),
                               p.x + 2.0 / 3 * (c.x - p.x), p.y + 2.0 / 3 * (c.y - p.y), p.x, p.y)
                current = p
            case .curve(let p, let c1, let c2): cairo_curve_to(cr, c1.x, c1.y, c2.x, c2.y, p.x, p.y); current = p
            case .close: cairo_close_path(cr)
            case .rect(let r): cairo_rectangle(cr, r.minX, r.minY, r.width, r.height)
            case .ellipse(let r):
                cairo_new_sub_path(cr)
                cairo_save(cr)
                cairo_translate(cr, r.midX, r.midY)
                cairo_scale(cr, max(r.width / 2, 1e-6), max(r.height / 2, 1e-6))
                cairo_arc(cr, 0, 0, 1, 0, 2 * Double.pi)
                cairo_restore(cr)
            case .arc(let c, let radius, let start, let end, let clockwise):
                if clockwise { cairo_arc(cr, c.x, c.y, radius, start, end) } else { cairo_arc_negative(cr, c.x, c.y, radius, start, end) }
            }
        }
    }

    private func source(_ shading: Shading) {
        switch shading {
        case .color(let c): cairo_set_source_rgba(cr, c.red, c.green, c.blue, c.alpha)
        case .linearGradient(let g, let a, let b):
            let pattern = cairo_pattern_create_linear(a.x, a.y, b.x, b.y)!
            addStops(pattern, g)
            cairo_set_source(cr, pattern)
            cairo_pattern_destroy(pattern)
        case .radialGradient(let g, let c, let r0, let r1):
            let pattern = cairo_pattern_create_radial(c.x, c.y, r0, c.x, c.y, r1)!
            addStops(pattern, g)
            cairo_set_source(cr, pattern)
            cairo_pattern_destroy(pattern)
        }
    }

    private func addStops(_ pattern: OpaquePointer, _ g: Gradient) {
        for s in g.stops {
            cairo_pattern_add_color_stop_rgba(pattern, min(1, max(0, s.location)), s.color.red, s.color.green, s.color.blue, s.color.alpha)
        }
    }

    // MARK: Zeichnen

    public func fill(_ path: Path, with shading: Shading) {
        apply(path)
        source(shading)
        cairo_fill(cr)
    }

    public func stroke(_ path: Path, with shading: Shading, lineWidth: CGFloat = 1) {
        stroke(path, with: shading, style: StrokeStyle(lineWidth: lineWidth))
    }

    public func stroke(_ path: Path, with shading: Shading, style: StrokeStyle) {
        apply(path)
        source(shading)
        cairo_set_line_width(cr, style.lineWidth)
        switch style.lineCap {
        case .butt: cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
        case .round: cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        case .square: cairo_set_line_cap(cr, CAIRO_LINE_CAP_SQUARE)
        }
        switch style.lineJoin {
        case .miter: cairo_set_line_join(cr, CAIRO_LINE_JOIN_MITER)
        case .round: cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        case .bevel: cairo_set_line_join(cr, CAIRO_LINE_JOIN_BEVEL)
        }
        if !style.dash.isEmpty { style.dash.map { Double($0) }.withUnsafeBufferPointer { cairo_set_dash(cr, $0.baseAddress, Int32($0.count), 0) } } else { cairo_set_dash(cr, nil, 0, 0) }
        cairo_stroke(cr)
    }

    public func clip(to path: Path) {
        apply(path)
        cairo_clip(cr)
    }

    public func translateBy(x: CGFloat, y: CGFloat) { cairo_translate(cr, x, y) }
    public func scaleBy(x: CGFloat, y: CGFloat) { cairo_scale(cr, x, y) }
    public func rotate(by angle: Angle) { cairo_rotate(cr, angle.radians) }
    public mutating func addFilter(_ filter: Filter) { pendingBlur = filter.blur }

    /// Eigene Ebene: Änderungen an Umrechnung, Beschnitt und Filter gelten nur darin. Der Inhalt wird auf einer unbegrenzten
    /// Aufzeichnungsfläche gesammelt (kostet nichts, solange nichts gezeichnet wird) und danach eingesetzt; mit Weichzeichner
    /// nur der tatsächlich bemalte Ausschnitt als Bild.
    public func drawLayer(content: (inout GraphicsContext) -> Void) {
        var scaleX = 1.0, scaleY = 1.0
        cairo_surface_get_device_scale(cairo_get_target(cr), &scaleX, &scaleY)
        var user = cairo_matrix_t()
        cairo_get_matrix(cr, &user)
        // Aufzeichnung in echten Gerätepunkten: Umrechnung der Ebene = Benutzerumrechnung, danach der Gerätefaktor
        var factor = cairo_matrix_t()
        cairo_matrix_init_scale(&factor, scaleX, scaleY)
        var layerMatrix = cairo_matrix_t()
        cairo_matrix_multiply(&layerMatrix, &user, &factor)

        guard let recording = cairo_recording_surface_create(CAIRO_CONTENT_COLOR_ALPHA, nil) else { return }
        defer { cairo_surface_destroy(recording) }
        let layerCr = cairo_create(recording)!
        cairo_set_matrix(layerCr, &layerMatrix)
        var inner = GraphicsContext(cairo: layerCr, size: canvasSize)
        content(&inner)
        cairo_destroy(layerCr)

        var inkX = 0.0, inkY = 0.0, inkW = 0.0, inkH = 0.0
        cairo_recording_surface_ink_extents(recording, &inkX, &inkY, &inkW, &inkH)
        guard inkW > 0, inkH > 0 else { return }

        cairo_save(cr)
        defer { cairo_restore(cr) }
        cairo_identity_matrix(cr)
        cairo_scale(cr, 1 / scaleX, 1 / scaleY)
        if inner.pendingBlur > 0 {
            let radius = Double(inner.pendingBlur) * max(scaleX, scaleY)
            let pad = (radius * 3).rounded(.up) + 2
            let x0 = (inkX - pad).rounded(.down), y0 = (inkY - pad).rounded(.down)
            let w = Int32((inkW + 2 * pad).rounded(.up)), h = Int32((inkH + 2 * pad).rounded(.up))
            guard let image = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h) else { return }
            defer { cairo_surface_destroy(image) }
            let imageCr = cairo_create(image)!
            cairo_set_source_surface(imageCr, recording, -x0, -y0)
            cairo_paint(imageCr)
            cairo_destroy(imageCr)
            blurImage(image, radius: radius)
            cairo_set_source_surface(cr, image, x0, y0)
            cairo_paint(cr)
        } else {
            cairo_set_source_surface(cr, recording, 0, 0)
            cairo_paint(cr)
        }
    }

    // MARK: Text

    public func draw(_ text: Text, at point: CGPoint, anchor: UnitPoint = .center) {
        guard !text.content.isEmpty, let layout = pango_cairo_create_layout(cr) else { return }
        defer { g_object_unref(UnsafeMutableRawPointer(layout)) }
        let family: String
        switch text.font.design {
        case .monospaced: family = "Noto Sans Mono"
        case .rounded: family = "Noto Sans"
        case .serif: family = "Noto Serif"
        case .default: family = "Noto Sans"
        }
        let description = pango_font_description_new()!
        defer { pango_font_description_free(description) }
        pango_font_description_set_family(description, family)
        pango_font_description_set_weight(description, PangoWeight(rawValue: UInt32(text.font.weight.rawValue)))
        pango_font_description_set_absolute_size(description, Double(text.font.size) * Double(PANGO_SCALE))
        pango_layout_set_font_description(layout, description)
        pango_layout_set_text(layout, text.content, -1)
        if text.trackingValue != 0, let attributes = pango_attr_list_new() {
            pango_attr_list_insert(attributes, pango_attr_letter_spacing_new(Int32(Double(text.trackingValue) * Double(PANGO_SCALE))))
            pango_layout_set_attributes(layout, attributes)
            pango_attr_list_unref(attributes)
        }
        var w: Int32 = 0, h: Int32 = 0
        pango_layout_get_pixel_size(layout, &w, &h)
        cairo_save(cr)
        cairo_set_source_rgba(cr, text.color.red, text.color.green, text.color.blue, text.color.alpha)
        cairo_move_to(cr, point.x - Double(w) * anchor.x, point.y - Double(h) * anchor.y)
        pango_cairo_show_layout(cr, layout)
        cairo_restore(cr)
    }
}

// MARK: - Weichzeichner

/// Dreifacher Kastenfilter auf einem ARGB32-Bild (nähert den Gauß-Filter mit Standardabweichung `radius` an)
func blurImage(_ surface: OpaquePointer, radius: Double) {
    cairo_surface_flush(surface)
    guard let data = cairo_image_surface_get_data(surface) else { return }
    let w = Int(cairo_image_surface_get_width(surface)), h = Int(cairo_image_surface_get_height(surface))
    let stride = Int(cairo_image_surface_get_stride(surface))
    let sigma = max(radius, 0.1)
    // Kastenbreiten für drei Durchgänge (Kovesi)
    let ideal = (12 * sigma * sigma / 3 + 1).squareRoot()
    var low = Int(ideal.rounded(.down)); if low % 2 == 0 { low -= 1 }
    let high = low + 2
    let m = Int((12 * sigma * sigma - 3 * Double(low * low) - 12 * Double(low) - 9) / (-4 * Double(low) - 4))
    let sizes = (0..<3).map { $0 < m ? low : high }
    var a = [Float](repeating: 0, count: max(w, h) * 4), b = a
    func pass(_ r: Int, horizontal: Bool) {
        let lines = horizontal ? h : w, length = horizontal ? w : h
        let window = Float(2 * r + 1)
        for line in 0..<lines {
            for i in 0..<length {
                let o = horizontal ? line * stride + i * 4 : i * stride + line * 4
                for c in 0..<4 { a[i * 4 + c] = Float(data[o + c]) }
            }
            for c in 0..<4 {
                var sum: Float = 0
                for k in -r...r { sum += a[min(max(k, 0), length - 1) * 4 + c] }
                for i in 0..<length {
                    b[i * 4 + c] = sum / window
                    sum += a[min(i + r + 1, length - 1) * 4 + c] - a[max(i - r, 0) * 4 + c]
                }
            }
            for i in 0..<length {
                let o = horizontal ? line * stride + i * 4 : i * stride + line * 4
                for c in 0..<4 { data[o + c] = UInt8(max(0, min(255, b[i * 4 + c].rounded()))) }
            }
        }
    }
    for size in sizes where size >= 1 {
        let r = (size - 1) / 2
        pass(r, horizontal: true)
        pass(r, horizontal: false)
    }
    cairo_surface_mark_dirty(surface)
}
