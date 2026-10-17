// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
#if !canImport(AppKit)
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Ausschnitt des HF-Wasserfalls um ein Signal als PNG (Linux: ohne Frequenzachse und Marke; die Beschriftung zeichnet nur die macOS-Fassung)
enum AssistantWaterfallImage {
    @MainActor
    static func png(from image: CGImage, startHz: Double, binHz: Double, measurement m: SignalMeasurement) -> Data? {
        let total = image.width
        guard total > 16, binHz > 0 else { return nil }
        let half = max(m.occupiedHz * 2.5, 40 * binHz, 3000)
        let centerBin = (m.centerHz - startHz) / binHz
        var c0 = Int((centerBin - half / binHz).rounded(.down)), c1 = Int((centerBin + half / binHz).rounded(.up))
        c0 = max(0, c0); c1 = min(total, c1)
        guard c1 - c0 >= 16, let crop = image.cropping(to: CGRect(x: c0, y: 0, width: c1 - c0, height: image.height)) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wasserfall-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, crop, nil)
        return CGImageDestinationFinalize(dest) ? try? Data(contentsOf: url) : nil
    }
}
#endif
