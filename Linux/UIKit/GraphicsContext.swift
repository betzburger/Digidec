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
}

// MARK: - Weichzeichner

/// Kastenbreiten (Kovesi) für drei Durchgänge, die den Gauß-Filter mit Standardabweichung `sigma` annähern
private func boxRadii(sigma: Double) -> [Int] {
    let ideal = (12 * sigma * sigma / 3 + 1).squareRoot()
    var low = Int(ideal.rounded(.down)); if low % 2 == 0 { low -= 1 }
    low = max(low, 1)
    let high = low + 2
    let m = Int((12 * sigma * sigma - 3 * Double(low * low) - 12 * Double(low) - 9) / (-4 * Double(low) - 4))
    return (0..<3).map { ($0 < m ? low : high) }.filter { $0 >= 1 }.map { ($0 - 1) / 2 }
}

/// Ein Durchgang des Kastenfilters über `count` Elemente mit Schrittweite `step` (Ränder zählen als 0), ganzzahlig und ohne Zwischenfelder
@inline(__always)
private func boxLine(_ src: UnsafePointer<UInt8>, _ dst: UnsafeMutablePointer<UInt8>, count: Int, step: Int, radius r: Int) {
    let window = 2 * r + 1
    var sum = 0
    for k in 0..<min(r + 1, count) { sum += Int(src[k * step]) }
    // Division durch Multiplikation mit Kehrwert (16.16), mit Rundung
    let inv = (1 << 16) / window
    let half = 1 << 15
    for i in 0..<count {
        dst[i * step] = UInt8(truncatingIfNeeded: min(255, (sum * inv + half) >> 16))
        let add = i + r + 1, drop = i - r
        if add < count { sum += Int(src[add * step]) }
        if drop >= 0 { sum -= Int(src[drop * step]) }
    }
}

/// Weichzeichner auf einem Bild mit `channels` Bytes je Pixel (ARGB32: 4, A8: 1); die Ränder zählen als transparent,
/// die Ebene muss also genug Rand haben (≥ 3σ).
func boxBlur(_ data: UnsafeMutablePointer<UInt8>, width w: Int, height h: Int, stride: Int, channels: Int, sigma: Double) {
    let radii = boxRadii(sigma: max(sigma, 0.1))
    let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: stride * h)
    defer { scratch.deallocate() }
    for r in radii {
        // waagerecht: data → scratch, senkrecht: scratch → data
        for y in 0..<h {
            for c in 0..<channels { boxLine(data + y * stride + c, scratch + y * stride + c, count: w, step: channels, radius: r) }
        }
        for x in 0..<w {
            for c in 0..<channels { boxLine(scratch + x * channels + c, data + x * channels + c, count: h, step: stride, radius: r) }
        }
    }
}

func blurImage(_ surface: OpaquePointer, radius: Double) {
    cairo_surface_flush(surface)
    guard let data = cairo_image_surface_get_data(surface) else { return }
    let w = Int(cairo_image_surface_get_width(surface)), h = Int(cairo_image_surface_get_height(surface))
    let stride = Int(cairo_image_surface_get_stride(surface))
    boxBlur(data, width: w, height: h, stride: stride, channels: 4, sigma: radius)
    cairo_surface_mark_dirty(surface)
}

/// Fertig weichgezeichnete Schattenmasken (A8), ausgewählt nach dem Inhalt der Silhouette: gleiche Silhouette → keine neue Rechnung
final class ShadowMask {
    let surface: OpaquePointer
    init(_ s: OpaquePointer) { surface = s }
    deinit { cairo_surface_destroy(surface) }
}

enum ShadowCache {
    struct Key: Hashable { var hash: UInt64; var w: Int32; var h: Int32; var sigma: Double }
    /// Schlüssel über den Fingerabdruck des Knotenbaums: spart auch das Zeichnen der Silhouette
    struct NodeKey: Hashable { var signature: Int; var fx: Int; var fy: Int; var w: Int32; var h: Int32; var sigma: Double }
    nonisolated(unsafe) private static var byNode: [NodeKey: ShadowMask] = [:]
    static func lookup(_ key: NodeKey) -> ShadowMask? { byNode[key] }
    static func store(_ key: NodeKey, _ mask: ShadowMask) { byNode[key] = mask }
    nonisolated(unsafe) private static var entries: [Key: ShadowMask] = [:]
    nonisolated(unsafe) private static var bytes = 0
    private static let limit = 24 << 20

    static func lookup(_ key: Key) -> ShadowMask? { entries[key] }
    static func store(_ key: Key, _ mask: ShadowMask) {
        let size = Int(key.w) * Int(key.h)
        if bytes + size > limit { entries.removeAll(keepingCapacity: true); byNode.removeAll(keepingCapacity: true); bytes = 0 }
        entries[key] = mask
        bytes += size
    }

    /// FNV-1a über das Bild, wortweise
    static func hash(_ data: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for y in 0..<height {
            let row = UnsafeRawPointer(data + y * stride)
            let words = width / 8
            for i in 0..<words { h = (h ^ row.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)) &* 0x100000001b3 }
            for i in (words * 8)..<width { h = (h ^ UInt64(data[y * stride + i])) &* 0x100000001b3 }
        }
        return h
    }
}

extension GraphicsContext {
    /// Schatten für beliebigen Inhalt: Silhouette des Inhalts in `color`, weichgezeichnet (σ = radius / 2) und um (x, y) versetzt.
    /// Mit `bounds` (Ausdehnung des Inhalts in Benutzerkoordinaten) wird die Silhouette direkt in eine A8-Maske gezeichnet;
    /// ohne sie über eine Aufzeichnung, deren Ausdehnung erst ermittelt werden muss.
    public func drawShadow(color: Color, radius: CGFloat, x: CGFloat, y: CGFloat, bounds: CGRect? = nil, signature: Int? = nil, content: (inout GraphicsContext) -> Void) {
        guard color.alpha > 0 else { return }
        var scaleX = 1.0, scaleY = 1.0
        cairo_surface_get_device_scale(cairo_get_target(cr), &scaleX, &scaleY)
        var user = cairo_matrix_t()
        cairo_get_matrix(cr, &user)
        var factor = cairo_matrix_t()
        cairo_matrix_init_scale(&factor, scaleX, scaleY)
        var layerMatrix = cairo_matrix_t()
        cairo_matrix_multiply(&layerMatrix, &user, &factor)
        let sigma = max(0.1, Double(radius) / 2 * max(scaleX, scaleY))
        let pad = (sigma * 3).rounded(.up) + 2

        var x0 = 0.0, y0 = 0.0
        var w: Int32 = 0, h: Int32 = 0
        var recording: OpaquePointer?
        var silhouette: OpaquePointer?
        var nodeKey: ShadowCache.NodeKey?
        defer { if let recording { cairo_surface_destroy(recording) } }

        if let bounds {
            // Ausdehnung in Ebenenpunkten (Gerätepunkte mal Gerätefaktor)
            var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
            for corner in [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY), CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)] {
                var px = Double(corner.x), py = Double(corner.y)
                cairo_matrix_transform_point(&layerMatrix, &px, &py)
                minX = min(minX, px); maxX = max(maxX, px); minY = min(minY, py); maxY = max(maxY, py)
            }
            guard maxX > minX, maxY > minY, maxX - minX < 8192, maxY - minY < 8192 else { return }
            x0 = (minX - pad).rounded(.down); y0 = (minY - pad).rounded(.down)
            w = Int32((maxX - minX + 2 * pad).rounded(.up)); h = Int32((maxY - minY + 2 * pad).rounded(.up))
            if let signature {
                let key = ShadowCache.NodeKey(signature: signature, fx: Int(((minX - minX.rounded(.down)) * 8).rounded()), fy: Int(((minY - minY.rounded(.down)) * 8).rounded()), w: w, h: h, sigma: sigma)
                nodeKey = key
                if let mask = ShadowCache.lookup(key) {
                    cairo_save(cr)
                    cairo_identity_matrix(cr)
                    cairo_scale(cr, 1 / scaleX, 1 / scaleY)
                    cairo_set_source_rgba(cr, color.red, color.green, color.blue, color.alpha)
                    cairo_mask_surface(cr, mask.surface, x0 + Double(x) * scaleX, y0 + Double(y) * scaleY)
                    cairo_restore(cr)
                    return
                }
            }
            guard let image = cairo_image_surface_create(CAIRO_FORMAT_A8, w, h) else { return }
            silhouette = image
            let imageCr = cairo_create(image)!
            var shift = cairo_matrix_t()
            cairo_matrix_init_translate(&shift, -x0, -y0)
            var matrix = cairo_matrix_t()
            cairo_matrix_multiply(&matrix, &layerMatrix, &shift)
            cairo_set_matrix(imageCr, &matrix)
            var inner = GraphicsContext(cairo: imageCr, size: canvasSize)
            content(&inner)
            cairo_destroy(imageCr)
        } else {
            guard let rec = cairo_recording_surface_create(CAIRO_CONTENT_COLOR_ALPHA, nil) else { return }
            recording = rec
            let layerCr = cairo_create(rec)!
            cairo_set_matrix(layerCr, &layerMatrix)
            var inner = GraphicsContext(cairo: layerCr, size: canvasSize)
            content(&inner)
            cairo_destroy(layerCr)
            var inkX = 0.0, inkY = 0.0, inkW = 0.0, inkH = 0.0
            cairo_recording_surface_ink_extents(rec, &inkX, &inkY, &inkW, &inkH)
            guard inkW > 0, inkH > 0 else { return }
            x0 = (inkX - pad).rounded(.down); y0 = (inkY - pad).rounded(.down)
            w = Int32((inkW + 2 * pad).rounded(.up)); h = Int32((inkH + 2 * pad).rounded(.up))
            guard let image = cairo_image_surface_create(CAIRO_FORMAT_A8, w, h) else { return }
            silhouette = image
            let imageCr = cairo_create(image)!
            cairo_set_source_rgba(imageCr, 0, 0, 0, 1)
            cairo_mask_surface(imageCr, rec, -x0, -y0)
            cairo_destroy(imageCr)
        }
        guard let silhouette else { return }

        cairo_surface_flush(silhouette)
        let stride = Int(cairo_image_surface_get_stride(silhouette))
        let mask: ShadowMask
        if let data = cairo_image_surface_get_data(silhouette) {
            let key = ShadowCache.Key(hash: ShadowCache.hash(data, stride: stride, width: Int(w), height: Int(h)), w: w, h: h, sigma: sigma)
            if let cached = ShadowCache.lookup(key) {
                cairo_surface_destroy(silhouette)
                mask = cached
            } else {
                if sigma > 0.3 {
                    boxBlur(data, width: Int(w), height: Int(h), stride: stride, channels: 1, sigma: sigma)
                    cairo_surface_mark_dirty(silhouette)
                }
                mask = ShadowMask(silhouette)
                ShadowCache.store(key, mask)
            }
            if let nodeKey { ShadowCache.store(nodeKey, mask) }
        } else { cairo_surface_destroy(silhouette); return }
        cairo_save(cr)
        cairo_identity_matrix(cr)
        cairo_scale(cr, 1 / scaleX, 1 / scaleY)
        cairo_set_source_rgba(cr, color.red, color.green, color.blue, color.alpha)
        cairo_mask_surface(cr, mask.surface, x0 + Double(x) * scaleX, y0 + Double(y) * scaleY)
        cairo_restore(cr)
    }

    /// Gruppe für Deckkraft: Die Zwischenfläche deckt nur `bounds` ab (sonst die ganze Beschnittfläche, oft das ganze Fenster)
    func drawOpacityGroup(alpha: Double, bounds: CGRect, content: (inout GraphicsContext) -> Void) {
        cairo_save(cr)
        cairo_rectangle(cr, bounds.minX, bounds.minY, bounds.width, bounds.height)
        cairo_clip(cr)
        cairo_push_group(cr)
        var inner = self
        content(&inner)
        cairo_pop_group_to_source(cr)
        cairo_paint_with_alpha(cr, alpha)
        cairo_restore(cr)
    }
}
