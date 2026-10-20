// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Bilder (CGImage) und Symbole (SF-Symbol-Namen werden mit Cairo gezeichnet), Label.
import Foundation
import CGtkCairo

public struct Image {
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

    @MainActor func makeNodes(_ r: Resolver) -> [Node] {
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

/// Die in Cairo-Format umgerechnete Fassung eines `CGImage`: bleibt erhalten, solange das Bild gleich bleibt
private final class ConvertedImage {
    weak var image: CGImage?
    let surface: OpaquePointer
    init(image: CGImage, surface: OpaquePointer) { self.image = image; self.surface = surface }
    deinit { cairo_surface_destroy(surface) }
}
nonisolated(unsafe) private var convertedImages: [ObjectIdentifier: ConvertedImage] = [:]

/// Cairo ARGB32 (Bytes B G R A, vormultipliziert) aus den Rohdaten des Bildes
private func makeSurface(for image: CGImage) -> OpaquePointer? {
    guard let data = image.dataProvider?.data else { return nil }
    let w = image.width, h = image.height
    guard w > 0, h > 0, let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(w), Int32(h)), let out = cairo_image_surface_get_data(surface) else { return nil }
    let stride = Int(cairo_image_surface_get_stride(surface))
    let bpp = image.bitsPerPixel / 8
    let rowBytes = image.bytesPerRow
    let alpha = image.alphaInfo
    // Lage der Kanäle im Quellpixel
    let first = alpha == .first || alpha == .noneSkipFirst || alpha == .premultipliedFirst
    let rOff = first ? 1 : 0, gOff = first ? 2 : 1, bOff = first ? 3 : 2
    let aOff: Int? = first ? (alpha == .noneSkipFirst ? nil : 0) : ((alpha == .last || alpha == .premultipliedLast) ? 3 : nil)
    data.withUnsafeBytes { raw in
        guard let src = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        for y in 0..<h {
            guard (y + 1) * rowBytes <= raw.count || y * rowBytes + w * bpp <= raw.count else { break }
            var s = src + y * rowBytes
            var d = out + y * stride
            if bpp == 1 {
                for _ in 0..<w { let v = s.pointee; d[0] = v; d[1] = v; d[2] = v; d[3] = 255; s += 1; d += 4 }
            } else if let aOff {
                for _ in 0..<w {
                    let af = UInt32(s[aOff])
                    d[0] = UInt8(UInt32(s[bOff]) * af / 255); d[1] = UInt8(UInt32(s[gOff]) * af / 255); d[2] = UInt8(UInt32(s[rOff]) * af / 255); d[3] = UInt8(af)
                    s += bpp; d += 4
                }
            } else {
                for _ in 0..<w { d[0] = s[bOff]; d[1] = s[gOff]; d[2] = s[rOff]; d[3] = 255; s += bpp; d += 4 }
            }
        }
    }
    cairo_surface_mark_dirty(surface)
    return surface
}

extension GraphicsContext {
    /// Zeichnet ein Rasterbild in `rect` (RGBA/Grau/RGB wie `CGImage` es liefert)
    public func drawImage(_ image: CGImage, in rect: CGRect, nearest: Bool = false) {
        guard rect.width > 0, rect.height > 0 else { return }
        let key = ObjectIdentifier(image)
        let surface: OpaquePointer
        if let cached = convertedImages[key], cached.image === image { surface = cached.surface }
        else {
            guard let made = makeSurface(for: image) else { return }
            if convertedImages.count >= 16 { convertedImages = convertedImages.filter { $0.value.image != nil } }
            if convertedImages.count >= 16 { convertedImages.removeAll() }
            convertedImages[key] = ConvertedImage(image: image, surface: made)
            surface = made
        }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        cairo_save(cr)
        cairo_rectangle(cr, rect.minX, rect.minY, rect.width, rect.height)
        cairo_clip(cr)
        cairo_translate(cr, rect.minX, rect.minY)
        cairo_scale(cr, rect.width / w, rect.height / h)
        cairo_set_source_surface(cr, surface, 0, 0)
        cairo_pattern_set_filter(cairo_get_source(cr), nearest ? CAIRO_FILTER_NEAREST : CAIRO_FILTER_BILINEAR)
        cairo_paint(cr)
        cairo_restore(cr)
    }
}

// MARK: - Label

public struct Label<Title: View, Icon: View> {
    let title: Title, icon: Icon
    public init(@ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) { self.title = title(); self.icon = icon() }
    public var body: some View { HStack(spacing: 4) { icon; title } }
}

extension Label where Title == Text, Icon == Image {
    public init(_ title: LocalizedStringKey, systemImage: String) { self.title = Text(title); icon = Image(systemName: systemImage) }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage: String) { self.title = Text(title); icon = Image(systemName: systemImage) }
}

extension Label where Title == Text, Icon == EmptyView {
    public init(_ title: LocalizedStringKey) { self.title = Text(title); icon = EmptyView() }
}

// Konformitäten als Erweiterung, damit die Typen nicht auf den Hauptakteur isoliert werden (wie in SwiftUI)
extension Image: PrimitiveView {}
extension Label: View {}
