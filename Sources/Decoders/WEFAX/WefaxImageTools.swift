// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import Foundation
import CoreGraphics
import ImageIO

/// Nachbearbeitung empfangener Wetterfax-Bilder (8-Bit-Graustufen, Zeile für Zeile).
/// Hat der Empfang den Zeilenanfang falsch getroffen (z. B. Phasing verpasst), ist das Bild zwar gerade, aber zyklisch gegen
/// den Rand verschoben: `shifted` schiebt es mit Umlauf zurück, `autoShift` findet die Naht selbst.
public enum WefaxImageTools {
    /// Schiebt jede Zeile um `dx` Pixel nach rechts; was rechts hinausläuft, erscheint links wieder (Umlauf).
    public static func shifted(_ pixels: [UInt8], width: Int, height: Int, by dx: Int) -> [UInt8] {
        guard width > 0, height > 0, pixels.count >= width * height else { return pixels }
        let d = ((dx % width) + width) % width
        if d == 0 { return pixels }
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            // Pixel x → (x + d) % width: der Rest [width-d, width) kommt nach vorn
            out.replaceSubrange(row..<(row + d), with: pixels[(row + width - d)..<(row + width)])
            out.replaceSubrange((row + d)..<(row + width), with: pixels[row..<(row + width - d)])
        }
        return out
    }

    /// Verschiebung (−width/2 … +width/2), die den hellsten, breiten senkrechten Streifen an den Bildrand legt.
    /// Wetterkarten haben links und rechts einen weißen Rand; liegt er in der Bildmitte, ist das Bild zyklisch verschoben.
    /// Liefert 0, wenn kein klar hellerer Streifen zu erkennen ist (z. B. Textseiten).
    public static func autoShift(_ pixels: [UInt8], width: Int, height: Int) -> Int {
        guard width >= 48, height >= 8, pixels.count >= width * height else { return 0 }
        // Tinte je Spalte (dunkel = viel)
        var ink = [Double](repeating: 0, count: width)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width { ink[x] += Double(255 - Int(pixels[row + x])) }
        }
        let perColumn = ink.map { $0 / Double(height) / 255.0 }
        let win = max(16, width / 12)
        // zyklische gleitende Summe
        var prefix = [Double](repeating: 0, count: width + win + 1)
        for i in 0..<(width + win) { prefix[i + 1] = prefix[i] + perColumn[i % width] }
        var best = 0, bestSum = Double.greatestFiniteMagnitude
        for start in 0..<width {
            let sum = prefix[start + win] - prefix[start]
            if sum < bestSum { bestSum = sum; best = start }
        }
        let median = perColumn.sorted()[width / 2]
        let windowMean = bestSum / Double(win)
        guard median > 0.02, windowMean < 0.6 * median else { return 0 }
        // Der Streifen kann breiter sein als das Fenster: Mitte der hellen Spalten um das beste Fenster bestimmen
        let limit = max(windowMean * 1.5, 0.01)
        var lo = best, hi = best + win - 1          // in laufenden (nicht umgebrochenen) Koordinaten
        while hi - lo < width - 1, perColumn[(lo - 1 + width * 2) % width] <= limit { lo -= 1 }
        while hi - lo < width - 1, perColumn[(hi + 1) % width] <= limit { hi += 1 }
        let center = ((lo + hi) / 2 % width + width) % width
        let dx = (width - center) % width
        return dx > width / 2 ? dx - width : dx
    }

    /// Lädt ein PNG/JPEG als 8-Bit-Graustufen
    public static func load(url: URL) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 255, count: w * h)
        let drawn = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? (buf, w, h) : nil
    }
}
