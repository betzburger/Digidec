// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Ersatz für ImageIO (nur Linux): PNG schreiben, PNG/JPEG lesen über libpng und libjpeg.
@_exported import CoreGraphics
import CImageCodec

public final class CGImageSource { fileprivate let url: URL; fileprivate init(url: URL) { self.url = url } }

public func CGImageSourceCreateWithURL(_ url: CFURL, _ options: CFDictionary?) -> CGImageSource? {
    FileManager.default.fileExists(atPath: url.path) ? CGImageSource(url: url) : nil
}

public func CGImageSourceCreateImageAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CGImage? {
    guard index == 0 else { return nil }
    var w: Int32 = 0, h: Int32 = 0
    guard let raw = cimg_read_rgba(source.url.path, &w, &h) else { return nil }
    defer { cimg_free(raw) }
    let data = Data(bytes: raw, count: Int(w) * Int(h) * 4)
    guard let provider = CGDataProvider(data: data) else { return nil }
    return CGImage(width: Int(w), height: Int(h), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(w) * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

public final class CGImageDestination {
    fileprivate let url: URL
    fileprivate var image: CGImage?
    fileprivate var description: String?
    fileprivate init(url: URL) { self.url = url }
}

public func CGImageDestinationCreateWithURL(_ url: CFURL, _ type: CFString, _ count: Int, _ options: CFDictionary?) -> CGImageDestination? {
    type == "public.png" && count == 1 ? CGImageDestination(url: url) : nil
}

public func CGImageDestinationAddImage(_ dest: CGImageDestination, _ image: CGImage, _ properties: CFDictionary?) {
    dest.image = image
    if let png = properties?[kCGImagePropertyPNGDictionary] as? [String: Any] { dest.description = png[kCGImagePropertyPNGDescription] as? String }
}

public func CGImageDestinationFinalize(_ dest: CGImageDestination) -> Bool {
    guard let image = dest.image, let data = image.dataProvider?.data else { return false }
    // Zeilen nach Grau (1), RGB (3) oder RGBA (4) umpacken
    let channels = image.bitsPerPixel == 8 ? 1 : (image.alphaInfo == .none || image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst ? 3 : 4)
    var out = [UInt8](repeating: 0, count: image.width * image.height * channels)
    data.withUnsafeBytes { src in
        let p = src.bindMemory(to: UInt8.self)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let o = (y * image.width + x) * channels
                if channels == 1 { out[o] = p[y * image.bytesPerRow + x] } else {
                    let c = image.rgba(x: x, y: y)
                    out[o] = c.r; out[o + 1] = c.g; out[o + 2] = c.b
                    if channels == 4 { out[o + 3] = c.a }
                }
            }
        }
    }
    return out.withUnsafeBufferPointer { buf in
        cimg_write_png(dest.url.path, buf.baseAddress, Int32(image.width), Int32(image.height), Int32(channels), Int32(image.width * channels), dest.description) == 0
    }
}

// MARK: - Eigenschaften (nur PNG: Größe und Textkommentar „Description“)

public let kCGImagePropertyPixelWidth = "PixelWidth"
public let kCGImagePropertyPixelHeight = "PixelHeight"

public func CGImageSourceCopyPropertiesAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CFDictionary? {
    guard index == 0, let data = try? Data(contentsOf: source.url), data.count > 33,
          Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else { return nil }
    func u32(_ at: Int) -> Int { Int(data[at]) << 24 | Int(data[at + 1]) << 16 | Int(data[at + 2]) << 8 | Int(data[at + 3]) }
    var result: [String: Any] = [kCGImagePropertyPixelWidth: u32(16), kCGImagePropertyPixelHeight: u32(20)]
    var png: [String: Any] = [:]
    var position = 8
    while position + 12 <= data.count {
        let length = u32(position)
        let type = String(decoding: data[position + 4..<position + 8], as: UTF8.self)
        let body = position + 8
        if type == "tEXt", body + length <= data.count, let zero = data[body..<body + length].firstIndex(of: 0) {
            let key = String(decoding: data[body..<zero], as: UTF8.self)
            png[key] = String(decoding: data[(zero + 1)..<body + length], as: UTF8.self)
        }
        if type == "IEND" { break }
        position = body + length + 4
    }
    result[kCGImagePropertyPNGDictionary] = png
    return result
}
