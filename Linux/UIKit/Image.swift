// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Bilder (CGImage) und Symbole (SF-Symbol-Namen werden mit Cairo gezeichnet), Label.
import Foundation
import CGtkCairo

public struct Image: PrimitiveView {
    enum Source { case symbol(String), bitmap(CGImage) }
    let source: Source
    var isResizable = false
    var interpolationNone = false

    public init(systemName: String) { source = .symbol(systemName) }
    public init(systemSymbolName: String, accessibilityDescription: String?) { source = .symbol(systemSymbolName) }
    public init(_ cgImage: CGImage, scale: CGFloat, label: Text) { source = .bitmap(cgImage) }
    public init(decorative cgImage: CGImage, scale: CGFloat) { source = .bitmap(cgImage) }
    public init(decorative cgImage: CGImage, scale: CGFloat, orientation: Orientation) { source = .bitmap(cgImage) }
    public enum Orientation { case up }

    public func resizable() -> Image { var i = self; i.isResizable = true; return i }
    public func interpolation(_ i: Interpolation) -> Image { var c = self; c.interpolationNone = i == .none; return c }
    public enum Interpolation { case none, low, medium, high }
    public func renderingMode(_ mode: TemplateRenderingMode) -> Image { self }
    public enum TemplateRenderingMode { case original, template }
    public func imageScale(_ scale: Scale) -> Image { self }
    public enum Scale { case small, medium, large }
    public func symbolRenderingMode(_ mode: SymbolRenderingMode?) -> Image { self }
    public struct SymbolRenderingMode: Sendable { public static let monochrome = SymbolRenderingMode(), hierarchical = SymbolRenderingMode(), multicolor = SymbolRenderingMode(), palette = SymbolRenderingMode() }

    func makeNodes(_ r: Resolver) -> [Node] {
        [ImageNode(identity: r.identity, source: source, resizable: isResizable, nearest: interpolationNone, color: r.env.foregroundColor ?? .primary, fontSize: r.env.font.size)]
    }
}

@MainActor
final class ImageNode: Node {
    let source: Image.Source
    let resizable: Bool
    let nearest: Bool
    let color: Color
    let fontSize: CGFloat

    init(identity: Identity, source: Image.Source, resizable: Bool, nearest: Bool, color: Color, fontSize: CGFloat) {
        self.source = source; self.resizable = resizable; self.nearest = nearest; self.color = color; self.fontSize = fontSize
        super.init(identity: identity)
    }

    override func computeSize(_ p: Proposal) -> CGSize {
        switch source {
        case .symbol:
            let side = (fontSize * 1.15).rounded()
            return CGSize(width: side, height: side)
        case .bitmap(let image):
            if resizable { return CGSize(width: p.width.flatMap { $0.isFinite ? $0 : nil } ?? CGFloat(image.width), height: p.height.flatMap { $0.isFinite ? $0 : nil } ?? CGFloat(image.height)) }
            return CGSize(width: image.width, height: image.height)
        }
    }

    override func draw(_ g: inout GraphicsContext, clip: CGRect) {
        switch source {
        case .symbol(let name): Icons.draw(name, in: frame, color: color, g: &g)
        case .bitmap(let image): g.drawImage(image, in: frame, nearest: nearest)
        }
    }
}

extension GraphicsContext {
    /// Zeichnet ein Rasterbild in `rect` (RGBA/Grau/RGB wie `CGImage` es liefert)
    public func drawImage(_ image: CGImage, in rect: CGRect, nearest: Bool = false) {
        guard rect.width > 0, rect.height > 0, let data = image.dataProvider?.data else { return }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let bpp = image.bitsPerPixel / 8
        let alpha = image.alphaInfo
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<w {
                    let o = y * image.bytesPerRow + x * bpp
                    let d = (y * w + x) * 4
                    var r: UInt8, gr: UInt8, b: UInt8, a: UInt8 = 255
                    if bpp == 1 { r = src[o]; gr = r; b = r }
                    else {
                        switch alpha {
                        case .first, .noneSkipFirst, .premultipliedFirst: r = src[o + 1]; gr = src[o + 2]; b = src[o + 3]; a = alpha == .noneSkipFirst ? 255 : src[o]
                        default: r = src[o]; gr = src[o + 1]; b = src[o + 2]; a = (alpha == .last || alpha == .premultipliedLast) ? src[o + 3] : 255
                        }
                    }
                    // Cairo ARGB32: Bytes B G R A, vormultipliziert
                    let af = UInt16(a)
                    pixels[d] = UInt8(UInt16(b) * af / 255); pixels[d + 1] = UInt8(UInt16(gr) * af / 255); pixels[d + 2] = UInt8(UInt16(r) * af / 255); pixels[d + 3] = a
                }
            }
        }
        pixels.withUnsafeMutableBytes { buffer in
            guard let surface = cairo_image_surface_create_for_data(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), CAIRO_FORMAT_ARGB32, Int32(w), Int32(h), Int32(w * 4)) else { return }
            cairo_save(cr)
            cairo_rectangle(cr, rect.minX, rect.minY, rect.width, rect.height)
            cairo_clip(cr)
            cairo_translate(cr, rect.minX, rect.minY)
            cairo_scale(cr, rect.width / CGFloat(w), rect.height / CGFloat(h))
            cairo_set_source_surface(cr, surface, 0, 0)
            cairo_pattern_set_filter(cairo_get_source(cr), nearest ? CAIRO_FILTER_NEAREST : CAIRO_FILTER_BILINEAR)
            cairo_paint(cr)
            cairo_restore(cr)
            cairo_surface_destroy(surface)
        }
    }
}

// MARK: - Label

public struct Label<Title: View, Icon: View>: View {
    let title: Title, icon: Icon
    public init(@ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) { self.title = title(); self.icon = icon() }
    public var body: some View { HStack(spacing: 4) { icon; title } }
}

extension Label where Title == Text, Icon == Image {
    public init(_ title: LocalizedStringKey, systemImage: String) { self.title = Text(title); icon = Image(systemName: systemImage) }
    public init<S: StringProtocol>(_ title: S, systemImage: String) { self.title = Text(title); icon = Image(systemName: systemImage) }
}

extension Label where Title == Text, Icon == EmptyView {
    public init(_ title: LocalizedStringKey) { self.title = Text(title); icon = EmptyView() }
}
