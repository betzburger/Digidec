// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Ersatz für den kleinen Teil von CoreGraphics, den Digidec für Rasterbilder nutzt (nur Linux).
// CGFloat, CGPoint, CGSize und CGRect liefert Foundation.
@_exported import Foundation

// Bequemlichkeiten, damit `x as CFData` usw. im gemeinsamen Quelltext unverändert bleibt
public typealias CFData = Data
public typealias CFURL = URL
public typealias CFString = String
public typealias CFDictionary = [String: Any]

public enum CGImageAlphaInfo: UInt32, Sendable {
    case none = 0, premultipliedLast, premultipliedFirst, last, first, noneSkipLast, noneSkipFirst, alphaOnly
}

public struct CGBitmapInfo: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public var alpha: CGImageAlphaInfo { CGImageAlphaInfo(rawValue: rawValue & 0x1F) ?? .none }
}

public enum CGColorRenderingIntent: Int32, Sendable { case defaultIntent = 0 }

public final class CGColorSpace: @unchecked Sendable {
    public let componentCount: Int
    init(components: Int) { componentCount = components }
}
public func CGColorSpaceCreateDeviceRGB() -> CGColorSpace { CGColorSpace(components: 3) }
public func CGColorSpaceCreateDeviceGray() -> CGColorSpace { CGColorSpace(components: 1) }

public final class CGDataProvider: @unchecked Sendable {
    public let data: Data
    public init?(data: CFData) { self.data = data }
}

public final class CGImage: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let bitsPerComponent: Int
    public let bitsPerPixel: Int
    public let bytesPerRow: Int
    public let colorSpace: CGColorSpace?
    public let bitmapInfo: CGBitmapInfo
    public let dataProvider: CGDataProvider?
    public var alphaInfo: CGImageAlphaInfo { bitmapInfo.alpha }

    public init?(width: Int, height: Int, bitsPerComponent: Int, bitsPerPixel: Int, bytesPerRow: Int, space: CGColorSpace,
                 bitmapInfo: CGBitmapInfo, provider: CGDataProvider, decode: UnsafePointer<CGFloat>?, shouldInterpolate: Bool,
                 intent: CGColorRenderingIntent) {
        guard width > 0, height > 0, bitsPerComponent == 8, bitsPerPixel % 8 == 0, bytesPerRow >= width * bitsPerPixel / 8,
              provider.data.count >= bytesPerRow * (height - 1) + width * bitsPerPixel / 8 else { return nil }
        self.width = width; self.height = height
        self.bitsPerComponent = bitsPerComponent; self.bitsPerPixel = bitsPerPixel; self.bytesPerRow = bytesPerRow
        colorSpace = space; self.bitmapInfo = bitmapInfo; dataProvider = provider
    }

    /// Ausschnitt (Punkte, oben links beginnend)
    public func cropping(to rect: CGRect) -> CGImage? {
        let x0 = max(0, Int(rect.minX.rounded(.down))), y0 = max(0, Int(rect.minY.rounded(.down)))
        let x1 = min(width, Int(rect.maxX.rounded(.up))), y1 = min(height, Int(rect.maxY.rounded(.up)))
        guard x1 > x0, y1 > y0, let provider = dataProvider, let space = colorSpace else { return nil }
        let bpp = bitsPerPixel / 8, newRow = (x1 - x0) * bpp
        var out = Data(count: newRow * (y1 - y0))
        provider.data.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                for y in y0..<y1 {
                    memcpy(dst.baseAddress! + (y - y0) * newRow, src.baseAddress! + y * bytesPerRow + x0 * bpp, newRow)
                }
            }
        }
        guard let newProvider = CGDataProvider(data: out) else { return nil }
        return CGImage(width: x1 - x0, height: y1 - y0, bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerPixel, bytesPerRow: newRow,
                       space: space, bitmapInfo: bitmapInfo, provider: newProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Punkt als RGBA (0…255, nicht vormultipliziert)
    public func rgba(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard let data = dataProvider?.data else { return (0, 0, 0, 255) }
        let bpp = bitsPerPixel / 8
        let o = y * bytesPerRow + x * bpp
        return data.withUnsafeBytes { raw -> (UInt8, UInt8, UInt8, UInt8) in
            let p = raw.bindMemory(to: UInt8.self)
            if bpp == 1 { return (p[o], p[o], p[o], 255) }
            switch alphaInfo {
            case .first, .noneSkipFirst, .premultipliedFirst: return (p[o + 1], p[o + 2], p[o + 3], alphaInfo == .noneSkipFirst ? 255 : p[o])
            case .last, .premultipliedLast:
                let a = p[o + 3]
                if alphaInfo == .premultipliedLast, a > 0, a < 255 {
                    return (UInt8(min(255, Int(p[o]) * 255 / Int(a))), UInt8(min(255, Int(p[o + 1]) * 255 / Int(a))), UInt8(min(255, Int(p[o + 2]) * 255 / Int(a))), a)
                }
                return (p[o], p[o + 1], p[o + 2], a)
            default: return (p[o], p[o + 1], p[o + 2], 255)
            }
        }
    }
}

/// Zeichenfläche über einem fremden Puffer (Grau 8 Bit oder RGBA 8 Bit); unterstützt wird nur das Einsetzen eines Bildes.
public final class CGContext {
    private let base: UnsafeMutablePointer<UInt8>
    private let width: Int, height: Int, bytesPerRow: Int, components: Int

    public init?(data: UnsafeMutableRawPointer?, width: Int, height: Int, bitsPerComponent: Int, bytesPerRow: Int, space: CGColorSpace, bitmapInfo: UInt32) {
        guard let data, bitsPerComponent == 8, width > 0, height > 0 else { return nil }
        base = data.assumingMemoryBound(to: UInt8.self)
        self.width = width; self.height = height; self.bytesPerRow = bytesPerRow; components = space.componentCount == 1 ? 1 : 4
    }

    /// Skaliert das Bild auf `rect` (Punkte; die y-Achse läuft wie bei Apple von unten nach oben) und legt es über den Puffer.
    public func draw(_ image: CGImage, in rect: CGRect) {
        let dstW = Int(rect.width.rounded()), dstH = Int(rect.height.rounded())
        guard dstW > 0, dstH > 0 else { return }
        let top = height - Int((rect.minY + rect.height).rounded())
        for dy in 0..<dstH {
            let y = top + dy
            guard y >= 0, y < height else { continue }
            let sy = min(image.height - 1, dy * image.height / dstH)
            for dx in 0..<dstW {
                let x = Int(rect.minX.rounded()) + dx
                guard x >= 0, x < width else { continue }
                let sx = min(image.width - 1, dx * image.width / dstW)
                let c = image.rgba(x: sx, y: sy)
                let o = y * bytesPerRow + x * components
                if components == 1 {
                    let luma = (299 * Int(c.r) + 587 * Int(c.g) + 114 * Int(c.b)) / 1000
                    let a = Int(c.a)
                    base[o] = UInt8((luma * a + Int(base[o]) * (255 - a)) / 255)
                } else {
                    base[o] = c.r; base[o + 1] = c.g; base[o + 2] = c.b; base[o + 3] = c.a
                }
            }
        }
    }
}

// Schlüssel für PNG-Zusatzangaben (ImageIO)
public let kCGImagePropertyPNGDictionary = "{PNG}"
public let kCGImagePropertyPNGDescription = "Description"
