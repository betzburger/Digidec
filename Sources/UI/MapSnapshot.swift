// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
import SwiftUI
import MapKit
import AppKit

/// Karte als PNG ablegen: Die Grundkarte kommt vom `MKMapSnapshotter` (die SwiftUI-Karte selbst lässt sich nicht abbilden),
/// Flächen, Isobaren, Linien, Wege und Punkte werden darauf gezeichnet. Gespeichert wird der gerade sichtbare Ausschnitt.
enum MapSnapshotExporter {
    /// `~/Documents/Digidec/Maps`
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Digidec/Maps", isDirectory: true)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let caption: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Dateiname ohne Sonderzeichen: „Karte-RTTY-TEMP-20261005-123000.png“
    static func fileName(_ name: String, at date: Date = Date()) -> String {
        let clean = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "-" }
        return String(clean) + "-" + stamp.string(from: date) + ".png"
    }

    /// Bild erzeugen und speichern; Rückgabe: Datei oder Fehlertext
    @MainActor
    static func save(content: MapContent, region: MKCoordinateRegion, size: CGSize, appearance: MapAppearance,
                     showTracks: Bool, name: String, title: String?) async -> Result<URL, SnapshotError> {
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        switch appearance {
        case .standard: options.mapType = .mutedStandard
        case .hybrid: options.mapType = .hybrid
        case .imagery: options.mapType = .satellite
        }
        let now = Date()
        let label = (title.map { $0 + " · " } ?? "") + caption.string(from: now) + " UTC"

        // Das Ergebnis (Data) ist Sendable; die Zeichnung läuft in der Rückmeldung auf der Hauptwarteschlange
        let data: Data? = await withCheckedContinuation { continuation in
            let holder = SnapshotHolder()
            holder.snapshotter = MKMapSnapshotter(options: options)
            holder.snapshotter?.start(with: .main) { snapshot, _ in
                guard let snapshot else {
                    continuation.resume(returning: nil)
                    holder.snapshotter = nil
                    return
                }
                // Der Schnappschuss wird nur auf der Hauptwarteschlange (hier) benutzt; die Hülle sagt das dem Compiler
                let box = SnapshotBox(snapshot: snapshot)
                let png = MainActor.assumeIsolated {
                    render(snapshot: box.snapshot, content: content, showTracks: showTracks, label: label)
                }
                continuation.resume(returning: png)
                holder.snapshotter = nil
            }
        }
        guard let data else { return .failure(.snapshot) }
        let url = directory.appendingPathComponent(fileName(name, at: now))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url)
            return .success(url)
        } catch {
            return .failure(.write(error.localizedDescription))
        }
    }

    enum SnapshotError: Error, Equatable {
        case snapshot
        case write(String)

        var message: String {
            switch self {
            case .snapshot: return "Kartenbild nicht erhältlich (kein Netz?)"
            case .write(let why): return "Speichern nicht möglich: \(why)"
            }
        }
    }

    /// Trägt den Schnappschuss vom Rückruf (Hauptwarteschlange) in die Zeichnung (Hauptakteur), ohne dass er den Bereich verlässt
    private struct SnapshotBox: @unchecked Sendable {
        let snapshot: MKMapSnapshotter.Snapshot
    }

    /// Hält den Schnappschuss-Auftrag am Leben, bis die Rückmeldung kommt
    private final class SnapshotHolder: @unchecked Sendable {
        var snapshotter: MKMapSnapshotter?
    }

    // MARK: Zeichnen

    private static let scale: CGFloat = 2

    @MainActor
    private static func render(snapshot: MKMapSnapshotter.Snapshot, content: MapContent, showTracks: Bool, label: String) -> Data? {
        let size = snapshot.image.size
        guard size.width > 1, size.height > 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let base = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = base
        let cg = base.cgContext
        cg.scaleBy(x: scale, y: scale)
        // Grundkarte (Ursprung unten links)
        snapshot.image.draw(in: NSRect(origin: .zero, size: size))
        // Ab hier Ursprung oben links, wie `snapshot.point(for:)`
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

        func pt(_ p: GeoPoint) -> CGPoint { snapshot.point(for: p.cl) }
        func inView(_ p: CGPoint) -> Bool { p.x > -40 && p.y > -40 && p.x < size.width + 40 && p.y < size.height + 40 }

        // Farbflächen
        for patch in content.patches {
            let pts = patch.corners.map(pt)
            guard let first = pts.first else { continue }
            let path = NSBezierPath()
            path.move(to: first)
            for p in pts.dropFirst() { path.line(to: p) }
            path.close()
            NSColor(MarkerBadge.scale(patch.level)).withAlphaComponent(0.34).setFill()
            path.fill()
        }

        func stroke(_ points: [CGPoint], color: NSColor, width: CGFloat) {
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.move(to: first)
            for p in points.dropFirst() { path.line(to: p) }
            color.setStroke()
            path.stroke()
        }

        // Linien (Großkreise, Wege der Module): bei zwei Punkten mit Großkreis-Zwischenpunkten
        for line in content.lines {
            var pts = line.points
            if line.geodesic, pts.count == 2 {
                pts = (0...24).map { i in
                    let f = Double(i) / 24
                    let d = Geo.distanceKm(pts[0], pts[1])
                    return d < 1 ? pts[0] : Geo.destination(from: pts[0], bearing: Geo.bearing(from: pts[0], to: pts[1]), km: d * f)
                }
            }
            stroke(pts.map(pt), color: NSColor(line.tone.color).withAlphaComponent(0.6), width: 1.4)
        }

        // Isobaren mit dunklem Saum für den Kontrast
        for c in content.contours {
            let pts = c.points.map(pt)
            stroke(pts, color: NSColor.black.withAlphaComponent(0.45), width: 3.4)
            stroke(pts, color: NSColor.white.withAlphaComponent(0.95), width: 1.5)
        }

        if showTracks {
            for m in content.markers where m.track.count > 1 {
                let pts = m.track.map(pt)
                stroke(pts, color: NSColor.black.withAlphaComponent(0.55), width: 5)
                stroke(pts, color: NSColor(m.tone.color).withAlphaComponent(0.85), width: 3)
            }
        }

        // Reichweitenkreise
        for m in content.markers where m.radiusKm > 0 {
            let center = pt(m.coordinate)
            let edge = pt(Geo.destination(from: m.coordinate, bearing: 90, km: m.radiusKm))
            let r = abs(edge.x - center.x)
            guard r > 2, inView(center) else { continue }
            let path = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            NSColor(m.tone.color).withAlphaComponent(0.07).setFill()
            path.fill()
            NSColor(m.tone.color).withAlphaComponent(0.5).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        // Beschriftung der Isobaren
        for c in content.contours {
            guard let text = c.label, let at = c.labelPoint else { continue }
            let p = pt(at)
            guard inView(p) else { continue }
            drawText(text, at: p, size: 10, weight: .bold, color: .black, background: NSColor.white.withAlphaComponent(0.85))
        }

        // Standort
        if let h = content.home {
            let p = pt(h)
            if inView(p) {
                let ring = NSBezierPath(ovalIn: NSRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16))
                NSColor(RadioTheme.bgDeep).withAlphaComponent(0.9).setFill()
                ring.fill()
                NSColor(RadioTheme.vfdAmber).setStroke()
                ring.lineWidth = 2
                ring.stroke()
            }
        }

        // Punkte
        let titled = content.markers.count < 60
        for m in content.markers {
            let p = pt(m.coordinate)
            guard inView(p) else { continue }
            if let text = m.valueText {
                let color = NSColor(m.valueLevel.map { MarkerBadge.scale($0) } ?? m.tone.color)
                if let h = m.headingDeg {
                    drawArrow(at: p, headingDeg: h, color: color)
                }
                drawText(text, at: p, size: 10, weight: .black, color: NSColor.black.withAlphaComponent(0.85), background: color, border: NSColor.black.withAlphaComponent(0.4))
            } else {
                let color = NSColor(m.tone.color)
                let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
                NSColor(RadioTheme.bgDeep).withAlphaComponent(0.92).setFill()
                dot.fill()
                color.setStroke()
                dot.lineWidth = 1.6
                dot.stroke()
                if titled {
                    drawText(m.title, at: CGPoint(x: p.x, y: p.y + 14), size: 9, weight: .semibold, color: .white, background: NSColor.black.withAlphaComponent(0.55))
                }
            }
        }

        // Fußzeile
        drawText("Digidec · " + label, at: CGPoint(x: 8, y: size.height - 12), size: 10, weight: .semibold, color: .white,
                 background: NSColor.black.withAlphaComponent(0.6), anchorLeft: true)

        return rep.representation(using: .png, properties: [:])
    }

    @MainActor
    private static func drawText(_ text: String, at p: CGPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor,
                                 background: NSColor, border: NSColor? = nil, anchorLeft: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let s = NSAttributedString(string: text, attributes: attrs)
        let ts = s.size()
        let pad: CGFloat = 4
        let w = ts.width + pad * 2, h = ts.height + 2
        let rect = NSRect(x: anchorLeft ? p.x : p.x - w / 2, y: p.y - h / 2, width: w, height: h)
        let path = NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2)
        background.setFill()
        path.fill()
        if let border {
            border.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        s.draw(at: NSPoint(x: rect.minX + pad, y: rect.minY + 1))
    }

    @MainActor
    private static func drawArrow(at p: CGPoint, headingDeg: Double, color: NSColor) {
        // Pfeilspitze 17 Punkte über dem Wert, gedreht um den Punkt (Richtung im Uhrzeigersinn ab Norden)
        let a = headingDeg * .pi / 180
        func rot(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: p.x + x * CGFloat(cos(a)) - y * CGFloat(sin(a)), y: p.y + x * CGFloat(sin(a)) + y * CGFloat(cos(a)))
        }
        let path = NSBezierPath()
        path.move(to: rot(0, -22))
        path.line(to: rot(-5, -14))
        path.line(to: rot(5, -14))
        path.close()
        color.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 0.8
        path.stroke()
    }
}
