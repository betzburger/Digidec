// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI

/// Umriss eines Fahrzeugs (Quadrat −1 … +1 auf die Fläche gespannt)
struct SilhouetteShape {
    let silhouette: MapSilhouette

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX, cy = rect.midY, hx = rect.width / 2, hy = rect.height / 2
        for contour in silhouette.contours {
            guard let first = contour.first else { continue }
            path.move(to: CGPoint(x: cx + first.x * hx, y: cy + first.y * hy))
            for p in contour.dropFirst() { path.addLine(to: CGPoint(x: cx + p.x * hx, y: cy + p.y * hy)) }
            path.closeSubpath()
        }
        return path
    }
}

// Konformität als Erweiterung (nicht Hauptakteur-gebunden), wie bei SwiftUI-eigenen Typen
extension SilhouetteShape: Shape {
    #if os(Linux)
    // Die eigene SwiftUI-Teilmenge (Linux) liefert für Formen keinen Standardkörper
    var body: some View { fill() }
    #endif
}

/// Punkt auf der Karte: Kreis in Tonfarbe mit Symbol oder Zeichen, Kursstrich
struct MarkerBadge: View {
    let marker: MapMarker
    let selected: Bool
    var span: Double = 60

    var body: some View {
        let color = marker.valueLevel.map { Self.scale($0) } ?? marker.tone.color
        // Bei starkem Hereinzoomen vergrößern sich die Silhouetten (1,0x bis 2,2x)
        let zoomScale: CGFloat = {
            guard span < 2.0 else { return 1.0 }
            let steps = max(0.0, -log2(span / 2.0))
            return min(2.2, 1.0 + 0.16 * CGFloat(steps))
        }()
        ZStack {
            if let text = marker.valueText {
                // Messwert: Beschriftung auf farbigem Grund, bei Wind mit Pfeil in Windrichtung
                if let h = marker.headingDeg {
                    Image(systemName: "arrow.up")
                        .font(.system(size: selected ? 13 : 11, weight: .black))
                        .foregroundColor(color)
                        .rotationEffect(.degrees(h))
                        .offset(y: selected ? -20 : -17)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                }
                Text(text)
                    .font(.system(size: selected ? 12 : 10, weight: .black, design: .monospaced))
                    .foregroundColor(.black.opacity(0.85))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(color))
                    .overlay(Capsule().stroke(selected ? Color.white : Color.black.opacity(0.4), lineWidth: selected ? 2 : 1))
                    .shadow(color: color.opacity(selected ? 0.8 : 0.35), radius: selected ? 6 : 2)
            } else if let sil = marker.silhouette {
                // Umriss von oben, um den Kurs gedreht (Höhe oder Tonfarbe), bei Auswahl größer mit weißem Rand und Schein
                let side = sil.size * marker.silhouetteScale * zoomScale * (selected ? 1.3 : 1)
                SilhouetteShape(silhouette: sil)
                    .fill(color)
                    .overlay(SilhouetteShape(silhouette: sil).stroke(selected ? Color.white : Color.black.opacity(0.7), lineWidth: selected ? 1.6 : 0.9))
                    .frame(width: side, height: side)
                    .rotationEffect(.degrees(marker.headingDeg ?? 0))
                    .shadow(color: color.opacity(selected ? 0.9 : 0.35), radius: selected ? 6 : 2)
            } else {
            
            if let h = marker.headingDeg {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(color)
                    .rotationEffect(.degrees(h))
                    .offset(y: -14)
                    .rotationEffect(.degrees(0))
            }
            Circle().fill(RadioTheme.bgDeep.opacity(0.92)).frame(width: selected ? 24 : 18, height: selected ? 24 : 18)
            Circle().stroke(color, lineWidth: selected ? 2.5 : 1.5).frame(width: selected ? 24 : 18, height: selected ? 24 : 18)
            if let s = marker.symbol {
                Image(systemName: s).font(.system(size: selected ? 11 : 8.5, weight: .bold)).foregroundColor(color)
            } else if let g = marker.glyph {
                Text(g).font(.system(size: selected ? 13 : 10))
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            }
        }
        .shadow(color: marker.valueText == nil && marker.silhouette == nil ? color.opacity(selected ? 0.7 : 0.3) : .clear, radius: selected ? 6 : 2)
    }

    /// Farbskala 0 (blau) … 0,5 (grün/gelb) … 1 (rot)
    static func scale(_ level: Double) -> Color {
        Color(hue: 0.66 * (1 - min(max(level, 0), 1)), saturation: 0.75, brightness: 0.98)
    }
}
