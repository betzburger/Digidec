// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import AppKit

// MARK: - Wasserfall-Ausschnitt für den KI-Assistenten

/// Ausschnitt des HF-Wasserfalls um ein Signal als PNG mit Frequenzachse und Marke an der gemessenen Mitte
enum AssistantWaterfallImage {
    /// `image`: das ganze Wasserfallbild (Spalten = Bins, Zeilen = Zeit, neueste oben), `startHz`: Frequenz am linken Rand
    @MainActor
    static func png(from image: CGImage, startHz: Double, binHz: Double, measurement m: SignalMeasurement) -> Data? {
        let total = image.width
        guard total > 16, binHz > 0 else { return nil }
        // Ausschnitt: mindestens ±3 kHz und ±40 Bins, sonst das Zweieinhalbfache der belegten Breite
        let half = max(m.occupiedHz * 2.5, 40 * binHz, 3000)
        let centerBin = (m.centerHz - startHz) / binHz
        var c0 = Int((centerBin - half / binHz).rounded(.down)), c1 = Int((centerBin + half / binHz).rounded(.up))
        c0 = max(0, c0); c1 = min(total, c1)
        guard c1 - c0 >= 16, let crop = image.cropping(to: CGRect(x: c0, y: 0, width: c1 - c0, height: image.height)) else { return nil }
        let lowHz = startHz + Double(c0) * binHz, highHz = startHz + Double(c1) * binHz
        let view = AssistantWaterfallImageView(crop: crop, lowHz: lowHz, highHz: highHz, centerHz: m.centerHz,
                                               edgeLowHz: m.lowEdgeHz, edgeHighHz: m.highEdgeHz, seconds: m.duration)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

private struct AssistantWaterfallImageView: View {
    let crop: CGImage
    let lowHz: Double
    let highHz: Double
    let centerHz: Double
    let edgeLowHz: Double
    let edgeHighHz: Double
    let seconds: Double

    private let width: CGFloat = 640, plotHeight: CGFloat = 280, axisHeight: CGFloat = 26, footer: CGFloat = 18

    private func x(_ hz: Double) -> CGFloat { CGFloat((hz - lowHz) / (highHz - lowHz)) * width }

    private func label(_ hz: Double) -> String {
        let span = highHz - lowHz
        let v = hz / 1000
        return String(format: span < 20_000 ? "%.2f" : "%.1f", v).replacingOccurrences(of: ".", with: ",")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Achse
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(red: 0.07, green: 0.08, blue: 0.10))
                ForEach(0..<5, id: \.self) { i in
                    let hz = lowHz + (highHz - lowHz) * Double(i) / 4
                    Text(label(hz))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                        .position(x: min(max(x(hz), 34), width - 34), y: 9)
                    Rectangle().fill(Color.white.opacity(0.5)).frame(width: 1, height: 6).position(x: x(hz), y: axisHeight - 3)
                }
            }
            .frame(width: width, height: axisHeight)
            // Wasserfall mit Marke
            ZStack(alignment: .topLeading) {
                Image(decorative: crop, scale: 1).resizable().interpolation(.none).frame(width: width, height: plotHeight)
                Rectangle().fill(Color.white.opacity(0.55)).frame(width: 1, height: plotHeight).position(x: x(edgeLowHz), y: plotHeight / 2)
                Rectangle().fill(Color.white.opacity(0.55)).frame(width: 1, height: plotHeight).position(x: x(edgeHighHz), y: plotHeight / 2)
                Rectangle().fill(Color.cyan).frame(width: 1.5, height: plotHeight).position(x: x(centerHz), y: plotHeight / 2)
            }
            .frame(width: width, height: plotHeight)
            .clipped()
            Text("Frequenz in kHz →  ·  Zeit ↓ (neueste Zeile oben, \(String(format: "%.0f", seconds)) s)  ·  cyan: Mitte, weiß: Rand der belegten Bandbreite")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: width, height: footer)
                .background(Color(red: 0.07, green: 0.08, blue: 0.10))
        }
        .frame(width: width, height: axisHeight + plotHeight + footer)
    }
}
